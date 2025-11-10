// --- 全局配置 ---
let hub_host = 'registry-1.docker.io';
const auth_url = 'https://auth.docker.io';
let 屏蔽爬虫UA = ['netcraft'];

// --- NAT64 功能配置 ---
const nat64Prefix = '2602:fc59:b0:64::';
const directHosts = [
	'registry-1.docker.io',
	'auth.docker.io',
	'index.docker.io',
	'hub.docker.com',
	'1.1.1.1',
];

// --- 核心功能函数 ---

function routeByHosts(host) {
	const routes = {
		"quay": "quay.io", "gcr": "gcr.io", "k8s-gcr": "k8s.gcr.io",
		"k8s": "registry.k8s.io", "ghcr": "ghcr.io", "cloudsmith": "docker.cloudsmith.io",
		"nvcr": "nvcr.io", "test": "registry-1.docker.io",
	};
	if (host in routes) return [routes[host], false];
	return [hub_host, true];
}

export default {
	async fetch(request, env, ctx) {
		const original_url = new URL(request.url);
		console.log(`[Request Start] 接收到请求: ${request.method} ${original_url.href}`);

		const getReqHeader = (key) => request.headers.get(key);
		const userAgent = (getReqHeader("User-Agent") || "null").toLowerCase();
		if (env.UA) 屏蔽爬虫UA = 屏蔽爬虫UA.concat(await ADD(env.UA));
		const workers_hostname = original_url.hostname;

		const ns = original_url.searchParams.get('ns');
		const req_hostname = original_url.searchParams.get('hubhost') || original_url.hostname;
		const hostTop = req_hostname.split('.')[0];
		
		let url = new URL(request.url);

		let checkHost;
		if (ns) {
			hub_host = (ns === 'docker.io') ? 'registry-1.docker.io' : ns;
			console.log(`[Routing] 使用 'ns' 参数指定上游: ${hub_host}`);
		} else {
			checkHost = routeByHosts(hostTop);
			hub_host = checkHost[0];
			console.log(`[Routing] 根据主机名 '${hostTop}' 路由到上游: ${hub_host}`);
		}

		const fakePage = checkHost ? checkHost[1] : false;
		console.log(`[Info] 域名头部: ${hostTop}, 反代地址: ${hub_host}, 是否显示搜索页: ${fakePage}`);
		
		url.hostname = hub_host;

		if (屏蔽爬虫UA.some(fxxk => userAgent.includes(fxxk)) && 屏蔽爬虫UA.length > 0) {
			console.log(`[Access Denied] 检测到被屏蔽的UA: ${userAgent}`);
			return new Response(await nginx(), { headers: { 'Content-Type': 'text/html; charset=UTF-8' } });
		}

		if ((userAgent.includes('mozilla')) || ['/v1/search', '/v1/repositories'].some(param => url.pathname.includes(param))) {
			if (url.pathname == '/') {
				if (env.URL302) return Response.redirect(env.URL302, 302);
				if (env.URL) {
					if (env.URL.toLowerCase() == 'nginx') return new Response(await nginx(), { headers: { 'Content-Type': 'text/html; charset=UTF-8' } });
					return fetch(new Request(env.URL, request));
				}
				if (fakePage) return new Response(await searchInterface(), { headers: { 'Content-Type': 'text/html; charset=UTF-8' } });
			} else {
				if (url.pathname.startsWith('/v1/')) url.hostname = 'index.docker.io';
				else if (fakePage) url.hostname = 'hub.docker.com';
				if (url.searchParams.get('q')?.includes('library/')) {
					url.searchParams.set('q', url.searchParams.get('q').replace('library/', ''));
				}
				return fetchUpstream(url.toString(), { method: request.method, headers: request.headers, body: request.body, redirect: request.redirect });
			}
		}

		if (!/%2F/.test(url.search) && /%3A/.test(url.toString())) {
			let modifiedUrl = url.toString().replace(/%3A(?=.*?&)/, '%3Alibrary%2F');
			url = new URL(modifiedUrl);
		}

		if (hub_host === 'registry-1.docker.io' && /^\/v2\/[^/]+\/[^/]+\/[^/]+$/.test(url.pathname) && !/^\/v2\/library/.test(url.pathname)) {
			url.pathname = '/v2/library/' + url.pathname.split('/v2/')[1];
		}
		
		// [FIXED] 构造一个清晰的 RequestInit 对象 (parameter)
		const parameter = {
			method: request.method,
			headers: new Headers(request.headers),
			body: request.body,
			redirect: 'manual'
		};
		parameter.headers.set('Host', hub_host);
		
		if (hub_host === 'registry-1.docker.io' && url.pathname.startsWith('/v2/') && (url.pathname.includes('/manifests/') || url.pathname.includes('/blobs/') || url.pathname.endsWith('/tags/list'))) {
			console.log(`[Auth] 检测到 Docker Hub 需要认证的 /v2/ 请求: ${url.pathname}`);
			let repo = '';
			const v2Match = url.pathname.match(/^\/v2\/(.+?)(?:\/(manifests|blobs|tags)\/)/);
			if (v2Match) repo = v2Match[1];
			if (repo && !repo.startsWith('library/')) repo = 'library/' + repo;
			
			if (repo) {
				const tokenUrl = `${auth_url}/token?service=registry.docker.io&scope=repository:${repo}:pull`;
				console.log(`[Auth] 正在为仓库 '${repo}' 从 ${auth_url} 获取Token...`);
				const tokenRes = await fetchUpstream(tokenUrl);
				if (tokenRes.ok) {
					const tokenData = await tokenRes.json();
					parameter.headers.set('Authorization', `Bearer ${tokenData.token}`);
					console.log(`[Auth] Token获取成功，将带Token继续请求`);
				} else {
					console.error(`[Auth] Token获取失败，状态码: ${tokenRes.status}`);
				}
			}
		}

		// [FIXED] 传递 url 和 parameter 对象，而不是一个 Request 对象
		let original_response = await fetchUpstream(url.toString(), parameter);
		
		let new_response_headers = new Headers(original_response.headers);

		if (new_response_headers.get("Www-Authenticate")) {
			const authHeader = new_response_headers.get("Www-Authenticate");
			const realmRegex = /realm="https?:\/\/([^"]+)"/;
			const realmMatch = authHeader.match(realmRegex);

			if (realmMatch && realmMatch[1]) {
				const originalRealmHost = realmMatch[1].split('/')[0];
				const modifiedAuthHeader = authHeader.replace(originalRealmHost, workers_hostname);
				new_response_headers.set("Www-Authenticate", modifiedAuthHeader);
				console.log(`[Header Modify] 重写 'Www-Authenticate' 头: ${authHeader} -> ${modifiedAuthHeader}`);
			}
		}

		if (new_response_headers.get("Location")) {
			const location = new_response_headers.get("Location");
			return httpHandler(request, location);
		}

		new_response_headers.set('access-control-allow-origin', '*');
		new_response_headers.set('access-control-expose-headers', '*');
		new_response_headers.delete('content-security-policy');
		new_response_headers.delete('content-security-policy-report-only');
		new_response_headers.delete('clear-site-data');

		return new Response(original_response.body, {
			status: original_response.status,
			headers: new_response_headers
		});
	}
};

