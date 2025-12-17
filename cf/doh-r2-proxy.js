/**
 * Project: Red-Star Stealth DoH (R2 Cache Edition)
 * Description: 
 *   1. 伪装页面由环境变量 CAMOUFLAGE_HTML 控制。
 *   2. 集成 R2 存储作为 DNS 缓存层，减少上游回源。
 *   3. 异步非阻塞写入，极致性能。
 */

/**
在部署代码之前，你必须完成以下 Cloudflare 配置：

#### 1. 创建 R2 存储桶 (Bucket)
1.  进入 Cloudflare Dashboard -> **R2**。
2.  点击 **Create bucket**。
3.  命名为 `doh-cache` (或者你喜欢的名字)。
4.  **重要：设置生命周期规则 (Lifecycle Rule)**：
    *   进入该 Bucket -> **Settings** -> **Object lifecycle rules** -> **Add rule**。
    *   Rule name: `Auto Cleanup`
    *   Delete objects older than: **1 Day** (或者 12 Hours)。
    *   *解释：虽然代码会校验缓存是否过期，但 R2 需要这个规则来物理删除旧文件，节省存储费用。*

#### 2. 绑定 R2 到 Worker
1.  进入 **Workers & Pages** -> 选择你的 Worker -> **Settings** -> **Variables**.
2.  找到 **R2 Bucket Bindings**。
3.  点击 **Add Binding**。
    *   Variable name: `DNS_CACHE` (代码中必须用这个名字)
    *   R2 Bucket: 选择刚才创建的 `doh-cache`。
4.  点击 **Save and Deploy**.

#### 3. 设置环境变量
在同一个 **Settings** -> **Variables** -> **Environment Variables** 区域，添加：

*   `SECRET_PATH`: 你的 UUID (例如 `8f3b2c1a-secret-key`)。
*   `CAMOUFLAGE_HTML`: 粘贴那个“三个代表”或其他任何 HTML 代码。
    *   *提示：由于 HTML 可能很长，建议先压缩成一行，或者直接粘贴。Cloudflare 环境变量支持存放大文本。*
*/

// ================= 全局配置 =================

// 上游 DNS 提供商池
const PROVIDERS = [
  // --- Adblock Group ---
  { id: 'adguard',  group: 'adblock', name: "AdGuard",  url: "https://dns.adguard.com/dns-query", weight: 30 },
  { id: 'mullvad',  group: 'adblock', name: "Mullvad",  url: "https://adblock.dns.mullvad.net/dns-query", weight: 30 },
  { id: 'controld', group: 'adblock', name: "ControlD", url: "https://freedns.controld.com/p2", weight: 20 },
  
  // --- Clean Group ---
  { id: 'cloudflare', group: 'clean', name: "Cloudflare", url: "https://cloudflare-dns.com/dns-query", weight: 30 },
  { id: 'google',     group: 'clean', name: "Google",     url: "https://dns.google/dns-query", weight: 20 },
  { id: 'quad9',      group: 'clean', name: "Quad9",      url: "https://dns.quad9.net/dns-query", weight: 20 },
];

// 路由映射
const ROUTE_MAP = {
  'default': { filter: p => p.group === 'clean', desc: '自动负载均衡 (Cloudflare/Google/Quad9)' },
  'adblock': { filter: p => p.group === 'adblock', desc: '去广告 & 隐私保护 (AdGuard/Mullvad)' },
  'google':  { filter: p => p.id === 'google', desc: '强制使用 Google DNS' },
  'security':{ filter: p => p.id === 'quad9', desc: '安全防护 (Quad9)' }
};

// 缓存配置
const LOGICAL_TTL = 300; // 5分钟 (代码逻辑判断过期时间)

