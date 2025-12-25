#!/usr/bin/env bash
# Ubuntu 24.04 专用 · 最终版 install.sh
# 一键部署：nginx(stream+http, nginx.org) + acme.sh(CF DNS) + SubConverter + sub-web-modify + S-UI
# 幂等：已存在的组件会跳过或安全覆盖
set -euo pipefail

# ----------------------------
# 检查 root
# ----------------------------
if [ "$EUID" -ne 0 ]; then
  echo "请以 root 权限运行脚本（sudo bash install.sh）"
  exit 1
fi

# ----------------------------
# 询问交互
# ----------------------------
read -rp "请输入主域名（例如 try.mycloudshare.org）: " DOMAIN
read -rp "请输入 Cloudflare 注册邮箱（用于 acme）: " CF_EMAIL
read -rp "请输入 Cloudflare API Token（有 DNS 编辑权限）: " CF_TOKEN
read -rp "如需使用自定义 sub-web 仓库，输入 HTTPS 地址（回车使用 https://github.com/about300/sub-web-modify.git ）: " SUBWEB_REPO
SUBWEB_REPO="${SUBWEB_REPO:-https://github.com/about300/sub-web-modify.git}"

export CF_Email="$CF_EMAIL"
export CF_Token="$CF_TOKEN"

# ----------------------------
# 变量
# ----------------------------
WEB_ROOT="/opt/web"
SUBWEB_SRC="/opt/sub-web-src"
SUBWEB_DIST="/opt/sub-web"
SUBCONV_DIR="/opt/subconverter"
CERT_DIR="/etc/nginx/ssl/$DOMAIN"
REALITY_PORT=10000   # S-UI Reality 内网监听端口（SNI 分流目标）
WEB_BACKEND_PORT=8443
SUBCONVERTER_BIN_URL="https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter"
SUI_INSTALLER="https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh"

# ----------------------------
# 基础包
# ----------------------------
echo "[1/10] 安装系统基础依赖..."
apt update -y
apt install -y curl wget git unzip socat cron ufw ca-certificates gnupg2 lsb-release build-essential

# ----------------------------
# 安装 nginx (nginx.org) — 若已是 nginx.org 版跳过
# ----------------------------
echo "[2/10] 安装/确认 nginx (从 nginx.org 官方源，确保 stream 支持)..."
NGINX_SRC=$(apt-cache policy nginx | sed -n '2p' | awk '{print $2}')
if apt policy nginx | grep -q "http://nginx.org/packages/ubuntu"; then
  echo "检测到 nginx 来自 nginx.org，跳过源安装。"
else
  echo "添加 nginx.org 官方源并安装 nginx..."
  apt purge -y nginx nginx-common nginx-core || true
  rm -rf /etc/nginx || true

  curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
    | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null

  echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" \
    | tee /etc/apt/sources.list.d/nginx.list

  apt update -y
  apt install -y nginx
fi

# 确认 nginx 支持 stream
if nginx -V 2>&1 | grep -q -- '--with-stream'; then
  echo "nginx 支持 stream，继续。"
else
  echo "错误：nginx 未启用 stream。请检查 nginx 包来源。"
  exit 1
fi

systemctl enable nginx || true

# ----------------------------
# 防火墙（按你要求放行）
# ----------------------------
echo "[3/10] 配置 ufw 防火墙（放行 22,80,443,25500,53,8445,8380,50913,6220,62203）..."
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 25500
ufw allow 53
ufw allow 8445
ufw allow 8380
ufw allow 50913
ufw allow 6220
ufw allow 62203
ufw --force enable

# ----------------------------
# 安装 acme.sh（不 source .bashrc，使用绝对路径）
# ----------------------------
echo "[4/10] 安装 acme.sh（用于 DNS-01）..."
ACME_SH="$HOME/.acme.sh/acme.sh"
if [ ! -f "$ACME_SH" ]; then
  curl -fsSL https://get.acme.sh | sh
fi
if [ ! -x "$ACME_SH" ]; then
  echo "acme.sh 安装失败或不可执行 ($ACME_SH)。"
  exit 1
fi

