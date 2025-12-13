#!/bin/bash
set -e
exec 2>&1

# ======== 颜色定义 ========
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log() { echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
info() { echo -e "${BLUE}[i] $1${NC}"; }
error() { echo -e "${RED}[x] $1${NC}"; exit 1; }

# ======== 用户输入 ========
read -p "请输入主域名 (例如: example.com): " MAIN_DOMAIN
read -p "请输入邮箱 (用于Let\'s Encrypt通知): " CERT_EMAIL

log "配置摘要："
echo "  - 主域名: $MAIN_DOMAIN"
echo "  - 邮箱: $CERT_EMAIL"
read -p "按 Enter 开始部署 (Ctrl+C 取消)..."

# ======== 阶段1：基础环境 ========
log "====== 阶段1：安装基础环境 ======"
apt update && apt upgrade -y
apt install -y nginx-extras unzip curl wget git socat lsof cron ufw

# 启用UFW并允许端口
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 8445/tcp
ufw --force enable

# ======== 阶段2：部署 Web 目录 ========
log "====== 阶段2：部署 Web 目录 ======"
WEB_DIR="/opt/vps-deploy/web"
mkdir -p $WEB_DIR
rm -rf /tmp/web_temp
git clone https://github.com/about300/vps-deployment.git /tmp/web_temp
cp -r /tmp/web_temp/web/* $WEB_DIR/
log "Web目录已部署到 $WEB_DIR"

# ======== 阶段3：部署 Subconverter API ========
log "====== 阶段3：部署 Subconverter API ======"
BIN_DIR="/opt/vps-deploy/bin"
CONFIG_DIR="/opt/vps-deploy/config"
mkdir -p $BIN_DIR $CONFIG_DIR
wget -q -O $BIN_DIR/subconverter https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
chmod +x $BIN_DIR/subconverter
cat > $CONFIG_DIR/subconverter.pref.ini <<EOF
listen=127.0.0.1
port=25500
api_access_token=
managed_config_prefix=https://$MAIN_DOMAIN/sub
EOF
nohup $BIN_DIR/subconverter -c $CONFIG_DIR/subconverter.pref.ini >/dev/null 2>&1 &
log "Subconverter API 启动在端口 25500"

# ======== 阶段4：部署 s-ui 面板 ========
log "====== 阶段4：部署 s-ui 面板 ======"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
log "s-ui 面板已安装，默认端口 2095"

# ======== 阶段5：申请 Let\'s Encrypt 证书 ========
log "====== 阶段5：申请 Let\'s Encrypt 证书 ======"
CERT_DIR="/root/cert"
mkdir -p $CERT_DIR
curl -s https://get.acme.sh | sh
source ~/.bashrc
/root/.acme.sh/acme.sh --issue -d "$MAIN_DOMAIN" --standalone --force --keylength ec-256 --server letsencrypt
/root/.acme.sh/acme.sh --install-cert -d "$MAIN_DOMAIN" \
    --key-file $CERT_DIR/privkey.key \
    --fullchain-file $CERT_DIR/fullchain.crt \
    --reloadcmd "systemctl restart nginx"

# ======== 阶段6：配置 Nginx ========
log "====== 阶段6：配置 Nginx ======"
cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name $MAIN_DOMAIN;
    root $WEB_DIR;
    index index.html;
    location /sub/ { proxy_pass http://127.0.0.1:25500/; }
    location /app/ { proxy_pass http://127.0.0.1:2095/app/; }
    location /.well-known/acme-challenge/ { root /var/www/html; }
}

server {
    listen 443 ssl http2;
    server_name $MAIN_DOMAIN;
    ssl_certificate $CERT_DIR/fullchain.crt;
    ssl_certificate_key $CERT_DIR/privkey.key;
    root $WEB_DIR;
    index index.html;
    location /sub/ { proxy_pass http://127.0.0.1:25500/; }
    location /app/ { proxy_pass http://127.0.0.1:2095/app/; }
}
EOF

nginx -t && systemctl restart nginx

# ======== 阶段7：安装 AdGuardHome ========
log "====== 阶段7：安装 AdGuardHome ======"
AGH_DIR="/opt/AdGuardHome"
mkdir -p $AGH_DIR && cd $AGH_DIR
wget -q https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz
tar xzf AdGuardHome_linux_amd64.tar.gz
./AdGuardHome -s install
log "AdGuardHome 已安装"

# ======== 完成 ========
clear
echo -e "${CYAN}╔════════════════════════════════╗${NC}"
echo -e "${CYAN}║         部署完成！           ║${NC}"
echo -e "${CYAN}╚════════════════════════════════╝${NC}"
echo "访问主页:      https://$MAIN_DOMAIN"
echo "订阅转换:      https://$MAIN_DOMAIN/sub/"
echo "s-ui 管理面板: https://$MAIN_DOMAIN/app"
echo "AdGuardHome 登录: https://$MAIN_DOMAIN:3000"
echo -e "${YELLOW}请确保防火墙已开放 22/80/443/8445 端口${NC}"
