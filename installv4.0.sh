#!/usr/bin/env bash
set -e

##############################
# VPS 全栈部署脚本
# Version: v4.6 (完整GitHub版)
# Author: Auto-generated
# Description: 直接从GitHub部署完整VPS服务栈
##############################

echo "===== VPS 全栈部署（完整GitHub版）v4.6 ====="

# -----------------------------
# 版本信息
# -----------------------------
SCRIPT_VERSION="4.6"
echo "版本: v${SCRIPT_VERSION}"
echo "更新: 直接从GitHub获取所有文件，保持原始外观"
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

# Web主页GitHub仓库（使用您完整的web目录）
WEB_HOME_REPO="https://github.com/about300/vps-deployment.git"

# -----------------------------
# 步骤 1：更新系统与依赖
# -----------------------------
echo "[1/11] 更新系统与安装依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3 npm net-tools

# 确保Nginx有sub_filter模块
if nginx -V 2>&1 | grep -q "http_sub_module"; then
    echo "[INFO] Nginx sub_filter模块已启用"
else
    echo "[WARN] Nginx可能缺少sub_filter模块，尝试安装nginx-extras"
    apt install -y nginx-extras 2>/dev/null || echo "[INFO] nginx-extras安装失败，继续使用标准版"
fi

# -----------------------------
# 步骤 2：防火墙配置
# -----------------------------
echo "[2/11] 配置防火墙（开放VLESS端口: $VLESS_PORT）"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 2095
ufw allow 3000
ufw allow 8445
ufw allow 8446
ufw allow from 127.0.0.1 to any port 25500
ufw allow ${VLESS_PORT}/tcp
echo "y" | ufw --force enable

echo "[INFO] 防火墙配置完成："
echo "  • 开放端口: 22(SSH), 80(HTTP), 443(HTTPS), 2095(S-UI), 3000, 8445, 8446"
echo "  • VLESS端口: ${VLESS_PORT} (外部可访问)"
echo "  • 本地访问(127.0.0.1): 25500(subconverter)"
echo ""

# -----------------------------
# 步骤 3：安装 acme.sh 和 SSL 证书
# -----------------------------
echo "[3/11] 安装 SSL 证书"
if [ ! -d "$HOME/.acme.sh" ]; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
mkdir -p /etc/nginx/ssl/$DOMAIN

if [ ! -f "/etc/nginx/ssl/$DOMAIN/fullchain.pem" ]; then
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
fi

~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
    --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
    --reloadcmd "systemctl reload nginx"

# -----------------------------
# 步骤 4：安装 SubConverter 后端
# -----------------------------
echo "[4/11] 安装 SubConverter"
mkdir -p /opt/subconverter
if [ ! -f "/opt/subconverter/subconverter" ]; then
    wget -O /opt/subconverter/subconverter $SUBCONVERTER_BIN
    chmod +x /opt/subconverter/subconverter
fi

cat > /opt/subconverter/subconverter.env <<EOF
# SubConverter 配置文件
API_MODE=true
API_HOST=0.0.0.0
API_PORT=25500
CACHE_ENABLED=true
CACHE_SUBSCRIPTION=true
CACHE_CONFIG=true
CACHE_UPDATE_INTERVAL=600
MANAGEMENT_PASS=admin123
EOF

chmod 600 /opt/subconverter/subconverter.env

cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter 服务
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/subconverter
ExecStart=/opt/subconverter/subconverter
Restart=always
RestartSec=3
EnvironmentFile=/opt/subconverter/subconverter.env

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

# -----------------------------
# 步骤 5：构建 sub-web-modify 前端
# -----------------------------
echo "[5/11] 构建 sub-web-modify 前端"
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
fi

rm -rf /opt/sub-web-modify
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify
cat > vue.config.js <<'EOF'
module.exports = { publicPath: '/subconvert/' }
EOF

npm install
npm run build

if [ -f "/opt/sub-web-modify/dist/config.template.js" ] && [ ! -f "/opt/sub-web-modify/dist/config.js" ]; then
    cp /opt/sub-web-modify/dist/config.template.js /opt/sub-web-modify/dist/config.js
fi

# -----------------------------
# 步骤 6：安装 S-UI 面板
# -----------------------------
echo "[6/11] 安装 S-UI 面板"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
echo "[INFO] S-UI 面板安装完成"

