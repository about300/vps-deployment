#!/usr/bin/env bash
set -e

echo "===== VPS 全栈部署（Web + Sub + Reality 共存） ====="

read -rp "请输入 Web 域名（如 webview.mycloudshare.org）: " WEB_DOMAIN
read -rp "请输入 Reality 域名（如 webview.vl.mycloudshare.org）: " VL_DOMAIN

### 基础环境
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx nodejs npm

### 防火墙
for p in 22 80 443 53 2550 3000 8445 8446 5001 8096; do
  ufw allow $p
done
ufw --force enable

### acme.sh（Cloudflare DNS-01 + Let's Encrypt）
if [ ! -f ~/.acme.sh/acme.sh ]; then
  curl https://get.acme.sh | sh
fi
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

mkdir -p /etc/nginx/ssl/$WEB_DOMAIN

~/.acme.sh/acme.sh --issue \
  --dns dns_cf \
  -d "$WEB_DOMAIN" \
  -d "$VL_DOMAIN" || true

~/.acme.sh/acme.sh --install-cert -d "$WEB_DOMAIN" \
  --key-file /etc/nginx/ssl/$WEB_DOMAIN/key.pem \
  --fullchain-file /etc/nginx/ssl/$WEB_DOMAIN/fullchain.pem \
  --reloadcmd "systemctl reload nginx"

### 1️⃣ 搜索主页（bing 风格）
if [ ! -d /opt/web-home ]; then
  git clone https://github.com/about300/web-home /opt/web-home
fi

### 2️⃣ SubConverter 后端
if [ ! -f /opt/subconverter/subconverter ]; then
  mkdir -p /opt/subconverter
  wget -O /opt/subconverter/subconverter \
    https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
  chmod +x /opt/subconverter/subconverter
fi

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

### 3️⃣ sub-web-modify（前端）
if [ ! -d /opt/sub-web-modify ]; then
  git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
  cd /opt/sub-web-modify
  npm install
  npm run build
fi

### 4️⃣ Nginx（严格分离 root）
cat >/etc/nginx/conf.d/web.conf <<EOF
server {
    listen 80;
    server_name $WEB_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $WEB_DOMAIN;

    ssl_certificate     /etc/nginx/ssl/$WEB_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$WEB_DOMAIN/key.pem;

    root /opt/web-home;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }
}
EOF

rm -f /etc/nginx/conf.d/default.conf
nginx -t
systemctl reload nginx

echo "======================================"
echo "✅ Web 首页: https://$WEB_DOMAIN"
echo "✅ 订阅转换: https://$WEB_DOMAIN/subconvert"
echo "✅ Sub API: https://$WEB_DOMAIN/sub/api"
echo "✅ Reality 域名: $VL_DOMAIN（仅用于 VLESS）"
echo "======================================"
