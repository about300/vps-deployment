sudo tee /root/install.sh > /dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# install.sh - 一键部署 SubConverter + sub-web-modify + S-UI + AdGuard
# Usage: sudo ./install.sh
# 脚本会交互询问：域名、Cloudflare 邮箱、Cloudflare API Token、sub-web 仓库地址

# ---- interactive inputs ----
read -rp "请输入你的域名（例如 example.com）: " DOMAIN
read -rp "请输入 Cloudflare 注册邮箱 (用于 acme.sh DNS 验证): " CF_EMAIL
read -rp "请输入 Cloudflare API Token (具有 DNS 编辑权限): " CF_TOKEN
read -rp "请输入你的 sub-web-modify 仓库 HTTPS 地址（默认 https://github.com/about300/sub-web-modify.git）: " SUBWEB_REPO
SUBWEB_REPO="${SUBWEB_REPO:-https://github.com/about300/sub-web-modify.git}"

export CF_Email="$CF_EMAIL"
export CF_Token="$CF_TOKEN"

echo
echo "==> 开始部署： $DOMAIN"
echo

# ---- basic packages ----
echo "[1/14] 更新 apt 并安装基础组件..."
apt update -y
DEBS="curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3 ca-certificates"
apt install -y $DEBS

# ---- firewall ----
echo "[2/14] 配置防火墙 (22,80,443,3000,8445)..."
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000
ufw allow 8445
ufw --force enable

# ---- acme.sh / cert ----
echo "[3/14] 安装 acme.sh (用于 Let'\''s Encrypt DNS-01 via Cloudflare)..."
curl -sS https://get.acme.sh | sh
ACME_SH="$HOME/.acme.sh/acme.sh"
if [ ! -f "$ACME_SH" ]; then
  echo "!! acme.sh 安装失败，请检查网络或手动安装再重试."
  exit 1
fi

echo "[4/14] 设置 acme.sh 默认 CA 为 letsencrypt 并申请证书（DNS: dns_cf）..."
"$ACME_SH" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

CERT_DIR="/etc/nginx/ssl/$DOMAIN"
mkdir -p "$CERT_DIR"

# export CF env already set above; acme.sh will read CF_Token/CF_Email
if "$ACME_SH" --renew -d "$DOMAIN" --force >/dev/null 2>&1; then
  echo "[4.1] 证书已存在并续期成功（或存在）"
else
  echo "[4.2] 申请新证书（需要 Cloudflare DNS 记录自动验证）"
  "$ACME_SH" --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
fi

echo "[4.3] 将证书安装到 $CERT_DIR 并配置 nginx reload 命令"
"$ACME_SH" --install-cert -d "$DOMAIN" \
  --key-file "$CERT_DIR/key.pem" \
  --fullchain-file "$CERT_DIR/fullchain.pem" \
  --reloadcmd "systemctl reload nginx"

# ---- SubConverter backend ----
echo "[5/14] 部署 SubConverter 后端 (/opt/subconverter)..."
mkdir -p /opt/subconverter
cd /opt/subconverter
wget -q -O subconverter https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
chmod +x subconverter || true

cat >/etc/systemd/system/subconverter.service <<'UNIT'
[Unit]
Description=SubConverter Service
After=network.target

[Service]
ExecStart=/opt/subconverter/subconverter
WorkingDirectory=/opt/subconverter
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now subconverter

# ---- clone and build sub-web-modify ----
echo "[6/14] 克隆 sub-web-modify 源码 并写入 publicPath=/sub/（确保子路径正确）"
rm -rf /opt/sub-web-src
git clone "$SUBWEB_REPO" /opt/sub-web-src

# 写入 vue.config.js 覆盖 publicPath（保证部署在 /sub/）
cat >/opt/sub-web-src/vue.config.js <<'VCONF'
module.exports = {
  publicPath: "/sub/"
};
VCONF

# ---- nvm + node ----
echo "[7/14] 安装 nvm 并用 nvm 安装 Node.js 22"
export NVM_DIR="$HOME/.nvm"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.6/install.sh | bash
fi
# shellcheck source=/dev/null
if [ -s "$NVM_DIR/nvm.sh" ]; then
  . "$NVM_DIR/nvm.sh"
