#!/bin/bash
set -e

# 1. Prompt for domain and Cloudflare API credentials
read -p "Main domain (e.g. web.example.com): " domain
read -p "Cloudflare Email: " cf_email
read -p "Cloudflare API Token: " cf_token

# 2. Install Nginx and Xray-core
sudo apt update
sudo apt install -y nginx curl socat git build-essential nodejs npm

# 3. Clone and Deploy the Web Homepage (with search bar)
sudo mkdir -p /var/www/html
sudo chown -R www-data:www-data /var/www/html
if [ ! -d /opt/vps-deployment ]; then
    sudo git clone https://github.com/about300/vps-deployment.git /opt/vps-deployment
fi
sudo cp -r /opt/vps-deployment/web/* /var/www/html/
sudo chown -R www-data:www-data /var/www/html

# 4. Install SubConverter backend (without Docker)
sudo mkdir -p /opt/subconverter
cd /opt/subconverter
sudo wget -O subconverter https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
sudo chmod +x subconverter

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

sudo systemctl daemon-reload
sudo systemctl enable subconverter
sudo systemctl start subconverter

# 5. Build sub-web-modify frontend without Docker
cd /opt
git clone https://github.com/about300/sub-web-modify.git /opt/sub-web-modify
cd /opt/sub-web-modify
sudo npm install
sudo npm run build

# 6. Install S-UI (local-only)
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# 7. Obtain TLS certificates using acme.sh with Cloudflare DNS-01
export CF_Email="$cf_email"
export CF_Token="$cf_token"
sudo mkdir -p /etc/nginx/ssl
~/.acme.sh/acme.sh --issue -d "$domain" --dns dns_cf  # Issue cert via DNS-01 (Cloudflare)
~/.acme.sh/acme.sh --install-cert -d "$domain" \
    --key-file /etc/nginx/ssl/$domain.key \
    --fullchain-file /etc/nginx/ssl/$domain.crt \
    --reloadcmd "systemctl reload nginx"

# 8. Configure Nginx:
sudo tee /etc/nginx/conf.d/$domain.conf > /dev/null <<EOF
server {
    listen 80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name $domain;

    ssl_certificate     /etc/nginx/ssl/$domain/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$domain/key.pem;

    root /var/www/html;
    index index.html;

    # Proxy /subconvert to the SubConverter frontend
    location /subconvert/ {
        proxy_pass http://127.0.0.1:8090/;
    }
}
EOF

# Test and restart nginx
sudo nginx -t
sudo systemctl restart nginx

# 9. Configure Xray (VLESS on port 443 with TLS and fallback to Nginx)
uuid=$(xray uuid)
sudo tee /usr/local/etc/xray/config.json > /dev/null <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$uuid", "level": 0, "flow": "xtls-rprx-direct" }],
      "decryption": "none",
      "fallbacks": [
        { "alpn": "h2", "dest": 20002, "xver": 1 }
      ]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{ 
          "certificateFile": "/etc/nginx/ssl/$domain.crt",
          "keyFile": "/etc/nginx/ssl/$domain.key"
        }]
      }
    }
  }]
}
EOF

# Restart Xray
sudo systemctl restart xray

# 10. Configure UFW firewall (allow required ports)
sudo ufw allow 22        # SSH
sudo ufw allow 53        # DNS (AdGuard)
sudo ufw allow 80        # HTTP
sudo ufw allow 443       # HTTPS/VLESS
sudo ufw allow 3000      # AdGuard Home UI
sudo ufw allow 25500     # SubConverter backend
sudo ufw allow 8445      # (if needed)
sudo ufw allow 8446      # (if needed)
sudo ufw --force enable

# 11. Enable services on boot (Nginx, Xray, AdGuard, S-UI are set by their installers)
sudo systemctl enable nginx
sudo systemctl enable xray
sudo systemctl enable AdGuardHome
sudo systemctl enable s-ui

echo "Setup complete! Access the homepage at https://$domain and the SubConverter UI at https://$domain/subconvert"
