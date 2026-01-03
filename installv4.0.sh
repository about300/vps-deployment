#!/usr/bin/env bash
set -e

##############################
# VPS 全栈部署脚本
# Version: v4.0 (带自动更新功能)
# Author: Auto-generated
# Description: 部署完整的VPS服务栈，包含自动更新功能
##############################

echo "===== VPS 全栈部署（自动更新版）v4.0 ====="

# -----------------------------
# 版本信息
# -----------------------------
SCRIPT_VERSION="4.0"
echo "版本: v${SCRIPT_VERSION}"
echo "更新: 添加Web主页自动更新功能"
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
echo "[1/14] 更新系统与安装依赖"
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
# 步骤 2：防火墙配置（开放VLESS端口）
# -----------------------------
echo "[2/14] 配置防火墙（开放VLESS端口: $VLESS_PORT）"
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

# 允许AdGuard Home端口
ufw allow 3000   # AdGuard Home Web界面
ufw allow 8445   # AdGuard Home 管理端口1
ufw allow 8446   # AdGuard Home 管理端口2

# 允许SubConverter端口（仅本地）
ufw allow from 127.0.0.1 to any port 25500

# 允许S-UI面板（仅本地）
ufw allow from 127.0.0.1 to any port 2095
ufw deny 2095  # 禁止外部直接访问

# 开放VLESS端口（外部可访问）
ufw allow ${VLESS_PORT}/tcp

# 启用防火墙
echo "y" | ufw --force enable

echo "[INFO] 防火墙配置完成："
echo "  • 开放端口: 22(SSH), 80(HTTP), 443(HTTPS), 3000, 8445, 8446"
echo "  • VLESS端口: ${VLESS_PORT} (外部可访问)"
echo "  • 本地访问(127.0.0.1): 2095(S-UI), 25500(subconverter)"
echo "  • 禁止外部访问: 2095(S-UI面板)"
echo ""

# 显示防火墙状态
ufw status numbered

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
# 步骤 7：安装 Node.js
# -----------------------------
echo "[7/14] 确保 Node.js 可用"
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
fi

# -----------------------------
# 步骤 8：构建 sub-web-modify 前端
# -----------------------------
echo "[8/14] 构建 sub-web-modify 前端"
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
# 步骤 9：安装 S-UI 面板（修复安装问题）
# -----------------------------
echo "[9/14] 安装 S-UI 面板"
if [ ! -d "/opt/s-ui" ]; then
    echo "[INFO] 开始安装 S-UI 面板..."
    # 下载安装脚本
    wget -O /tmp/s-ui-install.sh https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh
    chmod +x /tmp/s-ui-install.sh
    
    # 检查脚本内容
    if grep -q "#!/bin/bash" /tmp/s-ui-install.sh; then
        echo "[INFO] S-UI 安装脚本下载成功，开始安装..."
        # 设置自动应答
        echo -e "\n\n" | bash /tmp/s-ui-install.sh 2>/dev/null || {
            echo "[WARN] S-UI 自动安装可能有警告，继续执行..."
        }
    else
        echo "[ERROR] S-UI 安装脚本下载失败，尝试备用方法"
        # 备用安装方法
        curl -sSL https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh | bash
    fi
    
    # 检查S-UI是否安装成功
    if [ -d "/opt/s-ui" ]; then
        echo "[INFO] S-UI 面板安装成功"
        # 确保S-UI监听所有地址
        if [ -f "/opt/s-ui/config.json" ]; then
            echo "[INFO] S-UI 配置文件已找到，修复监听地址..."
            # 修改配置文件，确保监听0.0.0.0
            sed -i 's/"address": "127.0.0.1"/"address": "0.0.0.0"/g' /opt/s-ui/config.json 2>/dev/null || true
            sed -i 's/"host": "127.0.0.1"/"host": "0.0.0.0"/g' /opt/s-ui/config.json 2>/dev/null || true
            
            # 检查是否修改成功
            if grep -q '"address": "0.0.0.0"' /opt/s-ui/config.json; then
                echo "[INFO] S-UI 监听地址已设置为 0.0.0.0"
            else
                echo "[WARN] 无法自动修改S-UI配置，可能需要手动修改"
            fi
        else
            echo "[WARN] 未找到S-UI配置文件，尝试创建"
            # 创建基本配置文件
            mkdir -p /opt/s-ui
            cat > /opt/s-ui/config.json <<'EOF'
{
  "address": "0.0.0.0",
  "port": 2095,
  "assets": "/opt/s-ui/assets",
  "database": "/opt/s-ui/database.db",
  "log": "/opt/s-ui/logs",
  "secret": "sui-panel-secret-key-change-me",
  "admin": {
    "username": "admin",
    "password": "admin"
  }
}
EOF
        fi
    else
        echo "[ERROR] S-UI 可能未安装成功，请检查"
        echo "[INFO] 尝试手动安装: bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)"
    fi
