/**
 * Stealth High-Performance DoH Proxy
 * 
 * 功能亮点：
 * 1. 隐形模式：只有路径匹配环境变量 SECRET_PATH 时才响应，否则返回 "Hello World"。
 * 2. 多策略路由：支持 /adblock, /google, /clean 等不同子路径选择不同上游。
 * 3. 智能容错：自动在同类节点间负载均衡和故障转移。
 * 4. 生产就绪：修正了 POST 流处理，优化了 CORS 和缓存。
 */

// ================= 全局配置 =================

// 上游 DNS 提供商池
const PROVIDERS = [
  // --- 策略：adblock (去广告/隐私) ---
  { id: 'adguard',  group: 'adblock', name: "AdGuard",  url: "https://dns.adguard.com/dns-query", weight: 30 },
  { id: 'mullvad',  group: 'adblock', name: "Mullvad",  url: "https://adblock.dns.mullvad.net/dns-query", weight: 30 },
  { id: 'controld', group: 'adblock', name: "ControlD", url: "https://freedns.controld.com/p2", weight: 20 },
  
  // --- 策略：clean (无污染/高速/通用) ---
  { id: 'cloudflare', group: 'clean', name: "Cloudflare", url: "https://cloudflare-dns.com/dns-query", weight: 30 },
  { id: 'google',     group: 'clean', name: "Google",     url: "https://dns.google/dns-query", weight: 20 },
  { id: 'quad9',      group: 'clean', name: "Quad9",      url: "https://dns.quad9.net/dns-query", weight: 20 },
  { id: 'opendns',    group: 'clean', name: "OpenDNS",    url: "https://doh.opendns.com/dns-query", weight: 10 },

  // --- 策略：security (安全过滤/防恶意软件) ---
  { id: 'quad9_sec',  group: 'security', name: "Quad9 Sec", url: "https://dns.quad9.net/dns-query", weight: 50 },
  { id: 'cf_family',  group: 'security', name: "CF Family", url: "https://security.cloudflare-dns.com/dns-query", weight: 50 },
];

// 定义路由映射 (子路径 -> 筛选逻辑)
const ROUTE_MAP = {
  // 默认路由 (均衡负载所有 clean 节点)
  'default': { 
    filter: p => p.group === 'clean', 
    desc: '自动负载均衡 (Cloudflare/Google/Quad9)' 
  },
  // 强制去广告
  'adblock': { 
    filter: p => p.group === 'adblock', 
    desc: '去广告 & 隐私保护 (AdGuard/Mullvad)' 
  },
  // 强制安全过滤
  'security': { 
    filter: p => p.group === 'security', 
    desc: '拦截恶意网站 (Quad9/CF Security)' 
  },
  // 强制指定特定服务商 (示例)
  'google': { 
    filter: p => p.id === 'google', 
    desc: '强制使用 Google DNS' 
  },
  'cloudflare': { 
    filter: p => p.id === 'cloudflare', 
    desc: '强制使用 Cloudflare DNS' 
  },
  'aliyun': {
    filter: p => false, // 示例：如果列表中没有阿里DNS，这里需先在 PROVIDERS 添加
    // 仅作演示，实际上游池中未配置阿里
    fallback: true // 标记如果找不到则回退到 default
  }
};

// 缓存配置
const CACHE_TTL = 180; // 成功响应缓存 3 分钟

// ================= 核心逻辑 =================

