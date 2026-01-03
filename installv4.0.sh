#!/usr/bin/env bash
set -e

##############################
# VPS 全栈部署脚本
# Version: v4.5 (稳定版)
# Author: Auto-generated
# Description: 部署完整的VPS服务栈，保持S-UI默认安装
##############################

echo "===== VPS 全栈部署（稳定版）v4.5 ====="

# -----------------------------
# 版本信息
# -----------------------------
SCRIPT_VERSION="4.5"
echo "版本: v${SCRIPT_VERSION}"
echo ""

# -----------------------------
# Cloudflare API 权限提示
# -----------------------------
echo "-------------------------------------"
echo "Cloudflare API Token 需要以下权限："
echo " - Zone.Zone: Read"
echo " - Zone.DNS: Edit"
echo "作用域：仅限当前域名所在 Zone"
echo "acme.sh 使用 dns_cf 方式申请证书"
echo "-------------------------------------"
echo ""

# -----------------------------
# 步骤 0：用户输入交互
# -----------------------------
read -rp "请输入您的域名 (例如：example.domain): " DOMAIN
read -rp "请输入 Cloudflare 邮箱: " CF_Email
read -rp "请输入 Cloudflare API Token: " CF_Token

# VLESS 端口输入
read -rp "请输入 VLESS 端口 (推荐: 8443, 2053, 2087, 2096 等): " VLESS_PORT

# 如果用户未输入，设置默认值
if [[ -z "$VLESS_PORT" ]]; then
    VLESS_PORT=8443
    echo "[INFO] 使用默认端口: $VLESS_PORT"
fi

# 验证端口是否为数字
if ! [[ "$VLESS_PORT" =~ ^[0-9]+$ ]] || [ "$VLESS_PORT" -lt 1 ] || [ "$VLESS_PORT" -gt 65535 ]; then
    echo "[ERROR] 端口号必须是 1-65535 之间的数字"
    exit 1
fi

# 检查端口是否被占用（443除外）
if [ "$VLESS_PORT" -ne 443 ]; then
    if ss -tuln | grep -q ":$VLESS_PORT "; then
        echo "[WARN] 端口 $VLESS_PORT 已被占用，将尝试使用"
        read -p "是否继续？(y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "安装中止"
            exit 1
        fi
    fi
fi

export CF_Email
export CF_Token

# SubConverter 二进制下载链接
SUBCONVERTER_BIN="https://github.com/about300/vps-deployment/raw/refs/heads/main/bin/subconverter"

# Web主页GitHub仓库
WEB_HOME_REPO="https://github.com/about300/vps-deployment.git"

# -----------------------------
# 步骤 1：更新系统与依赖
# -----------------------------
echo "[1/13] 更新系统与安装依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3 npm net-tools

# -----------------------------
# 步骤 2：防火墙配置
# -----------------------------
echo "[2/13] 配置防火墙"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# 允许SSH连接
ufw allow 22
# 允许HTTP/HTTPS
ufw allow 80
ufw allow 443
# 允许S-UI面板端口
ufw allow 2095
# 允许AdGuard Home端口
ufw allow 3000
ufw allow 8445
ufw allow 8446
# 允许SubConverter端口（仅本地）
ufw allow from 127.0.0.1 to any port 25500
# 开放VLESS端口
ufw allow ${VLESS_PORT}/tcp

# 启用防火墙
echo "y" | ufw --force enable

echo "[INFO] 防火墙配置完成"
echo ""

# -----------------------------
# 步骤 3：安装 acme.sh
# -----------------------------
echo "[3/13] 安装 acme.sh（DNS-01）"
if [ ! -d "$HOME/.acme.sh" ]; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
fi

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
mkdir -p /etc/nginx/ssl/$DOMAIN

# -----------------------------
# 步骤 4：申请 SSL 证书
# -----------------------------
echo "[4/13] 申请 SSL 证书"
if [ ! -f "/etc/nginx/ssl/$DOMAIN/fullchain.pem" ]; then
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
    echo "[INFO] SSL证书申请成功"
else
    echo "[INFO] SSL证书已存在"
fi

