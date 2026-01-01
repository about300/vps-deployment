#!/usr/bin/env bash
set -e
echo "===== VPS 全栈部署 ====="

# 步骤 1：输入您的域名和 Cloudflare 凭证
read -rp "请输入您的域名 (例如：aa.mycloudshare.org): " DOMAIN
read -rp "请输入您的 Cloudflare 邮箱: " CF_Email
read -rp "请输入您的 Cloudflare API Token: " CF_Token
export CF_Email
export CF_Token

# 预设 VLESS 端口（可以根据需要修改）
VLESS_PORT=5000

echo "[1/12] 更新系统并安装依赖项"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3

echo "[2/12] 配置防火墙"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 8443
ufw allow 3000
ufw allow 8445
ufw allow 53
ufw allow 2550
ufw --force enable

echo "[3/12] 安装 acme.sh 用于 DNS-01 验证"
if [ ! -d "$HOME/.acme.sh" ]; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
else
    echo "[INFO] acme.sh 已安装，跳过安装"
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
mkdir -p /etc/nginx/ssl/$DOMAIN

echo "[4/12] 通过 Cloudflare 申请 SSL 证书"
if [ ! -f "/etc/nginx/ssl/$DOMAIN/fullchain.pem" ]; then
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
else
    echo "[INFO] SSL 证书已存在，跳过申请"
fi

echo "[5/12] 安装 SSL 证书到 Nginx"
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
  --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
  --reloadcmd "systemctl reload nginx"

echo "[6/12] 安装 SubConverter 后端（保持原有二进制）"
mkdir -p /opt/subconverter
if [ ! -f "/opt/subconverter/subconverter" ]; then
    echo "[INFO] 下载 SubConverter 二进制文件"
    wget -O /opt/subconverter/subconverter \
      https://github.com/about300/vps-deployment/raw/refs/heads/main/bin/subconverter
    chmod +x /opt/subconverter/subconverter
fi

cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter 服务
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

echo "[7/12] 安装 Node.js (LTS)"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

echo "[8/12] 构建 sub-web-modify（使用原仓库源码，并设置 publicPath）"
if [ ! -d "/opt/sub-web-modify" ]; then
    echo "[INFO] 克隆 sub-web-modify 仓库"
    git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
fi
cd /opt/sub-web-modify
npm install
# 设置 publicPath='/subconvert/' 重新构建
echo "[INFO] 构建 sub-web-modify 并设置 publicPath=/subconvert/"
npm run build -- --public-path /subconvert/

echo "[9/12] 安装 S-UI 面板（仅本地监听）"
if [ ! -d "/opt/s-ui" ]; then
    bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
fi

echo "[10/12] 克隆主页 Web 文件"
if [ ! -d "/opt/web-home" ]; then
    git clone https://github.com/about300/vps-deployment.git /opt/web-home
    mv /opt/web-home/web /opt/web-home/current
fi

echo "[11/12] 配置 Nginx"
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    
    ssl_certificate     /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    # 主页 Web
    root /opt/web-home/current;
    index index.html;
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Sub-Web（订阅转换前端）
    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        try_files \$uri \$uri/ /index.html;
    }

    # SubConverter 后端
    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }

    # VLESS 订阅
    location /vless/ {
        proxy_pass http://127.0.0.1:$VLESS_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }
}
EOF
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t
systemctl reload nginx

echo "[12/12] 安装 AdGuard Home（端口 3000）"
curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh

echo "[13/12] 部署完成 🎉"
echo "====================================="
echo "主页 Web: https://$DOMAIN"
echo "Sub-Web: https://$DOMAIN/subconvert/"
echo "SubConverter API: https://$DOMAIN/sub/api/"
echo "S-UI 面板: http://127.0.0.1:2095"
echo "====================================="
