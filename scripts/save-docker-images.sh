#!/bin/bash

# Docker镜像备份工具 (v1.2 - 修复版)
# 功能：从docker-compose.yml提取镜像并创建备份，支持断点续传和并行加速

# --- 全局配置 ---

# 最大并行任务数，可根据您的CPU核心数和磁盘I/O性能调整
MAX_JOBS=4

# Docker Compose 配置文件路径，默认为 docker-compose.yml
COMPOSE_FILE="${1:-docker-compose.yml}"

# 备份文件输出目录
OUTPUT_DIR="docker_images_backup"

# --- 脚本核心变量 ---
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE=""
PROGRESS_FILE=""

# 确保在脚本退出时执行清理函数
trap cleanup EXIT

# --- 脚本初始化与函数定义 ---

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# (已修复) 日志函数，将日志默认输出到 stderr
log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local formatted_message

    case $level in
        ERROR) formatted_message="${RED}[ERROR]${NC} ${message}" ;;
        WARN)  formatted_message="${YELLOW}[WARN]${NC} ${message}" ;;
        INFO)  formatted_message="${GREEN}[INFO]${NC} ${message}" ;;
        DEBUG) formatted_message="${BLUE}[DEBUG]${NC} ${message}" ;;
        *)     formatted_message="[${level}] ${message}" ;;
    esac

    # 关键修复：将日志输出到标准错误流(stderr)，避免污染函数返回值
    echo -e "$formatted_message" >&2

    # 记录到日志文件
    [[ -n "$LOG_FILE" ]] && echo "[$timestamp] [${level}] $message" >> "$LOG_FILE"
}

# 检查依赖环境
check_requirements() {
    if ! command -v docker &> /dev/null; then
        log ERROR "未找到 Docker 命令，请确保 Docker 已安装并位于您的 PATH 中。"
        exit 1
    fi

    if ! docker info &> /dev/null; then
        log ERROR "无法连接到 Docker 服务。请确保 Docker 守护进程正在运行，并且您有权限访问它。"
        exit 1
    fi

    if [[ ! -f "$COMPOSE_FILE" ]]; then
        log ERROR "Docker Compose 配置文件不存在: $COMPOSE_FILE"
        exit 1
    fi
}

# 初始化备份环境
init() {
    mkdir -p "$OUTPUT_DIR"
    LOG_FILE="$OUTPUT_DIR/backup_${TIMESTAMP}.log"
    touch "$LOG_FILE"
    PROGRESS_FILE="$OUTPUT_DIR/.backup_progress"

    log INFO "Docker 镜像备份任务启动"
    log INFO "配置文件: $COMPOSE_FILE"
    log INFO "输出目录: $OUTPUT_DIR"
    log INFO "并行任务数: $MAX_JOBS"

    if [[ -f "$PROGRESS_FILE" ]]; then
        log WARN "发现未完成的备份任务，将从上次断点处继续。"
    fi
}

# (已修复) 提取镜像列表
extract_images() {
    log INFO "使用 'docker compose config' 解析镜像列表，这是最可靠的方式..."

    local images
    # 优先使用 'docker compose' (v2)，如果失败则尝试 'docker-compose' (v1)
    if images=$(docker compose -f "$COMPOSE_FILE" config --images 2>/dev/null); then
        : # 命令成功，images 变量已赋值
    elif images=$(docker-compose -f "$COMPOSE_FILE" config --images 2>/dev/null); then
        : # 命令成功，images 变量已赋值
    else
        log ERROR "无法使用 'docker compose' 或 'docker-compose' 解析配置文件。"
        log ERROR "请确保 Docker Compose 已正确安装，并且文件 '$COMPOSE_FILE' 语法正确。"
        exit 1
    fi

    # 清理、去重并输出纯数据到 stdout
    echo "$images" | grep -v '^$' | sort -u
}

# 将镜像名转换为安全的文件名
safe_filename() {
    echo "$1" | sed 's/[/:@]/_/g' | sed 's/__*/_/g'
}

# 检查镜像是否已成功备份
is_image_backed_up() {
    local image=$1
    local filename
    filename=$(safe_filename "$image")
    local output_file="$OUTPUT_DIR/${filename}.tar.gz"

    if [[ -f "$output_file" ]] && [[ -s "$output_file" ]]; then
        if gzip -t "$output_file" &>/dev/null; then
            return 0  # 0 表示 true (已备份)
        else
            log WARN "备份文件已损坏，将重新备份: $output_file"
            rm -f "$output_file"
        fi
    fi
    return 1 # 1 表示 false (未备份)
}

# 记录备份进度
record_progress() {
    local image=$1
    local status=$2
    # 使用 flock 确保并行写入时的文件锁定，增加健壮性
    (
        flock 200
        echo "$(date '+%Y-%m-%d %H:%M:%S')|$image|$status" >> "$PROGRESS_FILE"
    ) 200>"$PROGRESS_FILE.lock"
}


