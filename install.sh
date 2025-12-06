#!/bin/bash
set -e

echo "=== VPS 部署一键脚本 ==="

# 1. 更新系统并安装依赖
apt update -y
apt install -y wget curl tar ufw caddy

# 2. 安装 s-ui 面板
echo "=== 安装 s-ui 面板 ==="
wget -O /tmp/s-ui.tar.gz https://github.com/alireza0/s-ui/releases/latest/download/s-ui-linux-amd64.tar.gz
tar -xzvf /tmp/s-ui.tar.gz -C /usr/local/bin/
bash /usr/local/bin/s-ui/s-ui.sh install

# 3. 交互式配置面板
read -p "设置面板端口(默认2095): " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-2095}

read -p "设置订阅端口(默认2096): " SUB_PORT
SUB_PORT=${SUB_PORT:-2096}

read -p "设置管理员用户名: " PANEL_USER
read -p "设置管理员密码: " PANEL_PASS

bash /usr/local/bin/s-ui/s-ui.sh modify \
  --panel-port $PANEL_PORT \
  --sub-port $SUB_PORT \
  --user $PANEL_USER \
  --pass $PANEL_PASS

# 4. 安装 Subconverter 后端 (MetaCubeX)
echo "=== 安装 Subconverter 后端 ==="
mkdir -p /usr/local/bin/subconvert
cp subconvert/subconverter /usr/local/bin/subconvert/
chmod +x /usr/local/bin/subconvert/subconverter
cp subconvert/config.json /usr/local/bin/subconvert/

# systemd 服务
cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=Subconverter Service
After=network.target

[Service]
ExecStart=/usr/local/bin/subconvert/subconverter -config /usr/local/bin/subconvert/config.json
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now subconverter

# 5. 安装 sub-web 前端
echo "=== 安装 sub-web 前端 ==="
cp -r sub-web-modify /var/www/sub-web
cat >/etc/caddy/Caddyfile <<EOF
:8080
root * /var/www/sub-web
file_server
EOF
systemctl enable --now caddy

# 6. 防火墙配置
echo "=== 配置防火墙 ==="
ufw allow 22
ufw allow $PANEL_PORT
ufw allow $SUB_PORT
ufw allow 8080
ufw allow 8081
ufw --force enable

echo "=== 安装完成 ==="
echo "s-ui 面板: http://<VPS_IP>:$PANEL_PORT/app/"
echo "Subconverter 后端: http://<VPS_IP>:8081"
echo "sub-web 前端: http://<VPS_IP>:8080"
