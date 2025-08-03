#!/bin/bash

# 确保以 sudo 权限运行
if [[ $EUID -ne 0 ]]; then
  echo "请使用 sudo 执行此脚本"
  exit 1
fi

# 1. 设置 root 密码（可选）
echo "为 root 设置密码（输入后按回车）"
passwd root

# 2. 确保 root 用户 shell 未被禁用
chsh -s /bin/bash root

# 3. 创建 SSH 目录并设置权限
mkdir -p /root/.ssh
chmod 700 /root/.ssh

# 4. 复制当前用户的 SSH 公钥到 root（假设 admin 使用密钥登录）
cp /home/admin/.ssh/authorized_keys /root/.ssh/
chmod 600 /root/.ssh/authorized_keys
chown -R root:root /root/.ssh

# 5. 修改 sshd_config 以允许 root 登录
sed -i 's/^#*\s*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#*\s*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

# 6. 重启 SSH 服务
if command -v systemctl >/dev/null; then
    systemctl restart ssh
else
    service ssh restart
fi

echo "✅ 已启用 root SSH 登录。你可以用以下命令登录："
echo "ssh root@$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || hostname -I | awk '{print $1}')"
