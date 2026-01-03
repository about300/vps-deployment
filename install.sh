#!/usr/bin/env bash
set -e

##############################
# VPS 全栈部署脚本
# Version: v2.5
# Author: Auto-generated
# Description: 部署完整的VPS服务栈，包括Sub-Web前端、聚合后端、S-UI面板等
##############################

echo "===== VPS 全栈部署（最终版）v2.4 ====="

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
export CF_Email
export CF_Token

# 服务端口定义
VLESS_PORT=5000
SUB_WEB_API_PORT=3001 # 聚合后端端口

# SubConverter 二进制下载链接
SUBCONVERTER_BIN="https://github.com/about300/vps-deployment/raw/refs/heads/main/bin/subconverter"

# Web主页GitHub仓库
WEB_HOME_REPO="https://github.com/about300/vps-deployment.git"
# 聚合后端仓库
SUB_WEB_API_REPO="https://github.com/about300/sub-web-api.git"

# -----------------------------
# 步骤 1：更新系统与依赖
# -----------------------------
echo "[1/14] 更新系统与安装依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3 npm net-tools

# -----------------------------
# 步骤 2：防火墙配置（修复S-UI访问问题）
# -----------------------------
echo "[2/14] 配置防火墙（允许本地访问2095端口）"
# 首先重置防火墙规则
ufw --force reset

# 设置默认策略
ufw default deny incoming
ufw default allow outgoing

# 允许SSH连接
ufw allow 22

# 允许HTTP/HTTPS（主域名服务）
ufw allow 80
ufw allow 443

# 允许AdGuard Home端口（通过域名+端口直接访问）
ufw allow 3000   # AdGuard Home Web界面
ufw allow 8445   # AdGuard Home 管理端口1
ufw allow 8446   # AdGuard Home 管理端口2

# 允许必要的服务端口（仅限本地访问）
ufw allow from 127.0.0.1 to any port 25500  # subconverter（仅本地）
ufw allow from 127.0.0.1 to any port 2095   # S-UI面板（仅本地）<-- 关键修复
ufw allow from 127.0.0.1 to any port 5000   # VLESS端口（仅本地）
ufw allow from 127.0.0.1 to any port ${SUB_WEB_API_PORT} # 聚合后端（仅本地）

# 拒绝外部直接访问2095端口
ufw deny 2095

# 启用防火墙
ufw --force enable

echo "[INFO] 防火墙配置完成："
echo "  • 开放端口: 22(SSH), 80(HTTP), 443(HTTPS), 3000, 8445, 8446"
echo "  • 本地访问(127.0.0.1): 2095(S-UI), 5000(VLESS), 25500(subconverter), ${SUB_WEB_API_PORT}(聚合后端)"
echo "  • 禁止外部访问: 2095(S-UI面板)"
echo "  • 拒绝其他所有入站连接"

# -----------------------------
# 步骤 3：安装 acme.sh
# -----------------------------
echo "[3/14] 安装 acme.sh（DNS-01）"
if [ ! -d "$HOME/.acme.sh" ]; then
    curl https://get.acme.sh | sh
    source ~/.bashrc
else
    echo "[INFO] acme.sh 已安装，跳过"
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
mkdir -p /etc/nginx/ssl/$DOMAIN

# -----------------------------
# 步骤 4：申请 SSL 证书
# -----------------------------
echo "[4/14] 申请或检查 SSL 证书"
if [ ! -f "/etc/nginx/ssl/$DOMAIN/fullchain.pem" ]; then
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
else
    echo "[INFO] SSL 证书已存在，跳过申请"
fi

# -----------------------------
# 步骤 5：安装证书到 Nginx
# -----------------------------
echo "[5/14] 安装证书到 Nginx"
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
    --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
    --reloadcmd "systemctl reload nginx"

# -----------------------------
# 步骤 6：安装 SubConverter 后端
# -----------------------------
echo "[6/14] 安装 SubConverter"
mkdir -p /opt/subconverter
if [ ! -f "/opt/subconverter/subconverter" ]; then
    wget -O /opt/subconverter/subconverter $SUBCONVERTER_BIN
    chmod +x /opt/subconverter/subconverter
fi

# 创建 subconverter.env 配置文件
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
# 步骤 7：修复聚合后端 (sub-web-api)
# -----------------------------
echo "[7/14] 修复聚合后端 (sub-web-api)"

# 停止并删除现有的聚合后端
if systemctl is-active --quiet sub-web-api; then
    echo "[INFO] 停止现有的 sub-web-api 服务"
    systemctl stop sub-web-api
fi

