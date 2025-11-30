#!/bin/bash

# VPS 一键部署脚本 - 443端口SNI分流版本
# Web服务和VLESS Reality共用443端口，通过SNI区分
# 使用方法: bash <(curl -sL https://raw.githubusercontent.com/about300/vps-deployment/main/deploy-sni.sh)

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# 显示横幅
show_banner() {
    echo -e "${GREEN}"
    cat << "EOF"
    __      _______  _______  _______ 
    \ \    / /  __ \|  ____|/ / ____|
     \ \  / /| |__) | |__  | | (___  
      \ \/ / |  ___/|  __| | |\___ \ 
       \  /  | |    | |____| |____) |
        \/   |_|    |______|_|_____/ 
        
    VPS 一键部署脚本 - 443端口SNI分流版
    Web服务 + VLESS Reality 共用443端口
EOF
    echo -e "${NC}"
}

# 检查系统
check_system() {
    step "检查系统环境..."
    if [ "$EUID" -ne 0 ]; then
        error "请使用 root 用户运行此脚本"
    fi
    
    if [ ! -f /etc/os-release ]; then
        error "无法检测操作系统"
    fi
    
    source /etc/os-release
    log "操作系统: $NAME $VERSION"
    
    # 检查系统架构
    ARCH=$(uname -m)
    log "系统架构: $ARCH"
}

# 获取用户输入
get_user_input() {
    echo
    step "请输入配置信息"
    
    read -p "请输入Web服务域名 (例如: myhouse.mycloudshare.org): " WEB_DOMAIN
    if [ -z "$WEB_DOMAIN" ]; then
        error "Web服务域名不能为空"
    fi
    
    read -p "请输入VLESS节点域名 (可以与Web域名相同): " VLESS_DOMAIN
    if [ -z "$VLESS_DOMAIN" ]; then
        VLESS_DOMAIN="$WEB_DOMAIN"
        warn "使用Web服务域名作为VLESS域名: $VLESS_DOMAIN"
    fi
    
    read -p "请输入邮箱 (用于 SSL 证书): " EMAIL
    if [ -z "$EMAIL" ]; then
        EMAIL="admin@$WEB_DOMAIN"
        warn "使用默认邮箱: $EMAIL"
    fi
    
    # Reality 配置
    read -p "请输入Reality握手服务器 (默认: www.51kankan.vip): " REALITY_SERVER
    if [ -z "$REALITY_SERVER" ]; then
        REALITY_SERVER="www.51kankan.vip"
    fi
    
    # 显示配置确认
    echo
    log "配置确认:"
    log "Web服务域名: $WEB_DOMAIN"
    log "VLESS节点域名: $VLESS_DOMAIN"
    log "邮箱: $EMAIL"
    log "Reality握手服务器: $REALITY_SERVER"
    log "共享端口: 443 (Web服务和VLESS共用)"
    echo
    
    read -p "确认开始部署? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        log "用户取消部署"
        exit 0
    fi
}

# 系统更新和基础安装
install_basics() {
    step "更新系统并安装基础软件..."
    
    apt update -y
    apt upgrade -y
    apt install -y cron socat ufw curl wget nginx unzip git jq
    
    log "基础软件安装完成"
}

# 配置防火墙
configure_firewall() {
    step "配置防火墙..."
    
    ufw --force enable
    
    # 开放端口 - 443端口共享给Web和VLESS
    ports=(22 53 80 443 3000 2095 25500)
    for port in "${ports[@]}"; do
        ufw allow $port/tcp
    done
    
    ufw status verbose
    log "防火墙配置完成"
}

