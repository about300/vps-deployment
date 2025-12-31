#!/usr/bin/env bash
set -e

echo "======================================"
echo " 一键部署 SubConverter"
echo " - 自动创建必要目录"
echo " - 自动下载并配置 config.ini"
echo "======================================"

# 创建必需的目录
echo "[1/6] 创建必要的目录"
mkdir -p /opt/subconverter/output
mkdir -p /opt/subconverter/rules
mkdir -p /opt/subconverter/logs

# 设置配置文件路径
CONFIG_FILE="/opt/subconverter/config.ini"

# 检查 config.ini 是否存在，如果不存在则创建并写入
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[2/6] 创建并配置 config.ini 文件"
    cat > "$CONFIG_FILE" <<EOF
[General]
# 设置目标协议和端口
target_protocol = vless
target_address = 127.0.0.1
target_port = 10000

# 设置日志路径
log_file = /opt/subconverter/logs/subconverter.log

# 启用调试模式
debug_mode = true

[SubConverterSettings]
# 设置订阅源
subscription_url = https://example.com/your_sub_url

# 设置订阅转换的协议
convert_protocol = vless
convert_encryption = none
convert_method = aes-128-gcm
EOF
    echo "config.ini 文件已创建并配置"
else
    echo "config.ini 文件已存在，跳过创建"
fi

# 给 config.ini 文件设置权限
chmod 644 "$CONFIG_FILE"

# 安装必要的依赖
echo "[3/6] 安装依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3

# 防火墙设置
echo "[4/6] 防火墙放行必要端口"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000
ufw allow 8445
ufw --force enable

# 安装 acme.sh
echo "[5/6] 安装 acme.sh"
curl https://get.acme.sh | sh
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# 使用 DNS-01 申请证书
echo "[6/6] 使用 DNS-01 申请证书"
mkdir -p /etc/nginx/ssl
~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
  --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
  --reloadcmd "systemctl reload nginx"

# 安装 SubConverter 后端
echo "[7/6] 安装 SubConverter 后端"
mkdir -p /opt/subconverter
cd /opt/subconverter
wget -O subconverter https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
chmod +x subconverter

# 创建 SubConverter 服务
cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter
After=network.target

[Service]
ExecStart=/opt/subconverter/subconverter
WorkingDirectory=/opt/subconverter
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconverter
systemctl start subconverter

echo "======================================"
echo "🎉 SubConverter 部署完成！"
echo "Web 页面： https://$DOMAIN"
echo "SubConverter API： https://$DOMAIN/sub/api/"
echo "======================================"
