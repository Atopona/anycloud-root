
#!/usr/bin/env bash
set -Eeuo pipefail

# 必须通过 sudo 运行
if [[ $EUID -ne 0 ]]; then
    echo "请使用 sudo bash $0 执行"
    exit 1
fi

# 自动识别原 SSH 用户
SSH_USER="${SUDO_USER:-}"
if [[ -z "$SSH_USER" || "$SSH_USER" == "root" ]]; then
    echo "无法识别原 SSH 用户，请使用 sudo 从普通用户执行"
    exit 1
fi

USER_HOME="$(getent passwd "$SSH_USER" | cut -d: -f6)"
SOURCE_KEYS="${USER_HOME}/.ssh/authorized_keys"

if [[ ! -s "$SOURCE_KEYS" ]]; then
    echo "错误：找不到 SSH 公钥文件：$SOURCE_KEYS"
    exit 1
fi

# 定位 SSH 服务及配置文件
if command -v sshd >/dev/null 2>&1; then
    SSHD="$(command -v sshd)"
elif [[ -x /usr/sbin/sshd ]]; then
    SSHD=/usr/sbin/sshd
else
    echo "错误：找不到 sshd"
    exit 1
fi

CONFIG=/etc/ssh/sshd_config
BACKUP="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

cp -a "$CONFIG" "$BACKUP"

# 安装 root 的公钥
install -d -m 700 -o root -g root /root/.ssh
install -m 600 -o root -g root \
    "$SOURCE_KEYS" /root/.ssh/authorized_keys

# 修改全局配置：只允许 root 使用密钥登录
# 删除主配置中原有的全局设置，再添加新值
# 保留 Match 块，避免全局指令被放入 Match 上下文
python3 - "$CONFIG" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    lines = f.readlines()

result = []
inserted = False

for line in lines:
    stripped = line.strip().lower()

    if stripped.startswith("match ") and not inserted:
        result.append("PermitRootLogin prohibit-password\n")
        inserted = True

    key = stripped.split(None, 1)[0] if stripped else ""
    if key == "permitrootlogin":
        continue

    result.append(line)

if not inserted:
    result.append("\nPermitRootLogin prohibit-password\n")

with open(path, "w", encoding="utf-8") as f:
    f.writelines(result)
PY

# 验证配置；失败则恢复备份
if ! "$SSHD" -t; then
    cp -a "$BACKUP" "$CONFIG"
    echo "错误：SSH 配置验证失败，已恢复备份"
    exit 1
fi

# 检查最终生效的 root 登录策略
EFFECTIVE="$("$SSHD" -T -C user=root,host=localhost,addr=127.0.0.1)"
if ! grep -qx 'permitrootlogin prohibit-password' <<< "$EFFECTIVE"; then
    cp -a "$BACKUP" "$CONFIG"
    echo "错误：最终配置未生效，已恢复主配置文件"
    echo "请检查 sshd_config.d 中的配置及 Match 规则"
    exit 1
fi

# 重启 SSH 服务
if command -v systemctl >/dev/null 2>&1; then
    if systemctl restart ssh 2>/dev/null; then
        :
    elif systemctl restart sshd 2>/dev/null; then
        :
    else
        echo "错误：SSH 服务重启失败，请保持当前会话并检查日志"
        exit 1
    fi
elif command -v service >/dev/null 2>&1; then
    service ssh restart || service sshd restart
else
    echo "错误：无法识别服务管理器"
    exit 1
fi

echo "已启用 root SSH 密钥登录"
echo "root 密码登录仍然禁止"
echo "原配置备份：$BACKUP"
echo "请在新的终端测试：ssh -i <密钥文件> root@<服务器IP>"
