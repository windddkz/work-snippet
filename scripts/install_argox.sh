#!/bin/bash

# ==============================================================
# ArgoX Ultimate - In-Memory Config | No Sleep | CI/CD Optimized
# ==============================================================

# 1. 核心参数解析 (直接读取管道/文件描述符，不检查文件存在性)
CONFIG_SOURCE=""
while getopts "f:" opt; do
  case $opt in
    f) CONFIG_SOURCE=$OPTARG ;;
  esac
done

# 如果未指定配置源，尝试读取 ARGO_AUTH 环境变量，否则报错
if [ -z "$CONFIG_SOURCE" ]; then
    # 允许不传 -f，直接通过环境变量运行的兼容模式
    if [ -z "$ARGO_AUTH" ]; then
        echo -e "\033[31m错误: 未指定配置来源。请使用 -f <(wget ...) 或设置环境变量。\033[0m"
        exit 1
    fi
else
    # 关键修改：直接 source 传入的文件描述符，不进行 [ -f ] 检查
    # 这解决了 bash <(...) -f <(...) 报错的问题
    source "$CONFIG_SOURCE"
fi

# 2. 变量初始化 (内存缺省值)
WORK_DIR="/etc/argox"
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
ARGO_PORT=8080
CDN_DOMAIN="www.visa.com.sg"

# 颜色定义
green() { echo -e "\033[32m\033[01m$1\033[0m"; }
red() { echo -e "\033[31m\033[01m$1\033[0m"; }

# 3. 环境清理与目录准备
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
chmod 777 "$WORK_DIR"

# 4. 极速安装依赖 & 核心 (并行下载)
install_core() {
    green "🚀 安装依赖与核心组件..."
    
    # 依赖安装
    if [ -f /etc/alpine-release ]; then
        apk add --no-cache bash curl unzip jq coreutils openssl ca-certificates iptables >/dev/null 2>&1
    elif [ -f /etc/debian_version ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl unzip jq coreutils openssl ca-certificates iptables >/dev/null 2>&1
    else
        yum install -y curl unzip jq coreutils openssl ca-certificates iptables >/dev/null 2>&1
    fi

    # 架构检测
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64') ARCH='amd64'; XRAY_ARCH='64' ;;
        'aarch64' | 'arm64') ARCH='arm64'; XRAY_ARCH='arm64-v8a' ;;
        *) red "不支持架构: ${ARCH_RAW}"; exit 1 ;;
    esac

    # 并行下载 Xray 和 Cloudflared
    (curl -sL "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip" -o "${WORK_DIR}/xray.zip" && \
     unzip -qo "${WORK_DIR}/xray.zip" -d "${WORK_DIR}" && \
     rm "${WORK_DIR}/xray.zip" && chmod +x "${WORK_DIR}/xray") &

    (curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" -o "${WORK_DIR}/argo" && \
     chmod +x "${WORK_DIR}/argo") &

    wait # 等待下载完成
}

# 5. 生成 Xray 纯净配置 (无 Vision 流控)
config_xray() {
    cat > "${WORK_DIR}/config.json" << EOF
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
  "inbounds": [
    {
      "port": $ARGO_PORT, "listen": "127.0.0.1", "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID", "flow": "" }],
        "decryption": "none",
        "fallbacks": [
          { "path": "/vl", "dest": 3001 },
          { "path": "/vm", "dest": 3002 },
          { "path": "/tr", "dest": 3003 }
        ]
      },
      "streamSettings": { "network": "tcp" }
    },
    {
      "port": 3001, "listen": "127.0.0.1", "protocol": "vless",
      "settings": { "clients": [{ "id": "$UUID", "level": 0 }], "decryption": "none" },
      "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "/vl" } }
    },
    {
      "port": 3002, "listen": "127.0.0.1", "protocol": "vmess",
      "settings": { "clients": [{ "id": "$UUID", "alterId": 0 }] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vm" } }
    },
    {
      "port": 3003, "listen": "127.0.0.1", "protocol": "trojan",
      "settings": { "clients": [{ "password": "$UUID" }] },
      "streamSettings": { "network": "ws", "security": "none", "wsSettings": { "path": "/tr" } }
    }
  ],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
}