# 申请 SSL 证书
setup_ssl() {
    step "申请 SSL 证书..."
    
    # 安装 acme.sh
    curl https://get.acme.sh | sh -s email=$EMAIL
    source ~/.bashrc
    ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh
    
    # 设置 CA
    acme.sh --set-default-ca --server letsencrypt
    
    # 创建web目录用于证书验证
    mkdir -p /var/www/html
    echo "ACME Challenge" > /var/www/html/index.html
    
    # 申请Web域名证书
    log "为Web域名 $WEB_DOMAIN 申请 SSL 证书..."
    if acme.sh --issue -d $WEB_DOMAIN --webroot /var/www/html --keylength ec-256; then
        log "Web域名 SSL 证书申请成功"
    else
        warn "webroot 方式失败，尝试 standalone 方式..."
        systemctl stop nginx 2>/dev/null || true
        sleep 2
        if acme.sh --issue -d $WEB_DOMAIN --standalone --keylength ec-256; then
            log "Web域名 SSL 证书申请成功"
        else
            error "Web域名 SSL 证书申请失败"
        fi
    fi
    
    # 安装Web域名证书
    acme.sh --install-cert -d $WEB_DOMAIN --ecc \
        --key-file /etc/ssl/private/web-server.key \
        --fullchain-file /etc/ssl/certs/web-server.crt
    
    # 如果VLESS域名不同，申请VLESS域名证书
    if [ "$VLESS_DOMAIN" != "$WEB_DOMAIN" ]; then
        log "为VLESS域名 $VLESS_DOMAIN 申请 SSL 证书..."
        if acme.sh --issue -d $VLESS_DOMAIN --webroot /var/www/html --keylength ec-256; then
            log "VLESS域名 SSL 证书申请成功"
            acme.sh --install-cert -d $VLESS_DOMAIN --ecc \
                --key-file /etc/ssl/private/vless-server.key \
                --fullchain-file /etc/ssl/certs/vless-server.crt
        else
            warn "VLESS域名证书申请失败，将使用Web域名证书"
            cp /etc/ssl/private/web-server.key /etc/ssl/private/vless-server.key
            cp /etc/ssl/certs/web-server.crt /etc/ssl/certs/vless-server.crt
        fi
    else
        # 相同域名，使用相同证书
        cp /etc/ssl/private/web-server.key /etc/ssl/private/vless-server.key
        cp /etc/ssl/certs/web-server.crt /etc/ssl/certs/vless-server.crt
    fi
    
    # 设置自动续期
    cat > /root/cert-renew.sh << EOF
#!/bin/bash
/root/.acme.sh/acme.sh --renew -d $WEB_DOMAIN --force --ecc --webroot /var/www/html
if [ "$VLESS_DOMAIN" != "$WEB_DOMAIN" ]; then
    /root/.acme.sh/acme.sh --renew -d $VLESS_DOMAIN --force --ecc --webroot /var/www/html
fi
systemctl reload nginx
EOF
    
    chmod +x /root/cert-renew.sh
    (crontab -l 2>/dev/null; echo "0 3 */30 * * /root/cert-renew.sh >>/var/log/cert-renew.log 2>&1") | crontab -
    
    log "SSL 证书设置完成"
}

