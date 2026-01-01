#!/usr/bin/env bash
set -e

echo "===== VPS 全栈部署（最终稳定版） ====="

# -----------------------------
# 步骤 0：基础变量（只在首次使用）
# -----------------------------
read -rp "请输入你的域名（例如：roa.mycloudshare.org）: " DOMAIN
read -rp "请输入 Cloudflare 邮箱: " CF_Email
read -rp "请输入 Cloudflare API Token: " CF_Token

export CF_Email
export CF_Token

# VLESS 默认端口（给 S-UI 用）
VLESS_PORT=5000

# SubConverter 二进制（你明确指定，禁止再改）
SUBCONVERTER_BIN="https://github.com/about300/vps-deployment/raw/refs/heads/main/bin/subconverter"

# 统一路径
SUBCONVERTER_DIR="/opt/subconverter"
SUBWEB_DIR="/opt/sub-web-modify"
WEBHOME_DIR="/opt/web-home"

# -----------------------------
# 步骤 1：系统依赖
# -----------------------------
echo "[1/12] 更新系统并安装基础依赖"
apt update -y
apt install -y \
  curl wget git unzip socat cron ufw nginx \
  build-essential python3 python-is-python3 npm

# -----------------------------
# 步骤 2：防火墙
# -----------------------------
echo "[2/12] 配置防火墙"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 53
ufw --force enable || true

# -----------------------------
# 步骤 3：安装 acme.sh
# -----------------------------
echo "[3/12] 检查并安装 acme.sh"
if [ ! -d "$HOME/.acme.sh" ]; then
  curl https://get.acme.sh | sh
  source ~/.bashrc
else
  echo "[INFO] acme.sh 已存在，跳过"
fi

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
mkdir -p /etc/nginx/ssl/"$DOMAIN"

# -----------------------------
# 步骤 4：申请证书（DNS-01）
# -----------------------------
echo "[4/12] 申请或复用 SSL 证书"
if [ ! -f "/etc/nginx/ssl/$DOMAIN/fullchain.pem" ]; then
  ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
else
  echo "[INFO] 证书已存在，跳过申请"
fi

# -----------------------------
# 步骤 5：安装证书到 Nginx
# -----------------------------
echo "[5/12] 安装证书到 Nginx"
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file       /etc/nginx/ssl/$DOMAIN/key.pem \
  --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
  --reloadcmd "systemctl reload nginx"

# -----------------------------
# 步骤 6：SubConverter 后端（二进制）
# -----------------------------
echo "[6/12] 安装 SubConverter 后端"
mkdir -p "$SUBCONVERTER_DIR"

if [ ! -f "$SUBCONVERTER_DIR/subconverter" ]; then
  echo "[INFO] 下载 SubConverter 二进制"
  wget -O "$SUBCONVERTER_DIR/subconverter" "$SUBCONVERTER_BIN"
  chmod +x "$SUBCONVERTER_DIR/subconverter"
else
  echo "[INFO] SubConverter 已存在，跳过"
fi

# systemd 服务
cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter 后端服务
After=network.target

[Service]
ExecStart=$SUBCONVERTER_DIR/subconverter
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

# -----------------------------
# 步骤 7：Node.js 环境
# -----------------------------
echo "[7/12] 检查 Node.js"
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt install -y nodejs
else
  echo "[INFO] Node.js 已存在"
fi

# -----------------------------
# 步骤 8：构建 sub-web-modify 前端
# -----------------------------
echo "[8/12] 构建 SubConverter 前端"
rm -rf "$SUBWEB_DIR"
git clone https://github.com/about300/sub-web-modify "$SUBWEB_DIR"
cd "$SUBWEB_DIR"

# 固定 publicPath，防止白屏
cat > vue.config.js <<'EOF'
module.exports = {
  publicPath: '/subconvert/'
}
EOF

npm install
npm run build

# -----------------------------
# 步骤 9：安装 S-UI 面板
# -----------------------------
echo "[9/12] 安装 S-UI 面板（本地监听）"
if [ ! -d "/opt/s-ui" ]; then
  bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
else
  echo "[INFO] S-UI 已存在，跳过"
fi

# -----------------------------
# 步骤 10：主页 Web
# -----------------------------
echo "[10/12] 部署主页 Web"
rm -rf "$WEBHOME_DIR"
git clone https://github.com/about300/vps-deployment.git "$WEBHOME_DIR"
mv "$WEBHOME_DIR/web" "$WEBHOME_DIR/current"

# -----------------------------
# 步骤 11：Nginx（核心修复在这里）
# -----------------------------
echo "[11/12] 写入 Nginx 配置（已修复 SubConverter API）"

cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    # 主页
    root $WEBHOME_DIR/current;
    index index.html;
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # SubConverter 前端
    location /subconvert/ {
        alias $SUBWEB_DIR/dist/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    # SubConverter 后端 API（关键修复：rewrite）
    location /sub/api/ {
        rewrite ^/sub/api/?(.*)$ /\$1 break;
        proxy_pass http://127.0.0.1:25500;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }

    # VLESS（给 S-UI 用）
    location /vless/ {
        proxy_pass http://127.0.0.1:$VLESS_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

# -----------------------------
# 步骤 12：AdGuard Home
# -----------------------------
echo "[12/12] 安装 AdGuard Home（可重复执行）"
if [ ! -d "/opt/AdGuardHome" ]; then
  curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh
else
  echo "[INFO] AdGuard Home 已存在，跳过"
fi

# -----------------------------
# 完成
# -----------------------------
echo "======================================"
echo "🎉 部署完成"
echo "主页: https://$DOMAIN"
echo "SubConverter 前端: https://$DOMAIN/subconvert/"
echo "SubConverter API: https://$DOMAIN/sub/api/version"
echo "======================================"
