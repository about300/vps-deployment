# VPS 一键部署脚本

这是一个用于快速部署 VPS 服务的自动化脚本，包含以下服务：

- 🔄 **订阅转换** (subconverter) - 支持 VLESS、VMess、Trojan 等协议
- 🛡️ **AdGuard Home** - DNS 广告过滤
- ⚡ **S-UI 面板** - 节点管理
- 🌐 **Nginx** - Web 服务器和反向代理

## 快速开始

在全新的 VPS 上执行以下命令，选择你需要的部署版本：

### Step 1: 执行安装脚本

1. **基本版本**（包括 Subconverter、S-UI 和 Nginx 反向代理配置）:

    ```bash
    bash <(curl -sL https://raw.githubusercontent.com/about300/vps-deployment/main/install.sh)
    ```



### 步骤 2: 配置 Nginx 反向代理|

根据你的需求，配置 Nginx 反向代理。例如，如果你想通过 HTTPS 访问 S-UI 面板，可以按照以下配置反向代理：

```nginx
server {
    listen 443 ssl http2;
    server_name panel.example.com;

    ssl_certificate     /etc/nginx/ssl/panel.example.com/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/panel.example.com/key.pem;

    # 反向代理到 S-UI 面板 HTTP 服务
    location /s-ui/ {
        proxy_pass http://127.0.0.1:2095/app/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        # SPA/UI 兼容
        proxy_redirect     off;
        proxy_read_timeout 90s;
    }
}

server {
    listen 80;
    server_name panel.example.com;
    return 301 https://$server_name$request_uri;  # 强制 HTTP 到 HTTPS 的重定向
}
```  

### 步骤 3: 执行安装后脚本

1. **更新 Web 主页脚本**（自动更新 GitHub 上的网页内容）:

    ```bash
    /usr/local/bin/update-home
    ```

2. **检查服务状态脚本**（检查所有服务是否正常运行）:

    ```bash
    /usr/local/bin/check-services.sh
    ```

**关于主页index的本地测试方法**

手动打开https://cors-anywhere.herokuapp.com/corsdemo 此链接 之后 在index.sh 在vscode运行 可以看是否能正常获取bing的背景图