# -----------------------------
# 步骤 7：安装 AdGuard Home
# -----------------------------
echo "[7/11] 安装 AdGuard Home"
cd /tmp
echo "[INFO] 运行官方安装脚本..."
if curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v; then
    echo "[INFO] AdGuard Home 安装成功"
else
    echo "[WARN] 官方安装脚本失败，尝试手动安装..."
    AGH_URL="https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_amd64.tar.gz"
    
    if wget -O AdGuardHome_linux_amd64.tar.gz "$AGH_URL"; then
        tar xzf AdGuardHome_linux_amd64.tar.gz
        
        if [ -d "AdGuardHome" ]; then
            mkdir -p /opt/AdGuardHome
            cp -r AdGuardHome/* /opt/AdGuardHome/
            chmod +x /opt/AdGuardHome/AdGuardHome
            
            cat >/etc/systemd/system/AdGuardHome.service <<EOF
[Unit]
Description=AdGuard Home
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/AdGuardHome
ExecStart=/opt/AdGuardHome/AdGuardHome
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
            
            systemctl daemon-reload
            systemctl enable AdGuardHome
            echo "[INFO] AdGuard Home 手动安装完成"
        fi
        
        rm -f AdGuardHome_linux_amd64.tar.gz
        rm -rf AdGuardHome 2>/dev/null || true
    fi
fi

systemctl start AdGuardHome 2>/dev/null || true

if [ -f "/opt/AdGuardHome/AdGuardHome.yaml" ]; then
    sed -i 's/^bind_port: .*/bind_port: 3000/' /opt/AdGuardHome/AdGuardHome.yaml 2>/dev/null || true
    systemctl restart AdGuardHome 2>/dev/null || true
fi

cd - > /dev/null
echo "[INFO] AdGuard Home 安装完成"

# -----------------------------
# 步骤 8：从GitHub部署主页（完整web目录）
# -----------------------------
echo "[8/11] 从GitHub部署主页"
rm -rf /opt/web-home
mkdir -p /opt/web-home/current

echo "[INFO] 克隆GitHub仓库获取完整web目录..."
git clone $WEB_HOME_REPO /tmp/web-home-repo

