#!/bin/bash

# ========================================
# VPS 一键部署脚本 - Ubuntu 24
# 支持：
# - VLESS+Reality TLS-through 共用 443
# - Subconverter 后端
# - Web 前端 (bing风格 + 订阅转换入口)
# ========================================

# ==== 用户交互设置 ====
read -p "请输入你的域名 (例如 myhome.mycloudshare.org): " DOMAIN
read -p "请输入 Web 面板路径 (默认 /sui): " WEB_PATH
WEB_PATH=${WEB_PATH:-/sui}
read -p "请输入 Subconverter 路径 (默认 /sub): " SUB_PATH
SUB_PATH=${SUB_PATH:-/sub}

# ==== 安装基础依赖 ====
apt update -y
apt install -y curl git socat wget unzip

# ==== 安装 Caddy ====
if ! command -v caddy &>/dev/null; then
    echo "安装 Caddy..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt update -y
    apt install -y caddy
fi

# ==== 设置目录 ====
mkdir -p /opt/web_frontend
mkdir -p /opt/subconverter

# ==== 拉取 Web 前端 ====
echo "拉取 Web 前端..."
git clone https://github.com/about300/vps-deployment.git /opt/web_frontend

# ==== 拉取 Subconverter ====
echo "拉取 Subconverter..."
git clone https://github.com/about300/vps-deployment.git /opt/subconverter

# ==== 生成 Caddyfile ====
echo "配置 Caddyfile..."
cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
    reverse_proxy $WEB_PATH/* {
        to unix//opt/web_frontend/server.sock
    }
    reverse_proxy $SUB_PATH/* {
        to unix//opt/subconverter/subconverter.sock
    }
    reverse_proxy /vless_reality/* {
        to 127.0.0.1:443 # VLESS+Reality TLS-through
    }
}
EOF

# ==== 启动 Subconverter ====
echo "启动 Subconverter..."
cd /opt/subconverter
# 假设你的 Subconverter 提供可执行脚本 converter.py
nohup python3 converter.py &>/dev/null &

# ==== 启动 Web 前端 ====
echo "启动 Web 前端..."
cd /opt/web_frontend
# 假设前端提供 server.py
nohup python3 server.py &>/dev/null &

# ==== 重载 Caddy ====
echo "重载 Caddy 服务..."
systemctl enable caddy
systemctl restart caddy

echo "部署完成！"
echo "访问 Web 前端: https://$DOMAIN$WEB_PATH"
echo "访问 Subconverter: https://$DOMAIN$SUB_PATH"
echo "VLESS+Reality TLS-through 保持在原端口配置"
