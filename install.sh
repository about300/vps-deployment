#!/usr/bin/env bash
set -e

##############################
# VPS 全栈部署脚本
# Version: v2.3
# Author: Auto-generated
# Description: 部署完整的VPS服务栈，包括Sub-Web前端、聚合后端、S-UI面板等
##############################

echo "===== VPS 全栈部署（最终版）v2.3 ====="

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
SUB_WEB_API_PORT=3001 # 你自己的聚合后端端口

# 证书路径定义
NGINX_SSL_DIR="/etc/nginx/ssl/$DOMAIN"
ROOT_CERTS_DIR="/root/certs/$DOMAIN"

# SubConverter 二进制下载链接
SUBCONVERTER_BIN="https://github.com/about300/vps-deployment/raw/refs/heads/main/bin/subconverter"

# Web主页GitHub仓库
WEB_HOME_REPO="https://github.com/about300/vps-deployment.git"
# 你的聚合后端仓库
SUB_WEB_API_REPO="https://github.com/about300/sub-web-api.git"

# -----------------------------
# 证书同步函数
# -----------------------------
sync_certificates_to_root() {
    echo "[证书同步] 将证书同步到 root 目录..."
    mkdir -p "$ROOT_CERTS_DIR"
    
    # 复制证书文件
    if [ -f "$NGINX_SSL_DIR/fullchain.pem" ]; then
        cp "$NGINX_SSL_DIR/fullchain.pem" "$ROOT_CERTS_DIR/fullchain.pem"
        cp "$NGINX_SSL_DIR/key.pem" "$ROOT_CERTS_DIR/key.pem"
        cp "$NGINX_SSL_DIR/ca.cer" "$ROOT_CERTS_DIR/ca.cer" 2>/dev/null || true
        
        # 设置安全权限
        chmod 600 "$ROOT_CERTS_DIR/key.pem"
        chmod 644 "$ROOT_CERTS_DIR/fullchain.pem"
        
        echo "✅ 证书已同步到: $ROOT_CERTS_DIR"
    else
        echo "⚠️  源证书不存在，跳过同步"
    fi
}

# -----------------------------
# 步骤 1：更新系统与依赖
# -----------------------------
echo "[1/14] 更新系统与安装依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3 npm net-tools

# -----------------------------
# 步骤 2：防火墙配置
# -----------------------------
echo "[2/14] 配置防火墙"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000   # AdGuard Home反代端口
ufw allow ${SUB_WEB_API_PORT} # 你的聚合后端端口
ufw allow 8445
ufw allow 8446
ufw allow 25500
ufw allow 2095   # S-UI面板端口
ufw allow 5000   # VLESS端口
ufw --force enable

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
mkdir -p "$NGINX_SSL_DIR"

# -----------------------------
# 步骤 4：申请 SSL 证书
# -----------------------------
echo "[4/14] 申请或检查 SSL 证书"
if [ ! -f "$NGINX_SSL_DIR/fullchain.pem" ]; then
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
else
    echo "[INFO] SSL 证书已存在，跳过申请"
fi

# -----------------------------
# 步骤 5：安装证书到 Nginx 并同步到 root
# -----------------------------
echo "[5/14] 安装证书到 Nginx 并同步到 root 目录"
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file "$NGINX_SSL_DIR/key.pem" \
    --fullchain-file "$NGINX_SSL_DIR/fullchain.pem" \
    --reloadcmd "systemctl reload nginx && sync_certificates_to_root"

# 初始同步证书到 root 目录
sync_certificates_to_root

# -----------------------------
# 步骤 6：安装 SubConverter 后端
# -----------------------------
echo "[6/14] 安装 SubConverter"
mkdir -p /opt/subconverter
if [ ! -f "/opt/subconverter/subconverter" ]; then
    wget -O /opt/subconverter/subconverter $SUBCONVERTER_BIN
    chmod +x /opt/subconverter/subconverter
fi

# 创建 systemd 服务
cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter 服务
After=network.target

[Service]
ExecStart=/opt/subconverter/subconverter
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

# -----------------------------
# 步骤 7：安装你自己的聚合后端 (sub-web-api)
# -----------------------------
echo "[7/14] 安装你自己的聚合后端 (sub-web-api)"
if [ -d "/opt/sub-web-api" ]; then
    echo "[INFO] 检测到已存在的 sub-web-api，停止服务..."
    systemctl stop sub-web-api 2>/dev/null || true
fi

rm -rf /opt/sub-web-api
git clone $SUB_WEB_API_REPO /opt/sub-web-api
cd /opt/sub-web-api

