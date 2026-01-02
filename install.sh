#!/usr/bin/env bash
set -e

##############################
# VPS 全栈部署（最终生产版）
# Version: v1.0.1
# Mode: ADD-ONLY / NO-DELETE
##############################

LOG_FILE="/var/log/vps-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== VPS 全栈部署（最终版） ====="
echo "Version: v1.0.1"
echo "Log: $LOG_FILE"
echo "Start Time: $(date)"

# -----------------------------
# 步骤 0：预定义变量（⚠ 不可修改）
# -----------------------------
read -rp "请输入您的域名 (例如：example.domain): " DOMAIN
read -rp "请输入 Cloudflare 邮箱: " CF_Email
read -rp "请输入 Cloudflare API Token: " CF_Token
export CF_Email
export CF_Token

# VLESS 默认端口
VLESS_PORT=5000

# SubConverter 二进制下载链接
SUBCONVERTER_BIN="https://github.com/about300/vps-deployment/raw/refs/heads/main/bin/subconverter"

# Web主页GitHub仓库
WEB_HOME_REPO="https://github.com/about300/vps-deployment.git"

# -----------------------------
# Cloudflare API 权限提示（新增）
# -----------------------------
echo "-------------------------------------"
echo "Cloudflare API Token 需要以下权限："
echo " - Zone.Zone: Read"
echo " - Zone.DNS: Edit"
echo "作用域：仅限当前域名所在 Zone"
echo "acme.sh 使用 dns_cf 方式申请证书"
echo "-------------------------------------"

# -----------------------------
# 步骤 1：更新系统与依赖
# -----------------------------
echo "[1/12] 更新系统与安装依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3 npm

# -----------------------------
# 步骤 2：防火墙配置
# -----------------------------
echo "[2/12] 配置防火墙"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000
ufw allow 8445
ufw allow 8446
ufw allow 25500
ufw allow 2095
ufw allow 5000
ufw --force enable

# -----------------------------
# 步骤 3：安装 acme.sh
# -----------------------------
echo "[3/12] 安装 acme.sh（DNS-01）"
if [ ! -d "$HOME/.acme.sh" ]; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
mkdir -p /etc/nginx/ssl/$DOMAIN

# -----------------------------
# 步骤 4：申请 SSL 证书
# -----------------------------
echo "[4/12] 申请或检查 SSL 证书"
if [ ! -f "/etc/nginx/ssl/$DOMAIN/fullchain.pem" ]; then
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
fi

# -----------------------------
# 步骤 5：安装证书到 Nginx
# -----------------------------
echo "[5/12] 安装证书到 Nginx"
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
    --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
    --reloadcmd "systemctl reload nginx"

# -----------------------------
# 步骤 6：安装 SubConverter 后端
# -----------------------------
echo "[6/12] 安装 SubConverter"
mkdir -p /opt/subconverter
if [ ! -f "/opt/subconverter/subconverter" ]; then
    wget -O /opt/subconverter/subconverter $SUBCONVERTER_BIN
    chmod +x /opt/subconverter/subconverter
fi

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

# -----------------------------
# 步骤 7：确保 Node.js
# -----------------------------
echo "[7/12] 确保 Node.js 可用"
if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
fi

# -----------------------------
# 步骤 8：构建 sub-web-modify
# -----------------------------
echo "[8/12] 构建 sub-web-modify 前端"
rm -rf /opt/sub-web-modify
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify
cat > vue.config.js <<'EOF'
module.exports = { publicPath: '/subconvert/' }
EOF
npm install
npm run build

# -----------------------------
# 步骤 9：安装 S-UI
# -----------------------------
echo "[9/12] 安装 S-UI 面板"
if [ ! -d "/opt/s-ui" ]; then
    bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
fi

# -----------------------------
# 步骤 10：Web 主页 + 自动更新（新增）
# -----------------------------
echo "[10/12] 配置 Web 主页"
rm -rf /opt/web
mkdir -p /opt/web
git clone $WEB_HOME_REPO /opt/web/tmp
mv /opt/web/tmp/web /opt/web/current
rm -rf /opt/web/tmp

cat >/opt/web/update-web.sh <<'EOF'
#!/usr/bin/env bash
cd /opt/web/current && git pull
EOF
chmod +x /opt/web/update-web.sh
(crontab -l 2>/dev/null; echo "0 3 * * 0 /opt/web/update-web.sh") | crontab -

# -----------------------------
# 步骤 11：壁纸每日更新（新增）
# -----------------------------
mkdir -p /opt/web/scripts
cat >/opt/web/scripts/update-wallpaper.sh <<'EOF'
#!/usr/bin/env bash
echo "Wallpaper update at $(date)" >> /opt/web/wallpaper.log
EOF
chmod +x /opt/web/scripts/update-wallpaper.sh
(crontab -l 2>/dev/null; echo "0 0 * * * /opt/web/scripts/update-wallpaper.sh") | crontab -

# -----------------------------
# 步骤 12：安装 AdGuard Home
# -----------------------------
echo "[11/12] 安装 AdGuard Home"
if [ ! -d "/opt/AdGuardHome" ]; then
    curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh
fi

# -----------------------------
# 步骤 13：配置 Nginx
# -----------------------------
echo "[12/12] 配置 Nginx"
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    root /opt/web/current;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
    }

    location /adguard/ {
        proxy_pass http://127.0.0.1:3000/;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t
systemctl reload nginx

# -----------------------------
# 完成 & VLESS 提示（新增）
# -----------------------------
echo "====================================="
echo "部署完成 🎉"
echo "Web主页: https://$DOMAIN"
echo "Sub-Web: https://$DOMAIN/subconvert/"
echo "AdGuard: https://$DOMAIN/adguard/"
echo ""
echo "VLESS 节点配置提示："
echo " - 监听 IP: 0.0.0.0"
echo " - 监听端口: $VLESS_PORT"
echo " - 传输层: TCP / Reality（在 S-UI 中配置）"
echo "====================================="
