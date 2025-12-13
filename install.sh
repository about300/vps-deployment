#!/usr/bin/env bash
set -e

# ==================== 颜色 & 工具 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR ]${NC} $*"; exit 1; }

# ==================== 开头页（固定，不可改） ====================
clear
echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     VPS 全栈部署脚本 - Ubuntu24    ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
echo ""

read -rp "请输入主域名 (例如: example.com): " MAIN_DOMAIN
read -rp "请输入邮箱 (用于申请 SSL，Let's Encrypt 通知): " CERT_EMAIL
read -rp "请输入 Cloudflare API Token: " CF_TOKEN

echo ""
log "配置摘要："
echo "  - 主域名: $MAIN_DOMAIN"
echo "  - 证书邮箱: $CERT_EMAIL"
echo ""
warn "脚本将清理并覆盖 /opt/vps-deploy 下的 web 内容（会备份现有配置）"
read -rp "按 Enter 开始部署 (Ctrl+C 取消)..." dummy

# ==================== 基础环境 ====================
log "安装基础依赖（apt）..."
apt update -y
apt install -y \
  curl wget git unzip tar cron socat ufw \
  nginx ca-certificates

systemctl enable nginx
systemctl start nginx

# ==================== 防火墙 ====================
log "配置防火墙..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

for p in 22 80 443 8443 8445; do
  ufw allow ${p}/tcp
done

ufw --force enable

# ==================== Web 文件 ====================
WEB_DIR="/opt/vps-deploy"
BACKUP_DIR="/opt/vps-deploy-backup-$(date +%s)"

if [ -d "$WEB_DIR" ]; then
  log "备份旧 web 目录到 $BACKUP_DIR"
  mv "$WEB_DIR" "$BACKUP_DIR"
fi

log "拉取 Web 前端（GitHub）..."
git clone https://github.com/about300/vps-deployment.git /tmp/vps-deploy-temp
mkdir -p "$WEB_DIR"
cp -r /tmp/vps-deploy-temp/web/* "$WEB_DIR/"
rm -rf /tmp/vps-deploy-temp

# ==================== acme.sh（只装一次） ====================
if [ ! -f /root/.acme.sh/acme.sh ]; then
  log "安装 acme.sh..."
  curl https://get.acme.sh | sh -s email="$CERT_EMAIL"
fi

source /root/.bashrc
ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh

acme.sh --set-default-ca --server letsencrypt

# ==================== Cloudflare DNS 证书 ====================
export CF_Token="$CF_TOKEN"

CERT_DIR="/root"
DOMAIN_CERT_DIR="$CERT_DIR"

log "使用 Cloudflare DNS 申请证书（不占用 80/443）..."

acme.sh --issue \
  --dns dns_cf \
  -d "$MAIN_DOMAIN" \
  --keylength ec-256

acme.sh --install-cert \
  -d "$MAIN_DOMAIN" \
  --ecc \
  --key-file       "$DOMAIN_CERT_DIR/server.key" \
  --fullchain-file "$DOMAIN_CERT_DIR/server.crt" \
  --reloadcmd     "systemctl reload nginx"

# ==================== Nginx 配置 ====================
log "配置 Nginx..."

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
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

nginx -t
systemctl reload nginx

# ==================== SubConvert ====================
log "安装 SubConvert..."
mkdir -p /opt/subconvert
cd /opt/subconvert

if [ ! -f subconverter ]; then
  wget -O subconverter.tar.gz https://github.com/tindy2013/subconverter/releases/latest/download/subconverter_linux64.tar.gz
  tar -xzf subconverter.tar.gz
  chmod +x subconverter
fi

cat >/etc/systemd/system/subconvert.service <<EOF
[Unit]
Description=SubConverter
After=network.target

[Service]
ExecStart=/opt/subconvert/subconverter
WorkingDirectory=/opt/subconvert
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable subconvert
systemctl start subconvert

# ==================== s-ui（官方脚本，不改） ====================
log "安装 s-ui（官方）..."
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# ==================== 完成页（固定，不可改） ====================
clear
echo -e "${CYAN}╔════════════════════════════════╗${NC}"
echo -e "${CYAN}║         部署完成！           ║${NC}"
echo -e "${CYAN}╚════════════════════════════════╝${NC}"
echo "Web主页:      https://$MAIN_DOMAIN"
echo "订阅转换:      https://$MAIN_DOMAIN/sub/"
echo "s-ui 管理面板: https://$MAIN_DOMAIN/app"
echo "证书路径:      $DOMAIN_CERT_DIR"
echo ""
echo -e "${YELLOW}已开启防火墙，允许端口: 22, 80, 443, 8445, 8443${NC}"
