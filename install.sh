#!/bin/bash

set -e

# ========== 用户变量设置区域 ==========

# 您的域名（填写用于 SSL 证书的域名）
DOMAIN="YOUR_DOMAIN"

# Cloudflare API 凭证（请自行替换为您的 Global API Key 和对应邮箱）
CF_Key="CLOUDFLARE_API_KEY"
CF_Email="CLOUDFLARE_EMAIL"

# =====================================

# 更新并安装基础软件
apt-get update
apt-get install -y nginx git curl wget unzip ufw nodejs npm build-essential

# 1. 释放 53 端口（关闭 systemd-resolved 的 stub）
echo -e "[Resolve]\nDNS=127.0.0.1\nDNSStubListener=no" > /etc/systemd/resolved.conf.d/adguardhome.conf
mv /etc/resolv.conf /etc/resolv.conf.backup
ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
systemctl restart systemd-resolved

# 2. 安装 acme.sh 并申请证书（DNS-01 via Cloudflare）
curl https://get.acme.sh | sh
export CF_Key CF_Email
export CF_Email="$CF_Email"
export CF_Key="$CF_Key"
~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN"
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /root/server.key --fullchain-file /root/server.crt

# 3. 安装并配置 nginx
cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate /root/server.crt;
    ssl_certificate_key /root/server.key;

    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /sub/ {
        alias /var/www/sub-web/;
        try_files \$uri \$uri/ /sub/index.html;
    }

    # 静态资源：可以根据需要配置 /assets, /js, /css 等路径
    location /assets/ { alias /var/www/sub-web/assets/; }
}
EOF
mkdir -p /var/www/html
echo "<html><body><h1>欢迎使用主站首页</h1><p><a href=\"/sub/\">订阅转换 UI</a></p></body></html>" > /var/www/html/index.html
systemctl reload nginx

# 4. 部署 Subconverter 后端 (端口25500)
mkdir -p /opt/subconverter
curl -L https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter -o /opt/subconverter/subconverter
chmod +x /opt/subconverter/subconverter
# 下载默认配置模板
mkdir -p /etc/subconverter
curl -L https://raw.githubusercontent.com/about300/ACL4SSR/master/Clash/config/Online_Full_github.ini -o /etc/subconverter/template.ini
# 创建 systemd 服务
cat > /etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=Subconverter Subscription Converter API
After=network.target

[Service]
Type=simple
ExecStart=/opt/subconverter/subconverter
WorkingDirectory=/opt/subconverter
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now subconverter

# 5. 构建并部署 sub-web 前端
git clone https://github.com/CareyWang/sub-web.git /opt/sub-web
cd /opt/sub-web
npm install
# 设置前端默认的 Subconverter 后端地址
export VUE_APP_SUBCONVERTER_DEFAULT_BACKEND="http://127.0.0.1:25500"
npm run build
# 将构建产物部署到 Nginx 指定目录
rm -rf /var/www/sub-web
mkdir -p /var/www/sub-web
cp -r dist/* /var/www/sub-web/

# 6. 安装 S-UI 面板（默认监听2095端口）:contentReference[oaicite:6]{index=6}
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# 7. 安装 AdGuardHome
AGH_VER=$(curl -s https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest | grep tag_name | cut -d '"' -f4)
wget -O AdGuardHome_linux_amd64.tar.gz "https://github.com/AdguardTeam/AdGuardHome/releases/download/${AGH_VER}/AdGuardHome_linux_amd64.tar.gz"
tar zxvf AdGuardHome_linux_amd64.tar.gz
cd AdGuardHome
./AdGuardHome -s install

# 8. 配置防火墙 (允许 TCP+UDP)
ufw allow 22/tcp
ufw allow 22/udp
ufw allow 53/tcp
ufw allow 53/udp
ufw allow 80/tcp
ufw allow 80/udp
ufw allow 443/tcp
ufw allow 443/udp
ufw allow 2095/tcp
ufw allow 2095/udp
ufw allow 25500/tcp
ufw allow 25500/udp
ufw --force enable

echo "部署完成！"
