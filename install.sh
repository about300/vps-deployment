#!/usr/bin/env bash
set -e

##############################
# VPS 全栈部署脚本
# Version: v2.8
# Author: Auto-generated
# Description: 全新系统安装版，保留 2.4 功能，支持 Sub-Web、S-UI、AdGuard、SubConverter
##############################

echo "===== VPS 全栈部署（最终版）v2.8 ====="

# -----------------------------
# Cloudflare API 权限提示
# -----------------------------
echo "-------------------------------------"
echo "Cloudflare API Token 需要以下权限："
echo " - Zone.Zone: Read"
echo " - Zone.DNS: Edit"
echo "作用域：仅限当前域名所在 Zone"
echo "acme.sh 使用 dns_cf 方式申请证书"
echo "-------------------------------------"
echo ""

# -----------------------------
# 步骤 0：用户输入交互
# -----------------------------
read -rp "请输入您的域名 (例如：example.domain): " DOMAIN
read -rp "请输入 Cloudflare 邮箱: " CF_Email
read -rp "请输入 Cloudflare API Token: " CF_Token
export CF_Email
export CF_Token

read -rp "请输入 VLESS 端口 (建议 443 以上): " VLESS_PORT

# 服务端口定义
SUB_WEB_API_PORT=3001 # 聚合后端端口

# SubConverter 二进制下载链接
SUBCONVERTER_BIN="https://github.com/about300/vps-deployment/raw/refs/heads/main/bin/subconverter"

# Web主页GitHub仓库
WEB_HOME_REPO="https://github.com/about300/vps-deployment.git"
# 聚合后端仓库
SUB_WEB_API_REPO="https://github.com/about300/sub-web-api.git"

# -----------------------------
# 步骤 1：更新系统与依赖
# -----------------------------
echo "[1/12] 更新系统与安装依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3 npm net-tools

# -----------------------------
# 步骤 2：防火墙配置
# -----------------------------
echo "[2/12] 配置防火墙"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22
ufw allow 80
ufw allow 443

# 开放额外端口
ufw allow 3000
ufw allow 8445
ufw allow 8446
ufw allow "$VLESS_PORT"

# 本地访问端口
ufw allow from 127.0.0.1 to any port 25500
ufw allow from 127.0.0.1 to any port 2095
ufw allow from 127.0.0.1 to any port "$VLESS_PORT"
ufw allow from 127.0.0.1 to any port ${SUB_WEB_API_PORT}

ufw --force enable

echo "[INFO] 防火墙配置完成"

# -----------------------------
# 步骤 3：安装 acme.sh
# -----------------------------
echo "[3/12] 安装 acme.sh"
if [ ! -d "$HOME/.acme.sh" ]; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
else
    echo "[INFO] acme.sh 已安装，跳过"
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
mkdir -p /etc/nginx/ssl/$DOMAIN

# -----------------------------
# 步骤 4：安装 SubConverter
# -----------------------------
echo "[4/12] 安装 SubConverter"
mkdir -p /opt/subconverter
if [ ! -f "/opt/subconverter/subconverter" ]; then
    wget -O /opt/subconverter/subconverter $SUBCONVERTER_BIN
    chmod +x /opt/subconverter/subconverter
fi

cat > /opt/subconverter/subconverter.env <<EOF
API_MODE=true
API_HOST=0.0.0.0
API_PORT=25500
CACHE_ENABLED=true
CACHE_SUBSCRIPTION=true
CACHE_CONFIG=true
CACHE_UPDATE_INTERVAL=600
MANAGEMENT_PASS=admin123
EOF

chmod 600 /opt/subconverter/subconverter.env

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
# 步骤 5：安装 聚合后端 sub-web-api
# -----------------------------
echo "[5/12] 安装聚合后端 sub-web-api"
rm -rf /opt/sub-web-api
git clone $SUB_WEB_API_REPO /opt/sub-web-api
cd /opt/sub-web-api
npm install --production