function httpHandler(req, location) {
	console.log(`[Redirect] 正在跟随重定向到: ${location}`);
	const reqInit = {
		method: req.method,
		headers: req.headers,
		redirect: 'follow',
		body: req.body
	};
	return fetchUpstream(location, reqInit);
}

// --- NAT64 功能函数 ---

async function fetchUpstream(url, options) {
    const urlObj = new URL(url);
    const hostname = urlObj.hostname;

    if (directHosts.includes(hostname)) {
        console.log(`[FetchUpstream] 主机 ${hostname} 在直连名单中，将使用直接连接。`);
        return fetch(url, options);
    } else {
        console.log(`[FetchUpstream] 主机 ${hostname} 不在直连名单中，将默认使用NAT64连接。`);
        return fetchWithNat64(url, options);
    }
}

// [FIXED] 函数签名和内部逻辑都已修正
async function fetchWithNat64(url, options) {
    const urlObj = new URL(url);
    const hostname = urlObj.hostname;

    console.log(`[NAT64 Fetch] 开始为 ${hostname} 执行NAT64请求`);
	// 添加日志以确认 Authorization 头是否存在
	if (options && options.headers && new Headers(options.headers).has('Authorization')) {
		console.log('[NAT64 Fetch] 检测到 Authorization 头，将一同转发。');
	}

    try {
        const ipv6Address = await getIPv6ProxyAddress(hostname);
        
        // 创建 options 的副本以安全地修改
        const newOptions = { ...options };
		
		// 确保 cf 对象存在
		newOptions.cf = { ...newOptions.cf };
        newOptions.cf.resolveOverride = ipv6Address.replace(/\[|\]/g, '');

        // 确保 headers 对象是 Headers 实例
        newOptions.headers = new Headers(newOptions.headers);
        newOptions.headers.set('Host', hostname);

        console.log(`[NAT64 Fetch] 将请求 ${url} (Host: ${hostname}) 解析到IPv6地址: ${ipv6Address}`);
        return fetch(url, newOptions);

    } catch (error) {
        console.error(`[NAT64 Fetch] NAT64请求失败: ${error.message}`);
        return new Response(`NAT64 connection failed for ${hostname}: ${error.message}`, { status: 502 });
    }
}

