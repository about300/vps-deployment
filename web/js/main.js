// 等待DOM加载完成
document.addEventListener('DOMContentLoaded', function() {
    // 服务状态检查
    checkServiceStatus();
    
    // 配置生成器
    setupConfigGenerator();
    
    // 搜索功能
    setupSearch();
    
    // 更新页脚统计
    updateFooterStats();
    
    // 平滑滚动
    setupSmoothScroll();
});

// 检查服务状态
async function checkServiceStatus() {
    const servicesGrid = document.getElementById('services-grid');
    
    const services = [
        { id: 'nginx', name: 'Web 服务', port: 443, icon: 'fas fa-globe' },
        { id: 'subconvert', name: '订阅转换', port: 25500, icon: 'fas fa-exchange-alt' },
        { id: 'sui', name: 'S-UI 面板', port: 2095, icon: 'fas fa-tachometer-alt' },
        { id: 'adguard', name: 'AdGuard', port: 3000, icon: 'fas fa-shield-alt' }
    ];
    
    // 清空现有内容
    servicesGrid.innerHTML = '';
    
    // 为每个服务创建卡片
    services.forEach(service => {
        const card = document.createElement('div');
        card.className = 'service-card loading';
        card.innerHTML = `
            <div class="service-icon">
                <i class="${service.icon}"></i>
            </div>
            <h3 class="service-title">${service.name}</h3>
            <p class="service-text">正在检测...</p>
            <span class="service-status status-checking">检测中</span>
        `;
        servicesGrid.appendChild(card);
    });
    
    // 模拟检测（实际应该向服务器发送请求）
    setTimeout(() => {
        services.forEach((service, index) => {
            const card = servicesGrid.children[index];
            // 模拟随机状态（实际应用中应该通过API检查）
            const isOnline = Math.random() > 0.3;
            
            card.className = `service-card ${isOnline ? 'online' : 'offline'}`;
            card.innerHTML = `
                <div class="service-icon">
                    <i class="${service.icon}"></i>
                </div>
                <h3 class="service-title">${service.name}</h3>
                <p class="service-text">${service.port ? `端口: ${service.port}` : ''}</p>
                <span class="service-status ${isOnline ? 'status-online' : 'status-offline'}">
                    ${isOnline ? '在线' : '离线'}
                </span>
            `;
        });
    }, 2000);
}

