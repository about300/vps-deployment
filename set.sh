#!/bin/bash
# quick_fix_clash.sh
# 快速修复SubConverter Clash配置

echo "快速修复SubConverter Clash配置..."
echo ""

# 停止服务
systemctl stop subconverter 2>/dev/null || true
sleep 2

# 创建最简单的修复规则
cat > /opt/subconverter/rules/fix_clash.ini <<'QUICKRULE'
[common]
script=1

[filter]
script=function(proxy) return proxy end

[config]
script=function(config)
    -- 确保Clash配置有所有必需字段
    if not config.port then
        local new_config = {
            port = 7890,
            ["socks-port"] = 7891,
            ["allow-lan"] = true,
            mode = "Rule",
            ["log-level"] = "info",
            ["external-controller"] = "0.0.0.0:9090",
            secret = "",
            ["proxy-groups"] = {
                {
                    name = "🚀 节点选择",
                    type = "select",
                    proxies = {"DIRECT"}
                }
            },
            rules = {
                "MATCH,🚀 节点选择"
            }
        }
        
        -- 如果有代理节点，添加进去
        if config and config.proxies then
            new_config.proxies = config.proxies
        else
            new_config.proxies = {}
        end
        
        return new_config
    end
    
    -- 如果已有配置，确保必需字段存在
    config.port = config.port or 7890
    config["socks-port"] = config["socks-port"] or 7891
    config["allow-lan"] = config["allow-lan"] or true
    config.mode = config.mode or "Rule"
    config["log-level"] = config["log-level"] or "info"
    config["external-controller"] = config["external-controller"] or "0.0.0.0:9090"
    config.secret = config.secret or ""
    
    if not config["proxy-groups"] then
        config["proxy-groups"] = {
            {
                name = "🚀 节点选择",
                type = "select",
                proxies = {"DIRECT"}
            }
        }
    end
    
    if not config.rules then
        config.rules = {
            "MATCH,🚀 节点选择"
        }
    end
    
    return config
end
QUICKRULE

# 更新配置
if [ -f "/opt/subconverter/config.ini" ]; then
    sed -i 's|rule_generator_config=.*|rule_generator_config=fix_clash.ini|g' /opt/subconverter/config.ini
    sed -i 's|enable_rule_generator=.*|enable_rule_generator=true|g' /opt/subconverter/config.ini
else
    echo "未找到config.ini，无法更新配置"
    exit 1
fi

# 重启服务
systemctl start subconverter
sleep 3

echo "修复完成！测试配置生成..."
TEST_URL="https://raw.githubusercontent.com/tindy2013/subconverter/master/base/sample/sample_multiple_vmess.yaml"
curl -s "http://127.0.0.1:25500/sub?target=clash&url=$TEST_URL" | head -15