#!/bin/bash
set -e

# ==================================================
# VPS Deployment Script with interactive token
# ==================================================

# 1️⃣ 安装依赖
apt update -y
apt install -y wget curl tar ufw

# 2️⃣ 配置防火墙（保留 22 端口）
ufw allow 22
ufw allow 8081/tcp   # Subconverter 后端端口
ufw --force enable

# 3️⃣ 创建目录
DEPLOY_DIR="/opt/vps-deployment"
SUB_DIR="$DEPLOY_DIR/subconvert"
WEB_DIR="$DEPLOY_DIR/web"

mkdir -p "$SUB_DIR"
mkdir -p "$WEB_DIR"

# 4️⃣ 复制仓库文件到部署目录
# 假设你已经在仓库中有 subconvert 和 web 文件夹
cp -r subconvert/* "$SUB_DIR/"
cp -r web/* "$WEB_DIR/"

# 5️⃣ 授权 Subconverter 可执行
chmod +x "$SUB_DIR/subconverter"

# 6️⃣ 交互设置 token
read -p "请输入 Subconverter token（用于 API 验证）: " SC_TOKEN

# 更新 config.json 中的 token
CONFIG_FILE="$SUB_DIR/config.json"
if [ -f "$CONFIG_FILE" ]; then
    # 使用 jq 更新 token
    if command -v jq >/dev/null 2>&1; then
        jq --arg t "$SC_TOKEN" '.token = $t' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    else
        # 如果没有 jq，使用简单 sed
        sed -i "s/\"token\": \".*\"/\"token\": \"$SC_TOKEN\"/" "$CONFIG_FILE"
    fi
else
    # 如果 config.json 不存在，则生成一个默认模板
    cat > "$CONFIG_FILE" <<EOL
{
  "token": "$SC_TOKEN",
  "port": 8081,
  "host": "0.0.0.0"
}
EOL
fi

# 7️⃣ 创建 systemd 服务
SERVICE_FILE="/etc/systemd/system/subconvert.service"

cat > "$SERVICE_FILE" <<EOL
[Unit]
Description=Subconverter VLESS Backend
After=network.target

[Service]
Type=simple
ExecStart=$SUB_DIR/subconverter -c $SUB_DIR/config.json
Restart=always
User=root
WorkingDirectory=$SUB_DIR

[Install]
WantedBy=multi-user.target
EOL

# 8️⃣ 启动服务
systemctl daemon-reload
systemctl enable subconvert
systemctl start subconvert

# 9️⃣ 输出信息
echo "============================================"
echo "Subconverter (VLESS) 已安装并启动"
echo "监听端口: 8081"
echo "配置目录: $SUB_DIR"
echo "使用 token: $SC_TOKEN"
echo "前端 Web 目录: $WEB_DIR"
echo "访问 Web 前端请使用你的 VPS IP 或域名指向 $WEB_DIR"
echo "============================================"
