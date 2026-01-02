#!/usr/bin/env bash
set -e

##############################
# VPS 全栈部署脚本
# Version: v2.2
# Author: Auto-generated
# Description: 部署完整的VPS服务栈，包括Sub-Web前端、聚合后端、S-UI面板等
##############################

echo "===== VPS 全栈部署（最终版）v2.2 ====="

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

# SubConverter 二进制下载链接
SUBCONVERTER_BIN="https://github.com/about300/vps-deployment/raw/refs/heads/main/bin/subconverter"

# Web主页GitHub仓库
WEB_HOME_REPO="https://github.com/about300/vps-deployment.git"
# 你的聚合后端仓库
SUB_WEB_API_REPO="https://github.com/about300/sub-web-api.git"

# -----------------------------
# 步骤 1：更新系统与依赖
# -----------------------------
echo "[1/14] 更新系统与安装依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3 npm net-tools

# -----------------------------
# 步骤 2：防火墙配置（仅开放指定端口）
# -----------------------------
echo "[2/14] 配置防火墙"
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
ufw allow from 127.0.0.1 to any port ${SUB_WEB_API_PORT} # 聚合后端端口（仅本地）
ufw allow from 127.0.0.1 to any port 25500  # subconverter（仅本地）
ufw allow from 127.0.0.1 to any port 2095   # S-UI面板（仅本地）
ufw allow from 127.0.0.1 to any port 5000   # VLESS端口（仅本地）

# 启用防火墙
ufw --force enable

echo "[INFO] 防火墙配置完成："
echo "  • 开放端口: 22(SSH), 80(HTTP), 443(HTTPS), 3000, 8445, 8446"
echo "  • 本地访问: 2095(S-UI), 5000(VLESS), 3001(后端API), 25500(subconverter)"
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
    
    # 检查S-UI是否安装成功
    if [ -d "/opt/s-ui" ]; then
        echo "[INFO] S-UI 面板安装成功"
        
        # 修改S-UI配置文件，如果需要的话
        if [ -f "/opt/s-ui/config.json" ]; then
            echo "[INFO] S-UI 配置文件已找到"
        fi
    else
        echo "[WARN] S-UI 可能未安装成功，请检查"
    fi
fi

