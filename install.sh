#!/usr/bin/env bash
set -e

echo "======================================"
echo " VPS 全栈部署 install.sh（最终稳定版）"
echo " Sub-Web + SubConverter + Nginx + SSL"
echo "======================================"

# =============================
# 0. 基础变量（交互）
# =============================
read -rp "请输入绑定到本机的域名（如 sub.example.com）: " DOMAIN
read -rp "请输入 Cloudflare 邮箱: " CF_Email
read -rp "请输入 Cloudflare API Token: " CF_Token

export CF_Email
export CF_Token

# =============================
# 1. 基础环境
# =============================
echo "[1/12] 更新系统 & 安装基础依赖"
apt update -y
apt install -y \
  curl wget git unzip socat cron ufw nginx \
  build-essential python3 python-is-python3 \
  nodejs npm

# =============================
# 2. 防火墙
# =============================
echo "[2/12] 配置防火墙"
ufw allow 22
ufw allow 80
ufw allow 443
ufw --force enable

# =============================
# 3. 安装 acme.sh
# =============================
echo "[3/12] 安装 acme.sh"
if [ ! -d "$HOME/.acme.sh" ]; then
  curl https://get.acme.sh | sh
fi
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# =============================
# 4. 申请 SSL 证书（DNS-01）
# =============================
echo "[4/12] 申请 SSL 证书"
mkdir -p /etc/nginx/ssl/$DOMAIN

if [ ! -f "/etc/nginx/ssl/$DOMAIN/fullchain.pem" ]; then
  ~/.acme.sh/acme.sh --issue \
    --dns dns_cf \
    -d "$DOMAIN" \
    --keylength ec-256
fi

~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file       /etc/nginx/ssl/$DOMAIN/key.pem \
  --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
  --reloadcmd "systemctl reload nginx"

# =============================
# 5. 安装 SubConverter 后端
# =============================
echo "[5/12] 安装 SubConverter 后端"
mkdir -p /opt/subconverter
cd /opt/subconverter

if [ ! -f subconverter ]; then
  wget -O subconverter \
    https://github.com/about300/vps-deployment/raw/refs/heads/main/bin/subconverter
  chmod +x subconverter
fi

cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter
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

# =============================
# 6. 拉取并构建 sub-web 前端（关键）
# =============================
echo "[6/12] 构建 sub-web 前端（强制本地后端）"
rm -rf /opt/sub-web
git clone https://github.com/about300/sub-web-modify.git /opt/sub-web
cd /opt/sub-web

echo "[INFO] 替换前端默认后端（去肥羊）"
sed -i \
  -e "s#https://sub\.xeton\.dev/sub#/sub/api/sub#g" \
  -e "s#https://api\.subconverter\.xyz/sub#/sub/api/sub#g" \
  -e "s#subconverter\.xyz/sub#/sub/api/sub#g" \
  src/**/*.js

echo "[INFO] 写入 .env"
cat > .env <<EOF
VUE_APP_SUBCONVERTER_DEFAULT_BACKEND=/sub/api/sub
VUE_APP_MYURLS_DEFAULT_BACKEND=/sub/api/short
VUE_APP_CONFIG_UPLOAD_BACKEND=/sub/api/upload
EOF

npm install --legacy-peer-deps
npm run build

# =============================
# 7. Nginx 配置
# =============================
echo "[7/12] 配置 Nginx"
rm -f /etc/nginx/sites-enabled/default

cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    # sub-web 前端
    location / {
        root /opt/sub-web/dist;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    # SubConverter API（核心）
    location /sub/api/ {
        rewrite ^/sub/api/(.*)$ /\$1 break;
        proxy_pass http://127.0.0.1:25500;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN
nginx -t
systemctl reload nginx

# =============================
# 8. 完成
# =============================
echo "======================================"
echo "🎉 部署完成"
echo
echo "在线订阅转换工具："
echo "https://$DOMAIN"
echo
echo "后端 API 测试："
echo "https://$DOMAIN/sub/api/sub?target=clash&url=https://example.com"
echo
echo "如果不显示，请 Ctrl + F5 强刷一次"
echo "======================================"
