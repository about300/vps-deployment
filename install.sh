#!/usr/bin/env bash
set -e

##############################
# VPS 全栈部署（最终生产版）
# Version: v1.0.3
# Mode: ADD-ONLY / NO-DELETE
##############################

LOG_FILE="/var/log/vps-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== VPS 全栈部署（最终版） ====="
echo "Version: v1.0.3"
echo "Log: $LOG_FILE"
echo "Start Time: $(date)"

# -----------------------------
# 步骤 0：预定义变量
# -----------------------------
read -rp "请输入您的域名 (例如：example.domain): " DOMAIN
read -rp "请输入 Cloudflare 邮箱: " CF_Email
read -rp "请输入 Cloudflare API Token: " CF_Token
export CF_Email
export CF_Token

# VLESS 默认端口
VLESS_PORT=5000

# SubConverter 二进制下载链接
SUBCONVERTER_BIN="https://github.com/about300/vps-deployment/raw/refs/heads/main/bin/subconverter"

# 你的仓库
WEB_HOME_REPO="https://github.com/about300/vps-deployment.git"
SUB_WEB_MODIFY_REPO="https://github.com/about300/sub-web-modify.git"
SUB_WEB_API_REPO="https://github.com/about300/sub-web-api.git"

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
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000
ufw allow 3001
ufw allow 8445
ufw allow 8446
ufw allow 25500
ufw allow 2095
ufw allow 5000
ufw --force enable

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
echo "[4/13] 申请或检查 SSL 证书"
if [ ! -f "/etc/nginx/ssl/$DOMAIN/fullchain.pem" ]; then
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
fi

# -----------------------------
# 步骤 5：安装证书到 Nginx
# -----------------------------
echo "[5/13] 安装证书到 Nginx"
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
    --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
    --reloadcmd "systemctl reload nginx"

# -----------------------------
# 步骤 6：安装 SubConverter 后端
# -----------------------------
echo "[6/13] 安装 SubConverter"
mkdir -p /opt/subconverter
if [ ! -f "/opt/subconverter/subconverter" ]; then
    wget -O /opt/subconverter/subconverter $SUBCONVERTER_BIN
    chmod +x /opt/subconverter/subconverter
fi

# 检查 subconverter 是否在运行
if systemctl is-active --quiet subconverter; then
    echo "停止已存在的 subconverter 服务..."
    systemctl stop subconverter
fi

cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter 服务
After=network.target

[Service]
Type=simple
User=root
ExecStart=/opt/subconverter/subconverter
WorkingDirectory=/opt/subconverter
Restart=always
RestartSec=5
StandardOutput=append:/var/log/subconverter.log
StandardError=append:/var/log/subconverter-error.log
Environment=PORT=25500
Environment=LISTEN=0.0.0.0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconverter
systemctl start subconverter

# 等待并检查服务状态
sleep 3
echo "检查 subconverter 服务状态..."
if systemctl is-active --quiet subconverter; then
    echo "✓ subconverter 服务运行正常"
    # 测试端口是否监听
    if netstat -tlnp | grep :25500; then
        echo "✓ subconverter 在 25500 端口监听"
        # 测试本地访问
        curl_output=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:25500 || echo "curl_failed")
        if [ "$curl_output" = "200" ]; then
            echo "✓ subconverter 本地访问正常"
        else
            echo "✗ subconverter 本地访问返回: $curl_output"
        fi
    else
        echo "✗ subconverter 未在 25500 端口监听"
    fi
else
    echo "✗ subconverter 服务未运行"
    journalctl -u subconverter --no-pager -n 20
fi

# -----------------------------
# 步骤 7：确保 Node.js
# -----------------------------
echo "[7/13] 确保 Node.js 可用"
if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
fi

# -----------------------------
# 步骤 8：安装 sub-web-api (聚合后端)
# -----------------------------
echo "[8/13] 安装 sub-web-api (聚合后端)"
rm -rf /opt/sub-web-api
git clone $SUB_WEB_API_REPO /opt/sub-web-api
cd /opt/sub-web-api

# 安装依赖
npm install

# 创建服务文件
cat >/etc/systemd/system/sub-web-api.service <<EOF
[Unit]
Description=Sub-Web-API 聚合后端服务
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/sub-web-api
ExecStart=/usr/bin/node /opt/sub-web-api/index.js
Restart=always
RestartSec=3
Environment=NODE_ENV=production
Environment=PORT=3001

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sub-web-api
systemctl restart sub-web-api

# 等待并检查服务状态
sleep 2
echo "检查 sub-web-api 服务状态..."
if systemctl is-active --quiet sub-web-api; then
    echo "✓ sub-web-api 服务运行正常"
    # 测试端口是否监听
    if netstat -tlnp | grep :3001; then
        echo "✓ sub-web-api 在 3001 端口监听"
    else
        echo "✗ sub-web-api 未在 3001 端口监听"
    fi
else
    echo "✗ sub-web-api 服务未运行"
    journalctl -u sub-web-api --no-pager -n 20
fi

# -----------------------------
# 步骤 9：构建 sub-web-modify 前端
# -----------------------------
echo "[9/13] 构建 sub-web-modify 前端"
rm -rf /opt/sub-web-modify
git clone $SUB_WEB_MODIFY_REPO /opt/sub-web-modify
cd /opt/sub-web-modify

# 修改配置文件，指向我们的 sub-web-api
cat > .env.production <<EOF
NODE_ENV=production
VUE_APP_API_BASE_URL=/subconvert/api/
VUE_APP_BACKEND_URL=https://$DOMAIN/subconvert/api/
EOF

