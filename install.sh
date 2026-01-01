#!/usr/bin/env bash
set -e
echo "===== VPS 全栈部署 ====="

# 步骤 1：输入您的域名和 Cloudflare 凭证
read -rp "请输入您的域名 (例如：web.mycloudshare.org): " DOMAIN
read -rp "请输入您的 Cloudflare 邮箱: " CF_Email
read -rp "请输入您的 Cloudflare API Token: " CF_Token
export CF_Email
export CF_Token

# 预设 VLESS 端口（根据需要更改）
VLESS_PORT=5000  # 可以根据需要更改为任何您想要的 VLESS 端口

echo "[1/12] 更新系统并安装依赖项"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3

echo "[2/12] 配置防火墙"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 8443
ufw allow 3000
ufw allow 8445
ufw allow 53
ufw allow 2550
ufw --force enable

echo "[3/12] 安装 acme.sh 用于 DNS-01 验证"
# 检查 acme.sh 是否已安装
if [ ! -d "$HOME/.acme.sh" ]; then
  curl https://get.acme.sh | sh
  source ~/.bashrc
else
  echo "[INFO] acme.sh 已安装，跳过安装。"
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
mkdir -p /etc/nginx/ssl/$DOMAIN

# 使用 Cloudflare 的 DNS-01 验证
echo "[4/12] 通过 Cloudflare 申请 SSL 证书"
# 如果证书已存在，跳过证书申请
if [ ! -f "/etc/nginx/ssl/$DOMAIN/fullchain.pem" ]; then
  echo "[INFO] 未找到 SSL 证书，正在申请..."
  ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
else
  echo "[INFO] SSL 证书已存在，跳过证书申请。"
fi

# 安装证书到 Nginx
echo "[5/12] 安装 SSL 证书到 Nginx"
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
  --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
  --reloadcmd "systemctl reload nginx"

echo "[6/12] 安装 SubConverter 后端"
# 检查 SubConverter 二进制文件是否存在，如果没有则复制二进制文件
if [ ! -f "/opt/subconverter/subconverter" ]; then
  echo "[INFO] 未找到 SubConverter 二进制文件，正在复制..."
  cp /path/to/your/subconverter /opt/subconverter/subconverter
  chmod +x /opt/subconverter/subconverter
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
else
  echo "[INFO] SubConverter 二进制文件已存在，跳过复制。"
fi

echo "[7/12] 安装 Node.js (LTS)"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

echo "[8/12] 构建 sub-web-modify (来自 about300 仓库)"
# 检查 sub-web-modify 是否存在，如果不存在，则克隆并构建
if [ ! -d "/opt/sub-web-modify" ]; then
  echo "[INFO] 未找到 sub-web-modify，正在克隆并构建..."
  rm -rf /opt/sub-web-modify
  git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
  cd /opt/sub-web-modify
  npm install
  npm run build
else
  echo "[INFO] sub-web-modify 已存在，跳过克隆。"
fi

echo "[9/12] 安装 S-UI 面板 (仅本地监听)"
# 检查 S-UI 面板是否已安装
if [ ! -d "/opt/s-ui" ]; then
  echo "[INFO] S-UI 面板未安装，正在安装..."
  bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
else
  echo "[INFO] S-UI 面板已安装，跳过安装。"
fi

echo "[10/12] 克隆 Web 文件从 GitHub"
# 检查 web-home 文件夹是否存在，如果没有则克隆
if [ ! -d "/opt/web-home" ]; then
  echo "[INFO] 未找到 web-home，正在克隆..."
  rm -rf /opt/web-home
  git clone https://github.com/about300/vps-deployment.git /opt/web-home
  mv /opt/web-home/web /opt/web-home/current
else
  echo "[INFO] web-home 已存在，跳过克隆。"
fi

echo "[11/12] 配置 Nginx 用于 Web 和 API"
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    
    ssl_certificate     /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    # 主页：指向 Web 内容并支持搜索功能
    root /opt/web-home/current;
    index index.html;
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # 订阅转换前端：指向 Sub-Web-Modify 构建的静态文件
    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        try_files \$uri \$uri/ /subconvert/index.html;
    }

    # 订阅转换后端：代理到本地 SubConverter 服务
    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }

    # VLESS 订阅：通过反向代理将流量转发到 S-UI 中设置的 VLESS 服务
    location /vless/ {
        proxy_pass http://127.0.0.1:$VLESS_PORT;  # 使用预设的端口
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }
}
EOF
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t
systemctl reload nginx

echo "[12/12] 安装 AdGuard Home (端口 3000)"
curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh

echo "[13/12] 完成 🎉"
echo "====================================="
echo "Web 主页: https://$DOMAIN"
echo "SubConverter API: https://$DOMAIN/sub/api/"
echo "S-UI 面板: http://127.0.0.1:2095"
echo "====================================="