# 备份单个镜像的核心函数
backup_image() {
    local image=$1
    local filename
    filename=$(safe_filename "$image")
    local output_file="$OUTPUT_DIR/${filename}.tar.gz"
    local output_tmp_file="${output_file}.tmp"

    log INFO "开始处理: $image"

    if ! docker image inspect "$image" &>/dev/null; then
        log WARN "本地不存在镜像 '$image'，正在尝试从远程仓库拉取..."
        if ! docker pull "$image"; then
            log ERROR "拉取镜像失败: $image"
            record_progress "$image" "PULL_FAILED"
            return 1
        fi
        log INFO "镜像拉取成功: $image"
    else
        log INFO "发现本地已存在镜像: $image"
    fi

    log INFO "正在备份: $image -> ${filename}.tar.gz"
    local start_time
    start_time=$(date +%s)

    if docker save "$image" | gzip > "$output_tmp_file"; then
        mv "$output_tmp_file" "$output_file"
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        local size
        size=$(du -h "$output_file" | cut -f1)

        log INFO "✓ 备份成功: $image (大小: ${size}, 耗时: ${duration}秒)"
        record_progress "$image" "SUCCESS"
        return 0
    else
        log ERROR "✗ 备份失败: $image"
        rm -f "$output_tmp_file"
        record_progress "$image" "SAVE_FAILED"
        return 1
    fi
}

