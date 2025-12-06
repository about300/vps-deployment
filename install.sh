#!/bin/bash
# =========================================
# VPS 部署一键脚本 - Ubuntu 22/24
# 功能：更新系统、安装依赖、Caddy、S-UI、VLESS+Reality、Subconverter、Web 前端
# 仅开放必要端口，保留 SSH 22
# =========================================

set -e

# 1. 系统更新
echo "==> 更新系统..."
apt update -y
apt upgrade -y
apt install -y curl wget tar git python3 python3-pip ufw

# 2. 设置防火墙
echo "==> 配置防火墙..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 22        # SSH
read -p "请输入 S-UI 面板端口(默认2095): " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-2095}
ufw allow $PANEL_PORT/tcp

read -p "请输入 VLESS/Reality 端口(默认443): " VLESS_PORT
VLESS_PORT=${VLESS_PORT:-443}
ufw allow $VLESS_PORT/tcp

read -p "请输入 Subconverter API 端口(默认25500): " SUB_PORT
SUB_PORT=${SUB_PORT:-25500}
ufw allow $SUB_PORT/tcp

read -p "请输入 Web 前端端口(默认8080): " WEB_PORT
WEB_PORT=${WEB_PORT:-8080}
ufw allow $WEB_PORT/tcp

ufw --force enable
echo "防火墙已配置完成."

# 3. 安装 Caddy
echo "==> 安装 Caddy..."
apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | apt-key add -
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update -y
apt install -y caddy

# Caddy 配置模板
mkdir -p /etc/caddy
cat > /etc/caddy/Caddyfile <<EOF
<YOUR_DOMAIN> {
    reverse_proxy localhost:$WEB_PORT
    tls {
        # 保存证书到 root 目录
        cert_file /root/caddy.crt
        key_file /root/caddy.key
    }
}
EOF

# 4. 安装 S-UI 面板
echo "==> 安装 S-UI..."
SUI_VERSION="v1.3.7"
wget -O /tmp/s-ui-linux-amd64.tar.gz https://github.com/alireza0/s-ui/releases/download/${SUI_VERSION}/s-ui-linux-amd64.tar.gz
tar -xzvf /tmp/s-ui-linux-amd64.tar.gz -C /usr/local/
cd /usr/local/s-ui
./s-ui.sh install

# S-UI 交互
echo "请按提示设置 S-UI 面板"
./s-ui.sh

# 5. 安装 VLESS+Reality
echo "==> 安装 Xray-core ..."
bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install

echo "请手动在 S-UI 面板配置 VLESS+Reality 节点和伪装域名 <YOUR_DOMAIN>"

# 6. 安装本地 Subconverter
echo "==> 安装 Subconverter ..."
git clone https://github.com/tindy2013/subconverter.git /opt/subconverter
cd /opt/subconverter
pip3 install -r requirements.txt
# systemd 管理 Subconverter
cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=Subconverter Service
After=network.target

[Service]
ExecStart=/usr/bin/python3 /opt/subconverter/subconverter.py
Restart=on-failure
User=root
WorkingDirectory=/opt/subconverter

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable subconverter
systemctl start subconverter

# 7. 部署 Web 前端
echo "==> 部署 Web 前端..."
mkdir -p /var/www/html
cp -r ./web/* /var/www/html/

# 8. 启动 Caddy
echo "==> 启动 Caddy ..."
systemctl enable caddy
systemctl restart caddy

# 9. 输出信息
echo "===================================="
echo "安装完成!"
echo "S-UI 面板端口: $PANEL_PORT"
echo "VLESS/Reality 节点端口: $VLESS_PORT"
echo "Subconverter API 端口: $SUB_PORT"
echo "Web 前端端口: $WEB_PORT"
echo "请访问面板完成 VLESS 节点配置和伪装域名 <YOUR_DOMAIN>"
echo "===================================="