async function getIPv4Address(domain) {
    const dnsQuery = await fetch(`https://1.1.1.1/dns-query?name=${encodeURIComponent(domain)}&type=A`, {
        headers: { 'Accept': 'application/dns-json' }
    });
    if (!dnsQuery.ok) throw new Error(`DNS查询API返回错误: ${dnsQuery.status}`);
    const dnsResult = await dnsQuery.json();
    if (dnsResult.Answer && dnsResult.Answer.length > 0) {
        const aRecord = dnsResult.Answer.find(record => record.type === 1);
        if (aRecord && aRecord.data) return aRecord.data;
    }
    throw new Error(`未能找到 ${domain} 的A记录`);
}

function convertToNAT64IPv6(ipv4Address) {
	const parts = ipv4Address.split('.');
	if (parts.length !== 4 || parts.some(part => isNaN(part) || part < 0 || part > 255)) {
		throw new Error(`无效的IPv4地址: ${ipv4Address}`);
	}
	const hex = parts.map(part => parseInt(part, 10).toString(16).padStart(2, '0'));
	return `[${nat64Prefix}${hex[0]}${hex[1]}:${hex[2]}${hex[3]}]`;
}

async function getIPv6ProxyAddress(domain) {
    try {
        const ipv4 = await getIPv4Address(domain);
        return convertToNAT64IPv6(ipv4);
    } catch (err) {
        console.error(`[NAT64] 获取 ${domain} 的NAT64地址失败: ${err.message}`);
        throw err;
    }
}