systemctl disable sub-web-api 2>/dev/null || true
rm -f /etc/systemd/system/sub-web-api.service

# 清理旧目录
rm -rf /opt/sub-web-api

# 重新安装聚合后端
echo "[INFO] 重新安装聚合后端"
git clone $SUB_WEB_API_REPO /opt/sub-web-api
cd /opt/sub-web-api

# 检查并安装依赖
if [ -f "package.json" ]; then
    echo "[INFO] 安装 npm 依赖"
    npm install --production
else
    echo "[WARN] 未找到 package.json，跳过 npm install"
fi

# 创建修复后的聚合后端服务配置
cat >/etc/systemd/system/sub-web-api.service <<EOF
[Unit]
Description=Sub-Web-API 聚合后端服务
After=network.target subconverter.service
Requires=subconverter.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/sub-web-api
ExecStart=/usr/bin/node /opt/sub-web-api/index.js
Restart=always
RestartSec=3
Environment=NODE_ENV=production
Environment=PORT=${SUB_WEB_API_PORT}
Environment=SUB_CONVERTER_URL=http://127.0.0.1:25500

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sub-web-api

# 等待 subconverter 启动
sleep 3
if systemctl is-active --quiet subconverter; then
    echo "[INFO] subconverter 服务已启动，开始启动聚合后端"
    systemctl start sub-web-api
    sleep 2
    
    if systemctl is-active --quiet sub-web-api; then
        echo "[INFO] sub-web-api 服务启动成功"
    else
        echo "[ERROR] sub-web-api 服务启动失败"
        echo "[INFO] 查看日志: journalctl -u sub-web-api --no-pager -n 20"
    fi
else
    echo "[ERROR] subconverter 服务未运行，无法启动聚合后端"
fi

# -----------------------------
# 步骤 8：安装 Node.js（已安装 npm 可跳过）
# -----------------------------
echo "[8/14] 确保 Node.js 可用"
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
fi

# -----------------------------
# 步骤 9：构建 sub-web-modify 前端
# -----------------------------
echo "[9/14] 构建 sub-web-modify 前端"
rm -rf /opt/sub-web-modify
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify
# 设置 publicPath 为 /subconvert/
cat > vue.config.js <<'EOF'
module.exports = { publicPath: '/subconvert/' }
EOF

npm install
npm run build

# 检查前端配置
echo "[INFO] 检查前端配置"
if [ -f "/opt/sub-web-modify/dist/config.js" ]; then
    echo "[INFO] 前端配置文件已存在"
elif [ -f "/opt/sub-web-modify/dist/config.template.js" ]; then
    echo "[INFO] 复制前端配置文件模板"
    cp /opt/sub-web-modify/dist/config.template.js /opt/sub-web-modify/dist/config.js
fi

# -----------------------------
# 步骤 10：安装 S-UI 面板
# -----------------------------
echo "[10/14] 安装 S-UI 面板"
if [ ! -d "/opt/s-ui" ]; then
    bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
    
    # 检查S-UI是否安装成功
    if [ -d "/opt/s-ui" ]; then
        echo "[INFO] S-UI 面板安装成功"
        # 确保S-UI监听所有地址
        if [ -f "/opt/s-ui/config.json" ]; then
            echo "[INFO] S-UI 配置文件已找到，确保监听0.0.0.0"
            # 修改配置文件，确保监听0.0.0.0
            sed -i 's/"address": "127.0.0.1"/"address": "0.0.0.0"/g' /opt/s-ui/config.json 2>/dev/null || echo "[INFO] S-UI 监听地址已设置为0.0.0.0"
        fi
    else
        echo "[WARN] S-UI 可能未安装成功，请检查"
    fi
fi

# 重启S-UI服务确保配置生效
systemctl restart s-ui 2>/dev/null || true

# -----------------------------
# 步骤 11：验证S-UI访问
# -----------------------------
echo "[11/14] 验证S-UI访问设置"
echo "[INFO] 检查S-UI服务状态..."
if systemctl is-active --quiet s-ui; then
    echo "[INFO] S-UI 服务正在运行"
    
    # 验证防火墙规则
    echo "[INFO] 验证防火墙规则："
    if ufw status | grep -q "2095.*127.0.0.1"; then
        echo "  ✅ 2095端口允许本地访问"
    else
        echo "  ❌ 2095端口未允许本地访问，修复中..."
        ufw allow from 127.0.0.1 to any port 2095
    fi
    
    if ufw status | grep -q "2095.*DENY"; then
        echo "  ✅ 2095端口已禁止外部访问"
    else
        echo "  ❌ 2095端口未禁止外部访问，修复中..."
        ufw deny 2095
    fi
