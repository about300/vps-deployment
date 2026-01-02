#!/usr/bin/env bash
set -e
##############################
# VPS 全栈部署脚本
# Version: v2.6
# Author: Auto-generated
# Description:
# 自动部署 VPS 全栈，包括：
# - Reality + VLESS 共用 443
# - Web 主页 + Sub-Web 前端/后端
# - S-UI 面板
# - SubConverter
# - AdGuard Home
# 兼容回滚旧配置
##############################

echo "===== VPS 全栈部署（v2.6 共用443 + Reality） ====="

# -----------------------------
# 步骤 0：用户输入
# -----------------------------
read -rp "请输入您的域名 (例如：example.domain): " DOMAIN
read -rp "请输入 Cloudflare 邮箱: " CF_Email
read -rp "请输入 Cloudflare API Token: " CF_Token
export CF_Email
export CF_Token

# 服务端口
VLESS_PORT=443              # 共用端口
SUB_WEB_API_PORT=3001
SUBCONVERTER_PORT=25500
REALITY_SNI="www.apple.com" # 默认 SNI，可后续修改
REALITY_SHORT_ID=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)

# 仓库地址
SUBCONVERTER_BIN="https://github.com/about300/vps-deployment/raw/refs/heads/main/bin/subconverter"
WEB_HOME_REPO="https://github.com/about300/vps-deployment.git"
SUB_WEB_API_REPO="https://github.com/about300/sub-web-api.git"

# -----------------------------
# 步骤 1：系统更新与依赖
# -----------------------------
echo "[1/14] 更新系统与安装依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3 npm net-tools

# -----------------------------
# 步骤 2：防火墙
# -----------------------------
echo "[2/14] 配置防火墙"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000 8445 8446
ufw allow from 127.0.0.1 to any port 25500  # SubConverter
ufw allow from 127.0.0.1 to any port 2095   # S-UI
ufw allow from 127.0.0.1 to any port ${SUB_WEB_API_PORT} # Sub-Web API
ufw --force enable

# -----------------------------
# 步骤 3：安装 acme.sh
# -----------------------------
echo "[3/14] 安装 acme.sh"
if [ ! -d "$HOME/.acme.sh" ]; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
else
    echo "[INFO] acme.sh 已安装"
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
mkdir -p /etc/nginx/ssl/$DOMAIN

# -----------------------------
# 步骤 4：申请 SSL 证书
# -----------------------------
echo "[4/14] 申请 SSL 证书"
if [ ! -f "/etc/nginx/ssl/$DOMAIN/fullchain.pem" ]; then
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
else
    echo "[INFO] SSL 已存在"
fi

# -----------------------------
# 步骤 5：安装证书到 Nginx
# -----------------------------
echo "[5/14] 安装证书到 Nginx"
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
    --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
    --reloadcmd "systemctl reload nginx"

# -----------------------------
# 步骤 6：安装 SubConverter
# -----------------------------
echo "[6/14] 安装 SubConverter"
mkdir -p /opt/subconverter
if [ ! -f "/opt/subconverter/subconverter" ]; then
    wget -O /opt/subconverter/subconverter $SUBCONVERTER_BIN
    chmod +x /opt/subconverter/subconverter
fi
cat > /opt/subconverter/subconverter.env <<EOF
API_MODE=true
API_HOST=0.0.0.0
API_PORT=${SUBCONVERTER_PORT}
CACHE_ENABLED=true
CACHE_SUBSCRIPTION=true
CACHE_CONFIG=true
CACHE_UPDATE_INTERVAL=600
MANAGEMENT_PASS=admin123
EOF
chmod 600 /opt/subconverter/subconverter.env

# Systemd 服务
cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter 服务
After=network.target
[Service]
Type=simple
WorkingDirectory=/opt/subconverter
ExecStart=/opt/subconverter/subconverter
Restart=always
RestartSec=3
EnvironmentFile=/opt/subconverter/subconverter.env
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

# -----------------------------
# 步骤 7：安装 Sub-Web API
# -----------------------------
echo "[7/14] 安装聚合后端"
rm -rf /opt/sub-web-api
git clone $SUB_WEB_API_REPO /opt/sub-web-api
cd /opt/sub-web-api
npm install --production || true

