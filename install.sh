#!/usr/bin/env bash
set -e

##############################
# VPS 全栈部署脚本
# Version: v2.7
# Description: 纯新系统部署（Web + 订阅 + S-UI + Reality 环境）
##############################

echo ""
echo "====================================="
echo "🚀 VPS 全栈部署脚本 v2.7"
echo "====================================="
echo ""

echo "Cloudflare API Token 需要以下权限："
echo " - Zone.Zone: Read"
echo " - Zone.DNS: Edit"
echo "作用域：仅限当前域名所在 Zone"
echo "证书申请方式：acme.sh + dns_cf"
echo ""

read -rp "请输入你的域名 (例如: example.com): " DOMAIN
read -rp "请输入 Cloudflare 邮箱: " CF_Email
read -rp "请输入 Cloudflare API Token: " CF_Token

echo ""
read -rp "请输入 VLESS 固定端口（例如 50021）: " VLESS_PORT

export CF_Email
export CF_Token

SUB_WEB_API_PORT=3001

WEB_REPO="https://github.com/about300/vps-deployment.git"
SUB_WEB_API_REPO="https://github.com/about300/sub-web-api.git"
SUBCONVERTER_BIN="https://github.com/about300/vps-deployment/raw/refs/heads/main/bin/subconverter"

echo ""
echo "[1/15] 更新系统与基础依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx \
               build-essential python3 python-is-python3 \
               npm net-tools

echo ""
echo "[2/15] 防火墙配置"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow 22
ufw allow 80
ufw allow 443

# AdGuard Home
ufw allow 3000
ufw allow 8445
ufw allow 8446

# S-UI 面板
ufw allow 2095

# VLESS 固定端口
ufw allow ${VLESS_PORT}

# 本地服务
ufw allow from 127.0.0.1 to any port ${SUB_WEB_API_PORT}

ufw --force enable

echo ""
echo "[3/15] 安装 acme.sh 并申请证书"
curl https://get.acme.sh | sh
source ~/.bashrc

mkdir -p /etc/nginx/ssl/${DOMAIN}

~/.acme.sh/acme.sh \
  --issue \
  --dns dns_cf \
  -d ${DOMAIN} \
  --key-file       /etc/nginx/ssl/${DOMAIN}/key.pem \
  --fullchain-file /etc/nginx/ssl/${DOMAIN}/fullchain.pem \
  --reloadcmd "systemctl reload nginx"

echo ""
echo "[4/15] 部署 Web 前端"
rm -rf /var/www/web
git clone ${WEB_REPO} /var/www/web

echo ""
echo "[5/15] 部署 Sub-Web-API（聚合后端）"
rm -rf /opt/sub-web-api
git clone ${SUB_WEB_API_REPO} /opt/sub-web-api
cd /opt/sub-web-api
npm install

cat > /etc/systemd/system/sub-web-api.service <<EOF
[Unit]
Description=Sub Web API
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/sub-web-api
ExecStart=/usr/bin/npm start
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sub-web-api
systemctl start sub-web-api

echo ""
echo "[6/15] 安装 SubConverter"
mkdir -p /opt/subconverter
wget -O /opt/subconverter/subconverter ${SUBCONVERTER_BIN}
chmod +x /opt/subconverter/subconverter

cat > /opt/subconverter/subconverter.env <<EOF
API_ACCESS_TOKEN=admin123
EOF

cat > /etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter Service
After=network.target

[Service]
Type=simple
ExecStart=/opt/subconverter/subconverter
WorkingDirectory=/opt/subconverter
Restart=always
EnvironmentFile=/opt/subconverter/subconverter.env

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconverter
systemctl start subconverter

echo ""
echo "[7/15] 安装 S-UI 面板"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/main/install.sh)

echo ""
echo "[8/15] Nginx 主配置（无 VLESS / WS / 反代）"
cat > /etc/nginx/sites-available/${DOMAIN}.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     /etc/nginx/ssl/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${DOMAIN}/key.pem;

    root /var/www/web/web;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /subconvert/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location /subconvert/api/ {
        proxy_pass http://127.0.0.1:${SUB_WEB_API_PORT}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/${DOMAIN}.conf /etc/nginx/sites-enabled/${DOMAIN}.conf

nginx -t
systemctl reload nginx

echo ""
echo "[9/15] 基础校验完成"

echo ""
echo "====================================="
echo "🎉 VPS 全栈部署完成 v2.7"
echo "====================================="
echo ""
echo "🌐 主页面:              https://${DOMAIN}"
echo "🔧 Sub-Web前端:         https://${DOMAIN}/subconvert/"
echo "⚙️  聚合后端API:         https://${DOMAIN}/subconvert/api/"
echo ""
echo "📊 S-UI 面板:"
echo "  - 地址: https://${DOMAIN}:2095"
echo "  - 默认账号: admin / admin（请立即修改）"
echo ""
echo "📡 VLESS:"
echo "  - 固定端口: ${VLESS_PORT}"
echo "  - 不反代 / 不 TLS / 不 WS"
echo ""
echo "📡 Reality:"
echo "  - 端口: 443"
echo "  - 在 S-UI 面板中自行创建"
echo "  - 不使用 nginx 证书（这是正常的）"
echo ""
echo "🛡️ AdGuard Home:"
echo "  - http://${DOMAIN}:3000"
echo "  - https://${DOMAIN}:8445"
echo "  - http://${DOMAIN}:8446"
echo ""
echo "🔐 证书路径:"
echo "  /etc/nginx/ssl/${DOMAIN}/fullchain.pem"
echo "  /etc/nginx/ssl/${DOMAIN}/key.pem"
echo ""
echo "⚠️ 提醒:"
echo "  1. 修改所有默认密码"
echo "  2. Reality 私钥/公钥必须使用 S-UI 自动生成"
echo "  3. nginx 未承载任何代理流量"
echo ""
echo "脚本版本: v2.7"
echo "部署时间: $(date)"
echo "====================================="
