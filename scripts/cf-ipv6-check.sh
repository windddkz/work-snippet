#!/usr/bin/env bash
set -Eeuo pipefail

# ==================== 配置参数 ====================
# 基本配置
DOMAIN="${DOMAIN:-MY-DOMAIN.COM}"
CHECK_URL="${CHECK_URL:-https://$DOMAIN/}"
PROXY_TYPE="${PROXY_TYPE:-socks5}"          # http|socks5
PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-1082}"
NETWORK_INTERFACE="${NETWORK_INTERFACE:-br0}"

# 网络重启方式配置
RESTART_METHOD="${RESTART_METHOD:-truenas}"  # truenas|systemd-networkd|raw|dhclient

# DDNS 更新配置
ENABLE_DDNS_RESTART="${ENABLE_DDNS_RESTART:-true}"
DDNS_COMPOSE_DIR="${DDNS_COMPOSE_DIR:-/root/docker-data/ddns-updater}"
DDNS_COMPOSE_SERVICE="${DDNS_COMPOSE_SERVICE:-ddns-updater}"

# 检测参数
CHECK_TIMEOUT="${CHECK_TIMEOUT:-15}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
MAX_RETRY_COUNT="${MAX_RETRY_COUNT:-3}"
RECOVERY_WAIT_TIME="${RECOVERY_WAIT_TIME:-120}"

# 高级配置
ENABLE_EXPONENTIAL_BACKOFF="${ENABLE_EXPONENTIAL_BACKOFF:-true}"
MAX_BACKOFF_INTERVAL="${MAX_BACKOFF_INTERVAL:-300}"
LOG_MAX_SIZE="${LOG_MAX_SIZE:-10485760}"   # 10MB
ENABLE_SYSLOG="${ENABLE_SYSLOG:-false}"

# 文件路径
LOG_FILE="${LOG_FILE:-/var/log/cloudflare_monitor.log}"
LOCK_FILE="${LOCK_FILE:-/var/run/cloudflare_monitor.lock}"
CONFIG_FILE="${CONFIG_FILE:-/etc/cloudflare-monitor.conf}"

# 内部变量
SCRIPT_PID=$$
CURRENT_BACKOFF_INTERVAL=$CHECK_INTERVAL
CONSECUTIVE_FAILURES=0

# ==================== 配置文件加载 ====================
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "加载配置文件: $CONFIG_FILE"
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
}

# ==================== 错误处理 ====================
error_handler() {
    local line_no=$1
    local error_code=$2
    log_error "脚本在第 $line_no 行发生错误 (退出码: $error_code)"
    cleanup
    exit "$error_code"
}

trap 'error_handler ${LINENO} $?' ERR
trap cleanup SIGTERM SIGINT

# ==================== 日志系统 ====================
log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_line="[$timestamp] [$$] [$level] $message"
    echo "$log_line"
    if [[ "$ENABLE_SYSLOG" == "true" ]]; then
        logger -t "cloudflare-monitor" -p "daemon.$level" "$message"
    fi
    if [[ -n "$LOG_FILE" ]]; then
        rotate_log_if_needed
        echo "$log_line" >> "$LOG_FILE"
    fi
}

rotate_log_if_needed() {
    if [[ -f "$LOG_FILE" ]] && [[ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt $LOG_MAX_SIZE ]]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
        log_info "日志文件已轮换"
    fi
}

log_info() { log_message "info" "$1"; }
log_warn() { log_message "warning" "$1"; }
log_error() { log_message "error" "$1"; }
log_success() { log_message "notice" "$1"; }

# ==================== 锁机制 ====================
acquire_lock() {
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then echo "脚本已在运行，退出"; exit 1; fi
    echo $$ >&200
}