# 检查是否有web目录
if [ -d "/tmp/web-home-repo/web" ]; then
    echo "[INFO] 找到web目录，复制所有文件..."
    cp -r /tmp/web-home-repo/web/* /opt/web-home/current/
else
    echo "[INFO] 未找到web目录，复制仓库根目录..."
    cp -r /tmp/web-home-repo/* /opt/web-home/current/
fi

# 确保目录结构正确
mkdir -p /opt/web-home/current/css
mkdir -p /opt/web-home/current/js

# 如果css文件不存在，创建基本的CSS
if [ ! -f "/opt/web-home/current/css/style.css" ]; then
    echo "[INFO] CSS文件不存在，创建基本CSS..."
    cat > /opt/web-home/current/css/style.css <<'EOF'
/* 基础CSS确保页面正常显示 */
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: 'Noto Sans SC', sans-serif; background: #f5f7fa; }
.container { width: 100%; max-width: 1200px; margin: 0 auto; padding: 0 20px; }
.navbar { background: white; padding: 15px 0; }
.nav-brand { display: flex; align-items: center; gap: 10px; }
.nav-menu { display: flex; gap: 30px; }
.page-header { background: linear-gradient(135deg, #3498db, #2980b9); color: white; padding: 60px 0; text-align: center; }
.tools-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 25px; }
.tool-card { background: white; padding: 25px; border-radius: 10px; box-shadow: 0 5px 15px rgba(0,0,0,0.08); }
EOF
fi

# 替换index.html中的域名占位符
if [ -f "/opt/web-home/current/index.html" ]; then
    echo "[INFO] 替换index.html中的域名和端口..."
    sed -i "s|\\\${DOMAIN}|$DOMAIN|g" /opt/web-home/current/index.html 2>/dev/null || true
    sed -i "s|\\\$DOMAIN|$DOMAIN|g" /opt/web-home/current/index.html 2>/dev/null || true
    sed -i "s|\\\${VLESS_PORT}|$VLESS_PORT|g" /opt/web-home/current/index.html 2>/dev/null || true
else
    echo "[WARN] index.html不存在，创建简单主页"
    cat > /opt/web-home/current/index.html <<EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>VPS Dashboard</title>
    <link rel="stylesheet" href="css/style.css">
</head>
<body>
    <nav class="navbar">
        <div class="container">
            <div class="nav-brand">
                <i class="fas fa-server"></i>
                <a href="/">VPS Dashboard</a>
            </div>
        </div>
    </nav>
    <header class="page-header">
        <div class="container">
            <h1>VPS 全栈服务</h1>
            <p>「离开世界之前 一切都是过程」</p>
        </div>
    </header>
    <main class="container">
        <div class="tools-grid">
            <a href="/subconvert/" class="tool-card">订阅转换</a>
            <a href="https://$DOMAIN:2095" class="tool-card" target="_blank">S-UI面板</a>
            <a href="https://$DOMAIN:3000" class="tool-card" target="_blank">AdGuard Home</a>
        </div>
    </main>
</body>
</html>
EOF
fi

# 设置文件权限
chown -R www-data:www-data /opt/web-home/current
chmod -R 755 /opt/web-home/current

# 清理临时文件
rm -rf /tmp/web-home-repo

echo "[INFO] 主页部署完成"
echo "[INFO] 主页文件结构:"
ls -la /opt/web-home/current/

# -----------------------------
# 步骤 9：配置 Nginx
# -----------------------------
echo "[9/11] 配置 Nginx"
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    # 主页
    root /opt/web-home/current;
    index index.html;
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # 静态文件缓存
    location ~* \\.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # Sub-Web 前端
    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    # SubConverter API
    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        add_header Access-Control-Allow-Origin *;
        add_header Access-Control-Allow-Methods 'GET, POST, OPTIONS';
        add_header Access-Control-Allow-Headers 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
        
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

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/

echo "[INFO] 测试Nginx配置..."
if nginx -t 2>&1 | grep -q "test is successful"; then
    echo "[INFO] Nginx配置测试成功"
    systemctl reload nginx
else
    echo "[ERROR] Nginx配置测试失败"
    nginx -t
    exit 1
fi

# -----------------------------
# 步骤 10：创建自动更新脚本
# -----------------------------
echo "[10/11] 创建自动更新脚本"
cat > /usr/local/bin/update-web-home.sh <<EOF
#!/bin/bash
# Web主页自动更新脚本

set -e

echo "[INFO] \$(date) - 开始更新Web主页"
cd /tmp

# 备份当前版本
BACKUP_DIR="/opt/web-home/backup"
mkdir -p "\$BACKUP_DIR"
BACKUP_NAME="backup-\$(date +%Y%m%d-%H%M%S)"
if [ -d "/opt/web-home/current" ]; then
    cp -r /opt/web-home/current "\$BACKUP_DIR/\$BACKUP_NAME"
    echo "[INFO] 备份当前版本到: \$BACKUP_DIR/\$BACKUP_NAME"
fi

# 从GitHub获取最新代码
echo "[INFO] 从GitHub获取最新代码..."
rm -rf /tmp/web-home-update
if git clone $WEB_HOME_REPO /tmp/web-home-update; then
    # 部署新版本
    echo "[INFO] 部署新版本..."
    rm -rf /opt/web-home/current/*
    
    if [ -d "/tmp/web-home-update/web" ]; then
        cp -r /tmp/web-home-update/web/* /opt/web-home/current/
    else
        cp -r /tmp/web-home-update/* /opt/web-home/current/
    fi
    
    # 替换域名
    if [ -f "/opt/web-home/current/index.html" ]; then
        sed -i "s|\\\\\\\${DOMAIN}|$DOMAIN|g" /opt/web-home/current/index.html 2>/dev/null || true
        sed -i "s|\\\\\\\$DOMAIN|$DOMAIN|g" /opt/web-home/current/index.html 2>/dev/null || true
        sed -i "s|\\\\\\\${VLESS_PORT}|$VLESS_PORT|g" /opt/web-home/current/index.html 2>/dev/null || true
    fi
    
    # 设置权限
    chown -R www-data:www-data /opt/web-home/current
    chmod -R 755 /opt/web-home/current
    
    # 重载Nginx
    systemctl reload nginx
    
    echo "[INFO] 主页更新成功！"
else
    echo "[ERROR] 从GitHub获取代码失败"
    # 恢复备份
    if [ -d "\$BACKUP_DIR/\$BACKUP_NAME" ]; then
        echo "[INFO] 恢复备份..."
        rm -rf /opt/web-home/current/*
        cp -r "\$BACKUP_DIR/\$BACKUP_NAME"/* /opt/web-home/current/
    fi
    exit 1
fi

# 清理临时文件
rm -rf /tmp/web-home-update

echo "[INFO] 更新完成"
EOF

chmod +x /usr/local/bin/update-web-home.sh

# 创建手动更新命令
cat > /usr/local/bin/update-home <<'EOF'
#!/bin/bash
echo "开始手动更新Web主页..."
/usr/local/bin/update-web-home.sh
EOF
chmod +x /usr/local/bin/update-home

# 添加cron任务
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/update-web-home.sh >> /var/log/web-home-update.log 2>&1") | crontab -

# -----------------------------
# 步骤 11：创建服务检查脚本
# -----------------------------
echo "[11/11] 创建服务检查脚本"
cat > /usr/local/bin/check-services.sh <<EOF
#!/bin/bash
echo "=== VPS 服务状态检查 ==="
echo "时间: \$(date)"
echo ""
echo "1. 服务状态:"
echo "   Nginx: \$(systemctl is-active nginx)"
echo "   SubConverter: \$(systemctl is-active subconverter)"
echo "   S-UI: \$(systemctl is-active s-ui)"
echo "   AdGuard Home: \$(systemctl is-active AdGuardHome)"
echo ""
echo "2. 端口监听:"
echo "   443 (HTTPS): \$(ss -tln | grep ':443 ' && echo '✅ 监听中' || echo '❌ 未监听')"
echo "   2095 (S-UI): \$(ss -tln | grep ':2095 ' && echo '✅ 监听中' || echo '❌ 未监听')"
echo "   3000 (AdGuard): \$(ss -tln | grep ':3000 ' && echo '✅ 监听中' || echo '❌ 未监听')"
echo "   $VLESS_PORT (VLESS): \$(ss -tln | grep ':$VLESS_PORT ' && echo '✅ 监听中' || echo '❌ 未监听')"
echo ""
echo "3. 访问测试:"
echo "   主页: curl -s -o /dev/null -w "%{http_code}" https://$DOMAIN"
echo "   Sub-Web: curl -s -o /dev/null -w "%{http_code}" https://$DOMAIN/subconvert/"
echo ""
echo "4. 防火墙状态:"
ufw status | head -20
EOF

chmod +x /usr/local/bin/check-services.sh

# -----------------------------
# 完成信息
# -----------------------------
echo ""
echo "====================================="
echo "🎉 VPS 全栈部署完成 v${SCRIPT_VERSION}"
echo "====================================="
echo ""
echo "📋 重要访问地址:"
echo ""
echo "  🌐 主页面:       https://$DOMAIN"
echo "  🔧 订阅转换:     https://$DOMAIN/subconvert/"
echo "  📊 S-UI面板:     https://$DOMAIN:2095"
echo "  🛡️  AdGuard:     https://$DOMAIN:3000"
echo ""
echo "🔧 管理命令:"
echo "  • 服务状态:      check-services.sh"
echo "  • 更新主页:      update-home"
echo "  • 查看日志:      tail -f /var/log/web-home-update.log"
echo ""
echo "⚙️  VLESS 配置:"
echo "  • 域名: $DOMAIN"
echo "  • 端口: $VLESS_PORT"
echo "  • 协议: VLESS"
echo ""
echo "📁 重要目录:"
echo "  • 主页目录:      /opt/web-home/current/"
echo "  • SSL证书:      /etc/nginx/ssl/$DOMAIN/"
echo "  • 订阅转换:      /opt/subconverter/"
echo "  • 备份目录:      /opt/web-home/backup/"
echo ""
echo "🔒 安全提醒:"
echo "  1. 修改S-UI默认密码"
echo "  2. 修改AdGuard Home默认密码"
echo "  3. 备份SSL证书"
echo ""
echo "🔄 自动更新:"
echo "  • 每天凌晨3点自动从GitHub更新主页"
echo "  • 更新日志: /var/log/web-home-update.log"
echo ""
echo "====================================="
echo "部署时间: \$(date)"
echo "====================================="

# 快速测试
echo ""
echo "🔍 快速测试..."
sleep 3
/usr/local/bin/check-services.sh