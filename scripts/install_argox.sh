#!/bin/bash

# ==============================================================
# ArgoX NAT VPS 专用版 - 配置文件驱动
# ==============================================================

# 默认变量
WORK_DIR="/etc/argox"
CONFIG_FILE=""

# 颜色定义
red() { echo -e "\033[31m\033[01m$1\033[0m"; }
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$1\033[0m"; }

# 1. 解析参数，加载配置文件
while getopts "f:" opt; do
  case $opt in
    f) CONFIG_FILE=$OPTARG ;;
  esac
done

if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
    red "错误: 未找到配置文件。请使用 -f 指定 config.conf 路径。"
    exit 1
fi

# 加载配置
source "$CONFIG_FILE"

# 2. 变量缺省值处理 (如果配置文件没填，则自动生成)
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
ARGO_PORT=8080
# 这是一个用于客户端显示的伪装域名，不影响 Argo 实际连接
CDN_DOMAIN="www.visa.com.sg" 

# 3. 检查 Root 权限
[[ $EUID -ne 0 ]] && red "请在 root 下运行" && exit 1

# 4. 安装依赖
install_deps() {
    green "正在安装依赖..."
    if [ -f /etc/alpine-release ]; then
        apk update && apk add bash curl wget unzip jq coreutils openssl ca-certificates iptables
    elif [ -f /etc/debian_version ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update && apt-get install -y curl wget unzip jq coreutils openssl ca-certificates iptables
    else
        yum install -y curl wget unzip jq coreutils openssl ca-certificates iptables
    fi
}

# 5. 安装核心组件
install_core() {
    green "安装 Xray 和 Cloudflared..."
    mkdir -p "${WORK_DIR}" && chmod 777 "${WORK_DIR}"
    
    # 架构判断
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64') ARCH='amd64'; XRAY_ARCH='64' ;;
        'aarch64' | 'arm64') ARCH='arm64'; XRAY_ARCH='arm64-v8a' ;;
        *) red "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
    esac

    # 下载组件
    curl -sLo "${WORK_DIR}/xray.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"
    unzip -o "${WORK_DIR}/xray.zip" -d "${WORK_DIR}/" > /dev/null 2>&1
    rm -f "${WORK_DIR}/xray.zip"
    chmod +x "${WORK_DIR}/xray"

    curl -sLo "${WORK_DIR}/argo" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}"
    chmod +x "${WORK_DIR}/argo"
}

# 6. 生成配置 (关键修复：移除 flow 流控)
config_xray() {
    green "生成 Xray 配置..."
    cat > "${WORK_DIR}/config.json" << EOF
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
  "inbounds": [
    {
      "port": $ARGO_PORT,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID", "flow": "" }], 
        "decryption": "none",
        "fallbacks": [
          { "path": "/argox-vl", "dest": 3001 },
          { "path": "/argox-vm", "dest": 3002 },
          { "path": "/argox-tr", "dest": 3003 }
        ]
      },
      "streamSettings": { "network": "tcp" }
    },
    {
      "port": 3001, "listen": "127.0.0.1", "protocol": "vless",
      "settings": { "clients": [{ "id": "$UUID", "level": 0 }], "decryption": "none" },
      "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "/argox-vl" } }
    },
    {
      "port": 3002, "listen": "127.0.0.1", "protocol": "vmess",
      "settings": { "clients": [{ "id": "$UUID", "alterId": 0 }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/argox-vm" } }
    },
    {
      "port": 3003, "listen": "127.0.0.1", "protocol": "trojan",
      "settings": { "clients": [{ "password": "$UUID" }] },
      "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "/argox-tr" } }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
}

# 7. 启动服务
start_services() {
    green "启动服务..."
    
    # 1. 启动 Xray
    if [ -f /etc/alpine-release ]; then
        # Alpine OpenRC 模拟 (Runner环境通常不完整，后台运行更稳)
        nohup ${WORK_DIR}/xray run -c ${WORK_DIR}/config.json >/dev/null 2>&1 &
    else
        # Systemd
        cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
Type=simple
ExecStart=${WORK_DIR}/xray run -c ${WORK_DIR}/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xray
        systemctl restart xray
    fi

    # 2. 启动 Argo
    if [ -n "$ARGO_AUTH" ] && [ -n "$ARGO_DOMAIN" ]; then
        green "使用固定 Argo 隧道: $ARGO_DOMAIN"
        # 判断是 Token 还是 Json
        if [[ "$ARGO_AUTH" =~ TunnelSecret ]]; then
            echo "$ARGO_AUTH" > ${WORK_DIR}/tunnel.json
            cat > ${WORK_DIR}/tunnel.yml << EOF
tunnel: $(echo "$ARGO_AUTH" | jq -r .TunnelID)
credentials-file: ${WORK_DIR}/tunnel.json
protocol: http2
ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:8080
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
            ARGO_CMD="${WORK_DIR}/argo tunnel --edge-ip-version auto --config ${WORK_DIR}/tunnel.yml run"
        else
            ARGO_CMD="${WORK_DIR}/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${ARGO_AUTH}"
        fi
    else
        green "使用临时 Argo 隧道 (TryCloudflare)..."
        ARGO_CMD="${WORK_DIR}/argo tunnel --url http://localhost:8080 --no-autoupdate --edge-ip-version auto --protocol http2"
    fi

    # 后台启动 Argo
    nohup $ARGO_CMD > ${WORK_DIR}/argo.log 2>&1 &
}

# 8. 输出信息
print_info() {
    green "等待隧道建立..."
    sleep 10
    
    # 获取最终域名
    if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]; then
        FINAL_DOMAIN="$ARGO_DOMAIN"
    else
        FINAL_DOMAIN=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" ${WORK_DIR}/argo.log | head -n 1 | sed 's/https:\/\///')
    fi

    if [ -z "$FINAL_DOMAIN" ]; then
        red "无法获取域名，请检查 Argo Token 或网络连接！"
        cat ${WORK_DIR}/argo.log
        exit 1
    fi

    echo "========================================================="
    green "ArgoX 安装完成"
    echo "UUID: $UUID"
    echo "Domain: $FINAL_DOMAIN"
    echo "========================================================="
    
    # VLESS WS
    echo -e "\n--- VLESS WS TLS ---"
    echo "vless://${UUID}@${CDN_DOMAIN}:443?encryption=none&security=tls&sni=${FINAL_DOMAIN}&type=ws&host=${FINAL_DOMAIN}&path=%2Fargox-vl#ArgoX-VLESS"
    
    # VMess WS
    echo -e "\n--- VMess WS TLS ---"
    VMESS_JSON="{\"v\":\"2\",\"ps\":\"ArgoX-VMess\",\"add\":\"${CDN_DOMAIN}\",\"port\":\"443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"none\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${FINAL_DOMAIN}\",\"path\":\"/argox-vm\",\"tls\":\"tls\",\"sni\":\"${FINAL_DOMAIN}\",\"alpn\":\"\"}"
    echo "vmess://$(echo -n ${VMESS_JSON} | base64 -w0)"
    
    echo -e "\n========================================================="
}

# 执行
install_deps
install_core
config_xray
start_services
print_info
