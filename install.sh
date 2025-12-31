#!/usr/bin/env bash
set -e

echo "======================================"
echo "全栈一键部署：Web 主页 + VLESS + TLS + Nginx"
echo "======================================"

read -rp "请输入主域名（如 web.mycloudshare.org）: " DOMAIN
read -rp "请输入订阅域名前缀（如 sub）: " SUB_DOMAIN

# 1. 更新系统并安装基础组件
echo "[1/10] 更新系统"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3

# 2. 防火墙配置
echo "[2/10] 配置防火墙"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000
ufw allow 8445
ufw allow 8446
ufw --force enable

# 3. 安装 acme.sh 并申请证书（通过 DNS-01 方式）
echo "[3/10] 安装 acme.sh 并获取 Let's Encrypt 证书"
curl https://get.acme.sh | sh
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
mkdir -p /etc/nginx/ssl/$DOMAIN

# 申请证书
~/.acme.sh/acme.sh --issue -d "$DOMAIN" --dns dns_cf || true
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
  --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
  --reloadcmd "systemctl reload nginx"

# 4. 安装 V2Ray 后端（VLESS）
echo "[4/10] 安装 V2Ray 后端"
mkdir -p /opt/v2ray
cd /opt/v2ray
wget https://github.com/v2ray/v2ray-core/releases/download/v4.45.1/v2ray-linux-amd64-v4.45.1.tar.gz
tar -xvf v2ray-linux-amd64-v4.45.1.tar.gz
rm v2ray-linux-amd64-v4.45.1.tar.gz

cat > /etc/systemd/system/v2ray.service <<EOF
[Unit]
Description=V2Ray
After=network.target

[Service]
ExecStart=/opt/v2ray/v2ray -config /opt/v2ray/config.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable v2ray
systemctl start v2ray

# 5. 安装 SubConverter 后端
echo "[5/10] 安装 SubConverter 后端"
mkdir -p /opt/subconverter
cd /opt/subconverter
wget -O subconverter https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
chmod +x subconverter

cat > /etc/systemd/system/subconverter.service <<EOF
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
systemctl start subconverter

# 6. 构建 Sub-Web-Modify 前端
echo "[6/10] 构建 sub-web-modify 前端"
rm -rf /opt/sub-web-modify
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify
npm install
npm run build

# 7. 安装 S-UI 面板（仅安装，不启用）
echo "[7/10] 安装 S-UI 面板"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# 8. 配置 Nginx 用于反向代理
echo "[8/10] 配置 Nginx"
cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    # Web 首页
    location / {
        root /opt/sub-web-modify/dist;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    # 订阅转换
    location /subconvert/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # VLESS 后端代理
    location /vless/ {
        proxy_pass http://127.0.0.1:443/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t
systemctl reload nginx

# 9. 完成设置
echo "[9/10] 完成配置，Web 和代理服务已启动"
echo "--------------------------------------"
echo "主页: https://$DOMAIN"
echo "订阅转换: https://$DOMAIN/subconvert"
echo "S-UI 面板访问：ssh -L 2095:127.0.0.1:2095 root@服务器IP"
echo "--------------------------------------"
echo "Reality / VLESS 请在 S-UI 中自行配置"

