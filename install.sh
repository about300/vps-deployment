#!/usr/bin/env bash
set -e

##############################
# VPS 全栈部署脚本 (最终反代版)
# Version: v6.1.0
# Author: Auto-generated
##############################

echo "===== VPS 全栈部署 v6.1.0 ====="

# 版本信息
SCRIPT_VERSION="6.1.0"
echo "版本: v${SCRIPT_VERSION}"
echo "说明: 尝试强力反代方案，如失败可回滚到端口访问"
echo "回滚指令: 在下次对话中输入'回滚'即可"
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
echo "  • S-UI面板: https://$DOMAIN/sui/ (反代)"
echo "  • AdGuard Home: https://$DOMAIN/adguard/ (反代)"
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
    curl https://get.acme.sh | sh
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

# 步骤 8：部署主页
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

# 更新HTML使用反代路径
echo "[INFO] 更新主页链接为反代路径..."
if [ -f "/opt/web-home/current/index.html" ]; then
    sed -i "s|https://\$host:2095|https://\$host/sui/|g" /opt/web-home/current/index.html 2>/dev/null || true
    sed -i "s|'https://' + currentDomain + ':2095'|'/sui/'|g" /opt/web-home/current/index.html 2>/dev/null || true
    sed -i "s|\"https://\" + currentDomain + \":2095\"|\"/sui/\"|g" /opt/web-home/current/index.html 2>/dev/null || true
    sed -i "s|https://\$host:3000|https://\$host/adguard/|g" /opt/web-home/current/index.html 2>/dev/null || true
fi

chown -R www-data:www-data /opt/web-home/current
chmod -R 755 /opt/web-home/current

rm -rf /tmp/web-home-repo
rm -rf /tmp/bing-image

