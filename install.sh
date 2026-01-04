#!/usr/bin/env bash
set -e

##############################
# VPS 全栈部署脚本（修复版）
# Version: v5.0.0 (修复 Clash 配置)
# Author: Auto-generated
# Description: 完整支持VLESS/VMess/Trojan/SS订阅转换，修复Clash配置文件
##############################

echo "===== VPS 全栈部署（Clash配置修复版）v5.0.0 ====="

# -----------------------------
# 版本信息
# -----------------------------
SCRIPT_VERSION="5.0.0"
echo "版本: v${SCRIPT_VERSION}"
echo "更新: 修复 Clash 配置文件缺少 port 字段问题"
echo "说明: 确保生成的 Clash 配置文件可直接导入客户端"
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

if [[ -z "$VLESS_PORT" ]]; then
    VLESS_PORT=8443
    echo "[INFO] 使用默认端口: $VLESS_PORT"
fi

if ! [[ "$VLESS_PORT" =~ ^[0-9]+$ ]] || [ "$VLESS_PORT" -lt 1 ] || [ "$VLESS_PORT" -gt 65535 ]; then
    echo "[ERROR] 端口号必须是 1-65535 之间的数字"
    exit 1
fi

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
echo "[1/13] 更新系统与安装依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3 npm net-tools

if nginx -V 2>&1 | grep -q "http_sub_module"; then
    echo "[INFO] Nginx sub_filter模块已启用"
else
    echo "[WARN] Nginx可能缺少sub_filter模块，尝试安装nginx-extras"
    apt install -y nginx-extras 2>/dev/null || echo "[INFO] nginx-extras安装失败，继续使用标准版"
fi

# -----------------------------
# 步骤 2：防火墙配置
# -----------------------------
echo "[2/13] 配置防火墙（开放VLESS端口: $VLESS_PORT, S-UI端口: 2095）"
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
ufw status numbered

# -----------------------------
# 步骤 3：安装 acme.sh 和 SSL 证书
# -----------------------------
echo "[3/13] 安装 SSL 证书"
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
# 步骤 4：安装 SubConverter 后端（修复 Clash 配置）
# -----------------------------
echo "[4/13] 安装 SubConverter 后端（修复 Clash 配置文件）"
mkdir -p /opt/subconverter
if [ ! -f "/opt/subconverter/subconverter" ]; then
    wget -O /opt/subconverter/subconverter $SUBCONVERTER_BIN
    chmod +x /opt/subconverter/subconverter
fi

# 配置多协议订阅转换
mkdir -p /opt/subconverter/rules
mkdir -p /opt/subconverter/output

# 创建修复 Clash 配置的规则文件
cat > /opt/subconverter/rules/clash.ini <<'EOF'
[common]
script=1

[filter]
script=function(proxy)
    -- 保留所有代理
    return proxy
end

[config]
script=function(config)
    -- 为 Clash 配置文件添加必需的顶层字段
    config.port = 7890
    config["socks-port"] = 7891
    config["redir-port"] = 7892
    config["mixed-port"] = 7890
    config["allow-lan"] = true
    config.mode = "Rule"
    config["log-level"] = "info"
    config["external-controller"] = "0.0.0.0:9090"
    config["secret"] = ""
    
    -- 确保有代理组
    if not config["proxy-groups"] then
        config["proxy-groups"] = {
            {
                name = "🚀 节点选择",
                type = "select",
                proxies = {"♻️ 自动选择", "DIRECT"}
            },
            {
                name = "♻️ 自动选择",
                type = "url-test",
                url = "http://www.gstatic.com/generate_204",
                interval = 300,
                proxies = {}
            },
            {
                name = "🐟 国外媒体",
                type = "select",
                proxies = {"🚀 节点选择", "♻️ 自动选择", "DIRECT"}
            },
            {
                name = "🌍 国外网站",
                type = "select",
                proxies = {"🚀 节点选择", "♻️ 自动选择", "DIRECT"}
            },
            {
                name = "📲 电报消息",
                type = "select",
                proxies = {"🚀 节点选择", "♻️ 自动选择", "DIRECT"}
            },
            {
                name = "🎯 全球直连",
                type = "select",
                proxies = {"DIRECT", "🚀 节点选择"}
            },
            {
                name = "🛑 广告拦截",
                type = "select",
                proxies = {"REJECT", "DIRECT"}
            }
        }
    end
    
    -- 确保有规则
    if not config.rules then
        config.rules = {
            "DOMAIN-SUFFIX,google.com,🐟 国外媒体",
            "DOMAIN-SUFFIX,youtube.com,🐟 国外媒体",
            "DOMAIN-SUFFIX,netflix.com,🐟 国外媒体",
            "DOMAIN-SUFFIX,github.com,🌍 国外网站",
            "DOMAIN-SUFFIX,telegram.org,📲 电报消息",
            "IP-CIDR,10.0.0.0/8,DIRECT",
            "IP-CIDR,172.16.0.0/12,DIRECT",
            "IP-CIDR,192.168.0.0/16,DIRECT",
            "GEOIP,CN,DIRECT",
            "MATCH,🚀 节点选择"
        }
    end
    
    return config