else
  echo "!! nvm 安装或加载失败，请检查并手动安装 nvm."
fi
if command -v nvm >/dev/null 2>&1; then
  nvm install 22
  nvm use 22
fi

echo "[8/14] 在 /opt/sub-web-src 安装依赖并构建（可能较久）"
cd /opt/sub-web-src
# some repos use package-lock, yarn, etc. npm should work for this project
npm install --no-audit --no-fund
npm run build

# ---- copy build to target ----
echo "[9/14] 复制构建产物到 /opt/sub-web-modify/dist"
rm -rf /opt/sub-web-modify/dist
mkdir -p /opt/sub-web-modify/dist
cp -r /opt/sub-web-src/dist/* /opt/sub-web-modify/dist/

# 确保 nginx 用户可读
chown -R www-data:www-data /opt/sub-web-modify/dist || true
chmod -R a+r /opt/sub-web-modify/dist || true

# ---- Search 首页 ----
echo "[10/14] 创建 Search 首页 (/opt/vps-deploy/index.html)"
mkdir -p /opt/vps-deploy
cat >/opt/vps-deploy/index.html <<'HTML'
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>Search</title></head>
<body style="text-align:center;margin-top:15%">
<h2>Search</h2>
<form action="https://www.bing.com/search" method="get">
<input name="q" style="width:300px;height:30px">
<br><br>
<button type="submit">Search</button>
</form>
<br><br>
<a href="/sub/?backend=https://__DOMAIN__/sub/api/">进入订阅转换</a>
</body>
</html>
HTML
# 替换 DOMAIN 占位符
sed -i "s|__DOMAIN__|${DOMAIN}|g" /opt/vps-deploy/index.html
chown -R www-data:www-data /opt/vps-deploy || true

# ---- AdGuard Home ----
echo "[11/14] 安装 AdGuard Home（3000）"
curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh || true

# ---- S-UI 面板 ----
echo "[12/14] 安装 S-UI 面板（默认 2095/2096，本机/隧道访问）"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh) || true

# ---- nginx 配置 ----
echo "[13/14] 写入 nginx 配置并启用站点"
NG_CONF="/etc/nginx/sites-available/$DOMAIN"
cat >"$NG_CONF" <<NGCFG
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/key.pem;

    # Search 首页
    location / {
        root /opt/vps-deploy;
        index index.html;
        try_files \$uri \$uri/ =404;
    }

    # sub-web-modify (SPA)
    location /sub/ {
        alias /opt/sub-web-modify/dist/;
        index index.html;
        try_files \$uri \$uri/ /sub/index.html;
    }

    # SubConverter 后端 API
    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # S-UI 面板（通过 SSH 隧道访问）
    location /ui/ {
        proxy_pass http://127.0.0.1:2095/app/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # S-UI 订阅服务
    location /suibs/ {
        proxy_pass http://127.0.0.1:2096/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGCFG

ln -sf "$NG_CONF" /etc/nginx/sites-enabled/"$DOMAIN"
rm -f /etc/nginx/sites-enabled/default || true

echo "[14/14] 测试 nginx 配置并重载"
nginx -t
systemctl reload nginx

echo
echo "======================================"
echo "部署完成 🎉"
echo "• 访问 Search 首页: https://$DOMAIN"
echo "• 订阅转换 UI:     https://$DOMAIN/sub/?backend=https://$DOMAIN/sub/api/"
echo "• SubConverter API: https://$DOMAIN/sub/api/"
echo "• S-UI 面板: 通过 SSH 隧道访问 127.0.0.1:2095 (ssh -L 2095:127.0.0.1:2095 root@your.vps)"
echo "• AdGuard Home: http://$DOMAIN:3000"
echo "• DoH / 备用端口已放行: 8445"
echo
echo "注意：Reality / VLESS 节点请在 S-UI 面板里手动添加并设置 TLS/SNI (例如 www.51kankan.vip)；"
echo "如果访问 /sub/ 仍然空白，请清浏览器缓存或把 Cloudflare 暂时设为 DNS 解析（暂停代理）以便排查。"
echo "======================================"
EOF

sudo chmod +x /root/install.sh
echo "脚本已写入 /root/install.sh —— 运行： sudo /root/install.sh"
