#!/bin/bash
# =================================================================
# VPS 全栈一键部署脚本
# Webroot + Web前端 + s-ui面板 + Subconverter + AdGuardHome
# 适配 Ubuntu 24.0
# =================================================================

set -e
exec 2>&1

# ------------------- 颜色定义 -------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}"; }
warn()  { echo -e "${YELLOW}[!] $1${NC}"; }
info()  { echo -e "${BLUE}[i] $1${NC}"; }
error() { echo -e "${RED}[x] $1${NC}"; exit 1; }

# ------------------- 用户输入 -------------------
clear
echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     VPS 全栈部署脚本 - Ubuntu24    ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
echo ""

read -p "请输入主域名 (例如: example.com): " MAIN_DOMAIN
read -p "请输入邮箱 (用于申请SSL证书): " CERT_EMAIL

log "配置摘要："
echo "  - 主域名: $MAIN_DOMAIN"
echo "  - 证书邮箱: $CERT_EMAIL"
echo ""
warn "脚本将清理系统中可能存在的旧版 Nginx 并安装必要组件"
read -p "按 Enter 开始部署 (Ctrl+C 取消)..."

# ------------------- 阶段1：基础环境 -------------------
log "====== 阶段1：安装基础环境 ======"
apt update && apt upgrade -y
apt install -y curl wget git socat cron jq lsof unzip ufw nginx-extras

# ------------------- 阶段2：安装 s-ui 面板 (官方) -------------------
log "====== 阶段2：安装 s-ui 面板 ======"
bash <(curl -Ls https://github.com/alireza0/s-ui/master/install.sh)
SUI_WEB_PORT=2095
log "s-ui 默认端口: ${SUI_WEB_PORT}"

# ------------------- 阶段3：部署 Web前端 + Subconverter -------------------
log "====== 阶段3：部署 Web前端 + Subconverter ======"
WORK_DIR="/opt/vps-deploy"
mkdir -p $WORK_DIR/web $WORK_DIR/bin $WORK_DIR/config

log "复制 Web主页..."
rm -rf $WORK_DIR/web/*
git clone https://github.com/about300/vps-deployment.git /tmp/tmp_web
cp -r /tmp/tmp_web/web/* $WORK_DIR/web/
rm -rf /tmp/tmp_web

log "部署 Subconverter..."
wget -q -O $WORK_DIR/bin/subconverter https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
chmod +x $WORK_DIR/bin/subconverter

cat > $WORK_DIR/config/subconverter.pref.ini <<EOF
listen=127.0.0.1
port=25500
api_access_token=
managed_config_prefix=https://${MAIN_DOMAIN}/sub
EOF

cd $WORK_DIR && nohup ./bin/subconverter -c config/subconverter.pref.ini >/dev/null 2>&1 &
log "Subconverter 启动在端口 25500"

# ------------------- 阶段4：配置防火墙 -------------------
log "====== 阶段4：配置防火墙 ======"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 8445
ufw --force enable

# ------------------- 阶段5：申请 Let’s Encrypt 证书 (Webroot) -------------------
CERT_DIR="/root/cert"
mkdir -p $CERT_DIR

log "====== 阶段5：申请 Let’s Encrypt 证书 ======"
curl https://get.acme.sh | sh -s email=$CERT_EMAIL
source ~/.bashrc
/root/.acme.sh/acme.sh --issue -d "$MAIN_DOMAIN" --webroot $WORK_DIR/web --keylength ec-256
/root/.acme.sh/acme.sh --install-cert -d "$MAIN_DOMAIN" \
    --fullchain-file $CERT_DIR/fullchain.crt \
    --key-file $CERT_DIR/privkey.key \
    --ecc

# ------------------- 阶段6：配置 Nginx -------------------
log "====== 阶段6：配置 Nginx ======"
cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
events { worker_connections 768; }

http {
    server {
        listen 80;
        server_name $MAIN_DOMAIN;
        root $WORK_DIR/web;
        location /.well-known/acme-challenge/ { allow all; }
        location / { return 301 https://\$host\$request_uri; }
    }
    server {
        listen 443 ssl http2;
        server_name $MAIN_DOMAIN;
        ssl_certificate $CERT_DIR/fullchain.crt;
        ssl_certificate_key $CERT_DIR/privkey.key;
        root $WORK_DIR/web;
        index index.html;
        location /app { proxy_pass http://127.0.0.1:${SUI_WEB_PORT}/app; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; }
        location /sub/ { proxy_pass http://127.0.0.1:25500/; proxy_set_header Host \$host; }
    }
}
EOF

nginx -t
systemctl enable nginx
systemctl restart nginx

# ------------------- 部署完成 -------------------
clear
echo -e "${CYAN}╔════════════════════════════════╗${NC}"
echo -e "${CYAN}║      部署完成!访问信息        ║${NC}"
echo -e "${CYAN}╚════════════════════════════════╝${NC}"
echo "Web主页: https://$MAIN_DOMAIN"
echo "s-ui面板: https://$MAIN_DOMAIN/app"
echo "Subconverter API: 127.0.0.1:25500"
echo ""
echo -e "${YELLOW}防火墙已开启，仅开放 22/80/443/8445 端口${NC}"
