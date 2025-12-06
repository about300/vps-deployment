#!/bin/bash
echo "===== VPS 自动部署 (Caddy + S-UI + Subconverter + Web前端) ====="

# ---- 输入域名 ----
read -p "请输入你的主站域名(例如 example.com): " DOMAIN
read -p "请输入用于面板的子域名(例如 panel.example.com): " PANEL_DOMAIN

echo -e "\n使用域名: $DOMAIN"
echo -e "面板域名: $PANEL_DOMAIN\n"

echo "准备安装..."

# ---- 安装依赖 ----
apt update -y
apt install -y curl wget unzip socat

# ---- 安装 Caddy ----
echo "安装 Caddy..."
apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/debian/raw/gpg.key" | sudo tee /etc/apt/trusted.gpg.d/caddy-stable.asc
curl -1sLf "https://dl.cloudsmith.io/public/caddy/stable/debian/raw/caddy-stable.list" | sudo tee /etc/apt/sources.list.d/caddy-stable.list
apt update -y
apt install -y caddy

# ---- 安装 S-UI ----
echo "安装 S-UI 面板..."
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

# ---- 安装 subconverter ----
echo "安装 subconverter 转换服务..."
mkdir -p /opt/sub
cd /opt/sub
wget https://github.com/tindy2013/subconverter/releases/latest/download/subconverter-linux64.zip
unzip subconverter-linux64.zip
chmod +x subconverter

# ---- 创建 systemd ----
cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=Subconverter Service
After=network.target

[Service]
WorkingDirectory=/opt/sub
ExecStart=/opt/sub/subconverter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

# ---- 部署 Web 前端 ----
mkdir -p /var/www/site
cd /var/www/site

# 复制来自仓库
curl -sL https://raw.githubusercontent.com/about300/vps-deployment/main/web/index.html -o index.html
curl -sL https://raw.githubusercontent.com/about300/vps-deployment/main/web/style.css -o style.css
curl -sL https://raw.githubusercontent.com/about300/vps-deployment/main/web/script.js -o script.js

# ---- Caddyfile ----
cat >/etc/caddy/Caddyfile <<EOF
{
    email admin@$DOMAIN
}

# 主站 (网页)
$DOMAIN {
    root * /var/www/site
    file_server
    reverse_proxy /sub* localhost:25500
}

# S-UI 面板
$PANEL_DOMAIN {
    reverse_proxy localhost:81
}
EOF

systemctl restart caddy

echo -e "\n=== 安装完成 ==="
echo "访问主页: https://$DOMAIN"
echo "访问面板: https://$PANEL_DOMAIN"
echo "注意：Reality 设置在S-UI面板内手动配置！！"