cat >/etc/systemd/system/sub-web-api.service <<EOF
[Unit]
Description=Sub-Web-API 聚合后端
After=network.target subconverter.service
Requires=subconverter.service
[Service]
Type=simple
User=root
WorkingDirectory=/opt/sub-web-api
ExecStart=/usr/bin/node /opt/sub-web-api/index.js
Restart=always
RestartSec=3
Environment=NODE_ENV=production
Environment=PORT=${SUB_WEB_API_PORT}
Environment=SUB_CONVERTER_URL=http://127.0.0.1:${SUBCONVERTER_PORT}
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable sub-web-api
systemctl restart sub-web-api

# -----------------------------
# 步骤 8：构建 Sub-Web 前端
# -----------------------------
echo "[8/14] 构建 Sub-Web 前端"
rm -rf /opt/sub-web-modify
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify
cat > vue.config.js <<'EOF'
module.exports = { publicPath: '/subconvert/' }
EOF
npm install
npm run build
[ -f "/opt/sub-web-modify/dist/config.template.js" ] && cp /opt/sub-web-modify/dist/config.template.js /opt/sub-web-modify/dist/config.js

# -----------------------------
# 步骤 9：安装 S-UI 面板
# -----------------------------
echo "[9/14] 安装 S-UI 面板"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
# 确保监听0.0.0.0
[ -f "/opt/s-ui/config.json" ] && sed -i 's/"address": "127.0.0.1"/"address": "0.0.0.0"/g' /opt/s-ui/config.json
systemctl restart s-ui

# -----------------------------
# 步骤 10：安装 Xray + Reality 共用 443
# -----------------------------
echo "[10/14] 安装 Xray + Reality 共用 443"
XRAY_CONFIG_DIR="/etc/xray"
mkdir -p ${XRAY_CONFIG_DIR}
XRAY_CONFIG_JSON="${XRAY_CONFIG_DIR}/config.json"

# 备份旧配置
[ -f "$XRAY_CONFIG_JSON" ] && cp "$XRAY_CONFIG_JSON" "${XRAY_CONFIG_JSON}.bak"

cat > $XRAY_CONFIG_JSON <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${REALITY_SHORT_ID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": true,
          "dest": "${REALITY_SNI}:443",
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "",
          "shortIds": ["${REALITY_SHORT_ID}"],
          "maxClientVer": 0
        },
        "fallbacks": [
          {"dest": 80},          // HTTP fallback 给 Nginx
          {"path": "/ws/", "dest": ${VLESS_PORT}}  // WS fallback
        ]
      }
    }
  ],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

# 安装 Xray
if ! command -v xray &>/dev/null; then
  bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) install
fi

systemctl enable xray
systemctl restart xray

# -----------------------------
# 步骤 11：配置 Web 主页 + Nginx fallback
# -----------------------------
echo "[11/14] 配置 Nginx"
rm -f /etc/nginx/sites-available/$DOMAIN.bak
[ -f /etc/nginx/sites-available/$DOMAIN ] && mv /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-available/$DOMAIN.bak

cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate     /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    root /opt/web-home/current;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }
    location /subconvert/api/ {
        proxy_pass http://127.0.0.1:${SUB_WEB_API_PORT}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    location /sui/ {
        proxy_pass http://127.0.0.1:2095/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t
systemctl reload nginx

# -----------------------------
# 步骤 12：配置 Web 主页仓库
# -----------------------------
echo "[12/14] 配置 Web 主页"
rm -rf /opt/web-home
mkdir -p /opt/web-home
git clone $WEB_HOME_REPO /opt/web-home/tmp
mv /opt/web-home/tmp/web /opt/web-home/current
rm -rf /opt/web-home/tmp

# -----------------------------
# 步骤 13：安装 AdGuard Home
# -----------------------------
echo "[13/14] 安装 AdGuard Home"
[ ! -d "/opt/AdGuardHome" ] && curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh

# -----------------------------
# 步骤 14：完成 & 验证
# -----------------------------
echo "[14/14] 部署完成，验证服务"
systemctl restart nginx xray s-ui sub-web-api subconverter
echo "🎉 VPS 全栈部署完成 v2.6（443 共用 Reality）"
echo "📌 S-UI 面板: https://$DOMAIN/sui/"
echo "📌 Reality VLESS: ${DOMAIN}:443 (SNI=$REALITY_SNI)"
echo "📌 Web主页: https://$DOMAIN/"
echo "📌 Sub-Web: https://$DOMAIN/subconvert/"
echo "📌 Sub-Web API: https://$DOMAIN/subconvert/api/"
echo ""
echo "⚠️ 回滚旧版本: 备份 Nginx: /etc/nginx/sites-available/$DOMAIN.bak, Xray: /etc/xray/config.json.bak"
