#!/usr/bin/env bash
set -Eeuo pipefail

# ==================== 配置区域 ====================
# 1. 目标检测配置
DOMAIN="${DOMAIN:-MY-DOMAIN.COM}"
CHECK_URL="${CHECK_URL:-https://$DOMAIN/}"

# 2. 根因排查配置
# IPv4 公网检测 (百度)
TEST_IPV4_URL="${TEST_IPV4_URL:-https://www.baidu.com}"
# IPv6 公网检测 (阿里DNS IPv6 Ping)
TEST_IPV6_ADDR="${TEST_IPV6_ADDR:-2400:3200::1}"
# 本地源站检测 (留空则跳过，用于判断Docker服务状态)
LOCAL_SOURCE_URL="${LOCAL_SOURCE_URL:-http://127.0.0.1:8300}"

# 3. 代理配置
ENABLE_PROXY="${ENABLE_PROXY:-false}"
PROXY_TYPE="${PROXY_TYPE:-socks5}"
PROXY_HOST="${PROXY_HOST:-192.168.100.3}"
PROXY_PORT="${PROXY_PORT:-1080}"

# 4. 运行策略
CHECK_TIMEOUT="${CHECK_TIMEOUT:-10}"       # 单次连接超时
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"     # 每次检查间隔
MAX_RETRY_COUNT="${MAX_RETRY_COUNT:-10}"   # 目标检测最大重试次数
RECOVERY_WAIT_TIME="${RECOVERY_WAIT_TIME:-300}" # 网络重启后等待时间

# 5. TrueNAS/Docker 环境配置
NETWORK_INTERFACE="${NETWORK_INTERFACE:-br0}"
RESTART_METHOD="${RESTART_METHOD:-truenas}" # truenas|systemd-networkd|raw|dhclient

# 6. 日志与锁
LOG_FILE="${LOG_FILE:-/var/log/cloudflare_monitor.log}"
LOCK_FILE="${LOCK_FILE:-/var/run/cloudflare_monitor.lock}"
# ==================== 配置结束 ====================

# 日志函数
log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_line="[$timestamp] [PID:$$] [$level] $message"
    # 同时输出到标准输出(SSH可见)和日志文件(持久化)
    echo "$log_line"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$log_line" >> "$LOG_FILE"
    fi
}
log_info() { log_message "INFO" "$1"; }
log_warn() { log_message "WARN" "$1"; }
log_error() { log_message "ERROR" "$1"; }
log_success() { log_message "SUCCESS" "$1"; }

# 锁机制
acquire_lock() {
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        echo "Script is already running (PID in lockfile)."
        exit 0
    fi
    echo $$ >&200
}

cleanup() {
    rm -f "$LOCK_FILE" 2>/dev/null
}
trap cleanup EXIT

# ==================== 核心检测函数 ====================

has_global_ipv6() {
    local iface="$1"
    # 逻辑：
    # 1. 显示指定接口的 IPv6 地址
    # 2. 筛选包含 'inet6' 和 'scope global' 的行
    # 3. 排除包含 'deprecated' 的行 (这是关键修正)
    # 4. 排除包含 'tentative' 的行 (还在地址冲突检测中，不可用)
    if ip -6 addr show dev "$iface" 2>/dev/null | grep 'inet6' | grep 'scope global' | grep -v 'deprecated' | grep -v 'tentative' | grep -q 'inet6'; then
        return 0
    else
        return 1
    fi
}

check_ipv6_connectivity() {
    # 优先测试阿里DNS，备用谷歌DNS
    local test_hosts=("$TEST_IPV6_ADDR" "2001:4860:4860::8888")
    for host in "${test_hosts[@]}"; do
        if ping6 -c 1 -W 5 "$host" >/dev/null 2>&1; then return 0; fi
    done
    return 1
}

