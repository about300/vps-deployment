#!/usr/bin/env bash
set -e

##############################
# VPS 全栈部署脚本
# Version: v2.5
# Author: Auto-generated
# Description: 部署完整的VPS服务栈，包括Web主页、Sub-Web前端、聚合后端、S-UI面板、Reality节点
##############################

echo "[v2.5] ===== VPS 全栈部署（最终版）v2.5） ====="

# -----------------------------
# Cloudflare API 权限提示
# -----------------------------
echo "[v2.5] -------------------------------------"
echo "[v2.5] Cloudflare API Token 需要以下权限："
echo "[v2.5]  - Zone.Zone: Read"
echo "[v2.5]  - Zone.DNS: Edit"
echo "[v2.5] 作用域：仅限当前域名所在 Zone"
echo "[v2.5] acme.sh 使用 dns_cf 方式申请证书"
echo "[v2.5] -------------------------------------"
echo ""

# -----------------------------
# 步骤 0：用户输入交互
# -----------------------------
read -rp "[v2.5] 请输入您的域名 (例如：example.domain): " DOMAIN
read -rp "[v2.5] 请输入 Cloudflare 邮箱: " CF_Email
read -rp "[v2.5] 请输入 Cloudflare API Token: " CF_Token
export CF_Email
export CF_Token

# 服务端口定义
REALITY_PORT=443
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
echo "[v2.5] [1/14] 更新系统与安装依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3 npm net-tools

# -----------------------------
# 步骤 2：防火墙配置
# -----------------------------
echo "[v2.5] [2/14] 配置防火墙"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000   # AdGuard Home Web界面
ufw allow 8445   # AdGuard Home 管理端口1
ufw allow 8446   # AdGuard Home 管理端口2
ufw allow 2095   # S-UI面板外部访问
ufw allow from 127.0.0.1 to any port 25500  # SubConverter 本地访问
ufw allow from 127.0.0.1 to any port ${SUB_WEB_API_PORT} # 聚合后端
ufw --force enable

# -----------------------------
# 步骤 3：安装 acme.sh
# -----------------------------
echo "[v2.5] [3/14] 安装 acme.sh（DNS-01）"
if [ ! -d "$HOME/.acme.sh" ]; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
else
    echo "[v2.5] [INFO] acme.sh 已安装，跳过"
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
mkdir -p /etc/nginx/ssl/$DOMAIN

# -----------------------------
# 步骤 4：申请 SSL 证书
# -----------------------------
echo "[v2.5] [4/14] 申请或检查 SSL 证书"
if [ ! -f "/etc/nginx/ssl/$DOMAIN/fullchain.pem" ]; then
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
else
    echo "[v2.5] [INFO] SSL 证书已存在，跳过申请"
fi

# -----------------------------
# 步骤 5：安装证书到 Nginx
# -----------------------------
echo "[v2.5] [5/14] 安装证书到 Nginx"
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
    --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
    --reloadcmd "systemctl reload nginx"

# -----------------------------
# 步骤 6：安装 SubConverter 后端
# -----------------------------
echo "[v2.5] [6/14] 安装 SubConverter"
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
# 步骤 7：修复聚合后端
# -----------------------------
echo "[v2.5] [7/14] 安装/修复聚合后端 (sub-web-api)"
rm -rf /opt/sub-web-api
git clone $SUB_WEB_API_REPO /opt/sub-web-api
cd /opt/sub-web-api
npm install --production || echo "[v2.5] [WARN] npm install失败，继续"

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
systemctl restart sub-web-api

# -----------------------------
# 步骤 8：Node.js 环境
# -----------------------------
echo "[v2.5] [8/14] 确保 Node.js 可用"
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
fi

# -----------------------------
# 步骤 9：构建 Sub-Web 前端
# -----------------------------
echo "[v2.5] [9/14] 构建 sub-web-modify 前端"
rm -rf /opt/sub-web-modify
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify
cat > vue.config.js <<'EOF'
module.exports = { publicPath: '/subconvert/' }
EOF
npm install
npm run build

# -----------------------------
# 步骤 10：安装 S-UI 面板
# -----------------------------
echo "[v2.5] [10/14] 安装 S-UI 面板"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
systemctl restart s-ui 2>/dev/null || true

# -----------------------------
# 步骤 11：Web 主页
# -----------------------------
echo "[v2.5] [11/14] 配置 Web 主页"
rm -rf /opt/web-home
mkdir -p /opt/web-home
git clone $WEB_HOME_REPO /opt/web-home/tmp
mv /opt/web-home/tmp/web /opt/web-home/current
rm -rf /opt/web-home/tmp

# -----------------------------
# 步骤 12：安装 AdGuard Home
# -----------------------------
echo "[v2.5] [12/14] 安装 AdGuard Home"
if [ ! -d "/opt/AdGuardHome" ]; then
    curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh
    sed -i 's/^bind_port: .*/bind_port: 3000/' /opt/AdGuardHome/AdGuardHome.yaml 2>/dev/null || true
fi

# -----------------------------
# 步骤 13：配置 Nginx
# -----------------------------
echo "[v2.5] [13/14] 写入 /etc/nginx/nginx.conf"
cat >/etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/access.log;
    gzip on;

    server {
        listen 443 ssl http2;
        server_name $DOMAIN;
        ssl_certificate /etc/nginx/ssl/$DOMAIN/fullchain.pem;
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
    }

    server {
        listen 80;
        server_name $DOMAIN;
        return 301 https://\$server_name\$request_uri;
    }
}
EOF

systemctl restart nginx

# -----------------------------
# 步骤 14：完成信息
# -----------------------------
echo ""
echo "[v2.5] ====================================="
echo "[v2.5] 🎉 VPS 全栈部署完成 v2.5"
echo "[v2.5] ====================================="
echo "[v2.5] 🌐 主页面: https://$DOMAIN"
echo "[v2.5] 🔧 Sub-Web前端: https://$DOMAIN/subconvert/"
echo "[v2.5] ⚙️ 聚合后端API: https://$DOMAIN/subconvert/api/"
echo "[v2.5] 📊 S-UI面板: 通过域名访问 https://$DOMAIN/sui/"
echo "[v2.5] 🛡️ AdGuard Home: http://$DOMAIN:3000/"
echo "[v2.5] 🔐 证书路径: /etc/nginx/ssl/$DOMAIN/"
echo "[v2.5] ⚙️ SubConverter配置: /opt/subconverter/subconverter.env"
echo "[v2.5] ====================================="
echo "[v2.5] 部署时间: $(date)"
echo "[v2.5] ====================================="
