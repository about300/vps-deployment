#!/bin/bash

# VPS 一键部署脚本 - 修复 Nginx 配置问题版本
# 使用方法: bash <(curl -sL https://raw.githubusercontent.com/about300/vps-deployment/main/deploy.sh)

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
        
    VPS 一键部署脚本 - 修复版
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

# 释放 80 端口
free_port_80() {
    step "检查并释放 80 端口..."
    
    # 检查 80 端口是否被占用
    if netstat -tln | grep ":80 " > /dev/null; then
        warn "80 端口被占用，停止相关服务..."
        
        # 尝试停止 Nginx
        if systemctl is-active --quiet nginx; then
            systemctl stop nginx
            log "已停止 Nginx"
        fi
        
        # 检查是否还有其他进程占用 80 端口
        if netstat -tln | grep ":80 " > /dev/null; then
            warn "还有其他进程占用 80 端口，强制释放..."
            fuser -k 80/tcp 2>/dev/null || true
            sleep 2
        fi
        
        # 再次检查
        if netstat -tln | grep ":80 " > /dev/null; then
            error "无法释放 80 端口，请手动检查并释放后重新运行脚本"
        fi
    fi
    
    log "80 端口已释放"
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
    
    # 设置 CA
    acme.sh --set-default-ca --server letsencrypt
    
    # 释放 80 端口并申请证书
    free_port_80
    
    log "申请 SSL 证书..."
    if acme.sh --issue -d $DOMAIN --standalone --keylength ec-256; then
        log "SSL 证书申请成功"
    else
        error "SSL 证书申请失败，请检查域名解析和网络连接"
    fi
    
    # 安装证书
    acme.sh --install-cert -d $DOMAIN --ecc \
        --key-file /root/server.key \
        --fullchain-file /root/server.crt
    
    # 设置自动续期
    cat > /root/cert-monitor.sh << EOF
#!/bin/bash
# 使用 webroot 方式续期，避免端口冲突
/root/.acme.sh/acme.sh --renew -d $DOMAIN --force --ecc --webroot /var/www/html
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
    
    # 创建主页面
    cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html lang="zh">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>服务管理中心 - $DOMAIN</title>
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
        footer {
            text-align: center;
            color: rgba(255, 255, 255, 0.7);
            padding: 3rem 0;
            margin-top: 3rem;
            border-top: 1px solid rgba(255, 255, 255, 0.2);
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>🚀 服务管理中心</h1>
            <p>一站式网络服务管理平台</p>
        </header>
        
        <div class="service-grid">
            <div class="service-card">
                <h3>🔄 订阅转换</h3>
                <p>支持 VLESS、VMess、Trojan 等协议转换，集成 ACL4SSR 规则</p>
                <a href="/sub" class="btn">进入转换工具</a>
            </div>
            
            <div class="service-card">
                <h3>🛡️ AdGuard Home</h3>
                <p>DNS 广告过滤和网络保护，提供安全的网络环境</p>
                <a href="http://$DOMAIN:3000" class="btn" target="_blank">管理面板</a>
                <div class="status">端口: 3000</div>
            </div>
            
            <div class="service-card">
                <h3>⚡ S-UI 面板</h3>
                <p>节点管理和流量监控，支持 Xray 核心</p>
                <a href="http://$DOMAIN:2095" class="btn" target="_blank">管理面板</a>
                <div class="status">端口: 2095</div>
            </div>
        </div>
        
        <footer>
            <p>&copy; 2025 服务管理中心 | 域名: $DOMAIN</p>
            <p>Reality 握手服务器: www.51kankan.vip</p>
        </footer>
    </div>
</body>
</html>
EOF

    # 创建订阅转换页面
    cat > /var/www/html/sub.html << EOF
<!DOCTYPE html>
<html lang="zh">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>订阅转换工具 - $DOMAIN</title>
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
        .back-link {
            display: inline-block;
            margin-bottom: 1rem;
            color: #667eea;
            text-decoration: none;
        }
        .config-row {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 15px;
            margin-bottom: 15px;
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
                url: urls.split('\\n').filter(url => url.trim()).join('|')
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

    log "网页界面设置完成"
}

# 配置 Nginx
setup_nginx() {
    step "配置 Nginx..."
    
    # 备份原有配置
    cp /etc/nginx/sites-available/default /etc/nginx/sites-available/default.backup 2>/dev/null || true
    
    # 创建新的 Nginx 配置
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
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    
    root /var/www/html;
    index index.html;
    
    # 静态文件服务
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # 订阅转换页面
    location = /sub {
        try_files /sub.html =404;
    }
    
    # 订阅转换API代理
    location /sub {
        proxy_pass http://127.0.0.1:25500;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # 增加超时时间
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF

    # 测试 Nginx 配置
    log "测试 Nginx 配置..."
    if nginx -t; then
        log "Nginx 配置测试成功"
    else
        error "Nginx 配置测试失败，请检查配置文件"
    fi
    
    # 启动 Nginx
    systemctl enable nginx
    systemctl restart nginx
    
    # 检查 Nginx 状态
    if systemctl is-active --quiet nginx; then
        log "Nginx 启动成功"
    else
        error "Nginx 启动失败，请检查错误日志: journalctl -u nginx -n 20"
    fi
    
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