cat >/etc/systemd/system/sub-web-api.service <<EOF
[Unit]
Description=Sub-Web-API 聚合后端服务
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
Environment=SUB_CONVERTER_URL=http://127.0.0.1:25500

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sub-web-api
systemctl start sub-web-api

# -----------------------------
# 步骤 6：Node.js
# -----------------------------
echo "[6/12] 确保 Node.js 可用"
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
fi

# -----------------------------
# 步骤 7：构建 sub-web-modify 前端
# -----------------------------
echo "[7/12] 构建 sub-web-modify 前端"
rm -rf /opt/sub-web-modify
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify
cat > vue.config.js <<'EOF'
module.exports = { publicPath: '/subconvert/' }
EOF
npm install
npm run build

# -----------------------------
# 步骤 8：安装 S-UI 面板
# -----------------------------
echo "[8/12] 安装 S-UI 面板"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
if [ -f "/opt/s-ui/config.json" ]; then
    sed -i 's/"address": "127.0.0.1"/"address": "0.0.0.0"/g' /opt/s-ui/config.json
fi
systemctl restart s-ui 2>/dev/null || true

# -----------------------------
# 步骤 9：Web 主页
# -----------------------------
echo "[9/12] 配置 Web 主页"
rm -rf /opt/web-home
mkdir -p /opt/web-home
git clone $WEB_HOME_REPO /opt/web-home/tmp
mv /opt/web-home/tmp/web /opt/web-home/current
rm -rf /opt/web-home/tmp

# -----------------------------
# 步骤 10：安装 AdGuard Home
# -----------------------------
echo "[10/12] 安装 AdGuard Home"
if [ ! -d "/opt/AdGuardHome" ]; then
    curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh
    sed -i 's/^bind_port: .*/bind_port: 3000/' /opt/AdGuardHome/AdGuardHome.yaml 2>/dev/null || true
fi

# -----------------------------
# 步骤 11：配置 Nginx
# -----------------------------
echo "[11/12] 配置 Nginx"
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
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
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_buffering off;
        add_header Access-Control-Allow-Origin *;
    }

    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location /sui/ {
        proxy_pass http://127.0.0.1:2095/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        rewrite ^/sui$ /sui/ permanent;
        rewrite ^/sui/(.*)$ /app/\$1 break;
        proxy_redirect http://127.0.0.1:2095/ https://\$host/sui/;
    }
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t
systemctl reload nginx

# -----------------------------
# 步骤 12：部署验证函数
# -----------------------------
echo "[12/12] 部署验证与状态检查"

check_service() {
    local name=$1
    local port=$2
    if nc -zv 127.0.0.1 "$port" &>/dev/null; then
        echo -e "✅ 服务 $name 端口 $port 可用"
    else
        echo -e "❌ 服务 $name 端口 $port 不可用，请检查"
    fi
}

echo "====================================="
echo "🚀 检查各项服务状态..."
check_service "SubConverter API" 25500
check_service "Sub-Web API" ${SUB_WEB_API_PORT}
check_service "S-UI 面板" 2095
check_service "Nginx HTTPS" 443
check_service "AdGuard Home Web" 3000
check_service "AdGuard 管理端口1" 8445
check_service "AdGuard 管理端口2" 8446
check_service "VLESS" "$VLESS_PORT"
echo "====================================="

echo "🎉 全部服务已启动完成"
echo "📋 访问示例:"
echo " - Sub-Web 前端: https://$DOMAIN/subconvert/"
echo " - 聚合后端 API: https://$DOMAIN/subconvert/api/"
echo " - 原始 SubConverter API: https://$DOMAIN/sub/api/"
echo " - S-UI 面板: https://$DOMAIN/sui/ (默认 admin/admin)"
echo " - AdGuard Home Web: http://$DOMAIN:3000/"
echo " - AdGuard 管理端口1: https://$DOMAIN:8445/"
echo " - AdGuard 管理端口2: http://$DOMAIN:8446/"
echo " - VLESS 端口: $VLESS_PORT (已放行)"
echo "====================================="