# ==================== 初始化检查 ====================
init_check() {
    log_info "========== 脚本启动 (版本 2.2 - DDNS & Curl Fix) =========="
    log_info "检测URL: $CHECK_URL"; log_info "代理类型: $PROXY_TYPE"; log_info "代理地址: $PROXY_HOST:$PROXY_PORT"; log_info "网络接口: $NETWORK_INTERFACE"; log_info "重启方式: $RESTART_METHOD"
    if [[ "$ENABLE_DDNS_RESTART" == "true" ]]; then log_info "DDNS重启已启用: $DDNS_COMPOSE_DIR"; fi

    if [[ $EUID -ne 0 ]]; then log_error "此脚本需要root权限运行"; exit 1; fi

    local required_commands=("curl" "ip"); if [[ "$ENABLE_DDNS_RESTART" == "true" ]]; then required_commands+=("docker"); fi
    case "$RESTART_METHOD" in
        truenas) required_commands+=("midclt") ;;
        systemd-networkd) required_commands+=("systemctl") ;;
        dhclient) required_commands+=("dhclient") ;;
    esac

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then log_error "缺少必要命令: $cmd"; exit 1; fi
    done
    if ! ip link show "$NETWORK_INTERFACE" &> /dev/null; then log_error "网络接口 $NETWORK_INTERFACE 不存在"; exit 1; fi
    if [[ "$ENABLE_DDNS_RESTART" == "true" ]] && [[ ! -f "$DDNS_COMPOSE_DIR/docker-compose.yml" ]]; then
        log_warn "DDNS重启已启用，但找不到docker-compose.yml文件: $DDNS_COMPOSE_DIR"
    fi
    log_info "初始化检查完成，PID: $$"
}

# ==================== 网络状态检查 ====================
has_global_ipv6() { ip -6 addr show "$1" 2>/dev/null | grep -q 'inet6.*scope global'; }
check_ipv6_connectivity() {
    local test_hosts=("2606:4700:4700::1111" "2001:4860:4860::8888")
    for host in "${test_hosts[@]}"; do if ping6 -c1 -W3 "$host" >/dev/null 2>&1; then return 0; fi; done
    return 1
}

# ==================== 代理URL构建 (已修复) ====================
build_proxy_url() {
    case "$PROXY_TYPE" in
        http|https) echo "$PROXY_TYPE://$PROXY_HOST:$PROXY_PORT" ;;
        # 注意：这里我们只构建基础URL，代理类型特定参数在build_curl_args中处理
        socks5) echo "socks5h://$PROXY_HOST:$PROXY_PORT" ;;
        *) log_error "不支持的代理类型: $PROXY_TYPE"; exit 1 ;;
    esac
}

build_curl_args() {
    local proxy_url
    proxy_url=$(build_proxy_url)
    # 使用socks5h协议方案，它等同于 --socks5-hostname
    # 这是一种更现代、兼容性更好的方式，让代理服务器执行DNS解析
    local args=(
        "--proxy" "$proxy_url" "--connect-timeout" "$CHECK_TIMEOUT"
        "--max-time" "$((CHECK_TIMEOUT * 2))" "--user-agent" "CloudflareMonitor/2.2"
        "--fail" "--silent" "--show-error" "-o" "/dev/null" "-w" "%{http_code}"
    )
    printf '%s\n' "${args[@]}"
}

# ==================== 域名访问检测 ====================
check_domain_accessibility() {
    local retry_count=0
    log_info "开始检测域名访问: $CHECK_URL"
    while [[ $retry_count -lt $MAX_RETRY_COUNT ]]; do
        ((retry_count++)); log_info "第 $retry_count 次检测尝试"
        local curl_args; mapfile -t curl_args < <(build_curl_args)
        local http_code curl_exit_code
        if http_code=$(curl "${curl_args[@]}" "$CHECK_URL" 2>&1); then
            curl_exit_code=0
        else
            curl_exit_code=$?
        fi
        log_info "Curl退出码: $curl_exit_code, HTTP状态码: $http_code"
        if [[ $curl_exit_code -eq 0 ]] && [[ "$http_code" =~ ^[23][0-9][0-9]$ ]]; then
            log_success "域名访问正常 (HTTP $http_code)"; CONSECUTIVE_FAILURES=0; CURRENT_BACKOFF_INTERVAL=$CHECK_INTERVAL; return 0
        fi
        log_warn "访问失败 - 退出码: $curl_exit_code, HTTP: $http_code"
        if [[ $retry_count -lt $MAX_RETRY_COUNT ]]; then log_info "等待10秒后重试..."; sleep 10; fi
    done
    log_error "经过 $MAX_RETRY_COUNT 次尝试，域名仍无法访问"; ((CONSECUTIVE_FAILURES++)); calculate_backoff_interval; return 1
}