# Curl 封装
perform_curl() {
    local url="$1"
    local use_proxy="$2"
    local args=("--connect-timeout" "$CHECK_TIMEOUT" "--max-time" "$((CHECK_TIMEOUT+5))" "-s" "-o" "/dev/null" "-w" "%{http_code}")

    if [[ "$use_proxy" == "true" ]] && [[ "$ENABLE_PROXY" == "true" ]]; then
        local proxy_url
        if [[ "$PROXY_TYPE" == "socks5" ]]; then proxy_url="socks5h://$PROXY_HOST:$PROXY_PORT"
        else proxy_url="$PROXY_TYPE://$PROXY_HOST:$PROXY_PORT"; fi
        args+=("--proxy" "$proxy_url")
    else
        args+=("--noproxy" "*")
    fi

    local code
    code=$(timeout "$((CHECK_TIMEOUT+10))" curl "${args[@]}" "$url" 2>&1 || echo "000")
    [[ "$code" =~ ^[23][0-9][0-9]$ ]] && return 0 || return 1
}

# 重启 Docker 服务 (源站不通时调用)
restart_docker_daemon() {
    log_warn "源站服务检测失败，判定为 Docker 服务异常，正在重启 Docker..."
    if systemctl restart docker; then
        log_success "Docker 服务已重启，脚本退出，等待下个周期检测。"
    else
        log_error "Docker 服务重启失败，请人工介入。"
    fi
    exit 0 # 重启 Docker 动静较大，重启后直接结束本次任务
}

# ==================== 网络重启逻辑 (核心保持不变) ====================
restart_by_truenas() {
    log_info "使用TrueNAS API方法重启接口: $NETWORK_INTERFACE"
    local interface_id
    if command -v jq &> /dev/null; then
        interface_id=$(midclt call interface.query '[["name", "=", "'"$NETWORK_INTERFACE"'"]]' | jq -r '.[0].id')
    else
        interface_id=$(midclt call interface.query | grep -B 2 "\"name\": \"$NETWORK_INTERFACE\"" | grep '"id":' | awk '{print $2}' | tr -d ',')
    fi
    if [[ -z "$interface_id" ]] || [[ "$interface_id" == "null" ]]; then log_error "无法找到接口 $NETWORK_INTERFACE 的ID"; return 1; fi
    log_info "找到接口ID: $interface_id"

    # 1. 先禁用，清理旧状态
    log_info "步骤 1/4: 禁用IPv4/IPv6自动配置"
    midclt call interface.update "$interface_id" '{"ipv4_dhcp": false, "ipv6_auto": false}'
    midclt call interface.commit '{"checkin_timeout": 60}' > /dev/null
    midclt call interface.checkin

    # 2. 【关键修改】在启用新配置之前，强制重置物理接口状态
    #    这样既能触发 IPv6 的底层状态刷新，又不会杀死即将启动的 IPv4 DHCP 进程
    log_info "步骤 2/4: 强制物理接口重置 (Down/Up)"
    ip link set "$interface_id" down
    sleep 3 # 给内核一点时间处理清理工作
    ip link set "$interface_id" up
    sleep 5 # 等待链路协商完成 (Link Up)

    # 3. 启用配置
    log_info "步骤 3/4: 重新启用IPv4/IPv6自动配置"
    midclt call interface.update "$interface_id" '{"ipv4_dhcp": true, "ipv6_auto": true}'

    # 4. 提交更改
    #    TrueNAS 此时会检测到接口已 UP，并启动 DHCP Client 和应用 IPv6 设置
    log_info "步骤 4/4: 提交并应用网络更改"
    midclt call interface.commit '{"checkin_timeout": 60}' > /dev/null
    midclt call interface.checkin

    log_info "网络重启完成，等待地址获取..."
}

restart_by_systemd() { log_info "重启systemd-networkd服务"; systemctl restart systemd-networkd; }
restart_by_raw() { log_info "使用ip命令重启接口: $NETWORK_INTERFACE"; ip link set "$NETWORK_INTERFACE" down; sleep 3; ip link set "$NETWORK_INTERFACE" up; }
restart_by_dhclient() {
    log_info "重启DHCPv6客户端"; dhclient -6 -r "$NETWORK_INTERFACE" >/dev/null 2>&1 || true; sleep 2; dhclient -6 "$NETWORK_INTERFACE" >/dev/null 2>&1; sleep 3
    if ! has_global_ipv6 "$NETWORK_INTERFACE"; then restart_by_raw; fi
}

