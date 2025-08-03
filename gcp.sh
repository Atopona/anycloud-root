#!/bin/bash

# 检查是否为 root 用户
if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 用户运行此脚本"
  exit 1
fi

echo "🟡 正在为 GCP 实例开启 root SSH 登录..."

# 1. 设置 root 密码
echo "请输入新的 root 密码："
passwd root

# 2. 启用 root SSH 登录
SSHD_CONFIG="/etc/ssh/sshd_config"
if grep -q "^PermitRootLogin" "$SSHD_CONFIG"; then
    sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
else
    echo "PermitRootLogin yes" >> "$SSHD_CONFIG"
fi

# 3. 启用密码认证（如果默认禁用了）
if grep -q "^PasswordAuthentication" "$SSHD_CONFIG"; then
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONFIG"
else
    echo "PasswordAuthentication yes" >> "$SSHD_CONFIG"
fi

# 4. 重新加载 SSH 服务
echo "🔁 重启 SSH 服务..."
if command -v systemctl >/dev/null; then
    systemctl restart sshd
else
    service ssh restart
fi

echo "✅ 设置完成！现在可以使用 root 用户通过 SSH 登录该实例。"
echo "⚠️ 强烈建议你仅允许指定 IP 登录并使用防火墙控制访问。"
