#!/usr/bin/env bash
set -euo pipefail

echo "====================================================="
echo " 一键部署：Nginx stream SNI 分流（同域名共用 443），S-UI 管理节点（不安装 xray）"
echo " 说明：主页由 nginx 在本地 4443 终止 TLS，VLESS/Reality 的 SNI 被 stream 分发到 S-UI 后端监听端口"
echo "====================================================="

read -rp "主页主域名（例如 web.mycloudshare.org）: " DOMAIN
read -rp "用于 VLESS/Reality 的 SNI（例如 vless.web.mycloudshare.org）: " VLESS_SNI
read -rp "S-UI 后端在本机监听的端口（S-UI 节点会监听这个端口，默认 4431）: " SUI_NODE_PORT
SUI_NODE_PORT=${SUI_NODE_PORT:-4431}
read -rp "Cloudflare API Token（用于 acme.sh DNS-01；若不使用可留空并手动上证书）: " CF_TOKEN
read -rp "Cloudflare 邮箱（acme.sh 注册用，可留空）: " CF_EMAIL

export CF_Token="$CF_TOKEN"
export CF_Email="$CF_EMAIL"

if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 或 sudo 运行此脚本"
  exit 1
fi

echo "[1/10] 安装基础依赖"
apt update -y
apt install -y curl wget git unzip socat cron ufw build-essential ca-certificates lsb-release gnupg2 apt-transport-https uuid-runtime nodejs npm

echo "[2/10] 配置防火墙（放通常用端口）"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000   # AdGuard Web UI
ufw allow 2550   # SubConverter
ufw --force enable || true

echo "[3/10] 安装 acme.sh（用于主域证书，Cloudflare DNS-01）"
if [ ! -d "/root/.acme.sh" ]; then
  curl https://get.acme.sh | sh -s email="$CF_Email"
fi
export PATH="$HOME/.acme.sh:$PATH"
source ~/.bashrc 2>/dev/null || true
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt || true

mkdir -p /etc/nginx/ssl

echo "[4/10] 为主域 $DOMAIN 申请证书（DNS-01 Cloudflare）"
if [ -n "$CF_Token" ]; then
  export CF_Token
  ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" --force
  ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file /etc/nginx/ssl/key.pem \
    --fullchain-file /etc/nginx/ssl/cert.pem
else
  echo "[warn] 未提供 Cloudflare Token，跳过自动申请证书。请手动准备 /etc/nginx/ssl/cert.pem & key.pem。"
fi

echo "[5/10] 安装官方 nginx.org（确保带 --with-stream）"
apt remove -y nginx nginx-core nginx-common nginx-full nginx-extras || true
apt autoremove -y || true

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

if nginx -V 2>&1 | grep -q -- '--with-stream'; then
  echo "[OK] nginx 支持 stream 模块"
else
  echo "[ERROR] nginx 未包含 stream 模块，stream 配置将失败。请安装带 stream 的 nginx（脚本退出）"
  nginx -V 2>&1 || true
  exit 1
fi

echo "[6/10] 安装 SubConverter（本地）"
mkdir -p /opt/subconverter
if [ ! -f /opt/subconverter/subconverter ]; then
  cd /opt/subconverter
  wget -O subconverter https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter || true
  chmod +x subconverter || true
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

echo "[7/10] 部署 sub-web-modify（主页）"
rm -rf /opt/sub-web-modify || true
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify || true
cd /opt/sub-web-modify || true
npm install --no-audit --no-fund || true
npm run build || true

echo "[8/10] 安装 S-UI（如果尚未安装）"
if ! command -v s-ui >/dev/null 2>&1; then
  bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh) || true
else
  echo "[info] 已检测到 s-ui，跳过安装"
fi

echo "[9/10] （可选）安装 AdGuard Home"
if [ ! -d /opt/AdGuardHome ]; then
  curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh || true
fi

echo "[10/10] 写入 nginx 配置（stream + http），并重启 nginx"
cat >/etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
events { worker_connections 1024; }

stream {
    # 根据 TLS ClientHello 的 SNI 字段做分流
    map \$ssl_preread_server_name \$backend {
        # VLESS/Reality 的 SNI -> 转到 S-UI 后端监听端口（本地）
        $VLESS_SNI 127.0.0.1:$SUI_NODE_PORT;
        # 默认（主页访问）-> 转到本地 nginx https 端口 4443，由 nginx 终止 TLS
        default      127.0.0.1:4443;
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

        # SubConverter 的 API（订阅转换）
        location /sub/api/ {
            proxy_pass http://127.0.0.1:2550/;
            proxy_set_header Host \$host;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Real-IP \$remote_addr;
        }
    }
}
EOF

nginx -t
systemctl restart nginx || true

echo "====================================================="
echo "完成：nginx 已配置为 443 层基于 SNI 分流"
echo "规则说明："
echo "  - 如果 TLS ClientHello 的 SNI = $VLESS_SNI ，流量被转发到本机端口 $SUI_NODE_PORT（请在 S-UI 中确保节点监听该端口）"
echo "  - 否则（默认）流量被转发到本机 4443，由 nginx 终止 TLS 并提供主页和 /sub/api"
echo ""
echo "你还需要在 S-UI 面板里："
echo "  1) 为节点设置 'Address' 或 'Host' 为 $DOMAIN，Port 填 443（客户端连接目标）"
echo "  2) 在节点配置里将 'ServerName' / SNI 填为 $VLESS_SNI（S-UI 允许自定义 SNI）"
echo "  3) 在 S-UI 的节点/服务端设置中把该节点的监听端口设为 $SUI_NODE_PORT（即 S-UI 在本机应把该节点服务监听到 127.0.0.1:$SUI_NODE_PORT）"
echo "  4) 确保 $DOMAIN 与 $VLESS_SNI 的 DNS 都解析到你服务器 IP，并在 Cloudflare 中将用于 Reality 的记录设为灰云（DNS-only）"
echo ""
echo "测试建议："
echo "  - nginx -V | grep -- '--with-stream'   # 确认 nginx 包含 stream 模块"
echo "  - nginx -t                              # 检查 nginx 配置"
echo "  - ss -lnpt | grep $SUI_NODE_PORT        # 确认 S-UI 后端已在本机监听该端口"
echo "  - openssl s_client -connect $(curl -s ipv4.icanhazip.com):443 -servername $DOMAIN -tls1_3"
echo "  - openssl s_client -connect $(curl -s ipv4.icanhazip.com):443 -servername $VLESS_SNI -tls1_3"
echo ""
echo "说明：对第一个 openssl 测试，你应看到常规 HTTPS/证书信息（表示 nginx 被正确回落）；"
echo "对第二个测试，Reality 握手是特殊的，输出可能不是标准证书链，但若连接被转发到 S-UI 后端就表示分流生效。"
echo ""
echo "如果 S-UI 已托管节点并监听正确端口，客户端（例如 v2rayN / S-UI 导出的配置）填写："
echo "  address: $DOMAIN"
echo "  port: 443"
echo "  security: reality (或你在 S-UI 中选择的协议)"
echo "  serverName (SNI): $VLESS_SNI"
echo ""
echo "有问题把 nginx -T 输出贴上来我可以帮你检查。"
echo "====================================================="
