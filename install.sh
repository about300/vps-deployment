#!/bin/bash
# ==================== 开头页（固定样式） ====================
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
echo -e "${CYAN}╔════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     VPS 全栈部署脚本 - Ubuntu24    ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════╝${NC}"
echo ""

# ------------------- 用户输入 -------------------
read -rp "请输入主域名 (例如: example.com): " MAIN_DOMAIN
read -rp "请输入邮箱 (用于申请 SSL，Let's Encrypt 通知): " CERT_EMAIL
echo ""
echo "配置摘要："
echo "  - 主域名: $MAIN_DOMAIN"
echo "  - 证书邮箱: $CERT_EMAIL"
echo ""
echo "脚本将清理并覆盖 /opt/vps-deploy 下的 web 内容（会备份现有配置）"
read -rp "按 Enter 开始部署 (Ctrl+C 取消)..." dummy

# ==================== 安装必要软件 ====================
apt update -y
apt install -y nginx unzip curl wget git socat ufw cron

# ==================== 配置防火墙 ====================
ufw --force enable
for p in 22 80 443 8445 8443; do
    ufw allow $p/tcp
    ufw allow $p/udp
done

# ==================== 部署 Web 目录 ====================
WEB_DIR="/opt/vps-deploy/web"
mkdir -p "$WEB_DIR"
# 备份已有内容
[ -d "$WEB_DIR" ] && mv "$WEB_DIR" "${WEB_DIR}_backup_$(date +%s)"
# 拉取你的 web 仓库内容
git clone --depth=1 https://github.com/about300/vps-deployment.git /tmp/vps-deploy-temp
cp -r /tmp/vps-deploy-temp/web "$WEB_DIR"
rm -rf /tmp/vps-deploy-temp

# ==================== 安装 acme.sh ====================
apt install -y socat
curl https://get.acme.sh | sh
source ~/.bashrc
ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh
acme.sh --set-default-ca --server letsencrypt

# ==================== 申请证书（不停止 nginx） ====================
CERT_DIR="/root"
acme.sh --issue --standalone -d "$MAIN_DOMAIN" --force --keylength ec-256
acme.sh --install-cert -d "$MAIN_DOMAIN" \
    --ecc \
    --key-file "$CERT_DIR/server.key" \
    --fullchain-file "$CERT_DIR/server.crt" \
    --reloadcmd "systemctl reload nginx"

# ==================== s-ui 面板 ====================
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# ==================== Subconverter 后端 + 前端 ====================
# 下载 Subconverter 二进制
SUBC_DIR="/opt/subconverter"
mkdir -p "$SUBC_DIR"
curl -L -o "$SUBC_DIR/Subconverter" https://github.com/ACL4SSR/ACL4SSR-Subconverter/releases/latest/download/Subconverter-linux
chmod +x "$SUBC_DIR/Subconverter"

# 配置 Subconverter API
nohup "$SUBC_DIR/Subconverter" -l 25500 -d "$SUBC_DIR" &

# 前端 (你本地 web/sub 已经有静态资源)
cp -r "$WEB_DIR/sub" /opt/sub-web

# ==================== 完成页（单独一页） ====================
clear
echo -e "${CYAN}╔════════════════════════════════╗${NC}"
echo -e "${CYAN}║         部署完成！           ║${NC}"
echo -e "${CYAN}╚════════════════════════════════╝${NC}"
echo "Web主页:      https://$MAIN_DOMAIN"
echo "订阅转换:      https://$MAIN_DOMAIN/sub/"
echo "s-ui 管理面板: https://$MAIN_DOMAIN/app"
echo "证书路径:      $CERT_DIR"
echo ""
echo -e "${YELLOW}已开启防火墙，允许端口: 22, 80, 443, 8445, 8443${NC}"

# ==================== 证书自动续期脚本 ====================
cat > /root/cert-monitor.sh <<EOF
#!/bin/bash
/root/.acme.sh/acme.sh --renew -d $MAIN_DOMAIN --force --ecc --key-file /root/server.key --fullchain-file /root/server.crt
systemctl reload nginx
EOF
chmod +x /root/cert-monitor.sh
(crontab -l 2>/dev/null; echo "0 3 */30 * * /root/cert-monitor.sh >>/var/log/cert-monitor.log 2>&1") | crontab -