# -----------------------------
# 步骤 5：安装证书到 Nginx
# -----------------------------
echo "[5/13] 安装证书到 Nginx"
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
    --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
    --reloadcmd "systemctl reload nginx"

echo "[INFO] 证书安装完成"

# -----------------------------
# 步骤 6：部署主页
# -----------------------------
echo "[6/13] 部署主页"
mkdir -p /opt/web-home/current

# 下载GitHub上的主页文件（如果有）
echo "[INFO] 检查GitHub主页仓库..."
if wget -q --spider "$WEB_HOME_REPO"; then
    echo "[INFO] 从GitHub下载主页文件"
    rm -rf /tmp/web-home-source
    git clone $WEB_HOME_REPO /tmp/web-home-source
    
    # 检查是否有web目录
    if [ -d "/tmp/web-home-source/web" ]; then
        echo "[INFO] 找到web目录，复制文件"
        cp -r /tmp/web-home-source/web/* /opt/web-home/current/ 2>/dev/null || true
    else
        echo "[WARN] 未找到web目录，创建默认主页"
    fi
    rm -rf /tmp/web-home-source
else
    echo "[WARN] 无法访问GitHub仓库，创建默认主页"
fi

# 确保主页文件存在
if [ ! -f "/opt/web-home/current/index.html" ]; then
    echo "[INFO] 创建默认主页"
    cat > /opt/web-home/current/index.html <<EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>VPS Dashboard - $DOMAIN</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .container {
            text-align: center;
            padding: 2rem;
            max-width: 800px;
        }
        .logo {
            font-size: 4rem;
            margin-bottom: 1rem;
        }
        h1 {
            font-size: 2.5rem;
            margin-bottom: 1rem;
        }
        .domain {
            background: rgba(255,255,255,0.1);
            padding: 0.5rem 1rem;
            border-radius: 8px;
            margin: 1rem 0;
            font-family: 'Courier New', monospace;
            font-size: 1.1rem;
            display: inline-block;
        }
        .links {
            display: flex;
            flex-wrap: wrap;
            gap: 1rem;
            justify-content: center;
            margin: 2rem 0;
        }
        .btn {
            display: inline-block;
            background: rgba(255,255,255,0.15);
            color: white;
            text-decoration: none;
            padding: 1rem 2rem;
            border-radius: 12px;
            transition: all 0.3s;
            min-width: 200px;
        }
        .btn:hover {
            background: rgba(255,255,255,0.25);
            transform: translateY(-3px);
        }
        .btn-icon {
            font-size: 2rem;
            display: block;
            margin-bottom: 0.5rem;
        }
        .info {
            margin-top: 2rem;
            opacity: 0.8;
            font-size: 0.9rem;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="logo">🚀</div>
        <h1>VPS Dashboard</h1>
        <p>一站式全栈服务管理平台</p>
        <div class="domain">$DOMAIN</div>
        
        <div class="links">
            <a href="https://$DOMAIN" class="btn">
                <span class="btn-icon">🏠</span>
                主页面
            </a>
            <a href="http://$DOMAIN:2095" target="_blank" class="btn">
                <span class="btn-icon">📊</span>
                S-UI 面板
            </a>
            <a href="https://$DOMAIN/subconvert/" class="btn">
                <span class="btn-icon">🔄</span>
                订阅转换
            </a>
            <a href="http://$DOMAIN:3000" target="_blank" class="btn">
                <span class="btn-icon">🛡️</span>
                AdGuard Home
            </a>
        </div>
        
        <div class="info">
            <p>部署时间: $(date '+%Y-%m-%d %H:%M:%S')</p>
            <p>VLESS端口: $VLESS_PORT</p>
        </div>
    </div>
</body>
</html>
EOF
fi

# 设置权限
chown -R www-data:www-data /opt/web-home/current
chmod -R 755 /opt/web-home/current

echo "[INFO] 主页部署完成"

# -----------------------------
# 步骤 7：配置 Nginx
# -----------------------------
echo "[7/13] 配置 Nginx"
cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    root /opt/web-home/current;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /subconvert/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        
        # CORS 支持
        add_header Access-Control-Allow-Origin *;
        add_header Access-Control-Allow-Methods 'GET, POST, OPTIONS';
        add_header Access-Control-Allow-Headers 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
        
        # 预检请求处理
        if (\$request_method = 'OPTIONS') {
            add_header Access-Control-Allow-Origin *;
            add_header Access-Control-Allow-Methods 'GET, POST, OPTIONS';
            add_header Access-Control-Allow-Headers 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
            add_header Access-Control-Max-Age 1728000;
            add_header Content-Type 'text/plain; charset=utf-8';
            add_header Content-Length 0;
            return 204;
        }
    }
}
EOF

# 启用站点
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# 测试并重启Nginx
echo "[INFO] 测试Nginx配置..."
if nginx -t; then
    systemctl restart nginx
    echo "[INFO] Nginx配置成功"
else
    echo "[ERROR] Nginx配置测试失败"
    exit 1
fi

# -----------------------------
# 步骤 8：安装 SubConverter
# -----------------------------
echo "[8/13] 安装 SubConverter"
mkdir -p /opt/subconverter
if [ ! -f "/opt/subconverter/subconverter" ]; then
    wget -O /opt/subconverter/subconverter $SUBCONVERTER_BIN
    chmod +x /opt/subconverter/subconverter
fi

# 创建服务文件
cat > /etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter Service
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/subconverter
ExecStart=/opt/subconverter/subconverter
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

echo "[INFO] SubConverter 安装完成"

# -----------------------------
# 步骤 9：安装 Node.js 和 sub-web-modify
# -----------------------------
echo "[9/13] 安装 Node.js 和 sub-web-modify"
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
fi

echo "[INFO] 构建 sub-web-modify"
rm -rf /opt/sub-web-modify
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify
cat > vue.config.js <<'EOF'
module.exports = { publicPath: '/subconvert/' }
EOF
npm install
npm run build

echo "[INFO] sub-web-modify 构建完成"

# -----------------------------
# 步骤 10：安装 S-UI 面板（完全默认）
# -----------------------------
echo "[10/13] 安装 S-UI 面板"
echo "========================================"
echo "现在开始安装 S-UI 面板"
echo "请按照提示完成交互式安装"
echo "========================================"
echo ""
echo "注意：S-UI 使用默认安装方式"
echo "安装完成后，可通过以下方式访问："
echo "1. 直接访问: http://服务器IP:2095"
echo "2. 通过域名: http://$DOMAIN:2095"
echo ""
echo "开始安装..."

# 运行原始安装脚本
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

echo "[INFO] S-UI 安装完成"
echo ""

# -----------------------------
# 步骤 11：安装 AdGuard Home（可选）
# -----------------------------
echo "[11/13] 安装 AdGuard Home（可选）"
read -p "是否安装 AdGuard Home？(y/n，默认n): " install_adguard
if [[ $install_adguard =~ ^[Yy]$ ]]; then
    echo "[INFO] 开始安装 AdGuard Home..."
    curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
    echo "[INFO] AdGuard Home 安装完成"
else
    echo "[INFO] 跳过 AdGuard Home 安装"
fi

# -----------------------------
# 步骤 12：创建自动更新脚本
# -----------------------------
echo "[12/13] 创建自动更新脚本"
cat > /usr/local/bin/update-web-home.sh <<'EOF'
#!/bin/bash
# Web主页自动更新脚本

set -e

LOG_FILE="/var/log/web-home-update.log"
BACKUP_DIR="/opt/web-home/backup"
CURRENT_DIR="/opt/web-home/current"
REPO_URL="https://github.com/about300/vps-deployment.git"

echo "[$(date)] 开始更新主页..." >> "$LOG_FILE"

# 备份当前版本
mkdir -p "$BACKUP_DIR"
BACKUP_NAME="backup-$(date +%Y%m%d-%H%M%S)"
cp -r "$CURRENT_DIR" "$BACKUP_DIR/$BACKUP_NAME" 2>/dev/null || true

# 下载最新版本
TEMP_DIR=$(mktemp -d)
git clone "$REPO_URL" "$TEMP_DIR" 2>&1 >> "$LOG_FILE"

# 检查是否有web目录
if [ -d "$TEMP_DIR/web" ]; then
    rm -rf "$CURRENT_DIR"/*
    cp -r "$TEMP_DIR/web"/* "$CURRENT_DIR"/
else
    echo "[ERROR] 未找到web目录" >> "$LOG_FILE"
fi

# 清理
rm -rf "$TEMP_DIR"

# 设置权限
chown -R www-data:www-data "$CURRENT_DIR"
chmod -R 755 "$CURRENT_DIR"

# 重启Nginx
if nginx -t; then
    systemctl reload nginx
    echo "[INFO] 主页更新完成" >> "$LOG_FILE"
else
    echo "[ERROR] Nginx配置测试失败" >> "$LOG_FILE"
fi
EOF

chmod +x /usr/local/bin/update-web-home.sh

# 添加定时任务
(crontab -l 2>/dev/null; echo "0 3 */3 * * /usr/local/bin/update-web-home.sh >> /var/log/web-home-cron.log 2>&1") | crontab -

