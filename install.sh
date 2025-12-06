#!/bin/bash

# ================================
# VPS 一键部署 S-UI + VLESS+Reality + Caddy + Subconvert
# ================================

set -e

# --- 交互式设置 ---
read -p "请输入你的域名（Web + VLESS SNI，例：www.example.com）: " DOMAIN
read -p "请输入 Web 面板内部端口（默认 2095）: " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-2095}
read -p "请输入 VLESS 后端内部监听端口（默认 4433）: " VLESS_PORT
VLESS_PORT=${VLESS_PORT:-4433}
read -p "请输入 S-UI admin 用户名（默认 admin）: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}
read -p "请输入 S-UI admin 密码（默认随机生成）: " ADMIN_PASS
ADMIN_PASS=${ADMIN_PASS:-$(openssl rand -base64 12)}

# --- 更新系统 & 安装依赖 ---
apt update -y && apt upgrade -y
apt install -y wget curl tar git ufw socat unzip 

# --- 配置防火墙 ---
ufw default deny incoming
ufw default allow outgoing
ufw allow 22
ufw allow 443
ufw enable

# --- 安装 Caddy ---
apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | apt-key add -
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update -y
apt install -y caddy

# Caddy 配置 TLS passthrough
cat >/etc/caddy/Caddyfile <<EOL
$DOMAIN {
  tls {
    passthrough
  }
  @vless {
    protocol tls
  }
  handle @vless {
    reverse_proxy 127.0.0.1:$VLESS_PORT
  }
  handle {
    reverse_proxy 127.0.0.1:$PANEL_PORT
  }
}
EOL

systemctl restart caddy

# --- 安装 S-UI 面板 ---
wget -O /tmp/s-ui-linux-amd64.tar.gz https://github.com/alireza0/s-ui/releases/latest/download/s-ui-linux-amd64.tar.gz
mkdir -p /opt/s-ui && tar -xzf /tmp/s-ui-linux-amd64.tar.gz -C /opt/s-ui
cd /opt/s-ui
chmod +x sui
cp s-ui.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable s-ui

# 初始化 S-UI admin
/opt/s-ui/sui reset --username $ADMIN_USER --password $ADMIN_PASS --port $PANEL_PORT
systemctl start s-ui

# --- 安装 VLESS+Reality 后端 ---
git clone https://github.com/your-local-vless-backend.git /opt/vless-backend
cd /opt/vless-backend
chmod +x run.sh
# 创建配置文件
cat >config.json <<EOL
{
  "listen_port": $VLESS_PORT,
  "domain": "$DOMAIN",
  "tls_cert": "/etc/ssl/caddy/fullchain.pem",
  "tls_key": "/etc/ssl/caddy/privkey.pem"
}
EOL
systemctl enable /opt/vless-backend/run.sh
systemctl start /opt/vless-backend/run.sh

# --- 安装 Subconvert ---
git clone https://github.com/tindy2013/subconverter.git /opt/subconverter
cd /opt/subconverter
chmod +x subconverter
# 默认配置可以后续在 panel 配置订阅转换

# --- 完成提示 ---
echo "==============================="
echo "安装完成！"
echo "S-UI 面板: http://$DOMAIN:$PANEL_PORT/app/"
echo "用户名: $ADMIN_USER"
echo "密码: $ADMIN_PASS"
echo "VLESS 后端监听端口: $VLESS_PORT"
echo "域名 SNI: $DOMAIN"
echo "==============================="
