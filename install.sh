#!/usr/bin/env bash
set -e

echo "========================================"
echo " Ubuntu 24.04 最终稳定 install.sh"
echo " - Nginx (http + stream, 共用 443)"
echo " - Let's Encrypt (acme.sh, DNS-01)"
echo " - Cloudflare API"
echo " - 可重复执行"
echo "========================================"

### ====== 交互输入 ======
read -rp "请输入主域名（如 money.mycloudshare.org）: " DOMAIN
read -rp "请输入 Cloudflare 邮箱: " CF_Email
read -rp "请输入 Cloudflare API Token: " CF_Token

export CF_Email
export CF_Token

### ====== 基础环境 ======
echo "[1/10] 更新系统 & 安装基础依赖..."
apt update -y
apt install -y curl wget git socat cron ufw ca-certificates lsb-release gnupg

### ====== 防火墙 ======
echo "[2/10] 配置防火墙..."
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 2550
ufw allow 53
ufw allow 8445
ufw allow 8380
ufw allow 50913
ufw allow 6220
ufw allow 62203
ufw --force enable

### ====== 安装 Nginx 官方版（带 stream） ======
if ! command -v nginx >/dev/null; then
  echo "[3/10] 安装 Nginx 官方仓库版本..."
  curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx.gpg
  echo "deb [signed-by=/usr/share/keyrings/nginx.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" \
    > /etc/apt/sources.list.d/nginx.list
  apt update -y
  apt install -y nginx
else
  echo "[3/10] Nginx 已存在，跳过"
fi

### ====== 安装 acme.sh ======
if [ ! -d "/root/.acme.sh" ]; then
  echo "[4/10] 安装 acme.sh..."
  curl https://get.acme.sh | sh
else
  echo "[4/10] acme.sh 已存在，跳过"
fi

### ====== 永久锁定 Let's Encrypt ======
echo "[5/10] 锁定 CA 为 Let's Encrypt..."
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

### ====== 申请证书（如已有则跳过） ======
CERT_DIR="/root/.acme.sh/${DOMAIN}_ecc"
if [ ! -d "$CERT_DIR" ]; then
  echo "[6/10] 申请 SSL 证书（DNS-01）..."
  /root/.acme.sh/acme.sh --issue \
    --server letsencrypt \
    --dns dns_cf \
    -d "$DOMAIN" \
    --keylength ec-256
else
  echo "[6/10] 证书已存在，跳过申请"
fi

### ====== 安装证书 ======
echo "[7/10] 安装证书..."
mkdir -p /etc/nginx/ssl
/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
  --key-file /etc/nginx/ssl/key.pem \
  --fullchain-file /etc/nginx/ssl/cert.pem \
  --reloadcmd "systemctl restart nginx" || true

### ====== Nginx 主配置（开启 stream） ======
if ! grep -q "stream {" /etc/nginx/nginx.conf; then
  echo "[8/10] 写入 nginx stream 配置..."
  cat >> /etc/nginx/nginx.conf <<'EOF'

stream {
    map $ssl_preread_server_name $backend {
        default 127.0.0.1:4433;   # Reality / VLESS
        ~.*     127.0.0.1:8443;   # Web / HTTPS
    }

    server {
        listen 443 reuseport;
        proxy_pass $backend;
        ssl_preread on;
    }
}
EOF
fi

### ====== HTTP Web 占位（8443） ======
mkdir -p /etc/nginx/conf.d
cat > /etc/nginx/conf.d/web.conf <<EOF
server {
    listen 8443 ssl;
    server_name $DOMAIN;

    ssl_certificate     /etc/nginx/ssl/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/key.pem;

    root /var/www/html;
    index index.html;
}
EOF

mkdir -p /var/www/html
if [ ! -f /var/www/html/index.html ]; then
cat > /var/www/html/index.html <<EOF
<!DOCTYPE html>
<html>
<head><title>Welcome</title></head>
<body>
<h1>$DOMAIN</h1>
<p>Service is running.</p>
</body>
</html>
EOF
fi

### ====== 启动 Nginx ======
echo "[9/10] 启动 Nginx..."
nginx -t
systemctl enable nginx
systemctl restart nginx

echo "========================================"
echo " 安装完成 ✅"
echo " - Web: https://$DOMAIN (通过 443 → 8443)"
echo " - 443 已预留给 S-UI Reality（SNI 分流）"
echo " - CA: Let's Encrypt（永久）"
echo "========================================"