# 检查并安装依赖
if [ -f "package.json" ]; then
    npm install
else
    echo "[WARN] 未找到 package.json，跳过 npm install"
fi

# 创建 systemd 服务
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
Environment=PORT=${SUB_WEB_API_PORT}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sub-web-api
systemctl start sub-web-api

# 等待服务启动
sleep 3
if systemctl is-active --quiet sub-web-api; then
    echo "[INFO] sub-web-api 服务启动成功"
else
    echo "[WARN] sub-web-api 服务可能启动失败，请检查日志: journalctl -u sub-web-api"
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

# -----------------------------
# 步骤 10：安装 S-UI 面板
# -----------------------------
echo "[10/14] 安装 S-UI 面板"
if [ ! -d "/opt/s-ui" ]; then
    bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
else
    echo "[INFO] S-UI 已安装，跳过"
fi

# -----------------------------
# 步骤 11：Web 主页（自动更新机制）
# -----------------------------
echo "[11/14] 配置 Web 主页"
rm -rf /opt/web-home
mkdir -p /opt/web-home
git clone $WEB_HOME_REPO /opt/web-home/tmp
mv /opt/web-home/tmp/web /opt/web-home/current
rm -rf /opt/web-home/tmp

# -----------------------------
# 步骤 12：安装 AdGuard Home
# -----------------------------
echo "[12/14] 安装 AdGuard Home"
if [ ! -d "/opt/AdGuardHome" ]; then
    curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh
fi