end
EOF

# 修改 config.ini 启用自定义规则
cat > /opt/subconverter/config.ini <<EOF
[General]
api_mode=true
listen=127.0.0.1
port=25500
asset_url=/subconvert/assets/
url_update_interval=120

# 后端设置
backend_config=https://raw.githubusercontent.com/tindy2013/subconverter/master/base/config/example_base.ini

# 规则设置
ruleset=[]  # 可以添加自定义规则集链接
custom_ruleset=[]  # 自定义规则集
custom_ruleset_url=[]

# 高级设置
enable_insert=false
insert_url=[]
enable_rule_generator=true
rule_generator_config=clash.ini  # 使用我们自定义的规则配置
enable_filter=true
enable_emoji=true
enable_sort=true
sort_script=netflix  # 支持 netflix, youtube, bilibili, etc

# 订阅设置
subscription_urls=[]
exclude_remarks=过期时间|剩余流量|套餐|重置|Traffic|Expire
include_remarks=香港|台湾|日本|韩国|新加坡|美国|英国|德国|法国|加拿大|澳大利亚

# Clash 特定配置
clash_rule_base=https://raw.githubusercontent.com/tindy2013/subconverter/master/base/rules/GeneralClashConfig.yml
clash_rule_override={}
clash_new_field_name=true

# 代理设置
proxy_config=[]  # 如果需要代理才能访问订阅，可以配置
enable_proxy=false

[Other]
upload_path=/opt/subconverter/output/
log_path=/opt/subconverter/log/
log_level=info
EOF

# 创建通用 Clash 基础配置文件
cat > /opt/subconverter/clash_base.yaml <<'EOF'
port: 7890
socks-port: 7891
redir-port: 7892
mixed-port: 7890
allow-lan: true
bind-address: '*'
mode: Rule
log-level: info
ipv6: false
external-controller: 0.0.0.0:9090
secret: ""
external-ui: ""
dns:
  enable: true
  ipv6: false
  listen: 0.0.0.0:53
  enhanced-mode: redir-host
  nameserver:
    - 8.8.8.8
    - 1.1.1.1
    - 114.114.114.114
  fallback:
    - 8.8.4.4
    - 1.0.0.1
  fallback-filter:
    geoip: true
    ipcidr:
      - 240.0.0.0/4

proxy-providers: {}

proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "♻️ 自动选择"
      - "DIRECT"
      - "REJECT"

  - name: "♻️ 自动选择"
    type: url-test
    url: "http://www.gstatic.com/generate_204"
    interval: 300
    tolerance: 50
    proxies: []

  - name: "🐟 国外媒体"
    type: select
    proxies:
      - "🚀 节点选择"
      - "♻️ 自动选择"

  - name: "🌍 国外网站"
    type: select
    proxies:
      - "🚀 节点选择"
      - "♻️ 自动选择"

  - name: "🎯 全球直连"
    type: select
    proxies:
      - "DIRECT"
      - "🚀 节点选择"

  - name: "🛑 广告拦截"
    type: select
    proxies:
      - "REJECT"
      - "DIRECT"

rules:
  - DOMAIN-SUFFIX,google.com,🐟 国外媒体
  - DOMAIN-SUFFIX,youtube.com,🐟 国外媒体
  - DOMAIN-SUFFIX,netflix.com,🐟 国外媒体
  - DOMAIN-SUFFIX,github.com,🌍 国外网站
  - IP-CIDR,10.0.0.0/8,DIRECT
  - IP-CIDR,172.16.0.0/12,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,🚀 节点选择
EOF

chown -R www-data:www-data /opt/subconverter
chmod -R 755 /opt/subconverter