// ================= 主入口逻辑 =================

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const secretPath = env.SECRET_PATH;
    const pathSegments = url.pathname.split('/').filter(Boolean);

    // 1. 隐形判断：路径不匹配 Secret -> 返回环境变量中的伪装页面
    if (!secretPath || pathSegments[0] !== secretPath) {
      return new Response(env.CAMOUFLAGE_HTML || "<h1>System Error: Camouflage missing.</h1>", {
        headers: { 'Content-Type': 'text/html; charset=utf-8' }
      });
    }

    // --- 进入 DoH 逻辑区域 ---
    const subPath = pathSegments[1] || ''; 
    
    // 面板路由
    if (!subPath && request.method === 'GET' && !url.searchParams.has('dns')) {
      return serveDashboard(url, secretPath);
    }
    
    // 确定 DNS 策略
    let routeConfig = ROUTE_MAP[subPath];
    if (!routeConfig) {
       if (subPath === 'dns-query' || subPath === '') routeConfig = ROUTE_MAP['default'];
       else return serveDashboard(url, secretPath, `未定义的接口: /${subPath}`);
    }

    // 筛选上游
    let candidates = PROVIDERS.filter(routeConfig.filter);
    if (candidates.length === 0) candidates = PROVIDERS.filter(ROUTE_MAP['default'].filter);

    // 2. 准备请求体并计算 Cache Key
    let dnsQueryBody = null;
    let cacheKey = null;

    if (request.method === 'POST') {
      try {
        dnsQueryBody = await request.arrayBuffer();
        cacheKey = await hashQuery(dnsQueryBody, subPath || 'default');
      } catch (e) {
        return new Response('Bad Request', { status: 400 });
      }
    } else if (request.method === 'GET') {
      if (!url.searchParams.has('dns')) return serveDashboard(url, secretPath);
      const dnsParam = url.searchParams.get('dns');
      // GET 请求将 Base64 字符串作为 Key
      cacheKey = await hashQuery(new TextEncoder().encode(dnsParam), subPath || 'default');
    } else {
      if (request.method === 'OPTIONS') return handleCORS();
      return new Response('Method Not Allowed', { status: 405 });
    }

    // 3. R2 缓存读取尝试 (Hit Strategy)
    // 只有配置了 R2 绑定才会执行
    if (env.DNS_CACHE && cacheKey) {
      const cachedRes = await checkR2Cache(env, cacheKey);
      if (cachedRes) return cachedRes; // 命中缓存，直接返回
    }

    // 4. 执行上游代理 (Miss Strategy)
    const primary = selectWeighted(candidates);
    return await handleProxy(request, url, primary, candidates, dnsQueryBody, env, ctx, cacheKey);
  }
};

// ================= 核心功能函数 =================

/**
 * 代理处理：包含故障转移 + 异步写入 R2
 */
async function handleProxy(originalReq, url, primary, candidates, bodyContent, env, ctx, cacheKey) {
  const backups = candidates.filter(p => p.id !== primary.id)
                            .sort(() => Math.random() - 0.5)
                            .slice(0, 2);
  const attemptQueue = [primary, ...backups];

  for (const provider of attemptQueue) {
    try {
      const targetUrl = provider.url + url.search;
      const headers = new Headers(originalReq.headers);
      headers.set('Accept', 'application/dns-message');
      headers.set('User-Agent', 'Stealth-DoH/5.0');
      headers.delete('X-Forwarded-For');
      headers.delete('CF-Connecting-IP');
      if (bodyContent) headers.set('Content-Type', 'application/dns-message');

      const response = await fetch(targetUrl, {
        method: originalReq.method,
        headers: headers,
        body: bodyContent,
        redirect: 'follow'
      });

      if (response.ok) {
        // 复制响应以备写入缓存和返回
        const resBodyClone = response.clone().body;
        
        // --- 异步写入 R2 (Fire and Forget) ---
        if (env.DNS_CACHE && cacheKey) {
          ctx.waitUntil(saveR2Cache(env, cacheKey, resBodyClone));
        }

        // 构建返回响应
        const newHeaders = new Headers(response.headers);
        addCorsHeaders(newHeaders);
        // 强制浏览器端也缓存
        if (!newHeaders.has('Cache-Control')) {
          newHeaders.set('Cache-Control', `public, max-age=${LOGICAL_TTL}`);
        }
        
        return new Response(response.body, {
          status: response.status,
          statusText: response.statusText,
          headers: newHeaders
        });
      }
    } catch (err) {
      console.warn(`[Failover] ${provider.name} error: ${err.message}`);
    }
  }

  return new Response('Service Unavailable', { status: 502, headers: { 'Access-Control-Allow-Origin': '*' } });
}

