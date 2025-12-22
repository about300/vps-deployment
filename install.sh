#!/usr/bin/env bash
set -e

echo "===== VPS 全栈部署（无 stream / Reality 友好）====="

read -rp "请输入域名（如 wo.mycloudshare.org）: " DOMAIN

echo "[1/9] 更新系统"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential

echo "[2/9] 防火墙"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 8443
ufw allow 3000
ufw allow 8445
ufw --force enable

echo "[3/9] 安装 acme.sh（只用于 Web，不干涉 Reality）"
curl https://get.acme.sh | sh
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

mkdir -p /etc/nginx/ssl/$DOMAIN

~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone || true
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file       /etc/nginx/ssl/$DOMAIN/key.pem \
  --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
  --reloadcmd "systemctl reload nginx"

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
systemctl restart subconverter

echo "[5/9] 安装 Node.js (LTS)"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

echo "[6/9] 构建 sub-web-modify（about300 仓库）"
rm -rf /opt/sub-web-modify
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify
npm install
npm run build

echo "[7/9] 安装 S-UI（仅本地监听）"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

echo "[8/9] Nginx 配置（HTTP / HTTPS，不占用 443 stream）"
cat >/etc/nginx/conf.d/$DOMAIN.conf <<EOF
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

rm -f /etc/nginx/conf.d/stream.conf
nginx -t
systemctl reload nginx

echo "[9/9] 完成 🎉"
echo "--------------------------------------"
echo "Web 面板: https://$DOMAIN"
echo "SubConverter API: https://$DOMAIN/sub/api/"
echo "S-UI 访问方式:"
echo "ssh -L 2095:127.0.0.1:2095 root@你的IP"
echo "--------------------------------------"
echo "Reality / VLESS 请在 S-UI 中自行配置"
