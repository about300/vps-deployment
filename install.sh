#!/bin/bash
# ==================== 用户输入页面 ====================
CYAN="\033[0;36m"
YELLOW="\033[1;33m"
NC="\033[0m"

clear
echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     VPS 全栈部署脚本 - Ubuntu24    ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
echo ""

read -rp "请输入主域名 (例如: example.com): " MAIN_DOMAIN
read -rp "请输入邮箱 (用于申请 SSL): " CERT_EMAIL
read -rp "请输入 Cloudflare API Token: " CF_Token
echo ""

echo "配置摘要："
echo "  - 主域名: $MAIN_DOMAIN"
echo "  - 证书邮箱: $CERT_EMAIL"
echo ""

echo "脚本将清理并覆盖 /opt/vps-deploy 下的 web 内容（会备份现有配置）"
read -rp "按 Enter 开始部署 (Ctrl+C 取消)..." dummy

# ==================== 基础工具安装 ====================
apt update -y
apt install -y cron socat ufw curl wget tar unzip git

# ==================== 防火墙设置 ====================
ufw --force enable
for p in 22 80 443 8445 8443; do
    ufw allow $p/tcp
    ufw allow $p/udp
done

# ==================== Web 前端部署 ====================
DEPLOY_DIR="/opt/vps-deploy"
BACKUP_DIR="/opt/vps-deploy-backup-$(date +%s)"
if [ -d "$DEPLOY_DIR" ]; then
    echo "备份现有 /opt/vps-deploy 到 $BACKUP_DIR"
    mv "$DEPLOY_DIR" "$BACKUP_DIR"
fi
echo "下载 Web 前端内容..."
git clone https://github.com/about300/vps-deployment.git "$DEPLOY_DIR"

# ==================== acme.sh + 证书 ====================
ACME_CMD="/root/.acme.sh/acme.sh"
if [ ! -f "$ACME_CMD" ]; then
    echo "安装 acme.sh..."
    curl https://get.acme.sh | sh
    source ~/.bashrc
    ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh
    "$ACME_CMD" --set-default-ca --server letsencrypt
fi

export CF_Token="$CF_Token"

# DNS-01 方式签发证书
"$ACME_CMD" --issue --dns dns_cf -d "$MAIN_DOMAIN" -d "*.$MAIN_DOMAIN" -m "$CERT_EMAIL" --server letsencrypt --keylength ec-256 || { echo "证书签发失败"; exit 1; }

DOMAIN_CERT_DIR="/root"
"$ACME_CMD" --install-cert -d "$MAIN_DOMAIN" \
  --key-file "$DOMAIN_CERT_DIR/server.key" \
  --fullchain-file "$DOMAIN_CERT_DIR/server.crt" \
  --reloadcmd "systemctl reload nginx" --ecc || { echo "证书安装失败"; exit 1; }

chmod 600 "$DOMAIN_CERT_DIR/server.key"
chmod 644 "$DOMAIN_CERT_DIR/server.crt"

# 自动续签
echo -e "#!/bin/bash\n$ACME_CMD --renew -d $MAIN_DOMAIN --force --ecc --key-file $DOMAIN_CERT_DIR/server.key --fullchain-file $DOMAIN_CERT_DIR/server.crt" >/root/cert-monitor.sh
chmod +x /root/cert-monitor.sh
(crontab -l 2>/dev/null; echo "0 3 */30 * * /root/cert-monitor.sh >>/var/log/cert-monitor.log 2>&1") | crontab -

# ==================== 安装 s-ui ====================
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# ==================== 安装 AdGuardHome ====================
curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh

# ==================== 部署完成页面 ====================
clear
echo -e "${CYAN}╔════════════════════════════════╗${NC}"
echo -e "${CYAN}║         部署完成！           ║${NC}"
echo -e "${CYAN}╚════════════════════════════════╝${NC}"
echo "Web主页:      https://$MAIN_DOMAIN"
echo "订阅转换:      https://$MAIN_DOMAIN/sub/"
echo "s-ui 管理面板: https://$MAIN_DOMAIN/app"
echo "证书路径:      $DOMAIN_CERT_DIR"
echo ""
echo -e "${YELLOW}已开启防火墙，允许端口: 22, 80, 443, 8445, 8443${NC}"
