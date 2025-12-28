#!/usr/bin/env bash
set -euo pipefail

# install.sh - Scheme 3: nginx HTTP + stream reverse proxy to S-UI backend (no xray install)
# Usage: sudo bash install.sh

echo "======================================"
echo " 一键部署：Nginx (stream) + sub-web-modify + SubConverter + S-UI (后台节点由 S-UI 管理)"
echo " 方案说明：主站由 nginx 在 4443 终止 TLS；VLESS/Reality 的 TLS（SNI 匹配）由 nginx stream 转发到 S-UI 后端端口"
echo "======================================"

read -rp "输入主页主域名（例如 web.mycloudshare.org）： " DOMAIN
read -rp "输入用于 VLESS/Reality 的子域名（SNI，例如 vless.web.mycloudshare.org）： " VLESS_SNI
read -rp "输入 S-UI 后端监听端口（例如 4431）： " SUI_NODE_PORT
SUI_NODE_PORT=${SUI_NODE_PORT:-4431}
read -rp "Cloudflare API Token（用于 acme.sh DNS-01；如不使用请回车跳过）: " CF_TOKEN
read -rp "Cloudflare 邮箱 (acme.sh 注册用, 可留空): " CF_EMAIL

export CF_Token="$CF_TOKEN"
export CF_Email="$CF_EMAIL"

if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 或 sudo 运行此脚本"
  exit 1
fi

echo
echo "[0] 先检查系统并提示（请确保 DNS 已将 $DOMAIN 和 $VLESS_SNI 指向本服务器 IP）"
echo "    并请在 Cloudflare 将用于 VLESS 的记录设置为灰云（DNS-only）"
read -rp "确认继续请回车（取消用 Ctrl+C）: " _

echo "[1/10] 更新并安装基础依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw build-essential ca-certificates lsb-release gnupg2 apt-transport-https uuid-runtime nodejs npm

echo "[2/10] 配置防火墙（放行常用端口）"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000   # AdGuard Web UI
ufw allow 2550   # SubConverter
ufw --force enable || true

echo "[3/10] 安装 acme.sh（用于网站证书，Cloudflare DNS-01）"
if [ ! -d "/root/.acme.sh" ]; then
  curl https://get.acme.sh | sh -s email="$CF_Email"
fi
export PATH="$HOME/.acme.sh:$PATH"
source ~/.bashrc 2>/dev/null || true
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt || true

mkdir -p /etc/nginx/ssl

if [ -n "$CF_TOKEN" ]; then
  echo "[3.1] 使用 Cloudflare DNS-01 为 $DOMAIN 申请证书"
  export CF_Token
  ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --force
  ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/nginx/ssl/key.pem \
    --fullchain-file /etc/nginx/ssl/cert.pem
else
  echo "[3.1] 未提供 Cloudflare Token，跳过自动申请证书。请稍后手动放置 cert/key 到 /etc/nginx/ssl"
fi

echo "[4/10] 安装官方 nginx.org（确保包含 stream 模块）"
# 移除可能已安装但不带 stream 的 nginx
apt remove -y nginx nginx-core nginx-common nginx-full nginx-extras || true
apt autoremove -y || true

# 添加 nginx.org 仓库并安装
curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
  | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null

echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" \
  > /etc/apt/sources.list.d/nginx.list

cat >/etc/apt/preferences.d/99nginx <<'EOF'
Package: *
Pin: origin nginx.org
Pin-Priority: 900
EOF

apt update
apt install -y nginx

# 验证 nginx 支持 stream
if nginx -V 2>&1 | grep -q -- '--with-stream'; then
  echo "[OK] nginx 二进制包含 --with-stream"
else
  echo "[ERROR] nginx 不包含 stream 模块，无法继续。请手动安装带 stream 的 nginx 后重跑脚本。"
  nginx -V 2>&1 || true
  exit 1
fi

echo "[5/10] 安装 SubConverter"
mkdir -p /opt/subconverter
if [ ! -f /opt/subconverter/subconverter ]; then
  cd /opt/subconverter || true
  wget -O /opt/subconverter/subconverter https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter || true
  chmod +x /opt/subconverter/subconverter || true
fi

cat >/etc/systemd/system/subconverter.service <<'EOF'
[Unit]
Description=SubConverter
After=network.target
[Service]
ExecStart=/opt/subconverter/subconverter
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter || true

echo "[6/10] 部署 sub-web-modify（主页）"
rm -rf /opt/sub-web-modify || true
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify || true
cd /opt/sub-web-modify || true
# 安装依赖并构建（npm 可能较慢）
npm install --no-audit --no-fund || true
npm run build || true

echo "[7/10] 安装/确认 S-UI（面板 & 后端）"
if ! command -v s-ui >/dev/null 2>&1; then
  bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh) || true
else
  echo "[info] 检测到 s-ui 已安装，跳过安装"
fi

