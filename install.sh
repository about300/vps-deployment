#!/bin/bash
# =================================================================
# VPS 全栈一键部署脚本 (Nginx + s-ui + Web + Subconverter + AdGuard Home)
# 不使用子域名，统一主域名 443 端口分流
# 适配 Ubuntu 24 minimal/stream
# =================================================================

set -e
exec 2>&1

# ==================== 颜色定义 ====================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log() { echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
error() { echo -e "${RED}[x] $1${NC}"; exit 1; }

# ==================== 输入配置 ====================
clear
echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     VPS 全栈部署脚本 - Ubuntu24    ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
echo ""

read -p "1. 请输入主域名 (例如: example.com): " MAIN_DOMAIN
read -p "2. 请输入邮箱 (用于申请SSL证书): " CERT_EMAIL

echo ""
log "配置摘要："
echo "  - 主域名: $MAIN_DOMAIN"
echo "  - 证书邮箱: $CERT_EMAIL"
echo ""
warn "脚本将彻底清理系统可能存在的旧版Nginx并安装依赖。"
read -p "按 Enter 开始部署 (Ctrl+C 取消)..."

# ==================== 阶段0：最小化系统修复 ====================
log "====== 阶段0：恢复 minimal 系统依赖 ======"
sudo unminimize || true
sudo apt update && sudo apt upgrade -y
sudo add-apt-repository universe
sudo apt update
sudo apt install -y nginx-extras unzip curl wget git socat lsof jq ufw software-properties-common

# ==================== 阶段1：Web目录创建 ====================
log "====== 阶段1：创建 Web 目录 ======"
WORK_DIR="/opt/vps-deploy"
mkdir -p $WORK_DIR/{web,sub,bin,config}
chown -R www-data:www-data $WORK_DIR
chmod -R 755 $WORK_DIR

# Web主页示例
cat > $WORK_DIR/web/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>VPS Home</title>
<style>
body{font-family:Arial;text-align:center;margin:0;padding:0;background:#f0f0f0;}
header{background:#0078d7;color:#fff;padding:10px;font-size:20px;}
a.button{display:inline-block;margin:10px;padding:10px 20px;background:#28a745;color:#fff;text-decoration:none;border-radius:5px;}
</style>
</head>
<body>
<header>Welcome to VPS</header>
<div style="margin-top:50px;">
<a class="button" href="/sub/">订阅转换</a>
</div>
</body>
</html>
EOF

# ==================== 阶段2：acme.sh 申请 SSL ====================
log "====== 阶段2：申请 SSL ======"
curl -s https://get.acme.sh | sh -s email=$CERT_EMAIL > /dev/null
source ~/.bashrc
ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh

CERT_DIR="/etc/ssl/private/${MAIN_DOMAIN}"
mkdir -p $CERT_DIR
acme.sh --issue -d "$MAIN_DOMAIN" --standalone --keylength ec-256
acme.sh --install-cert -d "$MAIN_DOMAIN" --ecc \
    --key-file $CERT_DIR/privkey.pem \
    --fullchain-file $CERT_DIR/fullchain.pem

# ==================== 阶段3：Nginx 配置 ====================
log "====== 阶段3：配置 Nginx ======"
XRAY_PORT=443
SUI_WEB_PORT=2095
SUBCONVERTER_PORT=25500
cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
events { worker_connections 768; }

stream {
    map \$ssl_preread_server_name \$backend {
        default xray_backend;  # 所有 443 流量默认走 VLESS/Reality
    }
    upstream xray_backend { server 127.0.0.1:${XRAY_PORT}; }
    server {
        listen 443 reuseport;
        listen [::]:443 reuseport;
        proxy_pass \$backend;
        ssl_preread on;
        proxy_protocol on;
        tcp_nodelay on;
    }
}

http {
    server {
        listen 127.0.0.1:5443 ssl http2;
        server_name ${MAIN_DOMAIN};
        ssl_certificate ${CERT_DIR}/fullchain.pem;
        ssl_certificate_key ${CERT_DIR}/privkey.pem;
        root $WORK_DIR/web;
        index index.html;
        location /sub/ { alias $WORK_DIR/sub/; index index.html; try_files \$uri \$uri/ /sub/index.html; }
        location /app { proxy_pass http://127.0.0.1:${SUI_WEB_PORT}/app; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; }
    }

    server {
        listen 80;
        server_name ${MAIN_DOMAIN};
        location /.well-known/acme-challenge/ { root /var/www/html; }
        location / { return 301 https://\$server_name\$request_uri; }
    }
}
EOF

nginx -t
systemctl restart nginx

# ==================== 阶段4：s-ui 面板 ====================
log "====== 阶段4：安装 s-ui 面板 ======"
SUI_TMP="/tmp/s-ui"
mkdir -p "$SUI_TMP" && cd "$SUI_TMP"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# ==================== 阶段5：Subconverter API ====================
log "====== 阶段5：部署 Subconverter API ======"
REPO_URL="https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter"
wget -q -O $WORK_DIR/bin/subconverter $REPO_URL && chmod +x $WORK_DIR/bin/subconverter
cat > $WORK_DIR/config/subconverter.pref.ini <<EOF
listen=127.0.0.1
port=${SUBCONVERTER_PORT}
api_access_token=
managed_config_prefix=https://${MAIN_DOMAIN}/sub
EOF
cd $WORK_DIR && nohup ./bin/subconverter -c config/subconverter.pref.ini >/dev/null 2>&1 &

# ==================== 阶段6：安装 AdGuard Home ====================
log "====== 阶段6：安装 AdGuard Home ======"
AGH_DIR="/opt/adguardhome"
mkdir -p $AGH_DIR && cd $AGH_DIR
wget -q https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz
tar xzf AdGuardHome_linux_amd64.tar.gz
./AdGuardHome -s install
systemctl enable AdGuardHome
systemctl start AdGuardHome

# ==================== 阶段7：配置 UFW 防火墙 ====================
log "====== 阶段7：配置 UFW 防火墙 ======"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 25500/tcp  # Subconverter
ufw allow 3000/tcp   # AdGuard Home
ufw --force enable

# ==================== 完成 ====================
clear
echo -e "${CYAN}╔════════════════════════════════╗${NC}"
echo -e "${CYAN}║         部署完成！           ║${NC}"
echo -e "${CYAN}╚════════════════════════════════╝${NC}"
echo "访问主页:      https://${MAIN_DOMAIN}"
echo "订阅转换:      https://${MAIN_DOMAIN}/sub/"
echo "s-ui 管理面板: https://${MAIN_DOMAIN}/app"
echo "AdGuard Home:   https://${MAIN_DOMAIN}:3000"
echo ""
echo -e "${YELLOW}请确保 VPS 外网安全组允许端口 22,80,443,25500,3000${NC}"
