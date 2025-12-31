#!/usr/bin/env bash
set -e
echo "===== VPS Full Stack Deployment ====="

# Step 1: Input your domain and Cloudflare credentials
read -rp "Please enter your domain (e.g., web.mycloudshare.org): " DOMAIN
read -rp "Please enter your Cloudflare email: " CF_Email
read -rp "Please enter your Cloudflare API Token: " CF_Token
export CF_Email
export CF_Token

# Pre-define the VLESS port (change this as needed)
VLESS_PORT=5000  # You can change this to any port you prefer for VLESS

echo "[1/12] Update system and install dependencies"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3

echo "[2/12] Configure firewall"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 8443
ufw allow 3000
ufw allow 8445
ufw allow 53
ufw allow 2550
ufw --force enable

echo "[3/12] Install acme.sh for DNS-01 verification"
curl https://get.acme.sh | sh
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
mkdir -p /etc/nginx/ssl/$DOMAIN

# Use DNS-01 verification via Cloudflare
echo "[4/12] Issue SSL certificate via Cloudflare"
~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256

# Install certificate to Nginx
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
  --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
  --reloadcmd "systemctl reload nginx"

echo "[5/12] Install SubConverter Backend"
mkdir -p /opt/subconverter
cd /opt/subconverter
wget -O subconverter https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
chmod +x subconverter
cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter Service
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

echo "[6/12] Install Node.js (LTS)"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

echo "[7/12] Build sub-web-modify (from about300 repo)"
rm -rf /opt/sub-web-modify
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify
npm install
npm run build

echo "[8/12] Install S-UI Panel (only local listening)"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

echo "[9/12] Clone Web Files from GitHub"
# Clone the 'web' folder from the about300 vps-deployment repo
rm -rf /opt/web-home
git clone https://github.com/about300/vps-deployment.git /opt/web-home

# Move the web folder to its proper location
mv /opt/web-home/web /opt/web-home/current

echo "[10/12] Configure Nginx for Web and API"
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    
    ssl_certificate     /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    # 主页：指向 Web 内容并支持搜索功能
    root /opt/web-home/current;
    index index.html;
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # 订阅转换前端：指向 Sub-Web-Modify 构建的静态文件
    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        try_files \$uri \$uri/ /subconvert/index.html;
    }

    # 订阅转换后端：代理到本地 SubConverter 服务
    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }

    # VLESS 订阅：通过反向代理将流量转发到 S-UI 中设置的 VLESS 服务
    location /vless/ {
        proxy_pass http://127.0.0.1:$VLESS_PORT;  # 使用预设的端口
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }
}
EOF
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t
systemctl reload nginx

echo "[11/12] Configure DNS-01 for Let's Encrypt"
echo "[INFO] Using Cloudflare API for DNS-01"

echo "[12/12] Install AdGuard Home (Port 3000)"
curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh

echo "[13/12] Finish 🎉"
echo "====================================="
echo "Web Home: https://$DOMAIN"
echo "SubConverter API: https://$DOMAIN/sub/api/"
echo "S-UI Panel: http://127.0.0.1:2095"
echo "====================================="