echo "[INFO] 自动更新脚本已安装"

# -----------------------------
# 步骤 13：验证部署
# -----------------------------
echo "[13/13] 验证部署"
echo ""
echo "========================================"
echo "✅ 部署完成！"
echo "========================================"
echo ""
echo "📋 重要访问地址："
echo ""
echo "  🌐 主页面:              https://$DOMAIN"
echo "  🔧 订阅转换前端:         https://$DOMAIN/subconvert/"
echo "  ⚙️  订阅转换API:          https://$DOMAIN/sub/api/"
echo "  📊 S-UI面板:            http://$DOMAIN:2095"
echo "  📊 S-UI面板(直接访问):   http://服务器IP:2095"
echo ""
if [[ $install_adguard =~ ^[Yy]$ ]]; then
echo "  🛡️  AdGuard Home:"
echo "     - Web界面:          http://$DOMAIN:3000/"
fi
echo ""
echo "🔐 SSL证书路径："
echo "  • 证书文件: /etc/nginx/ssl/$DOMAIN/fullchain.pem"
echo "  • 私钥文件: /etc/nginx/ssl/$DOMAIN/key.pem"
echo ""
echo "🔧 VLESS 配置："
echo "  • 端口: ${VLESS_PORT} (已在防火墙开放)"
echo "  • 域名: $DOMAIN"
echo "  • 注意: 请在S-UI面板中配置VLESS入站节点"
echo ""
echo "🔄 自动更新："
echo "  • 更新脚本: /usr/local/bin/update-web-home.sh"
echo "  • 日志文件: /var/log/web-home-update.log"
echo "  • 更新频率: 每3天自动更新"
echo "  • 手动更新: bash /usr/local/bin/update-web-home.sh"
echo ""
echo "🛠️ 管理命令："
echo "  • 查看Nginx状态: systemctl status nginx"
echo "  • 重启Nginx: systemctl restart nginx"
echo "  • 查看Nginx日志: tail -f /var/log/nginx/error.log"
echo "  • 查看防火墙: ufw status"
echo "  • 检查端口: netstat -tlnp"
echo ""
echo "⚠️  重要提醒："
echo "  1. 立即登录S-UI修改默认密码"
echo "  2. 在S-UI中配置VLESS入站节点，使用端口 ${VLESS_PORT}"
echo "  3. S-UI访问地址: http://$DOMAIN:2095"
echo "  4. 如果无法访问，请检查防火墙和端口"
echo "  5. 定期运行系统更新: apt update && apt upgrade"
echo ""
echo "========================================"
echo "脚本版本: v${SCRIPT_VERSION}"
echo "部署时间: $(date)"
echo "========================================"

# 最后测试
echo ""
echo "正在测试主页访问..."
sleep 2
if curl -s -o /dev/null -w "%{http_code}" https://$DOMAIN | grep -q "200\|301\|302"; then
    echo "✅ 主页访问正常"
else
    echo "⚠️  主页可能无法访问，请检查Nginx配置"
fi

echo ""
echo "安装完成！"