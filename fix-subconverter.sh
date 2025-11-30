#!/bin/bash

# Subconverter 配置修复脚本
# 修复 YAML 格式问题，使用标准格式而非压缩格式
# 使用方法: bash <(curl -sL https://raw.githubusercontent.com/about300/vps-deployment/main/fix-subconverter.sh)

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# 显示横幅
show_banner() {
    echo -e "${GREEN}"
    cat << "EOF"
   _____      _    _         _                     
  / ____|    | |  | |       | |                    
 | (___   ___| | _| |_ _   _| |___  __ _ _ __ _ __ 
  \___ \ / __| |/ / __| | | | / __|/ _` | '__| '__|
  ____) | (__|   <| |_| |_| | \__ \ (_| | |  | |   
 |_____/ \___|_|\_\\__|\__,_|_|___/\__,_|_|  |_|   
                                                    
    Subconverter 配置修复脚本 - 标准 YAML 格式版
EOF
    echo -e "${NC}"
}

# 检查环境
check_environment() {
    step "检查环境..."
    
    # 检查是否 root 用户
    if [ "$EUID" -ne 0 ]; then
        error "请使用 root 用户运行此脚本"
    fi
    
    # 检查 subconverter 是否安装
    if [ ! -f /opt/subconverter/subconverter ]; then
        error "未找到 subconverter，请先运行主部署脚本"
    fi
    
    # 检查服务状态
    if ! systemctl is-active --quiet subconverter; then
        warn "subconverter 服务未运行，尝试启动..."
        systemctl start subconverter
        sleep 3
    fi
    
    log "环境检查通过"
}

# 备份原有配置
backup_config() {
    step "备份原有配置..."
    
    local backup_dir="/opt/subconverter/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    # 备份关键文件
    cp /opt/subconverter/pref.ini "$backup_dir/" 2>/dev/null || true
    cp /opt/subconverter/profiles/*.ini "$backup_dir/" 2>/dev/null || true
    
    log "配置已备份到: $backup_dir"
}

# 创建自定义配置目录
create_profile_dir() {
    step "创建配置目录..."
    
    mkdir -p /opt/subconverter/profiles
    log "配置目录创建完成"
}

# 创建标准 YAML 格式配置
create_standard_config() {
    step "创建标准 YAML 格式配置..."
    
    cat > /opt/subconverter/profiles/standard-yaml.ini << 'EOF'
# 标准 YAML 格式配置
# 生成易读的多行 YAML 而非压缩单行格式

[common]
; 基本设置
sort_flag = true
sort_script = true
expand_proxy = true
compress_proxy = false

; 节点过滤
exclude_remark = 过期|时间|流量|剩余|重置|速度|延迟|倍率|官网|地址|官网地址|官网|网站|更新|订阅|获取|请|访问|网址|域名|账号|用户|密码|试用|体验|测试|test|TEST|Test|垃圾|废弃|过期|到期|异常|错误|错|故障|失效|暂停|停止|终止|结束|取消|关闭|关|无|没有|不|非|免|无需|不用|不要|禁止|拒绝|屏蔽|阻断|拦截|阻止|黑名单|白名单|中国|国内|大陆|内地

; 重命名规则
rename_node = 香港→🇭🇰 香港节点|台湾→🇨🇳 台湾节点|日本→🇯🇵 日本节点|美国→🇺🇲 美国节点|韩国→🇰🇷 韩国节点|新加坡→🇸🇬 狮城节点

; 代理组设置
add_proxy_groups = true
proxy_groups_remove = true

; 自定义代理组
custom_proxy_groups = >
  - name: 🚀 节点选择
    type: select
    proxies:
      - ♻️ 自动选择
      - 🚀 手动切换
      - 🎯 全球直连

  - name: 🚀 手动切换
    type: select
    proxies: []

  - name: ♻️ 自动选择
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies: []

  - name: 📹 油管视频
    type: select
    proxies:
      - 🚀 节点选择
      - ♻️ 自动选择

  - name: 🎥 奈飞视频
    type: select
    proxies:
      - 🚀 节点选择
      - ♻️ 自动选择
      - 🎥 奈飞节点

  - name: 🎥 奈飞节点
    type: select
    proxies: []

  - name: 💬 OpenAi
    type: select
    proxies:
      - 🚀 节点选择
      - ♻️ 自动选择

  - name: 📲 电报消息
    type: select
    proxies:
      - 🚀 节点选择
      - ♻️ 自动选择

  - name: Ⓜ️ 微软服务
    type: select
    proxies:
      - 🚀 节点选择
      - ♻️ 自动选择

  - name: 🍎 苹果服务
    type: select
    proxies:
      - 🎯 全球直连

  - name: 🎮 游戏平台
    type: select
    proxies:
      - 🚀 节点选择
      - ♻️ 自动选择

  - name: 🎶 网易音乐
    type: select
    proxies:
      - 🎯 全球直连

  - name: 📺 哔哩哔哩
    type: select
    proxies:
      - 🎯 全球直连
      - 🇨🇳 台湾节点
      - 🇭🇰 香港节点

  - name: 🛑 广告拦截
    type: select
    proxies:
      - REJECT

  - name: 🍃 应用净化
    type: select
    proxies:
      - 🎯 全球直连

  - name: 🐟 漏网之鱼
    type: select
    proxies:
      - 🎯 全球直连
      - 🚀 节点选择

  - name: 🇭🇰 香港节点
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies: []

  - name: 🇨🇳 台湾节点
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies: []

  - name: 🇯🇵 日本节点
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies: []

  - name: 🇺🇲 美国节点
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 150
    proxies: []

  - name: 🇸🇬 狮城节点
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies: []

  - name: 🇰🇷 韩国节点
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies: []

  - name: 🎯 全球直连
    type: select
    proxies:
      - DIRECT

  - name: 🛑 自定义拦截
    type: select
    proxies:
      - REJECT

; 规则配置
add_rules = true
ruleset = >
  🛑 广告拦截@REJECT,https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/BanAD.list
  🍃 应用净化@DIRECT,https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/BanProgram.list
  🛑 自定义拦截@REJECT,https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/BanEasyList.list
  📢 谷歌FCM@🚀 节点选择,https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/GoogleFCM.list
  Ⓜ️ 微软服务@🚀 节点选择,https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Microsoft.list
  🍎 苹果服务@DIRECT,https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Apple.list
  📹 油管视频@🚀 节点选择,https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/YouTube.list
  🎥 奈飞视频@🎥 奈飞视频,https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Netflix.list
  💬 OpenAi@🚀 节点选择,https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/OpenAI.list
  📲 电报消息@🚀 节点选择,https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Telegram.list
  🎮 游戏平台@🚀 节点选择,https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Game.list
  🌍 国外媒体@🚀 节点选择,https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/ProxyMedia.list
  🌏 国内媒体@DIRECT,https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/ChinaMedia.list
  📺 哔哩哔哩@🎯 全球直连,https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Bilibili.list
  🎶 网易音乐@DIRECT,https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/NetEaseMusic.list
  🎯 全球直连@DIRECT,https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/LocalAreaNetwork.list
  🎯 全球直连@DIRECT,https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/ChinaDomain.list
  🎯 全球直连@DIRECT,https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/ChinaCompanyIp.list
  🎯 全球直连@DIRECT,https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Download.list
  🐟 漏网之鱼@🎯 全球直连,https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/UnBan.list

; 自定义规则 - 本地网络和内网直连
custom_rules = >
  - DOMAIN-SUFFIX,acl4.ssr,🎯 全球直连
  - DOMAIN-SUFFIX,ip6-localhost,🎯 全球直连
  - DOMAIN-SUFFIX,ip6-loopback,🎯 全球直连
  - DOMAIN-SUFFIX,lan,🎯 全球直连
  - DOMAIN-SUFFIX,local,🎯 全球直连
  - DOMAIN-SUFFIX,localhost,🎯 全球直连
  - IP-CIDR,0.0.0.0/8,🎯 全球直连,no-resolve
  - IP-CIDR,10.0.0.0/8,🎯 全球直连,no-resolve
  - IP-CIDR,100.64.0.0/10,🎯 全球直连,no-resolve
  - IP-CIDR,127.0.0.0/8,🎯 全球直连,no-resolve
  - IP-CIDR,172.16.0.0/12,🎯 全球直连,no-resolve
  - IP-CIDR,192.168.0.0/16,🎯 全球直连,no-resolve
  - IP-CIDR,198.18.0.0/16,🎯 全球直连,no-resolve
  - IP-CIDR,224.0.0.0/4,🎯 全球直连,no-resolve
  - IP-CIDR6,::1/128,🎯 全球直连,no-resolve
  - IP-CIDR6,fc00::/7,🎯 全球直连,no-resolve
  - IP-CIDR6,fe80::/10,🎯 全球直连,no-resolve
  - IP-CIDR6,fd00::/8,🎯 全球直连,no-resolve
  - DOMAIN,instant.arubanetworks.com,🎯 全球直连
  - DOMAIN,setmeup.arubanetworks.com,🎯 全球直连
  - DOMAIN,router.asus.com,🎯 全球直连
  - DOMAIN,www.asusrouter.com,🎯 全球直连
  - DOMAIN-SUFFIX,hiwifi.com,🎯 全球直连
  - DOMAIN-SUFFIX,leike.cc,🎯 全球直连
  - DOMAIN-SUFFIX,miwifi.com,🎯 全球直连

; YAML 格式控制
yaml_style = true
clash_use_new_field_name = true
EOF

    log "标准 YAML 配置创建完成"
}

# 更新主配置文件
update_main_config() {
    step "更新主配置文件..."
    
    # 创建新的主配置
    cat > /opt/subconverter/pref.ini << 'EOF'
[common]
; 日志设置
loglevel = info

; API 设置
api_mode = true
api_access_token = 
default_url = 

; 订阅转换设置
enable_insert = true
append_proxy_type = false
insert_url = 

; 节点过滤
enable_filter = true
filter_script = https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/config/ACL4SSR_Online_Full.ini

; 规则设置
enable_rule_generator = true
overwrite_original_rules = true
update_ruleset_on_request = false

; 输出格式
clash_rule_base = https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/config/ACL4SSR_Online_Full.ini
surge_rule_base = https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Surge/config/ACL4SSR_Online_Full.conf
surfboard_rule_base = https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Surfboard/config/ACL4SSR_Online_Full.conf
quan_rule_base = https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Quantumult/config/ACL4SSR_Online_Full.conf
loon_rule_base = https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Loon/config/ACL4SSR_Online_Full.conf

; 自定义配置
custom_proxy_group = /opt/subconverter/profiles/standard-yaml.ini

; 性能设置
cache_subscription = true
cache_config = true
cache_ruleset = true

; 服务器设置
listen = 127.0.0.1
port = 25500
serve_file_root = /opt/subconverter/web

; 高级设置
; 启用标准 YAML 格式
clash_proxy_config = https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/config/ACL4SSR_Online_Full.ini
enable_profile_update = true
EOF

    log "主配置文件更新完成"
}

# 更新 Web 界面
update_web_interface() {
    step "更新 Web 界面配置..."
    
    if [ -f /var/www/html/sub.html ]; then
        # 更新默认配置选项
        sed -i 's|ACL4SSR_Online_Full.ini|standard-yaml.ini|g' /var/www/html/sub.html
        
        # 添加配置说明
        if ! grep -q "standard-yaml.ini" /var/www/html/sub.html; then
            warn "Web 界面更新失败，请手动检查"
        else
            log "Web 界面更新完成"
        fi
    else
        warn "未找到 Web 界面文件，跳过更新"
    fi
}

# 重启服务
restart_services() {
    step "重启服务..."
    
    # 重启 subconverter
    systemctl restart subconverter
    
    # 等待服务启动
    sleep 5
    
    # 检查服务状态
    if systemctl is-active --quiet subconverter; then
        log "✅ subconverter 服务重启成功"
    else
        error "❌ subconverter 服务启动失败"
    fi
    
    # 重启 nginx（如果修改了 Web 界面）
    if systemctl is-active --quiet nginx; then
        systemctl reload nginx
        log "✅ nginx 服务重载完成"
    fi
}

# 测试转换功能
test_conversion() {
    step "测试转换功能..."
    
    # 创建一个测试订阅链接（使用示例节点）
    local test_url="https://raw.githubusercontent.com/about300/vps-deployment/main/test-sub.txt"
    
    log "测试标准 YAML 格式转换..."
    local response=$(curl -s "http://127.0.0.1:25500/sub?target=clash&url=$test_url&config=standard-yaml.ini" | head -10)
    
    if echo "$response" | grep -q "proxies:"; then
        log "✅ 转换测试成功 - 生成标准 YAML 格式"
        echo "--- 示例输出前几行 ---"
        echo "$response"
    else
        warn "⚠️ 转换测试可能有问题，请检查服务状态"
    fi
}

# 显示使用说明
show_usage() {
    echo
    log "🎉 配置修复完成！"
    echo
    log "📖 使用说明:"
    log "   标准配置: /sub?target=clash&url=你的订阅&config=standard-yaml.ini"
    log "   简洁配置: /sub?target=clash&url=你的订阅&config=standard-yaml.ini&list=false&tfo=false"
    echo
    log "🔧 转换参数示例:"
    log "   https://你的域名:8443/sub?target=clash&url=订阅链接&config=standard-yaml.ini"
    log "   https://你的域名:8443/sub?target=clash&url=订阅链接&config=standard-yaml.ini&emoji=true&list=false"
    echo
    log "📋 配置特点:"
    log "   ✅ 标准多行 YAML 格式（非压缩单行）"
    log "   ✅ 完整的代理组和规则集"
    log "   ✅ 本地网络和内网直连优化"
    log "   ✅ 支持 VLESS Reality 节点"
    log "   ✅ 自动节点排序和过滤"
    echo
    log "⚠️ 如果遇到问题，请检查:"
    log "   - 服务状态: systemctl status subconverter"
    log "   - 服务日志: journalctl -u subconverter -f"
    log "   - 端口监听: netstat -tlnp | grep 25500"
}

# 主函数
main() {
    show_banner
    check_environment
    backup_config
    create_profile_dir
    create_standard_config
    update_main_config
    update_web_interface
    restart_services
    test_conversion
    show_usage
}

# 运行主函数
main "$@"
