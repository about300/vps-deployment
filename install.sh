#!/bin/bash
# ========================================
# VPS Deployment Script
# Features: S-UI + Subconverter + UFW firewall
# Author: about300
# ========================================

set -e

# --- 1. 安装依赖 ---
echo "Installing dependencies..."
apt update -y
apt install -y curl wget tar ufw

# --- 2. 设置面板信息（交互式） ---
read -p "Enter S-UI username: " SU_USER
read -s -p "Enter S-UI password: " SU_PASS
echo
read -p "Enter S-UI panel port (default 2095): " SU_PORT
SU_PORT=${SU_PORT:-2095}
read -p "Enter S-UI panel path (default /app/): " SU_PATH
SU_PATH=${SU_PATH:-/app/}
read -p "Enter S-UI subscription port (default 2096): " SUB_PORT
SUB_PORT=${SUB_PORT:-2096}
read -p "Enter S-UI subscription path (default /sub/): " SUB_PATH
SUB_PATH=${SUB_PATH:-/sub/}

# --- 3. 安装 S-UI ---
echo "Downloading S-UI..."
SU_VERSION=$(curl -s https://api.github.com/repos/alireza0/s-ui/releases/latest | grep tag_name | cut -d '"' -f 4)
wget -O /tmp/s-ui-linux-amd64.tar.gz "https://github.com/alireza0/s-ui/releases/download/${SU_VERSION}/s-ui-linux-amd64.tar.gz"

echo "Installing S-UI..."
tar -xzf /tmp/s-ui-linux-amd64.tar.gz -C /opt/
chmod +x /opt/s-ui/sui

# 配置面板
/opt/s-ui/sui admin -username "$SU_USER" -password "$SU_PASS"
/opt/s-ui/sui setting -port "$SU_PORT" -path "$SU_PATH" -subPort "$SUB_PORT" -subPath "$SUB_PATH"

# 设置 systemd 自启
echo "[Unit]
Description=S-UI Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/s-ui
ExecStart=/opt/s-ui/sui
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target" > /etc/systemd/system/s-ui.service

systemctl daemon-reload
systemctl enable s-ui
systemctl start s-ui

echo "S-UI installed! Panel: http://<YOUR_DOMAIN>:$SU_PORT$SU_PATH"

# --- 4. 部署 Subconverter ---
echo "Deploying Subconverter..."
read -p "Enter Subconverter token: " SUB_TOKEN

# 假设 subconvert 文件夹已经在 GitHub 仓库中
mkdir -p /opt/subconvert
cp -r ./subconvert/* /opt/subconvert/
chmod +x /opt/subconvert/subconvert

# 更新 config.json token
sed -i "s/YOUR_TOKEN_HERE/$SUB_TOKEN/" /opt/subconvert/config.json

# 设置 systemd 自启
echo "[Unit]
Description=Subconverter
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/subconvert
ExecStart=/opt/subconvert/subconvert
Restart=always
RestartSec=3s

[Install]
WantedBy=multi-user.target" > /etc/systemd/system/subconvert.service

systemctl daemon-reload
systemctl enable subconvert
systemctl start subconvert

echo "Subconverter deployed! Listening port defined in config.json"

# --- 5. 配置防火墙 ---
echo "Configuring UFW firewall..."
ufw allow 22
ufw allow "$SU_PORT"
ufw allow "$SUB_PORT"
# 这里可以让用户输入 VLESS 端口
read -p "Enter your VLESS+Reality port: " VLESS_PORT
ufw allow "$VLESS_PORT"
ufw --force enable

echo "Firewall configured, only 22, S-UI, Subconverter and VLESS ports are open."

echo "Installation complete!"