export default {
  async fetch(request, env, ctx) {
    // 1. 安全检查：验证 SECRET_PATH
    // 如果环境变量未设置，或者 URL 不包含 Secret，一律返回伪装响应
    const secretPath = env.SECRET_PATH;
    const url = new URL(request.url);
    const pathSegments = url.pathname.split('/').filter(Boolean); // 移除空字串

    // 路径结构应该是: /<SECRET_PATH>/<OPTIONAL_SUB_PATH>
    // 安全隐患规避：如果未配置环境变量，直接报错或伪装，这里选择伪装
    if (!secretPath || pathSegments[0] !== secretPath) {
      return new Response("Hello World", { 
        status: 200, 
        headers: { "Content-Type": "text/plain" } 
      });
    }

    // 2. 路由解析
    // subPath 是 /SECRET/ 之后的部分，例如 "adblock"
    const subPath = pathSegments[1] || ''; 
    
    // 如果是根目录 (即 /SECRET 或 /SECRET/)，显示配置面板
    if (!subPath && request.method === 'GET' && !url.searchParams.has('dns')) {
      return serveDashboard(url, secretPath, subPath);
    }
    
    // 3. 确定 DNS 策略
    let routeConfig = ROUTE_MAP[subPath];
    
    // 如果请求了不存在的子路径 (且不是dns查询)，或者未定义的路由
    // 为了用户体验，如果是 /SECRET/dns-query 这种标准格式，我们视为 default
    if (!routeConfig) {
       if (subPath === 'dns-query' || subPath === '') {
         routeConfig = ROUTE_MAP['default'];
       } else {
         // 未知路径，返回 404，但在隐形模式下，也许我们应该返回配置页？
         // 这里选择返回配置页提示用户
         return serveDashboard(url, secretPath, subPath, `Unknown endpoint: /${subPath}`);
       }
    }

    // 4. 筛选上游节点
    let candidates = PROVIDERS.filter(routeConfig.filter);
    if (candidates.length === 0) {
      // 如果筛选为空 (比如配置错误)，回退到默认
      candidates = PROVIDERS.filter(ROUTE_MAP['default'].filter);
    }

    // 5. 预处理 POST 请求体 (关键优化)
    // Fetch 的 body 流只能读一次。为了支持故障转移(Failover)，我们需要先读入内存。
    let dnsQueryBody = null;
    if (request.method === 'POST') {
      try {
        dnsQueryBody = await request.arrayBuffer();
      } catch (e) {
        return new Response('Bad Request: Unable to read body', { status: 400 });
      }
    } else if (request.method === 'GET') {
      // 必须包含 ?dns= 参数
      if (!url.searchParams.has('dns')) {
         return serveDashboard(url, secretPath, subPath);
      }
    } else {
      // 仅仅支持 GET 和 POST，其他作为 CORS 预检或错误处理
      if (request.method === 'OPTIONS') return handleCORS();
      return new Response('Method Not Allowed', { status: 405 });
    }

    // 6. 负载均衡与执行
    // 选出一个主要节点，并将其他节点作为备用
    const primary = selectWeighted(candidates);
    return await handleProxy(request, url, primary, candidates, dnsQueryBody);
  }
};

/**
 * 核心代理处理函数（带重试机制）
 */
async function handleProxy(originalReq, url, primary, candidates, bodyContent) {
  // 构建重试队列：Primary -> Random Backup 1 -> Random Backup 2
  const backups = candidates.filter(p => p.id !== primary.id)
                            .sort(() => Math.random() - 0.5)
                            .slice(0, 2); // 最多重试2次，防止请求堆积
  
  const attemptQueue = [primary, ...backups];

  for (const provider of attemptQueue) {
    try {
      // 构造上游 URL，保持 query string (包含 ?dns=...)
      const targetUrl = provider.url + url.search;
      
      const headers = new Headers(originalReq.headers);
      
      // 优化 Headers
      headers.set('Accept', 'application/dns-message');
      headers.set('User-Agent', 'Stealth-DoH-Worker/3.0');
      // 移除可能泄露 IP 的头 (CF Workers 默认会自动处理，但显式移除更安全)
      headers.delete('X-Forwarded-For');
      headers.delete('CF-Connecting-IP');
      
      if (bodyContent) {
        headers.set('Content-Type', 'application/dns-message');
      }

      // 发起请求
      const response = await fetch(targetUrl, {
        method: originalReq.method,
        headers: headers,
        body: bodyContent, // 复用 Buffer
        redirect: 'follow'
      });

      if (response.ok) {
        const newHeaders = new Headers(response.headers);
        addCorsHeaders(newHeaders);
        
        // 强制缓存优化：如果上游没给缓存头，我们自己补一个
        if (!newHeaders.has('Cache-Control')) {
          newHeaders.set('Cache-Control', `public, max-age=${CACHE_TTL}`);
        }
        
        return new Response(response.body, {
          status: response.status,
          statusText: response.statusText,
          headers: newHeaders
        });
      }
      
      // 非 200 响应，打印日志并尝试下一个
      console.warn(`[Failover] ${provider.name} responded with ${response.status}`);
    } catch (err) {
      console.error(`[Error] ${provider.name}: ${err.message}`);
    }
  }

  // 全部失败
  return new Response('DNS Upstream Failure', { 
    status: 502, 
    headers: { 'Access-Control-Allow-Origin': '*' } 
  });
}

