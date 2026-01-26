#!/usr/bin/env bash
set -e

##############################
# VPS 全栈部署脚本
# Version: v5.1.0 (反代修复版)
# Author: Auto-generated
# Description: 使用主域名路径访问所有服务，修复背景图片问题
##############################

echo "===== VPS 全栈部署（反代修复版）v5.1.0 ====="

# -----------------------------
# 版本信息
# -----------------------------
SCRIPT_VERSION="5.1.0"
echo "版本: v${SCRIPT_VERSION}"
echo "更新: 修复S-UI面板反代和主页背景图片问题"
echo "说明: 所有服务使用主域名路径访问，背景图片自动更新"
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

# Web主页GitHub仓库
WEB_HOME_REPO="https://github.com/about300/vps-deployment.git"

echo "[INFO] 将使用以下访问路径："
echo "  • 主域名: https://$DOMAIN"
echo "  • S-UI面板: https://$DOMAIN/sui/"
echo "  • AdGuard Home: https://$DOMAIN/adguard/"
echo "  • 订阅转换: https://$DOMAIN/subconvert/"
echo "  • VLESS端口: $VLESS_PORT"
echo ""

# -----------------------------
# 步骤 1：更新系统与依赖
# -----------------------------
echo "[1/12] 更新系统与安装依赖"
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
echo "[2/12] 配置防火墙"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 2095  # S-UI面板直接访问
ufw allow 3000   # AdGuard Home Web界面
ufw allow 8445   # AdGuard Home 管理端口1
ufw allow 8446   # AdGuard Home 管理端口2
ufw allow from 127.0.0.1 to any port 25500  # SubConverter仅本地访问
ufw allow ${VLESS_PORT}/tcp
echo "y" | ufw --force enable

echo "[INFO] 防火墙配置完成："
echo "  • 开放端口: 22(SSH), 80(HTTP), 443(HTTPS), 2095(S-UI), 3000, 8445, 8446"
echo "  • VLESS端口: ${VLESS_PORT}"
echo "  • 本地访问(127.0.0.1): 25500(subconverter)"
echo ""

# 显示防火墙状态
ufw status numbered

# -----------------------------
# 步骤 3：安装 acme.sh 和 SSL 证书
# -----------------------------
echo "[3/12] 安装 SSL 证书"
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

# -----------------------------
# 步骤 4：安装 SubConverter 后端
# -----------------------------
echo "[4/12] 安装 SubConverter 后端"
mkdir -p /opt/subconverter

# 直接下载 SubConverter 固定版本 (v0.9.2)
DOWNLOAD_URL="https://github.com/MetaCubeX/subconverter/releases/download/v0.9.2/subconverter_linux64.tar.gz"

echo "[INFO] 下载 SubConverter 二进制文件..."
wget -O /opt/subconverter/subconverter.tar.gz "$DOWNLOAD_URL"

# 解压 SubConverter 文件
echo "[INFO] 解压 SubConverter..."
tar -zxvf /opt/subconverter/subconverter.tar.gz -C /opt/subconverter --strip-components=1
rm -f /opt/subconverter/subconverter.tar.gz

# 确保二进制文件可执行
chmod +x /opt/subconverter/subconverter

# 创建 subconverter.env 配置文件
echo "[INFO] 创建 subconverter.env 配置文件"
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

# 创建 systemd 服务
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
echo "[5/12] 构建 sub-web-modify 前端"
if ! command -v node &> /dev/null; then
    echo "[INFO] 安装 Node.js..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
fi

# 清理旧目录
rm -rf /opt/sub-web-modify
mkdir -p /opt/sub-web-modify

# 克隆已修复的仓库
echo "[INFO] 克隆已修复的sub-web-modify仓库..."
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify

cd /opt/sub-web-modify

# 验证源码修复状态
echo "[INFO] 验证源码修复状态..."
if grep -q 'href="/subconvert/css/main.css"' public/index.html 2>/dev/null; then
    echo "    ✅ public/index.html路径已修复"
else
    echo "    ⚠️  public/index.html可能需要手动修复"
fi

# 安装依赖
echo "[INFO] 安装npm依赖..."
npm install --no-audit --no-fund

# 构建前端
echo "[INFO] 构建前端..."
npm run build

# 验证构建结果
if [ -f "dist/index.html" ]; then
    echo "    ✅ 构建成功"
else
    echo "    ❌ 构建失败"
    exit 1
fi

