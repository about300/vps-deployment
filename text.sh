echo "[5/12] 安装 SubConverter 后端"
# 检查 SubConverter 二进制文件是否存在，如果不存在，则复制
if [ ! -f "/opt/subconverter/subconverter" ]; then
  echo "[INFO] 未找到 SubConverter 二进制文件，正在复制..."
  cp /opt/subconverter/bin/subconverter /opt/subconverter/subconverter  # 请根据实际路径修改
  chmod +x /opt/subconverter/subconverter
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
else
  echo "[INFO] SubConverter 二进制文件已存在，跳过复制。"
fi

echo "[6/12] 安装 Node.js (LTS)"
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

echo "[7/12] 构建 sub-web-modify (来自 about300 仓库)"
# 检查 sub-web-modify 是否存在，如果不存在，则克隆并构建
if [ ! -d "/opt/sub-web-modify" ]; then
  echo "[INFO] 未找到 sub-web-modify，正在克隆并构建..."
  rm -rf /opt/sub-web-modify
  git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
  cd /opt/sub-web-modify
  npm install
  npm run build
else
  echo "[INFO] sub-web-modify 已存在，跳过克隆。"
fi

echo "[8/12] 安装 S-UI 面板 (仅本地监听)"
bash <(curl -Ls https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

echo "[9/12] 克隆 Web 文件"
# 检查 web-home 文件夹是否存在，如果不存在，则克隆
if [ ! -d "/opt/web-home" ]; then
  echo "[INFO] web-home 未找到，正在克隆..."
  rm -rf /opt/web-home
  git clone https://github.com/about300/vps-deployment.git /opt/web-home
  mv /opt/web-home/web /opt/web-home/current
else
  echo "[INFO] web-home 已存在，跳过克隆。"
fi

echo "[10/12] 配置 Nginx Web 和 API"
cat >/etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate     /etc/nginx/ssl/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN/key.pem;

    # 主页：指向 Web 内容并支持搜索功能
    root /opt/web-home/current;
    index index.html;
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # 订阅转换前端：指向 Sub-Web-Modify 构建的静态文件
    location /subconvert/ {
        alias /opt/sub-web-modify/dist/;
        try_files \$uri \$uri/ /subconvert/index.html;
    }

    # 订阅转换后端：代理到本地 SubConverter 服务
    location /sub/api/ {
        proxy_pass http://127.0.0.1:25500/;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }

    # VLESS 订阅：通过反向代理将流量转发到 S-UI 中设置的 VLESS 服务
    location /vless/ {
        proxy_pass http://127.0.0.1:$VLESS_PORT;  # 使用预设的端口
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
    }
}
EOF
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
nginx -t
systemctl reload nginx

echo "[11/12] 配置 DNS-01 用于 Let's Encrypt"
echo "[INFO] 使用 Cloudflare API 进行 DNS-01 验证"

echo "[12/12] 安装 AdGuard Home (端口 3000)"
curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh

echo "[13/12] 完成 🎉"
echo "====================================="
echo "主页: https://$DOMAIN"
echo "SubConverter API: https://$DOMAIN/sub/api/"
echo "S-UI 面板: http://127.0.0.1:2095"
echo "====================================="