# 6. 启动服务与输出
start_and_print() {
    green "🔥 启动服务..."
    
    # 启动 Xray (后台运行)
    nohup "${WORK_DIR}/xray" run -c "${WORK_DIR}/config.json" >/dev/null 2>&1 &

    # 启动 Argo
    if [ -n "$ARGO_AUTH" ]; then
        # >>> 模式 A: 固定隧道 (Token/Json) <<<
        if [[ "$ARGO_AUTH" =~ TunnelSecret ]]; then
            echo "$ARGO_AUTH" > "${WORK_DIR}/tunnel.json"
            cat > "${WORK_DIR}/tunnel.yml" << EOF
tunnel: $(echo "$ARGO_AUTH" | jq -r .TunnelID)
credentials-file: ${WORK_DIR}/tunnel.json
protocol: http2
ingress:
  - hostname: $ARGO_DOMAIN
    service: http://localhost:$ARGO_PORT
    originRequest: noTLSVerify: true
  - service: http_status:404
EOF
            nohup "${WORK_DIR}/argo" tunnel --edge-ip-version auto --config "${WORK_DIR}/tunnel.yml" run >/dev/null 2>&1 &
        else
            nohup "${WORK_DIR}/argo" tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token "$ARGO_AUTH" >/dev/null 2>&1 &
        fi
        
        # 固定隧道无需等待，直接使用配置中的域名
        FINAL_DOMAIN="$ARGO_DOMAIN"
        
    else
        # >>> 模式 B: 临时隧道 (TryCloudflare) <<<
        nohup "${WORK_DIR}/argo" tunnel --url "http://localhost:$ARGO_PORT" --no-autoupdate --edge-ip-version auto --protocol http2 > "${WORK_DIR}/argo.log" 2>&1 &
        
        echo "⏳ 等待临时域名分配..."
        # 高效轮询：一旦日志中出现域名立即退出循环，不使用硬 sleep
        for i in {1..30}; do
            if grep -q "trycloudflare.com" "${WORK_DIR}/argo.log"; then
                FINAL_DOMAIN=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" "${WORK_DIR}/argo.log" | head -n 1 | sed 's/https:\/\///')
                break
            fi
            sleep 1 # 仅在未获取到时等待1秒
        done
    fi

    if [ -z "$FINAL_DOMAIN" ]; then
        red "❌ 启动失败: 无法获取 Argo 域名，请检查 Token 或网络。"
        exit 1
    fi

    # 输出结果
    echo ""
    echo "========================================================="
    echo -e "✅ \033[32m安装成功\033[0m | UUID: \033[35m$UUID\033[0m"
    echo -e "🔗 域名: \033[36m$FINAL_DOMAIN\033[0m"
    echo "========================================================="
    
    # 构建链接
    VLESS="vless://${UUID}@${CDN_DOMAIN}:443?encryption=none&security=tls&sni=${FINAL_DOMAIN}&type=ws&host=${FINAL_DOMAIN}&path=%2Fvl#ArgoX-VLESS"
    
    VMESS_JSON="{\"v\":\"2\",\"ps\":\"ArgoX-VMess\",\"add\":\"${CDN_DOMAIN}\",\"port\":\"443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"none\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${FINAL_DOMAIN}\",\"path\":\"/vm\",\"tls\":\"tls\",\"sni\":\"${FINAL_DOMAIN}\",\"alpn\":\"\"}"
    VMESS="vmess://$(echo -n ${VMESS_JSON} | base64 -w0 | tr -d '\n')"
    
    TROJAN="trojan://${UUID}@${CDN_DOMAIN}:443?security=tls&sni=${FINAL_DOMAIN}&type=ws&host=${FINAL_DOMAIN}&path=%2Ftr#ArgoX-Trojan"

    echo -e "📡 \033[33mVLESS:\033[0m $VLESS"
    echo -e "📡 \033[33mVMess:\033[0m $VMESS"
    echo -e "📡 \033[33mTrojan:\033[0m $TROJAN"
    echo "========================================================="
}

# 执行主流程
install_core
config_xray
start_and_print
