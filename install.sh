#!/bin/bash
# =========================================================
# VPS 全栈一键部署（最终稳定版，证书改为 key/crt）
# Ubuntu 24 / minimal
# Web + Subconverter + s-ui + AdGuard Home + UFW
# 443 共用 / 无子域名
# =========================================================

set -e
export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
log(){ echo -e "${GREEN}[$(date +%H:%M:%S)] $1${NC}"; }
die(){ echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

# ================== 必要输入（仅 2 项） ==================
read -rp "请输入主域名（如 example.com）: " MAIN_DOMAIN
[[ -z "$MAIN_DOMAIN" ]] && die "域名不能为空"

read -rp "请输入邮箱（用于 SSL 证书）: " CERT_EMAIL
[[ -z "$CERT_EMAIL" ]] && die "邮箱不能为空"

# ================== 固定路径 ==================
WORKDIR="/opt/vps-deploy"
WEB_DIR="$WORKDIR/web"
SUB_DIR="$WEB_DIR/sub"
CERT_DIR="/root"

# ================== 阶段0：基础环境 ==================
log "阶段0：安装基础环境"
apt update -y
apt install -y curl wget git unzip socat lsof jq nginx-extras ufw

# ================== 阶段1：部署 Web 静态文件 ==================
log "阶段1：部署 Web 目录"
mkdir -p "$WEB_DIR"
if [ -d "./web" ]; then
  cp -r ./web/* "$WEB_DIR/"
else
  die "未检测到 ./web 目录，请确认仓库结构"
fi

# ================== 阶段2：申请 SSL（顺序修正） ==================
log "阶段2：申请 SSL 证书"

systemctl stop nginx 2>/dev/null || true
lsof -ti:80 | xargs kill -9 2>/dev/null || true

curl -s https://get.acme.sh | sh -s email="$CERT_EMAIL"
source ~/.bashrc

# 申请证书
~/.acme.sh/acme.sh --issue -d "$MAIN_DOMAIN" --standalone --force

# 安装证书到 /root，并设置 reload 命令
~/.acme.sh/acme.sh --install-cert -d "$MAIN_DOMAIN" \
  --key-file       "$CERT_DIR/privkey.key" \
  --fullchain-file "$CERT_DIR/fullchain.crt" \
  --reloadcmd "systemctl reload nginx || true; systemctl restart AdGuardHome || true"

chmod 600 "$CERT_DIR/privkey.key"
chmod 644 "$CERT_DIR/fullchain.crt"

# ================== 阶段3：安装 s-ui（官方） ==================
log "阶段3：安装 s-ui"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# ================== 阶段4：Subconverter API ==================
log "阶段4：Subconverter API"

mkdir -p "$WORKDIR/bin" "$WORKDIR/config"

wget -q -O "$WORKDIR/bin/subconverter" \
  https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
chmod +x "$WORKDIR/bin/subconverter"

cat > "$WORKDIR/config/subconverter.ini" <<EOF
listen=127.0.0.1
port=25500
managed_config_prefix=https://${MAIN_DOMAIN}/sub
EOF

nohup "$WORKDIR/bin/subconverter" -c "$WORKDIR/config/subconverter.ini" >/dev/null 2>&1 &

# ================== 阶段5：Nginx（443 共用） ==================
log "阶段5：配置 Nginx"

cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
events { worker_connections 1024; }

stream {
  map \$ssl_preread_server_name \$backend {
    $MAIN_DOMAIN web;
    default xray;
  }

  upstream web  { server 127.0.0.1:8443; }
  upstream xray { server 127.0.0.1:443; }

  server {
    listen 443 reuseport;
    proxy_pass \$backend;
    ssl_preread on;
  }
}

http {
  server {
    listen 127.0.0.1:8443 ssl http2;
    server_name $MAIN_DOMAIN;

    ssl_certificate     $CERT_DIR/fullchain.crt;
    ssl_certificate_key $CERT_DIR/privkey.key;

    root $WEB_DIR;
    index index.html;

    location /sub/ {
      alias $SUB_DIR/;
      try_files \$uri \$uri/ /index.html;
    }

    location /app/ {
      proxy_pass http://127.0.0.1:2095/app/;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
    }
  }
}
EOF

nginx -t
systemctl restart nginx

# ================== 阶段6：安装 AdGuard Home ==================
log "阶段6：安装 AdGuard Home"
curl -s https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh

# 修改 AdGuard Home TLS 配置
AGH_CONFIG="/opt/AdGuardHome/AdGuardHome.yaml"
if [ -f "$AGH_CONFIG" ]; then
  sed -i "/^tls:/,+4d" "$AGH_CONFIG"
  cat >> "$AGH_CONFIG" <<EOF
tls:
  enabled: true
  certificate_chain: $CERT_DIR/fullchain.crt
  private_key: $CERT_DIR/privkey.key
EOF
  systemctl restart AdGuardHome
fi

# ================== 阶段7：UFW 防火墙 ==================
log "阶段7：配置 UFW"

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 25500
ufw allow 3000
ufw allow 8445
ufw --force enable

# ================== 完成 ==================
log "部署完成"
echo "========================================"
echo "主页:        https://$MAIN_DOMAIN"
echo "订阅转换:    https://$MAIN_DOMAIN/sub/"
echo "s-ui 面板:   https://$MAIN_DOMAIN/app"
echo "AdGuard:     https://$MAIN_DOMAIN:3000"
echo "========================================"
