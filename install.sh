#!/bin/bash

set -e

echo "=== VPS 一键部署脚本 ==="

# 检查 root
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 执行此脚本"
  exit 1
fi

# -------------------------------
# 系统更新与依赖
# -------------------------------
echo "更新系统..."
apt update -y && apt upgrade -y
apt install -y wget curl tar unzip ufw git jq

# -------------------------------
# 防火墙
# -------------------------------
echo "配置防火墙..."
ufw allow 22/tcp

read -p "请输入 S-UI 面板端口 (默认 2095): " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-2095}
ufw allow $PANEL_PORT/tcp

read -p "请输入 Subconverter API 端口 (默认 8081): " SUB_PORT
SUB_PORT=${SUB_PORT:-8081}
ufw allow $SUB_PORT/tcp

ufw --force enable

# -------------------------------
# 安装 S-UI
# -------------------------------
echo "安装 S-UI 面板..."
SUI_VERSION="v1.3.7"
wget -O /tmp/s-ui-linux-amd64.tar.gz "https://github.com/alireza0/s-ui/releases/download/$SUI_VERSION/s-ui-linux-amd64.tar.gz"
mkdir -p /opt/s-ui
tar zxvf /tmp/s-ui-linux-amd64.tar.gz -C /opt/s-ui

cd /opt/s-ui

echo "配置 S-UI 面板..."
read -p "是否修改管理员账号? [y/n]: " MODIFY_ADMIN
if [[ "$MODIFY_ADMIN" == "y" ]]; then
    read -p "用户名: " SUI_USER
    read -p "密码: " SUI_PASS
    ./s-ui install
    ./s-ui resetadmin --user "$SUI_USER" --pass "$SUI_PASS"
else
    ./s-ui install
fi

# -------------------------------
# 安装 Subconverter (MetaCubeX)
# -------------------------------
echo "安装 Subconverter..."
mkdir -p /opt/subconvert
cp ./subconvert/subconverter /opt/subconvert/
cp ./subconvert/config.json /opt/subconvert/
chmod +x /opt/subconvert/subconverter

read -p "请输入 Subconverter token: " SUB_TOKEN
jq --arg token "$SUB_TOKEN" '.token=$token' /opt/subconvert/config.json > /opt/subconvert/config_tmp.json
mv /opt/subconvert/config_tmp.json /opt/subconvert/config.json

# 创建 systemd 服务
cat >/etc/systemd/system/subconvert.service <<EOF
[Unit]
Description=Subconverter Service
After=network.target

[Service]
Type=simple
ExecStart=/opt/subconvert/subconverter -config /opt/subconvert/config.json -port $SUB_PORT
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconvert
systemctl start subconvert

# -------------------------------
# 部署 Web 前端
# -------------------------------
echo "部署 Web 前端..."
mkdir -p /var/www/vps-web
cp -r ./web/* /var/www/vps-web/
echo "Web 前端部署完成: http://<VPS_IP>:$PANEL_PORT/web/"

# -------------------------------
# 完成提示
# -------------------------------
echo "=== 部署完成 ==="
echo "S-UI 面板: http://<VPS_IP>:$PANEL_PORT/app/"
echo "Subconverter API: http://<VPS_IP>:$SUB_PORT/api/v1/"
echo "Web 前端: http://<VPS_IP>:$PANEL_PORT/web/"