echo "[INFO] Sub-Web前端部署完成"

# -----------------------------
# 步骤 6：安装 S-UI 面板
# -----------------------------
echo "[6/12] 安装 S-UI 面板"
echo "[INFO] 使用官方安装脚本安装 S-UI 面板..."
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
echo "[INFO] S-UI 面板安装完成"

# -----------------------------
# 步骤 7：安装 AdGuard Home
# -----------------------------
echo "[7/12] 安装 AdGuard Home"
echo "[INFO] 使用指定命令安装 AdGuard Home..."
cd /tmp
curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v

# 配置AdGuard Home使用端口3000
if [ -f "/opt/AdGuardHome/AdGuardHome.yaml" ]; then
    echo "[INFO] 配置AdGuard Home绑定到3000端口"
    sed -i 's/^bind_port: .*/bind_port: 3000/' /opt/AdGuardHome/AdGuardHome.yaml 2>/dev/null || true
    systemctl restart AdGuardHome
fi

echo "[INFO] AdGuard Home 安装完成"
cd - > /dev/null

# -----------------------------
# 步骤 8：从GitHub部署主页（带背景图片）
# -----------------------------
echo "[8/12] 从GitHub部署主页（包含背景图片）"
rm -rf /opt/web-home
mkdir -p /opt/web-home/current

echo "[INFO] 克隆GitHub仓库获取主页..."
git clone $WEB_HOME_REPO /tmp/web-home-repo

