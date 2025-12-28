#!/usr/bin/env bash
set -e

echo "===== VPS 全栈部署（Nginx Stream + VLESS 共用 443）====="

read -rp "主域名（如 mycloudshare.org）: " DOMAIN
read -rp "VLESS 域名（如 vless.mycloudshare.org）: " VLESS_DOMAIN
read -rp "Cloudflare API Token: " CF_TOKEN

export CF_Token="$CF_TOKEN"

echo "[1/10] 更新系统"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx nginx-full build-essential

echo "[2/10] 防火墙"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 2095
ufw --force enable

echo "[3/10] 安装 acme.sh（Cloudflare DNS-01，Let's Encrypt）"
if [ ! -d "$HOME/.acme.sh" ]; then
  curl https://get.acme.sh | sh
fi
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

mkdir -p /etc/nginx/ssl

~/.acme.sh/acme.sh --issue \
  --dns dns_cf \
  -d "$DOMAIN" \
  -d "$VLESS_DOMAIN" \
  --keylength ec-256

~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file       /etc/nginx/ssl/key.pem \
  --fullchain-file /etc/nginx/ssl/fullchain.pem

echo "[4/10] 安装 SubConverter"
mkdir -p /opt/subconverter
cd /opt/subconverter
if [ ! -f subconverter ]; then
  wget -O subconverter https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
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

systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

echo "[5/10] 安装 Node.js LTS"
if ! command -v node >/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt install -y nodejs
fi

echo "[6/10] 构建 sub-web-modify（你的 CSS / Web 会生效）"
rm -rf /opt/sub-web-modify
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify
npm install
npm run build

echo "[7/10] 安装 S-UI（仅本地监听）"
if [ ! -d /usr/local/s-ui ]; then
  bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
fi

echo "[8/10] Nginx HTTP 配置（仅给 stream 回落用）"
cat >/etc/nginx/conf.d/web.conf <<EOF
server {
    listen 127.0.0.1:8443 ssl;
    server_name $DOMAIN;

    ssl_certificate     /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/key.pem;

    root /opt/sub-web-modify/dist;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }
}
EOF

echo "[9/10] Nginx stream（443 SNI 分流）"
cat >/etc/nginx/stream.conf <<EOF
stream {
    map \$ssl_preread_server_name \$backend {
        $VLESS_DOMAIN 127.0.0.1:4431;
        default       127.0.0.1:8443;
    }

    server {
        listen 443 reuseport;
        proxy_pass \$backend;
        ssl_preread on;
    }
}
EOF

sed -i '/stream {/d' /etc/nginx/nginx.conf
grep -q "include /etc/nginx/stream.conf;" /etc/nginx/nginx.conf || \
  sed -i '/http {/i include /etc/nginx/stream.conf;' /etc/nginx/nginx.conf

echo "[10/10] 启动服务"
nginx -t
systemctl restart nginx

echo "======================================"
echo "🎉 部署完成"
echo ""
echo "🌐 Web 主页: https://$DOMAIN"
echo "📦 Sub API : https://$DOMAIN/sub/api/"
echo "🛠 S-UI    : ssh -L 2095:127.0.0.1:2095 root@你的IP"
echo "🚀 VLESS   : 域名 $VLESS_DOMAIN（在 S-UI 里配 Reality / TLS）"
echo "======================================"