# (已修复) 并行处理备份任务
process_backup() {
    local images_to_backup=("$@")
    local total=${#images_to_backup[@]}
    local pids=()
    local results_dir="$OUTPUT_DIR/.results"
    
    mkdir -p "$results_dir"
    rm -f "$results_dir"/*

    log INFO "共计 $total 个镜像需要备份，开始并行处理..."

    for i in "${!images_to_backup[@]}"; do
        local image="${images_to_backup[$i]}"
        local current_num=$((i + 1))

        (
            # 在子shell的日志中加入进度，更清晰
            log INFO "[$current_num/$total] 启动备份进程: $image"
            if backup_image "$image"; then
                touch "$results_dir/$$.success"
            else
                touch "$results_dir/$$.failed"
            fi
        ) &
        pids+=($!)

        if (( ${#pids[@]} >= MAX_JOBS )); then
            wait "${pids[0]}"
            pids=("${pids[@]:1}")
        fi
    done

    wait

    local success_count
    success_count=$(ls -1 "$results_dir"/*.success 2>/dev/null | wc -l)
    local failed_count
    failed_count=$(ls -1 "$results_dir"/*.failed 2>/dev/null | wc -l)

    # 关键：只将纯数据输出到 stdout
    echo "$success_count $failed_count"
}


# 生成清单文件
generate_manifest() {
    local manifest_file="$OUTPUT_DIR/manifest_${TIMESTAMP}.txt"
    log INFO "正在生成清单文件: $manifest_file"
    {
        echo "Docker 镜像备份清单"
        echo "============================="
        echo "生成时间: $(date)"
        echo "备份主机: $(hostname)"
        echo "来源文件: $COMPOSE_FILE"
        echo ""
        echo "备份文件列表:"
        echo "-----------------------------"

        local file_count=0

        for file in "$OUTPUT_DIR"/*.tar.gz; do
            [[ -f "$file" ]] || continue
            ((file_count++))
            local filename
            filename=$(basename "$file")
            local size_human
            size_human=$(du -h "$file" | cut -f1)
            local md5
            md5=$(md5sum "$file" | cut -d' ' -f1)
            local mtime
            mtime=$(stat -c%y "$file" 2>/dev/null | cut -d. -f1 || stat -f%Sm -t "%Y-%m-%d %H:%M:%S" "$file" 2>/dev/null)

            echo "文件: $filename"
            echo "  大小: $size_human"
            echo "  MD5 : $md5"
            echo "  时间: $mtime"
            echo ""
        done

        echo "-----------------------------"
        echo "文件总数: $file_count"
        echo "备份总体积: $(du -sh "$OUTPUT_DIR" | cut -f1)"

    } > "$manifest_file"
}


# 生成恢复脚本
generate_restore_script() {
    local restore_script="$OUTPUT_DIR/restore.sh"
    log INFO "正在生成恢复脚本: $restore_script"
    cat > "$restore_script" << 'EOF'
#!/bin/bash
# Docker镜像恢复脚本 (可自动解压并加载)

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
FAILED_LIST=""

echo "--- 开始恢复 Docker 镜像 ---"
echo "镜像来源目录: $SCRIPT_DIR"
echo ""

if ! command -v docker &> /dev/null; then
    echo -e "${RED}错误: 未找到 Docker 命令。请先安装 Docker。${NC}"
    exit 1
fi

files=("$SCRIPT_DIR"/*.tar.gz)
total=${#files[@]}
current=0
success=0
failed=0

# 检查是否有文件需要恢复
if ! [[ -f "${files[0]}" ]]; then
    echo "未找到任何 .tar.gz 格式的镜像备份文件。"
    total=0
fi

for file in "${files[@]}"; do
    [[ -f "$file" ]] || continue
    ((current++))
    filename=$(basename "$file")

    printf "[%d/%d] 正在处理: %-50s ... " "$current" "$total" "$filename"

    if ! gzip -t "$file" 2>/dev/null; then
        echo -e "${RED}失败 (文件损坏)${NC}"
        ((failed++))
        FAILED_LIST+="  - $filename (文件损坏)"$'\n'
        continue
    fi

    if gunzip -c "$file" | docker load > /dev/null 2>&1; then
        echo -e "${GREEN}成功${NC}"
        ((success++))
    else
        echo -e "${RED}失败 (Docker加载错误)${NC}"
        ((failed++))
        FAILED_LIST+="  - $filename (Docker加载错误)"$'\n'
    fi
done

echo ""
echo "--- 恢复完成 ---"
echo -e "总计: $total, ${GREEN}成功: $success${NC}, ${RED}失败: $failed${NC}"

if [[ -n "$FAILED_LIST" ]]; then
    echo ""
    echo -e "${RED}以下文件恢复失败:${NC}"
    echo -e "$FAILED_LIST"
fi
EOF

    chmod +x "$restore_script"
}

# 清理临时文件
cleanup() {
    # 增加日志，让用户知道清理操作已执行
    # log INFO "正在清理临时文件..."
    rm -rf "$OUTPUT_DIR/.results" 2>/dev/null || true
    rm -f "$OUTPUT_DIR"/*.tmp 2>/dev/null || true
    rm -f "$PROGRESS_FILE.lock" 2>/dev/null || true
}

# 显示使用帮助
usage() {
    cat << EOF

Docker 镜像备份工具 (优化版)
================================

使用方法: $0 [docker-compose-file.yml]

功能特性:
  - ✨ [可靠] 使用 'docker compose config' 精确解析镜像，无惧复杂配置。
  - ⚡ [高效] 支持多任务并行备份，大幅提升备份速度 (可配置并行数)。
  - 🔄 [智能] 支持断点续传，自动跳过已成功备份的镜像。
  - 📝 [完整] 自动生成备份清单 (manifest) 和一键恢复脚本 (restore.sh)。

示例:
  # 使用当前目录的 docker-compose.yml 进行备份
  $0

  # 使用指定的 compose 文件
  $0 /path/to/docker-compose.prod.yml

默认输出目录: ./docker_images_backup/

EOF
    exit 0
}

# --- 主函数 ---
main() {
    if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
        usage
    fi

    check_requirements
    init

    log INFO "步骤 1/4: 解析镜像列表..."
    # 此时 all_images 只会包含纯净的镜像名
    all_images=$(extract_images)

    if [[ -z "$all_images" ]]; then
        log ERROR "在 '$COMPOSE_FILE' 中未找到任何可备份的镜像。"
        exit 1
    fi

    declare -a images_to_backup
    local skipped_count=0
    
    echo "" >&2 # 输出一个空行到 stderr，用于格式美化
    log INFO "分析镜像备份状态..."
    while IFS= read -r image; do
        [[ -z "$image" ]] && continue
        if is_image_backed_up "$image"; then
            log INFO "  - $image [已备份]"
            ((skipped_count++))
        else
            log INFO "  - $image [待备份]"
            images_to_backup+=("$image")
        fi
    done <<< "$all_images"
    echo "" >&2

    local success_count=0
    local failed_count=0
    if (( ${#images_to_backup[@]} == 0 )); then
        log INFO "所有镜像均已备份，无需执行新任务。"
    else
        log INFO "步骤 2/4: 执行备份任务..."
        # 此时 results 只会包含 "成功数 失败数"
        local results
        results=$(process_backup "${images_to_backup[@]}")
        read -r success_count failed_count <<< "$results"
    fi
    
    log INFO "步骤 3/4: 生成报告和脚本..."
    generate_manifest
    generate_restore_script
    
    log INFO "步骤 4/4: 清理临时文件..."
    # cleanup 将在脚本退出时通过 trap 自动调用
    
    echo "" >&2
    echo "=================================================" >&2
    log INFO "备份任务全部完成！"
    echo "-------------------------------------------------" >&2
    echo -e "  ${GREEN}成功: $success_count${NC}" >&2
    echo -e "  ${RED}失败: $failed_count${NC}" >&2
    echo -e "  ${BLUE}跳过 (已存在): $skipped_count${NC}" >&2
    echo "-------------------------------------------------" >&2
    echo "  输出目录: $OUTPUT_DIR" >&2
    echo "  日志文件: $LOG_FILE" >&2
    echo "  恢复脚本: $OUTPUT_DIR/restore.sh" >&2
    echo "" >&2
    echo "  要恢复镜像，请执行: cd $OUTPUT_DIR && ./restore.sh" >&2
    echo "=================================================" >&2

    if (( failed_count > 0 )); then
        exit 1
    fi
}

main "$@"