fi

# 重启S-UI服务确保配置生效
echo "[INFO] 重启S-UI服务..."
systemctl restart s-ui 2>/dev/null || {
    echo "[WARN] S-UI 服务重启失败，尝试启动..."
    systemctl start s-ui 2>/dev/null || true
}

# 检查S-UI服务状态
sleep 3
if systemctl is-active --quiet s-ui; then
    echo "[INFO] S-UI 服务正在运行"
else
    echo "[WARN] S-UI 服务未运行，尝试修复..."
    # 创建systemd服务文件
    cat >/etc/systemd/system/s-ui.service <<EOF
[Unit]
Description=S-UI Panel Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/s-ui
ExecStart=/opt/s-ui/s-ui
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable s-ui
    systemctl start s-ui
    sleep 2
    
    if systemctl is-active --quiet s-ui; then
        echo "[INFO] S-UI 服务已成功启动"
    else
        echo "[ERROR] S-UI 服务启动失败"
        echo "[INFO] 请手动检查: journalctl -u s-ui --no-pager -n 20"
    fi
fi

# -----------------------------
# 步骤 10：验证S-UI访问
# -----------------------------
echo "[10/14] 验证S-UI访问设置"
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
# 步骤 11：构建现代Web主页（使用npm）
# -----------------------------
echo "[11/14] 构建现代Web主页"
rm -rf /opt/web-home
mkdir -p /opt/web-home/current

# 检查主页仓库是否包含web目录
echo "[INFO] 从GitHub仓库获取主页源码..."
git clone $WEB_HOME_REPO /opt/web-home/source

