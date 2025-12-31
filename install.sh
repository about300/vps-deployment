#!/bin/bash

# 安装基本依赖
echo "Installing required packages..."
sudo apt-get update
sudo apt-get install -y wget curl build-essential libssl-dev libpcre3 libpcre3-dev zlib1g-dev

# 下载并解压 Nginx 源码
NGINX_VERSION="1.24.0"
echo "Downloading Nginx version $NGINX_VERSION..."
cd /opt
wget https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz
tar -zxvf nginx-$NGINX_VERSION.tar.gz
cd nginx-$NGINX_VERSION

# 下载并解压 OpenSSL
OPENSSL_VERSION="1.1.1k"
echo "Downloading OpenSSL version $OPENSSL_VERSION..."
cd /opt
wget https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz
tar -zxvf openssl-$OPENSSL_VERSION.tar.gz
cd openssl-$OPENSSL_VERSION

# 配置 Nginx 并启用必要的模块
echo "Configuring Nginx with necessary modules..."
cd /opt/nginx-$NGINX_VERSION
./configure --with-stream --with-stream_ssl_module --with-stream_realip_module --with-openssl=/opt/openssl-$OPENSSL_VERSION

# 编译和安装 Nginx
echo "Compiling Nginx..."
make -j$(nproc)
sudo make install

# 创建日志目录
sudo mkdir -p /usr/local/nginx/logs
sudo mkdir -p /usr/local/nginx/html

# 配置 Nginx
echo "Configuring Nginx..."
sudo cp /opt/nginx-$NGINX_VERSION/conf/nginx.conf /usr/local/nginx/conf/
sudo cp /opt/nginx-$NGINX_VERSION/conf/mime.types /usr/local/nginx/conf/
sudo cp -r /opt/nginx-$NGINX_VERSION/html/* /usr/local/nginx/html/

# 配置 Nginx 服务
echo "Setting up Nginx service..."
cat > /etc/systemd/system/nginx.service <<EOL
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=network.target

[Service]
ExecStart=/usr/local/nginx/sbin/nginx
ExecReload=/usr/local/nginx/sbin/nginx -s reload
ExecStop=/usr/local/nginx/sbin/nginx -s stop
Restart=always
PIDFile=/run/nginx.pid

[Install]
WantedBy=multi-user.target
EOL

# 重新加载系统服务
sudo systemctl daemon-reload
sudo systemctl enable nginx
sudo systemctl start nginx

# 测试 Nginx 配置是否成功
echo "Testing Nginx configuration..."
sudo /usr/local/nginx/sbin/nginx -t

# 安装 S-UI
echo "Installing S-UI..."
cd /opt
wget https://github.com/alireza0/s-ui/releases/download/v1.3.7/s-ui-linux-amd64.tar.gz
tar -zxvf s-ui-linux-amd64.tar.gz
cd s-ui

# 安装 S-UI 服务
echo "Setting up S-UI service..."
cat > /etc/systemd/system/s-ui.service <<EOL
[Unit]
Description=S-UI Panel
After=network.target

[Service]
ExecStart=/opt/s-ui/s-ui.sh
ExecReload=/opt/s-ui/s-ui.sh reload
ExecStop=/opt/s-ui/s-ui.sh stop
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOL

# 重新加载服务
sudo systemctl daemon-reload
sudo systemctl enable s-ui
sudo systemctl start s-ui

# 安装 AdGuard Home
echo "Installing AdGuard Home..."
cd /opt
wget https://github.com/AdguardTeam/AdGuardHome/releases/download/v0.107.0/AdGuardHome_linux_amd64.tar.gz
tar -zxvf AdGuardHome_linux_amd64.tar.gz
cd AdGuardHome

# 设置 AdGuard Home 服务
echo "Setting up AdGuard Home service..."
cat > /etc/systemd/system/adguardhome.service <<EOL
[Unit]
Description=AdGuard Home
After=network.target

[Service]
ExecStart=/opt/AdGuardHome/AdGuardHome
ExecReload=/opt/AdGuardHome/AdGuardHome reload
ExecStop=/opt/AdGuardHome/AdGuardHome stop
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOL

# 重新加载服务
sudo systemctl daemon-reload
sudo systemctl enable adguardhome
sudo systemctl start adguardhome

echo "Installation completed successfully!"

# 提示用户访问地址
echo "Access your S-UI panel at: http://<your_server_ip>:2095/app/"
echo "Access your AdGuard Home panel at: http://<your_server_ip>:3000/"
