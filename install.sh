#!/usr/bin/env bash
set -e

echo "======================================="
echo " VPS 全栈部署（Web + Sub + Reality）"
echo " - 搜索主页（about300/vps-deployment/web）"
echo " - SubConverter 本地后端 (25500)"
echo " - sub-web-modify 前端"
echo " - Nginx stream + Reality 共用 443"
echo " - Cloudflare DNS-01 + Let's Encrypt"
echo "======================================="

# ---------- 交互 ----------
read -rp "请输入【主站域名】（如 web.mycloudshare.org）: " WEB_DOMAIN
read -rp "请输入【Reality 域名】（如 web.vl.mycloudshare.org）: " VL_DOMAIN

export CF_Token
read -rp "请输入 Cloudflare API Token（DNS 编辑权限）: " CF_Token
echo
export CF_Account_ID
read -rp "请输入 Cloudflare Account ID（可留空）: " CF_Account_ID

# ---------- 基础 ----------
echo "[1/12] 系统更新 & 基础组件"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential

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
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$domain"
    ~/.acme.sh/acme.sh --install-cert -d "$domain" \
      --key-file       /etc/nginx/ssl/$domain/key.pem \
      --fullchain-file /etc/nginx/ssl/$domain/fullchain.pem
  else
    echo "证书已存在，跳过：$domain"
  fi
}

echo "[4/12] 申请 SSL 证书"
issue_cert "$WEB_DOMAIN"
issue_cert "$VL_DOMAIN"

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

# ---------- Node ----------
echo "[7/12] Node.js LTS"
if ! command -v node >/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt install -y nodejs
fi

# ---------- sub-web-modify ----------
echo "[8/12] sub-web-modify 前端"
if [ ! -d /opt/sub-web-modify ]; then
  git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
  cd /opt/sub-web-modify
  npm install
  npm run build
fi

# ---------- S-UI ----------
echo "[9/12] S-UI（仅安装，不接管 443）"
if [ ! -d /usr/local/s-ui ]; then
  bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
fi

# ---------- Nginx HTTP ----------
echo "[10/12] Nginx Web 配置"
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
        proxy_set_header X-Forwarded-For \$remote_addr;
    }
}
EOF

# ---------- Nginx stream ----------
echo "[11/12] Nginx stream（Reality 共用 443）"
cat >/etc/nginx/stream.conf <<EOF
stream {
    map \$ssl_preread_server_name \$backend {
        $VL_DOMAIN 127.0.0.1:4433;
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
echo "[12/12] 完成 🎉"
echo "---------------------------------------"
echo "主页: https://$WEB_DOMAIN"
echo "订阅转换: https://$WEB_DOMAIN/subconvert"
echo "Sub API: https://$WEB_DOMAIN/sub/api/"
echo
echo "Reality 域名（S-UI 中使用）:"
echo "  $VL_DOMAIN"
echo "  监听端口：4433（示例）"
echo "---------------------------------------"
