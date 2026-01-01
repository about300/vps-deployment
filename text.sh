#!/usr/bin/env bash
set -e
echo "===== VPS 全栈部署（最终版） ====="

# -----------------------------
# 步骤 0：预定义变量
# -----------------------------
read -rp "请输入您的域名 (例如：web.mycloudshare.org): " DOMAIN
read -rp "请输入 Cloudflare 邮箱: " CF_Email
read -rp "请输入 Cloudflare API Token: " CF_Token
export CF_Email
export CF_Token

# VLESS 默认端口
VLESS_PORT=5000

# SubConverter 二进制下载链接
SUBCONVERTER_BIN="https://github.com/about300/vps-deployment/raw/refs/heads/main/bin/subconverter"

# Web主页GitHub仓库
WEB_HOME_REPO="https://github.com/about300/vps-deployment.git"

# -----------------------------
# 步骤 1：更新系统与依赖
# -----------------------------
echo "[1/12] 更新系统与安装依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx build-essential python3 python-is-python3 npm

# -----------------------------
# 步骤 2：防火墙配置
# -----------------------------
echo "[2/12] 配置防火墙"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000   # AdGuard Home 反代端口
ufw allow 8445   # 本地 DoH 备用
ufw allow 8446   # 本地 DoH 备用
ufw allow 5000   # VLESS
ufw allow 25500  # SubConverter API
ufw allow 2095   # S-UI 面板
ufw --force enable

# -----------------------------
# 步骤 3：安装 acme.sh
# -----------------------------
echo "[3/12] 安装 acme.sh（DNS-01）"
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
echo "[4/12] 申请或检查 SSL 证书"
if [ ! -f "/etc/nginx/ssl/$DOMAIN/fullchain.pem" ]; then
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
else
    echo "[INFO] SSL 证书已存在，跳过申请"
fi

# -----------------------------
# 步骤 5：安装证书到 Nginx
# -----------------------------
echo "[5/12] 安装证书到 Nginx"
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/nginx/ssl/$DOMAIN/key.pem \
    --fullchain-file /etc/nginx/ssl/$DOMAIN/fullchain.pem \
    --reloadcmd "systemctl reload nginx"

# -----------------------------
# 步骤 6：安装 SubConverter 后端
# -----------------------------
echo "[6/12] 安装 SubConverter"
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
# 步骤 6.1：配置 pref.toml 启用 filter/sort
# -----------------------------
mkdir -p /opt/subconverter/profiles/filter /opt/subconverter/profiles/script
cat >/opt/subconverter/pref.toml <<EOF
enable_filter = true
filter_script = "profiles/filter/filter.js"
sort_flag = true
sort_script = "profiles/script/sort.js"
EOF

# -----------------------------
# 步骤 7：安装 Node.js（已安装 npm 可跳过）
# -----------------------------
echo "[7/12] 确保 Node.js 可用"
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
fi

# -----------------------------
# 步骤 8：构建 sub-web-modify 前端（含自定义 .env）
# -----------------------------
echo "[8/12] 构建 sub-web-modify 前端"
rm -rf /opt/sub-web-modify
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify

# 写入自定义 .env
cat > .env <<'EOF'
VUE_APP_PROJECT="https://github.com/youshandefeiyang/sub-web-modify"
VUE_APP_BOT_LINK="https://t.me/feiyangdigital"
VUE_APP_BILIBILI_LINK="https://space.bilibili.com/138129883"
VUE_APP_YOUTUBE_LINK="https://youtube.com/channel/UCKHJ2UPlkNsDRj1cVXi0UsA"
VUE_APP_BASIC_VIDEO="https://www.youtube.com/watch?v=C4WV4223uYw"
VUE_APP_ADVANCED_VIDEO="https://www.youtube.com/watch?v=cHs-J2P5CT0"
VUE_APP_SCRIPT_CONFIG="https://github.com/tindy2013/subconverter/blob/a24cb7c00a7e5a71ef2e6c0d64d84d91bc7a21d6/README-cn.md?plain=1#L703-L719"
VUE_APP_FILTER_CONFIG="https://github.com/tindy2013/subconverter/blob/a24cb7c00a7e5a71ef2e6c0d64d84d91bc7a21d6/README-cn.md?plain=1#L514-L531"
VUE_APP_SUBCONVERTER_REMOTE_CONFIG="https://subconverter.oss-ap-southeast-1.aliyuncs.com/Rules/RemoteConfig/universal/urltest.ini"
VUE_APP_SUBCONVERTER_DEFAULT_BACKEND="/sub/api/sub"
VUE_APP_MYURLS_DEFAULT_BACKEND="/sub/api/short"
VUE_APP_CONFIG_UPLOAD_BACKEND="/sub/api/upload"
EOF

# 设置 publicPath 为 /subconvert/
cat > vue.config.js <<'EOF'
module.exports = { publicPath: '/subconvert/' }
EOF

npm install
npm run build

# -----------------------------
# 步骤 9：安装 S-UI 面板
# -----------------------------
echo "[9/12] 安装 S-UI 面板（本地监听）"
if [ ! -d "/opt/s-ui" ]; then
    bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
fi

# -----------------------------
# 步骤 10：Web 主页（自动更新机制）
# -----------------------------
echo "[10/12] 配置 Web 主页"
rm -rf /opt/web-home
mkdir -p /opt/web-home
git clone $WEB_HOME_REPO /opt/web-home/tmp
mv /opt/web-home/tmp/web /opt/web-home/current
rm -rf /opt/web-home/tmp

# -----------------------------
# 步骤 11：安装 AdGuard Home
# -----------------------------
echo "[11/12] 安装 AdGuard Home"
if [ ! -d "/opt/AdGuardHome" ]; then
    curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh
fi

# -----------------------------
# 步骤 12：配置 Nginx
# -----------------------------
echo "[12/12] 配置 Nginx"
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    # Web主页
    root /opt/web-home/current;
    index index.html;
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # SubConverter 前端
    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    # SubConverter API
    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }

    # VLESS 订阅
    location /vless/ {
        proxy_pass http://127.0.0.1:$VLESS_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }

    # AdGuard Home 反代
    location /adguard/ {
        proxy_pass http://127.0.0.1:3000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t
systemctl reload nginx

# -----------------------------
# 完成
# -----------------------------
echo "====================================="
echo "部署完成 🎉"
echo "Web主页: https://$DOMAIN"
echo "SubConverter 前端: https://$DOMAIN/subconvert/"
echo "SubConverter API: https://$DOMAIN/sub/api/"
echo "S-UI 面板: http://127.0.0.1:2095"
echo "AdGuard Home: https://$DOMAIN/adguard/  (本地端口 3000/8445/8446 可用)"
echo "====================================="