# 步骤 9：配置 Nginx（强力反代配置）
echo "[9/11] 配置 Nginx（强力反代）"
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
    
    # ==================== S-UI面板强力反代 ====================
    location /sui/ {
        proxy_pass https://127.0.0.1:2095/;
        proxy_http_version 1.1;
        
        # 基础头
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Prefix /sui;
        
        # WebSocket支持
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # 重定向
        proxy_redirect https://127.0.0.1:2095/ https://\$host/sui/;
        proxy_redirect https://\$host:2095/ https://\$host/sui/;
        proxy_redirect http://127.0.0.1:2095/ https://\$host/sui/;
        
        # 超时
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        # 禁用缓存
        proxy_no_cache 1;
        proxy_cache_bypass 1;
        
        # ========== 强力内容重写 ==========
        proxy_set_header Accept-Encoding "";
        sub_filter_types *;
        sub_filter_once off;
        
        # 重写所有HTML路径
        sub_filter 'href="/' 'href="/sui/';
        sub_filter 'src="/' 'src="/sui/';
        sub_filter 'action="/' 'action="/sui/';
        sub_filter 'url("/' 'url("/sui/';
        sub_filter "url('/" "url('/sui/";
        
        # 重写API路径
        sub_filter '"/api/' '"/sui/api/';
        sub_filter "'/api/" "'/sui/api/";
        
        # 重写静态资源
        sub_filter '"/static/' '"/sui/static/';
        sub_filter "'/static/" "'/sui/static/";
        
        # 重写绝对URL
        sub_filter 'https://127.0.0.1:2095' 'https://\$host/sui';
        sub_filter 'https://\$host:2095' 'https://\$host/sui';
        
        # 重写登录相关路径
        sub_filter '"/login"' '"/sui/login"';
        sub_filter "'/login'" "'/sui/login'";
        
        # 允许所有请求方法
        proxy_method GET;
        proxy_method POST;
        proxy_method PUT;
        proxy_method DELETE;
        proxy_method OPTIONS;
    }
    
    # S-UI API路径特殊处理
    location /sui/api/ {
        proxy_pass https://127.0.0.1:2095/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    
    # S-UI静态资源
    location /sui/static/ {
        proxy_pass https://127.0.0.1:2095/static/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # S-UI根路径重定向
    location = /sui {
        return 301 https://\$host/sui/;
    }
    
    # ==================== AdGuard Home反代 ====================
    location /adguard/ {
        proxy_pass http://127.0.0.1:3000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_redirect http://127.0.0.1:3000/ https://\$host/adguard/;
        proxy_redirect http://\$host:3000/ https://\$host/adguard/;
        
        # 内容重写
        sub_filter_once off;
        sub_filter_types text/html text/css text/javascript;
        sub_filter 'href="/' 'href="/adguard/';
        sub_filter 'src="/' 'src="/adguard/';
        sub_filter 'action="/' 'action="/adguard/';
        sub_filter 'url("/' 'url("/adguard/';
    }
    
    # AdGuard控制接口
    location /adguard/control/ {
        proxy_pass http://127.0.0.1:3000/control/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    
    # AdGuard根路径重定向
    location = /adguard {
        return 301 https://\$host/adguard/;
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
cat > /usr/local/bin/update-web-home.sh <<'EOF'
#!/bin/bash
set -e

echo "[INFO] $(date) - 开始更新Web主页"
cd /tmp

BACKUP_DIR="/opt/web-home/backup"
mkdir -p "$BACKUP_DIR"
BACKUP_NAME="backup-$(date +%Y%m%d-%H%M%S)"
if [ -d "/opt/web-home/current" ]; then
    cp -r /opt/web-home/current "$BACKUP_DIR/$BACKUP_NAME"
fi

rm -rf /tmp/web-home-update
if git clone https://github.com/about300/vps-deployment.git /tmp/web-home-update; then
    rm -rf /opt/web-home/current/*
    
    if [ -d "/tmp/web-home-update/web" ]; then
        cp -r /tmp/web-home-update/web/* /opt/web-home/current/
    else
        cp -r /tmp/web-home-update/* /opt/web-home/current/
    fi
    
    # 确保使用反代路径
    if [ -f "/opt/web-home/current/index.html" ]; then
        sed -i "s|https://\$host:2095|https://\$host/sui/|g" /opt/web-home/current/index.html 2>/dev/null || true
        sed -i "s|'https://' + currentDomain + ':2095'|'/sui/'|g" /opt/web-home/current/index.html 2>/dev/null || true
        sed -i "s|\"https://\" + currentDomain + \":2095\"|\"/sui/\"|g" /opt/web-home/current/index.html 2>/dev/null || true
        sed -i "s|https://\$host:3000|https://\$host/adguard/|g" /opt/web-home/current/index.html 2>/dev/null || true
    fi
    
    chown -R www-data:www-data /opt/web-home/current
    chmod -R 755 /opt/web-home/current
    
    systemctl reload nginx
    echo "[INFO] 主页更新成功！"
else
    echo "[ERROR] 从GitHub获取代码失败"
    if [ -d "$BACKUP_DIR/$BACKUP_NAME" ]; then
        rm -rf /opt/web-home/current/*
        cp -r "$BACKUP_DIR/$BACKUP_NAME"/* /opt/web-home/current/
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

# 步骤 11：创建检查脚本和回滚脚本
echo "[11/11] 创建检查脚本和回滚脚本"
cat > /usr/local/bin/check-services.sh <<EOF
#!/bin/bash
echo "=== VPS 服务状态检查 ==="
echo "时间: \$(date)"
DOMAIN="${DOMAIN}"
echo "域名: \$DOMAIN"
echo ""

echo "1. 服务状态:"
echo "   Nginx: \$(systemctl is-active nginx)"
echo "   SubConverter: \$(systemctl is-active subconverter)"
echo "   S-UI: \$(systemctl is-active s-ui)"
echo "   AdGuard Home: \$(systemctl is-active AdGuardHome)"
echo ""

echo "2. SSL证书路径:"
echo "   • /etc/nginx/ssl/\$DOMAIN/fullchain.pem"
echo "   • /etc/nginx/ssl/\$DOMAIN/key.pem"
echo ""

echo "3. 反代访问地址:"
echo "   主页:        https://\$DOMAIN"
echo "   S-UI面板:    https://\$DOMAIN/sui/"
echo "   AdGuard Home: https://\$DOMAIN/adguard/"
echo "   订阅转换:     https://\$DOMAIN/subconvert/"
echo ""
echo "4. 备用端口访问:"
echo "   S-UI面板:    https://\$DOMAIN:2095"
echo "   AdGuard Home: https://\$DOMAIN:3000"
EOF

chmod +x /usr/local/bin/check-services.sh

# 创建回滚脚本
cat > /usr/local/bin/rollback-to-ports.sh <<'EOF'
#!/bin/bash
# 回滚到端口访问模式

set -e

echo "=== 开始回滚到端口访问模式 ==="

DOMAIN=$(cat /etc/nginx/sites-available/* | grep "server_name" | head -1 | awk '{print $2}' | tr -d ';')
echo "检测到域名: $DOMAIN"

# 1. 备份当前配置
BACKUP_FILE="/etc/nginx/sites-available/${DOMAIN}.backup.$(date +%Y%m%d_%H%M%S)"
cp "/etc/nginx/sites-available/${DOMAIN}" "$BACKUP_FILE"
echo "✅ 已备份当前配置: $BACKUP_FILE"

# 2. 创建端口访问的Nginx配置
cat > "/etc/nginx/sites-available/${DOMAIN}" <<NGINX_CONFIG
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
NGINX_CONFIG

# 3. 更新HTML文件为端口访问
if [ -f "/opt/web-home/current/index.html" ]; then
    echo "🔄 更新主页链接为端口访问..."
    cp /opt/web-home/current/index.html /opt/web-home/current/index.html.backup
    
    sed -i "s|https://\$host/sui/|https://\$host:2095|g" /opt/web-home/current/index.html 2>/dev/null || true
    sed -i "s|'/sui/'|'https://' + currentDomain + ':2095'|g" /opt/web-home/current/index.html 2>/dev/null || true
    sed -i "s|\"/sui/\"|\"https://\" + currentDomain + \":2095\"|g" /opt/web-home/current/index.html 2>/dev/null || true
    sed -i "s|https://\$host/adguard/|https://\$host:3000|g" /opt/web-home/current/index.html 2>/dev/null || true
    
    echo "✅ 主页链接已更新为端口访问"
fi

# 4. 测试并重载Nginx
echo "🔄 测试Nginx配置..."
if nginx -t; then
    echo "✅ Nginx配置测试成功"
    systemctl reload nginx
    echo "✅ Nginx已重载"
    
    echo ""
    echo "========================================"
    echo "🎉 回滚完成！"
    echo ""
    echo "访问地址:"
    echo "   主页:        https://$DOMAIN"
    echo "   S-UI面板:    https://$DOMAIN:2095"
    echo "   AdGuard Home: https://$DOMAIN:3000"
    echo "   订阅转换:     https://$DOMAIN/subconvert/"
    echo ""
    echo "💡 建议: 清除浏览器缓存后再访问"
    echo "========================================"
else
    echo "❌ Nginx配置测试失败，恢复备份"
    cp "$BACKUP_FILE" "/etc/nginx/sites-available/${DOMAIN}"
    nginx -t
    exit 1
fi

# 5. 更新自动更新脚本
cat > /usr/local/bin/update-web-home.sh <<'UPDATE_EOF'
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
        sed -i "s|https://\\\$host/sui/|https://\\\$host:2095|g" /opt/web-home/current/index.html 2>/dev/null || true
        sed -i "s|'/sui/'|'https://' + currentDomain + ':2095'|g" /opt/web-home/current/index.html 2>/dev/null || true
        sed -i "s|\"/sui/\"|\"https://\" + currentDomain + \":2095\"|g" /opt/web-home/current/index.html 2>/dev/null || true
        sed -i "s|https://\\\$host/adguard/|https://\\\$host:3000|g" /opt/web-home/current/index.html 2>/dev/null || true
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
UPDATE_EOF

chmod +x /usr/local/bin/update-web-home.sh
echo "✅ 自动更新脚本已更新为端口访问模式"

echo ""
echo "🎯 回滚操作完成！"
echo "下次对话中如需回滚，只需输入'回滚'"
EOF

chmod +x /usr/local/bin/rollback-to-ports.sh

# 完成信息
echo ""
echo "====================================="
echo "🎉 VPS 全栈部署完成 v${SCRIPT_VERSION}"
echo "====================================="
echo ""
echo "🌐 访问地址 (强力反代模式):"
echo ""
echo "   主页面:        https://$DOMAIN"
echo "   S-UI面板:     https://$DOMAIN/sui/"
echo "   AdGuard Home: https://$DOMAIN/adguard/"
echo "   订阅转换前端:  https://$DOMAIN/subconvert/"
echo "   订阅转换API:   https://$DOMAIN/sub/api/"
echo ""
echo "🔧 备用访问 (端口访问):"
echo ""
echo "   S-UI面板:     https://$DOMAIN:2095"
echo "   AdGuard Home: https://$DOMAIN:3000"
echo ""
echo "🔄 回滚功能:"
echo ""
echo "   如果反代模式有问题，可运行以下命令回滚到端口访问:"
echo "   rollback-to-ports.sh"
echo ""
echo "   或在下次对话中直接输入: 回滚"
echo ""
echo "🛠️ 管理命令:"
echo ""
echo "   • 服务状态: check-services.sh"
echo "   • 更新主页: update-home"
echo "   • 回滚到端口: rollback-to-ports.sh"
echo ""
echo "📁 重要目录:"
echo ""
echo "   • 主页: /opt/web-home/current/"
echo "   • 背景图片: /opt/web-home/current/assets/bing.jpg"
echo "   • Sub-Web: /opt/sub-web-modify/dist/"
echo "   • SubConverter: /opt/subconverter/"
echo "   • SSL证书: /etc/nginx/ssl/$DOMAIN/"
echo ""
echo "====================================="
echo "部署时间: $(date)"
echo "====================================="

echo ""
echo "🔍 执行快速测试..."
sleep 2
bash /usr/local/bin/check-services.sh

echo ""
echo "💡 提示: 如果S-UI面板登录有问题，请尝试:"
echo "   1. 清除浏览器缓存"
echo "   2. 使用备用地址: https://$DOMAIN:2095"
echo "   3. 运行回滚脚本: rollback-to-ports.sh"