# ==================== 指数退避 ====================
calculate_backoff_interval() {
    if [[ "$ENABLE_EXPONENTIAL_BACKOFF" != "true" ]]; then return; fi
    local backoff_multiplier=$((2 ** (CONSECUTIVE_FAILURES - 1)))
    CURRENT_BACKOFF_INTERVAL=$((CHECK_INTERVAL * backoff_multiplier))
    if [[ $CURRENT_BACKOFF_INTERVAL -gt $MAX_BACKOFF_INTERVAL ]]; then CURRENT_BACKOFF_INTERVAL=$MAX_BACKOFF_INTERVAL; fi
    log_info "连续失败 $CONSECUTIVE_FAILURES 次，下次检测间隔: ${CURRENT_BACKOFF_INTERVAL}秒"
}

# ==================== 网络重启与DDNS触发 (已更新) ====================
trigger_ddns_restart() {
    if [[ "$ENABLE_DDNS_RESTART" != "true" ]]; then
        log_info "DDNS重启被禁用，跳过此步骤"
        return
    fi
    log_info "开始触发DDNS更新..."
    if ! cd "$DDNS_COMPOSE_DIR"; then
        log_error "无法进入DDNS目录: $DDNS_COMPOSE_DIR"
        return 1
    fi
    if ! docker-compose restart "$DDNS_COMPOSE_SERVICE"; then
        log_error "重启DDNS服务失败: $DDNS_COMPOSE_SERVICE"
        # 返回脚本原目录
        cd - > /dev/null
        return 1
    fi
    log_success "DDNS服务 ($DDNS_COMPOSE_SERVICE) 重启指令已发送"
    # 最后强制重启所有 docker 容器
    systemctl restart docker
    # 返回脚本原目录
    cd - > /dev/null
}

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

    log_info "步骤 1/3: 禁用IPv6自动配置"; midclt call interface.update "$interface_id" '{"ipv6_auto": false}'
    log_info "步骤 2/3: 提交网络更改"; midclt call interface.commit '{"checkin_timeout": 60}' > /dev/null
    log_info "步骤 3/3: 确认网络更改"; midclt call interface.checkin
    log_info "已禁用IPv6自动配置，等待5秒以确保状态刷新"; sleep 5

    log_info "步骤 1/3: 重新启用IPv6自动配置"; midclt call interface.update "$interface_id" '{"ipv6_auto": true}'
    log_info "步骤 2/3: 提交网络更改"; midclt call interface.commit '{"checkin_timeout": 60}' > /dev/null
    log_info "步骤 3/3: 确认网络更改"; midclt call interface.checkin
}

restart_by_systemd() { log_info "重启systemd-networkd服务"; systemctl restart systemd-networkd; }
restart_by_raw() { log_info "使用ip命令重启接口: $NETWORK_INTERFACE"; ip link set "$NETWORK_INTERFACE" down; sleep 3; ip link set "$NETWORK_INTERFACE" up; }
restart_by_dhclient() {
    log_info "重启DHCPv6客户端"; dhclient -6 -r "$NETWORK_INTERFACE" >/dev/null 2>&1 || true; sleep 2; dhclient -6 "$NETWORK_INTERFACE" >/dev/null 2>&1; sleep 3
    if ! has_global_ipv6 "$NETWORK_INTERFACE"; then restart_by_raw; fi
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
        trigger_ddns_restart # 在网络恢复后触发DDNS
        return 0
    else
        log_error "IPv6网络重启失败"; return 1
    fi
}

