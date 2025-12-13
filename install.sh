#!/bin/bash
set -e
exec 2>&1

# 颜色定义
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log() { echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
info() { echo -e "${BLUE}[i] $1${NC}"; }
error() { echo -e "${RED}[x] $1${NC}"; exit 1; }

clear
echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     VPS 全栈部署脚本 - Ubuntu24    ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
echo ""

# ==================== 用户输入变量 ====================
read -p "请输入主域名 (例: example.com): " MAIN_DOMAIN
read -p "请输入邮箱 (用于申请证书): " CERT_EMAIL

# ==================== 第一阶段：系统基础 ====================
log "====== 阶段1：系统更新与依赖安装 ======"
apt update && apt upgrade -y
apt install -y curl wget git unzip socat lsof cron ufw nginx-extras

# 配置 ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 8445/tcp
ufw --force enable

# ==================== 第二阶段：Web目录 ====================
log "====== 阶段2：部署 Web 目录 ======"
WORK_DIR="/opt/vps-deploy"
mkdir -p $WORK_DIR
rm -rf $WORK_DIR/*

git clone https://github.com/about300/vps-deployment.git /tmp/vps-deploy-temp
cp -r /tmp/vps-deploy-temp/web/* $WORK_DIR/

# ==================== 第三阶段：Subconverter ====================
log "====== 阶段3：部署 Subconverter API ======"
mkdir -p $WORK_DIR/bin $WORK_DIR/config
wget -q -O $WORK_DIR/bin/subconverter https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
chmod +x $WORK_DIR/bin/subconverter

cat > $WORK_DIR/config/subconverter.pref.ini <<EOF
listen=127.0.0.1
port=25500
api_access_token=
managed_config_prefix=https://${MAIN_DOMAIN}/sub
EOF

cd $WORK_DIR && nohup ./bin/subconverter -c config/subconverter.pref.ini >/dev/null 2>&1 &

# ==================== 第四阶段：s-ui 面板 ====================
log "====== 阶段4：部署 s-ui 面板 ======"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# ==================== 第五阶段：申请 SSL 证书 ====================
log "====== 阶段5：申请 SSL ======"
CERT_DIR="/root/certs/$MAIN_DOMAIN"
mkdir -p $CERT_DIR

curl -s https://get.acme.sh | sh
source ~/.bashrc

systemctl stop nginx || true
lsof -ti:80 | xargs kill -9 || true

/root/.acme.sh/acme.sh --issue -d "$MAIN_DOMAIN" --standalone --keylength ec-256
/root/.acme.sh/acme.sh --install-cert -d "$MAIN_DOMAIN" \
    --key-file $CERT_DIR/privkey.key \
    --fullchain-file $CERT_DIR/fullchain.crt \
    --reloadcmd "systemctl restart nginx && systemctl restart AdGuardHome"

# ==================== 第六阶段：配置 nginx ====================
log "====== 阶段6：配置 nginx ======"
cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name $MAIN_DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name $MAIN_DOMAIN;

    ssl_certificate $CERT_DIR/fullchain.crt;
    ssl_certificate_key $CERT_DIR/privkey.key;

    root $WORK_DIR;
    index index.html;

    location /sub/ { proxy_pass http://127.0.0.1:25500/; }
    location /app { proxy_pass http://127.0.0.1:2095/app; }
}
EOF

nginx -t
systemctl enable nginx
systemctl restart nginx

clear
echo -e "${CYAN}╔════════════════════════════════╗${NC}"
echo -e "${CYAN}║      部署完成! 访问信息       ║${NC}"
echo -e "${CYAN}╚════════════════════════════════╝${NC}"
echo "Web主页:      https://$MAIN_DOMAIN"
echo "订阅转换:      https://$MAIN_DOMAIN/sub/"
echo "s-ui 管理面板: https://$MAIN_DOMAIN/app"
echo ""
echo -e "${YELLOW}请确保防火墙已开放 22, 80, 443, 8445 端口${NC}"
