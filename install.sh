#!/usr/bin/env bash
set -e

##############################
# VPS 全栈部署脚本 (回滚版)
# Version: v6.2.0
# Author: Auto-generated
##############################

echo "===== VPS 全栈部署 v6.2.0 ====="

# 版本信息
SCRIPT_VERSION="6.2.0"
echo "版本: v${SCRIPT_VERSION}"
echo "说明: 回滚到端口访问模式，S-UI使用根目录"
echo ""

# Cloudflare API 权限提示
echo "-------------------------------------"
echo "Cloudflare API Token 需要以下权限："
echo " - Zone.Zone: Read"
echo " - Zone.DNS: Edit"
echo "作用域：仅限当前域名所在 Zone"
echo "-------------------------------------"
echo ""

# 用户输入交互
read -rp "请输入您的域名 (例如：example.domain): " DOMAIN
read -rp "请输入 Cloudflare 邮箱: " CF_Email
read -rp "请输入 Cloudflare API Token: " CF_Token

# VLESS 端口输入
read -rp "请输入 VLESS 端口 (推荐: 8443, 2053, 2087, 2096 等): " VLESS_PORT

if [[ -z "$VLESS_PORT" ]]; then
    VLESS_PORT=8443
    echo "[INFO] 使用默认端口: $VLESS_PORT"
fi

# 验证端口
if ! [[ "$VLESS_PORT" =~ ^[0-9]+$ ]] || [ "$VLESS_PORT" -lt 1 ] || [ "$VLESS_PORT" -gt 65535 ]; then
    echo "[ERROR] 端口号必须是 1-65535 之间的数字"
    exit 1
fi

export CF_Email
export CF_Token

WEB_HOME_REPO="https://github.com/about300/vps-deployment.git"

echo "[INFO] 访问路径："
echo "  • 主域名: https://$DOMAIN"
echo "  • S-UI面板: https://$DOMAIN:2095 (根目录，端口访问)"
echo "  • AdGuard Home: https://$DOMAIN:3000 (端口访问)"
echo "  • 订阅转换: https://$DOMAIN/subconvert/"
echo "  • VLESS端口: $VLESS_PORT"
echo ""

# 步骤 1：更新系统与依赖
echo "[1/11] 更新系统与安装依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3 npm net-tools jq

# 步骤 2：防火墙配置
echo "[2/11] 配置防火墙"
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

echo "[INFO] 防火墙配置完成"
ufw status numbered

# 步骤 3：安装 SSL 证书
echo "[3/11] 安装 SSL 证书"
if [ ! -d "$HOME/.acme.sh" ]; then
    curl https::com//get.acme.sh | sh
    source ~/.bashrc
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
mkdir -p /etc/nginx/ssl/$DOMAIN

if [ ! -f "/etc/nginx/ssl/$DOMAIN/fullchain.pem" ]; then
    echo "[INFO] 为 $DOMAIN 申请SSL证书..."
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
fi

~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
    --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
    --reloadcmd "systemctl reload nginx"

# 步骤 4：安装 SubConverter 后端
echo "[4/11] 安装 SubConverter 后端"
mkdir -p /opt/subconverter

DOWNLOAD_URL="https://github.com/MetaCubeX/subconverter/releases/download/v0.9.2/subconverter_linux64.tar.gz"
echo "[INFO] 下载 SubConverter..."
wget -O /opt/subconverter/subconverter.tar.gz "$DOWNLOAD_URL"
tar -zxvf /opt/subconverter/subconverter.tar.gz -C /opt/subconverter --strip-components=1
rm -f /opt/subconverter/subconverter.tar.gz
chmod +x /opt/subconverter/subconverter

cat > /opt/subconverter/subconverter.env <<EOF
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

# 步骤 5：构建 sub-web-modify 前端
echo "[5/11] 构建 sub-web-modify 前端"
if ! command -v node &> /dev/null; then
    echo "[INFO] 安装 Node.js..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
fi

rm -rf /opt/sub-web-modify
mkdir -p /opt/sub-web-modify

echo "[INFO] 克隆已修复的sub-web-modify仓库..."
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify

cd /opt/sub-web-modify
npm install --no-audit --no-fund
npm run build

if [ -f "dist/index.html" ]; then
    echo "    ✅ 构建成功"
else
    echo "    ❌ 构建失败"
    exit 1
fi

# 步骤 6：安装 S-UI 面板
echo "[6/11] 安装 S-UI 面板"
echo "[INFO] 使用官方安装脚本安装 S-UI 面板..."
echo "[INFO] 注意：请设置S-UI面板使用根目录 (path: /)"
echo ""
echo "运行以下命令手动安装（推荐手动设置根目录）："
echo "bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)"
echo ""
echo "或按回车键继续自动安装（使用默认配置）..."
read -p "按回车键继续..." dummy

