#!/usr/bin/env bash
set -e

# ========== 颜色 ==========
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# ==================== 开始页（固定） ====================
clear
echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     VPS 全栈部署脚本 - Ubuntu24    ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
echo ""
read -rp "请输入主域名 (例如: example.com): " MAIN_DOMAIN
read -rp "请输入证书邮箱 (Let's Encrypt 通知): " CERT_EMAIL
read -rp "请输入 Cloudflare API Token: " CF_TOKEN
echo ""

log "配置摘要："
echo "  - 主域名: $MAIN_DOMAIN"
echo "  - 证书邮箱: $CERT_EMAIL"
echo ""
warn "将安装 nginx / s-ui / subconverter / sub-web"
warn "将覆盖 /opt 目录下相关内容（自动备份）"
read -rp "按 Enter 开始部署 (Ctrl+C 取消)..." dummy

# ==================== 基础环境 ====================
log "安装基础依赖"
apt update -y
apt install -y \
  curl wget git unzip tar \
  cron socat ufw \
  nginx ca-certificates

systemctl enable nginx

# ==================== 防火墙 ====================
log "配置防火墙"
ufw --force reset
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 8443
ufw allow 8445
ufw --force enable

# ==================== 安装 acme.sh（官方） ====================
log "安装 acme.sh"
if [ ! -d "/root/.acme.sh" ]; then
  curl -fsSL https://get.acme.sh | sh -s email="$CERT_EMAIL"
fi
ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh

acme.sh --set-default-ca --server letsencrypt

export CF_Token="$CF_TOKEN"

# ==================== 申请证书（DNS-01，不占 80） ====================
log "申请 Let's Encrypt 证书（Cloudflare DNS）"
acme.sh --issue \
  --dns dns_cf \
  -d "$MAIN_DOMAIN" \
  --keylength ec-256 \
  --force

CERT_DIR="/root/.acme.sh/${MAIN_DOMAIN}_ecc"
DOMAIN_CERT_DIR="/etc/ssl/${MAIN_DOMAIN}"

mkdir -p "$DOMAIN_CERT_DIR"

acme.sh --install-cert -d "$MAIN_DOMAIN" \
  --ecc \
  --key-file       "$DOMAIN_CERT_DIR/server.key" \
  --fullchain-file "$DOMAIN_CERT_DIR/server.crt" \
  --reloadcmd     "systemctl reload nginx"

# ==================== Web 主站 ====================
log "部署 Web 主站"
if [ -d /opt/vps-deploy ]; then
  mv /opt/vps-deploy "/opt/vps-deploy.bak.$(date +%s)"
fi

git clone https://github.com/youshandefeiyang/web-demo.git /opt/vps-deploy || true
echo "<h1>It works</h1>" >/opt/vps-deploy/index.html

# ==================== subconverter 后端 ====================
log "安装 subconverter"
mkdir -p /opt/subconverter
cd /opt/subconverter

wget -qO subconverter.tar.gz https://github.com/tindy2013/subconverter/releases/latest/download/subconverter_linux64.tar.gz
tar -xzf subconverter.tar.gz
chmod +x subconverter

pkill subconverter || true
nohup ./subconverter >/var/log/subconverter.log 2>&1 &

# ==================== sub-web 前端 ====================
log "部署 sub-web 前端"
mkdir -p /opt/sub-web
git clone https://github.com/youshandefeiyang/sub-web-modify.git /opt/sub-web || true

if [ -d /opt/sub-web/dist ]; then
  log "检测到已构建 dist，直接使用"
else
  warn "未检测到 dist，请自行构建后提交到 GitHub"
fi

# ==================== nginx 配置 ====================
log "配置 nginx"
cat >/etc/nginx/sites-available/default <<EOF
server {
    listen 443 ssl http2;
    server_name $MAIN_DOMAIN;

    ssl_certificate     $DOMAIN_CERT_DIR/server.crt;
    ssl_certificate_key $DOMAIN_CERT_DIR/server.key;

    root /opt/vps-deploy;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /sub/ {
        alias /opt/sub-web/dist/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}

server {
    listen 80;
    server_name $MAIN_DOMAIN;
    return 301 https://\$host\$request_uri;
}
EOF

nginx -t
systemctl reload nginx

# ==================== s-ui（官方） ====================
log "安装 s-ui（官方）"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# ==================== 完成页（固定） ====================
clear
echo -e "${CYAN}╔════════════════════════════════╗${NC}"
echo -e "${CYAN}║         部署完成！           ║${NC}"
echo -e "${CYAN}╚════════════════════════════════╝${NC}"
echo "Web主页:      https://$MAIN_DOMAIN"
echo "订阅转换:      https://$MAIN_DOMAIN/sub/"
echo "s-ui 管理面板: https://$MAIN_DOMAIN/app"
echo "证书路径:      $DOMAIN_CERT_DIR"
echo ""
echo -e "${YELLOW}已开启防火墙，允许端口: 22, 80, 443, 8443, 8445${NC}"