# 检查是否有web目录
if [ -d "/tmp/web-home-repo/web" ]; then
    echo "[INFO] 找到web目录，复制所有文件..."
    cp -r /tmp/web-home-repo/web/* /opt/web-home/current/
    
    # 确保assets目录存在
    if [ ! -d "/opt/web-home/current/assets" ]; then
        mkdir -p /opt/web-home/current/assets
        echo "[INFO] 创建assets目录"
    fi
else
    echo "[INFO] 未找到web目录，复制仓库根目录..."
    cp -r /tmp/web-home-repo/* /opt/web-home/current/
fi

# 确保目录结构正确
mkdir -p /opt/web-home/current/css
mkdir -p /opt/web-home/current/js
mkdir -p /opt/web-home/current/assets

# 验证背景图片路径
echo "[INFO] 验证背景图片路径..."
if [ -f "/tmp/web-home-repo/web/assets/bing.jpg" ]; then
    echo "    ✅ 找到bing.jpg背景图片"
    cp /tmp/web-home-repo/web/assets/bing.jpg /opt/web-home/current/assets/
elif [ -f "/tmp/web-home-repo/assets/bing.jpg" ]; then
    echo "    ✅ 找到bing.jpg背景图片（根目录）"
    cp /tmp/web-home-repo/assets/bing.jpg /opt/web-home/current/assets/
else
    echo "    ⚠️  未找到bing.jpg背景图片，将使用默认路径"
fi

# 设置文件权限
chown -R www-data:www-data /opt/web-home/current
chmod -R 755 /opt/web-home/current

# 清理临时文件
rm -rf /tmp/web-home-repo

echo "[INFO] 主页部署完成"

# -----------------------------
# 步骤 9：配置 Nginx（包含所有服务反代）
# -----------------------------
echo "[9/12] 配置 Nginx（包含S-UI和AdGuard Home反代）"
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
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    # 主页
    location / {
        root /opt/web-home/current;
        index index.html;
        try_files \$uri \$uri/ /index.html;
        
        # 添加CORS头部
        add_header Access-Control-Allow-Origin *;
        add_header Access-Control-Allow-Methods 'GET, POST, OPTIONS';
        add_header Access-Control-Allow-Headers 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
    }
    
    # 静态资源
    location /assets/ {
        root /opt/web-home/current;
        expires 1d;
        add_header Cache-Control "public, max-age=86400";
        
        # 尝试提供背景图片
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
        
        # 添加CORS头部
        add_header Access-Control-Allow-Origin *;
        add_header Access-Control-Allow-Methods 'GET, POST, OPTIONS';
        add_header Access-Control-Allow-Headers 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
    }
    
    # SubConverter API反向代理
    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # 允许跨域
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
    
    # S-UI面板反向代理 - 使用根路径重写
    location /sui/ {
        proxy_pass https://127.0.0.1:2095/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # 重写响应中的URL，解决登录跳转问题
        proxy_redirect https://127.0.0.1:2095/ https://\$host/sui/;
        proxy_redirect https://\$host:2095/ https://\$host/sui/;
        
        # 修改HTML响应中的链接
        sub_filter_once off;
        sub_filter_types text/html;
        sub_filter 'href="/' 'href="/sui/';
        sub_filter 'src="/' 'src="/sui/';
        sub_filter 'action="/' 'action="/sui/';
        sub_filter 'url("/' 'url("/sui/';
        sub_filter "url('/" "url('/sui/";
        
        # 处理可能的绝对路径
        sub_filter 'https://127.0.0.1:2095' 'https://\$host/sui';
        sub_filter 'https://\$host:2095' 'https://\$host/sui';
        
        # 处理API路径
        sub_filter '"/api/' '"/sui/api/';
    }
    
    # S-UI API路径
    location /sui/api/ {
        proxy_pass https://127.0.0.1:2095/api/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
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
    
    # AdGuard Home反向代理
    location /adguard/ {
        proxy_pass http://127.0.0.1:3000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # AdGuard Home需要WebSocket支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # 重写响应中的URL
        proxy_redirect http://127.0.0.1:3000/ https://\$host/adguard/;
        proxy_redirect http://\$host:3000/ https://\$host/adguard/;
        
        # 修改HTML响应中的链接
        sub_filter_once off;
        sub_filter_types text/html text/css text/javascript application/javascript;
        sub_filter 'href="/' 'href="/adguard/';
        sub_filter 'src="/' 'src="/adguard/';
        sub_filter 'action="/' 'action="/adguard/';
        sub_filter 'url("/' 'url("/adguard/';
        sub_filter "url('/" "url('/adguard/";
        
        # 处理API路径
        sub_filter '"/control/' '"/adguard/control/';
        sub_filter '"/dhcp/' '"/adguard/dhcp/';
    }
    
    # AdGuard Home控制接口
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
    
    # AdGuard Home DHCP接口
    location /adguard/dhcp/ {
        proxy_pass http://127.0.0.1:3000/dhcp/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # AdGuard Home根路径重定向
    location = /adguard {
        return 301 https://\$host/adguard/;
    }
    
    access_log /var/log/nginx/main_access.log;
    error_log /var/log/nginx/main_error.log;
}
EOF

# 移除默认站点，启用新配置
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/

echo "[INFO] 测试Nginx配置..."
if nginx -t 2>&1 | grep -q "test is successful"; then
    echo "[INFO] Nginx配置测试成功"
    systemctl reload nginx
    echo "[INFO] Nginx已重载配置"
else
    echo "[ERROR] Nginx配置测试失败"
    nginx -t
    exit 1
fi

# -----------------------------
# 步骤 10：创建自动更新脚本（带背景图片更新）
# -----------------------------
echo "[10/12] 创建自动更新脚本（包含背景图片更新）"
cat > /usr/local/bin/update-web-home.sh <<'EOF'
#!/bin/bash
# Web主页自动更新脚本（包含背景图片）
set -e

echo "[INFO] $(date) - 开始更新Web主页"
cd /tmp

# 备份当前版本
BACKUP_DIR="/opt/web-home/backup"
mkdir -p "$BACKUP_DIR"
BACKUP_NAME="backup-$(date +%Y%m%d-%H%M%S)"
if [ -d "/opt/web-home/current" ]; then
    cp -r /opt/web-home/current "$BACKUP_DIR/$BACKUP_NAME"
    echo "[INFO] 备份当前版本到: $BACKUP_DIR/$BACKUP_NAME"
fi

# 从GitHub获取最新代码
echo "[INFO] 从GitHub获取最新代码..."
rm -rf /tmp/web-home-update
if git clone https://github.com/about300/vps-deployment.git /tmp/web-home-update; then
    # 部署新版本
    echo "[INFO] 部署新版本..."
    rm -rf /opt/web-home/current/*
    
    # 确定源目录
    SRC_DIR="/tmp/web-home-update"
    if [ -d "/tmp/web-home-update/web" ]; then
        SRC_DIR="/tmp/web-home-update/web"
    fi
    
    # 复制所有文件
    cp -r "$SRC_DIR"/* /opt/web-home/current/
    
    # 确保assets目录存在
    mkdir -p /opt/web-home/current/assets
    
    # 复制背景图片（如果存在）
    if [ -f "/tmp/web-home-update/web/assets/bing.jpg" ]; then
        cp /tmp/web-home-update/web/assets/bing.jpg /opt/web-home/current/assets/
        echo "[INFO] 已更新背景图片: bing.jpg"
    elif [ -f "/tmp/web-home-update/assets/bing.jpg" ]; then
        cp /tmp/web-home-update/assets/bing.jpg /opt/web-home/current/assets/
        echo "[INFO] 已更新背景图片: bing.jpg"
    else
        echo "[WARN] 未找到背景图片，使用现有图片"
    fi
    
    # 替换域名和端口（如果index.html中有占位符）
    if [ -f "/opt/web-home/current/index.html" ]; then
        DOMAIN=$(cat /etc/nginx/sites-available/* | grep "server_name" | head -1 | awk '{print $2}' | tr -d ';')
        VLESS_PORT=$(cat /opt/web-home/current/index.html | grep -o 'VLESS_PORT=[0-9]*' | head -1 | cut -d= -f2)
        [ -z "$VLESS_PORT" ] && VLESS_PORT="8443"
        
        # 替换各种可能的占位符
        sed -i "s|\\\${DOMAIN}|$DOMAIN|g" /opt/web-home/current/index.html 2>/dev/null || true
        sed -i "s|\\\$DOMAIN|$DOMAIN|g" /opt/web-home/current/index.html 2>/dev/null || true
        sed -i "s|\\\${VLESS_PORT}|$VLESS_PORT|g" /opt/web-home/current/index.html 2>/dev/null || true
        sed -i "s|DOMAIN_PLACEHOLDER|$DOMAIN|g" /opt/web-home/current/index.html 2>/dev/null || true
        sed -i "s|VLESS_PORT_PLACEHOLDER|$VLESS_PORT|g" /opt/web-home/current/index.html 2>/dev/null || true
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
    if [ -d "$BACKUP_DIR/$BACKUP_NAME" ]; then
        echo "[INFO] 恢复备份..."
        rm -rf /opt/web-home/current/*
        cp -r "$BACKUP_DIR/$BACKUP_NAME"/* /opt/web-home/current/
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

# 添加cron任务（每天凌晨3点更新）
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/update-web-home.sh >> /var/log/web-home-update.log 2>&1") | crontab -

echo "[INFO] 已设置自动更新任务（每天凌晨3点）"

# -----------------------------
# 步骤 11：创建服务检查脚本
# -----------------------------
echo "[11/12] 创建服务检查脚本"
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

echo "3. 目录检查:"
echo "   主页目录: \$(ls -la /opt/web-home/current/ 2>/dev/null | wc -l) 个文件"
echo "   Sub-Web前端: \$(ls -la /opt/sub-web-modify/dist/ 2>/dev/null | wc -l) 个文件"
echo "   SubConverter: \$(ls -la /opt/subconverter/ 2>/dev/null | wc -l) 个文件"
echo ""

echo "4. 背景图片检查:"
if [ -f "/opt/web-home/current/assets/bing.jpg" ]; then
    echo "   ✅ 背景图片存在: /opt/web-home/current/assets/bing.jpg"
    echo "   文件大小: \$(ls -lh /opt/web-home/current/assets/bing.jpg | awk '{print \$5}')"
else
    echo "   ⚠️  背景图片不存在"
    echo "   [INFO] 在以下位置查找:"
    find /opt/web-home/current -name "*.jpg" -o -name "*.png" | head -5
fi
echo ""

echo "5. 访问路径:"
echo "   主页:        https://\$DOMAIN/"
echo "   S-UI面板:    https://\$DOMAIN/sui/"
echo "   AdGuard Home: https://\$DOMAIN/adguard/"
echo "   订阅转换:     https://\$DOMAIN/subconvert/"
echo "   直接访问:"
echo "     S-UI:     https://\$DOMAIN:2095"
echo "     AdGuard:  https://\$DOMAIN:3000"
EOF

chmod +x /usr/local/bin/check-services.sh

# -----------------------------
# 步骤 12：验证部署
# -----------------------------
echo "[12/12] 验证部署状态"
sleep 5

echo ""
echo "🔍 部署验证:"
echo "1. 检查服务状态:"
services=("nginx" "subconverter" "s-ui" "AdGuardHome")
for svc in "${services[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo "   ✅ $svc 运行正常"
    else
        echo "   ⚠️  $svc 未运行"
    fi
done

echo ""
echo "2. 检查目录:"
if [ -f "/opt/sub-web-modify/dist/index.html" ]; then
    echo "   ✅ Sub-Web前端文件存在"
else
    echo "   ⚠️  Sub-Web前端文件不存在"
fi

if [ -f "/opt/subconverter/subconverter" ]; then
    echo "   ✅ SubConverter后端文件存在"
else
    echo "   ⚠️  SubConverter后端文件不存在"
fi

if [ -f "/opt/web-home/current/index.html" ]; then
    echo "   ✅ 主页文件存在"
    # 检查背景图片
    if [ -f "/opt/web-home/current/assets/bing.jpg" ]; then
        echo "   ✅ 背景图片存在: /opt/web-home/current/assets/bing.jpg"
    else
        echo "   ⚠️  背景图片不存在，将在下次更新时获取"
    fi
else
    echo "   ⚠️  主页文件不存在"
fi

echo ""
echo "3. 路径架构:"
echo "   • 主站: / (独立资源路径)"
echo "   • Sub-Web: /subconvert/ (专属路径)"
echo "   • S-UI面板: /sui/ (通过Nginx反代，解决登录跳转)"
echo "   • AdGuard Home: /adguard/ (通过Nginx反代)"
echo "   • 所有服务使用同一个域名，不同路径访问"

echo ""
echo "4. 访问地址:"
echo "   • 主页面: https://$DOMAIN"
echo "   • S-UI面板: https://$DOMAIN/sui/"
echo "   • AdGuard Home: https://$DOMAIN/adguard/"
echo "   • 订阅转换前端: https://$DOMAIN/subconvert/"
echo "   • 订阅转换API: https://$DOMAIN/sub/api/"
echo ""
echo "   备用访问（直接端口）:"
echo "   • S-UI面板: https://$DOMAIN:2095"
echo "   • AdGuard Home: https://$DOMAIN:3000"

# -----------------------------
# 完成信息
# -----------------------------
echo ""
echo "====================================="
echo "🎉 VPS 全栈部署完成 v${SCRIPT_VERSION}"
echo "====================================="
echo ""
echo "📋 核心修复:"
echo ""
echo "  ✅ S-UI面板反代: 通过/sub/路径访问，使用Nginx sub_filter修复跳转"
echo "  ✅ AdGuard Home反代: 通过/adguard/路径访问"
echo "  ✅ 背景图片支持: 自动从GitHub仓库获取bing.jpg"
echo "  ✅ 路径完全隔离: 所有服务使用独立路径，避免冲突"
echo "  ✅ 自动更新: 主页和背景图片每天自动更新"
echo ""
echo "🌐 访问地址 (全部使用 $DOMAIN):"
echo ""
echo "   主页面:        https://$DOMAIN"
echo "   S-UI面板:     https://$DOMAIN/sui/"
echo "   AdGuard Home: https://$DOMAIN/adguard/"
echo "   订阅转换前端:  https://$DOMAIN/subconvert/"
echo "   订阅转换API:   https://$DOMAIN/sub/api/"
echo ""
echo "🔄 自动更新:"
echo "   • 主页和背景图片每天凌晨3点自动更新"
echo "   • 背景图片来源: vps-deployment/web/assets/bing.jpg"
echo "   • 手动更新命令: update-home"
echo ""
echo "🛠️ 管理命令:"
echo "  • 服务状态: check-services.sh"
echo "  • 更新主页: update-home"
echo "  • 查看日志: journalctl -u 服务名 -f"
echo ""
echo "📁 重要目录:"
echo "  • 主页: /opt/web-home/current/"
echo "  • 背景图片: /opt/web-home/current/assets/bing.jpg"
echo "  • Sub-Web: /opt/sub-web-modify/dist/"
echo "  • SubConverter: /opt/subconverter/"
echo ""
echo "====================================="
echo "部署时间: $(date)"
echo "====================================="

# 快速测试
echo ""
echo "🔍 执行快速测试..."
sleep 2
bash /usr/local/bin/check-services.sh

echo ""
echo "🚀 部署完成！请测试以下地址："
echo "1. 主页面: https://$DOMAIN"
echo "2. S-UI面板: https://$DOMAIN/sui/"
echo "3. AdGuard Home: https://$DOMAIN/adguard/"
echo ""
echo "💡 提示: 如果S-UI面板登录后有问题，请尝试:"
echo "  1. 清除浏览器缓存"
echo "  2. 或直接访问: https://$DOMAIN:2095"
echo ""