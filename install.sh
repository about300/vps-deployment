#!/usr/bin/env bash
set -e

echo "======================================"
echo " 一键部署 全栈服务"
echo " - SubConverter + sub‑web‑modify"
echo " - S‑UI 面板"
echo " - AdGuard Home 3000 端口"
echo " - SSL 使用 Let’s Encrypt DNS‑01 证书"
echo "======================================"

read -rp "请输入你的域名 (如 example.com): " DOMAIN
read -rp "请输入 Cloudflare 注册邮箱: " CF_EMAIL
read -rp "请输入 Cloudflare API Token: " CF_TOKEN
read -rp "请输入你的 sub-web-modify 仓库 HTTPS 地址: " SUBWEB_REPO

export CF_Email="$CF_EMAIL"
export CF_Token="$CF_TOKEN"

echo "[INFO] 更新系统并安装依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3

echo "[INFO] 配置防火墙"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000
ufw allow 8445
ufw --force enable

echo "[INFO] 安装 acme.sh 用于 Let’s Encrypt 证书"
curl https://get.acme.sh | sh
ACME_SH="$HOME/.acme.sh/acme.sh"

echo "[INFO] 设置默认 CA 为 Let’s Encrypt"
"$ACME_SH" --set-default-ca --server letsencrypt

CERT_DIR="/etc/nginx/ssl/$DOMAIN"
mkdir -p "$CERT_DIR"

echo "[INFO] 申请或续期 SSL 证书"
if "$ACME_SH" --renew -d "$DOMAIN" --force >/dev/null 2>&1; then
  echo "[OK] SSL 证书已存在或续期"
else
  "$ACME_SH" --issue --dns dns_cf -d "$DOMAIN"
fi

echo "[INFO] 安装证书到 Nginx"
"$ACME_SH" --install-cert -d "$DOMAIN" \
  --key-file "$CERT_DIR/key.pem" \
  --fullchain-file "$CERT_DIR/fullchain.pem" \
  --reloadcmd "systemctl reload nginx"

echo "[INFO] 部署 SubConverter 后端"
mkdir -p /opt/subconverter
cd /opt/subconverter
wget -q -O subconverter https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
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
systemctl enable --now subconverter

echo "[INFO] 克隆 sub-web-modify 前端源码"
rm -rf /opt/sub-web-src
git clone "$SUBWEB_REPO" /opt/sub-web-src

echo "[INFO] 安装 Node.js 22 via nvm 并构建前端"
export NVM_DIR="$HOME/.nvm"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.6/install.sh | bash
fi
# shellcheck source=/dev/null
. "$NVM_DIR/nvm.sh"

nvm install 22
nvm use 22

cd /opt/sub-web-src
npm install --no-audit --no-fund
npm run build

echo "[INFO] 将构建产物复制到静态目录"
rm -rf /opt/sub-web-modify/dist
mkdir -p /opt/sub-web-modify/dist
cp -r dist/* /opt/sub-web-modify/dist/

echo "[INFO] 安装 AdGuard Home"
curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh

echo "[INFO] 安装 S‑UI 面板（本机访问）"
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

    # Search 页面
    location / {
        root /opt/vps-deploy;
        index index.html;
    }

    # 订阅转换 UI
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

    # S‑UI 面板 (SSH 隧道访问)
    location /ui/ {
        proxy_pass http://127.0.0.1:2095/app/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # S‑UI 订阅
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
echo "部署成功 🎉"
echo ""
echo "• Search 首页: https://$DOMAIN"
echo "• 订阅转换 UI: https://$DOMAIN/sub/?backend=https://$DOMAIN/sub/api/"
echo "• SubConverter API: https://$DOMAIN/sub/api/"
echo "• S‑UI 面板 (SSH 隧道访问): https://$DOMAIN/ui/"
echo "• 8445 端口预留可用于 DoH DNS 服务"
echo ""
echo "⚠ 请在 S‑UI 面板中自行添加 Reality / VLESS 节点并设置 TLS & SNI"
echo "======================================"