# 检查是否有package.json，有则使用npm构建
if [ -f "/opt/web-home/source/web/package.json" ]; then
    echo "[INFO] 检测到Node.js项目，使用npm构建"
    cd /opt/web-home/source/web
    
    # 安装依赖
    if command -v npm &> /dev/null; then
        echo "[INFO] 安装npm依赖..."
        npm install --production 2>/dev/null || {
            echo "[WARN] npm安装可能有警告，继续..."
            npm install 2>/dev/null || true
        }
        
        # 如果有build命令，执行构建
        if grep -q '"build"' package.json; then
            echo "[INFO] 执行npm run build..."
            npm run build 2>/dev/null || {
                echo "[WARN] 构建可能失败，尝试直接复制文件"
                cp -r . /opt/web-home/current/
            }
            
            # 如果构建后生成dist目录，使用dist目录
            if [ -d "dist" ]; then
                echo "[INFO] 复制dist目录到目标位置"
                cp -r dist/* /opt/web-home/current/
            elif [ -d "public" ]; then
                echo "[INFO] 复制public目录到目标位置"
                cp -r public/* /opt/web-home/current/
            else
                echo "[INFO] 直接复制所有文件到目标位置"
                cp -r . /opt/web-home/current/
            fi
        else
            # 没有build命令，直接复制文件
            echo "[INFO] 没有build命令，直接复制文件"
            cp -r . /opt/web-home/current/
        fi
    else
        echo "[WARN] npm未找到，直接复制文件"
        cp -r . /opt/web-home/current/
    fi
else
    echo "[INFO] 静态HTML项目，直接复制文件"
    if [ -d "/opt/web-home/source/web" ]; then
        cp -r /opt/web-home/source/web/* /opt/web-home/current/
    else
        cp -r /opt/web-home/source/* /opt/web-home/current/
    fi
fi

# 确保主页有必要的文件
if [ ! -f "/opt/web-home/current/index.html" ]; then
    echo "[WARN] 未找到index.html，创建默认主页"
    cat > /opt/web-home/current/index.html <<'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>VPS Dashboard</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; 
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); 
                height: 100vh; display: flex; align-items: center; justify-content: center; }
        .container { text-align: center; color: white; padding: 2rem; }
        h1 { font-size: 3rem; margin-bottom: 1rem; }
        p { font-size: 1.2rem; opacity: 0.9; margin-bottom: 2rem; }
        .links { display: flex; gap: 1rem; justify-content: center; flex-wrap: wrap; }
        a { color: white; text-decoration: none; background: rgba(255,255,255,0.2); 
            padding: 0.75rem 1.5rem; border-radius: 50px; transition: all 0.3s; }
        a:hover { background: rgba(255,255,255,0.3); transform: translateY(-2px); }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 VPS Dashboard</h1>
        <p>全栈服务管理平台</p>
        <div class="links">
            <a href="/subconvert/">订阅转换</a>
            <a href="/sui/">S-UI面板</a>
            <a href="http://localhost:3000">AdGuard Home</a>
        </div>
    </div>
</body>
</html>
EOF
fi

# 设置正确的文件权限
chown -R www-data:www-data /opt/web-home/current
chmod -R 755 /opt/web-home/current

# 清理源文件
rm -rf /opt/web-home/source

echo "[INFO] 主页文件结构:"
ls -la /opt/web-home/current/

# -----------------------------
# 步骤 12：创建自动更新脚本
# -----------------------------
echo "[12/14] 创建自动更新脚本"
cat > /usr/local/bin/update-web-home.sh <<'EOF'
#!/bin/bash
# Web主页自动更新脚本
# 检查GitHub仓库更新并自动部署

set -e

# 配置
REPO_URL="https://github.com/about300/vps-deployment.git"
TEMP_DIR="/tmp/web-home-update-$(date +%Y%m%d-%H%M%S)"
CURRENT_DIR="/opt/web-home/current"
BACKUP_DIR="/opt/web-home/backup"
LOG_FILE="/var/log/web-home-update.log"
MAX_BACKUPS=5

# 创建日志目录
mkdir -p "$(dirname "$LOG_FILE")"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "开始检查主页更新..."

# 1. 备份当前版本
mkdir -p "$BACKUP_DIR"
BACKUP_NAME="backup-$(date +%Y%m%d-%H%M%S)"
cp -r "$CURRENT_DIR" "$BACKUP_DIR/$BACKUP_NAME" 2>/dev/null || {
    log "警告: 备份当前版本失败"
}

# 清理旧备份，只保留最新的5个
cd "$BACKUP_DIR"
BACKUP_COUNT=$(ls -d backup-* 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
    OLD_BACKUPS=$(ls -d backup-* | sort | head -n $((BACKUP_COUNT - MAX_BACKUPS)))
    for old in $OLD_BACKUPS; do
        rm -rf "$old"
        log "删除旧备份: $old"
    done
fi

# 2. 克隆最新代码
log "从GitHub获取最新代码..."
git clone "$REPO_URL" "$TEMP_DIR" 2>&1 | tee -a "$LOG_FILE"

if [ ! -d "$TEMP_DIR/web" ]; then
    log "错误: 仓库中未找到web目录"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# 3. 检查是否需要构建
BUILD_DIR="$TEMP_DIR/web"
cd "$BUILD_DIR"

if [ -f "package.json" ]; then
    log "检测到Node.js项目，开始构建..."
    
    # 安装依赖
    if command -v npm &> /dev/null; then
        npm install --production 2>&1 | tee -a "$LOG_FILE"
        
        # 检查是否有build命令
        if grep -q '"build"' package.json; then
            log "执行npm run build..."
            npm run build 2>&1 | tee -a "$LOG_FILE"
            
            # 确定构建输出目录
            if [ -d "dist" ]; then
                SOURCE_DIR="dist"
            elif [ -d "public" ]; then
                SOURCE_DIR="public"
            elif [ -d "build" ]; then
                SOURCE_DIR="build"
            else
                SOURCE_DIR="."
            fi
        else
            SOURCE_DIR="."
        fi
    else
        log "警告: npm未找到，使用原始文件"
        SOURCE_DIR="."
    fi
else
    log "静态HTML项目，直接部署"
    SOURCE_DIR="."
fi

# 4. 部署新版本
log "部署新版本..."
rm -rf "$CURRENT_DIR"/*
cp -r "$BUILD_DIR/$SOURCE_DIR"/* "$CURRENT_DIR"/ 2>&1 | tee -a "$LOG_FILE"

# 5. 设置权限
chown -R www-data:www-data "$CURRENT_DIR"
chmod -R 755 "$CURRENT_DIR"

# 6. 检查文件完整性
if [ ! -f "$CURRENT_DIR/index.html" ]; then
    log "错误: 部署后未找到index.html，恢复备份..."
    if [ -d "$BACKUP_DIR/$BACKUP_NAME" ]; then
        rm -rf "$CURRENT_DIR"/*
        cp -r "$BACKUP_DIR/$BACKUP_NAME"/* "$CURRENT_DIR"/
        log "已从备份恢复"
    else
        log "错误: 没有可用的备份"
        exit 1
    fi
fi

# 7. 清理临时文件
rm -rf "$TEMP_DIR"

# 8. 验证Nginx配置并重载
log "验证Nginx配置..."
if nginx -t 2>&1 | tee -a "$LOG_FILE" | grep -q "test is successful"; then
    systemctl reload nginx
    log "Nginx配置重载成功"
else
    log "错误: Nginx配置测试失败"
    # 尝试恢复备份
    if [ -d "$BACKUP_DIR/$BACKUP_NAME" ]; then
        log "尝试恢复备份..."
        rm -rf "$CURRENT_DIR"/*
        cp -r "$BACKUP_DIR/$BACKUP_NAME"/* "$CURRENT_DIR"/
        nginx -t 2>&1 | tee -a "$LOG_FILE" | grep -q "test is successful" && systemctl reload nginx
    fi
fi

# 9. 记录更新完成
log "主页更新完成！"
log "新版本文件数: $(find "$CURRENT_DIR" -type f | wc -l)"
log "当前index.html大小: $(stat -c%s "$CURRENT_DIR/index.html") 字节"

# 10. 发送通知（可选）
# 可以在这里添加发送邮件或Telegram通知的代码

exit 0
EOF

# 设置执行权限
chmod +x /usr/local/bin/update-web-home.sh

# 首次运行更新脚本
echo "[INFO] 首次运行更新脚本..."
/usr/local/bin/update-web-home.sh

# -----------------------------
# 步骤 13：设置定时任务（每3天自动更新）
# -----------------------------
echo "[13/14] 设置定时任务（每3天自动更新）"
# 创建systemd定时服务
cat > /etc/systemd/system/web-home-update.service <<EOF
[Unit]
Description=Web Home Auto Update Service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-web-home.sh
User=root
EOF

cat > /etc/systemd/system/web-home-update.timer <<EOF
[Unit]
Description=Update web home every 3 days
Requires=web-home-update.service

[Timer]
Unit=web-home-update.service
OnCalendar=*-*-1,4,7,10,13,16,19,22,25,28,31 03:00:00
Persistent=true
RandomizedDelaySec=1800

[Install]
WantedBy=timers.target
EOF

# 启用定时器
systemctl daemon-reload
systemctl enable web-home-update.timer
systemctl start web-home-update.timer

# 添加cron任务作为备用
(crontab -l 2>/dev/null; echo "0 3 */3 * * /usr/local/bin/update-web-home.sh >> /var/log/web-home-cron.log 2>&1") | crontab -

