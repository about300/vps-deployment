#!/usr/bin/env bash
set -e

echo "======================================"
echo " VPS 一键部署 SubConverter + Sub-Web"
echo " 统一 HTTPS 443+Search+SubConverter UI"
echo " 保持 AdGuard Home 原工作模式（端口访问）"
echo "======================================"

# 1）输入域名（变量 domin） + Cloudflare API
read -rp "请输入你的域名（将用于 HTTPS 和 SubConverter，如 example.com）: " domin
read -rp "请输入 Cloudflare 注册邮箱: " CF_EMAIL
read -rp "请输入 Cloudflare API Token: " CF_TOKEN

export CF_Email="$CF_EMAIL"
export CF_Token="$CF_TOKEN"

echo "[INFO] 更新系统 & 安装依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3

echo "[INFO] 防火墙放行常用端口"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000   # 保留 AdGuard Home 默认端口访问
ufw --force enable

echo "[INFO] 安装 acme.sh 用于 HTTPS 证书"
curl https://get.acme.sh | sh
source ~/.bashrc

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

echo "[INFO] 申请 SSL 证书（Cloudflare DNS）"
~/.acme.sh/acme.sh --issue --dns dns_cf \
    -d "$domin" \
    --keylength ec-256

CERT_DIR="/etc/nginx/ssl/$domin"
mkdir -p "$CERT_DIR"

~/.acme.sh/acme.sh --install-cert -d "$domin" --ecc \
  --key-file       "$CERT_DIR/key.pem" \
  --fullchain-file "$CERT_DIR/fullchain.pem" \
  --reloadcmd      "systemctl reload nginx"

echo "[INFO] 部署 SubConverter 后端"
mkdir -p /opt/subconverter
cd /opt/subconverter

# 从你 GitHub 仓库下载最新 binary
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

echo "[INFO] 安装 Node.js 16（兼容 Sub-Web 构建）"
curl -fsSL https://deb.nodesource.com/setup_16.x | bash -
apt install -y nodejs

echo "[INFO] 构建 Sub-Web 前端"
rm -rf /opt/sub-web
git clone https://github.com/CareyWang/sub-web.git /opt/sub-web
cd /opt/sub-web
npm install
npm run build

echo "[INFO] 准备主站 Search 页面"
mkdir -p /opt/vps-deploy
cat >/opt/vps-deploy/index.html <<EOF
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Search</title>
<style>
body { text-align:center; margin-top:15%; font-family:Arial }
a.btn { display:inline-block; padding:8px 16px; background:#0078D4; color:#fff; text-decoration:none; border-radius:4px; }
</style>
</head>
<body>
<h2>Search</h2>
<form action="https://www.bing.com/search" method="get">
<input type="text" name="q" style="width:300px; height:30px">
<br><br>
<button type="submit">Search</button>
</form>
<br><br>
<a class="btn" href="/sub/?backend=https://$domin/sub/api/">进入订阅转换</a>
</body>
</html>
EOF

echo "[INFO] 写入 Nginx 配置"
cat >/etc/nginx/sites-available/$domin <<EOF
server {
    listen 80;
    server_name $domin;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $domin;

    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/key.pem;

    # 主站 Search 页面
    location / {
        root /opt/vps-deploy;
        index index.html;
    }

    # Sub-Web 前端静态资源
    location /sub/ {
        alias /opt/sub-web/dist/;
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
}
EOF

ln -sf /etc/nginx/sites-available/$domin /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

echo "======================================"
echo "🎉 部署完成！"
echo "主站 Search:     https://$domin"
echo "订阅转换入口:   https://$domin/sub/?backend=https://$domin/sub/api/"
echo "后端 API:       https://$domin/sub/api/"
echo "AdGuard Home:   保持独立端口访问（例如 http://$domin:3000）"
echo "======================================"
