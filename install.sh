#!/bin/bash
# =================================================================
# VPS 全栈一键部署脚本 (SNI分流 + Web前端 + s-ui面板 + Subconverter)
# 适配 Ubuntu 24.0
# 执行: bash <(curl -s https://raw.githubusercontent.com/about300/vps-deployment/main/install.sh)
# =================================================================

set -e
exec 2>&1

# 颜色定义
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log() { echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
info() { echo -e "${BLUE}[i] $1${NC}"; }
error() { echo -e "${RED}[x] $1${NC}"; exit 1; }

# ==================== 配置 ====================
clear
echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     VPS 全栈部署脚本 - Ubuntu24    ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
echo ""

read -p "1. 请输入主域名 (例如: example.com): " MAIN_DOMAIN
read -p "2. 请输入SNI子域名 [默认: proxy.${MAIN_DOMAIN}]: " PROXY_SNI
PROXY_SNI=${PROXY_SNI:-"proxy.${MAIN_DOMAIN}"}
read -p "3. 请输入邮箱 (用于申请SSL证书): " CERT_EMAIL

echo ""
log "配置摘要："
echo "  - 主域名: $MAIN_DOMAIN"
echo "  - 代理SNI域名: $PROXY_SNI"
echo "  - 证书邮箱: $CERT_EMAIL"
echo ""
warn "脚本将彻底清理系统可能存在的旧版Nginx。"
read -p "按 Enter 开始部署 (Ctrl+C 取消)..."

# ==================== 第一阶段：基础环境 ====================
log "====== 阶段1：基础环境 ======"
apt update && apt upgrade -y
apt install -y curl wget git socat cron jq lsof unzip nginx-extras

# 确保 nginx 支持 stream
if ! nginx -V 2>&1 | grep -q -- '--with-stream'; then
    error "Nginx 不包含 stream 模块，请检查安装 nginx-extras"
fi

# ==================== 第二阶段：Web 前端 + Subconverter ====================
log "====== 阶段2：Web前端 + Subconverter ======"
WORK_DIR="/opt/vps-deploy"
mkdir -p $WORK_DIR/{web,bin,config}

# Web 前端 (模拟搜索主页 + 订阅转换入口)
cat > $WORK_DIR/web/index.html <<'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>VPS Home</title>
<style>
body{font-family:Arial;text-align:center;margin:0;padding:0;background:#f6f7fb;}
header{display:flex;justify-content:flex-end;padding:18px;}
a.button{display:inline-block;margin:0 10px;padding:8px 12px;background:#0b63e6;color:#fff;border-radius:6px;text-decoration:none;}
.brand{font-size:28px;font-weight:700;margin:20px 0;}
.search{margin-top:30px;}
input[type=text]{padding:12px;width:60%;border-radius:10px;border:1px solid #dfe6f5;font-size:16px;}
button{padding:12px 20px;border:none;border-radius:8px;background:#28a745;color:#fff;font-weight:600;cursor:pointer;}
</style>
</head>
<body>
<header>
  <a class="button" href="/sub/">订阅转换</a>
</header>
<div class="brand">MyHome</div>
<div class="search">
  <form method="GET" action="https://www.bing.com/search" target="_blank">
    <input type="text" name="q" placeholder="搜索..." />
    <button type="submit">搜索</button>
  </form>
</div>
</body>
</html>
EOF

# Subconverter 二进制
REPO_URL="https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter"
wget -q -O $WORK_DIR/bin/subconverter $REPO_URL && chmod +x $WORK_DIR/bin/subconverter
if [ -f "$WORK_DIR/bin/subconverter" ]; then
    cat > $WORK_DIR/config/subconverter.pref.ini <<EOF
listen=127.0.0.1
port=25500
api_access_token=
managed_config_prefix=https://${MAIN_DOMAIN}/sub
EOF
    cd $WORK_DIR && nohup ./bin/subconverter -c config/subconverter.pref.ini >/dev/null 2>&1 &
    log "Subconverter 启动在端口 25500"
fi

# ==================== 第三阶段：申请 SSL ====================
log "====== 阶段3：申请 SSL ======"
curl -s https://get.acme.sh | sh -s email=$CERT_EMAIL > /dev/null
source ~/.bashrc
ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh

systemctl stop nginx 2>/dev/null || true
lsof -ti:80 | xargs kill -9 2>/dev/null || true

CERT_DIR="/etc/ssl/private/${MAIN_DOMAIN}"
mkdir -p $CERT_DIR
acme.sh --issue -d "$MAIN_DOMAIN" -d "$PROXY_SNI" --standalone --keylength ec-256
acme.sh --install-cert -d "$MAIN_DOMAIN" --ecc \
    --key-file $CERT_DIR/privkey.pem \
    --fullchain-file $CERT_DIR/fullchain.pem

# ==================== 第四阶段：Nginx SNI 分流 ====================
log "====== 阶段4：配置 Nginx ======"
XRAY_PORT=443
cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
events { worker_connections 768; }
stream {
    map \$ssl_preread_server_name \$backend {
        ${MAIN_DOMAIN} web_backend;
        ${PROXY_SNI} xray_backend;
        default web_backend;
    }
    upstream web_backend { server 127.0.0.1:5443; }
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
        location /app { proxy_pass http://127.0.0.1:2095/app; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; }
        location /sub/ { proxy_pass http://127.0.0.1:25500/; proxy_set_header Host \$host; }
    }
    server {
        listen 80;
        server_name ${MAIN_DOMAIN} ${PROXY_SNI};
        location /.well-known/acme-challenge/ { root /var/www/html; }
        location / { return 301 https://\$server_name\$request_uri; }
    }
}
EOF

nginx -t
systemctl restart nginx

# ==================== 第五阶段：安装 s-ui 面板 ====================
log "====== 阶段5：安装 s-ui 面板 ======"
SUI_DIR="/opt/s-ui"
if [ ! -d "$SUI_DIR" ]; then
    git clone https://github.com/alireza0/s-ui.git "$SUI_DIR"
fi
cd "$SUI_DIR"
chmod +x s-ui
./s-ui install
systemctl enable s-ui
systemctl restart s-ui

# 获取 s-ui 面板端口
SUI_WEB_PORT=2095
CONFIG_FILE="/usr/local/s-ui/s-ui.conf"
if [ -f "$CONFIG_FILE" ]; then
    CONFIG_PORT=$(jq -r '.web.port // empty' "$CONFIG_FILE" 2>/dev/null)
    [ -n "$CONFIG_PORT" ] && [ "$CONFIG_PORT" != "null" ] && SUI_WEB_PORT=$CONFIG_PORT
fi
log "s-ui 面板端口: ${SUI_WEB_PORT}"

# ==================== 完成 ====================
clear
echo -e "${CYAN}╔════════════════════════════════╗${NC}"
echo -e "${CYAN}║      部署完成!访问信息        ║${NC}"
echo -e "${CYAN}╚════════════════════════════════╝${NC}"
echo "Web主页: https://${MAIN_DOMAIN}"
echo "s-ui面板: https://${MAIN_DOMAIN}/app"
echo "Subconverter API: 127.0.0.1:25500"
echo "SNI代理地址: ${PROXY_SNI}:443"
echo ""
echo -e "${YELLOW}请确保防火墙已开放 80 和 443 端口${NC}"
