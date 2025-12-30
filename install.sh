#!/bin/bash

# 1. Prompt for domain and Cloudflare API credentials
read -p "Main domain (e.g. web.example.com): " domain
read -p "Cloudflare Email: " cf_email
read -p "Cloudflare Global API Token: " cf_token

# 2. Install Nginx (with HTTP + stream modules) and Xray-core
#    (Nginx and Xray can be installed via apt and the official Xray script:contentReference[oaicite:0]{index=0})
sudo apt update
sudo apt install -y nginx curl socat
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install  # Install Xray-core:contentReference[oaicite:1]{index=1}

# 3. Clone and deploy the web homepage (with search bar)
#    (Using the about300/vps-deployment web frontend as the homepage)
sudo mkdir -p /var/www/html
sudo chown -R www-data:www-data /var/www/html
if [ ! -d /opt/vps-deployment ]; then
    sudo apt install -y git
    sudo git clone https://github.com/about300/vps-deployment.git /opt/vps-deployment
fi
sudo cp -r /opt/vps-deployment/web/* /var/www/html/
sudo chown -R www-data:www-data /var/www/html

# 4. Deploy Subscription Converter front-end (sub-web-modify) via Docker:contentReference[oaicite:2]{index=2}
#    and run SubConverter backend on port 25500
sudo apt install -y docker.io
sudo docker run -d --restart always -p 8090:80 --name sub-web-modify youshandefeiyang/sub-web-modify  # front-end on localhost:8090:contentReference[oaicite:3]{index=3}
sudo docker run -d --restart always -p 25500:25500 --name subconverter tindy2013/subconverter  # backend on port 25500

# 5. Install AdGuard Home (DNS/anti-ad service) on port 3000:contentReference[oaicite:4]{index=4}
#    (Download the latest release and install as a service)
AGH_VERSION=$(curl -s https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
wget -O AdGuardHome.tar.gz https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz
tar xzf AdGuardHome.tar.gz
cd AdGuardHome
sudo ./AdGuardHome -s install  # Install AdGuardHome as a system service:contentReference[oaicite:5]{index=5}
cd ..
rm AdGuardHome.tar.gz

# 6. Install S-UI panel (local-only) using the official install script:contentReference[oaicite:6]{index=6}
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# 7. Obtain TLS certificates using acme.sh with Cloudflare DNS-01:contentReference[oaicite:7]{index=7}:contentReference[oaicite:8]{index=8}
export CF_Email="$cf_email"
export CF_Token="$cf_token"
sudo mkdir -p /etc/nginx/ssl
~/.acme.sh/acme.sh --issue -d "$domain" --dns dns_cf  # Issue cert via DNS-01 (Cloudflare):contentReference[oaicite:9]{index=9}
~/.acme.sh/acme.sh --install-cert -d "$domain" \
    --key-file /etc/nginx/ssl/$domain.key \
    --fullchain-file /etc/nginx/ssl/$domain.crt \
    --reloadcmd "systemctl reload nginx"  # Install cert for Nginx (auto-reload):contentReference[oaicite:10]{index=10}

# 8. Configure Nginx:
#    - Redirect HTTP→HTTPS
#    - Serve web and proxy /subconvert to Docker
sudo tee /etc/nginx/conf.d/$domain.conf > /dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}
server {
    # Listen only on localhost for Xray fallback (HTTP/2 with PROXY protocol)
    listen 127.0.0.1:20002 http2 proxy_protocol;
    server_name $domain;
    root /var/www/html;
    index index.html;

    # Proxy /subconvert to the SubConverter frontend container
    location /subconvert/ {
        proxy_pass http://127.0.0.1:8090/;
    }
}
EOF
sudo nginx -t
sudo systemctl restart nginx

# 9. Configure Xray (VLESS on port 443 with TLS and fallback to Nginx)
#    Generate a UUID for the VLESS client
uuid=$(xray uuid)
#    Write Xray config to use port 443, TLS with our cert, and fallback to 127.0.0.1:20002 for web traffic.
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
sudo systemctl restart xray

# 10. Configure UFW firewall (allow required ports):contentReference[oaicite:11]{index=11}
sudo ufw allow 22        # SSH:contentReference[oaicite:12]{index=12}
sudo ufw allow 53        # DNS (AdGuard)
sudo ufw allow 80        # HTTP
sudo ufw allow 443       # HTTPS/VLESS
sudo ufw allow 3000      # AdGuard Home UI
sudo ufw allow 25500     # SubConverter backend
sudo ufw allow 8445      # (if needed, as per spec)
sudo ufw allow 8446      # (if needed)
sudo ufw allow 5001      # (if needed)
sudo ufw allow 8096      # (if needed)
sudo ufw --force enable

# 11. Enable services on boot (Nginx, Xray, AdGuard, S-UI are set by their installers)
sudo systemctl enable nginx
sudo systemctl enable xray
sudo systemctl enable AdGuardHome
sudo systemctl enable s-ui
