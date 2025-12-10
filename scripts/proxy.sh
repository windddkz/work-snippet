#!/bin/bash

# ==============================================================================
# Linux Shell Proxy Manager (Enhanced)
# 功能：智能设置/取消/测试 Shell 代理
# 特性：支持协议切换、配置记忆、连接测试、Zsh/Bash兼容
#
# 用法：
#   source proxy.sh set [IP] [PORT] [PROTOCOL]
#       - 示例: source proxy.sh set 7890           (默认 127.0.0.1, http)
#       - 示例: source proxy.sh set 192.168.1.5 1080 socks5
#   source proxy.sh unset
#   source proxy.sh show
#   source proxy.sh test
# ==============================================================================

# --- 1. 兼容性更强的 source 检测 (支持 Zsh 和 Bash) ---
(return 0 2>/dev/null) && sourced=1 || sourced=0
if [ $sourced -eq 0 ]; then
    echo -e "\033[31m[Error] 脚本必须通过 source 或 . 命令执行！\033[0m"
    echo -e "请使用: \033[32msource ${0} set 7890\033[0m"
    exit 1
fi

# --- 2. 配置持久化文件路径 ---
CONFIG_FILE="$HOME/.proxy_last_config"

# --- 3. 辅助函数 ---
function _echo_info() { echo -e "\033[36m$1\033[0m"; }
function _echo_success() { echo -e "\033[32m$1\033[0m"; }
function _echo_warn() { echo -e "\033[33m$1\033[0m"; }
function _echo_error() { echo -e "\033[31m$1\033[0m"; }

# --- 4. 核心逻辑 ---
action=${1:-"show"} # 默认行为改为 show
arg1=$2
arg2=$3
arg3=$4

case "$action" in
    set)
        # 智能参数解析
        local p_host="127.0.0.1"
        local p_port=""
        local p_proto="http"

        # 场景 A: source proxy.sh set (无参，尝试读取上次配置)
        if [[ -z "$arg1" ]]; then
            if [[ -f "$CONFIG_FILE" ]]; then
                source "$CONFIG_FILE"
                p_host="$LAST_HOST"
                p_port="$LAST_PORT"
                p_proto="${LAST_PROTO:-http}"
                _echo_info "读取上次配置: $p_host:$p_port ($p_proto)"
            else
                _echo_error "未指定参数且无历史配置。"
                _echo_info "用法: source proxy.sh set [IP] [PORT] [PROTO]"
                return 1
            fi
        # 场景 B: source proxy.sh set 7890 (单参数视作端口)
        elif [[ "$arg1" =~ ^[0-9]+$ ]] && [[ -z "$arg2" ]]; then
            p_port="$arg1"
        # 场景 C: source proxy.sh set 192.168.1.x 7890 [socks5]
        else
            p_host="$arg1"
            p_port="$arg2"
            if [[ -n "$arg3" ]]; then p_proto="$arg3"; fi
        fi

        if [[ -z "$p_port" ]]; then
            _echo_error "错误: 必须指定端口。"
            return 1
        fi

        # 构造代理 URL
        local proxy_url="${p_proto}://${p_host}:${p_port}"
        
        # 智能 no_proxy (追加模式，保留原有 no_proxy，防止覆盖公司内网设置)
        local basic_no_proxy="localhost,127.0.0.1,::1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,100.64.0.0/10"
        # 去重并合并
        if [[ -z "$no_proxy" ]]; then
            export no_proxy="$basic_no_proxy"
        else
            # 简单追加，不复杂的去重
            export no_proxy="$basic_no_proxy,$no_proxy"
        fi
        export NO_PROXY="$no_proxy"

        # 设置环境变量
        export http_proxy="${proxy_url}"
        export https_proxy="${proxy_url}"
        export ftp_proxy="${proxy_url}"
        export all_proxy="${proxy_url}"
        
        # 大写兼容
        export HTTP_PROXY="${proxy_url}"
        export HTTPS_PROXY="${proxy_url}"
        export FTP_PROXY="${proxy_url}"
        export ALL_PROXY="${proxy_url}"

        # 保存配置供下次无参使用
        echo "LAST_HOST='$p_host'" > "$CONFIG_FILE"
        echo "LAST_PORT='$p_port'" >> "$CONFIG_FILE"
        echo "LAST_PROTO='$p_proto'" >> "$CONFIG_FILE"

        _echo_success "代理已开启 -> ${proxy_url}"
        ;;

    unset)
        unset http_proxy https_proxy ftp_proxy all_proxy no_proxy
        unset HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY NO_PROXY
        _echo_success "代理已清除 (Unset)"
        ;;

    test)
        # 新增：连接测试功能
        if [[ -z "$http_proxy" ]]; then
            _echo_warn "警告: 当前未设置代理环境变量，测试可能直接走直连。"
        fi
        _echo_info "正在测试连接 Google ..."
        start_time=$(date +%s%N)
        # -I 仅请求头，-s 静默，-w 输出格式，--connect-timeout 超时限制
        http_code=$(curl -I -s --connect-timeout 3 -o /dev/null -w "%{http_code}" https://www.google.com)
        end_time=$(date +%s%N)
        
        if [[ "$http_code" == "200" ]]; then
            duration=$(( ($end_time - $start_time) / 1000000 ))
            _echo_success "连接成功! [Google] 响应码: $http_code 耗时: ${duration}ms"
        else
            _echo_error "连接失败! [Google] 响应码: $http_code (000代表超时或无法解析)"
        fi
        ;;

    show)
        echo "当前代理状态:"
        echo "------------------------------"
        # 漂亮的格式化输出
        env | grep -i "_proxy" | sort | while read line; do
            key=${line%%=*}
            val=${line#*=}
            printf "\033[33m%-15s\033[0m %s\n" "$key" "$val"
        done
        echo "------------------------------"
        if [[ -z $(env | grep -i "_proxy") ]]; then
            _echo_info "未设置代理。"
        fi
        ;;

    *)
        _echo_info "Linux Proxy Manager 使用说明:"
        echo "  source ${0} set <PORT>               : 开启本地代理 (默认http)"
        echo "  source ${0} set <IP> <PORT> [PROTO]  : 开启远程/自定义协议代理"
        echo "  source ${0} unset                    : 关闭代理"
        echo "  source ${0} test                     : 测试连通性 (curl Google)"
        echo "  source ${0} show                     : 查看当前变量"
        ;;
esac
