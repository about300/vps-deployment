#!/usr/bin/env bash
set -euo pipefail

# Final interactive install.sh
# - Two domains interactive:
#   1) Web domain (homepage + /subconvert)
#   2) Reality SNI domain (must be different)
# - Uses Cloudflare DNS-01 + acme.sh (Let's Encrypt)
# - SubConverter local at 127.0.0.1:25500
# - sub-web-modify built with publicPath = /subconvert/
# - nginx stream to dispatch 443 by SNI:
#     Reality SNI -> 127.0.0.1:4433 (S-UI / Xray expected to listen here)
#     other SNI -> nginx http(s) backend (127.0.0.1:4443)
# - S-UI installed (you configure nodes manually)
# - AdGuard Home installed via official script

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root: sudo bash ./install.sh"
  exit 1
fi

read -rp "请输入用于主页的域名（例 web.mycloudshare.org）: " WEB_DOMAIN
while [[ -z "$WEB_DOMAIN" ]]; do
  read -rp "域名不能为空，请重新输入主页域名: " WEB_DOMAIN
done

read -rp "请输入用于 Reality 的子域（例 web.vl.mycloudshare.org，必须与主页不同）: " VLESS_SNI
while [[ -z "$VLESS_SNI" || "$VLESS_SNI" == "$WEB_DOMAIN" ]]; do
  echo "Reality 子域不能为空且不能与主页相同。"
  read -rp "请重新输入 Reality 子域（例如 web.vl.mycloudshare.org）: " VLESS_SNI
done

read -rp "请输入 Cloudflare 注册邮箱: " CF_EMAIL
read -rp "请输入 Cloudflare API Token (需 Zone:DNS 编辑权限): " CF_TOKEN

export CF_Email="$CF_EMAIL"
export CF_Token="$CF_TOKEN"
export ACME_SH="$HOME/.acme.sh/acme.sh"

echo
echo "=== 开始安装：Web=$WEB_DOMAIN  Reality SNI=$VLESS_SNI ==="

echo "[1/12] 更新系统并安装基础依赖..."
apt update -y
apt install -y curl wget git unzip socat cron ufw ca-certificates lsb-release gnupg build-essential

echo "[2/12] 放行防火墙端口（22,80,443,53,3000,2550,5001,8096,8445,8446）..."
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 53/tcp
ufw allow 53/udp
ufw allow 3000
ufw allow 2550
ufw allow 5001
ufw allow 8096
ufw allow 8445
ufw allow 8446
ufw --force enable

echo "[3/12] 安装或确保 Nginx（包含 stream 支持）..."
if ! nginx -v >/dev/null 2>&1; then
  # Try to install official nginx (should include stream)
  apt install -y nginx || true
fi

echo "[4/12] 安装 acme.sh 并锁定 Let's Encrypt..."
if [ ! -f "$ACME_SH" ]; then
  curl https://get.acme.sh | sh
fi
# load acme.sh
# shellcheck source=/dev/null
source "$HOME/.bashrc" 2>/dev/null || true
$HOME/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

mkdir -p /etc/nginx/ssl

echo "[5/12] 使用 Cloudflare DNS-01 申请证书（可能需要几秒 - 若已有会跳过）..."
# Issue certificate for both domains in one cert to simplify nginx
"$HOME/.acme.sh/acme.sh" --issue --dns dns_cf -d "$WEB_DOMAIN" -d "$VLESS_SNI" --keylength ec-256 --force || true

echo "[6/12] 安装证书到 /etc/nginx/ssl/"
"$HOME/.acme.sh/acme.sh" --install-cert -d "$WEB_DOMAIN" \
  --ecc \
  --key-file /etc/nginx/ssl/key.pem \
  --fullchain-file /etc/nginx/ssl/cert.pem \
  --reloadcmd "systemctl reload nginx" || true

echo "[7/12] 安装 SubConverter 后端（本地 25500）..."
if [ ! -x /opt/subconverter/subconverter ]; then
  mkdir -p /opt/subconverter
  wget -q -O /opt/subconverter/subconverter \
    https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter || {
      echo "无法下载 SubConverter 二进制，请检查网络"
      exit 1
    }
  chmod +x /opt/subconverter/subconverter
fi

cat >/etc/systemd/system/subconverter.service <<'SERVICE'
[Unit]
Description=SubConverter
After=network.target

[Service]
ExecStart=/opt/subconverter/subconverter
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now subconverter

echo "[8/12] 获取并构建 sub-web-modify（about300），设置 publicPath=/subconvert/ ..."
if [ -d /opt/sub-web-modify ]; then
  echo "已存在 /opt/sub-web-modify，尝试更新"
  cd /opt/sub-web-modify || exit 1
  git pull --rebase || true
else
  git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
  cd /opt/sub-web-modify || exit 1
fi

# Ensure publicPath is /subconvert/
cat > vue.config.js <<'VCONF'
module.exports = {
  publicPath: '/subconvert/'
}
VCONF

# install node if missing (Node 20 LTS)
if ! command -v node >/dev/null 2>&1; then
  echo "[+] 安装 Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1 || true
  apt install -y nodejs build-essential
fi

