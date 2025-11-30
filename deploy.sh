#!/bin/bash

# VPS 一键部署脚本
# 使用方法: bash <(curl -sL https://raw.githubusercontent.com/你的用户名/vps-deployment/main/deploy.sh)

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
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
        
    VPS 一键部署脚本
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
    
    # 检查是否为 Ubuntu 或 Debian
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        warn "此脚本主要针对 Ubuntu/Debian 系统，其他系统可能不兼容"
    fi
}

# 获取用户输入
get_user_input() {
    echo
    step "请输入配置信息"
    
    read -p "请输入域名 (例如: myhouse.mycloudshare.org): " DOMAIN
    if [ -z "$DOMAIN" ]; then
        error "域名不能为空"
    fi
    
    read -p "请输入邮箱 (用于 SSL 证书): " EMAIL
    if [ -z "$EMAIL" ]; then
        EMAIL="admin@$DOMAIN"
        warn "使用默认邮箱: $EMAIL"
    fi
    
    # 显示配置确认
    echo
    log "配置确认:"
    log "域名: $DOMAIN"
    log "邮箱: $EMAIL"
    log "Reality 握手服务器: www.51kankan.vip"
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
    apt install -y cron socat ufw curl wget nginx unzip git
    
    log "基础软件安装完成"
}

# 配置防火墙
configure_firewall() {
    step "配置防火墙..."
    
    ufw --force enable
    
    # 开放端口
    ports=(22 53 80 443 3000 2095 25500)
    for port in "${ports[@]}"; do
        ufw allow $port/tcp
        ufw allow $port/udp 2>/dev/null || true
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
    
    # 创建符号链接
    ln -sf /root/.acme.sh/acme.sh /usr/local/bin/acme.sh
    
    # 设置 CA 并申请证书
    acme.sh --set-default-ca --server letsencrypt
    acme.sh --issue -d $DOMAIN --standalone --keylength ec-256
    
    # 安装证书
    acme.sh --install-cert -d $DOMAIN --ecc \
        --key-file /root/server.key \
        --fullchain-file /root/server.crt
    
    # 设置自动续期
    cat > /root/cert-monitor.sh << EOF
#!/bin/bash
/root/.acme.sh/acme.sh --renew -d $DOMAIN --force --ecc \
    --key-file /root/server.key \
    --fullchain-file /root/server.crt
EOF
    
    chmod +x /root/cert-monitor.sh
    (crontab -l 2>/dev/null; echo "0 3 */30 * * /root/cert-monitor.sh >>/var/log/cert-monitor.log 2>&1") | crontab -
    
    log "SSL 证书设置完成"
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
    
    # 下载网页文件
    local pages_url="https://raw.githubusercontent.com/你的用户名/vps-deployment/main/pages"
    
    if ! wget -q -O /var/www/html/index.html "$pages_url/index.html"; then
        warn "无法下载主页面，使用默认页面"
        create_default_pages
    else
        # 替换域名变量
        sed -i "s|MY_DOMAIN|$DOMAIN|g" /var/www/html/index.html
        sed -i "s|MY_DOMAIN|$DOMAIN|g" /var/www/html/sub.html
    fi
    
    log "网页界面设置完成"
}

# 创建默认页面（备用）
create_default_pages() {
    cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html lang="zh">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>服务管理中心 - $DOMAIN</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 30px; border-radius: 10px; }
        h1 { color: #333; text-align: center; }
        .service { background: #f8f9fa; padding: 20px; margin: 15px 0; border-radius: 8px; }
        .btn { display: inline-block; background: #007acc; color: white; padding: 10px 20px; text-decoration: none; border-radius: 5px; margin: 5px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>服务管理中心</h1>
        <div class="service">
            <h3>🔄 订阅转换</h3>
            <a href="/sub" class="btn">进入转换工具</a>
        </div>
        <div class="service">
            <h3>🛡️ AdGuard Home</h3>
            <a href="http://$DOMAIN:3000" class="btn" target="_blank">管理面板</a>
        </div>
        <div class="service">
            <h3>⚡ S-UI 面板</h3>
            <a href="http://$DOMAIN:2095" class="btn" target="_blank">管理面板</a>
        </div>
    </div>
</body>
</html>
EOF

    cat > /var/www/html/sub.html << EOF
<!DOCTYPE html>
<html lang="zh">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>订阅转换 - $DOMAIN</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 1000px; margin: 0 auto; background: white; padding: 30px; border-radius: 10px; }
        textarea { width: 100%; height: 200px; padding: 10px; margin: 10px 0; }
        .btn { background: #007acc; color: white; padding: 10px 20px; border: none; border-radius: 5px; cursor: pointer; margin: 5px; }
    </style>
</head>
<body>
    <div class="container">
        <a href="/">← 返回首页</a>
        <h1>订阅转换工具</h1>
        <textarea id="url" placeholder="输入订阅链接"></textarea>
        <select id="client">
            <option value="clash">Clash</option>
            <option value="surge">Surge</option>
        </select>
        <button class="btn" onclick="convert()">转换</button>
        <div id="result" style="display:none; margin-top:20px;"></div>
    </div>
    <script>
        function convert() {
            const url = document.getElementById('url').value;
            const client = document.getElementById('client').value;
            const result = '/sub?target=' + client + '&url=' + encodeURIComponent(url);
            document.getElementById('result').innerHTML = '<a href="' + result + '">' + result + '</a>';
            document.getElementById('result').style.display = 'block';
        }
    </script>
</body>
</html>
EOF
}

# 配置 Nginx
setup_nginx() {
    step "配置 Nginx..."
    
    cat > /etc/nginx/sites-available/default << EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    
    ssl_certificate /root/server.crt;
    ssl_certificate_key /root/server.key;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512;
    
    root /var/www/html;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    location = /sub {
        try_files /sub.html =404;
    }
    
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
EOF

    nginx -t && systemctl restart nginx
    log "Nginx 配置完成"
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

# 检查服务状态
check_services() {
    step "检查服务状态..."
    
    echo
    log "=== 服务状态 ==="
    local services=("nginx" "subconverter" "AdGuardHome")
    for service in "${services[@]}"; do
        if systemctl is-active --quiet $service; then
            log "✅ $service: 运行中"
        else
            warn "❌ $service: 未运行"
        fi
    done
    
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
}

# 显示部署结果
show_result() {
    echo
    echo -e "${GREEN}"
    echo "=========================================="
    echo "           部署完成！"
    echo "=========================================="
    echo -e "${NC}"
    
    log "🌐 主页面: https://$DOMAIN"
    log "🔄 订阅转换: https://$DOMAIN/sub"
    log "🛡️ AdGuard Home: http://$DOMAIN:3000"
    log "⚡ S-UI 面板: http://$DOMAIN:2095"
    echo
    log "🎯 Reality 握手服务器: www.51kankan.vip"
    echo
    warn "后续操作:"
    echo "1. 配置 AdGuard Home: 访问 http://$DOMAIN:3000"
    echo "2. 配置 S-UI 面板: 访问 http://$DOMAIN:2095"
    echo "3. 测试订阅转换: 访问 https://$DOMAIN/sub"
    echo
    log "保存此信息以便后续使用"
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
    install_subconverter
    setup_web_interface
    setup_nginx
    install_adguard
    install_sui
    
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
