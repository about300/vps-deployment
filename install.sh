#!/usr/bin/env bash
# ==================== 开头页 ====================
clear
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
NC="\033[0m"

echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     VPS 全栈部署脚本 - Ubuntu24    ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
echo ""

read -rp "请输入主域名 (例如: example.com): " MAIN_DOMAIN
read -rp "请输入邮箱 (用于申请 SSL，Let's Encrypt 通知): " CERT_EMAIL
echo ""
echo "配置摘要："
echo "  - 主域名: $MAIN_DOMAIN"
echo "  - 证书邮箱: $CERT_EMAIL"
echo ""
echo "脚本将清理并覆盖 /opt/vps-deploy 下的 web 内容（会备份现有配置）"
read -rp "按 Enter 开始部署 (Ctrl+C 取消)..." dummy

# ------------------- 更新系统 -------------------
apt update -y
apt upgrade -y

# ------------------- 安装基础工具 -------------------
apt install -y nginx unzip curl wget git socat lsof ufw acme.sh

# ------------------- 配置防火墙 -------------------
ufw enable
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 8445
ufw reload

# ------------------- 部署 Web 目录 -------------------
WEB_DIR="/opt/vps-deploy/web"
SUB_DIR="$WEB_DIR/sub"
BACKUP_DIR="/opt/vps-deploy/web_backup_$(date +%s)"

if [ -d "$WEB_DIR" ]; then
    echo "备份现有 web 目录到 $BACKUP_DIR"
    mv "$WEB_DIR" "$BACKUP_DIR"
fi

mkdir -p "$WEB_DIR"
mkdir -p "$SUB_DIR"

echo "下载 Web 前端内容..."
git clone https://github.com/about300/vps-deployment.git /tmp/tmp-vps-deploy
cp -r /tmp/tmp-vps-deploy/web/* "$WEB_DIR/"
rm -rf /tmp/tmp-vps-deploy

# ------------------- 部署 s-ui -------------------
echo "部署 s-ui 面板（官方源）..."
bash <(curl -sL https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# ------------------- 申请 Let's Encrypt 证书 -------------------
CERT_DIR="/root/cert/$MAIN_DOMAIN"
mkdir -p "$CERT_DIR"

echo "使用 acme.sh 申请证书..."
systemctl stop nginx
acme.sh --issue --standalone -d "$MAIN_DOMAIN" --force --accountemail "$CERT_EMAIL"
acme.sh --install-cert -d "$MAIN_DOMAIN" \
    --cert-file "$CERT_DIR/$MAIN_DOMAIN.crt" \
    --key-file "$CERT_DIR/$MAIN_DOMAIN.key" \
    --fullchain-file "$CERT_DIR/fullchain.crt" \
    --reloadcmd "systemctl restart nginx"

# ------------------- 配置 nginx -------------------
NGINX_CONF="/etc/nginx/sites-available/$MAIN_DOMAIN.conf"
cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $MAIN_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $MAIN_DOMAIN;

    ssl_certificate $CERT_DIR/fullchain.crt;
    ssl_certificate_key $CERT_DIR/$MAIN_DOMAIN.key;

    root $WEB_DIR;
    index index.html index.htm;

    location /sub/ {
        root $WEB_DIR;
        index index.html;
    }

    location /app/ {
        proxy_pass http://127.0.0.1:2095/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx

# ------------------- 完成页（单独一页） -------------------
clear
echo -e "${CYAN}╔════════════════════════════════╗${NC}"
echo -e "${CYAN}║         部署完成！           ║${NC}"
echo -e "${CYAN}╚════════════════════════════════╝${NC}"
echo "Web主页:      https://$MAIN_DOMAIN"
echo "订阅转换:      https://$MAIN_DOMAIN/sub/"
echo "s-ui 管理面板: https://$MAIN_DOMAIN/app"
echo "证书路径:      $CERT_DIR"
echo ""
echo -e "${YELLOW}已开启防火墙，允许端口: 22, 80, 443, 8445${NC}"
