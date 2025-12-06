#!/bin/bash
set -e

echo "=========== VPS 自动部署 (带本地 VLESS订阅后端) =========="

read -p "请输入主站域名(如 example.com): " DOMAIN_MAIN
read -p "请输入面板域名(如 panel.example.com): " DOMAIN_PANEL

#######################################
# INSTALL DEPENDENCIES
#######################################
apt update -y
apt install -y curl wget unzip socat git

#######################################
# INSTALL CADDY
#######################################
echo ">>> 安装 CADDY"
apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/debian/raw/gpg.key" \
    | tee /etc/apt/trusted.gpg.d/caddy-stable.asc
curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/debian/raw/caddy-stable.list" \
    | tee /etc/apt/sources.list.d/caddy-stable.list
apt update -y
apt install -y caddy

#######################################
# INSTALL S-UI
#######################################
echo ">>> 安装 S-UI"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

#######################################
# INSTALL Enhanced subconverter (MetaCubeX/subconverter)
#######################################
echo ">>> 安装本地 VLESS 订阅后端"
mkdir -p /opt/sub
cd /opt/sub
git clone https://github.com/MetaCubeX/subconverter.git .
chmod +x subconverter

cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=Subconverter VLESS版
After=network.target

[Service]
WorkingDirectory=/opt/sub
ExecStart=/opt/sub/subconverter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

#######################################
# INSTALL Bing Style Web UI
#######################################
echo ">>> 安装 WEB 前端"
mkdir -p /var/www/site
cd /var/www/site

curl -sL https://raw.githubusercontent.com/about300/vps-deployment/main/web/index.html -o index.html
curl -sL https://raw.githubusercontent.com/about300/vps-deployment/main/web/style.css -o style.css
curl -sL https://raw.githubusercontent.com/about300/vps-deployment/main/web/script.js -o script.js

#######################################
# CADDY CONFIG
#######################################
echo ">>> 写入 CADDY 配置"
cat >/etc/caddy/Caddyfile <<EOF
{
    email admin@$DOMAIN_MAIN
}

$DOMAIN_MAIN {
    root * /var/www/site
    file_server

    @api path_regexp ^/sub
    reverse_proxy @api http://127.0.0.1:18080
}

$DOMAIN_PANEL {
    reverse_proxy localhost:81
}
EOF

systemctl restart caddy

#######################################
# RESULT
#######################################
echo
echo "=================================================="
echo "  ✔ 部署完成!"
echo "=================================================="
echo "主页：https://$DOMAIN_MAIN"
echo "面板：https://$DOMAIN_PANEL"
echo
echo "⚠️ Reality配置需在面板里手动设置"
echo "⚠️ VLESS订阅转换 API 已本地运行"
echo "=================================================="