# 设置 letsencrypt 为默认 CA
"$ACME_SH" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

# ----------------------------
# 申请/安装证书（DNS-01 via Cloudflare） —— 幂等：若证书已存在则跳过
# ----------------------------
echo "[5/10] 检查并申请 SSL 证书..."
mkdir -p "$CERT_DIR"

if [ -f "$CERT_DIR/fullchain.pem" ] && [ -f "$CERT_DIR/key.pem" ]; then
  echo "已存在证书：$CERT_DIR/fullchain.pem，跳过申请。"
else
  echo "使用 Cloudflare DNS 验证申请证书（DNS-01）..."
  # 导出 token 供 acme.sh 使用
  export CF_Token="$CF_TOKEN"
  export CF_Email="$CF_EMAIL"

  # 执行 issue（若失败会退出）
  "$ACME_SH" --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256

  # 安装到指定目录
  "$ACME_SH" --install-cert -d "$DOMAIN" \
    --ecc \
    --key-file "$CERT_DIR/key.pem" \
    --fullchain-file "$CERT_DIR/fullchain.pem" \
    --reloadcmd "systemctl reload nginx" || true

  echo "证书已写入：$CERT_DIR"
fi

# ----------------------------
# 部署 SubConverter 后端 （幂等）
# ----------------------------
echo "[6/10] 部署 SubConverter 后端..."
mkdir -p "$SUBCONV_DIR"
if [ ! -x "$SUBCONV_DIR/subconverter" ]; then
  echo "下载 SubConverter 可执行文件..."
  wget -q -O "$SUBCONV_DIR/subconverter" "$SUBCONVERTER_BIN_URL" || {
    echo "下载 SubConverter 失败，检查网络或 URL。"
    exit 1
  }
  chmod +x "$SUBCONV_DIR/subconverter"
fi

# systemd service
if [ ! -f /etc/systemd/system/subconverter.service ]; then
  cat >/etc/systemd/system/subconverter.service <<'SVC'
[Unit]
Description=SubConverter
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/subconverter
ExecStart=/opt/subconverter/subconverter
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SVC
  systemctl daemon-reload
  systemctl enable --now subconverter
else
  systemctl restart subconverter || true
fi

# ----------------------------
# 部署 sub-web-modify（克隆 + 构建） 幂等
# ----------------------------
echo "[7/10] 克隆并构建 sub-web-modify（$SUBWEB_REPO）..."
rm -rf "$SUBWEB_SRC"
git clone "$SUBWEB_REPO" "$SUBWEB_SRC"

# Ensure publicPath for /sub/
cat >"$SUBWEB_SRC/vue.config.js" <<'VCONF'
module.exports = { publicPath: '/sub/' }
VCONF

# Node.js check (>=18 recommended). Install Node 18 if missing.
if command -v node >/dev/null 2>&1; then
  NODE_VER_MAJOR=$(node -v | sed 's/v\([0-9]*\).*/\1/')
else
  NODE_VER_MAJOR=0
fi

if [ "$NODE_VER_MAJOR" -lt 18 ]; then
  echo "安装 Node.js 18 (NodeSource)..."
  curl -fsSL https://deb.nodesource.com/setup_18.x | bash - >/dev/null 2>&1 || true
  apt install -y nodejs
fi

cd "$SUBWEB_SRC"
# 安装依赖并构建（npm install 可能很慢）
npm install --no-audit --no-fund || true
npm run build || true

# Copy built dist to /opt/sub-web (serve from here)
rm -rf "$SUBWEB_DIST"
mkdir -p "$SUBWEB_DIST"
if [ -d "$SUBWEB_SRC/dist" ]; then
  cp -r "$SUBWEB_SRC/dist/"* "$SUBWEB_DIST/"
else
  echo "[WARN] 构建未生成 dist/，请检查构建日志： npm run build"
fi
chown -R www-data:www-data "$SUBWEB_DIST" || true

