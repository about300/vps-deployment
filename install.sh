#!/bin/bash
# =================================================================
# VPS 全栈一键部署脚本 (Web + Subconverter + s-ui + AdGuardHome + UFW)
# 适配 Ubuntu 24.0 Stream
# =================================================================

set -e
exec 2>&1

# ==================== 颜色定义 ====================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log() { echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
info() { echo -e "${BLUE}[i] $1${NC}"; }
error() { echo -e "${RED}[x] $1${NC}"; exit 1; }

# ==================== 用户输入 ====================
read -p "请输入主域名（例如: example.com）: " MAIN_DOMAIN
read -p "请输入邮箱（用于申请 SSL）: " CERT_EMAIL

# ==================== 阶段1：基础环境 ====================
log "====== 阶段1：安装基础软件 ======"
apt update -y && apt upgrade -y
apt install -y nginx-extras unzip curl wget git socat lsof ufw cron jq

# ==================== 阶段2：Web目录部署 ====================
WORK_DIR="/opt/vps-deploy"
log "====== 阶段2：部署 Web 前端 ======"
rm -rf "$WORK_DIR"
mkdir -p $WORK_DIR

# 从你的仓库拉取 web 文件（包含 index.html, css, js, img, sub）
git clone https://github.com/about300/vps-deployment.git "$WORK_DIR"

log "Web 前端部署完成: $WORK_DIR/web"

# ==================== 阶段3：s-ui 面板安装（官方） ====================
log "====== 阶段3：安装 s-ui 面板 ======"
bash <(curl -Ls https://github.com/alireza0/s-ui/master/install.sh)
log "s-ui 面板已安装，默认端口 2095"

# ==================== 阶段4：申请 SSL 证书 ====================
CERT_DIR="/root/cert"
mkdir -p "$CERT_DIR"
log "====== 阶段4：申请 Let’s Encrypt SSL 证书 ======"
curl https://get.acme.sh | sh
source ~/.bashrc

# 停止 nginx 避免 80 端口冲突
systemctl stop nginx 2>/dev/null || true
lsof -ti:80 | xargs kill -9 2>/dev/null || true

/root/.acme.sh/acme.sh --issue -d $MAIN_DOMAIN --standalone -m $CERT_EMAIL --force
/root/.acme.sh/acme.sh --install-cert -d $MAIN_DOMAIN \
    --key-file   $CERT_DIR/privkey.key \
    --fullchain-file $CERT_DIR/fullchain.crt \
    --reloadcmd "systemctl reload nginx"

log "SSL 证书已安装到 $CERT_DIR"

# ==================== 阶段5：Subconverter API ====================
SC_BIN="$WORK_DIR/bin/subconverter"
SC_CONF="$WORK_DIR/config/subconverter.pref.ini"
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/config"

# 拉取 Subconverter 二进制
wget -q -O $SC_BIN https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
chmod +x $SC_BIN

cat > $SC_CONF <<EOF
listen=127.0.0.1
port=25500
api_access_token=
managed_config_prefix=https://$MAIN_DOMAIN/sub
EOF

# 启动 Subconverter
cd $WORK_DIR && nohup ./bin/subconverter -c config/subconverter.pref.ini >/dev/null 2>&1 &
log "Subconverter API 启动在端口 25500"

# ==================== 阶段6：Nginx 配置 ====================
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
        location /.well-known/acme-challenge/ { root /root/cert; }
        location / { return 301 https://\$host\$request_uri; }
    }

    server {
        listen 443 ssl http2;
        server_name $MAIN_DOMAIN;
        ssl_certificate $CERT_DIR/fullchain.crt;
        ssl_certificate_key $CERT_DIR/privkey.key;
        root $WORK_DIR/web;
        index index.html;

        location /app { proxy_pass http://127.0.0.1:2095/app; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; }
        location /sub/ { proxy_pass http://127.0.0.1:25500/; proxy_set_header Host \$host; }
    }
}
EOF

nginx -t
systemctl enable nginx
systemctl restart nginx
log "Nginx 已启动并加载 Web / s-ui / Subconverter"

# ==================== 阶段7：UFW 防火墙 ====================
log "====== 阶段7：配置 UFW 防火墙 ======"
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
echo -e "${CYAN}║         部署完成！           ║${NC}"
echo -e "${CYAN}╚════════════════════════════════╝${NC}"
echo "Web主页:      https://$MAIN_DOMAIN"
echo "订阅转换:      https://$MAIN_DOMAIN/sub/"
echo "s-ui 管理面板: https://$MAIN_DOMAIN/app"
echo "证书路径:      $CERT_DIR"
echo ""
echo -e "${YELLOW}已开启防火墙，允许端口: 22, 80, 443, 8445${NC}"