// 配置生成器
function setupConfigGenerator() {
    const generateBtn = document.getElementById('generate-config');
    const configModal = document.getElementById('config-modal');
    const closeModal = document.getElementById('close-modal');
    const generateConfigBtn = document.getElementById('generate-btn');
    const copyBtn = document.getElementById('copy-config');
    const downloadBtn = document.getElementById('download-btn');
    
    // 打开模态框
    generateBtn.addEventListener('click', () => {
        configModal.classList.add('active');
        generateSampleConfig();
    });
    
    // 关闭模态框
    closeModal.addEventListener('click', () => {
        configModal.classList.remove('active');
    });
    
    // 点击外部关闭
    configModal.addEventListener('click', (e) => {
        if (e.target === configModal) {
            configModal.classList.remove('active');
        }
    });
    
    // 生成配置
    generateConfigBtn.addEventListener('click', generateSampleConfig);
    
    // 复制配置
    copyBtn.addEventListener('click', () => {
        const configOutput = document.getElementById('config-output').textContent;
        navigator.clipboard.writeText(configOutput).then(() => {
            copyBtn.innerHTML = '<i class="fas fa-check"></i> 已复制';
            copyBtn.classList.add('copied');
            setTimeout(() => {
                copyBtn.innerHTML = '<i class="fas fa-copy"></i> 复制配置';
                copyBtn.classList.remove('copied');
            }, 2000);
        });
    });
    
    // 下载配置
    downloadBtn.addEventListener('click', () => {
        const protocol = document.getElementById('protocol').value;
        const client = document.getElementById('client').value;
        const configOutput = document.getElementById('config-output').textContent;
        
        const blob = new Blob([configOutput], { type: 'text/plain' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = `${protocol}-${client}-config.yaml`;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
    });
}

// 生成示例配置
function generateSampleConfig() {
    const protocol = document.getElementById('protocol').value;
    const client = document.getElementById('client').value;
    const domain = document.getElementById('domain').value || 'your.domain.com';
    const port = document.getElementById('port').value || 443;
    
    const configs = {
        vmess: {
            clash: `proxies:
  - name: "VPS-${protocol.toUpperCase()}"
    type: vmess
    server: ${domain}
    port: ${port}
    uuid: YOUR-UUID-HERE
    alterId: 0
    cipher: auto
    tls: true
    skip-cert-verify: false
    network: ws
    ws-opts:
      path: /your-path
      headers:
        Host: ${domain}`,
            v2ray: `{
  "inbounds": [],
  "outbounds": [{
    "protocol": "vmess",
    "settings": {
      "vnext": [{
        "address": "${domain}",
        "port": ${port},
        "users": [{
          "id": "YOUR-UUID-HERE",
          "alterId": 0,
          "security": "auto"
        }]
      }]
    }
  }]
}`
        },
        vless: {
            clash: `proxies:
  - name: "VPS-${protocol.toUpperCase()}"
    type: vless
    server: ${domain}
    port: ${port}
    uuid: YOUR-UUID-HERE
    tls: true
    skip-cert-verify: false
    network: ws
    ws-opts:
      path: /your-path
      headers:
        Host: ${domain}`,
            v2ray: `{
  "inbounds": [],
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "${domain}",
        "port": ${port},
        "users": [{
          "id": "YOUR-UUID-HERE",
          "flow": "xtls-rprx-vision",
          "encryption": "none"
        }]
      }]
    }
  }]
}`
        }
    };
    
    const config = configs[protocol]?.[client] || 
                   configs.vmess?.[client] || 
                   '选择参数后生成配置...';
    
    document.getElementById('config-output').innerHTML = `<code>${config}</code>`;
}

// 搜索功能
function setupSearch() {
    const searchInput = document.getElementById('search-input');
    const searchResults = document.getElementById('search-results');
    
    // 搜索数据
    const searchData = [
        { title: '订阅转换', description: '转换各种订阅格式', url: '/subconvert/', tags: ['转换', '订阅'] },
        { title: 'S-UI 面板', description: '节点管理和监控面板', url: '/sui/', tags: ['面板', '管理'] },
        { title: '配置生成器', description: '生成客户端配置文件', url: '#', tags: ['配置', '生成'] },
        { title: '服务状态', description: '查看所有服务运行状态', url: '#services', tags: ['状态', '监控'] },
        { title: 'AdGuard Home', description: 'DNS广告过滤服务', url: 'http://localhost:3000', tags: ['DNS', '安全'] }
    ];
    
    searchInput.addEventListener('input', function() {
        const query = this.value.toLowerCase().trim();
        
        if (query.length === 0) {
            searchResults.style.display = 'none';
            return;
        }
        
        const results = searchData.filter(item => {
            const searchText = `${item.title} ${item.description} ${item.tags.join(' ')}`.toLowerCase();
            return searchText.includes(query);
        });
        
        if (results.length > 0) {
            searchResults.innerHTML = results.map(item => `
                <div class="search-result-item">
                    <a href="${item.url}" class="search-result-link">
                        <h4>${item.title}</h4>
                        <p>${item.description}</p>
                        <div class="search-tags">
                            ${item.tags.map(tag => `<span class="search-tag">${tag}</span>`).join('')}
                        </div>
                    </a>
                </div>
            `).join('');
            searchResults.style.display = 'block';
        } else {
            searchResults.innerHTML = '<div class="search-no-results">未找到相关结果</div>';
            searchResults.style.display = 'block';
        }
    });
    
    // 点击外部关闭搜索结果
    document.addEventListener('click', function(e) {
        if (!searchResults.contains(e.target) && !searchInput.contains(e.target)) {
            searchResults.style.display = 'none';
        }
    });
}

// 更新页脚统计
function updateFooterStats() {
    const footerStats = document.getElementById('footer-stats');
    if (footerStats) {
        const services = ['Nginx', 'SubConverter', 'S-UI', 'AdGuard'];
        footerStats.textContent = `正在运行 ${services.length} 项服务`;
    }
}

// 平滑滚动
function setupSmoothScroll() {
    document.querySelectorAll('a[href^="#"]').forEach(anchor => {
        anchor.addEventListener('click', function(e) {
            e.preventDefault();
            const targetId = this.getAttribute('href');
            if (targetId === '#') return;
            
            const targetElement = document.querySelector(targetId);
            if (targetElement) {
                window.scrollTo({
                    top: targetElement.offsetTop - 80,
                    behavior: 'smooth'
                });
            }
        });
    });
}