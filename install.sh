#!/usr/bin/env bash
set -e

echo "========================================"
echo " Ubuntu 24.04 全栈一键部署（最终版）"
echo " - Nginx 官方源（stream + http）"
echo " - 443 共用（SNI 分流）"
echo " - Reality / VLESS"
echo " - sub-web-modify"
echo " - subconverter"
echo "========================================"
echo

read -rp "请输入主域名（如 try.mycloudshare.org）: " DOMAIN
read -rp "请输入 Cloudflare 邮箱: " CF_EMAIL
read -rp "请输入 Cloudflare API Token: " CF_TOKEN

export CF_Email="$CF_EMAIL"
export CF_Token="$CF_TOKEN"

echo
echo "[1/8] 基础环境准备..."
apt update -y
apt install -y curl wget git socat cron unzip \
  ca-certificates gnupg2 lsb-release ufw

echo
echo "[2/8] 安装 nginx（官方源，支持 stream）..."

apt purge -y nginx nginx-common nginx-core || true
rm -rf /etc/nginx

curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
  | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null

echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/ubuntu noble nginx" \
| tee /etc/apt/sources.list.d/nginx.list

apt update -y
apt install -y nginx

nginx -V 2>&1 | grep stream >/dev/null || {
  echo "❌ nginx 未启用 stream，终止"
  exit 1
}

systemctl enable nginx

echo
echo "[3/8] 安装 acme.sh（Cloudflare DNS）..."

curl https://get.acme.sh | sh
source ~/.bashrc

echo
echo "[4/8] 申请证书..."
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

~/.acme.sh/acme.sh --issue --dns dns_cf \
  -d "$DOMAIN" \
  --keylength ec-256

mkdir -p /etc/nginx/ssl
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --ecc \
  --key-file /etc/nginx/ssl/key.pem \
  --fullchain-file /etc/nginx/ssl/cert.pem \
  --reloadcmd "systemctl reload nginx"

echo
echo "[5/8] 写入 nginx 配置（stream + http + SNI）..."

cat >/etc/nginx/nginx.conf <<'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

stream {
    map $ssl_preread_server_name $backend {
        DOMAIN_PLACEHOLDER vless;
        default             web;
    }

    upstream vless {
        server 127.0.0.1:10000;
    }

    upstream web {
        server 127.0.0.1:8443;
    }

    server {
        listen 443 reuseport;
        proxy_pass $backend;
        ssl_preread on;
    }
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile on;
    keepalive_timeout 65;

    server {
        listen 8443 ssl;
        server_name DOMAIN_PLACEHOLDER;

        ssl_certificate     /etc/nginx/ssl/cert.pem;
        ssl_certificate_key /etc/nginx/ssl/key.pem;

        root /opt/sub-web/dist;
        index index.html;

        location / {
            try_files $uri $uri/ /index.html;
        }
    }
}
EOF

sed -i "s/DOMAIN_PLACEHOLDER/$DOMAIN/g" /etc/nginx/nginx.conf

nginx -t
systemctl restart nginx

echo
echo "[6/8] 安装 sub-web-modify..."

apt install -y nodejs npm
rm -rf /opt/sub-web
git clone https://github.com/about300/sub-web-modify.git /opt/sub-web
cd /opt/sub-web
npm install
npm run build

echo
echo "[7/8] 安装 subconverter..."

mkdir -p /opt/subconverter
cd /opt/subconverter
wget -O subconverter.tar.gz https://github.com/tindy2013/subconverter/releases/latest/download/subconverter_linux64.tar.gz
tar xzf subconverter.tar.gz

cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/subconverter
ExecStart=/opt/subconverter/subconverter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

echo
echo "[8/8] 防火墙配置..."

ufw allow 22
ufw allow 443
ufw --force enable

echo
echo "========================================"
echo " 🎉 部署完成"
echo
echo " Web 面板: https://$DOMAIN"
echo " 443 已启用 SNI 分流"
echo " Reality / VLESS 请在 s-ui 中监听 127.0.0.1:10000"
echo "========================================"
