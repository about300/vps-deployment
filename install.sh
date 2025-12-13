#!/bin/bash
# =================================================================
# VPS 全栈一键部署脚本 (Web + s-ui 面板 + Subconverter + UFW)
# 适配 Ubuntu 24.0
# 执行: bash install.sh
# =================================================================

set -e
exec 2>&1

# 颜色定义
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log() { echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
error() { echo -e "${RED}[x] $1${NC}"; exit 1; }

# ==================== 配置 ====================
clear
echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     VPS 全栈部署脚本 - Ubuntu24    ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
echo ""

read -p "1. 请输入主域名 (例如: example.com): " MAIN_DOMAIN
read -p "2. 请输入邮箱 (用于申请SSL证书): " CERT_EMAIL

log "配置摘要："
echo "  - 主域名: $MAIN_DOMAIN"
echo "  - 证书邮箱: $CERT_EMAIL"

read -p "按 Enter 开始部署 (Ctrl+C 取消)..."

# ==================== 阶段1：安装依赖 ====================
log "====== 阶段1：安装依赖 ======"
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y
apt install -y nginx-extras unzip curl wget git socat lsof ufw cron

# ==================== 阶段2：部署 Web 目录 ====================
log "====== 阶段2：部署 Web 目录 ======"
WORK_DIR="/opt/vps-deploy"
WEB_DIR="$WORK_DIR/web"
SUB_DIR="$WEB_DIR/sub"
mkdir -p $WEB_DIR $SUB_DIR

# 拉取你的仓库 Web 内容到临时目录，然后复制到工作目录
TMP_DIR=$(mktemp -d)
log "下载 Web 前端内容..."
git clone --depth=1 https://github.com/about300/vps-deployment.git $TMP_DIR
cp -r $TMP_DIR/web/* $WEB_DIR/
cp -r $TMP_DIR/web/sub/* $SUB_DIR/
rm -rf $TMP_DIR

# ==================== 阶段3：申请 SSL 证书 ====================
log "====== 阶段3：申请 SSL ======"
CERT_DIR="/root/certs/$MAIN_DOMAIN"
mkdir -p $CERT_DIR
curl -s https://get.acme.sh | sh -s email=$CERT_EMAIL
source ~/.bashrc
/root/.acme.sh/acme.sh --issue -d $MAIN_DOMAIN --standalone --keylength ec-256
/root/.acme.sh/acme.sh --install-cert -d $MAIN_DOMAIN --ecc \
    --key-file $CERT_DIR/privkey.key \
    --fullchain-file $CERT_DIR/fullchain.crt

# ==================== 阶段4：部署 s-ui 面板 ====================
log "====== 阶段4：安装 s-ui 面板 ======"
SUI_TMP="/tmp/s-ui"
mkdir -p $SUI_TMP && cd $SUI_TMP
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# ==================== 阶段5：部署 Subconverter API ======
log "====== 阶段5：部署 Subconverter API ======"
SUB_BIN="$WORK_DIR/bin/subconverter"
wget -q -O $SUB_BIN https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter && chmod +x $SUB_BIN
cat > $WORK_DIR/config/subconverter.pref.ini <<EOF
listen=127.0.0.1
port=25500
api_access_token=
managed_config_prefix=https://$MAIN_DOMAIN/sub
EOF
cd $WORK_DIR && nohup ./bin/subconverter -c config/subconverter.pref.ini >/dev/null 2>&1 &
log "Subconverter API 已启动在端口 25500"

# ==================== 阶段6：Nginx 配置 ====================
log "====== 阶段6：配置 Nginx ======"
XRAY_PORT=443
cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
events { worker_connections 768; }
http {
    server {
        listen 443 ssl http2;
        server_name $MAIN_DOMAIN;
        ssl_certificate $CERT_DIR/fullchain.crt;
        ssl_certificate_key $CERT_DIR/privkey.key;
        root $WEB_DIR;
        index index.html;
        location /app { proxy_pass http://127.0.0.1:2095/app; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; }
        location /sub/ { proxy_pass http://127.0.0.1:25500/; proxy_set_header Host \$host; }
    }
    server {
        listen 80;
        server_name $MAIN_DOMAIN;
        location /.well-known/acme-challenge/ { root /var/www/html; }
        location / { return 301 https://\$server_name\$request_uri; }
    }
}
EOF

nginx -t && systemctl restart nginx

# ==================== 阶段7：配置 UFW 防火墙 ====================
log "====== 阶段7：配置防火墙 ======"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 8445
ufw --force enable

# ==================== 完成 ====================
clear
echo -e "${CYAN}╔════════════════════════════════╗${NC}"
echo -e "${CYAN}║      部署完成!访问信息        ║${NC}"
echo -e "${CYAN}╚════════════════════════════════╝${NC}"
echo "Web主页: https://$MAIN_DOMAIN"
echo "s-ui面板: https://$MAIN_DOMAIN/app"
echo "Subconverter API: 127.0.0.1:25500"
echo "UFW 已启用并开放 22, 80, 443, 8445 端口"
