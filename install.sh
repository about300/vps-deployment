#!/bin/bash
# =================================================================
# VPS 全栈一键部署脚本（最终版）
# - Ubuntu 官方 apt 包
# - Webroot 模式申请 Let's Encrypt (acme.sh)
# - s-ui 使用官方安装脚本（不更改）
# - Web 前端从你的仓库拉取到 /opt/vps-deploy/web
# - Subconverter local binary, AdGuardHome installed and use same cert
# - Certs placed at /root/cert/<domain>/
# - 防火墙仅开放 22,80,443,8445
# =================================================================

set -e
exec 2>&1

# ------------------- 颜色 -------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log(){ echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}"; }
warn(){ echo -e "${YELLOW}[!] $1${NC}"; }
info(){ echo -e "${BLUE}[i] $1${NC}"; }
err(){ echo -e "${RED}[x] $1${NC}" ; exit 1; }

# ------------------- 顶部固定页（用户输入） -------------------
clear
echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     VPS 全栈部署脚本 - Ubuntu24    ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
echo ""
read -rp "请输入主域名 (例如: example.com): " MAIN_DOMAIN
read -rp "请输入邮箱 (用于申请 SSL，Let's Encrypt 通知): " CERT_EMAIL
echo ""
log "配置摘要："
echo "  - 主域名: $MAIN_DOMAIN"
echo "  - 证书邮箱: $CERT_EMAIL"
echo ""
warn "脚本将清理并覆盖 /opt/vps-deploy 下的 web 内容（会备份现有配置）"
read -rp "按 Enter 开始部署 (Ctrl+C 取消)..." dummy

# ------------------- 变量 -------------------
WORK_DIR="/opt/vps-deploy"
WEB_DIR="$WORK_DIR/web"
BIN_DIR="$WORK_DIR/bin"
CONF_DIR="$WORK_DIR/config"
CERT_BASE="/root/cert"
DOMAIN_CERT_DIR="$CERT_BASE/$MAIN_DOMAIN"
SUI_PORT=2095

# ------------------- 阶段1：系统 & 包 -------------------
log "====== 阶段1：更新系统并安装依赖（来自 apt 官方源）======"
apt update -y && apt upgrade -y
apt install -y nginx-extras unzip curl wget git socat lsof jq cron ufw

# ------------------- 阶段2：部署 Web (从仓库拉取) -------------------
log "====== 阶段2：部署 Web 前端（从仓库拉取）======"
mkdir -p "$WORK_DIR" "$WEB_DIR" "$BIN_DIR" "$CONF_DIR"
# 备份旧的 web（如果存在）
if [ -d "$WEB_DIR" ] && [ "$(ls -A "$WEB_DIR")" ]; then
  BACKUP="/opt/vps-deploy-web-backup-$(date +%s)"
  log "备份现有 web 到 $BACKUP"
  mkdir -p "$BACKUP"
  cp -a "$WEB_DIR/." "$BACKUP/" || true
fi

