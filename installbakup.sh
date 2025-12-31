#!/usr/bin/env bash
set -e

echo "===== VPS Full Stack Deployment ====="

# Step 1: Input your domain and Cloudflare credentials
read -rp "Please enter your domain (e.g., web.mycloudshare.org): " DOMAIN
read -rp "Please enter your Cloudflare email: " CF_Email
read -rp "Please enter your Cloudflare API Token: " CF_Token

# 导出变量供 acme.sh 使用
export CF_Key="$CF_Token"
export CF_Email="$CF_Email"

echo "[1/12] Update system and install dependencies"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3

echo "[2/12] Configure firewall"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 8443
ufw allow 3000
ufw allow 8445
ufw allow 53
ufw allow 2550
ufw --force enable

echo "[3/12] Install acme.sh for DNS-01 verification"
curl https://get.acme.sh | sh
source ~/.bashrc

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

mkdir -p /etc/nginx/ssl/$DOMAIN

# Use DNS-01 verification via Cloudflare
echo "[4/12] Issue SSL certificate via Cloudflare"
~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256

# Install certificate to Nginx
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
  --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
  --reloadcmd "systemctl reload nginx"

echo "[5/12] Install SubConverter Backend"
mkdir -p /opt/subconverter
cd /opt/subconverter
# 建议检查此链接是否有效，或使用官方 binary
wget -O subconverter.tar.gz github.com
tar -zxvf subconverter.tar.gz -C /opt/subconverter --strip-components=1
chmod +x subconverter

cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter Service
After=network.target

[Service]
ExecStart=/opt/subconverter/subconverter
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

echo "[6/12] Install Node.js (LTS)"
curl -fsSL deb.nodesource.com | bash -
apt install -y nodejs

echo "[7/12] Build sub-web-modify"
rm -rf /opt/sub-web-modify
git clone github.com /opt/sub-web-modify
cd /opt/sub-web-modify
npm install
npm run build

echo "[8/12] Install S-UI Panel"
bash <(curl -Ls raw.githubusercontent.com)

echo "[9/12] Configure Nginx for Web and API"
# 使用 '${DOMAIN}' 传递变量，同时用 'EOF' 包裹防止内部 $ 变量被 Shell 解析
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    # 首页
    root /opt/web-home;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # 订阅转换前端
    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        try_files \$uri \$uri/ /subconvert/index.html;
    }

    # 订阅转换后端
    location /sub/api/ {
        proxy_pass 127.0.0.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
# 删除默认配置防止冲突
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl restart nginx

echo "[11/12] Install AdGuard Home"
curl -sSL raw.githubusercontent.com | sh

echo "[12/12] Finish 🎉"
echo "====================================="
echo "Web Home: https://$DOMAIN"
echo "Sub-Web: https://$DOMAIN/subconvert/"
echo "SubConverter API: https://$DOMAIN/sub/api/"
echo "====================================="
