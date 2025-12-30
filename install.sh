#!/usr/bin/env bash
set -e

echo "======================================"
echo " VPS 全栈部署（Web + VLESS + TLS + Nginx + AdGuard Home + DNS + SubConverter）"
echo "======================================"

# 交互输入 Cloudflare API 认证
read -rp "请输入 Cloudflare API 电子邮件地址: " CF_EMAIL
read -rp "请输入 Cloudflare API 密钥: " CF_API_KEY

# 交互输入域名
read -rp "请输入 Web 域名（如 web.mycloudshare.org）: " WEB_DOMAIN

# 配置 Cloudflare API 环境变量
export CF_API_EMAIL=$CF_EMAIL
export CF_API_KEY=$CF_API_KEY
export CF_DNS_API="https://api.cloudflare.com/client/v4"
export CF_ZONE_ID=$(curl -s -X GET "$CF_DNS_API/zones?name=$WEB_DOMAIN" \
  -H "X-Auth-Email: $CF_API_EMAIL" \
  -H "X-Auth-Key: $CF_API_KEY" | jq -r '.result[0].id')

# 如果没有获取到 Zone ID，则退出
if [ -z "$CF_ZONE_ID" ]; then
  echo "无法获取 Cloudflare Zone ID，请检查域名和 API 权限。"
  exit 1
fi

echo "[1/10] 更新系统"
apt update -y
apt install -y curl wget git unzip socat cron ufw nginx \
               build-essential ca-certificates lsb-release jq dnsmasq

echo "[2/10] 防火墙设置"
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 3000  # AdGuard Home
ufw allow 8445  # 备用
ufw allow 25500 # 订阅转换
ufw --force enable

echo "[3/10] 安装 acme.sh (Cloudflare DNS-01 Let's Encrypt)"
if [ ! -d ~/.acme.sh ]; then
  curl https://get.acme.sh | sh
fi
source ~/.bashrc

# 检查证书是否已经存在
if [ -f "/etc/nginx/ssl/$WEB_DOMAIN/fullchain.pem" ]; then
  echo "证书已经存在，跳过证书申请步骤。"
else
  echo "[4/10] 申请 SSL 证书"
  ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$WEB_DOMAIN" \
    --key-file /etc/nginx/ssl/$WEB_DOMAIN/key.pem \
    --fullchain-file /etc/nginx/ssl/$WEB_DOMAIN/fullchain.pem \
    --dns-api $CF_API_KEY --accountemail $CF_EMAIL
fi

# 设置自动续期
echo "[5/10] 配置证书自动续期"
~/.acme.sh/acme.sh --install-cert -d "$WEB_DOMAIN" \
  --key-file /etc/nginx/ssl/$WEB_DOMAIN/key.pem \
  --fullchain-file /etc/nginx/ssl/$WEB_DOMAIN/fullchain.pem \
  --reloadcmd "systemctl reload nginx"

# 配置 cron 自动续期
echo "0 0 1 * * ~/.acme.sh/acme.sh --renew -d $WEB_DOMAIN --dns dns_cf && systemctl reload nginx" | crontab -

echo "[6/10] 安装 SubConverter 后端"
mkdir -p /opt/subconverter
cd /opt/subconverter
wget -O subconverter https://raw.githubusercontent.com/about300/vps-deployment/main/bin/subconverter
chmod +x subconverter

cat >/etc/systemd/system/subconverter.service <<EOF
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
systemctl enable --now subconverter

echo "[7/10] 构建 sub-web-modify"
rm -rf /opt/sub-web-modify
git clone https://github.com/about300/sub-web-modify /opt/sub-web-modify
cd /opt/sub-web-modify
npm install
npm run build

echo "[8/10] 安装 AdGuard Home"
curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v

echo "[9/10] 配置 Nginx 使用 SNI 区分不同服务"

cat >/etc/nginx/nginx.conf <<EOF
stream {
    # VLESS 服务配置
    server {
        listen 443 ssl;
        server_name vless.$WEB_DOMAIN;  # VLESS 域名

        ssl_certificate /etc/nginx/ssl/$WEB_DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/nginx/ssl/$WEB_DOMAIN/key.pem;

        # 通过 Nginx 隐藏 VLESS 服务，避免直接暴露
        proxy_pass 127.0.0.1:443;  # VLESS 服务监听端口（Xray 或 V2Ray）
    }

    # AdGuard Home 服务配置
    server {
        listen 443 ssl;
        server_name adguard.$WEB_DOMAIN;  # AdGuard Home 域名

        ssl_certificate /etc/nginx/ssl/$WEB_DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/nginx/ssl/$WEB_DOMAIN/key.pem;

        proxy_pass 127.0.0.1:3000;  # AdGuard Home 端口
    }
}

http {
    server {
        listen 443 ssl http2;
        server_name $WEB_DOMAIN;  # Web 域名

        ssl_certificate /etc/nginx/ssl/$WEB_DOMAIN/fullchain.pem;
        ssl_certificate_key /etc/nginx/ssl/$WEB_DOMAIN/key.pem;

        root /var/www/web-home;
        index index.html;

        location / {
            try_files \$uri \$uri/ /index.html;
        }

        # 右上角加入订阅转换链接
        location /subconvert/ {
            root /opt/sub-web-modify/dist;
            try_files \$uri \$uri/ /index.html;
        }
    }
}
EOF

# 配置 dnsmasq
echo "[10/10] 配置 DNS 解析服务 (dnsmasq)"
cat >>/etc/dnsmasq.conf <<EOF
# 监听所有地址并使用 53 端口
interface=eth0  # 修改为你的网络接口名称
listen-address=0.0.0.0
port=53

# 配置上游 DNS 服务器
server=8.8.8.8
server=8.8.4.4
EOF

# 启动 dnsmasq 服务
systemctl restart dnsmasq
systemctl enable dnsmasq

# 启动 Nginx 和其他服务
echo "[10/10] 启动 Nginx 和服务"
nginx -t
systemctl reload nginx

echo "======================================"
echo "部署完成 🎉"
echo "Web: https://$WEB_DOMAIN"
echo "订阅转换: https://$WEB_DOMAIN/subconvert/"
echo "S-UI 面板访问方式：ssh -L 2095:127.0.0.1:2095 root@服务器IP"
echo "VLESS 服务地址（不可公开暴露）: https://vless.$WEB_DOMAIN/"
echo "AdGuard Home 管理地址: https://adguard.$WEB_DOMAIN/"
echo "DNS 解析服务已启用，监听 53 端口"
echo "======================================"