wait_ipv6_ready() {
    local deadline=$((SECONDS + RECOVERY_WAIT_TIME))
    log_info "等待IPv6网络恢复，最长 ${RECOVERY_WAIT_TIME}秒"
    while ((SECONDS < deadline)); do
        # 这里的 has_global_ipv6 已经包含了对 deprecated 的过滤
        if has_global_ipv6 "$NETWORK_INTERFACE"; then
            log_info "检测到有效IPv6地址，测试外网连接..."
            if check_ipv6_connectivity; then
                log_success "IPv6网络完全恢复"; log_info "恢复后网络状态:"; ip -6 addr show "$NETWORK_INTERFACE" | grep inet6 | while IFS= read -r line; do log_info "  $line"; done
                return 0
            fi
        fi
        sleep 5
    done
    log_error "超时: ${RECOVERY_WAIT_TIME}秒内IPv6网络未完全恢复"; return 1
}

restart_ipv6_network() {
    log_warn "开始重启IPv6网络环境"; log_info "重启前网络状态:"; ip -6 addr show "$NETWORK_INTERFACE" | grep inet6 | while IFS= read -r line; do log_info "  $line"; done
    case "$RESTART_METHOD" in
        truenas) restart_by_truenas ;;
        systemd-networkd) restart_by_systemd ;;
        raw) restart_by_raw ;;
        dhclient) restart_by_dhclient ;;
        *) log_error "未知的重启方法: $RESTART_METHOD"; return 1 ;;
    esac

    if wait_ipv6_ready; then
        log_success "IPv6网络重启成功"
        log_info "重启所有容器服务"
        systemctl restart docker
        log_success "重启所有容器服务成功"
        return 0
    else
        log_error "IPv6网络重启失败"; return 1
    fi
}

# ==================== 主逻辑 ====================
main() {
    acquire_lock

    if [[ $EUID -ne 0 ]]; then
        log_error "Please run as root."
        exit 1
    fi

    # 1. 检查 IPv4 宽带连接 (基础物理层/光猫)
    if ! perform_curl "$TEST_IPV4_URL" "false"; then
        log_error "IPv4 公网连接异常 ($TEST_IPV4_URL)，中止任务。"
        exit 1
    fi

    # 2. 检查 IPv6 宽带连接 (运营商IPv6网络)
    if ! check_ipv6_connectivity; then
         log_error "IPv6 公网连接异常 (Ping $TEST_IPV6_ADDR 失败)，可能是运营商问题，中止任务。"
         exit 1
    fi

    # 3. 检查本地源站 (Docker 状态)
    if [[ -n "$LOCAL_SOURCE_URL" ]]; then
        local local_retry=0
        local local_ok=false
        while [[ $local_retry -lt 3 ]]; do
            if perform_curl "$LOCAL_SOURCE_URL" "false"; then
                local_ok=true
                break
            fi
            ((local_retry++))
            sleep 2
        done

        if [[ "$local_ok" == "false" ]]; then
            log_error "本地源站无法访问 ($LOCAL_SOURCE_URL)，网络正常但服务不可达。"
            restart_docker_daemon
        fi
    fi

    # 4. 检查目标域名 (最终端到端测试)
    local target_ok=false
    for ((i=1; i<=MAX_RETRY_COUNT; i++)); do
        if perform_curl "$CHECK_URL" "true"; then
            target_ok=true
            log_success "目标域名访问正常"
            break
        else
            log_warn "目标访问失败 ($i/$MAX_RETRY_COUNT): $CHECK_URL"
            if [[ $i -lt $MAX_RETRY_COUNT ]]; then sleep 10; fi
        fi
    done

    # 5. 判定修复
    if [[ "$target_ok" == "false" ]]; then
        log_error "故障判定: [宽带IPv4/v6正常] + [源站正常] + [目标不可达]。执行网络重置。"
        restart_ipv6_network
    fi
}

main "$@"