// ================= 辅助函数 =================

function selectWeighted(list) {
  if (list.length === 0) return null;
  const totalWeight = list.reduce((sum, p) => sum + (p.weight || 10), 0);
  let random = Math.random() * totalWeight;
  for (const p of list) {
    if (random < (p.weight || 10)) return p;
    random -= (p.weight || 10);
  }
  return list[0];
}

function handleCORS() {
  const headers = new Headers();
  addCorsHeaders(headers);
  headers.set('Access-Control-Max-Age', '86400');
  return new Response(null, { status: 204, headers });
}

function addCorsHeaders(headers) {
  headers.set('Access-Control-Allow-Origin', '*');
  headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  headers.set('Access-Control-Allow-Headers', 'Content-Type, Accept');
}

// ================= UI 仪表盘 =================

function serveDashboard(url, secret, currentSubPath, errorMsg = '') {
  // 动态生成基础 URL
  const baseUrl = `${url.protocol}//${url.host}/${secret}`;
  
  // 生成路由卡片 HTML
  const routesHtml = Object.entries(ROUTE_MAP).map(([key, config]) => {
    // 忽略 fallback
    if (config.fallback) return '';
    
    // 生成该路径的完整 URL
    const routeUrl = key === 'default' ? `${baseUrl}/dns-query` : `${baseUrl}/${key}`;
    const providers = PROVIDERS.filter(config.filter).map(p => p.name).join(', ');
    
    return `
      <div class="route-card" onclick="copyToClip('${routeUrl}')">
        <div class="route-header">
          <span class="route-tag ${key}">${key.toUpperCase()}</span>
          <span class="route-path">/${key === 'default' ? 'dns-query' : key}</span>
        </div>
        <div class="route-desc">${config.desc}</div>
        <div class="route-providers"><small>Upstreams: ${providers}</small></div>
        <div class="copy-hint">Click to Copy URL</div>
      </div>
    `;
  }).join('');

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Stealth DoH Console</title>
  <style>
    :root { --bg: #0f172a; --card: #1e293b; --text: #e2e8f0; --accent: #3b82f6; --accent-hover: #2563eb; --success: #10b981; }
    body { font-family: 'Segoe UI', system-ui, sans-serif; background: var(--bg); color: var(--text); margin: 0; padding: 20px; line-height: 1.5; }
    .container { max-width: 900px; margin: 0 auto; }
    header { margin-bottom: 40px; border-bottom: 1px solid #334155; padding-bottom: 20px; }
    h1 { color: #fff; margin: 0; font-size: 1.8rem; display: flex; align-items: center; gap: 10px; }
    .badge { background: var(--accent); font-size: 0.8rem; padding: 4px 8px; border-radius: 4px; vertical-align: middle; }
    .error-box { background: rgba(239, 68, 68, 0.2); border: 1px solid #ef4444; color: #fca5a5; padding: 15px; border-radius: 8px; margin-bottom: 20px; display: ${errorMsg ? 'block' : 'none'}; }
    
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; }
    
    .route-card { background: var(--card); border: 1px solid #334155; border-radius: 12px; padding: 20px; cursor: pointer; transition: all 0.2s; position: relative; overflow: hidden; }
    .route-card:hover { transform: translateY(-2px); border-color: var(--accent); box-shadow: 0 4px 20px rgba(0,0,0,0.2); }
    .route-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; }
    .route-tag { font-size: 0.75rem; font-weight: bold; padding: 2px 8px; border-radius: 10px; background: #475569; color: #fff; }
    .route-tag.adblock { background: #be123c; } /* Red */
    .route-tag.security { background: #047857; } /* Green */
    .route-tag.google { background: #d97706; } /* Yellow */
    .route-tag.default { background: var(--accent); }
    
    .route-path { font-family: monospace; color: var(--accent); font-weight: bold; }
    .route-desc { font-size: 0.95rem; margin-bottom: 10px; }
    .route-providers { color: #94a3b8; font-size: 0.85rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .copy-hint { position: absolute; bottom: 0; left: 0; right: 0; background: var(--accent); color: white; text-align: center; font-size: 0.8rem; padding: 5px; opacity: 0; transition: opacity 0.2s; }
    .route-card:hover .copy-hint { opacity: 1; }

    .setup-guide { background: var(--card); border-radius: 12px; padding: 25px; margin-top: 40px; }
    .code-block { background: #000; padding: 15px; border-radius: 6px; font-family: monospace; color: #a5b4fc; overflow-x: auto; margin: 10px 0; border: 1px solid #334155; }
    .footer { text-align: center; margin-top: 50px; color: #64748b; font-size: 0.8rem; }
    
    /* Toast Notification */
    #toast { visibility: hidden; min-width: 250px; margin-left: -125px; background-color: #333; color: #fff; text-align: center; border-radius: 8px; padding: 16px; position: fixed; z-index: 1; left: 50%; bottom: 30px; font-size: 17px; box-shadow: 0 5px 15px rgba(0,0,0,0.3); }
    #toast.show { visibility: visible; -webkit-animation: fadein 0.5s, fadeout 0.5s 2.5s; animation: fadein 0.5s, fadeout 0.5s 2.5s; }
    @-webkit-keyframes fadein { from {bottom: 0; opacity: 0;} to {bottom: 30px; opacity: 1;} }
    @keyframes fadein { from {bottom: 0; opacity: 0;} to {bottom: 30px; opacity: 1;} }
    @-webkit-keyframes fadeout { from {bottom: 30px; opacity: 1;} to {bottom: 0; opacity: 0;} }
    @keyframes fadeout { from {bottom: 30px; opacity: 1;} to {bottom: 0; opacity: 0;} }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <h1>
        <span>🛡️ Stealth DoH Proxy</span>
        <span class="badge">Active</span>
      </h1>
      <p style="color: #94a3b8;">Secure, routed, and load-balanced DNS-over-HTTPS worker.</p>
    </header>

    <div class="error-box">${errorMsg}</div>

    <h2 style="margin-bottom: 20px;">Available Endpoints</h2>
    <div class="grid">
      ${routesHtml}
    </div>

    <div class="setup-guide">
      <h2>⚡ Quick Setup</h2>
      <p>Use the standard DoH format for all requests:</p>
      
      <h3>1. Base64url (GET)</h3>
      <div class="code-block">GET ${baseUrl}/adblock?dns=q80BAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB</div>
      
      <h3>2. Binary (POST)</h3>
      <div class="code-block">curl -H "Content-Type: application/dns-message" --data-binary @query.dns ${baseUrl}/google</div>
      
      <h3>3. Browser Config (Chrome/Edge)</h3>
      <div class="code-block">${baseUrl}/adblock</div>
      <p style="font-size: 0.9rem; color: #94a3b8;">Paste the copied URL into your browser's "Secure DNS" > "Custom" field.</p>
    </div>

    <div class="footer">
      Generated by Cloudflare Worker | Request ID: ${new Date().getTime().toString(36)}
    </div>
  </div>

  <div id="toast">URL Copied to Clipboard!</div>

  <script>
    function copyToClip(text) {
      navigator.clipboard.writeText(text).then(() => {
        var x = document.getElementById("toast");
        x.className = "show";
        setTimeout(function(){ x.className = x.className.replace("show", ""); }, 3000);
      }).catch(err => {
        alert("Failed to copy: " + text);
      });
    }
  </script>
</body>
</html>`;
  
  return new Response(html, {
    headers: { 'Content-Type': 'text/html; charset=utf-8' }
  });
}
