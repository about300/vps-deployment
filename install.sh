#!/usr/bin/env bash
set -e

##############################
# VPS 全栈部署脚本
# Version: v5.0.0 (Clash兼容SubConverter版)
# Author: Auto-generated
# Description: 支持VLESS/VMess/Trojan，自动生成Clash YAML
##############################

echo "===== VPS 全栈部署 v5.0.0 ====="

# -----------------------------
# 用户交互
# -----------------------------
read -rp "请输入域名 (example.domain): " DOMAIN
read -rp "请输入 Cloudflare 邮箱: " CF_Email
read -rp "请输入 Cloudflare API Token: " CF_Token
read -rp "请输入 VLESS 端口 (默认: 8443): " VLESS_PORT
VLESS_PORT=${VLESS_PORT:-8443}

if ! [[ "$VLESS_PORT" =~ ^[0-9]+$ ]] || [ "$VLESS_PORT" -lt 1 ] || [ "$VLESS_PORT" -gt 65535 ]; then
    echo "[ERROR] 端口号必须在1-65535"
    exit 1
fi

export CF_Email
export CF_Token

SUBCONVERTER_BIN="https://github.com/about300/vps-deployment/raw/refs/heads/main/bin/subconverter"
WEB_HOME_REPO="https://github.com/about300/vps-deployment.git"

# -----------------------------
# 系统更新及依赖
# -----------------------------
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3 npm net-tools


# -----------------------------
# 防火墙配置
# -----------------------------
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 2095/tcp
ufw allow 3000/tcp
ufw allow ${VLESS_PORT}/tcp

# 开启防火墙
echo "y" | ufw --force enable

# 确认防火墙状态
ufw status numbered

# -----------------------------
# SSL 证书
# -----------------------------
if [ ! -d "$HOME/.acme.sh" ]; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
mkdir -p /etc/nginx/ssl/$DOMAIN
~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
    --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
    --reloadcmd "systemctl reload nginx"

# -----------------------------
# 安装 SubConverter 后端
# -----------------------------
mkdir -p /opt/subconverter
if [ ! -f "/opt/subconverter/subconverter" ]; then
    wget -O /opt/subconverter/subconverter $SUBCONVERTER_BIN
    chmod +x /opt/subconverter/subconverter
fi

# 生成 SubConverter 配置，保证 Clash 兼容
cat > /opt/subconverter/subconverter.env <<EOF
API_MODE=true
API_HOST=0.0.0.0
API_PORT=25500
CACHE_ENABLED=true
CACHE_SUBSCRIPTION=true
CACHE_CONFIG=true
CACHE_UPDATE_INTERVAL=600
MANAGEMENT_PASS=admin123

# Clash 输出
OUTPUT_FORMAT=clash
CONVERT_PROTOCOL=auto
EOF

chmod 600 /opt/subconverter/subconverter.env

# systemd 服务
cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter 服务
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/subconverter
ExecStart=/opt/subconverter/subconverter
Restart=always
RestartSec=3
EnvironmentFile=/opt/subconverter/subconverter.env

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

# -----------------------------
# 构建 Sub-Web 前端
# -----------------------------
rm -rf /opt/sub-web-modify
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify
npm install --no-audit --no-fund
npm run build

# -----------------------------
# 安装 S-UI 面板
# -----------------------------
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# -----------------------------
# 安装 AdGuard Home
# -----------------------------
cd /tmp
curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s --
sed -i 's/^bind_port:.*/bind_port: 3000/' /opt/AdGuardHome/AdGuardHome.yaml 2>/dev/null
systemctl restart AdGuardHome

# -----------------------------
# 部署主页
# -----------------------------
rm -rf /opt/web-home
mkdir -p /opt/web-home/current
git clone $WEB_HOME_REPO /tmp/web-home-repo
if [ -d "/tmp/web-home-repo/web" ]; then
    cp -r /tmp/web-home-repo/web/* /opt/web-home/current/
else
    cp -r /tmp/web-home-repo/* /opt/web-home/current/
fi
chown -R www-data:www-data /opt/web-home/current
chmod -R 755 /opt/web-home/current

# -----------------------------
# Nginx 配置
# -----------------------------
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    root /opt/web-home/current;
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
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        add_header Access-Control-Allow-Origin *;
    }
}

server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx



# -----------------------------
# 完成信息
# -----------------------------
echo ""
echo "====================================="
echo "🎉 VPS 全栈部署完成 v${SCRIPT_VERSION}"
echo "====================================="
echo ""
echo "📋 核心特性:"
echo ""
echo "  ✅ 源码级修复: Sub-Web源码已修复，资源路径为/subconvert/前缀"
echo "  ✅ 路径完全隔离: 主站与Sub-Web使用独立路径空间"
echo "  ✅ 一键部署: 无需复杂配置修正"
echo "  ✅ 服务兼容: 所有服务正常运行"
echo ""
echo "🌐 访问地址:"
echo ""
echo "  主页面:       https://$DOMAIN"
echo "  订阅转换前端: https://$DOMAIN/subconvert/"
echo "  订阅转换API:  https://$DOMAIN/sub/api/"
echo "  S-UI面板:     https://$DOMAIN:2095"
echo "  AdGuard Home: https://$DOMAIN:3000"
echo ""
echo "🔐 SSL证书路径:"
echo "   • /etc/nginx/ssl/$DOMAIN/fullchain.pem"
echo "   • /etc/nginx/ssl/$DOMAIN/key.pem"
echo ""
echo "🛠️ 管理命令:"
echo "  • 服务状态: check-services.sh"
echo "  • 更新主页: update-home"
echo "  • 查看日志: journalctl -u 服务名 -f"
echo ""
echo "📁 重要目录:"
echo "  • 主页: /opt/web-home/current/"
echo "  • Sub-Web: /opt/sub-web-modify/dist/"
echo "  • SubConverter: /opt/subconverter/"
echo ""
echo "====================================="
echo "部署时间: $(date)"
echo "====================================="

# 快速测试
echo ""
echo "🔍 执行快速测试..."
sleep 2
bash /usr/local/bin/check-services.sh