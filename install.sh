#!/bin/bash
set -e

echo "=== 更新系统 ==="
apt update -y
apt upgrade -y
apt install -y wget curl tar ufw

echo "=== 安装 Caddy ==="
apt install -y caddy

echo "=== 配置防火墙 ==="
ufw allow 22
ufw allow 443
ufw allow 2095
ufw allow 2096
ufw allow 8081
ufw --force enable

echo "=== 安装 S-UI 面板 ==="
cd /tmp
wget https://github.com/alireza0/s-ui/releases/download/v1.3.7/s-ui-linux-amd64.tar.gz
tar -xzf s-ui-linux-amd64.tar.gz
cd s-ui
bash s-ui.sh install
systemctl enable s-ui
systemctl start s-ui

echo "=== 安装 Subconverter 后端 ==="
mkdir -p /opt/subconvert
cp ./subconvert/subconverter /opt/subconvert/
cp ./subconvert/config.json /opt/subconvert/
chmod +x /opt/subconvert/subconverter

# 创建 systemd 服务
cat >/etc/systemd/system/subconvert.service <<EOF
[Unit]
Description=Subconverter Service
After=network.target

[Service]
ExecStart=/opt/subconvert/subconverter
WorkingDirectory=/opt/subconvert
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconvert
systemctl start subconvert

echo "=== 部署 Sub Web 前端 ==="
mkdir -p /var/www/sub-web
cp -r ./sub-web-modify/* /var/www/sub-web/
echo "前端访问：http://<你的服务器IP或域名>/sub-web/"

echo "=== 安装完成 ==="
