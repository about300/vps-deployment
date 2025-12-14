#!/bin/bash
set -e

# ====== 用户配置区 ======
# 修改为你的主域名（不带 https://），如 example.org
DOMAIN="example.org"

# Cloudflare API 令牌，需填写（仅限 DNS 级 token）
CLOUDFLARE_API_TOKEN="你的_Cloudflare_API_Token"  # <-- 填写 Cloudflare API Token
export CF_Token="${CLOUDFLARE_API_TOKEN}"
# 若需要，可填写 Cloudflare 账号 ID（可留空）
export CF_Account_ID=""

# =======================

# 检查是否以 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 权限运行此脚本"
  exit 1
fi

# 更新系统并安装基础依赖
apt update
apt install -y nginx git curl wget ufw unzip software-properties-common

# 安装 Node.js（用于构建 Vue 前端）
if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
    apt install -y nodejs
fi

# 设置防火墙（UFW）：允许 SSH(22)、HTTP(80)、HTTPS(443)、s-ui(2095)、AdGuard(3000) 等端口
ufw allow 22,80,443,2095,3000/tcp
ufw --force enable

# ===== 主站 Web UI 设置 =====
mkdir -p /var/www/html
cat > /var/www/html/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"><title>主站首页</title></head>
<body>
  <h1>欢迎访问主站</h1>
  <p><a href="/sub/">进入订阅转换</a></p>
  <p><a href="https://example.org:2095/" target="_blank">s-ui 面板</a> | 
     <a href="https://example.org:3000/" target="_blank">AdGuard Home</a></p>
</body>
</html>
EOF
# 这里的 example.org 应替换为实际域名

# ==== 部署 SubConverter 后端 ====
mkdir -p /opt
echo "下载 SubConverter 二进制文件..."
wget -O /opt/subconverter https://raw.githubusercontent.com/about300/vps-deployment/refs/heads/main/bin/subconverter
chmod +x /opt/subconverter

# 创建 systemd 服务
cat > /etc/systemd/system/subconverter.service <<'EOF'
[Unit]
Description=SubConverter Service
After=network.target

[Service]
Type=simple
ExecStart=/opt/subconverter -s 127.0.0.1:25500
Restart=always
User=nobody
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now subconverter.service

# ==== 部署 SubConverter 前端 (sub-web) ====
echo "克隆并构建 Sub-web 前端..."
git clone https://github.com/Marcus0605/Sub-web.git /opt/sub-web
cd /opt/sub-web
npm install
npm run build
# 假设构建后文件位于 /opt/sub-web/dist

# ==== 安装并配置 SSL 证书（acme.sh + Cloudflare DNS） ====
echo "安装 acme.sh 并请求 SSL 证书..."
curl https://get.acme.sh | sh
export CF_Token="${CLOUDFLARE_API_TOKEN}"
export CF_Account_ID="${CF_Account_ID}"
# 签发证书（DNS 验证）。这里仅示例含两域名：主域 + www 子域
~/.acme.sh/acme.sh --issue --dns dns_cf -d "${DOMAIN}" -d "www.${DOMAIN}" --keylength ec-256
mkdir -p /etc/nginx/ssl
~/.acme.sh/acme.sh --install-cert --domain "${DOMAIN}" \
    --key-file       /etc/nginx/ssl/${DOMAIN}.key    \
    --fullchain-file /etc/nginx/ssl/${DOMAIN}.crt   \
    --reloadcmd     "systemctl reload nginx"

# ==== Nginx 配置 ====
echo "配置 Nginx..."
# 备份默认配置
mv /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/default.bak >/dev/null 2>&1 || true

cat > /etc/nginx/sites-available/${DOMAIN}.conf <<EOF
server {
    listen 80;
    listen 443 ssl http2;
    server_name ${DOMAIN} www.${DOMAIN};

    ssl_certificate     /etc/nginx/ssl/${DOMAIN}.crt;
    ssl_certificate_key /etc/nginx/ssl/${DOMAIN}.key;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # 主站页面
    root /var/www/html;
    index index.html index.htm;

    # SubConverter 前端 (Vue) 静态托管
    location ^~ /sub/ {
        alias /opt/sub-web/dist/;
        index index.html;
        try_files \$uri \$uri/ /sub/index.html;
    }
    # SubConverter 后端代理
    location /sub {
        proxy_pass http://127.0.0.1:25500/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

ln -sf /etc/nginx/sites-available/${DOMAIN}.conf /etc/nginx/sites-enabled/

# 检查 Nginx 配置并重启
nginx -t
systemctl reload nginx

# ==== 安装 AdGuard Home（可选） ====
echo "安装 AdGuard Home..."
AGH_URL=$(curl -s https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest | grep browser_download_url | grep Linux_amd64 | cut -d '"' -f4)
wget -O /tmp/AdGuardHome.tar.gz "$AGH_URL"
tar xzf /tmp/AdGuardHome.tar.gz -C /opt
cd /opt/AdGuardHome*
./AdGuardHome -s install
systemctl enable adguardhome.service
systemctl start adguardhome.service

echo "部署完成！请通过 https://${DOMAIN} 访问主站，并访问 https://${DOMAIN}/sub/ 进行订阅转换。"
