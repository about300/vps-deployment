#!/bin/bash
# VPS 一键部署脚本 (Ubuntu 20.04+)
# 功能：安装 S-UI 面板、VLESS 后端、Caddy、Web 前端

set -e

echo "更新系统..."
apt update -y && apt upgrade -y
apt install -y wget curl tar git ufw

# 安装 Caddy
echo "安装 Caddy..."
apt install -y debian-keyring debian-archive-keyring apt-transport-https
apt update
apt install -y caddy

# 防火墙配置，仅开放必要端口
echo "配置 UFW..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 22
ufw allow 2095    # S-UI 面板
ufw allow 2096    # S-UI Sub
ufw allow 443     # TLS/Reality
ufw --force enable

# 安装 S-UI
echo "安装 S-UI 面板..."
SUI_VER="v1.3.7"
wget -O /tmp/s-ui-linux-amd64.tar.gz "https://github.com/alireza0/s-ui/releases/download/$SUI_VER/s-ui-linux-amd64.tar.gz"
tar zxvf /tmp/s-ui-linux-amd64.tar.gz -C /tmp
cd /tmp/s-ui
bash s-ui.sh install

echo "请按提示设置面板端口、路径和管理员账号"
echo "面板安装完成后自行设置 VLESS+Reality 节点"

# 安装本地 Subconverter
echo "安装 Subconverter 后端..."
cd /root
if [ ! -d "subconverter" ]; then
    git clone https://github.com/tindy2013/subconverter.git
fi
cd subconverter
chmod +x subconverter

echo "部署 Web 前端..."
WEB_DIR="/var/www/html"
mkdir -p $WEB_DIR
cp -r $(pwd)/../web/* $WEB_DIR/

# 设置 Caddy 反向代理 / TLS
cat > /etc/caddy/Caddyfile <<EOF
:443
root * $WEB_DIR
file_server
EOF

systemctl restart caddy

echo "部署完成！"
echo "面板 URL: http://$(curl -s ifconfig.me):2095/app/"
echo "Web 前端: https://$(curl -s ifconfig.me)/"
echo "订阅转换可在 Web 前端使用"
