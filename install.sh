#!/usr/bin/env bash
set -e

echo "======================================"
echo " 一键部署 SubConverter + sub-web-modify"
echo " 使用 ZeroSSL SSL 证书（无重复证书限制）"
echo "======================================"

read -rp "请输入你的域名（如 girl.example.com）: " DOMAIN
read -rp "请输入 Cloudflare 注册邮箱: " CF_EMAIL
read -rp "请输入 Cloudflare API Token: " CF_TOKEN

export CF_Email="$CF_EMAIL"
export CF_Token="$CF_TOKEN"

echo "[INFO] 更新系统 & 安装依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3

echo "[INFO] 防火墙放行端口"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000
ufw --force enable

echo "[INFO] 安装 acme.sh"
curl https://get.acme.sh | sh
# 使用 acme.sh 的完整路径以避免脚本找不到命令
ACME_SH_PATH="$HOME/.acme.sh/acme.sh"

echo "[INFO] 设置默认 CA 为 ZeroSSL（可多次调用）"
"$ACME_SH_PATH" --set-default-ca --server zerossl

echo "[INFO] 申请 ZeroSSL 证书"
"$ACME_SH_PATH" --issue \
  --dns dns_cf \
  -d "$DOMAIN" \
  --keylength ec-256 \
  --server zerossl

CERT_DIR="/etc/nginx/ssl/$DOMAIN"
mkdir -p "$CERT_DIR"

echo "[INFO] 安装证书到 Nginx"
"$ACME_SH_PATH" --install-cert -d "$DOMAIN" \
  --key-file "$CERT_DIR/key.pem" \
  --fullchain-file "$CERT_DIR/fullchain.pem" \
  --reloadcmd "systemctl reload nginx"

echo "[INFO] 部署 SubConverter 后端"
mkdir -p /opt/subconverter
cd /opt/subconverter

wget -O subconverter \
  https://github.com/about300/vps-deployment/raw/refs/heads/main/bin/subconverter
chmod +x subconverter

cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter Service
After=network.target

[Service]
ExecStart=/opt/subconverter/subconverter
WorkingDirectory=/opt/subconverter
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

echo "[INFO] 安装 Node.js 22（用于构建 sub-web-modify）"
# 移除旧版本并安装 Node 22
apt remove -y nodejs
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt install -y nodejs npm

echo "[INFO] 构建 sub-web-modify 前端"
rm -rf /opt/sub-web-modify
git clone https://github.com/youshandefeiyang/sub-web-modify.git /opt/sub-web-modify
cd /opt/sub-web-modify

# 强制 publicPath 为 /sub/ 以兼容 Nginx alias
cat >vue.config.js <<'EOF'
module.exports = {
  publicPath: '/sub/'
}
EOF

npm install
npm run build

echo "[INFO] 创建主站 Search 页面"
mkdir -p /opt/vps-deploy
cat >/opt/vps-deploy/index.html <<EOF
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
<a href="/sub/?backend=https://$DOMAIN/sub/api/">进入订阅转换</a>
</body>
</html>
EOF

echo "[INFO] 写入 Nginx 配置"
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
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

    # 主站 Search 页面
    location / {
        root /opt/vps-deploy;
        index index.html;
    }

    # sub-web-modify 前端 UI
    location /sub/ {
        alias /opt/sub-web-modify/dist/;
        index index.html;
        try_files \$uri \$uri/ /sub/index.html;
    }

    # SubConverter 后端 API 代理
    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

echo "======================================"
echo "🎉 部署完成！"
echo "主站 Search:      https://$DOMAIN"
echo "订阅转换 UI:      https://$DOMAIN/sub/?backend=https://$DOMAIN/sub/api/"
echo "后端 API:        https://$DOMAIN/sub/api/"
echo "AdGuard Home:    保留端口访问（如 http://$DOMAIN:3000）"
echo "======================================"
