#!/usr/bin/env bash
set -e

echo "======================================"
echo " VPS 全栈部署 (DNS-01 + 共用 443 + VLESS)"
echo "======================================"

read -rp "请输入主域名 (如 web.mycloudshare.org): " DOMAIN
read -rp "请输入 Cloudflare 邮箱: " CF_EMAIL
read -rp "请输入 Cloudflare API Token: " CF_TOKEN

export CF_Email="$CF_EMAIL"
export CF_Token="$CF_TOKEN"

echo "[1/10] 更新系统 & 安装依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3 nodejs npm

echo "[2/10] 防火墙设置"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000
ufw allow 25500
ufw allow 8445
ufw --force enable

echo "[3/10] 安装 acme.sh（DNS-01 / Cloudflare）"
curl https://get.acme.sh | sh
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

mkdir -p /etc/nginx/ssl/$DOMAIN

echo "[4/10] 获取 Let's Encrypt 证书"
~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file       /etc/nginx/ssl/$DOMAIN/key.pem \
  --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
  --reloadcmd     "systemctl reload nginx"

echo "[5/10] 部署 subconvert 后端源码"
if [ -d "/root/vps-deployment/subconvert" ]; then
  echo "subconvert 源码存在"
else
  echo "⚠ 没有找到 subconvert 源码，请确认已 fork 并放到 vps-deployment/subconvert"
  exit 1
fi

cd /root/vps-deployment/subconvert
go build -o /opt/subconvert ./...

cat >/etc/systemd/system/subconvert.service <<EOF
[Unit]
Description=subconvert Backend
After=network.target

[Service]
ExecStart=/opt/subconvert
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now subconvert

echo "[6/10] 构建 sub-web-modify"
cd /root/vps-deployment/sub-web-modify
npm install
npm run build

echo "[7/10] 准备搜索主页"
if [ -d "/root/vps-deployment/web" ]; then
  mkdir -p /opt/web-home
  cp -r /root/vps-deployment/web/* /opt/web-home/
fi

echo "[8/10] 安装 S-UI 面板"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

echo "[9/10] 安装 AdGuard Home"
curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh

echo "[10/10] 写入 Nginx 配置"
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    root /opt/web-home;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /subconvert/ {
        alias /root/vps-deployment/sub-web-modify/dist/;
        index index.html;
        try_files \$uri \$uri/ /subconvert/index.html;
    }

    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

echo "======================================"
echo "🎉 全部部署完成"
echo "主页: https://$DOMAIN"
echo "订阅转换: https://$DOMAIN/subconvert"
echo "Sub API: http://127.0.0.1:25500/"
echo "AdGuard Home: http://<你的IP>:3000"
echo "S-UI 面板: ssh -L 2095:127.0.0.1:2095 root@你的IP"
echo "======================================"
