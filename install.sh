#!/usr/bin/env bash
set -e

# ==================== 样式 ====================
CYAN="\033[36m"
YELLOW="\033[33m"
NC="\033[0m"

log() { echo -e "${CYAN}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }

# ==================== 开头页（不要动） ====================
clear
echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     VPS 全栈部署脚本 - Ubuntu     ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
echo ""

read -rp "请输入主域名 (example.com): " MAIN_DOMAIN
read -rp "请输入 Cloudflare API Token: " CF_Token
read -rp "请输入 Cloudflare 注册邮箱: " CF_Email
read -rp "请输入 SSL 通知邮箱 (Let's Encrypt): " CERT_EMAIL

echo ""
log "配置摘要："
echo "  - 域名: $MAIN_DOMAIN"
echo "  - 使用 Cloudflare DNS API"
echo ""

read -rp "按 Enter 开始部署 (Ctrl+C 取消)..." dummy

# ==================== 基础环境 ====================
log "安装基础依赖"
apt update -y
apt install -y \
  nginx git curl wget unzip cron socat ufw \
  nodejs npm yarn

# ==================== 防火墙 ====================
log "配置防火墙"
ufw --force reset
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 8443
ufw --force enable

# ==================== acme.sh（DNS 模式） ====================
log "安装 acme.sh"
curl -s https://get.acme.sh | sh -s email="$CERT_EMAIL"
source ~/.bashrc

export CF_Token
export CF_Email

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

log "申请 ECC 证书（DNS 验证，不占端口）"
~/.acme.sh/acme.sh --issue \
  --dns dns_cf \
  -d "$MAIN_DOMAIN" \
  --keylength ec-256

log "安装证书到 /root"
~/.acme.sh/acme.sh --install-cert -d "$MAIN_DOMAIN" --ecc \
  --key-file       /root/server.key \
  --fullchain-file /root/server.crt \
  --reloadcmd     "systemctl reload nginx"

# ==================== Web 主站 ====================
log "部署 Web 主站"
rm -rf /opt/vps-deploy
git clone https://github.com/about300/vps-deployment.git /opt/vps-deploy

# ==================== subconverter ====================
log "部署 subconverter"
mkdir -p /opt/subconverter
cd /opt/subconverter

if [ ! -f subconverter ]; then
  wget -O subconverter https://github.com/tindy2013/subconverter/releases/latest/download/subconverter_linux64
  chmod +x subconverter
fi

pkill subconverter || true
nohup ./subconverter >/var/log/subconverter.log 2>&1 &

# ==================== sub-web（自动构建） ====================
log "部署 sub-web 前端"
rm -rf /opt/sub-web
git clone https://github.com/youshandefeiyang/sub-web-modify.git /opt/sub-web

cd /opt/sub-web

log "修正 publicPath 为 /sub/"
cat > vue.config.js <<EOF
module.exports = {
  publicPath: '/sub/',
  outputDir: 'dist'
}
EOF

log "安装依赖并构建"
yarn install
yarn build

# ==================== nginx ====================
log "配置 nginx"

cat >/etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name $MAIN_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $MAIN_DOMAIN;

    ssl_certificate     /root/server.crt;
    ssl_certificate_key /root/server.key;

    root /opt/vps-deploy/web;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /sub/ {
        root /opt/sub-web/dist;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

nginx -t
systemctl restart nginx

# ==================== s-ui（官方） ====================
log "安装 s-ui（官方脚本）"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# ==================== 完成页（不要动） ====================
clear
echo -e "${CYAN}╔════════════════════════════════╗${NC}"
echo -e "${CYAN}║         部署完成！           ║${NC}"
echo -e "${CYAN}╚════════════════════════════════╝${NC}"
echo ""
echo "Web主页:      https://$MAIN_DOMAIN"
echo "订阅转换:      https://$MAIN_DOMAIN/sub/"
echo "s-ui 管理面板: https://$MAIN_DOMAIN/app"
echo "证书路径:      /root/server.crt /root/server.key"
echo ""
echo -e "${YELLOW}已开启防火墙，允许端口: 22, 80, 443, 8443${NC}"
