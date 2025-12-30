#!/usr/bin/env bash
set -e

echo "======================================="
echo " VPS 全栈部署（Web + Sub + AdGuard + S-UI + VLESS）"
echo " - Web 服务"
echo " - SubConverter 本地后端 (25500)"
echo " - sub-web-modify 前端"
echo " - AdGuard Home"
echo " - S-UI 面板"
echo " - Nginx stream + VLESS 共用 443"
echo " - Let's Encrypt HTTP-01 验证"
echo "======================================="

# ---------- 交互 ----------
read -rp "请输入【主站域名】（如 web.mycloudshare.org）: " WEB_DOMAIN

# ---------- 基础 ----------
echo "[1/12] 系统更新 & 基础组件"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential jq

# ---------- 防火墙 ----------
echo "[2/12] 防火墙"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 53
ufw allow 2550
ufw allow 3000
ufw allow 5001
ufw allow 8096
ufw allow 8445
ufw allow 8446
ufw --force enable

# ---------- acme.sh ----------
echo "[3/12] 安装 acme.sh（锁定 Let's Encrypt）"
if [ ! -d /root/.acme.sh ]; then
  curl https://get.acme.sh | sh
fi
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# ---------- 证书 ----------
issue_cert () {
  local domain=$1
  if [ ! -f "/etc/nginx/ssl/$domain/fullchain.pem" ]; then
    echo "申请证书：$domain"
    mkdir -p /etc/nginx/ssl/$domain
    ~/.acme.sh/acme.sh --issue --webroot /var/www/html -d "$domain"
    ~/.acme.sh/acme.sh --install-cert -d "$domain" \
      --key-file       /etc/nginx/ssl/$domain/key.pem \
      --fullchain-file /etc/nginx/ssl/$domain/fullchain.pem
  else
    echo "证书已存在，跳过：$domain"
  fi
}

echo "[4/12] 申请 SSL 证书"
issue_cert "$WEB_DOMAIN"

# ---------- 搜索主页 ----------
echo "[5/12] 搜索主页（about300/vps-deployment/web）"
if [ ! -d /opt/vps-deployment ]; then
  git clone https://github.com/about300/vps-deployment /opt/vps-deployment
else
  cd /opt/vps-deployment && git pull
fi

# ---------- SubConverter ----------
echo "[6/12] SubConverter 后端"
if [ ! -f /opt/subconverter/subconverter ]; then
  mkdir -p /opt/subconverter
  wget -O /opt/subconverter/subconverter \
    https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
  chmod +x /opt/subconverter/subconverter
fi

cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter
After=network.target

[Service]
ExecStart=/opt/subconverter/subconverter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

# ---------- Node.js LTS ----------
echo "[7/12] Node.js LTS"
if ! command -v node >/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - 
  apt install -y nodejs
fi

# ---------- sub-web-modify 前端 ----------
echo "[8/12] sub-web-modify 前端"
if [ ! -d /opt/sub-web-modify ]; then
  git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
  cd /opt/sub-web-modify
  npm install
  npm run build
fi

# ---------- S-UI 面板 ----------
echo "[9/12] S-UI（仅安装，不接管 443）"
if [ ! -d /usr/local/s-ui ]; then
  bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
fi

# ---------- AdGuard Home 安装 ----------
echo "[10/12] 安装 AdGuard Home"
if [ ! -d /opt/adguardhome ]; then
  wget -O /opt/adguardhome https://github.com/AdguardTeam/AdGuardHome/releases/download/v0.107.0/AdGuardHome_linux_amd64.tar.gz
  tar -xvf /opt/adguardhome
fi

# ---------- Nginx 配置（Web + AdGuard + S-UI + VLESS 隐蔽） ----------
echo "[11/12] Nginx Web 配置"
cat >/etc/nginx/conf.d/web.conf <<EOF
server {
    listen 80;
    server_name $WEB_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $WEB_DOMAIN;

    ssl_certificate     /etc/nginx/ssl/$WEB_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$WEB_DOMAIN/key.pem;

    root /opt/vps-deployment/web;
    index index.html;

    # 首页请求
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # 订阅转换前端
    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    # SubConverter 后端 API
    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }

    # 反向代理 AdGuard Home（通过 /adguard 路径） 
    location /adguard/ {
        proxy_pass http://127.0.0.1:3000/;  # AdGuard Home 默认端口
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # 反向代理 S-UI 面板（通过 /sui 路径） 
    location /sui/ {
        proxy_pass http://127.0.0.1:2095/;  # S-UI 面板默认端口
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# ---------- VLESS 配置（隐藏 VLESS 服务） ----------
echo "[12/12] Nginx stream 配置（VLESS 隐蔽）"
cat >/etc/nginx/stream.conf <<EOF
stream {
    map \$ssl_preread_server_name \$backend {
        $WEB_DOMAIN 127.0.0.1:4433;   # VLESS 服务通过 4433 端口处理流量
        default    127.0.0.1:4430;
    }

    server {
        listen 443 reuseport;
        ssl_preread on;
        proxy_pass \$backend;
    }
}
EOF

grep -q "stream.conf" /etc/nginx/nginx.conf || \
echo "include /etc/nginx/stream.conf;" >> /etc/nginx/nginx.conf

nginx -t
systemctl restart nginx

# ---------- 完成 ----------
echo "======================================="
echo "部署完成 🎉"
echo "---------------------------------------"
echo "主页: https://$WEB_DOMAIN"
echo
