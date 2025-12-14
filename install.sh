#!/usr/bin/env bash
set -e

### ====== 基本变量 ======
DOMAIN="friend.mycloudshare.org"
INSTALL_DIR="/opt"
SUBCONVERTER_PORT="25500"

echo "==============================="
echo " SubConverter 一键部署脚本"
echo " 域名: $DOMAIN"
echo "==============================="

### ====== 系统依赖 ======
echo "[1/8] 安装基础依赖..."
apt update -y
apt install -y \
  curl wget git nginx socat cron \
  nodejs npm ufw ca-certificates

### ====== 防火墙 ======
echo "[2/8] 配置防火墙..."
ufw allow 443
ufw allow ssh
ufw --force enable

### ====== acme.sh ======
echo "[3/8] 安装 acme.sh..."
curl https://get.acme.sh | sh
source ~/.bashrc

read -rp "请输入 Cloudflare Global API Key: " CF_Key
read -rp "请输入 Cloudflare Email: " CF_Email

export CF_Key
export CF_Email

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

### ====== 申请证书（DNS API） ======
echo "[4/8] 申请 SSL 证书（DNS API）..."
~/.acme.sh/acme.sh --issue \
  --dns dns_cf \
  -d "$DOMAIN" \
  --keylength ec-256

~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --ecc \
  --key-file       /root/server.key \
  --fullchain-file /root/server.crt \
  --reloadcmd     "systemctl reload nginx"

### ====== subconverter ======
echo "[5/8] 安装 subconverter..."
cd $INSTALL_DIR
rm -rf subconverter
git clone https://github.com/tindy2013/subconverter.git
cd subconverter

chmod +x subconverter
cat > config.ini <<EOF
[common]
listen=0.0.0.0
port=$SUBCONVERTER_PORT
EOF

cat > /etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter Service
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR/subconverter
ExecStart=$INSTALL_DIR/subconverter/subconverter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

### ====== sub-web ======
echo "[6/8] 构建 sub-web 前端..."
cd $INSTALL_DIR
rm -rf sub-web
git clone https://github.com/youshandefeiyang/sub-web-modify sub-web
cd sub-web

npm install
cat > vue.config.js <<EOF
module.exports = {
  publicPath: '/sub/'
}
EOF

npm run build

### ====== Nginx 配置 ======
echo "[7/8] 配置 Nginx..."
cat > /etc/nginx/sites-enabled/default <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /root/server.crt;
    ssl_certificate_key /root/server.key;

    root /opt/vps-deploy;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /sub/api/ {
        proxy_pass http://127.0.0.1:$SUBCONVERTER_PORT/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /sub/ {
        root /opt/sub-web/dist;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }
}

server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
EOF

nginx -t
systemctl reload nginx

### ====== 完成 ======
echo "==============================="
echo " 🎉 安装完成！"
echo " 主页: https://$DOMAIN/"
echo " Sub:  https://$DOMAIN/sub/"
echo " API:  https://$DOMAIN/sub/api/version"
echo "==============================="
