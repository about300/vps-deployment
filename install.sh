#!/usr/bin/env bash
set -e

# ==================== 颜色 ====================
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ------------------- 用户输入 -------------------
clear
echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     VPS 全栈部署脚本 - Ubuntu24    ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
echo ""
read -rp "请输入主域名 (例如: example.com): " MAIN_DOMAIN
read -rp "请输入 Cloudflare Email (用于 DNS API): " CF_EMAIL
read -rp "请输入 Cloudflare API Key: " CF_API_KEY
echo ""

echo -e "${YELLOW}脚本将清理并覆盖 /opt/vps-deploy 下的 web 内容（会备份现有配置）${NC}"
read -rp "按 Enter 开始部署 (Ctrl+C 取消)..."

# ------------------- 安装依赖 -------------------
apt update -y
apt install -y cron socat ufw curl wget tar unzip nginx

# ------------------- 防火墙 -------------------
ufw --force enable
for p in 22 443 8445 8443; do
    ufw allow $p/tcp
    ufw allow $p/udp
done

# ------------------- 拉取 Web -------------------
mkdir -p /opt/vps-deploy
cd /opt/vps-deploy
if [ -d web ]; then
    mv web web.bak.$(date +%s)
fi
git clone https://github.com/about300/vps-deployment.git web

# ------------------- subconvert -------------------
mkdir -p /opt/vps-deploy/subconvert
curl -sSL https://github.com/youshandefeiyang/sub-web-modify/releases/latest/download/subconvert_linux_amd64.tar.gz | tar -xz -C /opt/vps-deploy/subconvert
chmod +x /opt/vps-deploy/subconvert/subconvert

# ------------------- s-ui 官方面板 -------------------
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# ------------------- acme.sh (Let's Encrypt via Cloudflare DNS) -------------------
curl https://get.acme.sh | sh
source ~/.bashrc
ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh
acme.sh --set-default-ca --server letsencrypt
acme.sh --issue --dns dns_cf -d "$MAIN_DOMAIN" --keylength ec-256 --yes-I-know-dns-manual-mode-enough

# 安装证书
DOMAIN_CERT_DIR="/root"
acme.sh --install-cert -d "$MAIN_DOMAIN" --ecc \
  --key-file $DOMAIN_CERT_DIR/server.key \
  --fullchain-file $DOMAIN_CERT_DIR/server.crt \
  --reloadcmd "systemctl reload nginx"

# 自动续期脚本
cat > /root/cert-monitor.sh <<EOF
#!/bin/bash
/root/.acme.sh/acme.sh --renew -d $MAIN_DOMAIN --force --ecc \
  --key-file $DOMAIN_CERT_DIR/server.key \
  --fullchain-file $DOMAIN_CERT_DIR/server.crt \
  --reloadcmd "systemctl reload nginx"
EOF
chmod +x /root/cert-monitor.sh
(crontab -l 2>/dev/null; echo "0 3 */30 * * /root/cert-monitor.sh >>/var/log/cert-monitor.log 2>&1") | crontab -

# ------------------- nginx 配置 -------------------
cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 443 ssl http2;
    server_name $MAIN_DOMAIN;

    ssl_certificate $DOMAIN_CERT_DIR/server.crt;
    ssl_certificate_key $DOMAIN_CERT_DIR/server.key;

    root /opt/vps-deploy/web;
    index index.html;

    location / {
        try_files \$uri /index.html;
    }

    location /sub/ {
        proxy_pass http://127.0.0.1:3000/;  # subconvert 前端
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location /app/ {
        proxy_pass http://127.0.0.1:2095/;  # s-ui 面板
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}

server {
    listen 80;
    server_name $MAIN_DOMAIN;
    return 301 https://\$host\$request_uri;
}
EOF

systemctl restart nginx

# ------------------- 完成页（单独一页） -------------------
clear
echo -e "${CYAN}╔════════════════════════════════╗${NC}"
echo -e "${CYAN}║         部署完成！           ║${NC}"
echo -e "${CYAN}╚════════════════════════════════╝${NC}"
echo "Web主页:      https://$MAIN_DOMAIN"
echo "订阅转换:      https://$MAIN_DOMAIN/sub/"
echo "s-ui 管理面板: https://$MAIN_DOMAIN/app"
echo "证书路径:      $DOMAIN_CERT_DIR"
echo ""
echo -e "${YELLOW}已开启防火墙，允许端口: 22, 443, 8445, 8443${NC}"
