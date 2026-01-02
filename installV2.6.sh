#!/usr/bin/env bash
set -e
##############################
# VPS 全栈部署脚本
# Version: v2.6
# Author: Auto-generated (修复防火墙兼容性)
# Description: 部署完整VPS服务栈（Sub-Web前端+聚合后端+S-UI面板+VLESS+Reality共用443）
##############################

echo "===== VPS 全栈部署（v2.6） ====="

# -----------------------------
# 用户输入
# -----------------------------
read -rp "请输入您的域名 (例如 example.domain): " DOMAIN
read -rp "请输入 Cloudflare 邮箱: " CF_Email
read -rp "请输入 Cloudflare API Token: " CF_Token
export CF_Email
export CF_Token

# -----------------------------
# 服务端口定义
# -----------------------------
VLESS_PORT=5000
SUB_WEB_API_PORT=3001
SUBCONVERTER_BIN="https://github.com/about300/vps-deployment/raw/refs/heads/main/bin/subconverter"
WEB_HOME_REPO="https://github.com/about300/vps-deployment.git"
SUB_WEB_API_REPO="https://github.com/about300/sub-web-api.git"

# -----------------------------
# 系统更新与依赖
# -----------------------------
echo "[1/14] 更新系统与安装依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3 npm net-tools

# -----------------------------
# 防火墙配置（兼容 Ubuntu 24.0）
# -----------------------------
echo "[2/14] 配置防火墙（兼容 Ubuntu 24.0）"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000  # AdGuard Home
ufw allow 8445
ufw allow 8446

# 本地访问端口（兼容语法）
ufw allow proto tcp from 127.0.0.1 to any port 25500  # SubConverter
ufw allow proto tcp from 127.0.0.1 to any port 2095   # S-UI
ufw allow proto tcp from 127.0.0.1 to any port ${SUB_WEB_API_PORT} # Sub-Web API
ufw allow proto tcp from 127.0.0.1 to any port ${VLESS_PORT}       # VLESS

# 禁止外部访问2095（S-UI）
ufw deny 2095

ufw --force enable
echo "[INFO] 防火墙配置完成"

# -----------------------------
# 安装 acme.sh
# -----------------------------
echo "[3/14] 安装 acme.sh"
if [ ! -d "$HOME/.acme.sh" ]; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
else
    echo "[INFO] acme.sh 已安装，跳过"
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
mkdir -p /etc/nginx/ssl/$DOMAIN

# -----------------------------
# 申请证书
# -----------------------------
echo "[4/14] 申请或检查 SSL 证书"
if [ ! -f "/etc/nginx/ssl/$DOMAIN/fullchain.pem" ]; then
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
else
    echo "[INFO] SSL 证书已存在，跳过申请"
fi

# -----------------------------
# 安装证书到 Nginx
# -----------------------------
echo "[5/14] 安装证书到 Nginx"
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
    --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
    --reloadcmd "systemctl reload nginx"

# -----------------------------
# 安装 SubConverter
# -----------------------------
echo "[6/14] 安装 SubConverter"
mkdir -p /opt/subconverter
if [ ! -f "/opt/subconverter/subconverter" ]; then
    wget -O /opt/subconverter/subconverter $SUBCONVERTER_BIN
    chmod +x /opt/subconverter/subconverter
fi

cat > /opt/subconverter/subconverter.env <<EOF
API_MODE=true
API_HOST=0.0.0.0
API_PORT=25500
CACHE_ENABLED=true
CACHE_SUBSCRIPTION=true
CACHE_CONFIG=true
CACHE_UPDATE_INTERVAL=600
MANAGEMENT_PASS=admin123
EOF
chmod 600 /opt/subconverter/subconverter.env

cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter 服务
After=network.target
[Service]
Type=simple
WorkingDirectory=/opt/subconverter
ExecStart=/opt/subconverter/subconverter
Restart=always
RestartSec=3
EnvironmentFile=/opt/subconverter/subconverter.env
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

# -----------------------------
# 安装聚合后端
# -----------------------------
echo "[7/14] 安装 sub-web-api"
rm -rf /opt/sub-web-api
git clone $SUB_WEB_API_REPO /opt/sub-web-api
cd /opt/sub-web-api
npm install --production || true

cat >/etc/systemd/system/sub-web-api.service <<EOF
[Unit]
Description=Sub-Web-API 聚合后端
After=network.target subconverter.service
Requires=subconverter.service
[Service]
Type=simple
User=root
WorkingDirectory=/opt/sub-web-api
ExecStart=/usr/bin/node /opt/sub-web-api/index.js
Restart=always
RestartSec=3
Environment=NODE_ENV=production
Environment=PORT=${SUB_WEB_API_PORT}
Environment=SUB_CONVERTER_URL=http://127.0.0.1:25500
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable sub-web-api
systemctl restart sub-web-api

# -----------------------------
# 构建 Sub-Web 前端
# -----------------------------
echo "[8/14] 构建 Sub-Web 前端"
rm -rf /opt/sub-web-modify
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify
cat > vue.config.js <<'EOF'
module.exports = { publicPath: '/subconvert/' }
EOF
npm install
npm run build

# -----------------------------
# 安装 S-UI 面板
# -----------------------------
echo "[9/14] 安装 S-UI"
if [ ! -d "/opt/s-ui" ]; then
    bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
    if [ -f "/opt/s-ui/config.json" ]; then
        sed -i 's/"address": "127.0.0.1"/"address": "0.0.0.0"/g' /opt/s-ui/config.json
    fi
fi
systemctl restart s-ui || true

# -----------------------------
# 配置 Web 主页
# -----------------------------
echo "[10/14] 配置 Web 主页"
rm -rf /opt/web-home
mkdir -p /opt/web-home
git clone $WEB_HOME_REPO /opt/web-home/tmp
mv /opt/web-home/tmp/web /opt/web-home/current
rm -rf /opt/web-home/tmp

# -----------------------------
# 配置 Nginx 共用443（主页+Sub-Web+S-UI+VLESS+Reality）
# -----------------------------
echo "[11/14] 配置 Nginx 共用443"
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    root /opt/web-home/current;
    index index.html;

    # Web主页
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Sub-Web 前端
    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    # Sub-Web API
    location /subconvert/api/ {
        proxy_pass http://127.0.0.1:${SUB_WEB_API_PORT}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    # S-UI 面板反代
    location /sui/ {
        proxy_pass http://127.0.0.1:2095/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        rewrite ^/sui$ /sui/ permanent;
        rewrite ^/sui/(.*)$ /app/\$1 break;
    }

    # VLESS+Reality WS
    location /ws/ {
        proxy_pass http://127.0.0.1:${VLESS_PORT}/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t
systemctl reload nginx

echo "====================================="
echo "🎉 VPS 全栈部署完成 v2.6（防火墙兼容 Ubuntu 24.0）"
echo "====================================="
