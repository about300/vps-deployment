#!/usr/bin/env bash
set -e

echo "===== VPS 全栈部署（最终稳定版） ====="

# -----------------------------
# 交互式配置
# -----------------------------
read -rp "请输入绑定的域名 (例如 ack.mycloudshare.org): " DOMAIN

read -rp "VLESS 监听端口 (默认 5000): " VLESS_PORT
VLESS_PORT=${VLESS_PORT:-5000}

read -rp "SubConverter 后端端口 (默认 25500): " SUB_PORT
SUB_PORT=${SUB_PORT:-25500}

read -rp "AdGuard Home HTTP 端口 (默认 3000): " ADG_HTTP
ADG_HTTP=${ADG_HTTP:-3000}

read -rp "AdGuard Home HTTPS 端口 (默认 8445): " ADG_HTTPS
ADG_HTTPS=${ADG_HTTPS:-8445}

read -rp "S-UI 面板端口 (默认 2095): " SUI_PORT
SUI_PORT=${SUI_PORT:-2095}

echo ""
echo "========= 配置确认 ========="
echo "域名: $DOMAIN"
echo "VLESS: $VLESS_PORT"
echo "SubConverter: $SUB_PORT"
echo "AdGuard HTTP: $ADG_HTTP"
echo "AdGuard HTTPS: $ADG_HTTPS"
echo "S-UI: $SUI_PORT"
echo "============================"
sleep 2

# -----------------------------
# 基础环境
# -----------------------------
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx npm nodejs

# -----------------------------
# 防火墙
# -----------------------------
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow $VLESS_PORT
ufw allow $SUB_PORT
ufw allow $ADG_HTTP
ufw allow $ADG_HTTPS
ufw allow $SUI_PORT
ufw --force enable

# -----------------------------
# acme.sh + SSL
# -----------------------------
if [ ! -d "$HOME/.acme.sh" ]; then
  curl https://get.acme.sh | sh
  source ~/.bashrc
fi

mkdir -p /etc/nginx/ssl/$DOMAIN

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone

~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
  --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
  --reloadcmd "systemctl reload nginx"

# 固定拷贝到 /root（你要求的）
cp /etc/nginx/ssl/$DOMAIN/*.pem /root/

# -----------------------------
# SubConverter
# -----------------------------
mkdir -p /opt/subconverter
if [ ! -f /opt/subconverter/subconverter ]; then
  wget -O /opt/subconverter/subconverter \
    https://github.com/about300/vps-deployment/raw/refs/heads/main/bin/subconverter
  chmod +x /opt/subconverter/subconverter
fi

cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter
After=network.target

[Service]
ExecStart=/opt/subconverter/subconverter -p $SUB_PORT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

# -----------------------------
# Sub-Web 前端
# -----------------------------
rm -rf /opt/sub-web-modify
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify

cat > vue.config.js <<'EOF'
module.exports = {
  publicPath: '/subconvert/'
}
EOF

npm install
npm run build

# -----------------------------
# AdGuard Home
# -----------------------------
if [ ! -d /opt/AdGuardHome ]; then
  curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh
fi

# -----------------------------
# Nginx
# -----------------------------
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    location /sub/ {
        proxy_pass http://127.0.0.1:$SUB_PORT/;
        proxy_set_header Host \$host;
    }

    location /adguard/ {
        proxy_pass http://127.0.0.1:$ADG_HTTP/;
        proxy_set_header Host \$host;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t
systemctl reload nginx

# -----------------------------
# 完成提示
# -----------------------------
echo ""
echo "=========== 部署完成 ==========="
echo ""
echo "Sub-Web 前端:"
echo "https://$DOMAIN/subconvert/"
echo ""
echo "SubConverter 后端:"
echo "https://$DOMAIN/sub/"
echo ""
echo "VLESS 入站配置（S-UI / v2ray / xray）:"
echo "监听 IP: 127.0.0.1 或 ::"
echo "监听端口: $VLESS_PORT"
echo "协议: VLESS"
echo "传输: TCP"
echo ""
echo "AdGuard Home:"
echo "https://$DOMAIN/adguard/"
echo "================================"
