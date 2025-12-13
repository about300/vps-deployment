#!/bin/bash

# ------------------- 颜色 -------------------
CYAN="\033[1;36m"
YELLOW="\033[1;33m"
NC="\033[0m"

# ------------------- 用户输入 -------------------
clear
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

# ------------------- 安装依赖 -------------------
apt update -y
apt install -y git cron socat ufw curl wget tar unzip nginx

# ------------------- 配置防火墙 -------------------
ufw --force enable
for p in 22 80 443 8445 8443; do
    ufw allow $p/tcp
    ufw allow $p/udp
done

# ------------------- 拉取 Web 前端 -------------------
WEB_DIR="/opt/vps-deploy/web"
if [ -d "$WEB_DIR" ]; then
    mv "$WEB_DIR" "${WEB_DIR}_bak_$(date +%s)"
fi
git clone https://github.com/about300/vps-deployment.git /tmp/vps-deploy-temp
mkdir -p "$WEB_DIR"
cp -r /tmp/vps-deploy-temp/web/* "$WEB_DIR"

# ------------------- 安装 subconvert -------------------
SUB_DIR="/opt/vps-deploy/sub"
mkdir -p "$SUB_DIR"
curl -L -o "$SUB_DIR/subconvert" https://github.com/youshandefeiyang/sub-web-modify/releases/latest/download/subconvert-linux-amd64
chmod +x "$SUB_DIR/subconvert"

# ------------------- 安装 s-ui 面板 -------------------
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# ------------------- 安装 acme.sh 并申请证书 -------------------
curl https://get.acme.sh | sh -s email=$CERT_EMAIL
source ~/.bashrc
ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh
acme.sh --set-default-ca --server letsencrypt
# 使用 DNS API（Cloudflare）方式申请证书，无需停止 nginx
read -rp "请输入 Cloudflare API Key: " CF_API_KEY
read -rp "请输入 Cloudflare Email: " CF_EMAIL
export CF_Key="$CF_API_KEY"
export CF_Email="$CF_EMAIL"
acme.sh --issue --dns dns_cf -d $MAIN_DOMAIN --keylength ec-256
acme.sh --install-cert -d $MAIN_DOMAIN --ecc \
    --key-file /root/server.key \
    --fullchain-file /root/server.crt \
    --reloadcmd "systemctl reload nginx"

# ------------------- 配置 nginx -------------------
cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 443 ssl http2;
    server_name $MAIN_DOMAIN;

    ssl_certificate /root/server.crt;
    ssl_certificate_key /root/server.key;

    location / {
        root $WEB_DIR;
        index index.html;
    }

    location /sub/ {
        root $SUB_DIR;
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

systemctl restart nginx

# ------------------- 证书自动续期 -------------------
cat > /root/cert-monitor.sh <<'EOF'
#!/bin/bash
/root/.acme.sh/acme.sh --renew -d $MAIN_DOMAIN --force --ecc \
    --key-file /root/server.key \
    --fullchain-file /root/server.crt \
    --reloadcmd "systemctl reload nginx"
EOF
chmod +x /root/cert-monitor.sh
(crontab -l 2>/dev/null; echo "0 3 */30 * * /root/cert-monitor.sh >>/var/log/cert-monitor.log 2>&1")|crontab -

# ------------------- 完成页（单独一页） -------------------
clear
echo -e "${CYAN}╔════════════════════════════════╗${NC}"
echo -e "${CYAN}║         部署完成！           ║${NC}"
echo -e "${CYAN}╚════════════════════════════════╝${NC}"
echo "Web主页:      https://$MAIN_DOMAIN"
echo "订阅转换:      https://$MAIN_DOMAIN/sub/"
echo "s-ui 管理面板: https://$MAIN_DOMAIN/app"
echo "证书路径:      /root/server.crt"
echo ""
echo -e "${YELLOW}已开启防火墙，允许端口: 22, 80, 443, 8445, 8443${NC}"
