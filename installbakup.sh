#!/usr/bin/env bash
set -e

echo "===== VPS 全栈部署 · Reality + Web 共用 443 ====="

read -rp "请输入 WEB 域名 (如 web.mycloudshare.org): " WEB_DOMAIN
read -rp "请输入 Reality 域名 (可相同，留空则同 WEB): " REALITY_DOMAIN
REALITY_DOMAIN=${REALITY_DOMAIN:-$WEB_DOMAIN}

read -rp "请输入 Cloudflare API Token: " CF_Token
read -rp "请输入 Cloudflare Account ID (可留空): " CF_Account_ID

export CF_Token
[ -n "$CF_Account_ID" ] && export CF_Account_ID

echo
echo "WEB:      $WEB_DOMAIN"
echo "REALITY:  $REALITY_DOMAIN"
echo "==============================================="

### 1. 系统基础
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential

### 2. 防火墙
for p in 22 80 443 3000 5001 8096 8445 8446 53 25500; do
  ufw allow "$p"
done
ufw --force enable

### 3. acme.sh（DNS-01 + Let's Encrypt）
ACME="$HOME/.acme.sh/acme.sh"
if [ ! -f "$ACME" ]; then
  curl https://get.acme.sh | sh
fi

"$ACME" --set-default-ca --server letsencrypt

mkdir -p /etc/nginx/ssl/$WEB_DOMAIN

"$ACME" --issue --dns dns_cf -d "$WEB_DOMAIN" -d "$REALITY_DOMAIN"
"$ACME" --install-cert -d "$WEB_DOMAIN" \
  --key-file       /etc/nginx/ssl/$WEB_DOMAIN/key.pem \
  --fullchain-file /etc/nginx/ssl/$WEB_DOMAIN/fullchain.pem \
  --reloadcmd "systemctl reload nginx"

### 4. SubConverter 后端（25500）
mkdir -p /opt/subconverter
cd /opt/subconverter
wget -O subconverter https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
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
systemctl enable --now subconverter

### 5. Node.js
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

### 6. sub-web-modify（Vue 前端）
rm -rf /opt/sub-web
git clone https://github.com/about300/sub-web-modify /opt/sub-web
cd /opt/sub-web
npm install
npm run build

### 7. S-UI（Reality）
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

### 8. AdGuard Home
curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh

### 9. Nginx（仅 HTTP，不用 stream）
cat >/etc/nginx/conf.d/$WEB_DOMAIN.conf <<EOF
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

    root /opt/sub-web/dist;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /subconvert/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }
}
EOF

rm -f /etc/nginx/conf.d/default.conf
nginx -t
systemctl reload nginx

echo
echo "================= 部署完成 ================="
echo "主页:        https://$WEB_DOMAIN"
echo "订阅转换:    https://$WEB_DOMAIN/subconvert"
echo
echo "S-UI 面板（SSH 隧道）:"
echo "ssh -L 2095:127.0.0.1:2095 root@服务器IP"
echo
echo "Reality SNI 建议:"
echo "  $REALITY_DOMAIN"
echo "============================================"
