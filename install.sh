#!/usr/bin/env bash
set -e

echo "======================================"
echo " VPS 一键部署 V3（Ubuntu 24）"
echo "======================================"

read -rp "请输入你的域名（如 girl.mycloudshare.org）: " DOMAIN
read -rp "请输入 Cloudflare 注册邮箱: " CF_EMAIL
read -rp "请输入 Cloudflare API Token: " CF_TOKEN

export CF_Email="$CF_EMAIL"
export CF_Token="$CF_TOKEN"

echo "[INFO] 更新系统 & 安装基础依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx \
  build-essential python3 python-is-python3

echo "[INFO] 防火墙放行端口"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000
ufw allow 2095
ufw allow 1:65535/tcp
ufw allow 1:65535/udp
ufw --force enable

echo "[INFO] 安装 acme.sh"
curl https://get.acme.sh | sh
source ~/.bashrc

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

echo "[INFO] 申请 SSL 证书"
~/.acme.sh/acme.sh --issue \
  --dns dns_cf \
  -d "$DOMAIN" \
  --keylength ec-256

CERT_DIR="/etc/nginx/ssl/$DOMAIN"
mkdir -p "$CERT_DIR"

~/.acme.sh/acme.sh --install-cert \
  -d "$DOMAIN" \
  --ecc \
  --key-file       "$CERT_DIR/key.pem" \
  --fullchain-file "$CERT_DIR/fullchain.pem" \
  --reloadcmd     "systemctl reload nginx"

echo "[INFO] 部署 SubConverter（about300 版本）"
mkdir -p /opt/subconverter
cd /opt/subconverter
wget -O subconverter \
  https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
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
systemctl enable subconverter
systemctl restart subconverter

echo "[INFO] 安装 Node.js 16（避免 node-sass 错误）"
curl -fsSL https://deb.nodesource.com/setup_16.x | bash -
apt install -y nodejs

echo "[INFO] 构建 Sub-Web（careywang/sub-web）"
rm -rf /opt/sub-web
git clone https://github.com/careywang/sub-web.git /opt/sub-web
cd /opt/sub-web

npm install
npm run build

echo "[INFO] 准备主站搜索主页"
mkdir -p /opt/vps-deploy
cat >/opt/vps-deploy/index.html <<EOF
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Search</title>
</head>
<body style="text-align:center;margin-top:15%">
<h2>Search</h2>
<form action="https://www.bing.com/search" method="get">
<input type="text" name="q" style="width:300px;height:30px">
<br><br>
<button type="submit">Search</button>
</form>
<br>
<a href="/sub">订阅转换</a>
</body>
</html>
EOF

echo "[INFO] 写入 Nginx 配置"
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
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

    root /opt/vps-deploy;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /sub/ {
        alias /opt/sub-web/dist/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

echo "[INFO] 安装 AdGuard Home"
curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh

echo "======================================"
echo " 部署完成"
echo "--------------------------------------"
echo "主页: https://$DOMAIN"
echo "订阅转换: https://$DOMAIN/sub"
echo "Sub API: http://127.0.0.1:25500"
echo "AdGuard Home: http://$DOMAIN:3000"
echo "ACL4SSR 默认模板:"
echo "https://raw.githubusercontent.com/about300/ACL4SSR/master/Clash/config/Online_Full_github.ini"
echo "======================================"
