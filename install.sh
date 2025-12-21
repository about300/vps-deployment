#!/usr/bin/env bash
set -e

echo "======================================"
echo " 一键部署 enhanced SubConverter UI"
echo "======================================"

read -rp "请输入你的域名: " DOMAIN
read -rp "请输入 Cloudflare 注册邮箱: " CF_EMAIL
read -rp "请输入 Cloudflare API Token: " CF_TOKEN

export CF_Email="$CF_EMAIL"
export CF_Token="$CF_TOKEN"

apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3

ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000
ufw --force enable

curl https://get.acme.sh | sh
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256

CERT_DIR="/etc/nginx/ssl/$DOMAIN"
mkdir -p "$CERT_DIR"
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
  --key-file "$CERT_DIR/key.pem" \
  --fullchain-file "$CERT_DIR/fullchain.pem" \
  --reloadcmd "systemctl reload nginx"

# 后端
mkdir -p /opt/subconverter
cd /opt/subconverter
wget -O subconverter https://github.com/about300/vps-deployment/raw/refs/heads/main/bin/subconverter
chmod +x subconverter

cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter
After=network.target
[Service]
ExecStart=/opt/subconverter/subconverter
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

# 前端 enhanced sub-web-modify
apt install -y nodejs npm
cd /opt
rm -rf sub-web-modify
git clone https://github.com/youshandefeiyang/sub-web-modify.git
cd sub-web-modify

# 给 publicPath
cat >vue.config.js <<'EOF'
module.exports = {
  publicPath: '/sub/'
}
EOF

npm install
npm run build

echo "[INFO] 创建 Search 首页"
mkdir -p /opt/vps-deploy
cat >/opt/vps-deploy/index.html <<EOF
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

    ssl_certificate $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/key.pem;

    location / {
        root /opt/vps-deploy;
        index index.html;
    }

    location /sub/ {
        alias /opt/sub-web-modify/dist/;
        index index.html;
        try_files \$uri \$uri/ /sub/index.html;
    }

    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

echo "部署完成！访问 https://$DOMAIN/sub/?backend=https://$DOMAIN/sub/api/"
