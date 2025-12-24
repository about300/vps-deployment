#!/usr/bin/env bash
set -e

echo "========================================"
echo " 全栈一键部署（Ubuntu 24.04 稳定版）"
echo " - Nginx (stream + http, 443 共用)"
echo " - SubConverter"
echo " - sub-web-modify (about300)"
echo " - S-UI（仅安装，不暴露）"
echo " - Reality / VLESS 手动配置"
echo "========================================"

read -rp "请输入主域名（如 try.mycloudshare.org）: " DOMAIN
read -rp "请输入 Cloudflare 邮箱: " CF_EMAIL
read -rp "请输入 Cloudflare API Token: " CF_TOKEN

export CF_Email="$CF_EMAIL"
export CF_Token="$CF_TOKEN"

# -----------------------------
# 基础环境
# -----------------------------
apt update -y
apt install -y \
  curl wget git unzip socat cron ufw \
  nginx build-essential python3 python-is-python3

# -----------------------------
# 防火墙
# -----------------------------
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 25500
ufw allow 53
ufw allow 8445
ufw allow 8380
ufw allow 50913
ufw allow 6220
ufw allow 62203
ufw --force enable

# -----------------------------
# acme.sh + Let's Encrypt
# -----------------------------
curl https://get.acme.sh | sh
ACME="$HOME/.acme.sh/acme.sh"

"$ACME" --set-default-ca --server letsencrypt

CERT_DIR="/etc/nginx/ssl/$DOMAIN"
mkdir -p "$CERT_DIR"

"$ACME" --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256

"$ACME" --install-cert -d "$DOMAIN" \
  --key-file "$CERT_DIR/key.pem" \
  --fullchain-file "$CERT_DIR/fullchain.pem"

# -----------------------------
# SubConverter
# -----------------------------
mkdir -p /opt/subconverter
cd /opt/subconverter

wget -O subconverter \
  https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
chmod +x subconverter

cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter
After=network.target

[Service]
ExecStart=/opt/subconverter/subconverter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

# -----------------------------
# sub-web-modify（about300）
# -----------------------------
apt install -y nodejs npm

rm -rf /opt/sub-web
git clone https://github.com/about300/sub-web-modify.git /opt/sub-web
cd /opt/sub-web

npm install
npm run build

# -----------------------------
# Web 首页（搜索）
# -----------------------------
mkdir -p /opt/web
cat >/opt/web/index.html <<EOF
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Search</title>
</head>
<body style="text-align:center;margin-top:15%">
<h2>Search</h2>
<form action="https://www.bing.com/search" method="get">
<input name="q" style="width:320px;height:34px">
<br><br>
<button type="submit">Search</button>
</form>
<br>
<a href="/sub/?backend=https://$DOMAIN/sub/api/">订阅转换</a>
</body>
</html>
EOF

# -----------------------------
# Nginx 主配置（stream + http）
# -----------------------------
cat >/etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;

include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
}

stream {
    map \$ssl_preread_server_name \$backend {
        $DOMAIN             web_backend;
        www.51kankan.vip    reality_backend;
        default             web_backend;
    }

    upstream web_backend {
        server 127.0.0.1:8443;
    }

    upstream reality_backend {
        server 127.0.0.1:4430;
    }

    server {
        listen 443 reuseport;
        ssl_preread on;
        proxy_pass \$backend;
    }
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile on;

    server {
        listen 8443 ssl http2;
        server_name $DOMAIN;

        ssl_certificate     $CERT_DIR/fullchain.pem;
        ssl_certificate_key $CERT_DIR/key.pem;

        location / {
            root /opt/web;
            index index.html;
        }

        location /sub/ {
            alias /opt/sub-web/dist/;
            index index.html;
            try_files \$uri \$uri/ /index.html;
        }

        location /sub/api/ {
            proxy_pass http://127.0.0.1:25500/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }
    }
}
EOF

nginx -t
systemctl restart nginx

# -----------------------------
# S-UI（仅安装，不暴露）
# -----------------------------
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

echo "========================================"
echo " 🎉 部署完成"
echo ""
echo "Web 首页:        https://$DOMAIN"
echo "订阅转换:        https://$DOMAIN/sub/"
echo "Sub API:         https://$DOMAIN/sub/api/"
echo ""
echo "S-UI 面板（本地）："
echo "ssh -L 2095:127.0.0.1:2095 root@服务器IP"
echo ""
echo "Reality / VLESS："
echo "- 在 S-UI 中手动创建"
echo "- 监听端口：4430"
echo "- SNI：www.51kankan.vip"
echo "- 443 已由 Nginx stream 共用"
echo "========================================"
