#!/bin/bash
# ===========================
# VPS 部署脚本 - 完整版
# ===========================

set -e

echo "==== 1/15 配置基础变量 ===="
read -p "请输入主域名 (Main domain, 例: example.com): " MAIN_DOMAIN
read -p "请输入 VLESS 子域名 (Subdomain, 例: v.example.com): " SUB_DOMAIN
read -p "请输入 S-UI 面板用户名 (默认: admin): " SUI_USER
SUI_USER=${SUI_USER:-admin}
read -p "请输入 S-UI 面板密码 (默认: admin123): " SUI_PASS
SUI_PASS=${SUI_PASS:-admin123}
read -p "请输入 S-UI 面板端口 (默认 2095): " SUI_PORT
SUI_PORT=${SUI_PORT:-2095}
read -p "请输入 S-UI 订阅端口 (默认 2096): " SUB_PORT
SUB_PORT=${SUB_PORT:-2096}
read -p "请输入 AdGuard Home Web 端口 (默认 3000): " AD_PORT
AD_PORT=${AD_PORT:-3000}

SSL_PATH="/etc/ssl/mycerts"
mkdir -p $SSL_PATH

echo "==== 2/15 安装基础依赖 ===="
apt update -y
apt install -y curl wget tar unzip socat git npm ufw lsof

echo "==== 3/15 配置防火墙 ===="
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow $SUI_PORT
ufw allow $SUB_PORT
ufw allow $AD_PORT
ufw --force enable

echo "==== 4/15 安装 acme.sh ===="
curl https://get.acme.sh | sh
source ~/.bashrc

echo "==== 5/15 申请证书 ===="
acme.sh --issue --dns dns_cf -d $MAIN_DOMAIN -d $SUB_DOMAIN --keylength ec-256
acme.sh --install-cert -d $MAIN_DOMAIN -d $SUB_DOMAIN \
    --ecc \
    --key-file $SSL_PATH/key.pem \
    --fullchain-file $SSL_PATH/fullchain.pem \
    --reloadcmd "systemctl reload nginx"

echo "证书生成完成，路径如下："
echo "私钥: $SSL_PATH/key.pem"
echo "全链: $SSL_PATH/fullchain.pem"

echo "==== 6/15 安装 SubConverter ===="
wget -O /usr/local/bin/subconverter https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
chmod +x /usr/local/bin/subconverter
systemctl enable --now subconverter.service

echo "==== 7/15 安装前端主页 (带搜索 + 订阅转换) ===="
rm -rf /opt/sub-web
git clone https://github.com/about300/sub-web-modify.git /opt/sub-web
cd /opt/sub-web
npm install
npm run build
cp -r dist/* /var/www/html/

echo "==== 8/15 安装 S-UI 面板 ===="
bash <(curl -sL https://github.com/alireza0/s-ui/releases/latest/download/s-ui-linux-amd64.tar.gz) || true
# 使用官方脚本安装后再配置用户
s-ui reset-admin --user $SUI_USER --pass $SUI_PASS
echo "S-UI 面板安装完成，端口: $SUI_PORT, 订阅端口: $SUB_PORT"

echo "==== 9/15 安装 AdGuard Home ===="
wget -O /tmp/AdGuardHome.tar.gz https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz
tar -xzf /tmp/AdGuardHome.tar.gz -C /opt/
cd /opt/AdGuardHome
./AdGuardHome -s install
# 修改端口
sed -i "s/3000/$AD_PORT/g" /opt/AdGuardHome/AdGuardHome.yaml
systemctl restart AdGuardHome

echo "==== 安装完成 ===="
echo "主页已部署到 /var/www/html/"
echo "S-UI 面板地址: http://$MAIN_DOMAIN:$SUI_PORT/app/"
echo "S-UI 订阅地址: http://$MAIN_DOMAIN:$SUB_PORT/sub/"
echo "AdGuard Home Web 地址: https://$MAIN_DOMAIN:$AD_PORT/"
echo "证书路径: $SSL_PATH/"
echo "SubConverter 已安装，默认端口请自行在配置文件查看"

echo "安装完成！请通过面板添加节点和用户。"