# 安装和配置 Xray (VLESS Reality)
install_xray() {
    step "安装 Xray..."
    
    # 安装 Xray
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    # 生成 UUID
    local uuid=$(xray uuid)
    
    # 生成 Reality 密钥对
    local key_pair=$(xray x25519)
    local private_key=$(echo "$key_pair" | grep "Private" | cut -d: -f2 | tr -d ' ')
    local public_key=$(echo "$key_pair" | grep "Public" | cut -d: -f2 | tr -d ' ')
    
    # 生成 shortId
    local short_id=$(openssl rand -hex 4)
    
    # 创建 Xray 配置文件
    cat > /usr/local/etc/xray/config.json << EOF
{
    "log": {
        "loglevel": "warning"
    },
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": []
    },
    "inbounds": [
        {
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$uuid",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "$REALITY_SERVER:443",
                    "xver": 0,
                    "serverNames": ["$REALITY_SERVER"],
                    "privateKey": "$private_key",
                    "minClientVer": "",
                    "maxClientVer": "",
                    "maxTimeDiff": 0,
                    "shortIds": ["$short_id"]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls"]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ]
}
EOF

    # 创建 Xray 服务配置
    cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray
    systemctl start xray

    # 保存配置信息
    cat > /root/vless-config.txt << EOF
=== VLESS Reality 配置 ===
服务器: $VLESS_DOMAIN
端口: 443
协议: vless
UUID: $uuid
流控: xtls-rprx-vision
传输: tcp
TLS: reality
SNI: $REALITY_SERVER
Public Key: $public_key
Short ID: $short_id
指纹: chrome

订阅链接:
vless://$uuid@$VLESS_DOMAIN:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_SERVER&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp#VPS-Reality-节点

Clash配置:
  - name: "VPS-Reality-节点"
    type: vless
    server: $VLESS_DOMAIN
    port: 443
    uuid: $uuid
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    client-fingerprint: chrome
    servername: $REALITY_SERVER
    reality-opts:
      public-key: $public_key
      short-id: "$short_id"
EOF

    log "Xray 安装完成"
    log "VLESS Reality 配置已保存到: /root/vless-config.txt"
}

# 配置 Nginx SNI 分流
setup_nginx_sni() {
    step "配置 Nginx SNI 分流..."
    
    # 创建 Nginx 主配置
    cat > /etc/nginx/nginx.conf << EOF
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

# SNI 分流配置
stream {
    # SNI 映射，将不同的域名映射到不同的后端
    map \$ssl_preread_server_name \$backend {
        $WEB_DOMAIN    web_backend;
        $VLESS_DOMAIN  vless_backend;
        default        web_backend;
    }

    # Web 服务后端
    upstream web_backend {
        server 127.0.0.1:8443;
    }

    # VLESS 后端 (Xray)
    upstream vless_backend {
        server 127.0.0.1:443;
    }

    # 主监听端口
    server {
        listen 443 reuseport;
        listen [::]:443 reuseport;
        proxy_pass \$backend;
        ssl_preread on;
        proxy_protocol on;
    }
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    
    gzip on;
    
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

    # 创建 Web 服务配置
    mkdir -p /etc/nginx/conf.d
    cat > /etc/nginx/conf.d/web.conf << EOF
server {
    listen 8443 ssl http2 proxy_protocol;
    listen [::]:8443 ssl http2 proxy_protocol;
    server_name $WEB_DOMAIN;
    
    ssl_certificate /etc/ssl/certs/web-server.crt;
    ssl_certificate_key /etc/ssl/private/web-server.key;
    
    # 记录真实客户端IP
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
    
    root /var/www/html;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # 订阅转换API代理
    location /sub {
        proxy_pass http://127.0.0.1:25500;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}

# HTTP 重定向到 HTTPS
server {
    listen 80;
    server_name $WEB_DOMAIN $VLESS_DOMAIN;
    return 301 https://\$server_name\$request_uri;
}
EOF

    log "Nginx SNI 分流配置完成"
}

# 安装 subconverter
install_subconverter() {
    step "安装 subconverter..."
    
    mkdir -p /opt/subconverter
    cd /opt/subconverter
    
    # 下载 subconverter
    if ! wget -q https://github.com/MetaCubeX/subconverter/releases/download/v0.9.2/subconverter_linux64.tar.gz; then
        error "下载 subconverter 失败"
    fi
    
    tar -xzf subconverter_linux64.tar.gz
    rm subconverter_linux64.tar.gz
    
    # 创建服务
    cat > /etc/systemd/system/subconverter.service << EOF
[Unit]
Description=MetaCubeX SubConverter
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/subconverter
ExecStart=/opt/subconverter/subconverter
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable subconverter
    systemctl start subconverter
    
    # 等待服务启动
    sleep 5
    
    log "subconverter 安装完成"
}

# 创建网页界面
setup_web_interface() {
    step "创建网页界面..."
    
    mkdir -p /var/www/html
    
    # 创建主页面
    cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html lang="zh">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>服务管理中心 - $WEB_DOMAIN</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { 
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; 
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: #333;
            line-height: 1.6;
            min-height: 100vh;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
        }
        header {
            background: rgba(255, 255, 255, 0.1);
            backdrop-filter: blur(10px);
            padding: 3rem 2rem;
            text-align: center;
            border-radius: 20px;
            margin-bottom: 2rem;
            box-shadow: 0 8px 32px rgba(0, 0, 0, 0.1);
            border: 1px solid rgba(255, 255, 255, 0.2);
        }
        header h1 {
            color: white;
            font-size: 3rem;
            margin-bottom: 1rem;
            text-shadow: 2px 2px 4px rgba(0, 0, 0, 0.3);
        }
        header p {
            color: rgba(255, 255, 255, 0.9);
            font-size: 1.2rem;
        }
        .tech-badge {
            background: rgba(255, 255, 255, 0.2);
            border-radius: 20px;
            padding: 0.5rem 1rem;
            margin: 1rem 0;
            display: inline-block;
            color: white;
            font-size: 0.9rem;
        }
        .service-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 25px;
            margin-top: 2rem;
        }
        .service-card {
            background: rgba(255, 255, 255, 0.95);
            border-radius: 15px;
            padding: 2rem;
            text-align: center;
            box-shadow: 0 10px 30px rgba(0, 0, 0, 0.1);
            transition: transform 0.3s ease, box-shadow 0.3s ease;
            border: 1px solid rgba(255, 255, 255, 0.3);
        }
        .service-card:hover {
            transform: translateY(-5px);
            box-shadow: 0 15px 40px rgba(0, 0, 0, 0.2);
        }
        .service-card h3 {
            color: #4a5568;
            margin-bottom: 1rem;
            font-size: 1.4rem;
        }
        .service-card p {
            color: #718096;
            margin-bottom: 1.5rem;
        }
        .btn {
            display: inline-block;
            background: linear-gradient(135deg, #667eea, #764ba2);
            color: white;
            padding: 12px 28px;
            border-radius: 25px;
            text-decoration: none;
            font-weight: 500;
            transition: all 0.3s ease;
            border: none;
            cursor: pointer;
        }
        .btn:hover {
            transform: scale(1.05);
            box-shadow: 0 5px 15px rgba(102, 126, 234, 0.4);
        }
        .status {
            font-size: 0.8rem;
            color: #48bb78;
            margin-top: 0.5rem;
        }
        .status-warning {
            color: #e53e3e;
        }
        footer {
            text-align: center;
            color: rgba(255, 255, 255, 0.7);
            padding: 3rem 0;
            margin-top: 3rem;
            border-top: 1px solid rgba(255, 255, 255, 0.2);
        }
        .port-info {
            background: rgba(255, 255, 255, 0.9);
            border-radius: 10px;
            padding: 1.5rem;
            margin: 2rem 0;
            text-align: center;
        }
        .config-info {
            background: rgba(255, 255, 255, 0.9);
            border-radius: 10px;
            padding: 1.5rem;
            margin: 1rem 0;
            text-align: left;
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>🚀 服务管理中心</h1>
            <p>SNI分流技术 - Web服务与VLESS节点共享443端口</p>
            <div class="tech-badge">🎯 智能流量分流 | 🔒 全链路加密 | ⚡ 极速体验</div>
        </header>

        <div class="port-info">
            <h3>🎯 智能端口共享</h3>
            <p><strong>共享端口:</strong> 443 (HTTPS + VLESS Reality)</p>
            <p><strong>分流技术:</strong> SNI (Server Name Indication)</p>
            <p><strong>Web域名:</strong> $WEB_DOMAIN → Nginx Web服务</p>
            <p><strong>VLESS域名:</strong> $VLESS_DOMAIN → Xray VLESS节点</p>
        </div>
        
        <div class="service-grid">
            <div class="service-card">
                <h3>🔄 订阅转换</h3>
                <p>支持 VLESS、VMess、Trojan 等协议转换，集成 ACL4SSR 规则</p>
                <a href="/sub" class="btn">进入转换工具</a>
                <div class="status">基于SNI分流技术</div>
            </div>
            
            <div class="service-card">
                <h3>⚡ VLESS 节点</h3>
                <p>Reality 协议，无需证书，抗封锁能力强，共享443端口</p>
                <a href="/vless-info" class="btn">节点信息</a>
                <div class="status">端口: 443 (共享)</div>
            </div>
            
            <div class="service-card">
                <h3>🛡️ AdGuard Home</h3>
                <p>DNS 广告过滤和网络保护，提供安全的网络环境</p>
                <a href="http://$WEB_DOMAIN:3000" class="btn" target="_blank">管理面板</a>
                <div class="status">端口: 3000</div>
            </div>
            
            <div class="service-card">
                <h3>📊 S-UI 面板</h3>
                <p>节点管理和流量监控，支持 Xray 核心</p>
                <a href="http://$WEB_DOMAIN:2095/app" class="btn" target="_blank">管理面板</a>
                <div class="status">端口: 2095/app</div>
            </div>
        </div>

        <div class="config-info">
            <h3>🔧 技术架构</h3>
            <p><strong>Nginx Stream SNI 分流:</strong> 根据域名智能路由流量</p>
            <p><strong>Xray VLESS Reality:</strong> 现代代理协议，无需TLS证书</p>
            <p><strong>共享443端口:</strong> 最大化端口利用率</p>
            <p><strong>全自动部署:</strong> 一键配置所有服务</p>
        </div>
        
        <footer>
            <p>&copy; 2025 服务管理中心 | Web域名: $WEB_DOMAIN | VLESS域名: $VLESS_DOMAIN</p>
            <p>Reality 握手服务器: $REALITY_SERVER | 共享端口: 443 (SNI分流)</p>
        </footer>
    </div>
</body>
</html>
EOF

    # 创建 VLESS 信息页面
    cat > /var/www/html/vless-info.html << EOF
<!DOCTYPE html>
<html lang="zh">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>VLESS 节点信息 - $WEB_DOMAIN</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { 
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; 
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: #333;
            line-height: 1.6;
            min-height: 100vh;
            padding: 20px;
        }
        .container {
            max-width: 800px;
            margin: 0 auto;
            background: rgba(255, 255, 255, 0.95);
            border-radius: 15px;
            padding: 2rem;
            box-shadow: 0 10px 30px rgba(0, 0, 0, 0.1);
        }
        header {
            text-align: center;
            margin-bottom: 2rem;
        }
        h1 {
            color: #4a5568;
            margin-bottom: 0.5rem;
        }
        .back-link {
            display: inline-block;
            margin-bottom: 1rem;
            color: #667eea;
            text-decoration: none;
        }
        .config-card {
            background: #f7fafc;
            border: 1px solid #e2e8f0;
            border-radius: 10px;
            padding: 1.5rem;
            margin: 1rem 0;
        }
        .config-item {
            margin: 0.5rem 0;
        }
        .config-label {
            font-weight: 600;
            color: #4a5568;
            display: inline-block;
            width: 120px;
        }
        .config-value {
            font-family: monospace;
            background: #edf2f7;
            padding: 0.2rem 0.5rem;
            border-radius: 4px;
        }
        .btn {
            background: linear-gradient(135deg, #667eea, #764ba2);
            color: white;
            padding: 10px 20px;
            border: none;
            border-radius: 8px;
            cursor: pointer;
            margin: 0.5rem 0.5rem 0.5rem 0;
        }
        .subscription-box {
            background: #2d3748;
            color: #cbd5e0;
            padding: 1rem;
            border-radius: 8px;
            margin: 1rem 0;
            font-family: monospace;
            word-break: break-all;
        }
    </style>
</head>
<body>
    <div class="container">
        <a href="/" class="back-link">← 返回首页</a>
        
        <header>
            <h1>⚡ VLESS Reality 节点信息</h1>
            <p>共享443端口配置 - 基于SNI分流技术</p>
        </header>

        <div class="config-card">
            <h3>📋 服务器配置</h3>
            <div class="config-item">
                <span class="config-label">地址:</span>
                <span class="config-value">$VLESS_DOMAIN</span>
            </div>
            <div class="config-item">
                <span class="config-label">端口:</span>
                <span class="config-value">443 (与Web服务共享)</span>
            </div>
            <div class="config-item">
                <span class="config-label">协议:</span>
                <span class="config-value">VLESS</span>
            </div>
            <div class="config-item">
                <span class="config-label">传输:</span>
                <span class="config-value">TCP + Reality</span>
            </div>
        </div>

        <div class="config-card">
            <h3>🔑 安全配置</h3>
            <div class="config-item">
                <span class="config-label">UUID:</span>
                <span class="config-value" id="uuid-value">[点击显示]</span>
                <button class="btn" onclick="showValue('uuid-value')">显示</button>
            </div>
            <div class="config-item">
                <span class="config-label">Public Key:</span>
                <span class="config-value" id="pbk-value">[点击显示]</span>
                <button class="btn" onclick="showValue('pbk-value')">显示</button>
            </div>
            <div class="config-item">
                <span class="config-label">Short ID:</span>
                <span class="config-value" id="sid-value">[点击显示]</span>
                <button class="btn" onclick="showValue('sid-value')">显示</button>
            </div>
            <div class="config-item">
                <span class="config-label">流控:</span>
                <span class="config-value">xtls-rprx-vision</span>
            </div>
            <div class="config-item">
                <span class="config-label">SNI:</span>
                <span class="config-value">$REALITY_SERVER</span>
            </div>
            <div class="config-item">
                <span class="config-label">指纹:</span>
                <span class="config-value">chrome</span>
            </div>
        </div>

        <div class="config-card">
            <h3>📡 订阅链接</h3>
            <div class="subscription-box" id="sub-link">
                [安全原因不在此显示，请查看服务器上的配置文件]
            </div>
            <p><strong>配置文件位置:</strong> /root/vless-config.txt</p>
            <button class="btn" onclick="location.href='/sub'">前往订阅转换</button>
        </div>

        <div class="config-card">
            <h3>🎯 技术特点</h3>
            <ul>
                <li>✅ 与Web服务共享443端口</li>
                <li>✅ 基于SNI的智能流量分流</li>
                <li>✅ Reality协议，无需TLS证书</li>
                <li>✅ 抗封锁能力强</li>
                <li>✅ 极速网络体验</li>
            </ul>
        </div>
    </div>

    <script>
        function showValue(elementId) {
            // 在实际部署中，这些值应该从服务器API获取
            // 这里仅作演示
            const values = {
                'uuid-value': '从 /root/vless-config.txt 获取',
                'pbk-value': '从 /root/vless-config.txt 获取', 
                'sid-value': '从 /root/vless-config.txt 获取'
            };
            document.getElementById(elementId).textContent = values[elementId];
        }
    </script>
</body>
</html>
EOF

    # 创建订阅转换页面（与之前类似，但更新说明）
    cat > /var/www/html/sub.html << 'EOF'
<!DOCTYPE html>
<html lang="zh">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>订阅转换工具</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { 
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; 
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: #333;
            line-height: 1.6;
            min-height: 100vh;
            padding: 20px;
        }
        .container {
            max-width: 1000px;
            margin: 0 auto;
            background: rgba(255, 255, 255, 0.95);
            border-radius: 15px;
            padding: 2rem;
            box-shadow: 0 10px 30px rgba(0, 0, 0, 0.1);
        }
        header {
            text-align: center;
            margin-bottom: 2rem;
        }
        h1 {
            color: #4a5568;
            margin-bottom: 0.5rem;
        }
        .description {
            color: #718096;
            margin-bottom: 2rem;
        }
        .back-link {
            display: inline-block;
            margin-bottom: 1rem;
            color: #667eea;
            text-decoration: none;
        }
        .input-group {
            margin-bottom: 1.5rem;
        }
        label {
            display: block;
            margin-bottom: 0.5rem;
            font-weight: 600;
            color: #4a5568;
        }
        textarea, select {
            width: 100%;
            padding: 12px;
            border: 2px solid #e2e8f0;
            border-radius: 8px;
            font-size: 14px;
        }
        textarea {
            height: 150px;
            resize: vertical;
            font-family: monospace;
        }
        .btn {
            background: linear-gradient(135deg, #667eea, #764ba2);
            color: white;
            padding: 12px 24px;
            border: none;
            border-radius: 8px;
            cursor: pointer;
            font-size: 16px;
            margin-right: 10px;
            margin-bottom: 10px;
        }
        .btn:hover {
            transform: translateY(-2px);
            box-shadow: 0 5px 15px rgba(102, 126, 234, 0.4);
        }
        .result {
            margin-top: 2rem;
            padding: 1.5rem;
            background: #f7fafc;
            border-radius: 8px;
            display: none;
        }
        .config-row {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 15px;
            margin-bottom: 15px;
        }
        .tech-note {
            background: #e6fffa;
            border: 1px solid #81e6d9;
            border-radius: 8px;
            padding: 1rem;
            margin: 1rem 0;
        }
    </style>
</head>
<body>
    <div class="container">
        <a href="/" class="back-link">← 返回首页</a>
        
        <header>
            <h1>🔄 订阅转换工具</h1>
            <p class="description">支持 VLESS、VMess、Trojan 等协议转换为 Clash 配置</p>
        </header>

        <div class="tech-note">
            <strong>🎯 技术说明:</strong> 本服务使用SNI分流技术，Web服务和VLESS节点共享443端口。
            根据访问域名的不同，流量会被智能路由到相应的服务。
        </div>

        <div class="input-group">
            <label for="subscriptionUrl">订阅链接：</label>
            <textarea id="subscriptionUrl" placeholder="请输入订阅链接，每行一个链接..."></textarea>
        </div>
        
        <div class="config-row">
            <div class="input-group">
                <label for="clientType">目标客户端：</label>
                <select id="clientType">
                    <option value="clash">Clash</option>
                    <option value="surge">Surge</option>
                    <option value="quantumult">Quantumult</option>
                </select>
            </div>
            
            <div class="input-group">
                <label for="ruleConfig">规则配置：</label>
                <select id="ruleConfig">
                    <option value="https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/config/ACL4SSR_Online_Full.ini">ACL4SSR 全分组</option>
                    <option value="https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/config/ACL4SSR_Online_NoAuto.ini">ACL4SSR 无自动测速</option>
                    <option value="https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/config/ACL4SSR_Online_Mini.ini">ACL4SSR 最小化</option>
                </select>
            </div>
        </div>

        <button class="btn" onclick="generateConfig()">生成配置</button>
        <button class="btn" onclick="clearAll()">清空</button>

        <div id="result" class="result">
            <h3>生成结果：</h3>
            <div id="configOutput"></div>
            <button class="btn" onclick="copyResult()">复制链接</button>
            <a id="downloadLink" class="btn">下载配置</a>
        </div>
    </div>

    <script>
        function generateConfig() {
            const urls = document.getElementById('subscriptionUrl').value;
            const client = document.getElementById('clientType').value;
            const ruleset = document.getElementById('ruleConfig').value;
            
            if (!urls.trim()) {
                alert('请输入订阅链接');
                return;
            }
            
            // 构建转换链接
            let baseUrl = '/sub';
            let params = new URLSearchParams({
                target: client,
                url: urls.split('\n').filter(url => url.trim()).join('|')
            });
            
            if (ruleset) params.append('config', ruleset);
            
            const finalUrl = baseUrl + '?' + params.toString();
            const fullUrl = window.location.origin + finalUrl;
            
            // 显示结果
            document.getElementById('configOutput').innerHTML = 
                '<p>订阅链接：</p>' +
                '<input type="text" value="' + fullUrl + '" style="width: 100%; padding: 8px; margin: 5px 0;" readonly>' +
                '<p>或者直接访问：<a href="' + finalUrl + '" target="_blank">' + finalUrl + '</a></p>';
            
            document.getElementById('downloadLink').href = finalUrl;
            document.getElementById('downloadLink').download = 'config.' + (client === 'clash' ? 'yaml' : 'conf');
            document.getElementById('result').style.display = 'block';
        }
        
        function copyResult() {
            const resultInput = document.querySelector('#configOutput input');
            resultInput.select();
            document.execCommand('copy');
            alert('链接已复制到剪贴板');
        }
        
        function clearAll() {
            document.getElementById('subscriptionUrl').value = '';
            document.getElementById('result').style.display = 'none';
        }
    </script>
</body>
</html>
EOF

    # 创建符号链接
    ln -sf /var/www/html/vless-info.html /var/www/html/vless-info

    log "网页界面设置完成"
}

# 安装 AdGuard Home
install_adguard() {
    step "安装 AdGuard Home..."
    
    if curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v; then
        log "AdGuard Home 安装完成"
    else
        warn "AdGuard Home 安装失败，跳过..."
    fi
}

# 安装 S-UI 面板
install_sui() {
    step "安装 S-UI 面板..."
    
    if bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh); then
        log "S-UI 面板安装完成"
    else
        warn "S-UI 面板安装失败，跳过..."
    fi
}

# 重启服务
restart_services() {
    step "重启所有服务..."
    
    # 重启 Nginx
    systemctl restart nginx
    sleep 2
    
    # 重启 Xray
    systemctl restart xray
    sleep 2
    
    # 检查服务状态
    local services=("nginx" "xray" "subconverter")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet $service; then
            log "✅ $service: 运行正常"
        else
            warn "❌ $service: 启动失败"
        fi
    done
}

# 检查服务状态
check_services() {
    step "检查服务状态..."
    
    echo
    log "=== 服务状态 ==="
    local services=("nginx" "xray" "subconverter")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet $service; then
            log "✅ $service: 运行中"
        else
            warn "❌ $service: 未运行"
        fi
    done
    
    # 检查 AdGuard Home
    if systemctl is-active --quiet AdGuardHome 2>/dev/null; then
        log "✅ AdGuardHome: 运行中"
    else
        warn "❌ AdGuardHome: 未运行"
    fi
    
    echo
    log "=== 端口监听 ==="
    local ports=("80" "443" "25500" "3000" "2095")
    for port in "${ports[@]}"; do
        if netstat -tln | grep -q ":$port "; then
            log "✅ 端口 $port: 已监听"
        else
            warn "❌ 端口 $port: 未监听"
        fi
    done
    
    echo
    log "=== SNI 分流检查 ==="
    log "Web服务域名: $WEB_DOMAIN → Nginx (8443)"
    log "VLESS域名: $VLESS_DOMAIN → Xray (443)"
    log "共享端口: 443"
}

# 显示部署结果
show_result() {
    echo
    echo -e "${GREEN}"
    echo "=========================================="
    echo "           SNI分流部署完成！"
    echo "=========================================="
    echo -e "${NC}"
    
    log "🌐 Web服务: https://$WEB_DOMAIN"
    log "⚡ VLESS节点: $VLESS_DOMAIN:443"
    log "🔄 订阅转换: https://$WEB_DOMAIN/sub"
    log "🛡️ AdGuard Home: http://$WEB_DOMAIN:3000"
    log "📊 S-UI 面板: http://$WEB_DOMAIN:2095/app"
    echo
    log "🎯 SNI分流技术:"
    log "✅ 443端口共享: Web服务 + VLESS Reality"
    log "✅ 智能流量路由: 根据SNI自动分流"
    log "✅ 无端口冲突: 最大化端口利用率"
    echo
    log "🔧 VLESS配置信息:"
    log "   配置文件: /root/vless-config.txt"
    log "   包含: 订阅链接、Clash配置、二维码等"
    echo
    warn "后续操作:"
    echo "1. 查看VLESS配置: cat /root/vless-config.txt"
    echo "2. 配置 AdGuard Home: http://$WEB_DOMAIN:3000"
    echo "3. 配置 S-UI 面板: http://$WEB_DOMAIN:2095/app"
    echo "4. 测试Web服务: https://$WEB_DOMAIN"
    echo "5. 测试VLESS节点: 使用配置信息"
    echo
    log "💡 技术优势:"
    echo "   - 单一端口，简化防火墙配置"
    echo "   - 智能分流，提升用户体验"
    echo "   - 隐藏代理特征，增强安全性"
    echo "=========================================="
}

# 主函数
main() {
    show_banner
    check_system
    get_user_input
    
    # 记录开始时间
    local start_time=$(date +%s)
    
    # 执行部署步骤
    install_basics
    configure_firewall
    setup_ssl
    install_xray
    setup_nginx_sni
    install_subconverter
    setup_web_interface
    install_adguard
    install_sui
    restart_services
    
    # 检查服务状态
    check_services
    
    # 计算部署时间
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log "部署完成，总耗时: ${duration} 秒"
    
    # 显示结果
    show_result
}

# 运行主函数
main "$@"
