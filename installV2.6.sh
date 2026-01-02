#!/usr/bin/env bash
set -e
##############################
# VPS 全栈部署脚本 V2.6
# Author: Auto-generated (融合 Reality + VLESS + S-UI)
# Description:
#  - Ubuntu 24.x 支持
#  - S-UI 面板 + VLESS + Reality 自动部署
#  - 主页 + 订阅转换 + 443 共用
#  - 自动生成证书、配置防火墙
##############################

DOMAIN="text.mycloudshare.org"
REALITY_PORT=443
VLESS_PORT=$((RANDOM%1000+5000)) # 随机 5000~5999
S_UI_PORT=5000
SUB_WEB_PORT=25500
UUID="ac1c6a2b-a576-4bf0-d1fb-6d53a816b779" # 固定 UUID，可换

# 更新系统
apt update -y && apt upgrade -y
apt install -y curl wget ufw socat nginx git unzip cron

# ----------------------------
# 防火墙配置
# ----------------------------
ufw allow ssh
ufw allow 443/tcp
ufw allow $VLESS_PORT/tcp
ufw --force enable

# ----------------------------
# 证书安装 (Let's Encrypt)
# ----------------------------
if ! command -v acme.sh &>/dev/null; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
fi
~/.acme.sh/acme.sh --issue -d $DOMAIN --nginx --force
~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
    --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
    --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
    --reloadcmd "systemctl reload nginx"

mkdir -p /etc/nginx/ssl/$DOMAIN
cp ~/.acme.sh/$DOMAIN/*.pem /etc/nginx/ssl/$DOMAIN/

# ----------------------------
# Nginx 融合配置写入 nginx.conf
# ----------------------------
cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    access_log /var/log/nginx/access.log;
    gzip on;

    # =========================
    # 主机配置（融合 Reality + Sub-Web + 主页）
    # =========================
    server {
        listen 443 ssl http2;
        server_name $DOMAIN;

        ssl_certificate /etc/nginx/ssl/$DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

        # Reality WS
        location /ws/ {
            proxy_redirect off;
            proxy_pass http://127.0.0.1:$S_UI_PORT;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
        }

        # Sub-Web
        location /subconvert/ {
            proxy_pass http://127.0.0.1:$SUB_WEB_PORT/;
            proxy_set_header Host \$host;
        }

        # 首页
        location / {
            root /var/www/html;
            index index.html index.htm;
        }
    }

    # HTTP 重定向到 HTTPS
    server {
        listen 80;
        server_name $DOMAIN;
        return 301 https://\$host\$request_uri;
    }
}
EOF

systemctl restart nginx

# ----------------------------
# 安装 S-UI 面板
# ----------------------------
if [ ! -d "/root/s-ui" ]; then
    git clone https://github.com/alireza0/s-ui /root/s-ui
fi
cd /root/s-ui
bash install.sh <<EOF
$S_UI_PORT
$UUID
EOF

# ----------------------------
# 配置 VLESS + Reality 用户
# ----------------------------
# S-UI 内部会生成配置文件，确保 443 共用，Reality
# 后续进入面板可以编辑 SNI 为 $DOMAIN

# ----------------------------
# 安装 Sub-Web
# ----------------------------
if [ ! -d "/root/sub-web" ]; then
    git clone https://github.com/about300/sub-web-modify /root/sub-web
fi
cd /root/sub-web
bash build.sh
nohup python3 server.py --port $SUB_WEB_PORT &>/dev/null &

echo "=========================================="
echo "安装完成"
echo "VLESS端口: $VLESS_PORT"
echo "Reality端口: $REALITY_PORT"
echo "S-UI面板端口: $S_UI_PORT"
echo "订阅转换端口: $SUB_WEB_PORT"
echo "UUID: $UUID"
echo "域名: $DOMAIN"
echo "=========================================="