# 自动安装S-UI（使用默认根目录）
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
echo "[INFO] S-UI 面板安装完成"

# 步骤 7：安装 AdGuard Home
echo "[7/11] 安装 AdGuard Home"
cd /tmp
curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v

if [ -f "/opt/AdGuardHome/AdGuardHome.yaml" ]; then
    echo "[INFO] 配置AdGuard Home绑定到3000端口"
    sed -i 's/^bind_port: .*/bind_port: 3000/' /opt/AdGuardHome/AdGuardHome.yaml 2>/dev/null || true
    systemctl restart AdGuardHome
fi

cd - > /dev/null

# 步骤 8：部署主页（使用端口访问链接）
echo "[8/11] 从GitHub部署主页"
rm -rf /opt/web-home
mkdir -p /opt/web-home/current
mkdir -p /opt/web-home/current/assets

echo "[INFO] 克隆GitHub仓库获取主页..."
git clone $WEB_HOME_REPO /tmp/web-home-repo

if [ -d "/tmp/web-home-repo/web" ]; then
    echo "[INFO] 找到web目录，复制所有文件..."
    cp -r /tmp/web-home-repo/web/* /opt/web-home/current/
else
    echo "[INFO] 未找到web目录，复制仓库根目录..."
    cp -r /tmp/web-home-repo/* /opt/web-home/current/
fi

mkdir -p /opt/web-home/current/css
mkdir -p /opt/web-home/current/js

# 下载Bing背景图片
echo "[INFO] 获取今日Bing背景图片..."
mkdir -p /tmp/bing-image
cd /tmp/bing-image

BING_INFO=$(curl -s "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1")
if [ $? -eq 0 ]; then
    IMG_URL=$(echo $BING_INFO | jq -r '.images[0].url' 2>/dev/null)
    
    if [ ! -z "$IMG_URL" ] && [ "$IMG_URL" != "null" ]; then
        FULL_URL="https://www.bing.com${IMG_URL}"
        if wget -q -O bing_today.jpg "$FULL_URL"; then
            cp bing_today.jpg /opt/web-home/current/assets/bing.jpg
            echo "[INFO] Bing背景图片已下载"
        fi
    fi
fi

cd - > /dev/null

# 更新HTML使用端口访问
echo "[INFO] 更新主页链接为端口访问..."
if [ -f "/opt/web-home/current/index.html" ]; then
    # 备份原文件
    cp /opt/web-home/current/index.html /opt/web-home/current/index.html.backup
    
    # 使用直接端口访问链接
    sed -i 's|href="/sui/"|href="https://'"$DOMAIN"':2095"|g' /opt/web-home/current/index.html 2>/dev/null || true
    sed -i 's|'"'/sui/'"'|'"'https://'"$DOMAIN"':2095'"'|g' /opt/web-home/current/index.html 2>/dev/null || true
    sed -i 's|/sui/|https://'"$DOMAIN"':2095|g' /opt/web-home/current/index.html 2>/dev/null || true
    sed -i 's|/adguard/|https://'"$DOMAIN"':3000|g' /opt/web-home/current/index.html 2>/dev/null || true
    
    # 确保所有S-UI链接都指向端口
    sed -i 's|https://\$host/sui/|https://'"$DOMAIN"':2095|g' /opt/web-home/current/index.html 2>/dev/null || true
    sed -i 's|'\''/sui/'\''|'\''https://'"$DOMAIN"':2095'\''|g' /opt/web-home/current/index.html 2>/dev/null || true
    sed -i 's|"/sui/"|"https://'"$DOMAIN"':2095"|g' /opt/web-home/current/index.html 2>/dev/null || true
    
    # 更新服务检查路径
    sed -i 's|check: '\''/sui/'\''|check: '\''https://'"$DOMAIN"':2095'\''|g' /opt/web-home/current/index.html 2>/dev/null || true
    sed -i 's|check: \"/sui/\"|check: \"https://'"$DOMAIN"':2095\"|g' /opt/web-home/current/index.html 2>/dev/null || true
    
    echo "[INFO] 主页链接已更新为端口访问"
fi

chown -R www-data:www-data /opt/web-home/current
chmod -R 755 /opt/web-home/current

rm -rf /tmp/web-home-repo
rm -rf /tmp/bing-image

# 步骤 9：配置 Nginx（仅主站和订阅转换）
echo "[9/11] 配置 Nginx"
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    
    ssl_certificate /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    
    # 主页
    location / {
        root /opt/web-home/current;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }
    
    # 静态资源
    location /assets/ {
        root /opt/web-home/current;
        expires 1d;
        add_header Cache-Control "public, max-age=86400";
        try_files \$uri /assets/bing.jpg;
    }
    
    location /css/ {
        root /opt/web-home/current;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
    
    location /js/ {
        root /opt/web-home/current;
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
    
    # Sub-Web前端
    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        index index.html;
        try_files \$uri \$uri/ /subconvert/index.html;
    }
    
    # SubConverter API
    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    access_log /var/log/nginx/main_access.log;
    error_log /var/log/nginx/main_error.log;
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

# 步骤 10：创建自动更新脚本
echo "[10/11] 创建自动更新脚本"
cat > /usr/local/bin/update-web-home.sh <<EOF
#!/bin/bash
set -e

echo "[INFO] \$(date) - 开始更新Web主页"
cd /tmp

BACKUP_DIR="/opt/web-home/backup"
mkdir -p "\$BACKUP_DIR"
BACKUP_NAME="backup-\$(date +%Y%m%d-%H%M%S)"
if [ -d "/opt/web-home/current" ]; then
    cp -r /opt/web-home/current "\$BACKUP_DIR/\$BACKUP_NAME"
fi

rm -rf /tmp/web-home-update
if git clone https://github.com/about300/vps-deployment.git /tmp/web-home-update; then
    rm -rf /opt/web-home/current/*
    
    if [ -d "/tmp/web-home-update/web" ]; then
        cp -r /tmp/web-home-update/web/* /opt/web-home/current/
    else
        cp -r /tmp/web-home-update/* /opt/web-home/current/
    fi
    
    # 确保使用端口访问
    if [ -f "/opt/web-home/current/index.html" ]; then
        DOMAIN=\$(cat /etc/nginx/sites-available/* | grep "server_name" | head -1 | awk '{print \$2}' | tr -d ';')
        
        # 更新所有S-UI链接为端口访问
        sed -i 's|href="/sui/"|href="https://'"\$DOMAIN"':2095"|g' /opt/web-home/current/index.html 2>/dev/null || true
        sed -i 's|'"'/sui/'"'|'"'https://'"\$DOMAIN"':2095'"'|g' /opt/web-home/current/index.html 2>/dev/null || true
        sed -i 's|/sui/|https://'"\$DOMAIN"':2095|g' /opt/web-home/current/index.html 2>/dev/null || true
        sed -i 's|/adguard/|https://'"\$DOMAIN"':3000|g' /opt/web-home/current/index.html 2>/dev/null || true
        
        # 更新JavaScript中的链接
        sed -i 's|https://\\\\\\\$host/sui/|https://'"\$DOMAIN"':2095|g' /opt/web-home/current/index.html 2>/dev/null || true
        sed -i 's|'\''/sui/'\''|'\''https://'"\$DOMAIN"':2095'\''|g' /opt/web-home/current/index.html 2>/dev/null || true
        sed -i 's|"/sui/"|"https://'"\$DOMAIN"':2095"|g' /opt/web-home/current/index.html 2>/dev/null || true
    fi
    
    chown -R www-data:www-data /opt/web-home/current
    chmod -R 755 /opt/web-home/current
    
    systemctl reload nginx
    echo "[INFO] 主页更新成功！"
else
    echo "[ERROR] 从GitHub获取代码失败"
    if [ -d "\$BACKUP_DIR/\$BACKUP_NAME" ]; then
        rm -rf /opt/web-home/current/*
        cp -r "\$BACKUP_DIR/\$BACKUP_NAME"/* /opt/web-home/current/
    fi
    exit 1
fi

rm -rf /tmp/web-home-update
echo "[INFO] 更新完成"
EOF

chmod +x /usr/local/bin/update-web-home.sh

cat > /usr/local/bin/update-home <<'EOF'
#!/bin/bash
echo "开始手动更新Web主页..."
/usr/local/bin/update-web-home.sh
EOF
chmod +x /usr/local/bin/update-home

# 添加cron任务
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/update-web-home.sh >> /var/log/web-home-update.log 2>&1") | crontab -

# 步骤 11：创建检查脚本
echo "[11/11] 创建检查脚本"
cat > /usr/local/bin/check-services.sh <<EOF
#!/bin/bash
echo "=== VPS 服务状态检查 ==="
echo "时间: \$(date)"
DOMAIN="${DOMAIN}"
echo "域名: \$DOMAIN"
echo ""

echo "1. 服务状态:"
echo "   Nginx: \$(systemctl is-active nginx 2>/dev/null || echo '未安装')"
echo "   SubConverter: \$(systemctl is-active subconverter 2>/dev/null || echo '未安装')"
echo "   S-UI: \$(systemctl is-active s-ui 2>/dev/null || echo '未安装')"
echo "   AdGuard Home: \$(systemctl is-active AdGuardHome 2>/dev/null || echo '未安装')"
echo ""

echo "2. 端口监听:"
echo "   443 (HTTPS): \$(ss -tln 2>/dev/null | grep ':443 ' && echo '✅ 监听中' || echo '❌ 未监听')"
echo "   2095 (S-UI): \$(ss -tln 2>/dev/null | grep ':2095 ' && echo '✅ 监听中' || echo '❌ 未监听')"
echo "   3000 (AdGuard): \$(ss -tln 2>/dev/null | grep ':3000 ' && echo '✅ 监听中' || echo '❌ 未监听')"
echo "   25500 (SubConverter): \$(ss -tln 2>/dev/null | grep ':25500 ' && echo '✅ 监听中' || echo '❌ 未监听')"
echo ""

echo "3. SSL证书路径:"
echo "   • /etc/nginx/ssl/\$DOMAIN/fullchain.pem"
echo "   • /etc/nginx/ssl/\$DOMAIN/key.pem"
echo ""

echo "4. 访问地址:"
echo "   主页:        https://\$DOMAIN"
echo "   S-UI面板:    https://\$DOMAIN:2095 (根目录，端口访问)"
echo "   AdGuard Home: https://\$DOMAIN:3000 (端口访问)"
echo "   订阅转换:     https://\$DOMAIN/subconvert/"
echo ""

echo "5. 目录检查:"
echo "   主页目录: \$(ls -la /opt/web-home/current/ 2>/dev/null | wc -l) 个文件"
echo "   Sub-Web前端: \$(ls -la /opt/sub-web-modify/dist/ 2>/dev/null | wc -l) 个文件"
echo "   SubConverter: \$(ls -la /opt/subconverter/ 2>/dev/null | wc -l) 个文件"
echo ""

echo "6. 背景图片检查:"
if [ -f "/opt/web-home/current/assets/bing.jpg" ]; then
    echo "   ✅ 背景图片存在: /opt/web-home/current/assets/bing.jpg"
    IMG_SIZE=\$(stat -c%s "/opt/web-home/current/assets/bing.jpg" 2>/dev/null || echo 0)
    echo "   文件大小: \$((IMG_SIZE/1024)) KB"
else
    echo "   ❌ 背景图片不存在"
fi
EOF

chmod +x /usr/local/bin/check-services.sh

# 完成信息
echo ""
echo "====================================="
echo "🎉 VPS 全栈部署完成 v${SCRIPT_VERSION}"
echo "====================================="
echo ""
echo "📋 部署模式: 端口访问模式 (回滚版)"
echo ""
echo "🌐 访问地址:"
echo ""
echo "   主页面:        https://$DOMAIN"
echo "   S-UI面板:     https://$DOMAIN:2095 (根目录，直接端口访问)"
echo "   AdGuard Home: https://$DOMAIN:3000 (端口访问)"
echo "   订阅转换前端:  https://$DOMAIN/subconvert/"
echo "   订阅转换API:   https://$DOMAIN/sub/api/"
echo ""
echo "🔐 SSL证书路径:"
echo "   • /etc/nginx/ssl/$DOMAIN/fullchain.pem"
echo "   • /etc/nginx/ssl/$DOMAIN/key.pem"
echo ""
echo "🖼️ Bing背景图片:"
echo "   • 每日自动更新Bing壁纸"
echo "   • 路径: /opt/web-home/current/assets/bing.jpg"
echo ""
echo "🔄 自动更新:"
echo "   • 主页每天自动更新"
echo "   • 手动更新命令: update-home"
echo ""
echo "🛠️ 管理命令:"
echo "   • 服务状态: check-services.sh"
echo "   • 更新主页: update-home"
echo "   • 查看日志: journalctl -u 服务名 -f"
echo ""
echo "📁 重要目录:"
echo "   • 主页: /opt/web-home/current/"
echo "   • 背景图片: /opt/web-home/current/assets/bing.jpg"
echo "   • Sub-Web: /opt/sub-web-modify/dist/"
echo "   • SubConverter: /opt/subconverter/"
echo ""
echo "====================================="
echo "部署时间: $(date)"
echo "====================================="

echo ""
echo "🔍 执行快速测试..."
sleep 2
bash /usr/local/bin/check-services.sh

echo ""
echo "💡 重要提示:"
echo "   1. S-UI面板使用根目录，访问地址: https://$DOMAIN:2095"
echo "   2. AdGuard Home访问地址: https://$DOMAIN:3000"
echo "   3. 所有链接均已更新为端口访问模式"
echo "   4. 主页中的S-UI链接指向 https://$DOMAIN:2095"
echo ""

# 清理旧的S-UI反代配置（如果存在）
echo "[INFO] 清理旧的S-UI反代配置..."
rm -f /etc/nginx/sites-available/sui-*.conf 2>/dev/null || true
rm -f /etc/nginx/sites-enabled/sui-*.conf 2>/dev/null || true

# 重新测试Nginx
nginx -t && systemctl reload nginx
echo "[INFO] Nginx配置已清理并重载"