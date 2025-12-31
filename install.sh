#!/usr/bin/env bash
set -euo pipefail

echo "======================================="
echo " VPS 全栈部署 (Web + SubConverter + VLESS + AdGuard + S-UI)"
echo "======================================="

# —— 1. 输入域名和 Cloudflare API —— #
read -rp "请输入主域名 (如 web.mycloudshare.org): " DOMAIN
read -rp "请输入 Cloudflare 邮箱: " CF_EMAIL
read -rp "请输入 Cloudflare API Token: " CF_TOKEN

export CF_Email="$CF_EMAIL"
export CF_Token="$CF_TOKEN"

# —— 2. 更新系统 & 安装依赖 —— #
echo "[1/10] 安装依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx \
    build-essential python3 python-is-python3 nodejs npm

# —— 3. 防火墙端口 —— #
echo "[2/10] 配置防火墙"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000
ufw allow 8445
ufw allow 53
ufw allow 25500
ufw --force enable

# —— 4. 安装 acme.sh DNS-01 —— #
echo "[3/10] 安装 acme.sh 用于 DNS-01 获取证书"
curl https://get.acme.sh | sh
source ~/.bashrc

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

mkdir -p /etc/nginx/ssl/"$DOMAIN"

echo "[4/10] 使用 DNS-01 (Cloudflare) 申请证书..."
~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file       /etc/nginx/ssl/"$DOMAIN"/key.pem \
  --fullchain-file /etc/nginx/ssl/"$DOMAIN"/fullchain.pem \
  --reloadcmd     "systemctl reload nginx"

# —— 5. 安装 SubConverter 二进制 —— #
echo "[5/10] 安装 SubConverter 后端二进制"
mkdir -p /opt/subconverter
cd /opt/subconverter

BIN_URL="https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter"
echo "从 $BIN_URL 下载可执行文件..."
wget -q -O subconverter "$BIN_URL"
chmod +x subconverter

cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter Service
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
systemctl enable --now subconverter

# —— 6. 构建 sub-web-modify 前端 —— #
echo "[6/10] 构建 sub-web-modify 前端"
rm -rf /opt/sub-web-modify
cp -r ./sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify

# 修改 .env 让前端使用本地后端
cat >.env << EOF
VUE_APP_PROJECT="https://github.com/about300/vps-deployment"
VUE_APP_BOT_LINK="https://t.me/feiyangdigital"
VUE_APP_BILIBILI_LINK="https://space.bilibili.com/138129883"
VUE_APP_YOUTUBE_LINK="https://youtube.com/channel/UCKHJ2UPlkNsDRj1cVXi0UsA"
VUE_APP_BASIC_VIDEO="https://www.youtube.com/watch?v=C4WV4223uYw"
VUE_APP_ADVANCED_VIDEO="https://www.youtube.com/watch?v=cHs-J2P5CT0"
VUE_APP_SCRIPT_CONFIG="https://github.com/tindy2013/subconverter/blob/master/README-cn.md?plain=1#L703-L719"
VUE_APP_FILTER_CONFIG="https://github.com/tindy2013/subconverter/blob/master/README-cn.md?plain=1#L514-L531"
VUE_APP_SUBCONVERTER_REMOTE_CONFIG="https://raw.githubusercontent.com/about300/ACL4SSR/master/Clash/config/Online_Full_github.ini"
VUE_APP_SUBCONVERTER_DEFAULT_BACKEND="/sub/api/sub"
VUE_APP_MYURLS_DEFAULT_BACKEND="/sub/api/short"
VUE_APP_CONFIG_UPLOAD_BACKEND="/sub/api/upload"
EOF

npm install --legacy-peer-deps
npm run build

# —— 7. 安装搜索主页 —— #
echo "[7/10] 准备搜索主页"
rm -rf /opt/web-home
mkdir -p /opt/web-home
cp -r ./web/* /opt/web-home/

# —— 8. 安装 S-UI 面板 —— #
echo "[8/10] 安装 S-UI 面板"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# —— 9. 安装 AdGuard Home —— #
echo "[9/10] 安装 AdGuard Home"
curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh

# —— 10. 写入 Nginx 配置 —— #
echo "[10/10] 写入 nginx 配置并生效"
cat >/etc/nginx/sites-available/"$DOMAIN".conf <<EOF
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

    # 搜索主页
    root /opt/web-home;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # 订阅转换前端
    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        index index.html;
        try_files \$uri \$uri/ /subconvert/index.html;
    }

    # SubConverter 后端 API
    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

ln -sf /etc/nginx/sites-available/"$DOMAIN".conf /etc/nginx/sites-enabled/
nginx -t
systemctl reload nginx

echo "======================================"
echo "🎉 全部服务部署完成!"
echo "主页: https://$DOMAIN"
echo "订阅转换: https://$DOMAIN/subconvert/"
echo "SubConverter API: https://$DOMAIN/sub/api/"
echo "AdGuard Home UI: http://<你的IP>:3000"
echo "S-UI 面板 (本地访问): ssh -L 2095:127.0.0.1:2095 root@<你的IP>"
echo "======================================"