echo "[INFO] 定时任务配置完成"
echo "[INFO] 更新日志: /var/log/web-home-update.log"
echo "[INFO] 下次更新: $(systemctl list-timers web-home-update.timer --no-pager | grep web-home-update | head -1)"

# -----------------------------
# 步骤 14：安装 AdGuard Home
# -----------------------------
echo "[14/14] 安装 AdGuard Home"
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
# 步骤 15：配置 Nginx（修复S-UI反代问题 - 重点修改）
# -----------------------------
echo "[15/15] 配置 Nginx（包含博客和主页支持）"
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

    # ========================
    # 博客 - 集成GitHub Pages内容
    # ========================
    location /blog {
        alias /opt/blog;
        index index.html index.htm;
        try_files \$uri \$uri/ \$uri.html =404;
        
        # 缓存静态资源
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|webp|woff|woff2|ttf|eot)$ {
            expires 1y;
            add_header Cache-Control "public, immutable";
        }
        
        # 处理HTML文件
        location ~* \.html$ {
            expires 6h;
            add_header Cache-Control "public, must-revalidate";
        }
        
        # 处理RSS/Atom源
        location ~* \.(xml|rss|atom)$ {
            expires 1h;
            add_header Content-Type "application/xml; charset=utf-8";
        }
    }

    # 博客重定向
    location = /blog {
        return 301 /blog/;
    }

    # ========================
    # 现有功能 - 保持原样
    # ========================

    # 你的 Sub-Web 前端
    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
        
        # 缓存静态资源
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)\$ {
            expires 1y;
            add_header Cache-Control "public, immutable";
        }
    }

    # 原始 SubConverter API
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

    # ========================
    # S-UI 面板反代
    # ========================
    
    # 1. 静态资源代理
    location ~ ^/sui/static/(.*)$ {
        proxy_pass http://127.0.0.1:2095/static/\$1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Prefix /sui;
        
        # 缓存静态资源
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
    
    # 2. API接口代理
    location ~ ^/sui/api/(.*)$ {
        proxy_pass http://127.0.0.1:2095/api/\$1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Prefix /sui;
        
        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # 增加超时时间
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
    
    # 3. S-UI主页面代理（处理应用路由）
    location /sui/ {
        proxy_pass http://127.0.0.1:2095/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Prefix /sui;
        
        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # 修改响应中的HTML，添加base路径
        sub_filter 'href="/' 'href="/sui/';
        sub_filter 'src="/' 'src="/sui/';
        sub_filter 'action="/' 'action="/sui/';
        sub_filter '"/static/' '"/sui/static/';
        sub_filter '"/api/' '"/sui/api/';
        sub_filter_once off;
        
        # 重写重定向
        proxy_redirect / /sui/;
        proxy_redirect /static/ /sui/static/;
        proxy_redirect /api/ /sui/api/;
        
        # 增加超时时间
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
    
    # 4. 处理/sui重定向到/sui/
    location = /sui {
        return 301 /sui/;
    }
    
    # 5. 兼容/app路径（可选）
    location /app/ {
        proxy_pass http://127.0.0.1:2095/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
    
    # 6. 处理其他S-UI相关路径
    location ~ ^/(login|dashboard|inbounds|outbounds|settings|logs|users) {
        return 301 /sui/;
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
echo "[INFO] 测试Nginx配置..."
nginx -t 2>&1 | grep -q "test is successful" && {
    echo "[INFO] Nginx配置测试成功"
    systemctl reload nginx
    echo "[INFO] Nginx已重载配置"
} || {
    echo "[ERROR] Nginx配置测试失败，请检查"
    nginx -t
    exit 1
}

# -----------------------------
# 创建修复S-UI配置的脚本
# -----------------------------
cat > /usr/local/bin/fix-sui-proxy.sh <<'EOF'
#!/bin/bash
# 修复S-UI代理配置脚本
# 用法: fix-sui-proxy.sh [domain]

DOMAIN="${1:-$DOMAIN}"

if [ -z "$DOMAIN" ]; then
    echo "请提供域名参数"
    echo "用法: fix-sui-proxy.sh example.com"
    exit 1
fi

echo "[INFO] 检查S-UI服务状态..."
if systemctl is-active --quiet s-ui; then
    echo "✅ S-UI服务正在运行"
else
    echo "❌ S-UI服务未运行，尝试启动..."
    systemctl start s-ui
    sleep 3
    if systemctl is-active --quiet s-ui; then
        echo "✅ S-UI服务已启动"
    else
        echo "❌ S-UI服务启动失败"
        journalctl -u s-ui --no-pager -n 20
    fi
fi

echo "[INFO] 检查Nginx配置..."
nginx -t 2>&1 | grep -q "test is successful" && {
    echo "✅ Nginx配置正常"
    systemctl reload nginx
    echo "✅ Nginx已重载"
} || {
    echo "❌ Nginx配置有错误"
    nginx -t
}

echo "[INFO] 测试访问..."
echo "1. 测试直接访问S-UI:"
curl -s -o /dev/null -w "HTTP状态码: %{http_code}\n" http://127.0.0.1:2095/

echo "2. 测试反向代理访问:"
curl -s -o /dev/null -w "HTTP状态码: %{http_code}\n" https://$DOMAIN/sui/

echo ""
echo "🔧 访问地址:"
echo "  • https://$DOMAIN/sui/  (主路径)"
echo "  • https://$DOMAIN/app/  (兼容路径)"
echo "  • http://127.0.0.1:2095/  (直接访问)"
EOF

chmod +x /usr/local/bin/fix-sui-proxy.sh

# 创建手动更新命令别名
cat > /usr/local/bin/update-home <<'EOF'
#!/bin/bash
echo "开始手动更新Web主页..."
/usr/local/bin/update-web-home.sh
EOF
chmod +x /usr/local/bin/update-home

# -----------------------------
# VLESS 端口验证
# -----------------------------
echo ""
echo "====================================="
echo "🔧 VLESS 端口配置"
echo "====================================="
echo ""
echo "VLESS 端口已配置: ${VLESS_PORT}"
echo ""
echo "在 S-UI 面板中配置 VLESS 入站节点："
echo ""
echo "1. 登录 S-UI 面板："
echo "   - 通过域名: https://$DOMAIN/sui/"
echo "   - 或直接访问: http://服务器IP:2095/"
echo "   - 通过SSH隧道: ssh -L 8080:127.0.0.1:2095 root@$DOMAIN"
echo "     然后访问: http://localhost:8080/"
echo ""
echo "2. 添加入站节点："
echo "   点击左侧菜单 '入站管理' -> '添加入站'"
echo ""
echo "3. 配置 VLESS："
echo "   - 类型: VLESS"
echo "   - 地址: 0.0.0.0"
echo "   - 端口: ${VLESS_PORT}"
echo "   - 传输协议: 根据需要选择 (tcp, ws, grpc 等)"
echo "   - 流控: 根据需要选择 (none, xtls-rprx-vision, reality 等)"
echo ""
echo "4. 客户端连接信息："
echo "   - 地址: $DOMAIN"
echo "   - 端口: ${VLESS_PORT}"
echo "   - 用户ID: [在S-UI中生成的UUID]"
echo ""

# -----------------------------
# 验证部署
# -----------------------------
verify_deployment() {
    echo ""
    echo "🔍 验证部署状态..."
    echo "====================================="
    
    # 检查服务状态
    echo "1. 检查关键服务状态:"
    local services=("nginx" "subconverter" "s-ui")
    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc"; then
            echo "   ✅ $svc 运行正常"
        else
            echo "   ❌ $svc 未运行"
        fi
    done
    
    # 检查自动更新定时器
    echo ""
    echo "2. 检查自动更新定时器:"
    if systemctl is-active --quiet web-home-update.timer; then
        echo "   ✅ 自动更新定时器已启用"
        echo "   📅 下次更新时间:"
        systemctl list-timers web-home-update.timer --no-pager | grep web-home-update
    else
        echo "   ❌ 自动更新定时器未启用"
    fi
    
    echo ""
    echo "3. 检查防火墙状态:"
    echo "   - 开放端口 (外部访问):"
    local external_ports=("22" "80" "443" "3000" "8445" "8446" "${VLESS_PORT}")
    for port in "${external_ports[@]}"; do
        if ufw status | grep -q "$port.*ALLOW"; then
            echo "     ✅ 端口 $port 已开放"
        else
            echo "     ⚠️  端口 $port 未开放"
        fi
    done
    
    echo "   - 本地访问端口 (仅127.0.0.1):"
    local local_ports=("2095" "25500")
    for port in "${local_ports[@]}"; do
        if ufw status | grep -q "$port.*127.0.0.1"; then
            echo "     ✅ 端口 $port 允许本地访问"
        else
            echo "     ⚠️  端口 $port 可能不允许本地访问"
        fi
    done
    
    echo ""
    echo "4. 网络连接测试:"
    echo "   - Nginx HTTPS: curl -I https://$DOMAIN (等待5秒)..."
    sleep 5
    if curl -s -o /dev/null -w "%{http_code}" https://$DOMAIN --max-time 10 | grep -q "200\|301\|302"; then
        echo "     ✅ Nginx HTTPS 访问正常"
    else
        echo "     ⚠️  Nginx HTTPS 可能有问题"
    fi
    
    echo "   - Sub-Web前端: curl -I https://$DOMAIN/subconvert/..."
    if curl -s -o /dev/null -w "%{http_code}" https://$DOMAIN/subconvert/ --max-time 10 | grep -q "200\|301\|302"; then
        echo "     ✅ Sub-Web前端 访问正常"
    else
        echo "     ⚠️  Sub-Web前端 可能有问题"
    fi
    
    echo "   - S-UI面板反代: curl -I https://$DOMAIN/sui/..."
    SUI_STATUS=$(curl -s -o /dev/null -w "%{http_code}" https://$DOMAIN/sui/ --max-time 10)
    if echo "$SUI_STATUS" | grep -q "200\|301\|302"; then
        echo "     ✅ S-UI面板反代 访问正常 (HTTP状态码: $SUI_STATUS)"
    else
        echo "     ⚠️  S-UI面板反代 可能有问题 (HTTP状态码: $SUI_STATUS)"
        echo "     尝试直接访问S-UI: curl -I http://127.0.0.1:2095/"
    fi
    
    echo ""
    echo "5. SSL证书检查:"
    if [ -f "/etc/nginx/ssl/$DOMAIN/fullchain.pem" ]; then
        echo "   ✅ SSL证书已安装"
        echo "     证书路径: /etc/nginx/ssl/$DOMAIN/"
    else
        echo "   ❌ SSL证书未找到"
    fi
    
    echo ""
    echo "6. S-UI服务检查:"
    if curl -s http://127.0.0.1:2095 --max-time 5 > /dev/null; then
        echo "   ✅ S-UI服务运行正常 (127.0.0.1:2095)"
    else
        echo "   ⚠️  S-UI服务可能有问题"
        echo "   [调试] 检查S-UI日志: journalctl -u s-ui --no-pager -n 10"
    fi
    
    echo ""
    echo "7. 端口监听检查:"
    echo "   - Nginx (443):"
    if netstat -tlnp | grep -q ":443 "; then
        echo "     ✅ 443端口正在监听"
    else
        echo "     ❌ 443端口未监听"
    fi
    
    echo "   - S-UI (2095):"
    if netstat -tlnp | grep -q ":2095 "; then
        echo "     ✅ 2095端口正在监听"
    else
        echo "     ❌ 2095端口未监听"
    fi
    
    echo "   - SubConverter (25500):"
    if netstat -tlnp | grep -q ":25500 "; then
        echo "     ✅ 25500端口正在监听"
    else
        echo "     ❌ 25500端口未监听"
    fi
    
    echo ""
    echo "8. Web主页检查:"
    if [ -f "/opt/web-home/current/index.html" ]; then
        echo "   ✅ 主页文件存在"
        echo "   📁 文件数量: $(find /opt/web-home/current -type f | wc -l)"
    else
        echo "   ❌ 主页文件未找到"
    fi
    
    echo ""
    echo "9. 管理命令检查:"
    echo "   ✅ 修复脚本: /usr/local/bin/fix-sui-proxy.sh"
    echo "   ✅ 自动更新: /usr/local/bin/update-web-home.sh"
    echo "   ✅ 手动更新: update-home"
    echo "   📝 用法: fix-sui-proxy.sh $DOMAIN"
}

# 执行验证
sleep 5
verify_deployment

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
echo "  🌐 主页面:              https://$DOMAIN"
echo "  🔧 Sub-Web前端:         https://$DOMAIN/subconvert/"
echo "  ⚙️  原始后端API:         https://$DOMAIN/sub/api/"
echo "  📊 S-UI面板(通过域名):  https://$DOMAIN/sui/"
echo "  📊 S-UI面板(直接访问):  http://服务器IP:2095/"
echo "  📊 S-UI面板(SSH隧道):  先运行: ssh -L 8080:127.0.0.1:2095 root@$DOMAIN"
echo "                          然后访问: http://localhost:8080/"
echo ""
echo "  🛡️  AdGuard Home:"
echo "     - Web界面:          http://$DOMAIN:3000/"
echo "     - 管理端口1:        https://$DOMAIN:8445/"
echo "     - 管理端口2:        http://$DOMAIN:8446/"
echo ""
echo "🔐 证书路径:"
echo "  • 证书文件: /etc/nginx/ssl/$DOMAIN/fullchain.pem"
echo "  • 私钥文件: /etc/nginx/ssl/$DOMAIN/key.pem"
echo ""
echo "🔧 VLESS 配置:"
echo "  • 端口: ${VLESS_PORT} (已在防火墙开放)"
echo "  • 域名: $DOMAIN"
echo "  • 注意: 请在S-UI面板中配置VLESS入站节点"
echo ""
echo "⚙️  SubConverter 配置:"
echo "  • 配置文件: /opt/subconverter/subconverter.env"
echo "  • 管理密码: admin123"
echo "  • API地址: https://$DOMAIN/sub/api/"
echo ""
echo "🔄 自动更新系统:"
echo "  • 更新脚本: /usr/local/bin/update-web-home.sh"
echo "  • 日志文件: /var/log/web-home-update.log"
echo "  • 备份目录: /opt/web-home/backup/"
echo "  • 更新频率: 每3天自动更新"
echo "  • 手动更新: 运行 'update-home' 命令"
echo ""
echo "🛠️ 管理命令:"
echo "  • 查看 S-UI 日志: journalctl -u s-ui -f"
echo "  • 查看 subconverter 日志: journalctl -u subconverter -f"
echo "  • 重启 Nginx: systemctl reload nginx"
echo "  • 验证Nginx配置: nginx -t"
echo "  • 防火墙状态: ufw status verbose"
echo "  • 端口监听状态: netstat -tlnp"
echo "  • 修复S-UI代理: fix-sui-proxy.sh $DOMAIN"
echo "  • 手动更新主页: update-home"
echo ""
echo "📊 自动更新状态:"
echo "  • 定时器状态: systemctl status web-home-update.timer"
echo "  • 下次更新: systemctl list-timers web-home-update.timer"
echo "  • 查看日志: tail -f /var/log/web-home-update.log"
echo ""
echo "🔒 安全配置确认:"
echo "  ✅ 2095端口允许本地访问 (支持SSH隧道)"
echo "  ✅ 2095端口禁止外部直接访问"
echo "  ✅ VLESS端口(${VLESS_PORT})已开放"
echo "  ✅ 自动更新系统已配置"
echo ""
echo "⚠️  重要提醒:"
echo "  1. 立即登录S-UI修改默认密码"
echo "  2. 在S-UI中配置VLESS入站节点，使用端口 ${VLESS_PORT}"
echo "  3. S-UI反代路径: https://$DOMAIN/sui/"
echo "  4. 如果反代有问题，可直接访问: http://服务器IP:2095/"
echo "  5. 使用修复脚本: fix-sui-proxy.sh $DOMAIN"
echo "  6. Web主页每3天自动从GitHub更新"
echo "  7. 如需立即更新，运行: update-home"
echo "  8. 定期更新系统和软件"
echo "  9. 备份证书文件: /etc/nginx/ssl/$DOMAIN/"
echo ""
echo "====================================="
echo "脚本版本: v${SCRIPT_VERSION} (带自动更新)"
echo "部署时间: $(date)"
echo "====================================="

# 最后提示
echo ""
echo "🔧 快速修复命令（如果访问有问题）:"
echo "  sudo /usr/local/bin/fix-sui-proxy.sh $DOMAIN"
echo ""
echo "🔄 手动更新主页:"
echo "  sudo update-home"
echo ""
echo "🌐 访问测试:"
echo "  curl -I https://$DOMAIN/sui/"
echo ""