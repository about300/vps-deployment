#!/usr/bin/env bash
set -e

# 1. Prompt for domain and Cloudflare API credentials
read -p "请输入主域名（如 web.mycloudshare.org）: " DOMAIN
read -p "请输入 Cloudflare 邮箱: " CF_EMAIL
read -p "请输入 Cloudflare API Token: " CF_TOKEN

# 2. Update system and install dependencies
echo "[1/9] 更新系统"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3 nodejs npm

# 3. Firewall setup
echo "[2/9] 配置防火墙"
ufw allow 22        # SSH
ufw allow 80        # HTTP
ufw allow 443       # HTTPS/VLESS
ufw allow 3000      # AdGuard Home UI
ufw allow 25500     # SubConverter backend
ufw allow 8445      # (if needed)
ufw allow 8446      # (if needed)
ufw --force enable

# 4. Install acme.sh and obtain SSL certificate (Let’s Encrypt)
echo "[3/9] 安装 acme.sh 并获取 SSL 证书"
curl https://get.acme.sh | sh
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
mkdir -p /etc/nginx/ssl/$DOMAIN
~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone || true
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
  --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
  --reloadcmd "systemctl reload nginx"

# 5. Install SubConverter backend (without Docker)
echo "[4/9] 安装 SubConverter 后端"
mkdir -p /opt/subconverter
cd /opt/subconverter
wget -O subconverter https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
chmod +x subconverter

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
systemctl start subconverter

# 6. Build sub-web-modify frontend
echo "[5/9] 构建 sub-web-modify 前端"
cd /opt
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify
npm install
npm run build

# 7. Install S-UI (for managing VLESS nodes and settings)
echo "[6/9] 安装 S-UI 面板"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# 8. Install AdGuard Home for DNS filtering
echo "[7/9] 安装 AdGuard Home"
curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh

# 9. Configure Nginx (HTTP/HTTPS and reverse proxy)
echo "[8/9] 配置 Nginx"
cat >/etc/nginx/sites-available/$DOMAIN.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    root /var/www/html;
    index index.html;

    # Proxy /subconvert to the SubConverter frontend
    location /subconvert/ {
        proxy_pass http://127.0.0.1:8090/;
    }

    # WebSocket proxy for VLESS (SNI-based routing)
    location /vless/ {
        proxy_pass http://127.0.0.1:443/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# Test and restart nginx
nginx -t
systemctl restart nginx

# 10. Configure Xray (VLESS and Reality)
uuid=$(xray uuid)
cat >/usr/local/etc/xray/config.json <<EOF
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
          "certificateFile": "/etc/nginx/ssl/$DOMAIN.crt",
          "keyFile": "/etc/nginx/ssl/$DOMAIN.key"
        }]
      }
    }
  }]
}
EOF

# Restart Xray
systemctl restart xray

# 11. Final configuration and services enablement
systemctl enable nginx
systemctl enable xray
systemctl enable AdGuardHome
systemctl enable s-ui

echo "配置完成！"
echo "--------------------------------------"
echo "访问主页: https://$DOMAIN"
echo "订阅转换 UI: https://$DOMAIN/subconvert"
echo "S-UI 面板: https://$DOMAIN/ui"
echo "--------------------------------------"
echo "Reality/VLESS 请在 S-UI 中设置，使用同一个域名和443端口"
