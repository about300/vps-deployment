#!/usr/bin/env bash
set -e

### ===== 基础检查 =====
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 运行"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

### ===== 交互输入 =====
while true; do
  read -rp "请输入主域名（如 money.mycloudshare.org）: " DOMAIN
  [[ -n "$DOMAIN" ]] && break
done

read -rp "请输入订阅前缀（回车默认 sub）: " SUB_PREFIX
SUB_PREFIX=${SUB_PREFIX:-sub}
SUB_DOMAIN="${SUB_PREFIX}.${DOMAIN}"

read -rp "请输入 Cloudflare 邮箱: " CF_EMAIL
read -rp "请输入 Cloudflare API Token: " CF_TOKEN

### ===== 常量 =====
WEB_ROOT=/var/www/web
SUBWEB_ROOT=/var/www/sub-web
SUBCONVERTER_DIR=/opt/subconverter
NGINX_SSL=/etc/nginx/ssl
STREAM_PORT_REALITY=10000
HTTP_BACKEND_PORT=8443

### ===== 1. 系统依赖 =====
apt update -y
apt install -y curl wget git socat cron ufw ca-certificates gnupg lsb-release

### ===== 2. 防火墙 =====
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 53
ufw allow 2550
ufw allow 8445
ufw allow 8380
ufw allow 50913
ufw allow 6220
ufw allow 62203
ufw --force enable

### ===== 3. 安装 Nginx（官方源，内置 stream）=====
if ! command -v nginx >/dev/null; then
  curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx.gpg
  echo "deb [signed-by=/usr/share/keyrings/nginx.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" \
    > /etc/apt/sources.list.d/nginx.list
  apt update -y
  apt install -y nginx
fi

### ===== 4. acme.sh =====
if [ ! -d ~/.acme.sh ]; then
  curl https://get.acme.sh | sh
fi

export CF_Email="$CF_EMAIL"
export CF_Token="$CF_TOKEN"

mkdir -p "$NGINX_SSL"

~/.acme.sh/acme.sh --issue \
  --dns dns_cf \
  -d "$DOMAIN" \
  --keylength ec-256 \
  --force || true

~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --ecc \
  --key-file "$NGINX_SSL/key.pem" \
  --fullchain-file "$NGINX_SSL/cert.pem" \
  --reloadcmd "systemctl restart nginx" || true

### ===== 5. Web 首页 =====
mkdir -p "$WEB_ROOT"
cat > "$WEB_ROOT/index.html" <<EOF
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>$DOMAIN</title>
<style>
body{background:#0b1220;color:#fff;font-family:sans-serif}
.search{margin-top:30vh;text-align:center}
input{width:480px;padding:14px;border-radius:999px;border:0}
a{position:fixed;top:20px;right:20px;color:#8ad}
</style>
</head>
<body>
<a href="https://$SUB_DOMAIN">订阅转换</a>
<div class="search">
<form action="https://www.bing.com/search">
<input name="q" placeholder="Search with Bing">
</form>
</div>
</body>
</html>
EOF

### ===== 6. SubConverter（二进制）=====
mkdir -p "$SUBCONVERTER_DIR"
if [ ! -x "$SUBCONVERTER_DIR/subconverter" ]; then
  wget -O "$SUBCONVERTER_DIR/subconverter" \
    https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
  chmod +x "$SUBCONVERTER_DIR/subconverter"
fi

cat > /etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter
After=network.target

[Service]
ExecStart=$SUBCONVERTER_DIR/subconverter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now subconverter

### ===== 7. sub-web-modify =====
if [ ! -d /opt/sub-web ]; then
  git clone https://github.com/about300/sub-web-modify.git /opt/sub-web
fi

if ! command -v node >/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
  apt install -y nodejs
fi

cd /opt/sub-web
npm install --no-fund --no-audit || true
npm run build || true

mkdir -p "$SUBWEB_ROOT"
cp -r dist/* "$SUBWEB_ROOT/" || true

### ===== 8. S-UI（仅安装）=====
if ! systemctl list-units | grep -q sub-api; then
  bash <(curl -fsSL https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh) || true
fi

### ===== 9. Nginx stream + http =====
NGINX_CONF=/etc/nginx/nginx.conf

if ! grep -q "stream {" "$NGINX_CONF"; then
  sed -i '1istream {' "$NGINX_CONF"
  sed -i "2i\ \ server { listen 443 reuseport; ssl_preread on; proxy_pass 127.0.0.1:$HTTP_BACKEND_PORT; }" "$NGINX_CONF"
  sed -i '3i}' "$NGINX_CONF"
fi

cat > /etc/nginx/conf.d/web.conf <<EOF
server {
  listen $HTTP_BACKEND_PORT ssl;
  server_name $DOMAIN $SUB_DOMAIN;

  ssl_certificate $NGINX_SSL/cert.pem;
  ssl_certificate_key $NGINX_SSL/key.pem;

  root $WEB_ROOT;
  index index.html;

  location /sub/ {
    alias $SUBWEB_ROOT/;
    try_files \$uri \$uri/ /index.html;
  }
}
EOF

nginx -t
systemctl restart nginx

echo
echo "======================================"
echo " 安装完成"
echo " Web: https://$DOMAIN"
echo " Sub: https://$SUB_DOMAIN"
echo " S-UI: 本地端口，请用 SSH 隧道"
echo "======================================"
