#!/bin/bash
# =================================================================
# VPS 全栈一键部署脚本
# 主页 + Subconverter静态前端 + s-ui + SSL + Nginx stream
# 适配 Ubuntu 24.0
# =================================================================

set -e
exec 2>&1

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033m'
log() { echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
error() { echo -e "${RED}[x] $1${NC}"; exit 1; }

clear
echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║      VPS 全栈部署脚本 - Ubuntu24      ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
echo ""

read -p "请输入主域名 (例如 example.com): " MAIN_DOMAIN
read -p "请输入邮箱 (用于申请SSL证书): " CERT_EMAIL

echo ""
log "配置摘要："
echo "  主域名: $MAIN_DOMAIN"
echo "  SSL 邮箱: $CERT_EMAIL"
echo ""
warn "请确保 DNS 已解析到本机，80/443 端口未被占用。"
read -p "按 Enter 开始部署 (Ctrl+C 取消)..."

# ==================== 第一阶段：基础环境 ====================
log "====== 阶段1：安装基础环境 ======"
apt update && apt upgrade -y
apt install -y curl wget git socat cron jq lsof nginx-extras unzip

# 检查 nginx 是否带 stream 模块
if ! nginx -V 2>&1 | grep -q -- '--with-stream'; then
    error "当前 nginx 不包含 stream 模块，请安装 nginx-extras"
fi

# ==================== 第二阶段：前端部署 + Subconverter API 启动 ========
log "====== 阶段2：Web前端 + Subconverter API ======"

WORK_DIR="/opt/vps-deploy"
mkdir -p "$WORK_DIR"

# 复制静态网站文件
log "复制 Web主页..."
curl -sL "https://raw.githubusercontent.com/about300/vps-deployment/main/web/index.html" -o "$WORK_DIR/web/index.html"

log "复制 Subconverter 前端静态资源..."
mkdir -p "$WORK_DIR/web/sub"
# CSS/JS/IMG 等全部按你仓库结构拉
curl -sL "https://raw.githubusercontent.com/about300/vps-deployment/main/web/sub/index.html" -o "$WORK_DIR/web/sub/index.html"
# 按需下载静态文件
# 例如：
curl -sL "https://raw.githubusercontent.com/about300/vps-deployment/main/web/sub/css/app.css" -o "$WORK_DIR/web/sub/css/app.css"
curl -sL "https://raw.githubusercontent.com/about300/vps-deployment/main/web/sub/js/app.js" -o "$WORK_DIR/web/sub/js/app.js"
# 若有 img 目录资源，类似下载

# 下载 Subconverter API 二进制
curl -sL "https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter" -o "$WORK_DIR/bin/subconverter"
chmod +x "$WORK_DIR/bin/subconverter"

cat > "$WORK_DIR/config/subconverter.pref.ini" <<EOF
listen=127.0.0.1
port=25500
api_access_token=
managed_config_prefix=https://${MAIN_DOMAIN}/sub
EOF

# 后台启动 Subconverter API
cd "$WORK_DIR"
./bin/subconverter -c config/subconverter.pref.ini >/dev/null 2>&1 & disown
log "Subconverter API 已后台启动: 127.0.0.1:25500"

# ==================== 第三阶段：申请 SSL ====================
log "====== 阶段3：申请 SSL ======"
curl -s https://get.acme.sh | sh -s email="$CERT_EMAIL" > /dev/null
source ~/.bashrc
ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh

systemctl stop nginx 2>/dev/null || true
lsof -ti:80 | xargs kill -9 2>/dev/null || true

CERT_DIR="/etc/ssl/private/${MAIN_DOMAIN}"
mkdir -p "$CERT_DIR"

acme.sh --issue -d "$MAIN_DOMAIN" --standalone --keylength ec-256
acme.sh --install-cert -d "$MAIN_DOMAIN" --ecc \
    --key-file "$CERT_DIR/privkey.pem" \
    --fullchain-file "$CERT_DIR/fullchain.pem"

# ==================== 第四阶段：Nginx 配置（Stream + HTTP） ====================
log "====== 阶段4：配置 Nginx ======"
cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
events { worker_connections 768; }

stream {
    upstream xray_backend { server 127.0.0.1:443; }
    server {
        listen 443 reuseport;
        listen [::]:443 reuseport;
        proxy_pass xray_backend;
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

        location /app {
            proxy_pass http://127.0.0.1:2095/app;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
        }
        location /sub/ {
            alias $WORK_DIR/web/sub/;
            index index.html;
            try_files \$uri \$uri/ /sub/index.html;
        }
    }

    server {
        listen 80;
        server_name ${MAIN_DOMAIN};
        location /.well-known/acme-challenge/ { root /var/www/html; }
        location / { return 301 https://\$server_name\$request_uri; }
    }
}
EOF

nginx -t && systemctl restart nginx

# ==================== 第五阶段：安装 官方 s-ui ========
log "====== 阶段5：安装 s-ui 面板 ======"
curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh -o /tmp/s-ui-install.sh
chmod +x /tmp/s-ui-install.sh
bash /tmp/s-ui-install.sh

# 获取 s-ui 面板端口
SUI_DIR="/usr/local/s-ui"
SUI_PORT=2095
if [ -f "${SUI_DIR}/s-ui.conf" ]; then
    P=$(jq -r '.web.port // empty' "${SUI_DIR}/s-ui.conf")
    [ -n "$P" ] && [ "$P" != "null" ] && SUI_PORT=$P
fi
log "s-ui 面板监听端口: ${SUI_PORT}"

# ==================== 完成通知 ====================
clear
echo -e "${CYAN}╔════════════════════════════════╗${NC}"
echo -e "${CYAN}║         部署完成！           ║${NC}"
echo -e "${CYAN}╚════════════════════════════════╝${NC}"
echo "访问主页:      https://${MAIN_DOMAIN}"
echo "订阅转换:      https://${MAIN_DOMAIN}/sub/"
echo "s-ui 管理面板: https://${MAIN_DOMAIN}/app"
echo ""
echo -e "${YELLOW}请确保防火墙已开放 80 和 443 端口${NC}"