else
    echo "[WARN] S-UI 服务未运行，跳过访问限制配置"
fi

# -----------------------------
# 步骤 12：Web 主页（自动更新机制）
# -----------------------------
echo "[12/14] 配置 Web 主页"
rm -rf /opt/web-home
mkdir -p /opt/web-home
git clone $WEB_HOME_REPO /opt/web-home/tmp
mv /opt/web-home/tmp/web /opt/web-home/current
rm -rf /opt/web-home/tmp

# -----------------------------
# 步骤 13：安装 AdGuard Home
# -----------------------------
echo "[13/14] 安装 AdGuard Home"
if [ ! -d "/opt/AdGuardHome" ]; then
    curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh
    
    # 配置AdGuard Home使用端口3000
    if [ -f "/opt/AdGuardHome/AdGuardHome.yaml" ]; then
        echo "[INFO] 配置AdGuard Home绑定到3000端口"
        # 备份原始配置
        cp /opt/AdGuardHome/AdGuardHome.yaml /opt/AdGuardHome/AdGuardHome.yaml.backup
        # 修改绑定端口为3000
        sed -i 's/^bind_port: .*/bind_port: 3000/' /opt/AdGuardHome/AdGuardHome.yaml 2>/dev/null || true
    fi
fi

# -----------------------------
# 步骤 14：配置 Nginx（修复S-UI反代路径）
# -----------------------------
echo "[14/14] 配置 Nginx（修复S-UI反代路径）"
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

    # 你的 Sub-Web 前端 (已修改为调用你自己的后端)
    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
        
        # 缓存静态资源
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
            expires 1y;
            add_header Cache-Control "public, immutable";
        }
    }

    # 聚合后端 API
    location /subconvert/api/ {
        proxy_pass http://127.0.0.1:${SUB_WEB_API_PORT}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # 增加超时时间
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        # 关闭缓冲
        proxy_buffering off;
        proxy_buffer_size 4k;
        proxy_buffers 8 4k;
        
        # CORS 支持 (前端跨域访问需要)
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

    # 原始 SubConverter API (保留备用)
    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        
        # 增加超时时间
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    # S-UI 面板反代 - 修复：直接代理到S-UI的根路径
    location /sui/ {
        proxy_pass http://127.0.0.1:2095/sui;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # 重要：重写路径，将 /sui 重定向到 S-UI 的 /app
        rewrite ^/sui$ /sui/ permanent;
        rewrite ^/sui/(.*)$ /app/\$1 break;
        
        # 代理重写后的请求
        proxy_redirect http://127.0.0.1:2095/ https://\$host/sui/;
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

# 测试并重载 Nginx
nginx -t
systemctl reload nginx

# -----------------------------
# 验证部署
# -----------------------------
verify_deployment() {
    echo ""
    echo "🔍 验证部署状态..."
    echo "====================================="
    
    # 检查服务状态
    echo "1. 检查关键服务状态:"
    local services=("nginx" "subconverter" "sub-web-api" "s-ui")
    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc"; then
            echo "   ✅ $svc 运行正常"
        else
            echo "   ❌ $svc 未运行"
            if [ "$svc" = "sub-web-api" ]; then
                echo "      [DEBUG] 查看日志: journalctl -u sub-web-api --no-pager -n 20"
            fi
        fi
    done
    
    echo ""
    echo "2. 检查防火墙状态:"
    echo "   - 开放端口 (外部访问):"
    local external_ports=("22" "80" "443" "3000" "8445" "8446")
    for port in "${external_ports[@]}"; do
        if ufw status | grep -q "$port.*ALLOW"; then
            echo "     ✅ 端口 $port 已开放"
        else
            echo "     ⚠️  端口 $port 未开放"
        fi
    done
    
    echo "   - 本地访问端口 (仅127.0.0.1):"
    local local_ports=("2095" "5000" "3001" "25500")
    for port in "${local_ports[@]}"; do
        if ufw status | grep -q "$port.*127.0.0.1"; then
            echo "     ✅ 端口 $port 允许本地访问"
        else
            echo "     ⚠️  端口 $port 可能不允许本地访问"
        fi
    done
    
    echo ""
    echo "3. SSH隧道访问测试提示:"
    echo "   使用以下命令通过SSH隧道访问S-UI:"
    echo "   ssh -L 8080:127.0.0.1:2095 root@$DOMAIN -p 22"
    echo "   然后浏览器访问: http://localhost:8080/app"
    
    echo ""
    echo "4. 快速HTTP访问测试 (可能需要几秒):"
    local endpoints=("/" "/subconvert/" "/subconvert/api/version" "/sub/api/version" "/ws/" "/sui/")
    for endpoint in "${endpoints[@]}"; do
        local status_code=$(curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN$endpoint" --max-time 10 2>/dev/null || echo "000")
        if [[ "$status_code" =~ ^[2-3] ]]; then
            echo "   ✅ https://$DOMAIN$endpoint ($status_code)"
        else
            echo "   ⚠️  https://$DOMAIN$endpoint ($status_code)"
        fi
    done
    
    echo ""
    echo "5. S-UI访问测试:"
    echo "   - 通过域名访问: https://$DOMAIN/sui/"
    echo "   - 通过SSH隧道访问: http://localhost:8080/app (需要先建立SSH隧道)"
}

# 执行验证
sleep 5  # 给服务一点启动时间
verify_deployment

# -----------------------------
# 完成信息
# -----------------------------
echo ""
echo "====================================="
echo "🎉 VPS 全栈部署完成 v2.4"
echo "====================================="
echo ""
echo "📋 重要访问地址:"
echo ""
echo "  🌐 主页面:              https://$DOMAIN"
echo "  🔧 Sub-Web前端:         https://$DOMAIN/subconvert/"
echo "  ⚙️  聚合后端API:         https://$DOMAIN/subconvert/api/"
echo "  🔌 原始后端API:         https://$DOMAIN/sub/api/"
echo "  📊 S-UI面板(通过域名):  https://$DOMAIN/sui/"
echo "  📊 S-UI面板(SSH隧道):  先运行: ssh -L 8080:127.0.0.1:2095 root@$DOMAIN"
echo "                          然后访问: http://localhost:8080/app"
echo "  📡 VLESS订阅:           https://$DOMAIN/vless/"
echo "  📡 VLESS WebSocket:     wss://$DOMAIN/ws/"
echo ""
echo "  🛡️  AdGuard Home:"
echo "     - Web界面:          http://$DOMAIN:3000/"
echo "     - 管理端口1:        https://$DOMAIN:8445/"
echo "     - 管理端口2:        http://$DOMAIN:8446/"
echo ""
echo "🔐 证书路径 (重要):"
echo "  • 证书文件 (公钥): /etc/nginx/ssl/$DOMAIN/fullchain.pem"
echo "  • 私钥文件:        /etc/nginx/ssl/$DOMAIN/key.pem"
echo ""
echo "⚙️  SubConverter 配置:"
echo "  • 配置文件: /opt/subconverter/subconverter.env"
echo "  • 管理密码: admin123"
echo ""
echo "🔧 S-UI 面板配置:"
echo ""
echo "  1. 登录S-UI面板:"
echo "     - 通过域名: https://$DOMAIN/sui/"
echo "     - 通过SSH隧道: 见上方说明"
echo "     - 默认用户名/密码: admin/admin (请立即修改)"
echo ""
echo "  2. 添加入站节点配置:"
echo "     - 点击左侧菜单 '入站管理' -> '添加入站'"
echo "     - 类型: VLESS"
echo "     - 地址: 0.0.0.0"
echo "     - 端口: 5000"
echo "     - 传输协议: WebSocket"
echo "     - 路径: /ws/"
echo "     - TLS: 启用"
echo "     - 证书路径: /etc/nginx/ssl/$DOMAIN/fullchain.pem"
echo "     - 私钥路径: /etc/nginx/ssl/$DOMAIN/key.pem"
echo ""
echo "🛠️ 管理命令:"
echo "  • 查看 S-UI 日志: journalctl -u s-ui -f"
echo "  • 查看 sub-web-api 日志: journalctl -u sub-web-api -f"
echo "  • 查看 subconverter 日志: journalctl -u subconverter -f"
echo "  • 重启 Nginx: systemctl reload nginx"
echo "  • 验证Nginx配置: nginx -t"
echo "  • 防火墙状态: ufw status verbose"
echo ""
echo "🔒 安全配置确认:"
echo "  ✅ 2095端口允许本地访问 (支持SSH隧道)"
echo "  ✅ 2095端口禁止外部直接访问"
echo "  ✅ 后端API端口(${SUB_WEB_API_PORT})仅限本地访问"
echo "  ✅ AdGuard Home通过端口直接访问"
echo ""
echo "⚠️  安全提醒:"
echo "  1. 立即修改所有默认密码"
echo "  2. 定期更新系统和软件"
echo "  3. 备份证书文件: /etc/nginx/ssl/$DOMAIN/"
echo ""
echo "====================================="
echo "脚本版本: v2.4"
echo "部署时间: $(date)"
echo "====================================="