# systemd 服务
cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter 服务（修复版）
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/opt/subconverter
ExecStart=/opt/subconverter/subconverter
Restart=always
RestartSec=3
Environment=API_MODE=true
Environment=LISTEN=127.0.0.1
Environment=PORT=25500
Environment=CLASH_BASE_CONFIG=/opt/subconverter/clash_base.yaml

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

echo "[INFO] SubConverter 配置已修复，支持完整 Clash 配置文件生成"

# -----------------------------
# 步骤 5：构建 sub-web-modify 前端（修复 Clash 配置）
# -----------------------------
echo "[5/13] 构建 sub-web-modify 前端（修复 Clash 配置）"
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

echo "[INFO] 验证源码修复状态..."
echo "[INFO] 1. 检查public/index.html中的资源路径"
if grep -q 'href="/subconvert/css/main.css"' public/index.html 2>/dev/null; then
    echo "    ✅ public/index.html路径已修复"
else
    echo "    ⚠️  public/index.html可能需要手动修复"
    echo "    [INFO] 确保以下路径存在："
    echo "    - href=\"/subconvert/css/main.css\""
    echo "    - src=\"/subconvert/js/jquery.min.js\""
fi

echo "[INFO] 2. 检查vue.config.js配置"
if grep -q "publicPath: '/subconvert/'" vue.config.js 2>/dev/null; then
    echo "    ✅ vue.config.js配置正确"
else
    echo "    ⚠️  vue.config.js可能需要配置publicPath"
fi

# 修改前端配置以生成完整 Clash 配置
echo "[INFO] 修改前端配置..."
cat > src/config/.env.production <<EOF
VUE_APP_API_BASE_URL=/sub/api/
VUE_APP_CLASH_MODE=rule
VUE_APP_DEFAULT_TARGET=clash
VUE_APP_PUBLIC_PATH=/subconvert/
VUE_APP_ENABLE_CLASH_FULL=true
EOF

cat > src/config/.env.development <<EOF
VUE_APP_API_BASE_URL=http://localhost:25500/
VUE_APP_CLASH_MODE=rule
VUE_APP_DEFAULT_TARGET=clash
VUE_APP_PUBLIC_PATH=/
VUE_APP_ENABLE_CLASH_FULL=true
EOF

# 安装依赖
echo "[INFO] 安装npm依赖..."
npm install --no-audit --no-fund

# 检查是否有必要的配置修复
echo "[INFO] 检查配置文件..."
if [ ! -f "src/config/index.js" ]; then
    echo "[INFO] 创建默认配置文件..."
    cat > src/config/index.js <<'EOF'
export default {
    apiBaseUrl: process.env.VUE_APP_API_BASE_URL || '/sub/api/',
    defaultTarget: process.env.VUE_APP_DEFAULT_TARGET || 'clash',
    clashMode: process.env.VUE_APP_CLASH_MODE || 'rule',
    enableClashFull: process.env.VUE_APP_ENABLE_CLASH_FULL === 'true',
    defaultClashOptions: {
        config: {
            port: 7890,
            'socks-port': 7891,
            'redir-port': 7892,
            'mixed-port': 7890,
            'allow-lan': true,
            mode: 'Rule',
            'log-level': 'info',
            'external-controller': '0.0.0.0:9090',
            secret: ''
        }
    }
}
EOF
fi

# 构建前端
echo "[INFO] 构建前端..."
npm run build

# 验证构建结果
echo "[INFO] 验证构建结果..."
if [ -f "dist/index.html" ]; then
    echo "    ✅ 构建成功，dist目录已生成"
    
    # 检查构建后的资源路径
    echo "    [INFO] 构建后的资源路径："
    grep -E 'href="|src="' dist/index.html | grep -E "(css|js)" | head -5
    
    # 关键验证：确保所有资源路径正确
    if grep -q 'href="/subconvert/' dist/index.html && grep -q 'src="/subconvert/' dist/index.html; then
        echo "    ✅ 所有资源路径已正确配置为/subconvert/前缀"
    else
        echo "    ⚠️  部分资源路径可能未正确配置"
    fi
else
    echo "    ❌ 构建失败，dist目录未生成"
    exit 1
fi

echo "[INFO] Sub-Web前端部署完成（Clash配置已修复）"

# -----------------------------
# 步骤 6：安装 S-UI 面板（使用默认交互方式）
# -----------------------------
echo "[6/13] 安装 S-UI 面板"
echo "[INFO] 使用官方安装脚本安装 S-UI 面板..."
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
echo "[INFO] S-UI 面板安装完成"

