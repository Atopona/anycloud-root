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
    echo "无法识别原 SSH 用户，请从普通用户通过 sudo 执行"
    exit 1
fi

USER_HOME="$(getent passwd "$SSH_USER" | cut -d: -f6)"
if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
    echo "错误：无法获取用户 $SSH_USER 的主目录"
    exit 1
fi

SOURCE_KEYS="${USER_HOME}/.ssh/authorized_keys"

if [[ ! -s "$SOURCE_KEYS" ]]; then
    echo "错误：找不到 SSH 公钥文件：$SOURCE_KEYS"
    exit 1
fi

# 定位 SSH 服务端程序
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

# 备份配置文件
cp -a "$CONFIG" "$BACKUP"
echo "配置备份：$BACKUP"

# 安装 root 的 SSH 公钥
install -d -m 700 -o root -g root /root/.ssh
install -m 600 -o root -g root \
    "$SOURCE_KEYS" /root/.ssh/authorized_keys

# 修改主配置文件，允许 root 使用密钥登录
python3 - "$CONFIG" <<'PY'
import sys

path = sys.argv[1]

with open(path, encoding="utf-8") as f:
    lines = f.readlines()

result = []
inserted = False

for line in lines:
    stripped = line.strip().lower()

    # 在第一个 Match 块前插入全局配置
    if stripped.startswith("match ") and not inserted:
        result.append("PermitRootLogin prohibit-password\n")
        inserted = True

    key = stripped.split(None, 1)[0] if stripped else ""

    # 删除原有 PermitRootLogin 设置，避免主配置内部冲突
    if key == "permitrootlogin":
        continue

    result.append(line)

# 如果没有 Match 块，则追加全局配置
if not inserted:
    result.append("\nPermitRootLogin prohibit-password\n")

with open(path, "w", encoding="utf-8") as f:
    f.writelines(result)
PY

# 验证 SSH 配置语法
if ! "$SSHD" -t; then
    cp -a "$BACKUP" "$CONFIG"
    echo "错误：SSH 配置验证失败，已恢复主配置文件"
    exit 1
fi

# 获取最终生效的 root 登录策略
if ! EFFECTIVE="$("$SSHD" -T -C user=root,host=localhost,addr=127.0.0.1)"; then
    cp -a "$BACKUP" "$CONFIG"
    echo "错误：无法读取最终 SSH 配置，已恢复主配置文件"
    exit 1
fi

ROOT_LOGIN="$(awk '$1 == "permitrootlogin" {print $2; exit}' <<< "$EFFECTIVE")"

# 修复点：旧版 OpenSSH 可能输出 without-password
# 它与 prohibit-password 的含义相同
if [[ "$ROOT_LOGIN" != "prohibit-password" &&
      "$ROOT_LOGIN" != "without-password" ]]; then
    cp -a "$BACKUP" "$CONFIG"
    echo "错误：最终 root 登录策略不符合预期"
    echo "当前策略：${ROOT_LOGIN:-未知}"
    echo "已恢复主配置文件，请检查 sshd_config.d 和 Match 规则"
    exit 1
fi

# 同时确认公钥认证已启用
if ! grep -qx 'pubkeyauthentication yes' <<< "$EFFECTIVE"; then
    cp -a "$BACKUP" "$CONFIG"
    echo "错误：公钥认证未启用，已恢复主配置文件"
    exit 1
fi

# 重启 SSH 服务
if command -v systemctl >/dev/null 2>&1; then
    if systemctl restart ssh 2>/dev/null; then
        :
    elif systemctl restart sshd 2>/dev/null; then
        :
    else
        echo "错误：SSH 服务重启失败"
        echo "请保持当前 SSH 会话，并检查服务日志"
        exit 1
    fi
elif command -v service >/dev/null 2>&1; then
    if ! service ssh restart && ! service sshd restart; then
        echo "错误：SSH 服务重启失败，请检查服务日志"
        exit 1
    fi
else
    echo "错误：无法识别服务管理器"
    exit 1
fi

echo
echo "======================================"
echo "root SSH 密钥登录配置完成"
echo "有效策略：$ROOT_LOGIN"
echo "公钥认证：已启用"
echo "root 密码登录：禁止"
echo "配置备份：$BACKUP"
echo "======================================"
echo
echo "请在新的终端测试："
echo "ssh -i <密钥文件> root@<服务器公网IP>"
echo
echo "请先确认新连接成功，再关闭当前 SSH 会话。"
