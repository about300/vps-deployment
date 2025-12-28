#!/usr/bin/env bash
set -e

echo "===== VPS 全栈部署（Reality / SNI / 二级域） ====="

read -rp "Web 域名（如 cdn.mycloudshare.org）: " WEB_DOMAIN
read -rp "Reality SNI 域名（如 img.mycloudshare.org）: " REALITY_SNI
read -rp "Cloudflare Email: " CF_EMAIL
read -rp "Cloudflare API Token: " CF_TOKEN

export CF_Email="$CF_EMAIL"
export CF_Token="$CF_TOKEN"

### 1. 基础环境
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx

### 2. 防火墙
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 53
ufw allow 3000
ufw allow 2550
ufw allow 8445
ufw allow 8446
ufw allow 5001
ufw allow 8096
ufw --force enable

### 3. acme.sh（DNS-01 + Let's Encrypt）
if [ ! -d ~/.acme.sh ]; then
  curl https://get.acme.sh | sh
fi
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

mkdir -p /etc/nginx/ssl

~/.acme.sh/acme.sh --issue \
  -d "$WEB_DOMAIN" \
  --dns dns_cf \
  --keylength ec-256 || true

~/.acme.sh/acme.sh --install-cert \
  -d "$WEB_DOMAIN" \
  --key-file /etc/nginx/ssl/key.pem \
  --fullchain-file /etc/nginx/ssl/cert.pem \
  --reloadcmd "systemctl reload nginx"

### 4. SubConverter
if [ ! -f /opt/subconverter/subconverter ]; then
  mkdir -p /opt/subconverter
  cd /opt/subconverter
  wget -O subconverter https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
  chmod +x subconverter
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

### 5. Node.js
if ! command -v node >/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt install -y nodejs
fi

### 6. sub-web-modify
rm -rf /opt/sub-web-modify
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify
npm install
npm run build

### 7. nginx Web
cat >/etc/nginx/conf.d/web.conf <<EOF
server {
  listen 80;
  server_name $WEB_DOMAIN;
  return 301 https://\$host\$request_uri;
}

server {
  listen 443 ssl http2;
  server_name $WEB_DOMAIN;

  ssl_certificate /etc/nginx/ssl/cert.pem;
  ssl_certificate_key /etc/nginx/ssl/key.pem;

  root /opt/sub-web-modify/dist;
  index index.html;

  location / {
    try_files \$uri \$uri/ /index.html;
  }

  location /sub/api/ {
    proxy_pass http://127.0.0.1:2550/;
  }
}
EOF

nginx -t
systemctl restart nginx

echo "===== 第一阶段完成 ====="

### 安装s-ui面板

bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)


### 安装Adgurad home

curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh