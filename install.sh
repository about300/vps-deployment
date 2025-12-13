#!/usr/bin/env bash
set -e
# =================================================================
# Final install.sh
# - Uses apt when available
# - Uses webroot ACME issuance (no stopping nginx)
# - s-ui: official installer (unchanged)
# - AdGuardHome: official installer (optional)
# - Ports opened: 22, 80, 443, 8445, 8443
# - Certificates placed at /root/cert/<domain>/
# - SNI-based stream routing scaffold included (user must run Xray/VLESS on XRAY_PORT)
# =================================================================

# ------------------- colors & functions -------------------
CYAN="\033[1;36m"; YELLOW="\033[1;33m"; GREEN="\033[1;32m"; RED="\033[0;31m"; NC="\033[0m"
log(){ echo -e "${GREEN}[$(date '+%H:%M:%S')] $1${NC}"; }
warn(){ echo -e "${YELLOW}[!] $1${NC}"; }
err(){ echo -e "${RED}[x] $1${NC}"; exit 1; }

# ------------------- top fixed input page (DO NOT CHANGE) -------------------
clear
echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     VPS 全栈部署脚本 - Ubuntu24    ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
echo ""
read -rp "请输入主域名 (例如: example.com): " MAIN_DOMAIN
read -rp "请输入 SNI 代理子域名 (用于 VLESS/Reality, 默认: proxy.${MAIN_DOMAIN}): " PROXY_SNI
PROXY_SNI=${PROXY_SNI:-"proxy.${MAIN_DOMAIN}"}
read -rp "请输入邮箱 (用于 Let's Encrypt 通知): " CERT_EMAIL
echo ""
log "配置摘要："
echo "  - 主域名: $MAIN_DOMAIN"
echo "  - 代理 SNI: $PROXY_SNI"
echo "  - 证书邮箱: $CERT_EMAIL"
echo ""
warn "脚本将清理并覆盖 /opt/vps-deploy 下的 web 内容（会备份现有 web 若存在）"
read -rp "按 Enter 开始部署 (Ctrl+C 取消)..." dummy

# ------------------- variables -------------------
WORK_DIR="/opt/vps-deploy"
WEB_DIR="$WORK_DIR/web"
BIN_DIR="$WORK_DIR/bin"
CONF_DIR="$WORK_DIR/config"
CERT_BASE="/root/cert"
DOMAIN_CERT_DIR="$CERT_BASE/$MAIN_DOMAIN"
SUI_PORT=2095
XRAY_PORT=8445   # Xray/VLESS backend listening port (change in your VLESS config if needed)

# ------------------- stage 1: apt install base packages -------------------
log "阶段1：更新并安装官方包 (apt)"
apt update -y
apt upgrade -y
apt install -y nginx-extras unzip curl wget git socat lsof jq cron ufw

# Try to install acme.sh from apt if available; otherwise fall back to official installer
ACME_AVAILABLE=false
if apt show acme.sh >/dev/null 2>&1; then
  log "acme.sh 在 apt 仓库可用，使用 apt 安装 acme.sh"
  apt install -y acme.sh && ACME_AVAILABLE=true
fi
if ! $ACME_AVAILABLE; then
  log "acme.sh 未在 apt 仓库或安装失败，使用官方安装脚本安装 acme.sh"
  curl -sS https://get.acme.sh | sh -s -- --install
  # ensure link
  ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh || true
fi

# ------------------- stage 2: firewall -------------------
log "阶段2：配置 UFW 防火墙 (仅开放 22,80,443,8445,8443)"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 8445/tcp
ufw allow 8443/tcp
ufw --force enable

# ------------------- stage 3: deploy web files (from your repo) -------------------
log "阶段3：部署 Web 前端 (从仓库拉取)"
mkdir -p "$WORK_DIR" "$WEB_DIR" "$BIN_DIR" "$CONF_DIR"
if [ -d "$WEB_DIR" ] && [ "$(ls -A "$WEB_DIR")" ]; then
  BACKUP="/opt/vps-deploy-web-backup-$(date +%s)"
  log "备份现有 web 到 $BACKUP"
  mkdir -p "$BACKUP"
  cp -a "$WEB_DIR/." "$BACKUP/" || true
  rm -rf "$WEB_DIR"/*
fi

TMP="/tmp/vps_dep_tmp_$$"
rm -rf "$TMP"
git clone --depth=1 https://github.com/about300/vps-deployment.git "$TMP" || err "克隆仓库失败，请检查网络或仓库 URL"
if [ -d "$TMP/web" ]; then
  cp -r "$TMP/web/." "$WEB_DIR/"
  log "复制 web 内容到 $WEB_DIR"
else
  rm -rf "$TMP"
  err "仓库没有包含 web/ 目录，请先将静态资源放入仓库的 web/ 中"
fi
rm -rf "$TMP"

# Ensure acme challenge dir exists
mkdir -p "$WEB_DIR/.well-known/acme-challenge"

# ------------------- stage 4: initial nginx http config for webroot (no SSL yet) -------------------
log "阶段4：写入初始 Nginx 配置 (支持 webroot 验证)"
# backup nginx.conf
if [ -f /etc/nginx/nginx.conf ]; then
  cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak-$(date +%s) || true
fi

cat > /etc/nginx/nginx.conf <<NGINIT
user www-data;
worker_processes auto;
pid /run/nginx.pid;
events { worker_connections 768; }

http {
    server_tokens off;
    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;

    server {
        listen 80;
        listen [::]:80;
        server_name $MAIN_DOMAIN $PROXY_SNI;
        root $WEB_DIR;
        index index.html;
        location /.well-known/acme-challenge/ {
            alias $WEB_DIR/.well-known/acme-challenge/;
            try_files \$uri =404;
        }
        location / {
            # temporary info page before SSL
            try_files \$uri \$uri/ =404;
        }
    }
}
NGINIT

nginx -t || { cat /etc/nginx/nginx.conf; err "初始 nginx 配置语法错误"; }
systemctl enable nginx
systemctl restart nginx
log "Nginx 已用 HTTP 配置启动，$WEB_DIR 可用于 webroot 验证"

# ------------------- stage 5: issue cert via webroot (no nginx stop) -------------------
log "阶段5：使用 acme.sh 的 webroot 模式申请 Let'\''s Encrypt 证书"
mkdir -p "$DOMAIN_CERT_DIR"

ACME_CMD="$(command -v acme.sh || echo /root/.acme.sh/acme.sh)"
if [ ! -x "$ACME_CMD" ]; then
  err "acme.sh 未安装或不可执行 ($ACME_CMD)"
fi

# Try to issue for both MAIN_DOMAIN and PROXY_SNI so both SNI names covered
"$ACME_CMD" --issue -d "$MAIN_DOMAIN" -d "$PROXY_SNI" --webroot "$WEB_DIR" -m "$CERT_EMAIL" --server letsencrypt --keylength ec-256 || err "证书签发失败，请检查 DNS 是否解析到本机并确保 80 端口可访问"

# Install cert into fixed directory and set reloadcmd to reload nginx (and optionally AdGuard)
"$ACME_CMD" --install-cert -d "$MAIN_DOMAIN" \
  --key-file "$DOMAIN_CERT_DIR/privkey.key" \
  --fullchain-file "$DOMAIN_CERT_DIR/fullchain.crt" \
  --reloadcmd "systemctl reload nginx || true; systemctl restart AdGuardHome || true" \
  --ecc || err "证书安装失败"

chmod 600 "$DOMAIN_CERT_DIR/privkey.key" || true
chmod 644 "$DOMAIN_CERT_DIR/fullchain.crt" || true
log "证书已安装到 $DOMAIN_CERT_DIR (privkey.key / fullchain.crt)"

# ------------------- stage 6: final nginx config (stream + http(s)) -------------------
log "阶段6：写入最终 Nginx 配置 (包含 stream SNI 分流与 HTTPS 服务)"

cat > /etc/nginx/nginx.conf <<NGFINAL
user www-data;
worker_processes auto;
pid /run/nginx.pid;
events { worker_connections 768; }

# Stream layer for raw TCP SNI-based routing (VLESS/Reality etc.)
stream {
    map \$ssl_preread_server_name \$backend {
        ${MAIN_DOMAIN} web_backend;
        ${PROXY_SNI} xray_backend;
        default web_backend;
    }

    upstream web_backend {
        server 127.0.0.1:5443;  # http(s) backend for website (nginx http on loopback)
    }

    upstream xray_backend {
        server 127.0.0.1:${XRAY_PORT}; # Xray/VLESS backend (must be running)
    }

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
    server_tokens off;
    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;

    # Local HTTPS listener for web content (only on loopback port 5443)
    server {
        listen 127.0.0.1:5443 ssl http2;
        server_name $MAIN_DOMAIN;
        ssl_certificate $DOMAIN_CERT_DIR/fullchain.crt;
        ssl_certificate_key $DOMAIN_CERT_DIR/privkey.key;
        root $WEB_DIR;
        index index.html;

        # s-ui panel proxy (served by s-ui at its port)
        location /app/ {
            proxy_pass http://127.0.0.1:${SUI_PORT}/app/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }

        # Subconverter front & API
        location /sub/ {
            proxy_pass http://127.0.0.1:25500/;
            proxy_set_header Host \$host;
        }
    }

    # Public redirect from http to https (SNI-aware routing handled by stream)
    server {
        listen 80;
        listen [::]:80;
        server_name $MAIN_DOMAIN $PROXY_SNI;
        return 301 https://\$host\$request_uri;
    }
}
NGFINAL

nginx -t || { cat /etc/nginx/nginx.conf; err "最终 nginx 配置语法错误"; }
systemctl restart nginx
log "最终 nginx 已重启并加载 stream + http(s) 配置（SNI 将分流至 Xray 或本地 web）"

# ------------------- stage 7: deploy Subconverter binary & conf -------------------
log "阶段7：部署 Subconverter (二进制)"
SC_BIN="$BIN_DIR/subconverter"
SC_CONF="$CONF_DIR/subconverter.pref.ini"
wget -q -O "$SC_BIN" "https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter" || warn "下载 subconverter 失败"
chmod +x "$SC_BIN" || true

cat > "$SC_CONF" <<EOF
listen=127.0.0.1
port=25500
api_access_token=
managed_config_prefix=https://${MAIN_DOMAIN}/sub
EOF

nohup "$SC_BIN" -c "$SC_CONF" >/dev/null 2>&1 &

# ------------------- stage 8: install s-ui (official) -------------------
log "阶段8：安装 s-ui（官方脚本，不改）"
bash <(curl -sSL https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh) || warn "s-ui 安装脚本返回非0，继续..."

# ------------------- stage 9: install AdGuardHome (official) -------------------
log "阶段9：安装 AdGuardHome（官方脚本）"
curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh || warn "AdGuardHome 安装返回非0，继续..."

# Try to configure AdGuardHome to use same certs (best effort)
AG_DIR="/opt/AdGuardHome"
AG_CONF="$AG_DIR/AdGuardHome.yaml"
if [ -f "$AG_CONF" ]; then
  log "为 AdGuardHome 写入 TLS 配置"
  # Append tls block if not present (best-effort)
  if ! grep -q "certificate_chain:" "$AG_CONF"; then
    cat >> "$AG_CONF" <<AGTLS

tls:
  enabled: true
  certificate_chain: $DOMAIN_CERT_DIR/fullchain.crt
  private_key: $DOMAIN_CERT_DIR/privkey.key
AGTLS
    systemctl restart AdGuardHome || warn "重启 AdGuardHome 失败"
  fi
else
  warn "未找到 AdGuardHome 配置文件 $AG_CONF，请手动在面板中配置 TLS 证书路径"
fi

# ------------------- stage 10: setup renew helper (optional) -------------------
log "阶段10：创建证书续期脚本 /root/cert-monitor.sh (并安装 crontab 每28天执行一次)"
cat > /root/cert-monitor.sh <<'CMON'
#!/usr/bin/env bash
# renew cert and reload nginx/adguard
DOMAIN="REPLACE_DOMAIN"
ACME_CMD="$(command -v acme.sh || echo /root/.acme.sh/acme.sh)"
if [ -x "$ACME_CMD" ]; then
  "$ACME_CMD" --renew -d "$DOMAIN" --force --ecc --key-file /root/cert/$DOMAIN/privkey.key --fullchain-file /root/cert/$DOMAIN/fullchain.crt
  systemctl reload nginx || true
  systemctl restart AdGuardHome || true
fi
CMON
sed -i "s|REPLACE_DOMAIN|$MAIN_DOMAIN|g" /root/cert-monitor.sh
chmod +x /root/cert-monitor.sh
( crontab -l 2>/dev/null || true; echo "0 3 */28 * * /root/cert-monitor.sh >>/var/log/cert-monitor.log 2>&1" ) | crontab -

# ------------------- final page (single separate page) -------------------
clear
echo -e "${CYAN}╔════════════════════════════════╗${NC}"
echo -e "${CYAN}║         部署完成！           ║${NC}"
echo -e "${CYAN}╚════════════════════════════════╝${NC}"
echo "Web主页:      https://${MAIN_DOMAIN}"
echo "订阅转换:      https://${MAIN_DOMAIN}/sub/"
echo "s-ui 管理面板: https://${MAIN_DOMAIN}/app"
echo "证书路径:      ${DOMAIN_CERT_DIR}/privkey.key (key)  &  ${DOMAIN_CERT_DIR}/fullchain.crt (crt)"
echo ""
echo -e "${YELLOW}已开启防火墙，允许端口: 22, 80, 443, 8445, 8443${NC}"

# show top page again (fixed style)
sleep 2
clear
echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     VPS 全栈部署脚本 - Ubuntu24    ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
echo ""

exit 0
