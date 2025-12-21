#!/usr/bin/env bash
set -e

echo "===== VPS ALL-IN-ONE INSTALL v2 ====="

# ========= 基础输入 =========
read -rp "请输入主域名 (如 MOMAIN): " DOMAIN
read -rp "请输入 Cloudflare API Token: " CF_Token
read -rp "请输入 Cloudflare 注册邮箱: " CF_Email

INSTALL_ADGUARD="y"

export CF_Token
export CF_Email

# ========= 基础环境 =========
apt update -y
apt install -y \
  curl wget git nginx ufw socat cron \
  nodejs npm

# ========= 防火墙 =========
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

for p in 22 443 2095 3000; do
  ufw allow ${p}/tcp
  ufw allow ${p}/udp
done

ufw --force enable

# ========= acme.sh（DNS-01，不占 80） =========
apt install -y acme.sh
acme.sh --set-default-ca --server letsencrypt

acme.sh --issue \
  --dns dns_cf \
  -d "$DOMAIN" \
  --keylength ec-256

mkdir -p /root/cert
acme.sh --install-cert \
  -d "$DOMAIN" \
  --ecc \
  --key-file       /root/cert/server.key \
  --fullchain-file /root/cert/server.crt \
  --reloadcmd "systemctl reload nginx"

# ========= Web 主站（Bing 风格） =========
rm -rf /opt/vps-deploy
git clone https://github.com/about300/vps-deployment.git /opt/vps-deploy

chown -R www-data:www-data /opt/vps-deploy
chmod -R 755 /opt/vps-deploy

# ========= subconverter（about300） =========
mkdir -p /opt/subconverter
cd /opt/subconverter

wget -O subconverter \
  https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter

chmod +x subconverter

cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=Subconverter Service
After=network.target

[Service]
Type=simple
ExecStart=/opt/subconverter/subconverter
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable --now subconverter

# ========= sub-web（careywang） =========
rm -rf /opt/sub-web
git clone https://github.com/careywang/sub-web.git /opt/sub-web
cd /opt/sub-web

npm install --legacy-peer-deps
npm run build

chown -R www-data:www-data /opt/sub-web
chmod -R 755 /opt/sub-web

# ========= Nginx =========
cat >/etc/nginx/sites-enabled/default <<EOF
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     /root/cert/server.crt;
    ssl_certificate_key /root/cert/server.key;

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
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

nginx -t
systemctl restart nginx

# ========= s-ui =========
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# ========= AdGuard Home =========
if [[ "$INSTALL_ADGUARD" == "y" ]]; then
  curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh
fi

echo
echo "===== 安装完成 ====="
echo "主页: https://${DOMAIN}"
echo "订阅转换: https://${DOMAIN}/sub"
echo "Sub 后端: http://127.0.0.1:25500/version"
echo "AdGuard Home: http://${DOMAIN}:3000"
echo "s-ui 面板: http://${DOMAIN}:2095"