# 拉取到临时目录并复制
TMP="/tmp/vps_web_tmp_$$"
rm -rf "$TMP"
git clone --depth=1 https://github.com/about300/vps-deployment.git "$TMP"
if [ -d "$TMP/web" ]; then
  rm -rf "$WEB_DIR"/*
  cp -r "$TMP/web/." "$WEB_DIR/"
  log "复制 web 内容到 $WEB_DIR"
else
  rm -rf "$TMP"
  err "仓库中未找到 web/ 目录，请先确保仓库包含 web 静态资源"
fi
rm -rf "$TMP"

# 确保 web 的 acme challenge 路径存在
mkdir -p "$WEB_DIR/.well-known/acme-challenge"

# ------------------- 阶段3：最小 Nginx（HTTP）配置以支持 webroot 验证 =======
log "====== 阶段3：配置临时 Nginx（仅 HTTP）用于 Webroot 验证 ======"
# 备份原 nginx 配置（如果存在）
if [ -f /etc/nginx/nginx.conf ]; then
  cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak-$(date +%s) || true
fi

cat > /etc/nginx/nginx.conf <<'NGTMP'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
events { worker_connections 768; }

http {
    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;
    server_tokens off;

    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name _;
        root /var/www/html;
        location /.well-known/acme-challenge/ {
            alias __WEBROOT_PATH__/.well-known/acme-challenge/;
            try_files $uri =404;
        }
        location / {
            return 200 'OK';
            add_header Content-Type text/plain;
        }
    }
}
NGTMP

# 替换占位符为实际路径
sed -i "s|__WEBROOT_PATH__|$WEB_DIR|g" /etc/nginx/nginx.conf

nginx -t || { cat /etc/nginx/nginx.conf; err "nginx 配置检测失败"; }
systemctl enable nginx
systemctl restart nginx
log "临时 Nginx 已启动并用 $WEB_DIR 提供 /.well-known/acme-challenge"

# ------------------- 阶段4：申请 Let’s Encrypt（acme.sh, webroot） -------------------
log "====== 阶段4：申请 Let’s Encrypt 证书（Webroot 模式） ======"
mkdir -p "$DOMAIN_CERT_DIR"
curl -s https://get.acme.sh | sh -s -- --install
# 确保环境生效
export PATH="$HOME/.acme.sh:$PATH"
ACME_SH="$HOME/.acme.sh/acme.sh"
if [ ! -f "$ACME_SH" ]; then
  ACME_SH="/root/.acme.sh/acme.sh"
fi
if [ ! -f "$ACME_SH" ]; then
  err "acme.sh 未安装成功，查看网络或手动安装"
fi

# issue with webroot; include email
"$ACME_SH" --issue -d "$MAIN_DOMAIN" --webroot "$WEB_DIR" -m "$CERT_EMAIL" --server letsencrypt --keylength ec-256 --nocron

# install cert to fixed location and set reload hook (nginx + AdGuardHome)
"$ACME_SH" --install-cert -d "$MAIN_DOMAIN" \
  --key-file "$DOMAIN_CERT_DIR/privkey.key" \
  --fullchain-file "$DOMAIN_CERT_DIR/fullchain.crt" \
  --reloadcmd "systemctl reload nginx || true; systemctl restart AdGuardHome || true"

chmod 600 "$DOMAIN_CERT_DIR/privkey.key" || true
chmod 644 "$DOMAIN_CERT_DIR/fullchain.crt" || true
log "证书已写入 $DOMAIN_CERT_DIR"

# ------------------- 阶段5：安装 s-ui（官方脚本，不更改） -------------------
log "====== 阶段5：安装 s-ui 面板（官方） ======"
# 使用官方 raw 安装脚本
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh) || warn "s-ui 安装脚本返回非 0，继续尝试后续步骤"
log "s-ui 已安装（如需要，请登录面板检查并在面板内配置证书路径）"

# ------------------- 阶段6：配置最终 Nginx（HTTPS + 反向代理）=========
log "====== 阶段6：写入最终 Nginx 配置（HTTPS + /app /sub） ======"
cat > /etc/nginx/nginx.conf <<NGFINAL
user www-data;
worker_processes auto;
pid /run/nginx.pid;
events { worker_connections 768; }

http {
    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;
    server_tokens off;

    server {
        listen 80;
        listen [::]:80;
        server_name $MAIN_DOMAIN;
        root $WEB_DIR;
        index index.html;
        location /.well-known/acme-challenge/ {
            alias $WEB_DIR/.well-known/acme-challenge/;
        }
        location / { return 301 https://\$host\$request_uri; }
    }

    server {
        listen 443 ssl http2;
        listen [::]:443 ssl http2;
        server_name $MAIN_DOMAIN;

        ssl_certificate $DOMAIN_CERT_DIR/fullchain.crt;
        ssl_certificate_key $DOMAIN_CERT_DIR/privkey.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers on;

        root $WEB_DIR;
        index index.html;

        # s-ui 面板前端路径代理到本地 s-ui 服务
        location /app/ {
            proxy_pass http://127.0.0.1:${SUI_PORT}/app/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }

        # Subconverter 前端 / API proxy
        location /sub/ {
            proxy_pass http://127.0.0.1:25500/;
            proxy_set_header Host \$host;
        }
    }
}
NGFINAL

nginx -t || { cat /etc/nginx/nginx.conf; err "最终 nginx 配置检查失败"; }
systemctl restart nginx
log "最终 Nginx 已加载 HTTPS 配置"

# ------------------- 阶段7：部署 Subconverter（本地二进制） -------------------
log "====== 阶段7：部署 Subconverter ======"
# 下载或覆盖本地二进制
SC_BIN="$BIN_DIR/subconverter"
wget -q -O "$SC_BIN" "https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter" || warn "下载 subconverter 失败"
chmod +x "$SC_BIN" || true

cat > "$CONF_DIR/subconverter.pref.ini" <<EOF
listen=127.0.0.1
port=25500
api_access_token=
managed_config_prefix=https://$MAIN_DOMAIN/sub
EOF

nohup "$SC_BIN" -c "$CONF_DIR/subconverter.pref.ini" >/dev/null 2>&1 &
log "Subconverter 启动（后台）"

# ------------------- 阶段8：安装 AdGuardHome 并配置 TLS（使用相同证书） ----
log "====== 阶段8：安装 AdGuardHome 并配置 TLS ======"
AG_DIR="/opt/AdGuardHome"
mkdir -p "$AG_DIR"
cd /tmp
wget -q https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz
tar xzf AdGuardHome_linux_amd64.tar.gz
# mv extracted to /opt/AdGuardHome
if [ -d "./AdGuardHome" ]; then
  mv -f ./AdGuardHome "$AG_DIR"
fi
# install as service
"$AG_DIR/AdGuardHome" -s install || warn "AdGuardHome install returned non-zero"

# modify AdGuard config to use certs (if present)
AG_CONF="$AG_DIR/AdGuardHome.yaml"
if [ -f "$AG_CONF" ]; then
  # Remove any existing tls: block then append new tls block
  sed -i '/^tls:/,/^[^[:space:]]/d' "$AG_CONF" 2>/dev/null || true
  cat >> "$AG_CONF" <<EOF

tls:
  enabled: true
  certificate_chain: $DOMAIN_CERT_DIR/fullchain.crt
  private_key: $DOMAIN_CERT_DIR/privkey.key
EOF
  systemctl restart AdGuardHome || warn "AdGuardHome restart failed"
  log "AdGuardHome 已配置为使用 $DOMAIN_CERT_DIR 下证书"
else
  warn "未找到 AdGuardHome 配置文件 $AG_CONF，请登录 AdGuard 面板手动配置 TLS"
fi

# ------------------- 阶段9：UFW（确认） -------------------
log "====== 阶段9：确认 UFW ======"
ufw --force enable
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 8445/tcp

# ------------------- 完成页（单独一页） -------------------
clear
echo -e "${CYAN}╔════════════════════════════════╗${NC}"
echo -e "${CYAN}║         部署完成！           ║${NC}"
echo -e "${CYAN}╚════════════════════════════════╝${NC}"
echo "Web主页:      https://$MAIN_DOMAIN"
echo "订阅转换:      https://$MAIN_DOMAIN/sub/"
echo "s-ui 管理面板: https://$MAIN_DOMAIN/app"
echo "证书路径:      $DOMAIN_CERT_DIR"
echo ""
echo -e "${YELLOW}已开启防火墙，允许端口: 22, 80, 443, 8445${NC}"

# ------------------- 再显示一次顶部样式页（固定模式） -------------------
sleep 2
clear
echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     VPS 全栈部署脚本 - Ubuntu24    ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
echo ""

# 结束
exit 0