# 修改 vue.config.js
cat > vue.config.js <<'EOF'
module.exports = {
  publicPath: '/subconvert/',
  outputDir: 'dist',
  assetsDir: 'static',
  productionSourceMap: false,
  devServer: {
    proxy: {
      '/api': {
        target: 'http://localhost:25500',
        changeOrigin: true,
        pathRewrite: {
          '^/api': '/'
        }
      }
    }
  }
}
EOF

npm install
npm run build

# 修复权限
chmod -R 755 /opt/sub-web-modify/dist

# -----------------------------
# 步骤 10：安装 S-UI
# -----------------------------
echo "[10/13] 安装 S-UI 面板"
if [ ! -d "/opt/s-ui" ]; then
    bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
fi

# -----------------------------
# 步骤 11：Web 主页 + 自动更新
# -----------------------------
echo "[11/13] 配置 Web 主页"
rm -rf /opt/web
mkdir -p /opt/web
git clone $WEB_HOME_REPO /opt/web/tmp
mv /opt/web/tmp/web /opt/web/current
rm -rf /opt/web/tmp

cat >/opt/web/update-web.sh <<'EOF'
#!/usr/bin/env bash
cd /opt/web/current && git pull
EOF
chmod +x /opt/web/update-web.sh
(crontab -l 2>/dev/null; echo "0 3 * * 0 /opt/web/update-web.sh") | crontab -

# -----------------------------
# 步骤 12：安装 AdGuard Home
# -----------------------------
echo "[12/13] 安装 AdGuard Home"
if [ ! -d "/opt/AdGuardHome" ]; then
    curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh
fi

# -----------------------------
# 步骤 13：配置 Nginx - 重点修复
# -----------------------------
echo "[13/13] 配置 Nginx"
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    # 主要主页
    location / {
        root /opt/web/current;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    # SubConverter 原始后端 (端口 25500)
    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # CORS 头部
        add_header Access-Control-Allow-Origin *;
        add_header Access-Control-Allow-Methods 'GET, POST, OPTIONS';
        add_header Access-Control-Allow-Headers 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
        
        # 处理 OPTIONS 请求
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

    # Sub-Web 前端 (你的修改版)
    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    # Sub-Web-API 聚合后端 (端口 3001)
    location /subconvert/api/ {
        proxy_pass http://127.0.0.1:3001/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # CORS 头部
        add_header Access-Control-Allow-Origin *;
        add_header Access-Control-Allow-Methods 'GET, POST, OPTIONS';
        add_header Access-Control-Allow-Headers 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
        
        # 处理 OPTIONS 请求
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

    # AdGuard Home
    location /adguard/ {
        proxy_pass http://127.0.0.1:3000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # 静态文件缓存
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        try_files \$uri \$uri/ =404;
    }
}

# HTTP 重定向到 HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
EOF

# 删除默认配置
rm -f /etc/nginx/sites-enabled/default

# 启用站点
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/

# 测试并重启 Nginx
echo "测试 Nginx 配置..."
nginx -t
if [ $? -eq 0 ]; then
    systemctl reload nginx
    echo "✓ Nginx 配置已重载"
    
    # 等待 Nginx 重启完成
    sleep 2
    
    # 测试后端访问
    echo "测试后端服务访问..."
    echo "1. 测试 subconverter (原始后端):"
    curl -I "https://$DOMAIN/sub/api/" 2>/dev/null | head -1
    
    echo "2. 测试 sub-web-api (聚合后端):"
    curl -I "https://$DOMAIN/subconvert/api/" 2>/dev/null | head -1
    
    echo "3. 测试前端页面:"
    curl -I "https://$DOMAIN/subconvert/" 2>/dev/null | head -1
else
    echo "✗ Nginx 配置测试失败，请检查错误"
fi

# -----------------------------
# 完成提示
# -----------------------------
echo "====================================="
echo "部署完成 🎉"
echo ""
echo "重要链接:"
echo "✅ Web主页: https://$DOMAIN"
echo "✅ Sub-Web 前端: https://$DOMAIN/subconvert/"
echo "✅ Sub-Web API: https://$DOMAIN/subconvert/api/"
echo "✅ SubConverter 原始 API: https://$DOMAIN/sub/api/"
echo "✅ AdGuard: https://$DOMAIN/adguard/"
echo ""
echo "后端服务状态:"
echo " - SubConverter (25500): http://localhost:25500"
echo " - Sub-Web-API (3001): http://localhost:3001"
echo ""
echo "服务管理命令:"
echo "  systemctl status subconverter"
echo "  systemctl status sub-web-api"
echo "  systemctl status nginx"
echo ""
echo "日志文件:"
echo "  /var/log/subconverter.log"
echo "  /var/log/subconverter-error.log"
echo "  /var/log/nginx/error.log"
echo ""
echo "VLESS 节点配置:"
echo " - 监听 IP: 0.0.0.0"
echo " - 监听端口: $VLESS_PORT"
echo " - 传输层: TCP / Reality（在 S-UI 中配置）"
echo "====================================="
echo ""
echo "问题排查:"
echo "1. 如果 /sub/api/ 返回 404，请检查:"
echo "   - subconverter 服务是否运行: systemctl status subconverter"
echo "   - 端口是否监听: netstat -tlnp | grep 25500"
echo "   - 日志文件: tail -f /var/log/subconverter-error.log"
echo ""
echo "2. 如果 /subconvert/api/ 有问题，请检查:"
echo "   - sub-web-api 服务: systemctl status sub-web-api"
echo "   - 端口监听: netstat -tlnp | grep 3001"
echo ""
echo "3. 如果前端无法访问，请检查:"
echo "   - Nginx 配置: nginx -t"
echo "   - 目录权限: ls -la /opt/sub-web-modify/dist/"
echo "====================================="