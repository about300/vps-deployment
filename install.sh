#!/usr/bin/env bash
set -e

echo "===== VPS 全栈部署（Nginx Stream + Sub-web + S-UI）====="

read -rp "主域名（主页用，如 mycloudshare.org）: " DOMAIN
read -rp "子域名（VLESS 用，如 vless.mycloudshare.org）: " VLESS_DOMAIN
read -rp "Cloudflare API Token（DNS-01 申请证书）: " CF_TOKEN

export CF_Token="$CF_TOKEN"

echo "[1/10] 更新系统并安装依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw build-essential lsb-release gnupg2 apt-transport-https

echo "[2/10] 配置防火墙"
ufw allow 22
ufw allow 80
ufw allow 443
ufw --force enable

echo "[3/10] 安装 acme.sh（DNS-01）"
if [ ! -d "$HOME/.acme.sh" ]; then
  curl https://get.acme.sh | sh
fi
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

mkdir -p /etc/nginx/ssl

echo "[4/10] 申请证书（Cloudflare DNS）"
~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" -d "$VLESS_DOMAIN"
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file       /etc/nginx/ssl/key.pem \
  --fullchain-file /etc/nginx/ssl/cert.pem

echo "[5/10] 安装 nginx 官方版（带 stream 模块）"
# 卸载系统自带 nginx
apt remove -y nginx nginx-common nginx-full
# 官方源安装
curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor > /usr/share/keyrings/nginx-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" \
    > /etc/apt/sources.list.d/nginx.list
apt update -y
apt install -y nginx

echo "[6/10] 安装 Node.js LTS（用于 sub-web-modify）"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

echo "[7/10] 构建 sub-web-modify"
rm -rf /opt/sub-web-modify
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify
npm install --no-audit --no-fund
npm run build

echo "[8/10] 安装 S-UI（面板端口后续在面板里设置）"
if [ ! -d /usr/local/s-ui ]; then
  bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
fi

echo "[9/10] 配置 nginx"
mkdir -p /etc/nginx/conf.d

cat >/etc/nginx/conf.d/web.conf <<EOF
# 主域名主页 HTTP/HTTPS
server {
    listen 127.0.0.1:4443 ssl;
    server_name $DOMAIN;

    ssl_certificate     /etc/nginx/ssl/cert.pem;
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

cat >/etc/nginx/stream.conf <<EOF
stream {
    map \$ssl_preread_server_name \$backend {
        $VLESS_DOMAIN 127.0.0.1:4431;
        default 127.0.0.1:4443;
    }

    server {
        listen 443 reuseport;
        proxy_pass \$backend;
        ssl_preread on;
    }
}
EOF

# 在 nginx.conf include stream.conf
grep -q "include /etc/nginx/stream.conf;" /etc/nginx/nginx.conf || \
  sed -i '/http {/i include /etc/nginx/stream.conf;' /etc/nginx/nginx.conf

echo "[10/10] 启动 nginx"
nginx -t
systemctl restart nginx

echo "======================================"
echo "🎉 部署完成"
echo ""
echo "🌐 Web 主页: https://$DOMAIN"
echo "📦 Sub API : https://$DOMAIN/sub/api/"
echo "🛠 S-UI    : 通过面板设置端口和节点（默认本地监听）"
echo "🚀 VLESS   : 子域名 $VLESS_DOMAIN（在 S-UI 里配 Reality / TLS）"
echo "======================================"