# -----------------------------
# 步骤 13：配置 Nginx (关键：添加VLESS WebSocket反代)
# -----------------------------
echo "[13/14] 配置 Nginx (添加VLESS WebSocket反代)"
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     $NGINX_SSL_DIR/fullchain.pem;
    ssl_certificate_key $NGINX_SSL_DIR/key.pem;

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

    # 你自己的聚合后端 API (关键配置)
    location /subconvert/api/ {
        proxy_pass http://127.0.0.1:${SUB_WEB_API_PORT}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
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
    }

    # S-UI 面板反代 (方便通过域名访问)
    location /sui/ {
        proxy_pass http://127.0.0.1:2095/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # VLESS 订阅链接
    location /vless/ {
        proxy_pass http://127.0.0.1:${VLESS_PORT}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    # VLESS WebSocket 协议反代 (关键：新增)
    location /ws/ {
        proxy_pass http://127.0.0.1:${VLESS_PORT}/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # 重要：确保连接保持
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        
        # 关闭缓冲
        proxy_buffering off;
        
        # 增加缓冲区大小
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
    }

    # AdGuard Home 反代
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
# 步骤 14：验证部署
# -----------------------------
echo "[14/14] 验证部署"
verify_deployment() {
    echo ""
    echo "🔍 验证部署状态..."
    echo "====================================="
    
    # 检查服务状态
    echo "1. 检查关键服务状态:"
    local services=("nginx" "subconverter" "sub-web-api")
    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc"; then
            echo "   ✅ $svc 运行正常"
        else
            echo "   ❌ $svc 未运行"
        fi
    done
    
    echo ""
    echo "2. 检查端口监听:"
    local ports=("80" "443" "25500" "${SUB_WEB_API_PORT}" "3000" "5000")
    for port in "${ports[@]}"; do
        if netstat -tln | grep -q ":$port "; then
            echo "   ✅ 端口 $port 已监听"
        else
            echo "   ⚠️  端口 $port 未监听"
        fi
    done
    
    echo ""
    echo "3. 检查证书文件:"
    local cert_paths=("$NGINX_SSL_DIR/fullchain.pem" "$ROOT_CERTS_DIR/fullchain.pem")
    for cert_path in "${cert_paths[@]}"; do
        if [ -f "$cert_path" ]; then
            echo "   ✅ $(basename "$cert_path") 存在 ($cert_path)"
        else
            echo "   ❌ $(basename "$cert_path") 不存在"
        fi
    done
    
    echo ""
    echo "4. 快速HTTP访问测试 (可能需要几秒):"
    local endpoints=("/" "/subconvert/" "/subconvert/api/" "/sub/api/" "/ws/")
    for endpoint in "${endpoints[@]}"; do
        local status_code=$(curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN$endpoint" --max-time 5 2>/dev/null || echo "000")
        if [[ "$status_code" =~ ^[2-3] ]]; then
            echo "   ✅ https://$DOMAIN$endpoint ($status_code)"
        else
            echo "   ⚠️  https://$DOMAIN$endpoint ($status_code)"
        fi
    done
}

# 执行验证
sleep 2  # 给服务一点启动时间
verify_deployment

# -----------------------------
# 完成信息与配置提示
# -----------------------------
echo ""
echo "====================================="
echo "🎉 VPS 全栈部署完成 v2.3"
echo "====================================="
echo ""
echo "📋 重要访问地址:"
echo ""
echo "  🌐 主页面:              https://$DOMAIN"
echo "  🔧 Sub-Web前端:         https://$DOMAIN/subconvert/"
echo "  ⚙️  聚合后端API:         https://$DOMAIN/subconvert/api/"
echo "  🔌 原始后端API:         https://$DOMAIN/sub/api/"
echo "  🛡️  AdGuard Home:       https://$DOMAIN/adguard/"
echo "  📊 S-UI面板(Web):       https://$DOMAIN/sui/"
echo "  📊 S-UI面板(直连):      http://127.0.0.1:2095 或 http://服务器IP:2095"
echo "  📡 VLESS订阅:           https://$DOMAIN/vless/"
echo "  📡 VLESS WebSocket:     wss://$DOMAIN/ws/"
echo ""
echo "🔐 证书路径:"
echo "  • Nginx使用: $NGINX_SSL_DIR/"
echo "  • 其他服务: $ROOT_CERTS_DIR/ (自动同步)"
echo ""
echo "🔧 S-UI 面板配置步骤:"
echo ""
echo "  1. 登录S-UI面板:"
echo "     - 地址: http://127.0.0.1:2095 或 https://$DOMAIN/sui/"
echo "     - 默认用户名/密码: admin/admin (请立即修改)"
echo ""
echo "  2. 添加入站节点配置:"
echo "     - 点击左侧菜单 '入站管理' -> '添加入站'"
echo "     - 类型: VLESS"
echo "     - 地址: 0.0.0.0"
echo "     - 端口: $VLESS_PORT (5000)"
echo "     - 协议: VLESS"
echo ""
echo "  3. 配置传输设置 (关键步骤):"
echo "     - 点击 '启用传输'"
echo "     - 传输协议: WebSocket"
echo "     - 路径: /ws/"
echo "     - 其它选项保持默认"
echo ""
echo "  4. 配置TLS设置:"
echo "     - 点击 'TLS'"
echo "     - TLS类型: tls"
echo "     - 证书文件: /root/certs/$DOMAIN/fullchain.pem"
echo "     - 私钥文件: /root/certs/$DOMAIN/key.pem"
echo ""
echo "  5. 创建用户:"
echo "     - 点击 '用户管理'"
echo "     - 添加新用户，获取UUID"
echo "     - 保存所有设置"
echo ""
echo "  6. 客户端配置示例 (v2ray/clash):"
echo "     - 服务器: $DOMAIN"
echo "     - 端口: 443"
echo "     - UUID: 在S-UI中创建的用户UUID"
echo "     - 传输协议: WebSocket"
echo "     - 路径: /ws/"
echo "     - TLS: 启用"
echo "     - SNI: $DOMAIN"
echo ""
echo "  7. 订阅链接获取:"
echo "     - 在S-UI面板中生成订阅链接"
echo "     - 或使用: https://$DOMAIN/vless/"
echo ""
echo "🛠️ 管理命令:"
echo "  • 查看 S-UI 日志: journalctl -u s-ui -f"
echo "  • 查看 sub-web-api 日志: journalctl -u sub-web-api -f"
echo "  • 查看 subconverter 日志: journalctl -u subconverter -f"
echo "  • 重启 Nginx: systemctl reload nginx"
echo "  • 验证Nginx配置: nginx -t"
echo "  • 重启所有服务: systemctl restart nginx subconverter sub-web-api"
echo ""
echo "⚠️  重要安全提醒:"
echo "  1. 立即修改S-UI默认密码和AdGuard Home密码"
echo "  2. 定期更新系统和软件: apt update && apt upgrade"
echo "  3. 检查防火墙状态: ufw status verbose"
echo "  4. 备份重要配置和证书"
echo ""
echo "🔗 相关路径:"
echo "  • Nginx配置: /etc/nginx/sites-available/$DOMAIN"
echo "  • SSL证书(Nginx): $NGINX_SSL_DIR/"
echo "  • SSL证书(服务用): $ROOT_CERTS_DIR/ (自动同步)"
echo "  • 前端文件: /opt/sub-web-modify/dist/"
echo "  • 聚合后端: /opt/sub-web-api/"
echo "  • S-UI配置目录: /opt/s-ui/"
echo ""
echo "====================================="
echo "部署时间: $(date)"
echo "脚本版本: v2.3"
echo "====================================="