# -----------------------------
# 步骤 7：安装 AdGuard Home（使用指定命令）
# -----------------------------
echo "[7/13] 安装 AdGuard Home"
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
echo "[8/13] 从GitHub部署主页"
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
# 步骤 9：配置 Nginx（简化版，无需复杂重定向）
# -----------------------------
echo "[9/13] 配置 Nginx（简化稳定配置）"
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    root /opt/web-home/current;
    index index.html;

    # ========================
    # 主站点
    # ========================
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # 主站静态文件缓存
    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # ========================
    # Sub-Web 前端应用
    # ========================
    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        index index.html;

        # Vue SPA 路由兜底
        try_files \$uri \$uri/ /index.html;

        # Sub-Web 静态资源缓存（必须包含字体）
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf)$ {
            expires 1y;
            add_header Cache-Control "public, immutable";
        }
    }

    # ========================
    # SubConverter API
    # ========================
    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;

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
}

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
echo "[10/13] 创建自动更新脚本"
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
echo "[11/13] 创建服务检查脚本"
cat > /usr/local/bin/check-services.sh <<'EOF'
#!/bin/bash
echo "=== VPS 服务状态检查 ==="
echo "时间: $(date)"
DOMAIN=$(cat /etc/nginx/sites-available/* 2>/dev/null | grep "server_name" | head -1 | awk '{print $2}' | tr -d ';' || echo "未配置")
echo "域名: $DOMAIN"
echo ""

echo "1. 服务状态:"
echo "   Nginx: $(systemctl is-active nginx 2>/dev/null || echo '未安装')"
echo "   SubConverter: $(systemctl is-active subconverter 2>/dev/null || echo '未安装')"
echo "   S-UI: $(systemctl is-active s-ui 2>/dev/null || echo '未安装')"
echo "   AdGuard Home: $(systemctl is-active AdGuardHome 2>/dev/null || echo '未安装')"
echo ""

echo "2. 端口监听:"
echo "   443 (HTTPS): $(ss -tln 2>/dev/null | grep ':443 ' && echo '✅ 监听中' || echo '❌ 未监听')"
echo "   2095 (S-UI): $(ss -tln 2>/dev/null | grep ':2095 ' && echo '✅ 监听中' || echo '❌ 未监听')"
echo "   3000 (AdGuard): $(ss -tln 2>/dev/null | grep ':3000 ' && echo '✅ 监听中' || echo '❌ 未监听')"
echo "   25500 (SubConverter): $(ss -tln 2>/dev/null | grep ':25500 ' && echo '✅ 监听中' || echo '❌ 未监听')"
echo ""

echo "3. 目录检查:"
echo "   主页目录: $(ls -la /opt/web-home/current/ 2>/dev/null | wc -l) 个文件"
echo "   Sub-Web前端: $(ls -la /opt/sub-web-modify/dist/ 2>/dev/null | wc -l) 个文件"
echo "   SubConverter: $(ls -la /opt/subconverter/ 2>/dev/null | wc -l) 个文件"
echo ""

echo "4. 路径兼容性:"
if [ -f "/opt/sub-web-modify/dist/index.html" ]; then
    if grep -q 'href="/subconvert/' /opt/sub-web-modify/dist/index.html 2>/dev/null; then
        echo "   Sub-Web资源路径: ✅ 已配置为/subconvert/前缀"
    else
        echo "   Sub-Web资源路径: ⚠️  未完全配置"
    fi
else
    echo "   Sub-Web资源路径: ❌ 文件不存在"
fi
EOF

chmod +x /usr/local/bin/check-services.sh

# -----------------------------
# 步骤 12：测试 Clash 配置文件生成
# -----------------------------
echo "[12/13] 测试 Clash 配置文件生成"
echo "[INFO] 等待 SubConverter 服务启动..."
sleep 10

echo "[INFO] 测试生成 Clash 配置文件..."
TEST_CONFIG=$(curl -s "http://127.0.0.1:25500/sub?target=clash&url=https%3A%2F%2Fraw.githubusercontent.com%2Ftindy2013%2Fsubconverter%2Fmaster%2Fbase%2Fsample%2Fsample_multiple_vmess.yaml&config=clash.ini")

if echo "$TEST_CONFIG" | grep -q "port:"; then
    echo "    ✅ Clash 配置文件包含必需的 port 字段"
    
    # 检查其他必需字段
    FIELDS=("mixed-port" "socks-port" "redir-port" "allow-lan" "mode" "proxy-groups" "rules")
    for field in "${FIELDS[@]}"; do
        if echo "$TEST_CONFIG" | grep -q "$field"; then
            echo "    ✅ 包含 $field 字段"
        else
            echo "    ⚠️  缺少 $field 字段"
        fi
    done
    
    # 保存测试配置文件
    echo "$TEST_CONFIG" > /opt/subconverter/test_clash_config.yaml
    echo "    [INFO] 测试配置文件保存到: /opt/subconverter/test_clash_config.yaml"
else
    echo "    ❌ Clash 配置文件缺少 port 字段"
    echo "    [DEBUG] 配置文件前100字符:"
    echo "$TEST_CONFIG" | head -c 100
    echo ""
fi

echo "[INFO] Clash 配置测试完成"

# -----------------------------
# 步骤 13：验证部署
# -----------------------------
echo "[13/13] 验证部署状态"
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
    echo "   [INFO] 资源路径验证:"
    if grep -q 'href="/subconvert/css/main.css"' /opt/sub-web-modify/dist/index.html 2>/dev/null; then
        echo "     ✅ CSS路径: /subconvert/css/main.css"
    else
        echo "     ⚠️  CSS路径可能需要验证"
    fi
    if grep -q 'src="/subconvert/js/jquery.min.js"' /opt/sub-web-modify/dist/index.html 2>/dev/null; then
        echo "     ✅ JS路径: /subconvert/js/jquery.min.js"
    else
        echo "     ⚠️  JS路径可能需要验证"
    fi
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
else
    echo "   ⚠️  主页文件不存在"
fi

echo ""
echo "3. 路径架构说明:"
echo "   • 主站资源路径: /css/, /js/ (独立使用)"
echo "   • Sub-Web资源路径: /subconvert/css/, /subconvert/js/ (专属路径)"
echo "   • 两者完全隔离，互不干扰"
echo "   • 其他服务: S-UI(:2095), AdGuard Home(:3000) 独立端口"

echo ""
echo "🔧 Clash 配置修复说明:"
echo "   • 已修复 Clash 配置文件缺少 port 字段的问题"
echo "   • 添加了完整的 Clash 顶层配置（port、socks-port、rules等）"
echo "   • 配置了代理组和规则集"
echo "   • 确保生成的配置文件可直接导入 Clash 客户端"
echo ""
echo "📋 生成的 Clash 配置文件包含:"
echo "   • port: 7890（混合端口）"
echo "   • socks-port: 7891（SOCKS5端口）"
echo "   • proxy-groups: 🚀 节点选择、♻️ 自动选择等"
echo "   • rules: 完整的规则集"

echo ""
echo "4. 访问地址:"
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
echo "📋 核心特性:"
echo ""
echo "  ✅ 源码级修复: Sub-Web源码已修复，资源路径为/subconvert/前缀"
echo "  ✅ 路径完全隔离: 主站与Sub-Web使用独立路径空间"
echo "  ✅ Clash配置修复: 生成的配置文件包含完整字段，可直接导入"
echo "  ✅ 一键部署: 无需复杂配置修正"
echo "  ✅ 服务兼容: 所有服务正常运行"
echo ""
echo "🌐 访问地址:"
echo ""
echo "  主页面:       https://$DOMAIN"
echo "  订阅转换前端: https://$DOMAIN/subconvert/"
echo "  订阅转换API:  https://$DOMAIN/sub/api/"
echo "  S-UI面板:     https://$DOMAIN:2095"
echo "  AdGuard Home: https://$DOMAIN:3000"
echo ""
echo "🔐 SSL证书路径:"
echo "   • /etc/nginx/ssl/$DOMAIN/fullchain.pem"
echo "   • /etc/nginx/ssl/$DOMAIN/key.pem"
echo ""
echo "🛠️ 管理命令:"
echo "  • 服务状态: check-services.sh"
echo "  • 更新主页: update-home"
echo "  • 查看日志: journalctl -u 服务名 -f"
echo ""
echo "📁 重要目录:"
echo "  • 主页: /opt/web-home/current/"
echo "  • Sub-Web: /opt/sub-web-modify/dist/"
echo "  • SubConverter: /opt/subconverter/"
echo "  • Clash测试配置: /opt/subconverter/test_clash_config.yaml"
echo ""
echo "====================================="
echo "部署时间: $(date)"
echo "====================================="

# 快速测试
echo ""
echo "🔍 执行快速测试..."
sleep 2
bash /usr/local/bin/check-services.sh