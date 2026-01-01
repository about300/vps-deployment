#!/usr/bin/env bash
set -e

echo "=============================="
echo " VPS 一键部署（最终稳定版）"
echo "=============================="

# ===== 基本输入 =====
read -rp "请输入域名（例如：girl.mycloudshare.org）: " DOMAIN
read -rp "请输入 Cloudflare API Token: " CF_Token
export CF_Token

# ===== 端口预设 =====
SUBCONVERTER_PORT=25500
VLESS_PORT=5000   # 仅预留，不创建节点

# ===== 路径预设 =====
SUBCONVERTER_DIR=/opt/subconverter
SUBWEB_DIR=/opt/sub-web-modify
WEBROOT=/opt/web-home/current
SSL_DIR=/etc/nginx/ssl/${DOMAIN}

# ===== Step 1：系统依赖 =====
echo "[1/12] 安装系统依赖"
apt update -y
apt install -y curl wget git nginx ufw socat cron unzip nodejs npm

# ===== Step 2：防火墙 =====
echo "[2/12] 配置防火墙"
ufw allow 22
ufw allow 80
ufw allow 443
ufw --force enable

# ===== Step 3：acme.sh =====
echo "[3/12] 安装 acme.sh"
if [ ! -d ~/.acme.sh ]; then
  curl https://get.acme.sh | sh
fi
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# ===== Step 4：申请证书 =====
echo "[4/12] 申请 SSL 证书"
mkdir -p "${SSL_DIR}"
if [ ! -f "${SSL_DIR}/fullchain.pem" ]; then
  ~/.acme.sh/acme.sh --issue --dns dns_cf -d "${DOMAIN}"
fi

# ===== Step 5：安装证书 =====
echo "[5/12] 安装 SSL 证书"
~/.acme.sh/acme.sh --install-cert -d "${DOMAIN}" \
  --key-file "${SSL_DIR}/key.pem" \
  --fullchain-file "${SSL_DIR}/fullchain.pem" \
  --reloadcmd "systemctl reload nginx"

# ===== Step 6：SubConverter 后端 =====
echo "[6/12] 安装 SubConverter 后端"
mkdir -p "${SUBCONVERTER_DIR}"

if [ ! -f "${SUBCONVERTER_DIR}/subconverter" ]; then
  echo "[INFO] 下载 SubConverter 二进制"
  wget -O "${SUBCONVERTER_DIR}/subconverter" \
    https://github.com/about300/vps-deployment/raw/refs/heads/main/bin/subconverter
  chmod +x "${SUBCONVERTER_DIR}/subconverter"
fi

cat >/etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter 服务
After=network.target

[Service]
ExecStart=${SUBCONVERTER_DIR}/subconverter
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable subconverter
systemctl restart subconverter

# ===== Step 7：Sub-Web 前端 =====
echo "[7/12] 构建 Sub-Web 前端（about300 仓库）"
if [ ! -d "${SUBWEB_DIR}" ]; then
  git clone https://github.com/about300/sub-web-modify "${SUBWEB_DIR}"
  cd "${SUBWEB_DIR}"
  npm install
  npm run build
fi

# ===== Step 8：示例主页 =====
echo "[8/12] 准备主页"
mkdir -p "${WEBROOT}"
if [ ! -f "${WEBROOT}/index.html" ]; then
  cat >"${WEBROOT}/index.html" <<EOF
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>Welcome</title></head>
<body>
<h1>主页正常</h1>
<p><a href="/subconvert/">进入订阅转换</a></p>
</body>
</html>
EOF
fi

# ===== Step 9：Nginx 配置（重点） =====
echo "[9/12] 配置 Nginx（已修复子路径反代问题）"

cat >/etc/nginx/sites-available/${DOMAIN} <<EOF
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${SSL_DIR}/fullchain.pem;
    ssl_certificate_key ${SSL_DIR}/key.pem;

    # ===== 主页 =====
    root ${WEBROOT};
    index index.html;
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # ===== Sub-Web 前端 =====
    location /subconvert/ {
        alias ${SUBWEB_DIR}/dist/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    # ===== SubConverter 后端（关键修复）=====
    location /sub/api/ {
        rewrite ^/sub/api/?(.*)$ /\$1 break;
        proxy_pass http://127.0.0.1:${SUBCONVERTER_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }
}
EOF

ln -sf /etc/nginx/sites-available/${DOMAIN} /etc/nginx/sites-enabled/${DOMAIN}
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

# ===== Step 10：完成 =====
echo "=============================="
echo "部署完成 ✅"
echo "主页：https://${DOMAIN}/"
echo "订阅前端：https://${DOMAIN}/subconvert/"
echo "订阅后端：https://${DOMAIN}/sub/api/"
echo "=============================="
