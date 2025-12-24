#!/usr/bin/env bash
set -e

echo "========================================"
echo " 全栈一键部署（最终稳定版）"
echo " - Nginx (stream + http)"
echo " - SubConverter"
echo " - sub-web-modify (about300)"
echo " - S-UI（仅安装，不暴露）"
echo " - Reality / VLESS 共用 443（SNI）"
echo "========================================"

# ===== 交互输入 =====
read -rp "请输入主域名（如 wo.mycloudshare.org）: " DOMAIN
read -rp "请输入 Cloudflare 邮箱: " CF_EMAIL
read -rp "请输入 Cloudflare API Token: " CF_TOKEN

export CF_Email="$CF_EMAIL"
export CF_Token="$CF_TOKEN"

# ===== 基础环境 =====
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx \
               nginx-module-stream \
               build-essential ca-certificates

# ===== 防火墙 =====
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

# ===== ACME =====
curl https://get.acme.sh | sh
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

mkdir -p /etc/nginx/ssl/$DOMAIN

~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256

~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
  --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
  --reloadcmd "systemctl reload nginx"

# ===== SubConverter =====
mkdir -p /opt/subconverter
cd /opt/subconverter

wget -O subconverter https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
chmod +x subconverter

cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter
After=network.target

[Service]
ExecStart=/opt/subconverter/subconverter
WorkingDirectory=/opt/subconverter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now subconverter

# ===== 前端 =====
mkdir -p /var/www

if [ ! -d /var/www/sub-web ]; then
  git clone https://github.com/about300/sub-web-modify.git /var/www/sub-web
fi

cd /var/www/sub-web

# Node 18（稳定）
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt install -y nodejs
npm install
npm run build

# ===== 搜索主页 =====
mkdir -p /var/www/search
cat >/var/www/search/index.html <<EOF
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
<form action="https://www.bing.com/search">
<input name="q" placeholder="Search with Bing">
</form>
</div>
</body>
</html>
EOF

# ===== Nginx 主配置 =====
cat >/etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;

include /etc/nginx/modules-enabled/*.conf;

events { worker_connections 1024; }

stream {
  map \$ssl_preread_server_name \$backend {
    $DOMAIN web_backend;
    www.51kankan.vip reality_backend;
    default block;
  }

  upstream web_backend {
    server 127.0.0.1:8443;
  }

  upstream reality_backend {
    server 127.0.0.1:4430;
  }

  server {
    listen 443 reuseport;
    ssl_preread on;
    proxy_pass \$backend;
  }
}

http {
  include mime.types;
  default_type application/octet-stream;
  include /etc/nginx/conf.d/*.conf;
}
EOF

# ===== Web 配置 =====
cat >/etc/nginx/conf.d/web.conf <<EOF
server {
  listen 80;
  server_name $DOMAIN;
  return 301 https://\$host\$request_uri;
}

server {
  listen 8443 ssl http2;
  server_name $DOMAIN;

  ssl_certificate /etc/nginx/ssl/$DOMAIN/fullchain.pem;
  ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

  location / {
    root /var/www/search;
    index index.html;
  }

  location /sub/ {
    root /var/www/sub-web/dist;
    try_files \$uri \$uri/ /index.html;
  }

  location /sub/api/ {
    proxy_pass http://127.0.0.1:25500/;
  }
}
EOF

nginx -t
systemctl restart nginx

# ===== S-UI =====
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

echo "========================================"
echo " 🎉 部署完成"
echo " Web:        https://$DOMAIN"
echo " 订阅转换:  https://$DOMAIN/sub/"
echo " 后端:      https://$DOMAIN/sub/api/"
echo " S-UI:      仅本地 2095（SSH 隧道访问）"
echo " Reality:   SNI = www.51kankan.vip"
echo "========================================"