# ----------------------------
# Search 首页（带右上角订阅入口）
# ----------------------------
echo "[8/10] 创建 Search 首页..."
mkdir -p "$WEB_ROOT"
cat >"$WEB_ROOT/index.html" <<HTML
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Search</title>
<style>
body{margin:0;display:flex;justify-content:center;align-items:center;height:100vh;font-family:sans-serif}
.box{text-align:center}
input{width:420px;padding:12px;font-size:16px}
a{position:fixed;top:20px;right:30px;text-decoration:none}
</style>
</head>
<body>
<a href="/sub/">订阅转换</a>
<div class="box">
<form action="https://www.bing.com/search" method="get">
<input name="q" placeholder="Search with Bing">
</form>
</div>
</body>
</html>
HTML
chown -R www-data:www-data "$WEB_ROOT" || true

# ----------------------------
# 写入 nginx 主配置（stream + http），备份旧配置（幂等）
# ----------------------------
echo "[9/10] 备份并写入 nginx 配置（stream + http，443 SNI 分流）..."
NGINX_CONF="/etc/nginx/nginx.conf"
BACKUP_DIR="/root/nginx-backup-$(date +%s)"
mkdir -p "$BACKUP_DIR"
if [ -f "$NGINX_CONF" ]; then
  cp -a "$NGINX_CONF" "$BACKUP_DIR/nginx.conf.bak"
fi

cat >"$NGINX_CONF" <<NGC
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

stream {
    # 按 SNI 分流：$DOMAIN -> web_backend, www.51kankan.vip -> reality_backend
    map \$ssl_preread_server_name \$backend {
        $DOMAIN            web_backend;
        www.51kankan.vip   reality_backend;
        default            web_backend;
    }

    upstream web_backend {
        server 127.0.0.1:$WEB_BACKEND_PORT;
    }

    upstream reality_backend {
        server 127.0.0.1:$REALITY_PORT;
    }

    server {
        listen 443 reuseport;
        proxy_pass \$backend;
        ssl_preread on;
    }
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile on;
    keepalive_timeout 65;

    server {
        listen $WEB_BACKEND_PORT ssl http2;
        server_name $DOMAIN;

        ssl_certificate     $CERT_DIR/fullchain.pem;
        ssl_certificate_key $CERT_DIR/key.pem;

        # Search 首页
        location / {
            root $WEB_ROOT;
            index index.html;
        }

        # sub-web 前端
        location /sub/ {
            alias $SUBWEB_DIST/;
            index index.html;
            try_files \$uri \$uri/ /index.html;
        }

        # SubConverter API
        location /sub/api/ {
            proxy_pass http://127.0.0.1:25500/;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
}
NGC

# 测试并启动 nginx（如果已启动则重载）
echo "[10/10] 测试 nginx 配置并启动/重载..."
nginx -t
if systemctl is-active --quiet nginx; then
  systemctl reload nginx
else
  systemctl start nginx
fi

# ----------------------------
# 安装 S-UI（面板，仅本机监听），幂等尝试
# ----------------------------
echo "[11/11] 安装 S-UI 面板（若已安装则跳过）..."
# check common s-ui service path (installer creates /usr/local/bin/sui or systemd)
if ! systemctl list-units --type=service | grep -q 'sub-api\|s-ui\|sui'; then
  bash -c "$(curl -fsSL $SUI_INSTALLER)" || true
  echo "请通过 SSH 隧道访问 S-UI: ssh -L 2095:127.0.0.1:2095 root@<your-ip>"
else
  echo "检测到已安装的 S-UI 服务，跳过安装。"
fi

# ----------------------------
# 最终信息
# ----------------------------
echo
echo "========================================"
echo "部署完成 ✅"
echo "• Search 首页: https://$DOMAIN"
echo "• 订阅转换 UI: https://$DOMAIN/sub/?backend=https://$DOMAIN/sub/api/"
echo "• SubConverter API: http://127.0.0.1:25500 (本机访问)"
echo "• S-UI 面板: 通过 SSH 隧道访问 http://127.0.0.1:2095 (ssh -L 2095:127.0.0.1:2095 root@<ip>)"
echo "• Reality: 在 S-UI 中创建，监听地址请设置为 127.0.0.1:$REALITY_PORT，SNI 可填 www.51kankan.vip"
echo "========================================"
