#!/usr/bin/env bash
set -e

echo "========================================"
echo " install_continue.sh"
echo " - Web 首页"
echo " - SubConverter"
echo " - sub-web-modify"
echo " - S-UI（仅安装）"
echo " - Nginx stream 共用 443"
echo "========================================"

### 交互参数（与 install.sh 保持一致）
read -rp "请输入主域名（如 money.mycloudshare.org）: " DOMAIN
read -rp "请输入订阅域名前缀（如 sub）: " SUB_PREFIX
SUB_DOMAIN="${SUB_PREFIX}.${DOMAIN}"

### 基础目录
WEB_ROOT="/var/www/web"
SUBWEB_ROOT="/var/www/sub-web"
SUBCONVERTER_DIR="/opt/subconverter"

mkdir -p /etc/nginx/stream.d /etc/nginx/http.d "$WEB_ROOT" "$SUBWEB_ROOT"

# -------------------------------------------------
# [6] Web 首页（bing-like）
# -------------------------------------------------
if [ ! -f "$WEB_ROOT/index.html" ]; then
cat > "$WEB_ROOT/index.html" <<EOF
<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="UTF-8">
<title>${DOMAIN}</title>
<style>
body { background:#111; color:#eee; text-align:center; margin-top:15%; font-family:sans-serif; }
input { width:420px; padding:14px; font-size:16px; border-radius:30px; border:none; }
button { padding:12px 20px; border-radius:30px; border:none; background:#4caf50; color:#fff; }
a { color:#4caf50; position:fixed; top:20px; right:20px; text-decoration:none; }
</style>
</head>
<body>
<a href="https://${SUB_DOMAIN}">订阅转换</a>
<form action="https://www.bing.com/search" method="get">
<input name="q" placeholder="Search..." autofocus>
</form>
</body>
</html>
EOF
echo "[6/10] Web 首页已创建"
else
echo "[6/10] Web 首页已存在，跳过"
fi

# -------------------------------------------------
# [7] SubConverter
# -------------------------------------------------
if [ ! -d "$SUBCONVERTER_DIR" ]; then
echo "[7/10] 安装 SubConverter..."
git clone https://github.com/tindy2013/subconverter "$SUBCONVERTER_DIR"
cd "$SUBCONVERTER_DIR"
chmod +x subconverter
cat > /etc/systemd/system/subconverter.service <<EOF
[Unit]
Description=SubConverter
After=network.target

[Service]
ExecStart=${SUBCONVERTER_DIR}/subconverter
WorkingDirectory=${SUBCONVERTER_DIR}
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now subconverter
else
echo "[7/10] SubConverter 已存在，跳过"
fi

# -------------------------------------------------
# [8] sub-web-modify（前端）
# -------------------------------------------------
if [ ! -d "/opt/sub-web" ]; then
echo "[8/10] 构建 sub-web-modify..."
git clone https://github.com/about300/sub-web-modify /opt/sub-web
cd /opt/sub-web
npm install
npm run build
cp -r dist/* "$SUBWEB_ROOT/"
else
echo "[8/10] sub-web-modify 已存在，确保 dist 已部署"
cp -r /opt/sub-web/dist/* "$SUBWEB_ROOT/" 2>/dev/null || true
fi

# -------------------------------------------------
# [9] S-UI（仅安装）
# -------------------------------------------------
if ! command -v s-ui >/dev/null 2>&1; then
echo "[9/10] 安装 S-UI..."
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)
systemctl enable --now s-ui
else
echo "[9/10] S-UI 已安装，跳过"
fi

# -------------------------------------------------
# [10] Nginx stream 共用 443（SNI）
# -------------------------------------------------
STREAM_CONF="/etc/nginx/nginx.conf"

if ! grep -q "stream {" "$STREAM_CONF"; then
echo "[10/10] 写入 stream 共用 443 配置..."
sed -i '1i\
stream {\n\
  map $ssl_preread_server_name $backend {\n\
    '"$DOMAIN"' web_backend;\n\
    '"$SUB_DOMAIN"' web_backend;\n\
    default web_backend;\n\
  }\n\
\n\
  upstream web_backend {\n\
    server 127.0.0.1:8443;\n\
  }\n\
\n\
  server {\n\
    listen 443 reuseport;\n\
    ssl_preread on;\n\
    proxy_pass $backend;\n\
  }\n\
}\n' "$STREAM_CONF"
else
echo "[10/10] stream 已存在，跳过"
fi

# -------------------------------------------------
# HTTP 8443
# -------------------------------------------------
cat > /etc/nginx/http.d/web.conf <<EOF
server {
  listen 8443 ssl;
  server_name ${DOMAIN} ${SUB_DOMAIN};

  ssl_certificate /etc/nginx/ssl/cert.pem;
  ssl_certificate_key /etc/nginx/ssl/key.pem;

  location / {
    root ${WEB_ROOT};
    index index.html;
  }

  location /sub {
    proxy_pass http://127.0.0.1:2550;
  }
}
EOF

nginx -t
systemctl restart nginx

echo "========================================"
echo " 安装补全完成"
echo " Web: https://${DOMAIN}"
echo " Sub: https://${SUB_DOMAIN}"
echo " S-UI: http://IP:54321"
echo "========================================"
