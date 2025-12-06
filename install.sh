#!/bin/bash
set -e

echo "========== VLESS+Reality+s-ui 自动安装 =========="

read -p "请输入你的域名 (默认 myhome.mycloudshare.org): " DOMAIN
DOMAIN=${DOMAIN:-myhome.mycloudshare.org}

read -p "请输入伪装域名SNI (默认 www.bing.com): " SNI
SNI=${SNI:-www.bing.com}

echo "开始安装必要环境..."
apt update -y && apt install -y curl wget unzip socat cron nginx

echo "安装 s-ui 面板..."
bash <(curl -fsSL https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh)

echo "停止 nginx 使用 Caddy 接管 443"
systemctl stop nginx
systemctl disable nginx

echo "安装 Caddy..."
apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/deb/debian/pubkey.gpg' | gpg --dearmor \
| tee /usr/share/keyrings/caddy-stable-archive-keyring.gpg >/dev/null
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/deb/debian/debian.deb.txt' \
| tee /etc/apt/sources.list.d/caddy-stable.list
apt update -y && apt install -y caddy

echo "生成 Reality 公私钥..."
mkdir -p /opt/reality
PRIV=$(openssl rand -hex 32)
PUB=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 32)
echo "$PRIV" > /opt/reality/private.key
echo "$PUB" > /opt/reality/public.key

echo "部署 Caddy 配置..."
cat >/etc/caddy/Caddyfile <<EOF
{
    servers {
        protocol {
            experimental_http3
        }
    }
}
$DOMAIN:443 {
    encode gzip

    @main path /
    handle @main {
        root * /var/www/site
        file_server
    }

    @sub path /sub
    handle @sub {
        reverse_proxy 127.0.0.1:18080
    }

    reverse_proxy 127.0.0.1:4433
}
EOF

systemctl restart caddy

echo "部署订阅转换 subconverter..."
mkdir -p /opt/sub && cd /opt/sub
wget -O sub.zip https://github.com/tindy2013/subconverter/archive/master.zip
unzip -o sub.zip
mv subconverter-master subconverter
chmod +x subconverter/subconverter
nohup ./subconverter/subconverter &

echo "部署Bing风格Web前端..."
mkdir -p /var/www/site
cd /var/www/site
curl -fsSL https://raw.githubusercontent.com/USERNAME/REPO/main/web/index.html -o index.html
curl -fsSL https://raw.githubusercontent.com/USERNAME/REPO/main/web/script.js -o script.js
curl -fsSL https://raw.githubusercontent.com/USERNAME/REPO/main/web/style.css -o style.css

echo "========== 安装完成 =========="
echo "面板访问： https://$DOMAIN"
echo "订阅转换： https://$DOMAIN/sub?target=clash&url=你的节点"
echo "Reality 公钥： $PUB"
echo "Reality 私钥： $PRIV"