echo "[8/10] 安装 AdGuard Home（可选，若已安装则跳过）"
if [ ! -d /opt/AdGuardHome ]; then
  curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh || true
fi

echo "[9/10] 备份并写入 nginx 配置 (stream + http)"
# 备份旧配置
backup_dir="/root/nginx_backup_$(date +%s)"
mkdir -p "$backup_dir"
cp -r /etc/nginx "$backup_dir" || true
echo "[info] 备份旧 /etc/nginx 到 $backup_dir"

# 删除默认站点以避免抢占
rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf || true

# 写入新的 nginx.conf（变量会被展开）
cat >/etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
events { worker_connections 10240; }

stream {
    # 根据 TLS ClientHello 的 SNI 做分流
    map \$ssl_preread_server_name \$backend {
        $VLESS_SNI 127.0.0.1:$SUI_NODE_PORT;
        default    127.0.0.1:4443;
    }

    server {
        listen 443 reuseport;
        proxy_pass \$backend;
        ssl_preread on;
    }
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile on;

    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log warn;

    server {
        listen 80;
        server_name $DOMAIN;
        return 301 https://\$host\$request_uri;
    }

    server {
        listen 4443 ssl http2;
        server_name $DOMAIN;

        ssl_certificate     /etc/nginx/ssl/cert.pem;
        ssl_certificate_key /etc/nginx/ssl/key.pem;

        root /opt/sub-web-modify/dist;
        index index.html;

        location / {
            try_files \$uri \$uri/ /index.html;
        }

        location /sub/api/ {
            proxy_pass http://127.0.0.1:2550/;
            proxy_set_header Host \$host;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Real-IP \$remote_addr;
        }
    }
}
EOF

# 测试并重启 nginx
nginx -t
systemctl restart nginx || true

echo "[10/10] 完成并提示后续步骤"

cat <<EOF

部署完成 ✅

说明摘要：
- Nginx 已配置为在 TCP 层根据 SNI 做分流：
    * 若 ClientHello 的 SNI = $VLESS_SNI -> 转发到本机 127.0.0.1:$SUI_NODE_PORT（请在 S-UI 中确保节点/后端监听该端口）
    * 其它 SNI -> 回落到 127.0.0.1:4443，由 nginx 在本机 4443 上终止 TLS 并提供网站（https://$DOMAIN）

重要后续操作（请务必完成）：
1) 在 Cloudflare 中确保：
   - $DOMAIN 与 $VLESS_SNI 指向你服务器 IP（A 记录）
   - 对用于 VLESS 的 DNS 记录（$VLESS_SNI）设置为灰云（DNS-only）

2) 在 S-UI 面板中为节点/服务：
   - 节点监听地址/端口设置为 127.0.0.1:$SUI_NODE_PORT（或让 S-UI 的后端把服务监听到本机该端口）
   - 节点的客户端配置：address = $DOMAIN, port = 443, ServerName(SNI) = $VLESS_SNI，security = reality（或你当前使用的协议）
   - S-UI 会生成 privateKey/shortId，服务端（S-UI）与客户端需互相匹配（S-UI 管理面板会处理）

3) 证书：
   - 脚本若能使用 Cloudflare Token 已为 $DOMAIN 自动申请并安装到 /etc/nginx/ssl
   - 若你跳过了 Cloudflare token，请手动把 cert/key 放到 /etc/nginx/ssl/cert.pem 和 /etc/nginx/ssl/key.pem

测试命令：
    nginx -V | grep -- '--with-stream'
    nginx -t
    ss -lnpt | grep :$SUI_NODE_PORT
    ss -lnpt | grep :443
    # 测试网页 SNI (应展示证书信息)
    openssl s_client -connect $(curl -s ipv4.icanhazip.com):443 -servername $DOMAIN -tls1_3
    # 测试 VLESS SNI (会被转发到 S-UI 后端)
    openssl s_client -connect $(curl -s ipv4.icanhazip.com):443 -servername $VLESS_SNI -tls1_3

如果浏览器访问 https://$DOMAIN 无法打开或只显示 nginx 默认页：
  - 检查 /var/log/nginx/error.log 查看具体错误
  - 确认 /etc/nginx/ssl/cert.pem 和 key.pem 存在且权限正确
  - 确认 sub-web-modify 的构建输出位于 /opt/sub-web-modify/dist

若 VLESS 客户端连不上：
  - 确认 S-UI 后端在 127.0.0.1:$SUI_NODE_PORT 监听（ss -lnpt）
  - 确认 S-UI 节点配置的 ServerName 与 VLESS_SNI 一致
  - 确认 Cloudflare 对 $VLESS_SNI 为灰云（DNS-only）

需要我再做的：
- 我可以把脚本改为非交互版（把 DOMAIN / VLESS_SNI / SUI_NODE_PORT / CF_TOKEN 直接写死），你把值发给我我生成；
- 或者你把 `nginx -T` 输出贴来，我帮你快速定位并修复出现的问题。

EOF
