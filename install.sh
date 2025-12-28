#!/usr/bin/env bash
set -e

# ====== 基础设置 ======
MAIN_DOMAIN="example.com"        # 主域名
VLESS_SUBDOMAIN="vless.example.com"  # VLESS 子域名
CERT_PATH="/etc/nginx/ssl"
SUI_PANEL_PORT=2095
SUI_PANEL_PATH="/app/"
SUI_SUB_PORT=2096
SUI_SUB_PATH="/sub/"
SUI_ADMIN_USER="adminuser"
SUI_ADMIN_PASS="adminpass"
AGH_PORT=3000
WEB_PATH="/var/www/html"

# ====== 安装依赖 ======
echo "1/10 安装系统依赖..."
apt update -y
apt install -y curl wget git npm tar ufw socat expect nginx

# ====== 防火墙配置 ======
echo "2/10 配置防火墙..."
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow $SUI_PANEL_PORT/tcp
ufw allow $SUI_SUB_PORT/tcp
ufw allow $AGH_PORT/tcp
ufw enable

# ====== 安装 acme.sh ======
echo "3/10 安装 acme.sh..."
curl https://get.acme.sh | sh
source ~/.bashrc
mkdir -p $CERT_PATH

# ====== 申请证书 ======
echo "4/10 申请证书..."
~/.acme.sh/acme.sh --issue --dns dns_cf -d $MAIN_DOMAIN -d $VLESS_SUBDOMAIN
~/.acme.sh/acme.sh --install-cert -d $MAIN_DOMAIN \
  --key-file       $CERT_PATH/key.pem \
  --fullchain-file $CERT_PATH/fullchain.pem \
  --reloadcmd      "systemctl restart nginx && systemctl restart AdGuardHome"

# ====== 安装 SubConverter ======
echo "5/10 安装 SubConverter..."
wget -O /usr/local/bin/subconverter https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
chmod +x /usr/local/bin/subconverter
systemctl enable subconverter.service

# ====== 安装 sub-web-modify ======
echo "6/10 安装 sub-web-modify..."
git clone https://github.com/about300/sub-web-modify.git /opt/sub-web-modify
cd /opt/sub-web-modify
npm install
npm run build
mkdir -p $WEB_PATH
cp -r dist/* $WEB_PATH/

# ====== 安装 S-UI 官方脚本 ======
echo "7/10 安装 S-UI..."
expect <<EOF
spawn bash -c "bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/refs/heads/main/install.sh)"
expect "Do you want to continue with the modification"
send "y\r"
expect "Enter the panel port"
send "$SUI_PANEL_PORT\r"
expect "Enter the panel path"
send "$SUI_PANEL_PATH\r"
expect "Enter the subscription port"
send "$SUI_SUB_PORT\r"
expect "Enter the subscription path"
send "$SUI_SUB_PATH\r"
expect "Do you want to change admin credentials"
send "y\r"
expect "Please set up your username"
send "$SUI_ADMIN_USER\r"
expect "Please set up your password"
send "$SUI_ADMIN_PASS\r"
expect eof
EOF

# ====== 安装 AdGuard Home ======
echo "8/10 安装 AdGuard Home..."
AGH_PATH="/opt/adguardhome"
wget -O AdGuardHome.tar.gz https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz
tar -xzf AdGuardHome.tar.gz -C /opt
cd $AGH_PATH
./AdGuardHome -s install

# ====== 配置 AdGuard Home HTTPS ======
echo "9/10 配置 AdGuard Home HTTPS..."
cp $CERT_PATH/fullchain.pem $AGH_PATH/AdGuardHome.crt
cp $CERT_PATH/key.pem $AGH_PATH/AdGuardHome.key
systemctl restart AdGuardHome

# ====== 配置 Nginx 反代 ======
echo "10/10 配置 Nginx 反代 S-UI、主页和 SubConverter..."
cat >/etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    server_name $MAIN_DOMAIN $VLESS_SUBDOMAIN;

    location / {
        root $WEB_PATH;
        index index.html;
    }

    location /subconverter/ {
        proxy_pass http://127.0.0.1:25500/;   # SubConverter 默认端口
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location $SUI_PANEL_PATH {
        proxy_pass http://127.0.0.1:$SUI_PANEL_PORT$app/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    listen 443 ssl;
    ssl_certificate $CERT_PATH/fullchain.pem;
    ssl_certificate_key $CERT_PATH/key.pem;
}
EOF

systemctl restart nginx

# ====== 完成提示 ======
echo "安装完成！"
echo "S-UI 面板: https://$MAIN_DOMAIN$SUI_PANEL_PATH"
echo "主页: https://$MAIN_DOMAIN/"
echo "SubConverter: https://$MAIN_DOMAIN/subconverter/"
echo "AdGuard Home: https://$MAIN_DOMAIN:$AGH_PORT"
echo "证书路径: $CERT_PATH"
