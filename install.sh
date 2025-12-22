#!/usr/bin/env bash
set -euo pipefail

# One-shot installer: SubConverter + sub-web-modify + S-UI + AdGuard + nginx + acme.sh (dns_cf)
# Prompts: DOMAIN, Cloudflare email, Cloudflare API Token, sub-web repo (default about300).
# Run as root.

echo
echo "========================================"
echo " 一键部署：SubConverter + sub-web-modify + S-UI + AdGuard"
echo " 使用 Let’s Encrypt (acme.sh) + Cloudflare dns_cf"
echo "========================================"
echo

read -rp "请输入你的域名（例如 example.com）: " DOMAIN
read -rp "请输入 Cloudflare 注册邮箱 (用于 acme.sh): " CF_EMAIL
read -rp "请输入 Cloudflare API Token (具有 DNS 编辑权限): " CF_TOKEN
read -rp "请输入你的 sub-web-modify 仓库 HTTPS 地址（默认 https://github.com/about300/sub-web-modify.git）: " SUBWEB_REPO
SUBWEB_REPO="${SUBWEB_REPO:-https://github.com/about300/sub-web-modify.git}"

export CF_Email="$CF_EMAIL"
export CF_Token="$CF_TOKEN"

echo
echo "[INFO] 开始部署，域名: $DOMAIN"
sleep 1

# Update & basic tools
echo "[1/12] 更新 apt 和安装基础依赖..."
apt update -y
apt install -y curl wget git unzip socat cron ufw ca-certificates gnupg lsb-release build-essential

# Firewall
echo "[2/12] 配置防火墙（22,80,443,3000,8443,8445）..."
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000
ufw allow 8443
ufw allow 8445
ufw --force enable

# Install acme.sh
echo "[3/12] 安装 acme.sh..."
curl -sS https://get.acme.sh | sh
# ensure acme.sh is available in current shell
if [ -f "$HOME/.bashrc" ]; then
  # shellcheck source=/dev/null
  . "$HOME/.bashrc" || true
fi
ACME_SH="${HOME}/.acme.sh/acme.sh"
if [ ! -x "$ACME_SH" ]; then
  echo "ERROR: acme.sh 未安装或不可执行."
  exit 1
fi

# configure acme.sh for Cloudflare DNS
echo "[4/12] 配置 acme.sh 使用 Cloudflare DNS (dns_cf) 并申请 Let\'s Encrypt 证书..."
"$ACME_SH" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

CERT_DIR="/etc/nginx/ssl/$DOMAIN"
mkdir -p "$CERT_DIR"

# Set environment variables for acme.sh (acme.sh reads CF_Token/CF_Email)
export CF_Token="$CF_TOKEN"
export CF_Email="$CF_EMAIL"

# Try renew first; if fail, issue a new one
if "$ACME_SH" --renew -d "$DOMAIN" --force >/dev/null 2>&1; then
  echo "[4.1] 证书已存在或续期成功"
else
  echo "[4.2] 申请新证书（DNS-01 via Cloudflare）..."
  "$ACME_SH" --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
fi

echo "[4.3] 安装证书到 $CERT_DIR ..."
"$ACME_SH" --install-cert -d "$DOMAIN" \
  --key-file "$CERT_DIR/key.pem" \
  --fullchain-file "$CERT_DIR/fullchain.pem" \
  --reloadcmd "systemctl reload nginx" >/dev/null 2>&1 || true

# SubConverter backend
echo "[5/12] 部署 SubConverter 后端..."
mkdir -p /opt/subconverter
cd /opt/subconverter
wget -q -O subconverter https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
chmod +x subconverter || true

cat >/etc/systemd/system/subconverter.service <<'EOF'
[Unit]
Description=SubConverter Service
After=network.target

[Service]
ExecStart=/opt/subconverter/subconverter
WorkingDirectory=/opt/subconverter
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now subconverter

# Clone front-end and ensure publicPath
echo "[6/12] 克隆并构建 front-end (sub-web-modify) from: $SUBWEB_REPO"
rm -rf /opt/sub-web-src
git clone "$SUBWEB_REPO" /opt/sub-web-src

