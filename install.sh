#!/bin/bash
set -e

echo "========= VPS Deployment Script ========="

# 1️⃣ 安装依赖
echo "[*] Installing dependencies..."
apt update -y
apt install -y wget curl tar ufw git

# 2️⃣ 设置防火墙
echo "[*] Configuring UFW..."
ufw allow 22/tcp
read -p "请输入面板端口（默认2095）: " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-2095}
ufw allow $PANEL_PORT/tcp
read -p "请输入订阅端口（默认2096）: " SUB_PORT
SUB_PORT=${SUB_PORT:-2096}
ufw allow $SUB_PORT/tcp
ufw enable

# 3️⃣ 安装 S-UI 官方面板
echo "[*] Installing S-UI Panel..."
cd /tmp
SU_VERSION=$(curl -s https://api.github.com/repos/alireza0/s-ui/releases/latest | grep 'tag_name' | cut -d\" -f4)
wget https://github.com/alireza0/s-ui/releases/download/${SU_VERSION}/s-ui-linux-amd64.tar.gz -O s-ui-linux-amd64.tar.gz
tar -xzf s-ui-linux-amd64.tar.gz -C /opt
cd /opt/s-ui

# 交互设置管理员账号
read -p "是否修改管理员账号? [y/n]: " MODIFY_ADMIN
if [[ "$MODIFY_ADMIN" == "y" ]]; then
    read -p "用户名: " ADMIN_USER
    read -p "密码: " ADMIN_PASS
fi

chmod +x sui
./sui install
./sui resetadmin --user "$ADMIN_USER" --pass "$ADMIN_PASS"

echo "[*] S-UI installed! Panel port: $PANEL_PORT"

# 4️⃣ 部署 Subconverter
echo "[*] Deploying Subconverter..."
cd /opt
mkdir -p subconverter
cp /path/to/github/subconverter/* /opt/subconverter/
chmod +x /opt/subconverter/subconverter

# 设置 token
read -p "请输入 Subconverter token: " SUB_TOKEN
sed -i "s/\"token\": \"\"/\"token\": \"$SUB_TOKEN\"/" /opt/subconverter/config.json

# 启动 Subconverter
cat >/etc/systemd/system/subconverter.service <<EOL
[Unit]
Description=Subconverter Service
After=network.target

[Service]
Type=simple
ExecStart=/opt/subconverter/subconverter -config /opt/subconverter/config.json
Restart=always

[Install]
WantedBy=multi-user.target
EOL

systemctl daemon-reload
systemctl enable subconverter
systemctl start subconverter

# 5️⃣ 部署 Web 前端
echo "[*] Deploying Web frontend..."
mkdir -p /opt/web
# 可以放置简单搜索 + 订阅转换前端 HTML/JS 文件
# 例如：index.html、search.js
# 用户可以自定义 HTML 文件内容
echo "<html><body><h2>Welcome to VPS Web</h2></body></html>" > /opt/web/index.html

# 使用 Caddy 作为静态 web server
apt install -y caddy
cat >/etc/caddy/Caddyfile <<EOL
:80 {
    root * /opt/web
    file_server
}
EOL
systemctl restart caddy

echo "========= Deployment Finished ========="
echo "S-UI URL: http://<your_server_ip>:$PANEL_PORT/app/"
echo "Subconverter URL: http://<your_server_ip>:$SUB_PORT/sub?token=$SUB_TOKEN"
