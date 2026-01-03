#!/usr/bin/env bash
set -e

##############################
# VPS 全栈部署脚本
# Version: v4.9 (修复Sub-Web前端版)
# Author: Auto-generated
# Description: 修复SubConverter前端问题，确保所有功能正常
##############################

echo "===== VPS 全栈部署（修复Sub-Web前端）v4.9 ====="

# -----------------------------
# 版本信息
# -----------------------------
SCRIPT_VERSION="4.9"
echo "版本: v${SCRIPT_VERSION}"
echo "更新: 修复SubConverter前端页面问题，确保订阅转换正常显示"
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
echo "[2/12] 配置防火墙（开放VLESS端口: $VLESS_PORT, S-UI端口: 2095）"
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
echo "  • VLESS端口: ${VLESS_PORT} (外部可访问)"
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
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
fi

~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
    --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
    --reloadcmd "systemctl reload nginx"

# -----------------------------
# 步骤 4：安装 SubConverter 后端（使用3.4版本配置）
# -----------------------------
echo "[4/12] 安装 SubConverter 后端"
mkdir -p /opt/subconverter
if [ ! -f "/opt/subconverter/subconverter" ]; then
    echo "[INFO] 下载 subconverter..."
    wget -O /opt/subconverter/subconverter $SUBCONVERTER_BIN
    chmod +x /opt/subconverter/subconverter
fi

# 创建 subconverter.env 配置文件（使用3.4版本配置）
echo "[INFO] 创建 subconverter.env 配置文件"
cat > /opt/subconverter/subconverter.env <<EOF
# SubConverter 配置文件
API_MODE=true
API_HOST=0.0.0.0  # 监听所有地址
API_PORT=25500
CACHE_ENABLED=true
CACHE_SUBSCRIPTION=true
CACHE_CONFIG=true
CACHE_UPDATE_INTERVAL=600
MANAGEMENT_PASS=admin123
EOF

chmod 600 /opt/subconverter/subconverter.env

# 创建 systemd 服务（使用3.4版本配置）
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
# 步骤 5：构建 sub-web-modify 前端（修复前端问题）
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

# 克隆仓库
echo "[INFO] 克隆 sub-web-modify 仓库..."
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify

cd /opt/sub-web-modify

# 修复package.json如果不存在
if [ ! -f "package.json" ]; then
    echo "[INFO] 创建默认package.json..."
    cat > package.json <<EOF
{
  "name": "sub-web-modify",
  "version": "1.0.0",
  "description": "SubConverter Web Frontend",
  "scripts": {
    "serve": "vue-cli-service serve",
    "build": "vue-cli-service build",
    "lint": "vue-cli-service lint"
  },
  "dependencies": {
    "vue": "^2.6.14",
    "vue-router": "^3.5.3",
    "axios": "^0.27.2",
    "element-ui": "^2.15.9"
  },
  "devDependencies": {
    "@vue/cli-service": "^4.5.19"
  }
}
EOF
fi

# 创建vue.config.js文件
echo "[INFO] 创建vue.config.js配置文件..."
cat > vue.config.js <<'EOF'
const { defineConfig } = require('@vue/cli-service')

module.exports = defineConfig({
  transpileDependencies: true,
  publicPath: '/subconvert/',
  outputDir: 'dist',
  assetsDir: 'static',
  indexPath: 'index.html',
  productionSourceMap: false,
  devServer: {
    proxy: {
      '/api': {
        target: 'http://localhost:25500',
        changeOrigin: true
      }
    }
  }
})
EOF

# 安装依赖并构建
echo "[INFO] 安装npm依赖..."
npm install --no-audit --no-fund

echo "[INFO] 构建前端..."
npm run build

