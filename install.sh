#!/usr/bin/env bash
set -e
echo "===== VPS Full Stack Deployment ====="

# Step 1: Input your domain and Cloudflare credentials
read -rp "Please enter your domain (e.g., web.mycloudshare.org): " DOMAIN
read -rp "Please enter your Cloudflare email: " CF_Email
read -rp "Please enter your Cloudflare API Token: " CF_Token
export CF_Email
export CF_Token

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

# Copy the certificates to /root and ensure they are updated
echo "[5/12] Copy updated certificates to /root"
cp -f /etc/nginx/ssl/$DOMAIN/fullchain.pem /root/
cp -f /etc/nginx/ssl/$DOMAIN/key.pem /root/

echo "[6/12] Install SubConverter Backend"
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

echo "[7/12] Install Node.js (LTS)"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

echo "[8/12] Build sub-web-modify (from about300 repo)"
rm -rf /opt/sub-web-modify
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify
npm install
npm run build

# Add 'Enter Sub-Web' link to homepage
echo "[9/12] Add 'Enter Sub-Web' link to homepage"
echo '<a href="/subconvert/" style="position: absolute; top: 10px; right: 20px; padding: 10px; background-color: #008CBA; color: white; border-radius: 5px; text-decoration: none;">Enter Sub-Web</a>' >> /opt/web-home/current/index.html

echo "[10/12] Install S-UI Panel (only local listening)"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

echo "[11/12] Configure Nginx for Web and API"
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    # Home Page: Point to Web Content and support search functionality
    root /opt/web-home/current;
    index index.html;
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Sub-Web: Point to Sub-Web's build files
    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        try_files \$uri \$uri/ /subconvert/index.html;
    }

    # SubConverter Backend: Proxy to local SubConverter service
    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }

    # VLESS 订阅：通过反向代理将流量转发到 S-UI 中设置的 VLESS 服务
    location /vless/ {
        proxy_pass http://127.0.0.1:5000;  # 反向代理到本地 VLESS 服务
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t
systemctl reload nginx

echo "[12/12] Install AdGuard Home (Port 3000)"
curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh

echo "[13/12] Finish 🎉"
echo "====================================="
echo "Web Home: https://$DOMAIN"
echo "SubConverter API: https://$DOMAIN/sub/api/"
echo "S-UI Panel: http://127.0.0.1:2095"
echo "====================================="

# Final reminder
echo "===== Deployment Complete ====="
echo "✅ Your VPS is now fully set up with the following services:"
echo "- Web Home: https://$DOMAIN (Main Page)"
echo "- Sub-Web: https://$DOMAIN/subconvert/ (Sub-Web Frontend)"
echo "- SubConverter API: https://$DOMAIN/sub/api/ (Backend API)"
echo "- S-UI Panel: http://127.0.0.1:2095 (Control Panel for VLESS)"
echo "- AdGuard Home: http://127.0.0.1:3000 (DNS Blocking and Filtering)"

echo ""
echo "Next Steps:"
echo "1. Ensure your Cloudflare DNS settings are correct for the domain $DOMAIN."
echo "2. Verify that the VLESS service is configured correctly in the S-UI panel and is listening on 127.0.0.1:5000."
echo "3. Test the Sub-Web by visiting https://$DOMAIN/subconvert/."
echo "4. If using Cloudflare, ensure the proxy is enabled (orange cloud) for your domain."
echo "5. To access the S-UI panel, open http://127.0.0.1:2095 in your browser."

echo ""
echo "If you encounter any issues, check the logs for Nginx, SubConverter, and S-UI for further troubleshooting."
echo "Good luck, and enjoy your setup!"