// --- 辅助及展示函数 ---
async function ADD(envadd) {
	var addtext = envadd.replace(/[	 |"'\r\n]+/g, ',').replace(/,+/g, ',');
	if (addtext.charAt(0) == ',') addtext = addtext.slice(1);
	if (addtext.charAt(addtext.length - 1) == ',') addtext = addtext.slice(0, addtext.length - 1);
	return addtext.split(',');
}

async function nginx() {
	return `<!DOCTYPE html><html><head><title>Welcome to nginx!</title><style>body{width:35em;margin:0 auto;font-family:Tahoma,Verdana,Arial,sans-serif}</style></head><body><h1>Welcome to nginx!</h1><p>If you see this page, the nginx web server is successfully installed and working. Further configuration is required.</p><p>For online documentation and support please refer to<a href="http://nginx.org/">nginx.org</a>.<br/>Commercial support is available at<a href="http://nginx.com/">nginx.com</a>.</p><p><em>Thank you for using nginx.</em></p></body></html>`;
}

async function searchInterface() {
	return `<!DOCTYPE html><html><head><title>Docker Hub 镜像搜索</title><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><style>:root{--github-color:rgb(27,86,198);--github-bg-color:#ffffff;--primary-color:#0066ff;--primary-dark:#0052cc;--gradient-start:#1a90ff;--gradient-end:#003eb3;--text-color:#ffffff;--shadow-color:rgba(0,0,0,0.1);--transition-time:0.3s}*{box-sizing:border-box;margin:0;padding:0}body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;display:flex;flex-direction:column;justify-content:center;align-items:center;min-height:100vh;margin:0;background:linear-gradient(135deg,var(--gradient-start) 0%,var(--gradient-end) 100%);padding:20px;color:var(--text-color);overflow-x:hidden}.container{text-align:center;width:100%;max-width:800px;padding:20px;margin:0 auto;display:flex;flex-direction:column;justify-content:center;min-height:60vh;animation:fadeIn 0.8s ease-out}@keyframes fadeIn{from{opacity:0;transform:translateY(20px)}to{opacity:1;transform:translateY(0)}}.github-corner{position:fixed;top:0;right:0;z-index:999;transition:transform var(--transition-time) ease}.github-corner:hover{transform:scale(1.08)}.github-corner svg{fill:var(--github-bg-color);color:var(--github-color);position:absolute;top:0;border:0;right:0;width:80px;height:80px;filter:drop-shadow(0 2px 5px rgba(0,0,0,0.2))}.logo{margin-bottom:20px;transition:transform var(--transition-time) ease;animation:float 6s ease-in-out infinite}@keyframes float{0%,100%{transform:translateY(0)}50%{transform:translateY(-10px)}}.logo:hover{transform:scale(1.08) rotate(5deg)}.logo svg{filter:drop-shadow(0 5px 15px rgba(0,0,0,0.2))}.title{color:var(--text-color);font-size:2.3em;margin-bottom:10px;text-shadow:0 2px 10px rgba(0,0,0,0.2);font-weight:700;letter-spacing:-0.5px;animation:slideInFromTop 0.5s ease-out 0.2s both}@keyframes slideInFromTop{from{opacity:0;transform:translateY(-20px)}to{opacity:1;transform:translateY(0)}}.subtitle{color:rgba(255,255,255,0.9);font-size:1.1em;margin-bottom:25px;max-width:600px;margin-left:auto;margin-right:auto;line-height:1.4;animation:slideInFromTop 0.5s ease-out 0.4s both}.search-container{display:flex;align-items:stretch;width:100%;max-width:600px;margin:0 auto;height:55px;position:relative;animation:slideInFromBottom 0.5s ease-out 0.6s both;box-shadow:0 10px 25px rgba(0,0,0,0.15);border-radius:12px;overflow:hidden}@keyframes slideInFromBottom{from{opacity:0;transform:translateY(20px)}to{opacity:1;transform:translateY(0)}}#search-input{flex:1;padding:0 20px;font-size:16px;border:none;outline:none;transition:all var(--transition-time) ease;height:100%}#search-input:focus{padding-left:25px}#search-button{width:60px;background-color:var(--primary-color);border:none;cursor:pointer;transition:all var(--transition-time) ease;height:100%;display:flex;align-items:center;justify-content:center;position:relative}#search-button svg{transition:transform 0.3s ease;stroke:white}#search-button:hover{background-color:var(--primary-dark)}#search-button:hover svg{transform:translateX(2px)}#search-button:active svg{transform:translateX(4px)}.tips{color:rgba(255,255,255,0.8);margin-top:20px;font-size:0.9em;animation:fadeIn 0.5s ease-out 0.8s both;transition:transform var(--transition-time) ease}.tips:hover{transform:translateY(-2px)}@media (max-width:768px){.container{padding:20px 15px;min-height:60vh}.title{font-size:2em}.subtitle{font-size:1em;margin-bottom:20px}.search-container{height:50px}}@media (max-width:480px){.container{padding:15px 10px;min-height:60vh}.github-corner svg{width:60px;height:60px}.search-container{height:45px}#search-input{padding:0 15px}#search-button{width:50px}#search-button svg{width:18px;height:18px}.title{font-size:1.7em;margin-bottom:8px}.subtitle{font-size:0.95em;margin-bottom:18px}}</style></head><body><a href="https://github.com/cmliu/CF-Workers-docker.io" target="_blank" class="github-corner" aria-label="View source on Github"><svg viewBox="0 0 250 250" aria-hidden="true"><path d="M0,0 L115,115 L130,115 L142,142 L250,250 L250,0 Z"></path><path d="M128.3,109.0 C113.8,99.7 119.0,89.6 119.0,89.6 C122.0,82.7 120.5,78.6 120.5,78.6 C119.2,72.0 123.4,76.3 123.4,76.3 C127.3,80.9 125.5,87.3 125.5,87.3 C122.9,97.6 130.6,101.9 134.4,103.2" fill="currentColor" style="transform-origin: 130px 106px;" class="octo-arm"></path><path d="M115.0,115.0 C114.9,115.1 118.7,116.5 119.8,115.4 L133.7,101.6 C136.9,99.2 139.9,98.4 142.2,98.6 C133.8,88.0 127.5,74.4 143.8,58.0 C148.5,53.4 154.0,51.2 159.7,51.0 C160.3,49.4 163.2,43.6 171.4,40.1 C171.4,40.1 176.1,42.5 178.8,56.2 C183.1,58.6 187.2,61.8 190.9,65.4 C194.5,69.0 197.7,73.2 200.1,77.6 C213.8,80.2 216.3,84.9 216.3,84.9 C212.7,93.1 206.9,96.0 205.4,96.6 C205.1,102.4 203.0,107.8 198.3,112.5 C181.9,128.9 168.3,122.5 157.7,114.1 C157.9,116.9 156.7,120.9 152.7,124.9 L141.0,136.5 C139.8,137.7 141.6,141.9 141.8,141.8 Z" fill="currentColor" class="octo-body"></path></svg></a><div class="container"><div class="logo"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 18" fill="#ffffff" width="110" height="85"><path d="M23.763 6.886c-.065-.053-.673-.512-1.954-.512-.32 0-.659.03-1.01.087-.248-1.703-1.651-2.533-1.716-2.57l-.345-.2-.227.328a4.596 4.596 0 0 0-.611 1.433c-.23.972-.09 1.884.403 2.666-.596.331-1.546.418-1.744.42H.752a.753.753 0 0 0-.75.749c-.007 1.456.233 2.864.692 4.07.545 1.43 1.355 2.483 2.409 3.13 1.181.725 3.104 1.14 5.276 1.14 1.016 0 2.03-.092 2.93-.266 1.417-.273 2.705-.742 3.826-1.391a10.497 10.497 0 0 0 2.61-2.14c1.252-1.42 1.998-3.005 2.553-4.408.075.003.148.005.221.005 1.371 0 2.215-.55 2.68-1.01.505-.5.685-.998.704-1.053L24 7.076l-.237-.19Z"></path><path d="M2.216 8.075h2.119a.186.186 0 0 0 .185-.186V6a.186.186 0 0 0-.185-.186H2.216A.186.186 0 0 0 2.031 6v1.89c0 .103.083.186.185.186Zm2.92 0h2.118a.185.185 0 0 0 .185-.186V6a.185.185 0 0 0-.185-.186H5.136A.185.185 0 0 0 4.95 6v1.89c0 .103.083.186.186.186Zm2.964 0h2.118a.186.186 0 0 0 .185-.186V6a.186.186 0 0 0-.185-.186H8.1A.185.185 0 0 0 7.914 6v1.89c0 .103.083.186.186.186Zm2.928 0h2.119a.185.185 0 0 0 .185-.186V6a.185.185 0 0 0-.185-.186h-2.119a.186.186 0 0 0-.185.186v1.89c0 .103.083.186.185.186Zm-5.892-2.72h2.118a.185.185 0 0 0 .185-.186V3.28a.186.186 0 0 0-.185-.186H5.136a.186.186 0 0 0-.186.186v1.89c0 .103.083.186.186.186Zm2.964 0h2.118a.186.186 0 0 0 .185-.186V3.28a.186.186 0 0 0-.185-.186H8.1a.186.186 0 0 0-.186.186v1.89c0 .103.083.186.186.186Zm2.928 0h2.119a.185.185 0 0 0 .185-.186V3.28a.186.186 0 0 0-.185-.186h-2.119a.186.186 0 0 0-.185.186v1.89c0 .103.083.186.185.186Zm0-2.72h2.119a.186.186 0 0 0 .185-.186V.56a.185.185 0 0 0-.185-.186h-2.119a.186.186 0 0 0-.185.186v1.89c0 .103.083.186.185.186Zm2.955 5.44h2.118a.185.185 0 0 0 .186-.186V6a.185.185 0 0 0-.186-.186h-2.118a.185.185 0 0 0-.185.186v1.89c0 .103.083.186.185.186Z"></path></svg></div><h1 class="title">Docker Hub 镜像搜索</h1><p class="subtitle">快速查找、下载和部署 Docker 容器镜像</p><div class="search-container"><input type="text" id="search-input" placeholder="输入关键词搜索镜像，如: nginx, mysql, redis..."><button id="search-button" title="搜索"><svg width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path d="M13 5l7 7-7 7M5 5l7 7-7 7" stroke-linecap="round" stroke-linejoin="round"></path></svg></button></div><p class="tips">基于 Cloudflare Workers / Pages 构建，利用全球边缘网络实现毫秒级响应。</p></div><script>function performSearch(){const query=document.getElementById('search-input').value;if(query){window.location.href='/search?q='+encodeURIComponent(query)}}document.getElementById('search-button').addEventListener('click',performSearch);document.getElementById('search-input').addEventListener('keypress',function(event){if(event.key==='Enter'){performSearch()}});window.addEventListener('load',function(){document.getElementById('search-input').focus()});</script></body></html>`;
}