# 检查构建结果
if [ ! -d "dist" ]; then
    echo "[ERROR] 前端构建失败，dist目录不存在"
    echo "[INFO] 尝试手动构建..."
    # 创建简单的静态页面
    mkdir -p dist
    cat > dist/index.html <<'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>订阅转换 - SubConverter</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Noto Sans SC', sans-serif; background: #f5f7fa; }
        .container { max-width: 1200px; margin: 0 auto; padding: 20px; }
        header { background: #0078ff; color: white; padding: 2rem; border-radius: 10px; margin-bottom: 2rem; }
        h1 { font-size: 2.5rem; margin-bottom: 0.5rem; }
        .main-content { background: white; padding: 2rem; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .api-info { background: #e8f4ff; padding: 1.5rem; border-radius: 8px; margin: 2rem 0; }
        pre { background: #2c3e50; color: white; padding: 1rem; border-radius: 5px; overflow-x: auto; }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>订阅转换服务</h1>
            <p>SubConverter 后端API服务正常运行</p>
        </header>
        <div class="main-content">
            <h2>API 接口信息</h2>
            <div class="api-info">
                <p>后端API地址: <code>/sub/api/</code></p>
                <p>支持格式: Clash, V2Ray, Quantumult X, Surge, Sing-Box等</p>
            </div>
            
            <h3>使用示例:</h3>
            <pre># 基本格式转换
/sub/api/sub?target=clash&url=你的订阅链接

# 更多参数
/sub/api/sub?target=clash&url=订阅链接&config=https://raw.githubusercontent.com/.../config.ini</pre>
            
            <h3>API文档:</h3>
            <p>详细的API文档请参考: <a href="https://github.com/tindy2013/subconverter" target="_blank">SubConverter GitHub</a></p>
        </div>
    </div>
</body>
</html>
EOF
else
    echo "[INFO] 前端构建成功"
    # 复制配置文件模板
    if [ -f "dist/config.template.js" ] && [ ! -f "dist/config.js" ]; then
        echo "[INFO] 复制配置文件模板"
        cp dist/config.template.js dist/config.js
    fi
fi

echo "[INFO] Sub-Web前端部署完成"

# -----------------------------
# 步骤 6：安装 S-UI 面板（使用默认交互方式）
# -----------------------------
echo "[6/12] 安装 S-UI 面板"
echo "[INFO] 使用官方安装脚本安装 S-UI 面板..."
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
echo "[INFO] S-UI 面板安装完成"

# -----------------------------
# 步骤 7：安装 AdGuard Home（使用指定命令）
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
# 步骤 8：从GitHub部署主页
# -----------------------------
echo "[8/12] 从GitHub部署主页"
rm -rf /opt/web-home
mkdir -p /opt/web-home/current

echo "[INFO] 克隆GitHub仓库获取主页..."
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

# 如果index.html存在，替换域名
if [ -f "/opt/web-home/current/index.html" ]; then
    echo "[INFO] 替换index.html中的域名和端口..."
    sed -i "s|\\\${DOMAIN}|$DOMAIN|g" /opt/web-home/current/index.html 2>/dev/null || true
    sed -i "s|\\\$DOMAIN|$DOMAIN|g" /opt/web-home/current/index.html 2>/dev/null || true
    sed -i "s|\\\${VLESS_PORT}|$VLESS_PORT|g" /opt/web-home/current/index.html 2>/dev/null || true
fi

# 设置文件权限
chown -R www-data:www-data /opt/web-home/current
chmod -R 755 /opt/web-home/current

# 清理临时文件
rm -rf /tmp/web-home-repo

echo "[INFO] 主页部署完成"

# -----------------------------
# 步骤 9：配置 Nginx（确保Sub-Web前端正常）
# -----------------------------
echo "[9/12] 配置 Nginx"
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

    # ========================
    # Sub-Web 前端
    # ========================
    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
        
        # 缓存静态资源
        location ~* \\.(js|css|png|jpg|jpeg|gif|ico|svg)\$ {
            expires 1y;
            add_header Cache-Control "public, immutable";
        }
    }

    # ========================
    # SubConverter API 后端
    # ========================
    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        
        # 增加超时时间
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
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

# HTTP 强制跳转 HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
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
# 步骤 10：创建自动更新脚本
# -----------------------------
echo "[10/12] 创建自动更新脚本"
cat > /usr/local/bin/update-web-home.sh <<'EOF'
#!/bin/bash
# Web主页自动更新脚本
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
    
    if [ -d "/tmp/web-home-update/web" ]; then
        cp -r /tmp/web-home-update/web/* /opt/web-home/current/
    else
        cp -r /tmp/web-home-update/* /opt/web-home/current/
    fi
    
    # 替换域名
    if [ -f "/opt/web-home/current/index.html" ]; then
        DOMAIN=$(cat /etc/nginx/sites-available/* | grep "server_name" | head -1 | awk '{print $2}' | tr -d ';')
        VLESS_PORT=$(cat /opt/web-home/current/index.html | grep -o 'VLESS_PORT=[0-9]*' | head -1 | cut -d= -f2)
        [ -z "$VLESS_PORT" ] && VLESS_PORT="8443"
        
        sed -i "s|\\\${DOMAIN}|$DOMAIN|g" /opt/web-home/current/index.html 2>/dev/null || true
        sed -i "s|\\\$DOMAIN|$DOMAIN|g" /opt/web-home/current/index.html 2>/dev/null || true
        sed -i "s|\\\${VLESS_PORT}|$VLESS_PORT|g" /opt/web-home/current/index.html 2>/dev/null || true
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

# 添加cron任务
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/update-web-home.sh >> /var/log/web-home-update.log 2>&1") | crontab -

# -----------------------------
# 步骤 11：创建服务检查脚本
# -----------------------------
echo "[11/12] 创建服务检查脚本"
cat > /usr/local/bin/check-services.sh <<'EOF'
#!/bin/bash
echo "=== VPS 服务状态检查 ==="
echo "时间: $(date)"
echo "域名: $(cat /etc/nginx/sites-available/* | grep "server_name" | head -1 | awk '{print $2}' | tr -d ';')"
echo ""
echo "1. 服务状态:"
echo "   Nginx: $(systemctl is-active nginx)"
echo "   SubConverter: $(systemctl is-active subconverter)"
echo "   S-UI: $(systemctl is-active s-ui)"
echo "   AdGuard Home: $(systemctl is-active AdGuardHome)"
echo ""
echo "2. 端口监听:"
echo "   443 (HTTPS): $(ss -tln | grep ':443 ' && echo '✅ 监听中' || echo '❌ 未监听')"
echo "   2095 (S-UI): $(ss -tln | grep ':2095 ' && echo '✅ 监听中' || echo '❌ 未监听')"
echo "   3000 (AdGuard): $(ss -tln | grep ':3000 ' && echo '✅ 监听中' || echo '❌ 未监听')"
echo "   25500 (SubConverter): $(ss -tln | grep ':25500 ' && echo '✅ 监听中' || echo '❌ 未监听')"
echo ""
echo "3. 目录检查:"
echo "   主页目录: $(ls -la /opt/web-home/current/ | wc -l) 个文件"
echo "   Sub-Web前端: $(ls -la /opt/sub-web-modify/dist/ 2>/dev/null | wc -l) 个文件"
echo "   SubConverter: $(ls -la /opt/subconverter/ | wc -l) 个文件"
echo ""
echo "4. 访问测试:"
echo "   主页: curl -s -o /dev/null -w "%{http_code}" https://$DOMAIN"
echo "   Sub-Web: curl -s -o /dev/null -w "%{http_code}" https://$DOMAIN/subconvert/"
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
    if systemctl is-active --quiet "$svc"; then
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
    echo "   [INFO] 前端文件位置: /opt/sub-web-modify/dist/"
fi

if [ -f "/opt/subconverter/subconverter" ]; then
    echo "   ✅ SubConverter后端文件存在"
else
    echo "   ⚠️  SubConverter后端文件不存在"
fi

if [ -f "/opt/web-home/current/index.html" ]; then
    echo "   ✅ 主页文件存在"
else
    echo "   ⚠️  主页文件不存在"
fi

echo ""
echo "3. 访问地址:"
echo "   • 主页面: https://$DOMAIN"
echo "   • 订阅转换前端: https://$DOMAIN/subconvert/"
echo "   • 订阅转换API: https://$DOMAIN/sub/api/"
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
echo "📋 重要访问地址:"
echo ""
echo "  🌐 主页面:       https://$DOMAIN"
echo "  🔧 订阅转换前端: https://$DOMAIN/subconvert/"
echo "  ⚙️  订阅转换API:  https://$DOMAIN/sub/api/"
echo "  📊 S-UI面板:     https://$DOMAIN:2095"
echo "  🛡️  AdGuard:     https://$DOMAIN:3000"
echo ""
echo "🔧 订阅转换使用说明:"
echo "  1. 访问 https://$DOMAIN/subconvert/"
echo "  2. 在页面中输入订阅链接"
echo "  3. 选择目标格式 (Clash, V2Ray, Quantumult X等)"
echo "  4. 点击转换并复制结果"
echo ""
echo "⚙️  VLESS 配置:"
echo "  • 域名: $DOMAIN"
echo "  • 端口: $VLESS_PORT"
echo "  • 在S-UI面板中配置入站节点"
echo ""
echo "🛠️ 管理命令:"
echo "  • 服务状态: check-services.sh"
echo "  • 更新主页: update-home"
echo "  • SubConverter日志: journalctl -u subconverter -f"
echo "  • S-UI日志: journalctl -u s-ui -f"
echo ""
echo "📁 重要目录:"
echo "  • 主页目录: /opt/web-home/current/"
echo "  • Sub-Web前端: /opt/sub-web-modify/dist/"
echo "  • SubConverter: /opt/subconverter/"
echo "  • SSL证书: /etc/nginx/ssl/$DOMAIN/"
echo ""
echo "🔄 自动更新:"
echo "  • 每天凌晨3点自动从GitHub更新主页"
echo "  • 更新日志: /var/log/web-home-update.log"
echo ""
echo "====================================="
echo "部署时间: $(date)"
echo "====================================="

# 快速测试
echo ""
echo "🔍 快速测试..."
sleep 3
bash /usr/local/bin/check-services.sh