/**
 * R2 缓存读取
 */
async function checkR2Cache(env, key) {
  try {
    const object = await env.DNS_CACHE.get(key);
    
    if (object === null) return null;

    // 检查是否过期
    const savedTime = parseInt(object.customMetadata?.timestamp || "0");
    const now = Date.now();
    
    // 如果超过逻辑 TTL (5分钟)，视为过期，返回 null 以触发重新查询
    if (now - savedTime > LOGICAL_TTL * 1000) {
      // 可选：在这里可以异步删除过期对象，但依赖 Bucket Lifecycle 规则更高效
      return null; 
    }

    const headers = new Headers();
    object.writeHttpMetadata(headers);
    headers.set('etag', object.httpEtag);
    addCorsHeaders(headers);
    headers.set('X-Cache-Status', 'R2-HIT'); // 调试标记
    headers.set('Cache-Control', `public, max-age=${Math.floor((LOGICAL_TTL * 1000 - (now - savedTime))/1000)}`);

    return new Response(object.body, { headers });
  } catch (e) {
    // R2 读取错误不应阻断流程，降级为回源
    return null;
  }
}

/**
 * R2 缓存写入
 */
async function saveR2Cache(env, key, bodyStream) {
  try {
    // 注意：R2 每次 PUT 都是一次计费操作 (Class A)，GET 是 (Class B)
    // 这里的写入由于在 waitUntil 中，不会拖慢用户响应
    await env.DNS_CACHE.put(key, bodyStream, {
      httpMetadata: {
        contentType: 'application/dns-message',
      },
      customMetadata: {
        timestamp: Date.now().toString()
      }
    });
  } catch (e) {
    console.error("R2 Write Failed:", e);
  }
}

/**
 * 计算 Cache Key (SHA-256)
 * 为了避免不同子路径的缓存混淆 (如 /adblock 和 /google 的结果不应混用)，
 * 我们将 subPath 也加入 Hash 计算。
 */
async function hashQuery(buffer, salt) {
  const hashBuffer = await crypto.subtle.digest('SHA-256', buffer);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
  return `${salt}_${hashHex}`;
}

// ================= 辅助工具 =================

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

function serveDashboard(url, secret, errorMsg = '') {
  const baseUrl = `${url.protocol}//${url.host}/${secret}`;
  const routesHtml = Object.entries(ROUTE_MAP).map(([key, config]) => {
    const routeUrl = key === 'default' ? `${baseUrl}/dns-query` : `${baseUrl}/${key}`;
    return `<div class="card" onclick="copy('${routeUrl}')">
        <div class="chk">/${key === 'default' ? 'dns-query' : key}</div>
        <div class="desc">${config.desc}</div>
    </div>`;
  }).join('');

  const html = `<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Stealth Console</title>
  <style>
    body{font-family:monospace;background:#111;color:#0f0;padding:20px;max-width:800px;margin:0 auto}
    h1{border-bottom:1px dashed #0f0;padding-bottom:10px}
    .err{color:red;border:1px solid red;padding:10px;margin-bottom:20px;display:${errorMsg?'block':'none'}}
    .card{border:1px solid #333;margin-bottom:10px;padding:15px;cursor:pointer;transition:0.2s}
    .card:hover{border-color:#0f0;background:#001100}
    .chk{font-weight:bold;font-size:1.1em;margin-bottom:5px}
    .desc{color:#888;font-size:0.9em}
    .toast{position:fixed;bottom:20px;left:50%;transform:translateX(-50%);background:#0f0;color:#000;padding:5px 15px;display:none}
  </style></head><body>
  <h1>[SYSTEM_ROOT]: DoH Proxy Active</h1>
  <div class="err">${errorMsg}</div>
  <p>Status: ONLINE | Mode: STEALTH | Cache: R2-ENABLED</p>
  <h3>Available Endpoints (Click to Copy):</h3>
  ${routesHtml}
  <div class="toast" id="t">Copied!</div>
  <script>
    function copy(txt){navigator.clipboard.writeText(txt).then(()=>{
      const t=document.getElementById('t');t.style.display='block';setTimeout(()=>t.style.display='none',2000);
    })}
  </script></body></html>`;
  return new Response(html, { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
}