wait_ipv6_ready() {
    local deadline=$((SECONDS + RECOVERY_WAIT_TIME))
    log_info "等待IPv6网络恢复，最长 ${RECOVERY_WAIT_TIME}秒"
    while ((SECONDS < deadline)); do
        if has_global_ipv6 "$NETWORK_INTERFACE"; then
            log_info "检测到IPv6地址，测试外网连接..."
            if check_ipv6_connectivity; then
                log_success "IPv6网络完全恢复"; log_info "恢复后网络状态:"; ip -6 addr show "$NETWORK_INTERFACE" | grep inet6 | while IFS= read -r line; do log_info "  $line"; done
                return 0
            fi
        fi
        sleep 5
    done
    log_error "超时: ${RECOVERY_WAIT_TIME}秒内IPv6网络未完全恢复"; return 1
}

# ==================== 自检功能 ====================
self_check() {
    echo "=== Cloudflare Monitor 自检 ==="; echo "配置检查:"; echo "  域名: $DOMAIN"; echo "  检测URL: $CHECK_URL"; echo "  代理: $PROXY_TYPE://$PROXY_HOST:$PROXY_PORT"; echo "  网络接口: $NETWORK_INTERFACE"; echo "  重启方式: $RESTART_METHOD"; echo
    echo "网络状态:"; if has_global_ipv6 "$NETWORK_INTERFACE"; then echo "  ✓ IPv6地址: $(ip -6 addr show "$NETWORK_INTERFACE" | grep 'inet6.*global' | awk '{print $2}' | head -1)"; else echo "  ✗ 无IPv6地址"; fi
    if check_ipv6_connectivity; then echo "  ✓ IPv6外网连通"; else echo "  ✗ IPv6外网不通"; fi
    echo; echo "域名检查:"; if check_domain_accessibility; then echo "  ✓ 域名访问正常"; else echo "  ✗ 域名访问失败"; fi
}

# ==================== 主循环 ====================
main_check() {
    log_info "========== 开始单次检测和修复任务 =========="
    if check_domain_accessibility; then
        log_success "检测通过，任务正常结束。"
    else
        log_error "域名访问异常，执行网络修复..."
        if restart_ipv6_network; then
            log_success "网络修复成功。"
        else
            log_error "网络修复失败。"
        fi
    fi
    log_info "================ 任务结束 ================"
}

# ==================== 清理功能 ====================
cleanup() { log_info "收到退出信号，清理资源"; log_info "脚本退出"; exit 0; }

# ==================== 主函数 (已更新) ====================
show_help() {
    cat << EOF
用法: $0 [选项]

此脚本用于监控通过特定代理的域名访问，并在失败时尝试通过重启网络来恢复。
特别优化了对TrueNAS SCALE系统的支持，并能在恢复后触发DDNS更新。

选项:
  --check       执行一次检查并退出
  --restart     强制重启网络并退出
  --self-check  显示配置和状态信息
  --help        显示此帮助信息

环境变量:
  DOMAIN                目标域名
  PROXY_HOST           代理主机
  PROXY_PORT           代理端口
  NETWORK_INTERFACE    网络接口名 (默认: br0)
  RESTART_METHOD       重启方式(truenas|systemd-networkd|raw|dhclient) (默认: truenas)
  ENABLE_DDNS_RESTART  是否重启DDNS (true|false, 默认: true)
  DDNS_COMPOSE_DIR     DDNS docker-compose.yml 所在目录

配置文件: $CONFIG_FILE
EOF
}

main() {
    load_config
    case "${1:-}" in
        --help|-h) show_help; exit 0 ;;
        --self-check) init_check; self_check; exit 0 ;;
        --check) init_check; check_domain_accessibility; exit $? ;;
        --restart) init_check; restart_ipv6_network; exit $? ;;
        *) # 任何其他情况，包括不带参数，都执行主任务
            acquire_lock
            init_check
            main_check
            ;;
    esac
}

# 执行主函数
main "$@"
