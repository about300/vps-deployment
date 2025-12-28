#!/usr/bin/env bash
set -e

echo "=================================================="
echo " VPS 全栈最终部署（443 共用 / Stream + Reality）"
echo " Ubuntu 24.04 / Cloudflare DNS-01 / Let's Encrypt"
echo "=================================================="

### ============ 交互 ============
read -rp "请输入主域名（如 mycloudshare.org）: " DOMAIN
read -rp "请输入 VLESS SNI 子域名（如 img.mycloudshare.org）: " VLESS_SNI
read -rp "请输入 Cloudflare 邮箱: " CF_Email
read -rp "请输入 Cloudflare API Token: " CF_Token

export CF_Email
export CF_Token

### ============ 基础 ============
echo "[1/10] 安装基础依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw \
               nginx nodejs npm \
               build-essential ca-certificates

### ============ 防火墙 ============
echo "[2/10] 配置防火墙"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 53
ufw allow 3000
ufw allow 2550
ufw allow 5001
ufw allow 8096
ufw allow 8445
ufw allow 8446
ufw --force enable

### ============ acme.sh ============
echo "[3/10] 安装 acme.sh（DNS-01）"
if [ ! -d ~/.acme.sh ]; then
  curl https://get.acme.sh | sh
fi
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

mkdir -p /etc/nginx/ssl

echo "[4/10] 申请证书（$DOMAIN / $VLESS_SNI）"
~/.acme.sh/acme.sh --issue \
  --dns dns_cf \
  -d "$DOMAIN" \
  -d "$VLESS_SNI" \
  --keylength ec-256 \
  --force

~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file       /etc/nginx/ssl/key.pem \
  --fullchain-file /etc/nginx/ssl/cert.pem

### ============ SubConverter ============
echo "[5/10] 安装 SubConverter"
if [ ! -f /opt/subconverter/subconverter ]; then
  mkdir -p /opt/subconverter
  cd /opt/subconverter
  wget -O subconverter \
    https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
  chmod +x subconverter
fi

cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter
After=network.target

[Service]
ExecStart=/opt/subconverter/subconverter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl enable subconverter
systemctl restart subconverter

### ============ sub-web-modify ============
echo "[6/10] 构建 sub-web-modify（about300）"
if [ ! -d /opt/sub-web-modify ]; then
  git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
  cd /opt/sub-web-modify
  npm install
  npm run build
fi

### ============ S-UI ============
echo "[7/10] 安装 S-UI（本地监听）"
if ! command -v s-ui >/dev/null; then
  bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
fi

### ============ AdGuard ============
echo "[8/10] 安装 AdGuard Home"
if [ ! -d /opt/AdGuardHome ]; then
  curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh
fi

### ============ Nginx ============
echo "[9/10] 配置 Nginx（http + stream）"

cat >/etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
events { worker_connections 1024; }

stream {
    map \$ssl_preread_server_name \$backend {
        $VLESS_SNI 127.0.0.1:8443;
        default   127.0.0.1:4443;
    }

    server {
        listen 443;
        ssl_preread on;
        proxy_pass \$backend;
    }
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile on;

    server {
        listen 80;
        server_name $DOMAIN;
        return 301 https://\$host\$request_uri;
    }

    server {
        listen 4443 ssl http2;
        server_name $DOMAIN;

        ssl_certificate     /etc/nginx/ssl/cert.pem;
        ssl_certificate_key /etc/nginx/ssl/key.pem;

        root /opt/sub-web-modify/dist;
        index index.html;

        location / {
            try_files \$uri \$uri/ /index.html;
        }

        location /sub/api/ {
            proxy_pass http://127.0.0.1:2550/;
            proxy_set_header Host \$host;
            proxy_set_header X-Forwarded-For \$remote_addr;
        }
    }
}
EOF

nginx -t
systemctl restart nginx

echo "[10/10] 部署完成 🎉"
echo "----------------------------------"
echo "主页：https://$DOMAIN"
echo "订阅：https://$DOMAIN/sub"
echo "SubConverter：https://$DOMAIN/sub/api"
echo "AdGuard：http://$DOMAIN:3000"
echo "S-UI：ssh -L 2095:127.0.0.1:2095 root@服务器IP"
echo "VLESS Reality SNI：$VLESS_SNI"
echo "----------------------------------"
