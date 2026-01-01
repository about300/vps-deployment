#!/usr/bin/env bash
set -e
echo "===== VPS 全栈部署 ====="

# -------------------------------
# 步骤 1：输入您的域名和 Cloudflare 凭证
# -------------------------------
read -rp "请输入您的域名 (例如：web.mycloudshare.org): " DOMAIN
read -rp "请输入您的 Cloudflare 邮箱: " CF_Email
read -rp "请输入您的 Cloudflare API Token: " CF_Token
export CF_Email
export CF_Token

# -------------------------------
# 预设 VLESS 端口
# -------------------------------
VLESS_PORT=5000  # 可根据需要修改

# -------------------------------
# 步骤 2：更新系统并安装依赖
# -------------------------------
echo "[1/12] 更新系统并安装依赖..."
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3

# -------------------------------
# 步骤 3：配置防火墙
# -------------------------------
echo "[2/12] 配置防火墙..."
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 8443
ufw allow 3000
ufw allow 8445
ufw allow 53
ufw allow 2550
ufw --force enable

# -------------------------------
# 步骤 4：安装 acme.sh 用于 DNS-01 验证
# -------------------------------
echo "[3/12] 安装 acme.sh..."
if [ ! -d "$HOME/.acme.sh" ]; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
else
    echo "[INFO] acme.sh 已安装，跳过安装。"
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
mkdir -p /etc/nginx/ssl/$DOMAIN

# -------------------------------
# 步骤 5：申请 SSL 证书
# -------------------------------
echo "[4/12] 通过 Cloudflare 申请 SSL..."
if [ ! -f "/etc/nginx/ssl/$DOMAIN/fullchain.pem" ]; then
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
else
    echo "[INFO] SSL 已存在，跳过申请。"
fi

# 安装证书到 Nginx
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
    --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
    --reloadcmd "systemctl reload nginx"

# -------------------------------
# 步骤 6：安装 SubConverter 后端（保持原二进制）
# -------------------------------
echo "[5/12] 安装 SubConverter 后端..."
mkdir -p /opt/subconverter
if [ ! -f "/opt/subconverter/subconverter" ]; then
    echo "[INFO] 下载 SubConverter 二进制文件..."
    wget -O /opt/subconverter/subconverter \
        https://github.com/about300/vps-deployment/raw/refs/heads/main/bin/subconverter
    chmod +x /opt/subconverter/subconverter
else
    echo "[INFO] SubConverter 二进制已存在，跳过下载。"
fi

# 创建 systemd 服务
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

# -------------------------------
# 步骤 7：安装 Node.js (LTS)
# -------------------------------
echo "[6/12] 安装 Node.js..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

# -------------------------------
# 步骤 8：构建 Sub-Web（使用 about300/sub-web-modify 仓库源码）
# -------------------------------
echo "[7/12] 构建 Sub-Web 前端..."
if [ ! -d "/opt/sub-web-modify" ]; then
    rm -rf /opt/sub-web-modify
    git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
    cd /opt/sub-web-modify
    npm install
    npm run build
else
    echo "[INFO] sub-web-modify 已存在，跳过克隆。"
fi

# -------------------------------
# 步骤 9：安装 S-UI 面板
# -------------------------------
echo "[8/12] 安装 S-UI 面板..."
if [ ! -d "/opt/s-ui" ]; then
    bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
else
    echo "[INFO] S-UI 面板已存在，跳过安装。"
fi

# -------------------------------
# 步骤 10：克隆 Web 主页
# -------------------------------
echo "[9/12] 克隆 Web 主页..."
if [ ! -d "/opt/web-home" ]; then
    git clone https://github.com/about300/vps-deployment.git /opt/web-home
    mv /opt/web-home/web /opt/web-home/current
else
    echo "[INFO] web-home 已存在，跳过克隆。"
fi

# -------------------------------
# 步骤 11：配置 Nginx
# -------------------------------
echo "[10/12] 配置 Nginx..."
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

    # Sub-Web 前端 SPA
    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        index index.html;
        try_files \$uri \$uri/ /subconvert/index.html;
    }

    # SubConverter 后端
    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }

    # VLESS 订阅
    location /vless/ {
        proxy_pass http://127.0.0.1:$VLESS_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }

    # 静态文件缓存优化
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?|ttf|eot)$ {
        expires 7d;
        access_log off;
    }
}
EOF
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t
systemctl reload nginx

# -------------------------------
# 步骤 12：安装 AdGuard Home
# -------------------------------
echo "[11/12] 安装 AdGuard Home..."
curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh

# -------------------------------
# 步骤 13：完成提示
# -------------------------------
echo "[12/12] 安装完成 🎉"
echo "====================================="
echo "主页 Web: https://$DOMAIN"
echo "Sub-Web 前端: https://$DOMAIN/subconvert/"
echo "SubConverter API: https://$DOMAIN/sub/api/"
echo "S-UI 面板: http://127.0.0.1:2095"
echo "====================================="
