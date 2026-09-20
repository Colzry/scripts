#!/usr/bin/env bash
# ===========================================================================
#  Colzry/scripts —— 脚本集合统一入口 (Unified Launcher)
#
#  作用: 只需记住一条命令即可调用仓库内的全部管理脚本，无需为每个脚本单独
#        记录/分享下载链接。入口会按需把目标脚本拉取到本地缓存后运行。
#
#  用法:
#    1) 交互式菜单 (推荐, 任意目录可用):
#       bash -c "$(curl -fsSL https://gitpy.223327.xyz/https://raw.githubusercontent.com/Colzry/scripts/main/main.sh)"
#
#    2) 直接启动指定脚本 (用编号或文件名关键字):
#       SCRIPT_ID=aria2 bash -c "$(curl -fsSL https://gitpy.223327.xyz/https://raw.githubusercontent.com/Colzry/scripts/main/main.sh)"
#
#    3) 已克隆/已下载到本地时:
#       ./main.sh            # 打开菜单
#       ./main.sh 3          # 直接运行第 3 个脚本
#       ./main.sh frp        # 按文件名关键字匹配并运行
# ===========================================================================

set -uo pipefail

# ---------------------------- 仓库与下载源配置 ----------------------------
REPO_OWNER="Colzry"
REPO_NAME="scripts"
REPO_BRANCH="main"

GH_RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"
PROXY_PREFIX="https://gitpy.223327.xyz/"
PROXY_LABEL="加速节点 (gitpy.223327.xyz)"
GH_LABEL="GitHub 原生 (raw.githubusercontent.com)"

# 缓存有效期(小时): 超过则尝试联网刷新, 刷新失败自动回退到旧缓存
CACHE_TTL_HOURS=24

