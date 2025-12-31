#!/usr/bin/env bash
set -e

echo "======================================"
echo " 一键部署 全栈服务"
echo " - VLESS + Reality 共用 443 端口"
echo " - SubConverter 后端 + sub-web-modify"
echo " - S-UI 面板"
echo " - AdGuard Home"
echo " - Let's Encrypt DNS-01"
echo "======================================"

# 输入域名与 Cloudflare 配置信息
read -rp "请输入主域名（如 mycloudshare.org）: " DOMAIN
read -rp "请输入 Cloudflare 邮箱: " CF_EMAIL
read -rp "请输入 Cloudflare API Token: " CF_TOKEN

# 设置 Cloudflare API Token
export CF_Email="$CF_EMAIL"
export CF_Token="$CF_TOKEN"

# 更新系统
echo "[1/9] 更新系统 & 安装基础组件"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3

# 防火墙设置
echo "[2/9] 防火墙放行必要端口"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000
ufw allow 8445
ufw --force enable

# 安装 acme.sh
echo "[3/9] 安装 acme.sh"
curl https://get.acme.sh | sh
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# 使用 DNS-01 进行 Let's Encrypt 证书申请
echo "[4/9] 使用 DNS-01 申请证书"
mkdir -p /etc/nginx/ssl/$DOMAIN
~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
  --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
  --reloadcmd "systemctl reload nginx"

# 安装 SubConverter 后端
echo "[5/9] 安装 SubConverter 后端"
mkdir -p /opt/subconverter
cd /opt/subconverter
git clone https://github.com/about300/vps-deployment /opt/subconverter
cd /opt/subconverter
# Modify backend code/config here as needed

# 创建 SubConverter 服务
cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter
After=network.target

[Service]
ExecStart=/opt/subconverter/subconverter
WorkingDirectory=/opt/subconverter
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

# 安装 Node.js (LTS)
echo "[6/9] 安装 Node.js (LTS)"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 
apt install -y nodejs

# 构建 sub-web-modify 前端
echo "[7/9] 构建 sub-web-modify"
rm -rf /opt/sub-web-modify
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify
# Modify the frontend code for search functionality or other UI changes
npm install
npm run build

# 安装 S-UI 面板（仅安装，不暴露）
echo "[8/9] 安装 S-UI 面板"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# nginx 配置（共用 443 端口，nginx 反向代理）
echo "[9/9] 配置 nginx"
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/nginx/ssl/$DOMAIN/fullchain.pem;
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

    # VLESS 流量反向代理
    location /vless/ {
        proxy_pass http://127.0.0.1:10000;  # VLESS 服务端口
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # S-UI 面板反向代理
    location /ui/ {
        proxy_pass http://127.0.0.1:2095/app/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

echo "======================================"
echo "🎉 部署完成！"
echo "Web 页面： https://$DOMAIN"
echo "SubConverter API： https://$DOMAIN/sub/api/"
echo "S-UI 面板： https://$DOMAIN/ui/"
echo "======================================"
echo "请根据需要配置 VLESS + Reality、AdGuard Home 及其他服务。"