echo "[+] npm install && npm run build （可能较慢）..."
npm install --no-audit --no-fund || true
npm run build || true

# Ensure build copied
mkdir -p /opt/sub-web-deploy
rm -rf /opt/sub-web-deploy/*
cp -r /opt/sub-web-modify/dist/* /opt/sub-web-deploy/ || true
chown -R www-data:www-data /opt/sub-web-deploy

echo "[9/12] 部署首页（仿 Bing 搜索）到 /opt/web-home ..."
mkdir -p /opt/web-home
cat >/opt/web-home/index.html <<'HTML'
<!doctype html>
<html>
<head><meta charset="utf-8"><title>Search</title>
<style>
body{background:#0b1220;color:#fff;font-family:Arial,Helvetica,sans-serif}
a.top{position:fixed;right:18px;top:18px;color:#8ad}
.container{display:flex;align-items:center;justify-content:center;height:100vh}
form{width:100%}
input{width:520px;padding:14px;border-radius:999px;border:0;font-size:16px}
</style>
</head>
<body>
<a class="top" href="/subconvert/">订阅转换</a>
<div class="container">
  <form action="https://www.bing.com/search" method="get">
    <input name="q" placeholder="Search with Bing" autofocus />
  </form>
</div>
</body>
</html>
HTML

chown -R www-data:www-data /opt/web-home

echo "[10/12] 安装 S-UI 面板（本地监听）..."
if [ ! -d /usr/local/s-ui ] && [ ! -d /opt/s-ui ] ; then
  bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh) || true
fi

echo "[11/12] 安装 AdGuard Home（官方脚本）..."
if [ ! -d /opt/AdGuardHome ]; then
  curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh || true
fi

echo "[12/12] 配置 Nginx (stream + http)，并测试启动..."
# Backup old nginx.conf
if [ ! -f /etc/nginx/nginx.conf.bak.installsh ]; then
  cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak.installsh || true
fi

# Create stream.conf and include it if not included
cat >/etc/nginx/stream.conf <<STREAM
stream {
    map \$ssl_preread_server_name \$backend {
        ${VLESS_SNI} vless_backend;
        default           web_backend;
    }

    upstream vless_backend {
        server 127.0.0.1:4433;  # S-UI / Xray Reality should listen here
    }

    upstream web_backend {
        server 127.0.0.1:4443;  # nginx HTTPS backend for web & subconvert
    }

    server {
        listen 443 reuseport;
        ssl_preread on;
        proxy_pass \$backend;
    }
}
STREAM

# Ensure nginx.conf includes stream.conf at top
if ! grep -q "include /etc/nginx/stream.conf;" /etc/nginx/nginx.conf 2>/dev/null; then
  sed -i '1i include /etc/nginx/stream.conf;' /etc/nginx/nginx.conf
fi

# Create http server that listens on 4443 (internal) with SSL cert we installed
cat >/etc/nginx/conf.d/web_internal.conf <<'HTTPCONF'
server {
    listen 127.0.0.1:4443 ssl http2;
    server_name __WEB_DOMAIN__ __SUB_DOMAIN__;

    ssl_certificate /etc/nginx/ssl/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/key.pem;

    # Homepage
    location = / {
        root /opt/web-home;
        index index.html;
    }

    location /subconvert/ {
        alias /opt/sub-web-deploy/;
        index index.html;
        try_files $uri $uri/ /subconvert/index.html;
    }

    location /subconvert/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # fallback for other paths -> homepage
    location / {
        root /opt/web-home;
        index index.html;
    }
}
HTTPCONF

# Replace placeholders with actual domains
sed -i "s|__WEB_DOMAIN__|$WEB_DOMAIN|g" /etc/nginx/conf.d/web_internal.conf
sed -i "s|__SUB_DOMAIN__|$SUB_DOMAIN|g" /etc/nginx/conf.d/web_internal.conf

# Also create public-facing HTTP listener that just redirects to https (this is optional; stream handles 443)
cat >/etc/nginx/conf.d/web_public.conf <<PUB
server {
    listen 80;
    server_name $WEB_DOMAIN $SUB_DOMAIN;
    return 301 https://\$host\$request_uri;
}
PUB

# Test nginx config and restart
nginx -t || {
  echo "nginx 配置测试失败，请查看 /var/log/nginx/error.log"
  # restore backup
  cp /etc/nginx/nginx.conf.bak.installsh /etc/nginx/nginx.conf || true
  exit 1
}

systemctl restart nginx || { echo "无法启动 nginx，请检查日志"; exit 1; }

echo
echo "=== 部署完成 ==="
echo "主页: https://$WEB_DOMAIN"
echo "订阅入口: https://$WEB_DOMAIN/subconvert/ (或访问 https://$SUB_DOMAIN/ )"
echo "SubConverter 后端: http://127.0.0.1:25500 (systemd: subconverter)"
echo "S-UI 面板: 请用 SSH 隧道访问 (ssh -L 2095:127.0.0.1:2095 root@你的VPS)"
echo
echo "注意：请到 S-UI 面板手动添加 Reality 节点，监听地址请设为 127.0.0.1:4433，SNI 填写：$VLESS_SNI"
echo "客户端配置示例请告诉我，我可以生成相应模板。"