# ---------------------------- 终端色彩定义 ----------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---------------------------- 脚本注册表 ----------------------------
# 新增脚本时只需在下方追加一行: 文件名|菜单标题|功能简介
SCRIPT_ENTRIES=(
    "aria2_manager.sh|Aria2 & AriaNg 管理|安装/配置后端、做种与限速、BT Trackers、吸血 Peer 防火墙、任务迁移、日志排查、清理工具箱"
    "filebrowser_manager.sh|FileBrowser Quantum 管理|安装/更新、全局设置与源目录管理、账号管理、启停控制、状态查看与卸载"
    "frp_manager.sh|FRP 内网穿透管理|frps / frpc 安装更新、多实例配置管理、服务启停看板、Acme.sh 证书申请与部署、完整卸载"
    "rathole_manager.sh|Rathole 内网穿透管理|服务端 / 客户端安装更新、配置与实例管理、Acme.sh 证书与续期 Hook、完整卸载"
    "webdav_manager.sh|WebDAV 文件服务管理|安装/更新、全局设置与账号增删改、启停控制、状态查看与卸载"
)
SCRIPT_COUNT=${#SCRIPT_ENTRIES[@]}

entry_file()  { printf '%s' "${SCRIPT_ENTRIES[$1]%%|*}"; }
entry_title() { local rest="${SCRIPT_ENTRIES[$1]#*|}"; printf '%s' "${rest%%|*}"; }
entry_desc()  { printf '%s' "${SCRIPT_ENTRIES[$1]##*|}"; }

# ---------------------------- 运行状态 ----------------------------
USE_PROXY=true
FORCE_UPDATE=false
USE_LOCAL=false
CACHE_DIR=""
ENTRY_DIR="$(pwd)"

# ==================== 基础工具函数 ====================
init_entry_dir() {
    # 仅当入口本身是以文件形式运行时, 才启用「同目录脚本优先」,
    # 避免 curl | bash 场景误用当前目录里的同名文件。
    local self="${BASH_SOURCE[0]:-}"
    if [ -n "$self" ] && [ -f "$self" ]; then
        ENTRY_DIR="$(cd "$(dirname "$self")" 2>/dev/null && pwd)" || ENTRY_DIR="$(pwd)"
        USE_LOCAL=true
    fi
}

init_cache_dir() {
    local base target
    for base in "${XDG_CACHE_HOME:-}" "${HOME:-}/.cache" "/tmp"; do
        [ -n "$base" ] || continue
        target="${base%/}/scripts-repo"
        if mkdir -p "$target" 2>/dev/null && [ -w "$target" ]; then
            CACHE_DIR="$target"
            return 0
        fi
    done
    return 1
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

source_label() {
    if [ "$USE_PROXY" = true ]; then printf '%s' "$PROXY_LABEL"; else printf '%s' "$GH_LABEL"; fi
}

is_shell_script() {
    local f="${1:-}" first
    [ -n "$f" ] && [ -s "$f" ] || return 1
    first=$(head -n 1 "$f" 2>/dev/null || true)
    case "$first" in
        '#!'*bash*|'#!'*/sh|'#!'*' sh'*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ==================== 下载与缓存 ====================
fetch_to() {
    local url="$1" dest="$2"
    if have_cmd curl; then
        curl -fsSL --connect-timeout 15 --max-time 180 -o "$dest" "$url"
    elif have_cmd wget; then
        wget -q --timeout=20 --tries=2 -O "$dest" "$url"
    else
        return 127
    fi
}

download_script() {
    # $1 = 文件名, $2 = 目标路径; 按当前下载源优先, 失败自动切换另一来源
    local file="$1" dest="$2" url rc
    local -a urls
    if [ "$USE_PROXY" = true ]; then
        urls=("${PROXY_PREFIX}${GH_RAW_BASE}/${file}" "${GH_RAW_BASE}/${file}")
    else
        urls=("${GH_RAW_BASE}/${file}" "${PROXY_PREFIX}${GH_RAW_BASE}/${file}")
    fi

    local tmp="${dest}.tmp"
    rm -f "$tmp"

    for url in "${urls[@]}"; do
        if fetch_to "$url" "$tmp"; then
            if is_shell_script "$tmp"; then
                mv -f "$tmp" "$dest"
                return 0
            fi
            echo -e "${YELLOW}>> 下载内容校验失败 (可能被代理拦截或文件不存在): ${url}${NC}" >&2
        else
            rc=$?
            if [ "$rc" -eq 127 ]; then
                echo -e "${RED}>> 未检测到 curl 或 wget, 请先安装其中之一后再运行。${NC}" >&2
                rm -f "$tmp"
                return 127
            fi
            echo -e "${YELLOW}>> 拉取失败: ${url}${NC}" >&2
        fi
    done

    rm -f "$tmp"
    return 1
}

cache_is_fresh() {
    local f="${1:-}" now mtime
    [ -s "$f" ] || return 1
    now=$(date +%s 2>/dev/null || echo 0)
    mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    [ "$mtime" -gt 0 ] || return 0
    [ $((now - mtime)) -lt $((CACHE_TTL_HOURS * 3600)) ]
}

# 输出变量: SCRIPT_PATH (最终脚本路径) / SCRIPT_SOURCE (来源描述)
SCRIPT_PATH=""
SCRIPT_SOURCE=""

resolve_script_path() {
    # 依次尝试: 同目录脚本 -> 新鲜缓存 -> 联网拉取 -> 过期缓存兜底
    local file="$1"
    local sidecar_path="${ENTRY_DIR}/${file}"
    local cache_path="${CACHE_DIR}/${file}"

    SCRIPT_PATH=""
    SCRIPT_SOURCE=""

    if [ "$USE_LOCAL" = true ] && is_shell_script "$sidecar_path"; then
        SCRIPT_PATH="$sidecar_path"
        SCRIPT_SOURCE="同目录本地文件"
        return 0
    fi

    if [ "$FORCE_UPDATE" != true ] && cache_is_fresh "$cache_path"; then
        SCRIPT_PATH="$cache_path"
        SCRIPT_SOURCE="本地缓存"
        return 0
    fi

    echo -e "${CYAN}>> 正在从仓库拉取 ${file} ...${NC}"
    if download_script "$file" "$cache_path"; then
        chmod +x "$cache_path" 2>/dev/null || true
        SCRIPT_PATH="$cache_path"
        SCRIPT_SOURCE="在线拉取"
        return 0
    fi

    if [ -s "$cache_path" ]; then
        echo -e "${YELLOW}>> 联网更新失败, 改用本地已缓存的版本。${NC}"
        SCRIPT_PATH="$cache_path"
        SCRIPT_SOURCE="本地缓存 (在线更新失败)"
        return 0
    fi

    return 1
}

# ==================== 启动脚本 ====================
launch_file() {
    # $1 = 文件名, $2 = 菜单标题
    local file="$1" title="${2:-$1}" rc

    echo ""
    echo -e "${CYAN}>> 准备启动: ${BOLD}${title}${NC}${CYAN} (${file})${NC}"

    if ! resolve_script_path "$file"; then
        echo -e "${RED}>> 无法获取 ${file}, 请检查网络连接或改用其他下载源 (菜单 s)。${NC}"
        return 1
    fi

    echo -e "${CYAN}>> 脚本来源: ${SCRIPT_SOURCE} (${SCRIPT_PATH})${NC}"
    echo "------------------------------------------------------------------------"
    sleep 0.4

    bash "$SCRIPT_PATH"
    rc=$?
    echo "------------------------------------------------------------------------"
    if [ "$rc" -eq 0 ]; then
        echo -e "${GREEN}>> ${file} 已正常结束, 返回统一入口菜单。${NC}"
    else
        echo -e "${YELLOW}>> ${file} 退出码: ${rc}${NC}"
    fi
    return 0
}

launch_index() {
    launch_file "$(entry_file "$1")" "$(entry_title "$1")"
}

# ==================== 命令行参数解析 ====================
resolve_target_index() {
    # 支持: 数字编号 / 完整文件名 / 文件名关键字
    local target="$1" i f
    if [[ "$target" =~ ^[0-9]+$ ]]; then
        if [ "$target" -ge 1 ] && [ "$target" -le "$SCRIPT_COUNT" ]; then
            printf '%s' "$((target - 1))"
            return 0
        fi
        return 1
    fi
    for ((i = 0; i < SCRIPT_COUNT; i++)); do
        f=$(entry_file "$i")
        [ "$f" = "$target" ] && { printf '%s' "$i"; return 0; }
    done
    for ((i = 0; i < SCRIPT_COUNT; i++)); do
        f=$(entry_file "$i")
        case "$f" in
            *"$target"*) printf '%s' "$i"; return 0 ;;
        esac
    done
    return 1
}

print_script_table() {
    local i
    echo "=========================================="
    echo -e "   ${BOLD}${REPO_OWNER}/${REPO_NAME} 脚本集合统一入口${NC}"
    echo "=========================================="
    for ((i = 0; i < SCRIPT_COUNT; i++)); do
        printf " %s. %s\n" "$((i + 1))" "$(entry_title "$i")"
        printf "    %s\n" "$(entry_desc "$i")"
    done
    echo "=========================================="
}

print_usage() {
    print_script_table
    echo ""
    echo -e "${BOLD}推荐的可交互调用方式:${NC}"
    echo "  bash -c \"\$(curl -fsSL ${PROXY_PREFIX}${GH_RAW_BASE}/main.sh)\""
    echo ""
    echo "非交互环境请通过变量或参数指定脚本, 例如:"
    echo "  SCRIPT_ID=1 bash main.sh"
    echo "  bash main.sh aria2"
}

# ==================== 主菜单 ====================
main_menu() {
    local choice i
    while true; do
        echo ""
        echo "=========================================="
        echo -e "   ${BOLD}${REPO_OWNER}/${REPO_NAME} 脚本集合统一入口${NC}"
        echo "=========================================="
        echo " 当前下载源: $(source_label)"
        if [ "$USE_LOCAL" = true ]; then
            echo " 脚本来源:   本地优先 (检测到入口所在目录, 优先运行同目录脚本)"
        else
            echo " 脚本来源:   在线拉取 (缓存目录: ${CACHE_DIR})"
        fi
        echo "------------------------------------------"
        for ((i = 0; i < SCRIPT_COUNT; i++)); do
            echo " $((i + 1)). $(entry_title "$i")"
            echo "    $(entry_desc "$i")"
        done
        echo "------------------------------------------"
        echo " 0. 退出"
        echo " r. 强制重新下载脚本 (刷新缓存)"
        echo " s. 切换下载源 (当前: $(source_label))"
        echo " m. 手动指定脚本文件名运行"
        echo "=========================================="
        read -rp "请输入操作编号 [0-${SCRIPT_COUNT} 默认: 0]: " choice
        choice="${choice:-0}"

        case "$choice" in
            0)
                echo "已退出。"
                return 0
                ;;
            r | R)
                FORCE_UPDATE=true
                echo -e "${CYAN}>> 已开启强制刷新, 下次启动将重新下载目标脚本。${NC}"
                ;;
            s | S)
                if [ "$USE_PROXY" = true ]; then
                    USE_PROXY=false
                else
                    USE_PROXY=true
                fi
                echo -e "${CYAN}>> 下载源已切换为: $(source_label)${NC}"
                ;;
            m | M)
                local custom_file
                read -rp "请输入仓库中的脚本文件名 (例如 aria2_manager.sh): " custom_file
                custom_file="${custom_file// /}"
                [ -n "$custom_file" ] || { echo -e "${YELLOW}>> 输入为空, 已取消。${NC}"; continue; }
                case "$custom_file" in
                    *.sh) ;;
                    *) custom_file="${custom_file}.sh" ;;
                esac
                if [[ ! "$custom_file" =~ ^[A-Za-z0-9._-]+$ ]]; then
                    echo -e "${RED}>> 文件名包含非法字符, 已取消。${NC}"
                    continue
                fi
                launch_file "$custom_file" "$custom_file"
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$SCRIPT_COUNT" ]; then
                    launch_index "$((choice - 1))"
                else
                    echo -e "${YELLOW}无效选项, 请重新选择。${NC}"
                fi
                ;;
        esac
    done
}

# ==================== 入口 ====================
init_entry_dir
if ! init_cache_dir; then
    echo -e "${RED}>> 无法创建缓存目录, 请检查 HOME 或 /tmp 的写入权限。${NC}"
    exit 1
fi

TARGET="${1:-${SCRIPT_ID:-}}"

if [ -n "$TARGET" ]; then
    if idx=$(resolve_target_index "$TARGET"); then
        launch_index "$idx"
        exit 0
    fi
    echo -e "${YELLOW}>> 未匹配到脚本: ${TARGET}${NC}"
    print_usage
    exit 1
fi

if [ ! -t 0 ]; then
    echo -e "${YELLOW}>> 检测到标准输入不是终端 (如 curl ... | bash 方式), 无法使用交互式菜单。${NC}"
    print_usage
    exit 1
fi

main_menu