# -----------------------------
# 步骤 11：配置S-UI访问限制
# -----------------------------
echo "[11/14] 配置S-UI访问限制"
# 检查S-UI服务状态
if systemctl is-active --quiet s-ui; then
    echo "[INFO] S-UI 服务正在运行"
    
    # 确认防火墙规则（S-UI仅允许本地访问）
    ufw delete allow 2095 2>/dev/null || true
    ufw allow from 127.0.0.1 to any port 2095
    ufw deny 2095
    
    echo "[INFO] S-UI 端口已配置为仅允许本地访问"
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
# 步骤 14：配置 Nginx (移除AdGuard Home反代)
# -----------------------------
echo "[14/14] 配置 Nginx (移除AdGuard Home反代)"
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

    # S-UI 面板反代
    location /sui/ {
        proxy_pass http://127.0.0.1:2095/app/;  # 注意这里加了/app
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # 重写路径 - 去掉/sui前缀
        rewrite ^/sui/(.*)$ /\$1 break;
    }

    # VLESS 订阅
    location /vless/ {
        proxy_pass http://127.0.0.1:${VLESS_PORT}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    # VLESS WebSocket 协议反代
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
            echo "     ✅ 端口 $port 仅允许本地访问"
        else
            echo "     ⚠️  端口 $port 可能允许外部访问"
        fi
    done
    
    echo ""
    echo "3. 检查证书文件:"
    if [ -f "/etc/nginx/ssl/$DOMAIN/fullchain.pem" ]; then
        echo "   ✅ 证书存在: /etc/nginx/ssl/$DOMAIN/fullchain.pem"
    else
        echo "   ❌ 证书不存在"
    fi
    
    if [ -f "/etc/nginx/ssl/$DOMAIN/key.pem" ]; then
        echo "   ✅ 私钥存在: /etc/nginx/ssl/$DOMAIN/key.pem"
    else
        echo "   ❌ 私钥不存在"
    fi
    
    echo ""
    echo "4. 快速HTTP访问测试 (可能需要几秒):"
    local endpoints=("/" "/subconvert/" "/subconvert/api/" "/sub/api/" "/ws/" "/sui/")
    for endpoint in "${endpoints[@]}"; do
        local status_code=$(curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN$endpoint" --max-time 5 2>/dev/null || echo "000")
        if [[ "$status_code" =~ ^[2-3] ]]; then
            echo "   ✅ https://$DOMAIN$endpoint ($status_code)"
        else
            echo "   ⚠️  https://$DOMAIN$endpoint ($status_code)"
        fi
    done
    
    echo ""
    echo "5. AdGuard Home端口测试:"
    if curl -s -o /dev/null -w "%{http_code}" "http://$DOMAIN:3000/" --max-time 5 2>/dev/null | grep -q "^[2-3]"; then
        echo "   ✅ AdGuard Home 3000端口可访问"
    else
        echo "   ⚠️  AdGuard Home 3000端口不可访问"
    fi
    
    echo ""
    echo "6. 直接访问后端API测试 (应该失败):"
    if curl -s -o /dev/null -w "%{http_code}" "http://$DOMAIN:${SUB_WEB_API_PORT}/" --max-time 5 2>/dev/null | grep -q "000\|4[0-9][0-9]\|5[0-9][0-9]"; then
        echo "   ✅ 后端API端口(${SUB_WEB_API_PORT})被阻止外部访问 (安全)"
    else
        echo "   ⚠️  后端API端口(${SUB_WEB_API_PORT})可能未被阻止"
    fi
}

# 执行验证
sleep 3  # 给服务一点启动时间
verify_deployment

# -----------------------------
# 完成信息
# -----------------------------
echo ""
echo "====================================="
echo "🎉 VPS 全栈部署完成 v2.2"
echo "====================================="
echo ""
echo "📋 重要访问地址:"
echo ""
echo "  🌐 主页面:              https://$DOMAIN"
echo "  🔧 Sub-Web前端:         https://$DOMAIN/subconvert/"
echo "  ⚙️  聚合后端API:         https://$DOMAIN/subconvert/api/ (仅限前端调用)"
echo "  🔌 原始后端API:         https://$DOMAIN/sub/api/"
echo "  📊 S-UI面板:            https://$DOMAIN/sui/"
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
echo "🔧 S-UI 面板配置:"
echo ""
echo "  1. 登录S-UI面板:"
echo "     - 通过域名: https://$DOMAIN/sui/"
echo "     - 本地访问: http://127.0.0.1:2095/app (需SSH隧道)"
echo "     - 默认用户名/密码: admin/admin (请立即修改)"
echo ""
echo "  2. SSH隧道访问本地S-UI (安全推荐):"
echo "     ssh -L 8080:127.0.0.1:2095 user@$DOMAIN"
echo "     然后浏览器访问: http://localhost:8080/app"
echo ""
echo "  3. 添加入站节点配置:"
echo "     - 点击左侧菜单 '入站管理' -> '添加入站'"
echo "     - 类型: VLESS"
echo "     - 地址: 0.0.0.0"
echo "     - 端口: 5000"
echo ""
echo "  4. 传输设置 (关键):"
echo "     - 启用传输: 选择 WebSocket"
echo "     - 路径: /ws/"
echo ""
echo "  5. TLS设置:"
echo "     - 启用 TLS"
echo "     - 证书路径: /etc/nginx/ssl/$DOMAIN/fullchain.pem"
echo "     - 私钥路径: /etc/nginx/ssl/$DOMAIN/key.pem"
echo ""
echo "  6. 创建用户获取UUID"
echo "  7. 客户端连接信息:"
echo "     - 服务器: $DOMAIN"
echo "     - 端口: 443"
echo "     - UUID: 在S-UI中创建的用户UUID"
echo "     - 传输协议: WebSocket"
echo "     - 路径: /ws/"
echo "     - TLS: 启用"
echo "     - SNI: $DOMAIN"
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
echo "  ✅ 2095端口已禁止外部访问，仅允许本地和Nginx反代"
echo "  ✅ 后端API端口(${SUB_WEB_API_PORT})已禁止外部访问，仅限前端调用"
echo "  ✅ AdGuard Home直接通过端口3000,8445,8446访问"
echo "  ✅ 所有Web服务通过Nginx 443端口统一访问"
echo ""
echo "🌐 访问策略总结:"
echo "  外部可访问:"
echo "    • HTTPS (443): 所有Web服务"
echo "    • SSH (22): 服务器管理"
echo "    • AdGuard Home: 3000, 8445, 8446端口"
echo ""
echo "  仅本地访问:"
echo "    • S-UI面板: 2095端口"
echo "    • VLESS服务: 5000端口"
echo "    • 聚合后端: ${SUB_WEB_API_PORT}端口"
echo "    • SubConverter: 25500端口"
echo ""
echo "⚠️  安全提醒:"
echo "  1. 立即修改S-UI默认密码和AdGuard Home密码"
echo "  2. 定期更新系统和软件"
echo "  3. 备份证书文件: /etc/nginx/ssl/$DOMAIN/"
echo "  4. 建议设置SSH密钥登录，禁用密码登录"
echo "  5. AdGuard Home首次访问请设置管理员密码"
echo ""
echo "====================================="
echo "脚本版本: v2.2"
echo "部署时间: $(date)"
echo "====================================="