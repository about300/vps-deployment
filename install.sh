#!/usr/bin/env bash
set -e

echo "======================================"
echo " 一键部署 全栈服务"
echo " - SubConverter + sub-web-modify"
echo " - S-UI 面板（SSH 隧道访问）"
echo " - AdGuard Home 3000端口"
echo " - Let’s Encrypt DNS-01 自动获取证书"
echo "======================================"

read -rp "请输入你的域名（如 example.com）: " DOMAIN
read -rp "请输入 Cloudflare 注册邮箱: " CF_EMAIL
read -rp "请输入 Cloudflare API Token: " CF_TOKEN

export CF_Email="$CF_EMAIL"
export CF_Token="$CF_TOKEN"

echo "[INFO] 更新系统 & 安装基础组件"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3

echo "[INFO] 防火墙放行必要端口"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000
ufw --force enable

echo "[INFO] 安装 acme.sh 用于 Let’s Encrypt 证书"
curl https://get.acme.sh | sh
ACME_SH="$HOME/.acme.sh/acme.sh"

echo "[INFO] 切换默认 CA 为 Let’s Encrypt"
"$ACME_SH" --set-default-ca --server letsencrypt

CERT_DIR="/etc/nginx/ssl/$DOMAIN"
mkdir -p "$CERT_DIR"

echo "[INFO] 申请或续期 SSL 证书"
if "$ACME_SH" --renew -d "$DOMAIN" --force; then
  echo "[OK] SSL 证书已存在或续期"
else
  "$ACME_SH" --issue --dns dns_cf -d "$DOMAIN"
fi

echo "[INFO] 安装 SSL 到 Nginx"
"$ACME_SH" --install-cert -d "$DOMAIN" \
  --key-file "$CERT_DIR/key.pem" \
  --fullchain-file "$CERT_DIR/fullchain.pem" \
  --reloadcmd "systemctl reload nginx"

echo "[INFO] 部署 SubConverter 后端"
mkdir -p /opt/subconverter
cd /opt/subconverter
wget -O subconverter https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
chmod +x subconverter

cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter Service
After=network.target

[Service]
ExecStart=/opt/subconverter/subconverter
WorkingDirectory=/opt/subconverter
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

echo "[INFO] 构建 sub-web-modify 前端"
cd /opt/vps-deployment/sub-web-modify

export NVM_DIR="$HOME/.nvm"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.6/install.sh | bash
fi
source "$NVM_DIR/nvm.sh"
nvm install 22
nvm use 22

npm install
npm run build

rm -rf /opt/sub-web-modify/dist
mkdir -p /opt/sub-web-modify/dist
cp -r dist/* /opt/sub-web-modify/dist/

echo "[INFO] 安装 S-UI 面板（通过 SSH 隧道访问，不暴露公网端口）"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

echo "[INFO] 写入 Nginx 配置"
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/key.pem;

    # 首页 Search
    location / {
        root /opt/vps-deploy;
        index index.html;
    }

    # 订阅转换
    location /sub/ {
        alias /opt/sub-web-modify/dist/;
        index index.html;
        try_files \$uri \$uri/ /sub/index.html;
    }

    # SubConverter 后端 API
    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # S-UI 面板（SSH 隧道访问）
    location /ui/ {
        proxy_pass http://127.0.0.1:2095/app/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # S-UI 订阅
    location /suibs/ {
        proxy_pass http://127.0.0.1:2096/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

echo "======================================"
echo "🎉 全部部署完成"
echo "访问主站 Search: https://$DOMAIN"
echo "订阅转换 UI:   https://$DOMAIN/sub/?backend=https://$DOMAIN/sub/api/"
echo "S-UI 面板（通过 SSH 隧道访问）: https://$DOMAIN/ui/"
echo "======================================"
