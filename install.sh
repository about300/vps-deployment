#!/usr/bin/env bash
set -e

echo "=== VPS 一键部署（方案A｜CF Zone Token） ==="

read -rp "请输入你的域名（如 girl.mycloudshare.org）: " DOMAIN
read -rp "请输入 Cloudflare 注册邮箱: " CF_EMAIL
read -rp "请输入 Cloudflare Zone API Token: " CF_TOKEN

export DEBIAN_FRONTEND=noninteractive

echo "[1/10] 基础环境"
apt update -y
apt install -y curl wget git nginx ufw socat cron unzip nodejs npm

echo "[2/10] 防火墙放行 TCP / UDP"
ufw allow OpenSSH
ufw allow 80
ufw allow 443
ufw allow 2095
ufw allow 3000
ufw allow 1:65535/tcp
ufw allow 1:65535/udp
ufw --force enable

echo "[3/10] 安装 acme.sh"
curl https://get.acme.sh | sh
source ~/.bashrc

export CF_Token="$CF_TOKEN"
export CF_Email="$CF_EMAIL"

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

mkdir -p /etc/nginx/ssl

~/.acme.sh/acme.sh --issue \
  --dns dns_cf \
  -d "$DOMAIN"

~/.acme.sh/acme.sh --install-cert \
  -d "$DOMAIN" \
  --key-file       /etc/nginx/ssl/$DOMAIN.key \
  --fullchain-file /etc/nginx/ssl/$DOMAIN.crt \
  --reloadcmd "systemctl reload nginx"

echo "[4/10] 部署 Web 主站 UI"
rm -rf /opt/vps-deploy
git clone https://github.com/about300/vps-deployment.git /opt/vps-deploy

echo "[5/10] 部署 SubConverter（about300）"
mkdir -p /opt/subconverter
wget -O /opt/subconverter/subconverter \
  https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
chmod +x /opt/subconverter/subconverter

cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter
After=network.target

[Service]
ExecStart=/opt/subconverter/subconverter
WorkingDirectory=/opt/subconverter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl enable subconverter
systemctl restart subconverter

echo "[6/10] 构建 Sub-Web（careywang）"
rm -rf /opt/sub-web
git clone https://github.com/careywang/sub-web.git /opt/sub-web
cd /opt/sub-web
npm install
npm run build

echo "[7/10] Nginx 配置"
cat >/etc/nginx/conf.d/$DOMAIN.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/nginx/ssl/$DOMAIN.crt;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN.key;

    root /opt/vps-deploy;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
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
EOF

rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

echo "[8/10] 安装 AdGuard Home（3000）"
curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh || true

echo "[9/10] 安装 s-ui（2095）"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

echo "[10/10] 完成"

cat <<EOF

====================================
部署完成 ✅

主页：
https://$DOMAIN

订阅转换：
https://$DOMAIN/sub

Sub 默认模板：
https://raw.githubusercontent.com/about300/ACL4SSR/master/Clash/config/Online_Full_github.ini

AdGuard Home：
http://$DOMAIN:3000

s-ui 面板：
http://$DOMAIN:2095
====================================
EOF
