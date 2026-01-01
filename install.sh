#!/usr/bin/env bash
set -e
echo "===== VPS Full Stack Deployment ====="

# 第一步：输入你的域名和Cloudflare的凭证
read -rp "请输入你的域名 (e.g., web.mycloudshare.org): " DOMAIN
read -rp "请输入你的Cloudflare邮箱: " CF_Email
read -rp "请输入你的Cloudflare API Token: " CF_Token
export CF_Email
export CF_Token

# 预设VLESS端口（可以根据需要修改）
VLESS_PORT=5000  # 你可以根据需要修改这个端口

echo "[1/12] 更新系统并安装必要的依赖"
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

echo "[3/12] 安装acme.sh进行DNS-01验证"
curl https://get.acme.sh | sh
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
mkdir -p /etc/nginx/ssl/$DOMAIN

# 使用Cloudflare进行DNS-01验证
echo "[4/12] 通过Cloudflare申请SSL证书"
~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256

# 安装证书到Nginx
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
  --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
  --reloadcmd "systemctl reload nginx"

echo "[5/12] 安装SubConverter后台"
# 检查SubConverter是否存在，如果没有则复制二进制文件
if [ ! -f "/opt/subconverter/bin/subconverter" ]; then
    echo "[INFO] 未找到SubConverter，正在复制二进制文件..."
    mkdir -p /opt/subconverter/bin
    # 将路径替换为你的subconverter文件实际路径
    cp /opt/vps-deployment/bin/subconverter /opt/subconverter/bin/  # 修改为你实际的路径
    chmod +x /opt/subconverter/bin/subconverter

    # 创建systemd服务来运行SubConverter
    cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter Service
After=network.target

[Service]
ExecStart=/opt/subconverter/bin/subconverter
Restart=always
RestartSec=3
User=www-data

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable subconverter
    systemctl start subconverter
else
    echo "[INFO] SubConverter二进制文件已存在，跳过复制。"
fi

echo "[6/12] 安装Node.js (LTS)"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

echo "[7/12] 构建sub-web-modify (来自about300仓库)"
# 检查sub-web-modify是否存在，如果没有则克隆并构建
if [ ! -d "/opt/sub-web-modify" ]; then
    echo "[INFO] 未找到sub-web-modify，正在克隆并构建..."
    rm -rf /opt/sub-web-modify
    git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
    cd /opt/sub-web-modify
    npm install
    npm run build
else
    echo "[INFO] sub-web-modify已存在，跳过克隆。"
fi

echo "[8/12] 安装S-UI面板（仅本地监听）"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

echo "[9/12] 从GitHub克隆Web文件"
# 检查web-home文件夹是否存在，如果没有则克隆
if [ ! -d "/opt/web-home" ]; then
    echo "[INFO] 未找到web-home，正在克隆..."
    rm -rf /opt/web-home
    git clone https://github.com/about300/vps-deployment.git /opt/web-home
    mv /opt/web-home/web /opt/web-home/current
else
    echo "[INFO] web-home已存在，跳过克隆。"
fi

echo "[10/12] 配置Nginx用于Web和API"
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    
    ssl_certificate     /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    # 主页：指向Web内容并支持搜索功能
    root /opt/web-home/current;
    index index.html;
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # 订阅转换前端：指向Sub-Web-Modify构建的静态文件
    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        try_files \$uri \$uri/ /subconvert/index.html;
    }

    # 订阅转换后端：代理到本地SubConverter服务
    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }

    # VLESS订阅：通过反向代理将流量转发到S-UI中设置的VLESS服务
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

echo "[11/12] 配置DNS-01用于Let's Encrypt"
echo "[INFO] 使用Cloudflare API进行DNS-01验证"

echo "[12/12] 安装AdGuard Home（端口3000）"
curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh

echo "[13/12] 完成 🎉"
echo "====================================="
echo "Web主页: https://$DOMAIN"
echo "SubConverter API: https://$DOMAIN/sub/api/"
echo "S-UI面板: http://127.0.0.1:2095"
echo "====================================="