# Ensure publicPath for deployment under /sub/
cat >/opt/sub-web-src/vue.config.js <<'VCONF'
module.exports = {
  publicPath: "/sub/"
};
VCONF

# Install nvm and Node 22 (if nvm missing)
echo "[7/12] 安装 nvm 并使用 Node.js 22 构建前端（可能需要几分钟）"
export NVM_DIR="$HOME/.nvm"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.6/install.sh | bash
fi
# shellcheck source=/dev/null
if [ -s "$NVM_DIR/nvm.sh" ]; then
  . "$NVM_DIR/nvm.sh"
else
  echo "[WARN] nvm 未能加载到当前 shell 环境，继续尝试全局 node/npm（若不存在会导致构建失败）"
fi

if command -v nvm >/dev/null 2>&1; then
  nvm install 22
  nvm use 22
else
  # fallback to NodeSource (try install)
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - || true
  apt install -y nodejs || true
fi

cd /opt/sub-web-src
npm install --no-audit --no-fund || true
npm run build || true

# Copy build artifacts
echo "[8/12] 复制构建产物到 /opt/sub-web-modify/dist"
rm -rf /opt/sub-web-modify/dist
mkdir -p /opt/sub-web-modify/dist
if [ -d /opt/sub-web-src/dist ]; then
  cp -r /opt/sub-web-src/dist/* /opt/sub-web-modify/dist/
else
  echo "[WARN] 构建未产生 dist/，请手动检查 /opt/sub-web-src 构建日志。"
fi
chown -R www-data:www-data /opt/sub-web-modify/dist || true
chmod -R a+r /opt/sub-web-modify/dist || true

# Create simple Search home
echo "[9/12] 创建 Search 首页 (/opt/vps-deploy/index.html)"
mkdir -p /opt/vps-deploy
cat >/opt/vps-deploy/index.html <<HTML
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>Search</title></head>
<body style="text-align:center;margin-top:15%">
<h2>Search</h2>
<form action="https://www.bing.com/search" method="get">
<input name="q" style="width:300px;height:30px">
<br><br>
<button type="submit">Search</button>
</form>
<br><br>
<a href="/sub/?backend=https://$DOMAIN/sub/api/">进入订阅转换</a>
</body>
</html>
HTML
chown -R www-data:www-data /opt/vps-deploy || true

# AdGuard Home
echo "[10/12] 安装 AdGuard Home（3000端口）"
curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh || true

# Install S-UI
echo "[11/12] 安装 S-UI 面板（本机监听）"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh) || true

# Nginx configuration
echo "[12/12] 写入 nginx 配置并启用站点"
NGCONF="/etc/nginx/sites-available/$DOMAIN"
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
cat >"$NGCONF" <<NGCFG
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/key.pem;

    # Serve sub-web at /sub/
    location /sub/ {
        alias /opt/sub-web-modify/dist/;
        index index.html;
        try_files \$uri \$uri/ /sub/index.html;
    }

    # Simple site root -> search homepage
    location / {
        root /opt/vps-deploy;
        index index.html;
        try_files \$uri \$uri/ =404;
    }

    # SubConverter API
    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # S-UI panel reverse proxy (accessible via ssh tunnel)
    location /ui/ {
        proxy_pass http://127.0.0.1:2095/app/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # S-UI subscribes
    location /suibs/ {
        proxy_pass http://127.0.0.1:2096/;
    }
}
NGCFG

ln -sf "$NGCONF" /etc/nginx/sites-enabled/$DOMAIN
rm -f /etc/nginx/sites-enabled/default || true

echo "[INFO] 测试并重载 nginx 配置..."
nginx -t
systemctl reload nginx

echo
echo "========================================"
echo "部署完成 🎉"
echo "访问说明："
echo "• Search 首页: https://$DOMAIN"
echo "• 订阅转换 UI: https://$DOMAIN/sub/?backend=https://$DOMAIN/sub/api/"
echo "• SubConverter API: https://$DOMAIN/sub/api/"
echo "• S-UI 面板: 通过 SSH 隧道访问 127.0.0.1:2095"
echo "• AdGuard Home: http://$DOMAIN:3000"
echo "注意：请在 S-UI 面板里手动添加 Reality/VLESS 节点并配置 TLS/SNI（例如 www.51kankan.vip）"
echo "========================================"
