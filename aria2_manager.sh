#!/usr/bin/env bash
set -e

# ---------------------------- 终端色彩定义 ----------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ==================== 环境与权限自适应 ====================
# 当前执行用户（精简环境下可能不存在 USER 变量）
CURRENT_USER="${USER:-$(id -un 2>/dev/null || printf 'user')}"
USER_HOME="$HOME"
IS_ROOT=false

if [ "$EUID" -eq 0 ]; then
    IS_ROOT=true
    SUDO_CMD=""
    SYSTEMD_DIR="/etc/systemd/system"
    SYSTEMCTL_CMD="systemctl"
    ARIA2C_BIN_DIR="/usr/local/bin"
    ARIA2C_BIN="${ARIA2C_BIN_DIR}/aria2c"
else
    IS_ROOT=false
    SUDO_CMD="sudo"
    SYSTEMD_DIR="${USER_HOME}/.config/systemd/user"
    SYSTEMCTL_CMD="systemctl --user"
    ARIA2C_BIN_DIR="${USER_HOME}/.local/bin"
    ARIA2C_BIN="${ARIA2C_BIN_DIR}/aria2c"
fi

ARIA2_CONF_DIR="${USER_HOME}/.aria2"
CONF_FILE="${ARIA2_CONF_DIR}/aria2.conf"
SESSION_FILE="${ARIA2_CONF_DIR}/aria2.session"
# aria2-next 的原生恢复/断点数据目录(不再使用下载目录旁的 .aria2 控制文件)
STATE_DIR="${ARIA2_CONF_DIR}/state"
LOG_FILE="${ARIA2_CONF_DIR}/aria2.log"
TRACKER_SCRIPT="${ARIA2_CONF_DIR}/scripts/update_tracker.sh"
BLOCKER_SCRIPT="${ARIA2_CONF_DIR}/scripts/block_peers.sh"
FILTER_SCRIPT="${ARIA2_CONF_DIR}/scripts/auto_filter_video.py"
DEFAULT_DOWNLOAD_DIR="${USER_HOME}/Downloads"
DEFAULT_PORT="6800"
DEFAULT_ARIANG_PORT="6880"
GH_PROXY="https://gitpy.223327.xyz/https://github.com"
ARIANG_DIR="${ARIA2_CONF_DIR}/ariang"

# ==================== 运行模式: systemd / docker ====================
# systemd: 本机 aria2-next 二进制 + systemd 服务 (默认)
# docker : 官方镜像 ghcr.io/aninsomniacy/aria2-next，无需本机编译
# 挂载策略: 把配置/下载/状态等目录按【完全相同的路径】挂进容器，
#           这样 aria2.conf 里的路径在容器内外都一致，所有现有功能无需做路径转换。
ARIA2_RUN_MODE="systemd"
ARIA2_DOCKER_IMAGE="ghcr.io/aninsomniacy/aria2-next"
ARIA2_DOCKER_TAG="latest"
ARIA2_DOCKER_NAME="aria2-next"
DOCKER_CMD="docker"
DOCKER_RESOLVED=0
ARIA2_MODE_FILE="${ARIA2_CONF_DIR}/run-mode.conf"

is_docker_mode() { [ "${ARIA2_RUN_MODE:-systemd}" = "docker" ]; }

# 读取持久化的运行模式与容器参数
load_run_mode() {
    [ -f "${ARIA2_MODE_FILE}" ] || return 0
    local v=""
    v=$(grep -E '^mode=' "${ARIA2_MODE_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d ' \r')
    [ -n "$v" ] && ARIA2_RUN_MODE="$v"
    v=$(grep -E '^image=' "${ARIA2_MODE_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d ' \r')
    [ -n "$v" ] && ARIA2_DOCKER_IMAGE="$v"
    v=$(grep -E '^tag=' "${ARIA2_MODE_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d ' \r')
    [ -n "$v" ] && ARIA2_DOCKER_TAG="$v"
    v=$(grep -E '^container=' "${ARIA2_MODE_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2- | tr -d ' \r')
    [ -n "$v" ] && ARIA2_DOCKER_NAME="$v"
}

save_run_mode() {
    mkdir -p "${ARIA2_CONF_DIR}"
    cat > "${ARIA2_MODE_FILE}" <<EOF
# 由 aria2_manager.sh 维护，请勿手工修改
mode=${ARIA2_RUN_MODE}
image=${ARIA2_DOCKER_IMAGE}
tag=${ARIA2_DOCKER_TAG}
container=${ARIA2_DOCKER_NAME}
EOF
}

# 解析可用的 docker 命令(必要时带 sudo)，结果缓存到 DOCKER_CMD
docker_ensure() {
    [ "${DOCKER_RESOLVED}" = "1" ] && return 0
    command -v docker >/dev/null 2>&1 || return 1
    if docker info >/dev/null 2>&1; then
        DOCKER_CMD="docker"
    elif [ "$IS_ROOT" = false ] && ${SUDO_CMD} docker info >/dev/null 2>&1; then
        DOCKER_CMD="${SUDO_CMD} docker"
    else
        return 1
    fi
    DOCKER_RESOLVED=1
    return 0
}

docker_container_exists() {
    docker_ensure || return 1
    $DOCKER_CMD container inspect "${ARIA2_DOCKER_NAME}" >/dev/null 2>&1
}

docker_container_running() {
    docker_ensure || return 1
    [ "$($DOCKER_CMD container inspect -f '{{.State.Running}}' "${ARIA2_DOCKER_NAME}" 2>/dev/null)" = "true" ]
}

# SELinux 处于强制模式时，bind mount 需要 z 标签
selinux_enforcing() {
    if command -v getenforce >/dev/null 2>&1; then
        [ "$(getenforce 2>/dev/null)" = "Enforcing" ]
        return $?
    fi
    [ -f /sys/fs/selinux/enforce ] && [ "$(cat /sys/fs/selinux/enforce 2>/dev/null)" = "1" ]
}

# 计算需要按相同路径挂载进容器的路径(去重、过滤非绝对路径与已被父目录覆盖的项)
aria2_docker_mounts() {
    local -a out=()
    local p item covered
    for p in "${ARIA2_CONF_DIR}" "$(get_current_download_dir)" \
             "$(get_conf_value "state-dir" "${STATE_DIR}")" \
             "$(get_conf_value "log" "${LOG_FILE}")" \
             "$(get_conf_value "input-file" "${SESSION_FILE}")" \
             "$(get_conf_value "save-session" "${SESSION_FILE}")"; do
        p="${p%/}"
        [ -n "$p" ] || continue
        case "$p" in
            /*) ;;
            *) continue ;;   # 非绝对路径(例如 log=-)直接跳过
        esac
        covered=""
        for item in "${out[@]:-}"; do
            [ -n "$item" ] || continue
            if [ "$p" = "$item" ] || [ "${p#"${item}/"}" != "$p" ]; then
                covered=1
                break
            fi
        done
        [ -n "$covered" ] && continue
        out+=("$p")
    done
    if [ ${#out[@]} -gt 0 ]; then
        printf '%s\n' "${out[@]}"
    fi
    return 0
}

# 以当前配置 (重新)创建并启动容器
docker_apply_container() {
    if ! docker_ensure; then
        echo ">> !! Docker 不可用 (命令缺失 / 守护进程未运行 / 当前用户无权限)。"
        return 1
    fi

    local download_dir
    download_dir="$(get_current_download_dir)"
    mkdir -p "${download_dir}" "${ARIA2_CONF_DIR}" 2>/dev/null || true
    touch "${SESSION_FILE}" "${LOG_FILE}" 2>/dev/null || true

    local vol_suffix=""
    selinux_enforcing && vol_suffix=":z"

    local -a vol_args=()
    local p
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if [ -e "$p" ]; then
            vol_args+=(-v "${p}:${p}${vol_suffix}")
        else
            echo ">> 跳过不存在的挂载路径: ${p}"
        fi
    done < <(aria2_docker_mounts)

    if docker_container_exists; then
        $DOCKER_CMD rm -f "${ARIA2_DOCKER_NAME}" >/dev/null 2>&1 || true
    fi

    echo ">> 正在启动容器 ${ARIA2_DOCKER_NAME} (镜像 ${ARIA2_DOCKER_IMAGE}:${ARIA2_DOCKER_TAG})..."
    if ! $DOCKER_CMD run -d \
            --name "${ARIA2_DOCKER_NAME}" \
            --restart unless-stopped \
            --network host \
            -e "PUID=$(id -u)" \
            -e "PGID=$(id -g)" \
            "${vol_args[@]}" \
            "${ARIA2_DOCKER_IMAGE}:${ARIA2_DOCKER_TAG}" \
            "--conf-path=${CONF_FILE}" >/dev/null; then
        echo ">> !! 容器启动失败，请检查上方 Docker 错误输出。"
        return 1
    fi
    return 0
}

# ==================== 分页预览 + 处理前确认 ====================
# 用法: confirm_paged_list <条目数组名> <标题> [每页条数] [显示数组名]
#   - 条目数组: 实际要处理的内容(调用方后续使用)
#   - 显示数组: 可省略；省略时直接显示条目本身 (需与条目数组下标一一对应)
# 返回 0 = 用户确认处理；1 = 用户取消 / 输入结束
confirm_paged_list() {
    local items_name="$1"
    local title="$2"
    local page_size="${3:-15}"
    local display_name="$4"
    local mode="${5:-}"

    local -n _cpl_items="$items_name"
    local -n _cpl_disp="${display_name:-$items_name}"

    local total="${#_cpl_items[@]}"
    if [ "$total" -eq 0 ]; then
        return 1
    fi

    local idx=0 line=0 action="" reply=""
    local page_total=$(( (total + page_size - 1) / page_size ))
    local page_no=0 end=0

    if [ "$total" -le "$page_size" ]; then
        echo ""
        echo "===== ${title} (共 ${total} 项) ====="
        for ((line=0; line<total; line++)); do
            printf ' [%d] %s\n' "$((line + 1))" "${_cpl_disp[$line]}"
        done
        echo "--------------------------------------------------"
        if [ "$mode" = "view" ]; then
            read -rp "已浏览全部 ${total} 项，按 [Enter] 继续..." _cpl_pause || true
            return 0
        fi
        read -rp "确认处理以上 ${total} 项? [Y/n 默认: Y]: " reply || true
        if [[ "${reply:-Y}" =~ ^[Yy]$ ]]; then
            return 0
        fi
        return 1
    fi

    # 清单较长: 由用户决定是否翻页预览
    read -rp ">> 共 ${total} 项，清单较长；是否翻页查看? [Y/n 默认: Y]: " reply || true
    if [[ "${reply:-Y}" =~ ^[Yy]$ ]]; then
        while [ "$idx" -lt "$total" ]; do
            clear 2>/dev/null || true
            page_no=$(( idx / page_size + 1 ))
            echo "===== ${title} (第 ${page_no}/${page_total} 页，共 ${total} 项) ====="
            end=$((idx + page_size))
            [ "$end" -gt "$total" ] && end="$total"
            for ((line=idx; line<end; line++)); do
                printf ' [%d] %s\n' "$((line + 1))" "${_cpl_disp[$line]}"
            done
            echo "--------------------------------------------------"
            idx="$end"
            if [ "$idx" -lt "$total" ]; then
                read -rp "按 [Enter] 下一页，输入 [q] 退出预览，输入 [g] 直接进入确认: " action || break
                case "$action" in
                    [Qq]) break ;;
                    [Gg]) break ;;
                esac
            fi
        done
    else
        echo ">> 已跳过预览。"
    fi

    if [ "$mode" = "view" ]; then
        return 0
    fi

    echo ""
    read -rp "确认处理以上 ${total} 项? [Y/n 默认: Y]: " reply || true
    if [[ "${reply:-Y}" =~ ^[Yy]$ ]]; then
        return 0
    fi
    echo ">> 已取消。"
    return 1
}

# ==================== 分页预览任意文本输出 (日志/规则等) ====================
# 用法: preview_file_paged <标题> <文件> [每页行数]
#   - 内容不超一页时直接输出；否则分页，按 [Enter] 继续 / [q] 退出
#   - 输入流结束(Ctrl-D)不会死循环
preview_file_paged() {
    local title="$1"
    local file="$2"
    local page_size="${3:-20}"

    if [ ! -s "$file" ]; then
        echo "===== ${title} ====="
        echo "（无内容）"
        return 0
    fi

    local -a _pv_lines=()
    mapfile -t _pv_lines < "$file" 2>/dev/null || _pv_lines=()
    local total="${#_pv_lines[@]}"
    if [ "$total" -eq 0 ]; then
        echo "===== ${title} ====="
        echo "（无内容）"
        return 0
    fi

    if [ "$total" -le "$page_size" ]; then
        echo "===== ${title} (共 ${total} 行) ====="
        printf '%s\n' "${_pv_lines[@]}"
        echo "--------------------------------------------------"
        return 0
    fi

    local idx=0 end=0 i=0 page_no=0 action=""
    local page_total=$(( (total + page_size - 1) / page_size ))
    while [ "$idx" -lt "$total" ]; do
        clear 2>/dev/null || true
        page_no=$(( idx / page_size + 1 ))
        echo "===== ${title} (第 ${page_no}/${page_total} 页，共 ${total} 行) ====="
        end=$((idx + page_size))
        [ "$end" -gt "$total" ] && end="$total"
        for ((i=idx; i<end; i++)); do
            printf '%s\n' "${_pv_lines[$i]}"
        done
        echo "--------------------------------------------------"
        idx="$end"
        if [ "$idx" -lt "$total" ]; then
            read -rp "按 [Enter] 下一页，输入 [q] 退出预览: " action || break
            case "$action" in
                [Qq]) break ;;
            esac
        fi
    done
    return 0
}

# ==================== 服务控制抽象 (systemd / docker 通用) ====================
svc_is_active() {
    if is_docker_mode; then
        docker_container_running
    else
        ${SYSTEMCTL_CMD} is-active --quiet aria2.service 2>/dev/null
    fi
}

svc_start() {
    if is_docker_mode; then
        # 直接按当前配置重建容器，确保 dir/端口等变更后挂载依然正确
        docker_apply_container
    else
        ${SYSTEMCTL_CMD} start aria2.service
    fi
}

svc_stop() {
    if is_docker_mode; then
        if docker_container_exists; then
            $DOCKER_CMD stop "${ARIA2_DOCKER_NAME}" >/dev/null 2>&1 || true
        fi
    else
        ${SYSTEMCTL_CMD} stop aria2.service 2>/dev/null || true
    fi
}

# 容器模式下直接按当前配置重建容器，使 dir/端口/限速等变更一并生效
svc_restart() {
    if is_docker_mode; then
        docker_apply_container
    else
        ${SYSTEMCTL_CMD} restart aria2.service
    fi
}

svc_logs() {
    if is_docker_mode; then
        docker_ensure || { echo ">> Docker 不可用，无法读取容器日志。"; return 1; }
        $DOCKER_CMD logs --tail 60 "${ARIA2_DOCKER_NAME}" 2>&1
    elif [ "$IS_ROOT" = true ]; then
        journalctl -u aria2.service -n 40 --no-pager
    else
        journalctl --user -u aria2.service -n 40 --no-pager
    fi
}

# ==================== 基础依赖检测 (仅缺失时安装，不刷源) ====================
# 包是否真的装好: 注意 dpkg -s 在“已卸载但残留配置”时依然返回 0，不能用它判断
dpkg_installed() {
    local pkg="$1"
    command -v dpkg-query >/dev/null 2>&1 || return 1
    [ "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null)" = "install ok installed" ]
}

rpm_installed() {
    command -v rpm >/dev/null 2>&1 || return 1
    rpm -q "$1" >/dev/null 2>&1
}

pkg_installed() {
    local pkg="$1"
    if command -v dpkg-query >/dev/null 2>&1; then
        dpkg_installed "$pkg"
    elif command -v rpm >/dev/null 2>&1 && { command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1 || command -v zypper >/dev/null 2>&1; }; then
        rpm_installed "$pkg"
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Q "$pkg" >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk info -e "$pkg" >/dev/null 2>&1
    else
        # 无包管理器信息时回退为命令探测
        command -v "$pkg" >/dev/null 2>&1
    fi
}

install_packages() {
    local pkgs=("$@")
    local missing_pkgs=()
    local pkg=""

    for pkg in "${pkgs[@]}"; do
        pkg_installed "$pkg" || missing_pkgs+=("$pkg")
    done

    if [ ${#missing_pkgs[@]} -eq 0 ]; then
        return 0
    fi

    echo ">> 发现缺少依赖，正在安装: ${missing_pkgs[*]}..."
    if command -v apt-get >/dev/null 2>&1; then
        # 仅在确实缺包时才刷新一次软件源索引 (安静模式)，日常进入菜单不会触发，避免刷屏
        echo ">> 正在刷新软件源索引 (apt-get update -qq)..."
        ${SUDO_CMD} apt-get update -qq 2>/dev/null || true
        if ! ${SUDO_CMD} apt-get install -y --no-install-recommends "${missing_pkgs[@]}"; then
            echo ">> !! 依赖安装失败: ${missing_pkgs[*]}，请检查网络或软件源后重试。"
            return 1
        fi
    elif command -v pacman >/dev/null 2>&1; then
        ${SUDO_CMD} pacman -Sy --noconfirm "${missing_pkgs[@]}" || return 1
    elif command -v dnf >/dev/null 2>&1; then
        ${SUDO_CMD} dnf install -y "${missing_pkgs[@]}" || return 1
    elif command -v yum >/dev/null 2>&1; then
        ${SUDO_CMD} yum install -y "${missing_pkgs[@]}" || return 1
    elif command -v zypper >/dev/null 2>&1; then
        ${SUDO_CMD} zypper --non-interactive install "${missing_pkgs[@]}" || return 1
    elif command -v apk >/dev/null 2>&1; then
        ${SUDO_CMD} apk add "${missing_pkgs[@]}" || return 1
    else
        echo ">> !! 未识别到可用的包管理器，无法自动安装: ${missing_pkgs[*]}"
        echo "   请手动安装后重试。"
        return 1
    fi
    return 0
}

# 校验必需命令是否可用(安装后调用)；缺失时给出可操作的提示并返回 1
check_cmds() {
    local missing=() c=""
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo ">> !! 缺少必需命令: ${missing[*]}"
        echo "   请先安装后重试，例如: sudo apt install ${missing[*]} / sudo dnf install ${missing[*]}"
        return 1
    fi
    return 0
}

# 是否允许在 rsync 不可用时用 cp 兜底(默认不允许: 优先安装 rsync)
USE_CP_FALLBACK=0

# 确保 rsync 可用: 不存在则尝试安装；装不上时给出可操作的手动安装命令，
# 默认中止操作(只有用户明确同意才启用 cp 兜底)
ensure_rsync() {
    if command -v rsync >/dev/null 2>&1; then
        return 0
    fi

    echo ">> 未检测到 rsync，正在尝试自动安装..."
    install_packages rsync || true
    if command -v rsync >/dev/null 2>&1; then
        echo ">> rsync 已就绪: $(command -v rsync)"
        return 0
    fi

    echo ""
    echo ">> !! 未能自动安装 rsync (安装失败或软件源不可用)。"
    echo "   请手动安装后重试:"
    echo "     Debian/Ubuntu  : sudo apt install -y rsync"
    echo "     RHEL/Rocky/Alma: sudo dnf install -y rsync"
    echo "     Arch/Manjaro   : sudo pacman -S --noconfirm rsync"
    local _use_cp=""
    read -rp "   是否改用 cp -a 复制继续 (无断点续传/无进度，大文件中断后需重跑本功能)? [y/N 默认: N]: " _use_cp || true
    if [[ "${_use_cp:-N}" =~ ^[Yy]$ ]]; then
        USE_CP_FALLBACK=1
        echo ">> 已选择 cp -a 兜底复制。"
        return 0
    fi
    echo ">> 已取消操作：请先安装 rsync 后重试。"
    return 1
}

# 复制单个文件/目录，保持 <src>/./<rel> 的相对层级
#   用法: copy_path "<绝对路径>[/./<相对路径>]" "<目标目录>"
#   优先使用 rsync --partial(断点续传)；系统无 rsync 时自动退化为 cp -a，
#   调用方仍会做“目标存在 + 字节数一致”校验，因此退化方案不会导致误删
copy_path() {
    local spec="$1"
    local dest="${2%/}/"
    [ -n "$spec" ] && [ -n "$2" ] || return 1

    if command -v rsync >/dev/null 2>&1; then
        case "$spec" in
            *"/./"*) rsync -avP --partial -R "$spec" "$dest" ;;
            *)        rsync -avP --partial "$spec" "$dest" ;;
        esac
        return $?
    fi

    if [ "${USE_CP_FALLBACK:-0}" != "1" ]; then
        echo "   !! 未安装 rsync 且未启用 cp 兜底，无法复制: ${spec}" >&2
        return 1
    fi
    if [ "${COPY_PATH_NOTIFIED:-0}" != "1" ]; then
        echo "   (提示: 使用 cp -a 复制；大文件中断后需重跑本功能)"
        COPY_PATH_NOTIFIED=1
    fi

    local src_leaf="" target_parent="" rel=""
    case "$spec" in
        *"/./"*)
            local base="${spec%%/./*}"
            rel="${spec#*/./}"
            src_leaf="${base%/}/${rel}"
            ;;
        *)
            rel="$(basename "$spec")"
            src_leaf="$spec"
            ;;
    esac
    [ -n "$rel" ] && [ -n "$src_leaf" ] || return 1
    [ -e "$src_leaf" ] || return 1
    target_parent="$(dirname "${dest}${rel}")"
    mkdir -p "$target_parent" || return 1
    cp -a -- "$src_leaf" "${target_parent}/" || return 1
    return 0
}

# 把 <src_dir> 下的全部内容复制进 <dest_dir>
copy_tree_contents() {
    local src="${1%/}" dest="${2%/}"
    [ -d "$src" ] || return 1
    mkdir -p "$dest" || return 1
    if command -v rsync >/dev/null 2>&1; then
        rsync -avP --partial "${src}/" "${dest}/"
        return $?
    fi
    if [ "${USE_CP_FALLBACK:-0}" != "1" ]; then
        echo "   !! 未安装 rsync 且未启用 cp 兜底，无法复制目录。" >&2
        return 1
    fi
    echo "   (提示: 使用 cp -a 复制目录)"
    cp -a "${src}/." "${dest}/" || return 1
    return 0
}

# ==================== 通用交互辅助 ====================
# 暂停并等待用户回车
pause_menu() {
    local __dummy=""
    read -rp "按回车键返回菜单..." __dummy || exit 0
}

# ==================== 状态与配置检查辅助函数 ====================
# 运行状态（带颜色）
get_aria2_status() {
    if is_docker_mode; then
        if ! docker_ensure; then
            printf '%b' "${YELLOW}Docker 不可用${NC}"
        elif docker_container_running; then
            printf '%b' "${GREEN}运行中 (容器)${NC}"
        elif docker_container_exists; then
            printf '%b' "${RED}已停止 (容器)${NC}"
        else
            printf '%b' "${YELLOW}未安装${NC}"
        fi
        return 0
    fi
    if [ ! -f "${ARIA2C_BIN}" ]; then
        printf '%b' "${YELLOW}未安装${NC}"
    elif ${SYSTEMCTL_CMD} is-active --quiet aria2.service 2>/dev/null; then
        printf '%b' "${GREEN}运行中${NC}"
    else
        printf '%b' "${RED}已停止${NC}"
    fi
}

# 开机自启状态（带颜色）
get_aria2_boot_status() {
    if is_docker_mode; then
        if ! docker_ensure; then
            printf '%b' "${YELLOW}Docker 不可用${NC}"
        elif docker_container_exists; then
            printf '%b' "${GREEN}已启用 (restart 策略)${NC}"
        else
            printf '%b' "${YELLOW}未安装${NC}"
        fi
        return 0
    fi
    if [ ! -f "${ARIA2C_BIN}" ]; then
        printf '%b' "${YELLOW}未安装${NC}"
    elif ${SYSTEMCTL_CMD} is-enabled --quiet aria2.service 2>/dev/null; then
        printf '%b' "${GREEN}已启用${NC}"
    else
        printf '%b' "${RED}已停用${NC}"
    fi
}

# 已安装的 aria2c 版本号，未安装或读取失败时返回 "未安装"
get_aria2_version_text() {
    if is_docker_mode; then
        printf 'Docker 镜像 %s' "${ARIA2_DOCKER_TAG}"
        return 0
    fi
    local ver=""
    ver=$("$ARIA2C_BIN" --version 2>/dev/null | head -n1 | sed -nE 's/.*[Vv]ersion[[:space:]]+([0-9][0-9A-Za-z.-]*).*/\1/p') || true
    if [ -n "$ver" ]; then
        printf '%s' "$ver"
    else
        printf '未安装'
    fi
}

get_current_download_dir() {
    if [ -f "${CONF_FILE}" ]; then
        local configured_dir
        configured_dir=$(grep -E "^dir=" "${CONF_FILE}" 2>/dev/null | cut -d'=' -f2- | tr -d '\r')
        if [ -n "$configured_dir" ]; then
            echo "$configured_dir"
            return
        fi
    fi
    echo "$DEFAULT_DOWNLOAD_DIR"
}

get_conf_value() {
    local key="$1"
    local default_val="$2"
    if [ -f "${CONF_FILE}" ]; then
        local val
        val=$(grep -E "^${key}=" "${CONF_FILE}" 2>/dev/null | cut -d'=' -f2- | tr -d '\r')
        if [ -n "$val" ]; then
            echo "$val"
            return
        fi
    fi
    echo "$default_val"
}

update_conf_kv() {
    local key="$1"
    local val="$2"
    if grep -q "^${key}=" "${CONF_FILE}" 2>/dev/null; then
        local tmp
        tmp=$(mktemp)
        if KV_KEY="${key}" KV_VAL="${val}" awk '
            BEGIN { key = ENVIRON["KV_KEY"] "=" }
            index($0, key) == 1 { print ENVIRON["KV_KEY"] "=" ENVIRON["KV_VAL"]; next }
            { print }
        ' "${CONF_FILE}" > "${tmp}"; then
            cp "${tmp}" "${CONF_FILE}"
        else
            echo "   !! 写入 ${CONF_FILE} 失败 (${key})" >&2
        fi
        rm -f "${tmp}"
    else
        printf '%s=%s\n' "${key}" "${val}" >> "${CONF_FILE}"
    fi
}

# 按字面量替换文件内容 (不做正则/转义解释)，用于改写 session 中的路径映射
replace_literal_in_file() {
    local file="$1"
    local from="$2"
    local to="$3"
    [ -f "${file}" ] || return 0
    [ -n "${from}" ] || return 0
    local tmp
    tmp=$(mktemp)
    if LIT_FROM="${from}" LIT_TO="${to}" awk '
        BEGIN { from = ENVIRON["LIT_FROM"]; to = ENVIRON["LIT_TO"]; n = length(from) }
        {
            line = $0
            out = ""
            while ((p = index(line, from)) > 0) {
                out = out substr(line, 1, p - 1) to
                line = substr(line, p + n)
            }
            print out line
        }
    ' "${file}" > "${tmp}"; then
        cp "${tmp}" "${file}"
    else
        echo "   !! 改写 ${file} 失败" >&2
    fi
    rm -f "${tmp}"
}

# ==================== Aria2 活动任务查询 (aria2-next 无 .aria2 控制文件) ====================
# 通过 RPC 查询「进行中 + 等待中」的任务；aria2-next 不再生成 .aria2 控制文件，
# 因此磁盘上的文件是否仍被 Aria2 托管，只能以 RPC 任务清单为准。
#   $1 = names  输出受管理名称集合(小写、去重，含 BT 根目录名/文件名/顶层目录名)
#   $1 = paths  输出未完成任务的绝对文件路径(去重)
_rpc_active_query() {
    [ -f "${CONF_FILE}" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    ARIA2_CONF_FILE="${CONF_FILE}" ARIA2_QUERY_MODE="$1" python3 - <<'PYEOF'
import json
import os
import sys
import urllib.request

CONF_FILE = os.environ.get("ARIA2_CONF_FILE", "")
MODE = os.environ.get("ARIA2_QUERY_MODE", "names")
TIMEOUT = 10


def read_conf(key, default):
    try:
        with open(CONF_FILE, "r", encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                if k.strip() == key:
                    return v.strip()
    except OSError:
        pass
    return default


PORT = read_conf("rpc-listen-port", "6800") or "6800"
SECRET = read_conf("rpc-secret", "")
URL = "http://127.0.0.1:" + PORT + "/jsonrpc"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def rpc(method, params=None):
    cp = ["token:" + SECRET] if SECRET else []
    if params:
        cp.extend(params)
    body = json.dumps({"jsonrpc": "2.0", "id": "active_query", "method": method, "params": cp}).encode("utf-8")
    req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json"})
    try:
        with OPENER.open(req, timeout=TIMEOUT) as resp:
            data = json.loads(resp.read().decode("utf-8", "replace"))
    except Exception:
        return None
    if isinstance(data, dict) and data.get("error"):
        return None
    return data.get("result") if isinstance(data, dict) else None


names = set()
paths = set()
for method, params in (("aria2.tellActive", None), ("aria2.tellWaiting", [0, 10000])):
    tasks = rpc(method, params)
    if not isinstance(tasks, list):
        continue
    for task in tasks:
        bt = task.get("bittorrent")
        if isinstance(bt, dict):
            inner = bt.get("info")
            if isinstance(inner, dict) and inner.get("name"):
                names.add(inner["name"].lower())
        task_dir = task.get("dir") or ""
        files = task.get("files")
        if not isinstance(files, list):
            continue
        for f in files:
            path = (f or {}).get("path") or ""
            if not path:
                continue
            if not os.path.isabs(path):
                path = os.path.join(task_dir, path) if task_dir else path
            real = os.path.realpath(path)
            paths.add(real)
            names.add(os.path.basename(real).lower())
            if task_dir:
                real_dir = os.path.realpath(task_dir)
                if real != real_dir and real.startswith(real_dir + os.sep):
                    names.add(os.path.relpath(real, real_dir).split(os.sep)[0].lower())

if MODE == "paths":
    for p in sorted(paths):
        print(p)
else:
    for n in sorted(names):
        print(n)
PYEOF
}

rpc_active_managed_names() { _rpc_active_query names; }
rpc_active_file_paths() { _rpc_active_query paths; }

# ==================== Aria2 RPC 诊断 (模块 6/7/8 复用) ====================
# 纯 bash + curl 探测 RPC，不依赖 python3；连接失败返回非零
rpc_diagnose() {
    echo "---- Aria2 RPC 诊断 ----"
    if [ ! -f "${CONF_FILE}" ]; then
        echo "配置文件: ${CONF_FILE} (不存在，请先完成安装)"
        echo "连接状态: 失败"
        return 1
    fi

    local rpc_port rpc_secret
    rpc_port="$(get_conf_value "rpc-listen-port" "6800")"
    rpc_secret="$(get_conf_value "rpc-secret" "")"
    echo "配置文件: ${CONF_FILE}"
    echo "RPC 端点: http://127.0.0.1:${rpc_port}/jsonrpc (rpc-secret: $([ -n "$rpc_secret" ] && echo 已设置 || echo 未设置))"
    if command -v python3 >/dev/null 2>&1; then
        echo "python3 : 可用 ($(command -v python3))"
    else
        echo "python3 : !! 未检测到 (模块 6/7/8 依赖它解析 RPC 返回，请先安装 python3)"
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "连接状态: 无法探测 (缺少 curl)"
        return 1
    fi

    # rpc-secret 中的引号/反斜杠会破坏 JSON，这里做最小化剔除
    local safe_secret="${rpc_secret//\"/}"
    local token_part=""
    [ -n "$safe_secret" ] && token_part="\"token:${safe_secret//\\/}\""

    local resp=""
    resp="$(printf '{"jsonrpc":"2.0","id":"probe","method":"aria2.getVersion","params":[%s]}' "$token_part" \
        | curl -sS -m 10 --noproxy '*' -X POST -H 'Content-Type: application/json' --data-binary @- \
            "http://127.0.0.1:${rpc_port}/jsonrpc" 2>&1 || true)"

    if ! printf '%s' "$resp" | grep -q '"result"'; then
        echo "连接状态: 失败"
        echo "服务端返回: ${resp:-（无响应）}"
        if printf '%s' "$resp" | grep -qi 'unauthorized'; then
            echo "原因: rpc-secret 与运行中的 Aria2 实例不一致。"
        else
            echo "原因: Aria2 服务未运行 / 端口不匹配 / RPC 未开启，可在主菜单 9 -> 3 做健康诊断。"
        fi
        return 1
    fi

    local ver
    ver="$(printf '%s' "$resp" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -n1)"
    echo "连接状态: 正常${ver:+ (aria2 ${ver})}"

    local method label count tasks
    for method in aria2.tellActive aria2.tellWaiting aria2.tellStopped; do
        case "$method" in
            aria2.tellActive)  label="进行中    " ;;
            aria2.tellWaiting) label="等待/暂停 ";;
            *)                 label="已停止    " ;;
        esac
        if [ "$method" = "aria2.tellActive" ]; then
            tasks="$(printf '{"jsonrpc":"2.0","id":"c","method":"%s","params":[%s]}' "$method" "$token_part" \
                | curl -sS -m 10 --noproxy '*' -X POST -H 'Content-Type: application/json' --data-binary @- \
                    "http://127.0.0.1:${rpc_port}/jsonrpc" 2>/dev/null || true)"
        else
            tasks="$(printf '{"jsonrpc":"2.0","id":"c","method":"%s","params":[%s,0,10000]}' "$method" "$token_part" \
                | curl -sS -m 10 --noproxy '*' -X POST -H 'Content-Type: application/json' --data-binary @- \
                    "http://127.0.0.1:${rpc_port}/jsonrpc" 2>/dev/null || true)"
        fi
        count="$(printf '%s' "$tasks" | grep -o '"gid"' | wc -l | tr -d ' ')"
        echo "任务列表 ${label}: ${count} 个"
    done
    echo "-----------------------"
    return 0
}

# 查询「未完成任务」的数据文件绝对路径(进行中 / 等待 / 暂停 / 未完成已停止)
#   $1 = 输出文件(NUL 分隔的路径)；stdout 打印诊断；RPC 失败返回非零
rpc_unfinished_paths_to() {
    local out_file="$1"
    ARIA2_CONF_FILE="${CONF_FILE}" ARIA2_OUT_FILE="${out_file}" \
    ARIA2_SRC_HINT="$(get_current_download_dir)" python3 - <<'PYEOF'
import json
import os
import sys
import urllib.error
import urllib.request

CONF_FILE = os.environ.get("ARIA2_CONF_FILE", "")
OUT_FILE = os.environ.get("ARIA2_OUT_FILE", "")
SRC_HINT = os.path.realpath(os.environ.get("ARIA2_SRC_HINT", "."))
RPC_TIMEOUT = 20


def read_conf(key, default):
    try:
        with open(CONF_FILE, "r", encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                name, value = line.split("=", 1)
                if name.strip() == key:
                    return value.strip()
    except OSError:
        pass
    return default


def num(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


RPC_PORT = read_conf("rpc-listen-port", "6800") or "6800"
RPC_SECRET = read_conf("rpc-secret", "")
RPC_URL = "http://127.0.0.1:" + RPC_PORT + "/jsonrpc"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def rpc(method, params=None):
    """返回 (结果, 错误描述)；urllib 失败时回退 curl。"""
    call_params = ["token:" + RPC_SECRET] if RPC_SECRET else []
    if params:
        call_params.extend(params)
    body = json.dumps({"jsonrpc": "2.0", "id": "unfinished", "method": method, "params": call_params}).encode("utf-8")
    first_error = ""
    try:
        req = urllib.request.Request(RPC_URL, data=body, headers={"Content-Type": "application/json"})
        with OPENER.open(req, timeout=RPC_TIMEOUT) as resp:
            data = json.loads(resp.read().decode("utf-8", "replace"))
        if isinstance(data, dict) and data.get("error"):
            info = data["error"] if isinstance(data["error"], dict) else {}
            return None, "RPC 拒绝请求 [%s] %s" % (info.get("code", "?"), info.get("message", ""))
        return (data.get("result") if isinstance(data, dict) else None), None
    except urllib.error.HTTPError as exc:
        first_error = "HTTP %s" % exc.code
    except urllib.error.URLError as exc:
        first_error = "无法连接 127.0.0.1:%s (%s)" % (RPC_PORT, getattr(exc, "reason", exc))
    except Exception as exc:
        first_error = "%s: %s" % (type(exc).__name__, exc)

    try:
        import subprocess
        proc = subprocess.run(["curl", "-sS", "-m", str(RPC_TIMEOUT), "--noproxy", "*", "-X", "POST",
                               "-H", "Content-Type: application/json", "--data-binary", "@-", RPC_URL],
                              input=body, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=RPC_TIMEOUT + 10)
        if proc.returncode == 0:
            data = json.loads(proc.stdout.decode("utf-8", "replace"))
            if isinstance(data, dict) and data.get("error"):
                info = data["error"] if isinstance(data["error"], dict) else {}
                return None, "RPC 拒绝请求 [%s] %s" % (info.get("code", "?"), info.get("message", ""))
            return (data.get("result") if isinstance(data, dict) else None), None
        return None, "%s；curl 回退失败 (退出码 %s)" % (first_error, proc.returncode)
    except Exception as exc2:
        return None, "%s；curl 回退异常: %s" % (first_error, exc2)


def is_finished(task):
    """是否属于「已正常下载完整」: 做种中 / 状态 complete / 进度跑满。"""
    if task.get("seeder") == "true":
        return True
    if (task.get("status") or "").strip() == "complete":
        return True
    total = num(task.get("totalLength"))
    done = num(task.get("completedLength"))
    return total > 0 and done >= total


def task_name(task):
    bt = task.get("bittorrent")
    if isinstance(bt, dict):
        inner = bt.get("info")
        if isinstance(inner, dict) and inner.get("name"):
            return inner["name"]
    files = task.get("files")
    if isinstance(files, list):
        for f in files:
            path = (f or {}).get("path") or ""
            if path:
                return os.path.basename(path)
    return task.get("gid") or "未知任务"


version, ver_err = rpc("aria2.getVersion")
if ver_err:
    print("!! 无法连接 Aria2 RPC: %s" % ver_err)
    print("   端点: %s" % RPC_URL)
    print("   排查: 服务是否运行 / rpc-listen-port 与 rpc-secret 是否与运行实例一致")
    sys.exit(1)
version_text = ""
if isinstance(version, dict):
    version_text = version.get("version", "")
print(">> RPC 连接正常: %s%s" % (RPC_URL, (" (aria2 %s)" % version_text) if version_text else ""))

paths = []
seen = set()
missing = 0
outside = 0
unfinished = []
for method, params, label in (("aria2.tellActive", None, "进行中"),
                              ("aria2.tellWaiting", [0, 10000], "等待/暂停"),
                              ("aria2.tellStopped", [0, 10000], "已停止")):
    tasks, err = rpc(method, params)
    if err:
        print("!! %s 列表查询失败: %s" % (label, err))
        sys.exit(1)
    if not isinstance(tasks, list):
        tasks = []
    pending = 0
    for task in tasks:
        if is_finished(task):
            continue
        pending += 1
        unfinished.append((task_name(task), (task.get("status") or ""), task.get("dir") or ""))
        task_dir = task.get("dir") or ""
        files = task.get("files")
        if not isinstance(files, list):
            continue
        for f in files:
            raw_path = (f or {}).get("path") or ""
            if not raw_path or raw_path.startswith("[METADATA]"):
                continue
            if not os.path.isabs(raw_path):
                raw_path = os.path.join(task_dir, raw_path) if task_dir else raw_path
            real = os.path.realpath(raw_path)
            if real in seen:
                continue
            seen.add(real)
            if real != SRC_HINT and not real.startswith(SRC_HINT + os.sep):
                outside += 1
                continue
            if not os.path.exists(real):
                missing += 1
                continue
            paths.append(real)
    print(">> %s 列表: 共 %d 个任务，其中未完成 %d 个" % (label, len(tasks), pending))

print(">> 未完成任务合计: %d 个" % len(unfinished))
for name, status, tdir in unfinished[:10]:
    print("     - [%s] %s (task dir: %s)" % (status or "?", name, tdir or "?"))
if len(unfinished) > 10:
    print("     ... 以及其余 %d 个" % (len(unfinished) - 10))
print(">> 参照源目录: %s" % SRC_HINT)
print(">> 可迁移数据文件: %d 个 (磁盘上不存在 %d 个已跳过 / 不在源目录内 %d 个已跳过)"
      % (len(paths), missing, outside))

with open(OUT_FILE, "wb") as fh:
    for p in sorted(paths):
        fh.write(p.encode("utf-8", "surrogateescape") + b"\x00")
PYEOF
}

# 校验转移/迁移目标目录: 必须是绝对路径，且不能与源目录相同或位于源目录内部
check_transfer_dest() {
    local src="$1" dest="$2" src_real="" dest_real=""
    case "$dest" in
        /*) ;;
        *) echo ">> !! 目标目录必须是绝对路径 (你输入的是: ${dest})"; return 1 ;;
    esac
    if ! mkdir -p "$dest" 2>/dev/null; then
        echo ">> !! 无法创建目标目录: ${dest} (权限不足或路径无效)"
        return 1
    fi
    src_real="$(realpath "$src" 2>/dev/null || true)"
    [ -n "$src_real" ] || src_real="$src"
    dest_real="$(realpath "$dest" 2>/dev/null || true)"
    [ -n "$dest_real" ] || dest_real="$dest"
    if [ "$dest_real" = "$src_real" ]; then
        echo ">> !! 目标目录与源目录相同 (${dest_real})，已取消以避免数据丢失。"
        return 1
    fi
    case "${dest_real}/" in
        "${src_real}/"*)
            echo ">> !! 目标目录位于源目录内部 (${dest_real})，已取消以避免递归复制与误删。"
            return 1
            ;;
    esac
    return 0
}

# ==================== 进程安全停机与等待 ====================
stop_aria2_safely() {
    echo ">> 正在平稳停止 Aria2 服务以刷新保存 session..."
    if is_docker_mode; then
        svc_stop
        return 0
    fi
    ${SYSTEMCTL_CMD} stop aria2.service 2>/dev/null || true
    
    local timeout=10
    while pgrep -u "$CURRENT_USER" -x aria2c &>/dev/null && [ $timeout -gt 0 ]; do
        sleep 0.5
        ((timeout--))
    done
}

# ==================== 安装 Caddy ====================
ensure_caddy() {
    if command -v caddy &>/dev/null; then
        echo ">> Caddy 已安装，跳过安装步骤。"
        return 0
    fi

    echo ">> 正在安装 Caddy..."
    if command -v apt-get &>/dev/null; then
        ${SUDO_CMD} apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg
        curl -1sLf --connect-timeout 10 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | ${SUDO_CMD} gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf --connect-timeout 10 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | ${SUDO_CMD} tee /etc/apt/sources.list.d/caddy-stable.list
        ${SUDO_CMD} apt-get update -o Dir::Etc::sourcelist="sources.list.d/caddy-stable.list" -y || ${SUDO_CMD} apt-get update -y
        ${SUDO_CMD} apt-get install -y caddy
    elif command -v pacman &>/dev/null; then
        ${SUDO_CMD} pacman -Sy --noconfirm caddy
    elif command -v dnf &>/dev/null; then
        ${SUDO_CMD} dnf install -y 'dnf-command(copr)'
        ${SUDO_CMD} dnf copr enable -y @caddy/caddy
        ${SUDO_CMD} dnf install -y caddy
    else
        echo "未识别的包管理器，请手动安装 Caddy 后重试。"
        exit 1
    fi
}

# ==================== 卸载 Caddy 软件包 ====================
remove_caddy_package() {
    if ! command -v caddy &>/dev/null; then
        return 0
    fi

    echo ""
    read -rp "是否彻底卸载系统中的 Caddy 软件包及软件源? [y/N 默认: N]: " PURGE_CADDY
    PURGE_CADDY="${PURGE_CADDY:-N}"

    if [[ "$PURGE_CADDY" =~ ^[Yy]$ ]]; then
        echo ">> 正在彻底卸载 Caddy..."
        if command -v apt-get &>/dev/null; then
            ${SUDO_CMD} apt-get purge -y caddy || true
            ${SUDO_CMD} apt-get autoremove -y || true
            ${SUDO_CMD} rm -f /etc/apt/sources.list.d/caddy-stable.list
            ${SUDO_CMD} rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        elif command -v pacman &>/dev/null; then
            ${SUDO_CMD} pacman -Rns --noconfirm caddy || true
        elif command -v dnf &>/dev/null; then
            ${SUDO_CMD} dnf remove -y caddy || true
        fi
        echo ">> Caddy 软件包及源已彻底清除。"
    else
        echo ">> 已保留 Caddy 软件包及系统源。"
    fi
}

# ==================== Tracker 拉取模式 (best 精选 / all 全量) ====================
# 读取当前 update_tracker.sh 所用的模式；脚本不存在或不带标记时按默认 best
current_tracker_mode() {
    local mode=""
    if [ -f "${TRACKER_SCRIPT}" ]; then
        mode=$(grep -E '^TRACKER_MODE="(best|all)"' "${TRACKER_SCRIPT}" 2>/dev/null | head -n1 | cut -d'"' -f2)
        if [ -z "$mode" ]; then
            # 兼容旧版脚本(无 TRACKER_MODE 标记): 按其中的 URL 判断
            if grep -qE 'master/all\.txt|trackers_all\.txt' "${TRACKER_SCRIPT}" 2>/dev/null; then
                mode="all"
            fi
        fi
    fi
    if [ "$mode" = "all" ]; then
        printf 'all'
    else
        printf 'best'
    fi
}

tracker_mode_text() {
    if [ "$(current_tracker_mode)" = "all" ]; then
        printf '%b' "all (全量列表)"
    else
        printf '%b' "best (精选列表)"
    fi
}

# ==================== Tracker 自动更新周期 ====================
# 默认每周更新；取值使用 systemd 时间跨度写法 (如 12h / 24h / 72h / 1w / 2w)
TRACKER_INTERVAL_DEFAULT="1w"

# systemd 时间跨度 -> 中文可读说明
tracker_interval_text() {
    case "${1:-}" in
        "")        printf '每周 (1w，默认)' ;;
        12h)       printf '每 12 小时 (12h)' ;;
        24h|1d)    printf '每天 (24h)' ;;
        72h|3d)    printf '每 3 天 (72h)' ;;
        1w|7d)     printf '每周 (1w)' ;;
        2w|14d)    printf '每两周 (2w)' ;;
        30d|1month) printf '每 30 天 (30d)' ;;
        *)         printf '每 %s' "$1" ;;
    esac
}

# 读取当前更新周期(取自已写入的 timer 单元)；未安装或解析不到时返回默认值
current_tracker_interval() {
    local unit="${SYSTEMD_DIR}/aria2-update-tracker.timer"
    local value=""
    if [ -f "${unit}" ]; then
        value=$(grep -E '^OnUnitActiveSec=' "${unit}" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' \r')
    fi
    if [ -n "${value}" ]; then
        printf '%s' "${value}"
    else
        printf '%s' "${TRACKER_INTERVAL_DEFAULT}"
    fi
}

# 写入 Trackers 自动更新的 systemd 单元 (service + timer)，周期使用指定值，缺省沿用当前周期
write_tracker_timer_units() {
    local interval="${1:-}"
    if [ -z "$interval" ]; then
        interval="$(current_tracker_interval)"
    fi

    [ "$IS_ROOT" = false ] && mkdir -p "${SYSTEMD_DIR}"

    ${SUDO_CMD} bash -c "cat > '${SYSTEMD_DIR}/aria2-update-tracker.service'" <<EOF
[Unit]
Description=Update Aria2 BT Trackers
After=network.target

[Service]
Type=oneshot
ExecStart=${TRACKER_SCRIPT}
EOF

    ${SUDO_CMD} bash -c "cat > '${SYSTEMD_DIR}/aria2-update-tracker.timer'" <<EOF
[Unit]
Description=Run Aria2 Trackers Update Periodically

[Timer]
OnBootSec=10min
OnUnitActiveSec=${interval}
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

# ==================== 生成 Tracker 更新脚本 ====================
# 用法: ensure_tracker_script [best|all]
#   不带参数时沿用当前模式(无脚本则 best)，避免安装/开启定时器时把用户的 all 选择静默改回 best
ensure_tracker_script() {
    local mode="${1:-}"
    if [ "$mode" != "best" ] && [ "$mode" != "all" ]; then
        mode="$(current_tracker_mode)"
    fi

    local tracker_url_1 tracker_url_2
    if [ "$mode" = "all" ]; then
        tracker_url_1="https://bitbucket.org/xiu2/trackerslistcollection/raw/master/all.txt"
        tracker_url_2="https://cdn.jsdelivr.net/gh/ngosang/trackerslist@master/trackers_all.txt"
    else
        tracker_url_1="https://bitbucket.org/xiu2/trackerslistcollection/raw/master/best.txt"
        tracker_url_2="https://cdn.jsdelivr.net/gh/ngosang/trackerslist@master/trackers_best.txt"
    fi

    mkdir -p "${ARIA2_CONF_DIR}/scripts"
    cat > "${TRACKER_SCRIPT}" <<EOF
#!/usr/bin/env bash
CONF_FILE="${CONF_FILE}"
# 拉取模式: best(精选) / all(全量)
TRACKER_MODE="${mode}"
TRACKER_URL1="${tracker_url_1}"
TRACKER_URL2="${tracker_url_2}"

echo "正在从多源获取最新 Tracker 列表 (模式: \${TRACKER_MODE})..."
tracker_list=\$( (curl -sSL --connect-timeout 10 -m 30 "\${TRACKER_URL1}"; echo ""; curl -sSL --connect-timeout 10 -m 30 "\${TRACKER_URL2}") | tr -d '\r' | sed '/^[[:space:]]*#/d; /^[[:space:]]*\$/d' | sort -u | paste -sd "," - )

if [ -n "\$tracker_list" ]; then
    if grep -q "^bt-tracker=" "\$CONF_FILE"; then
        # 用 awk 按字面量写入，避免 tracker 中的 & | \ 被 sed 当作特殊字符
        KV_VAL="\$tracker_list" awk '
            BEGIN { key = "bt-tracker=" }
            index(\$0, key) == 1 { print key ENVIRON["KV_VAL"]; next }
            { print }
        ' "\$CONF_FILE" > "\${CONF_FILE}.tmp" && mv "\${CONF_FILE}.tmp" "\$CONF_FILE"
    else
        printf 'bt-tracker=%s\n' "\$tracker_list" >> "\$CONF_FILE"
    fi
    echo "Tracker 列表更新成功！"
    # 按运行模式重启: Docker 容器模式用 docker restart，本机模式用 systemctl
    if grep -q '^mode=docker' "${ARIA2_MODE_FILE}" 2>/dev/null; then
        docker restart "${ARIA2_DOCKER_NAME}" >/dev/null 2>&1 || sudo docker restart "${ARIA2_DOCKER_NAME}" >/dev/null 2>&1 || true
    else
        ${SYSTEMCTL_CMD} restart aria2.service
    fi
else
    echo "警告: Tracker 列表获取为空，跳过更新。"
    exit 1
fi
EOF
    chmod +x "${TRACKER_SCRIPT}"
}

# ==================== 生成 内核级吸血 Peer 拦截更新脚本 ====================
ensure_blocker_script() {
    mkdir -p "${ARIA2_CONF_DIR}/scripts"
    cat > "${BLOCKER_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -e

BLOCK_LIST_URL="https://bcr.pbh-btn.com/combine/all.txt"
SUDO_EXEC=""
[ "$EUID" -ne 0 ] && SUDO_EXEC="sudo"

echo ">> 正在从远程源获取吸血 Peer 黑名单..."
raw_content=$(curl -sSL --connect-timeout 15 -m 60 "${BLOCK_LIST_URL}" | tr -d '\r' | sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d')

if [ -z "$raw_content" ]; then
    echo "警告: 拉取黑名单为空，终止更新。"
    exit 1
fi

echo ">> 正在刷新 Linux 内核 ipset 集合..."
$SUDO_EXEC ipset create aria2_ban_v4 hash:net family inet -exist
$SUDO_EXEC ipset create aria2_ban_v6 hash:net family inet6 -exist

$SUDO_EXEC ipset flush aria2_ban_v4
$SUDO_EXEC ipset flush aria2_ban_v6

v4_count=0
v6_count=0

while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    if [[ "$ip" =~ : ]]; then
        $SUDO_EXEC ipset add aria2_ban_v6 "$ip" -exist
        ((v6_count++)) || true
    else
        $SUDO_EXEC ipset add aria2_ban_v4 "$ip" -exist
        ((v4_count++)) || true
    fi
done <<< "$raw_content"

echo ">> 正在挂载 iptables 丢弃规则..."
$SUDO_EXEC iptables -C INPUT -m set --match-set aria2_ban_v4 src -j DROP 2>/dev/null || \
$SUDO_EXEC iptables -I INPUT -m set --match-set aria2_ban_v4 src -j DROP

if command -v ip6tables &>/dev/null; then
    $SUDO_EXEC ip6tables -C INPUT -m set --match-set aria2_ban_v6 src -j DROP 2>/dev/null || \
    $SUDO_EXEC ip6tables -I INPUT -m set --match-set aria2_ban_v6 src -j DROP 2>/dev/null || true
fi

echo ">> 吸血 Peer 黑名单更新完毕！已成功注入 IPv4 规则 ${v4_count} 条，IPv6 规则 ${v6_count} 条。"
EOF
    chmod +x "${BLOCKER_SCRIPT}"
}

# ==================== 生成 BT 自动筛选 Python 守护脚本 ====================
ensure_filter_script() {
    local min_size="${1:-50}"
    local target_exts="${2:-ALL}"
    mkdir -p "${ARIA2_CONF_DIR}/scripts"

    cat > "${FILTER_SCRIPT}" <<EOF
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os
import time
import json
import urllib.request
import urllib.error

CONF_FILE = "${CONF_FILE}"
DEFAULT_PORT = 6800
DEFAULT_MIN_MB = ${min_size}
FILTER_EXTS = "${target_exts}"

def get_allowed_extensions():
    if FILTER_EXTS == "ALL":
        return None
    ext_list = [ext.strip().lower() for ext in FILTER_EXTS.split(",") if ext.strip()]
    return set(ext if ext.startswith(".") else "." + ext for ext in ext_list)

ALLOWED_EXTS = get_allowed_extensions()

def get_aria2_config():
    rpc_port = DEFAULT_PORT
    rpc_secret = ""
    if os.path.exists(CONF_FILE):
        with open(CONF_FILE, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if line.startswith("rpc-listen-port="):
                    try:
                        rpc_port = int(line.split("=", 1)[1].strip())
                    except ValueError:
                        pass
                elif line.startswith("rpc-secret="):
                    rpc_secret = line.split("=", 1)[1].strip()
    return rpc_port, rpc_secret

def rpc_call(method, params=None):
    port, secret = get_aria2_config()
    url = f"http://127.0.0.1:{port}/jsonrpc"
    p = []
    if secret:
        p.append(f"token:{secret}")
    if params:
        p.extend(params)

    payload = {
        "jsonrpc": "2.0",
        "id": "bt_filter_daemon",
        "method": method,
        "params": p
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=5) as resp:
            res = json.loads(resp.read().decode("utf-8"))
            return res.get("result")
    except Exception:
        return None

def process_tasks(handled_gids, min_size_mb):
    min_bytes = min_size_mb * 1024 * 1024
    active_tasks = rpc_call("aria2.tellActive") or []
    waiting_tasks = rpc_call("aria2.tellWaiting", [0, 100]) or []
    all_tasks = active_tasks + waiting_tasks

    current_gids = set()
    for task in all_tasks:
        gid = task.get("gid")
        current_gids.add(gid)
        
        if not task.get("bittorrent"):
            continue
        if gid in handled_gids:
            continue

        files = task.get("files", [])
        if not files or len(files) <= 1:
            continue

        selected_indices = []
        for f in files:
            path = f.get("path", "")
            length = int(f.get("length", 0))
            idx = str(f.get("index"))
            ext = os.path.splitext(path)[1].lower()

            if length < min_bytes:
                continue

            if ALLOWED_EXTS is not None and ext not in ALLOWED_EXTS:
                continue

            selected_indices.append(idx)

        if selected_indices:
            select_str = ",".join(selected_indices)
            rpc_call("aria2.changeOption", [gid, {"select-file": select_str}])
            desc = f"类型限制 [{FILTER_EXTS}]" if ALLOWED_EXTS else "任意格式"
            print(f"[Aria2-Filter] 成功为 GID {gid} 勾选符合项 ({desc}, >={min_size_mb}MB): 匹配 {len(selected_indices)}/{len(files)} 个文件 (索引: {select_str})", flush=True)
        else:
            print(f"[Aria2-Filter] 提示: 任务 GID {gid} 未匹配到符合条件的文件，保持默认全选下载。", flush=True)

        handled_gids.add(gid)

    obsolete = handled_gids - current_gids
    for gid in list(obsolete):
        handled_gids.remove(gid)

def main():
    type_info = f"扩展名: {FILTER_EXTS}" if ALLOWED_EXTS else "任意文件格式 (无后缀限制)"
    print(f"[Aria2-Filter] 守护进程启动完成！规则: 体积 >= {DEFAULT_MIN_MB}MB, {type_info}", flush=True)
    handled_gids = set()
    while True:
        try:
            process_tasks(handled_gids, DEFAULT_MIN_MB)
        except Exception:
            time.sleep(2)
        time.sleep(2)

if __name__ == "__main__":
    main()
EOF
    chmod +x "${FILTER_SCRIPT}"
}

# ==================== Aria2 二进制 (aria2-next) 下载 ====================
ARIA2_NEXT_REPO="AnInsomniacy/aria2-next"
# 无法联网获取最新 tag 时使用的固定版本(保证资源命名一致)
ARIA2_NEXT_FALLBACK_TAG="v2.8.2"
# aria2-next 的 Linux 发布二进制要求 glibc 不低于该版本
ARIA2_NEXT_MIN_GLIBC="2.35"
# 记录本次二进制来源，用于安装概要展示
ARIA2_INSTALL_NOTE=""

# 读取系统 glibc 版本(非 glibc 或读取失败时输出空)
detect_glibc_version() {
    local out=""
    if command -v getconf >/dev/null 2>&1; then
        out=$(getconf GNU_LIBC_VERSION 2>/dev/null || true)
    fi
    if [ -z "$out" ] && command -v ldd >/dev/null 2>&1; then
        out=$(ldd --version 2>/dev/null | head -n1 || true)
    fi
    printf '%s' "$out" | grep -oE '[0-9]+\.[0-9]+' | head -n1
}

# 通用版本比较: $1=实际版本 $2=要求版本，满足(>=)返回 0
version_at_least() {
    local have="$1" want="$2"
    [ -n "$have" ] || return 1
    [ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -n1)" = "$want" ]
}

# 当前 glibc 版本是否 >= 指定版本
glibc_at_least() {
    version_at_least "$(detect_glibc_version)" "$1"
}

# aria2-next 对应的 Linux 资源后缀(不支持的架构返回 1)
aria2_next_asset_suffix() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'linux-x86_64' ;;
        aarch64|arm64) printf 'linux-aarch64' ;;
        *) return 1 ;;
    esac
}

# 当前平台能否运行 aria2-next 官方预编译二进制
aria2_next_supported() {
    if ! aria2_next_asset_suffix >/dev/null 2>&1; then
        return 1
    fi
    glibc_at_least "$ARIA2_NEXT_MIN_GLIBC"
}

# 后端说明文本(用于安装确认前的概要展示)
aria2_backend_text() {
    printf 'aria2-next (AnInsomniacy/官方预编译优先，glibc 过旧则本机源码编译)'
}

# 平台不满足要求时的原因说明
aria2_next_unsupported_reason() {
    local arch="" glibc=""
    arch="$(uname -m)"
    if ! aria2_next_asset_suffix >/dev/null 2>&1; then
        printf '当前架构 %s 没有官方预编译产物(仅 x86_64 / aarch64)' "$arch"
        return 0
    fi
    glibc="$(detect_glibc_version)"
    printf '需要 glibc >= %s，当前为 %s' "$ARIA2_NEXT_MIN_GLIBC" "${glibc:-未知}"
}

# 识别已安装二进制的来源: next / legacy / unknown / none
detect_aria2_flavor() {
    [ -x "${ARIA2C_BIN}" ] || { printf 'none'; return 0; }
    local out="" help_out=""
    out=$("${ARIA2C_BIN}" --version 2>/dev/null | head -n 10 || true)
    if printf '%s' "$out" | grep -qi 'aria2-next'; then
        printf 'next'
        return 0
    fi
    # 兜底: 能力探测。aria2-next 独有 state-dir，旧版 aria2 没有该选项
    help_out=$("${ARIA2C_BIN}" --help=#all 2>/dev/null || true)
    if printf '%s' "$help_out" | grep -q -- '--state-dir'; then
        printf 'next'
        return 0
    fi
    if [ -n "$out" ]; then
        printf 'legacy'
    else
        printf 'unknown'
    fi
}

# 解析 aria2-next 最新 release tag，失败时用固定版本兑底
resolve_aria2_next_tag() {
    local api="https://api.github.com/repos/${ARIA2_NEXT_REPO}/releases/latest"
    local tag=""
    tag=$(curl -sSL -m 12 "$api" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 || true)
    if [ -n "$tag" ]; then
        printf '%s' "$tag"
    else
        printf '%s' "$ARIA2_NEXT_FALLBACK_TAG"
    fi
}

# 计算文件 sha256(优先 sha256sum，其次 openssl)
file_sha256() {
    local f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" 2>/dev/null | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$f" 2>/dev/null | awk '{print $NF}'
    fi
}

# 下载 GitHub 资源(先走加速代理，失败再直连)；成功返回 0
download_with_proxy_fallback() {
    local gh_path="$1" dest="$2"
    local direct="https://github.com/${gh_path}"
    local proxied="${GH_PROXY}/${gh_path}"
    local url=""
    if command -v curl >/dev/null 2>&1; then
        for url in "$proxied" "$direct"; do
            if curl -fSL --connect-timeout 15 -m 300 -o "$dest" "$url" 2>/dev/null && [ -s "$dest" ]; then
                return 0
            fi
        done
    elif command -v wget >/dev/null 2>&1; then
        for url in "$proxied" "$direct"; do
            if wget -q -T 20 -O "$dest" "$url" 2>/dev/null && [ -s "$dest" ]; then
                return 0
            fi
        done
    else
        return 1
    fi
    return 1
}

# 安装单一后端的二进制，成功返回 0
install_aria2_binary_backend() {
    local tmp_dir=""
    tmp_dir=$(mktemp -d)
    local candidate="${tmp_dir}/aria2c.new"
    mkdir -p "${ARIA2C_BIN_DIR}"

    local suffix="" tag="" ver="" asset=""
    suffix="$(aria2_next_asset_suffix)" || { echo ">> 本机架构无 aria2-next 预编译产物。"; rm -rf "${tmp_dir}"; return 1; }
    tag="$(resolve_aria2_next_tag)"
    ver="${tag#v}"
    asset="aria2-next-${ver}-${suffix}"

    echo ">> 版本: aria2-next ${tag} (${suffix})"
    echo ">> 正在下载 Aria2 二进制 (多源加速 + 直连回退)..."
    if ! download_with_proxy_fallback "${ARIA2_NEXT_REPO}/releases/download/${tag}/${asset}" "${candidate}"; then
        echo ">> !! aria2-next 下载失败，请检查网络后重试。"
        rm -rf "${tmp_dir}"
        return 1
    fi

    # SHA-256 校验: 官方提供 checksums 文件；拿不到时仅提示，校验不通过则中止
    local sums_file="${tmp_dir}/checksums.sha256"
    local expected="" actual=""
    if download_with_proxy_fallback "${ARIA2_NEXT_REPO}/releases/download/${tag}/aria2-next-${ver}-checksums.sha256" "${sums_file}"; then
        expected=$(awk -v n="$asset" '$2 == n || $2 == "*" n { print $1 }' "${sums_file}" 2>/dev/null | head -n1)
        actual="$(file_sha256 "${candidate}")"
        if [ -n "$expected" ] && [ -n "$actual" ] && [ "$expected" != "$actual" ]; then
            echo ">> !! SHA-256 校验不通过(期望 ${expected} / 实际 ${actual})。"
            rm -rf "${tmp_dir}"
            return 2
        fi
        if [ -n "$expected" ] && [ -n "$actual" ]; then
            echo ">> SHA-256 校验通过。"
        else
            echo ">> 提示: 校验信息不完整，已跳过 SHA-256 校验。"
        fi
    else
        echo ">> 提示: 未获取到官方校验文件，已跳过 SHA-256 校验。"
    fi

    chmod +x "${candidate}" 2>/dev/null || true
    # 先验证能否执行(既校验完整性，也提前发现 glibc 过旧等问题)，再覆盖现有二进制
    if ! "${candidate}" --version >/dev/null 2>&1; then
        echo ">> !! 下载的二进制无法在本机执行(--version 失败)，可能 glibc 版本不足。"
        rm -rf "${tmp_dir}"
        return 1
    fi

    mv -f "${candidate}" "${ARIA2C_BIN}"
    chmod +x "${ARIA2C_BIN}" 2>/dev/null || true
    rm -rf "${tmp_dir}"
    echo ">> 已安装: ${ARIA2C_BIN}"
    "${ARIA2C_BIN}" --version 2>/dev/null | head -n1 | sed 's/^/   /' || true
    return 0
}

# 安装 Aria2 二进制(aria2-next)；返回 2 表示完整性校验失败
install_aria2_binary() {
    local rc=0
    install_aria2_binary_backend || rc=$?
    if [ "$rc" -eq 0 ]; then
        return 0
    fi
    if [ "$rc" -eq 2 ]; then
        echo ">> !! 安装包完整性校验失败，为避免装入被篡改/损坏的程序，已中止。"
        echo "   可稍后重试；若反复出现，请检查网络或下载加速代理。"
        return 1
    fi
    echo ">> !! aria2-next 安装失败，请检查网络/架构/glibc 后重试。"
    return 1
}

# ==================== aria2-next 源码编译 (glibc 过旧时的官方可行路径) ====================
# 官方 Linux 预编译以 Ubuntu 22.04 为基线(glibc >= 2.35)，在更旧的系统(如 RHEL/Rocky/Alma 9
# 的 glibc 2.34)上无法运行。此时保留 aria2-next 的唯一官方路径就是本机源码编译：
# 依赖库全部内置在源码 third_party 中，只需 CMake >= 3.25、Ninja/Make、Perl 与 C/C++ 工具链，
# 编译产物只依赖本机 glibc，因此在旧系统上可以正常运行。
ARIA2_NEXT_MIN_CMAKE="3.25"
ARIA2_NEXT_BUILD_ROOT="${ARIA2_CONF_DIR}/build"
ARIA2_NEXT_TOOLS_DIR="${ARIA2_CONF_DIR}/tools"
# 系统 CMake 过旧时下载 Kitware 官方静态版(要求 glibc >= 2.17，兼容老系统)
ARIA2_CMAKE_FALLBACK_VER="3.31.6"
# 源码编译建议的最小可用磁盘(GB)
ARIA2_BUILD_MIN_FREE_GB=8

# 读取某个 cmake 可执行文件的版本号
cmake_cmd_version() {
    "$1" --version 2>/dev/null | sed -n '1s/[^0-9]*\([0-9][0-9.]*\).*/\1/p'
}

# 解析可用的 CMake (>= 3.25)：优先系统自带，其次 Kitware 官方静态版
# 注意: 诊断信息一律输出到 stderr，函数 stdout 只用于回传路径
resolve_cmake_bin() {
    local sys_cmake="" arch="" tag="" base="" pkg=""
    sys_cmake="$(command -v cmake 2>/dev/null || true)"
    if [ -n "$sys_cmake" ] && version_at_least "$(cmake_cmd_version "$sys_cmake")" "$ARIA2_NEXT_MIN_CMAKE"; then
        printf '%s' "$sys_cmake"
        return 0
    fi
    if [ -x "${ARIA2_NEXT_TOOLS_DIR}/cmake/bin/cmake" ] \
        && version_at_least "$(cmake_cmd_version "${ARIA2_NEXT_TOOLS_DIR}/cmake/bin/cmake")" "$ARIA2_NEXT_MIN_CMAKE"; then
        printf '%s' "${ARIA2_NEXT_TOOLS_DIR}/cmake/bin/cmake"
        return 0
    fi

    case "$(uname -m)" in
        x86_64|amd64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) return 1 ;;
    esac

    tag=$(curl -sSL -m 12 https://api.github.com/repos/Kitware/CMake/releases/latest 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' | head -n1 || true)
    [ -n "$tag" ] || tag="$ARIA2_CMAKE_FALLBACK_VER"
    base="cmake-${tag}-linux-${arch}"
    pkg="${ARIA2_NEXT_TOOLS_DIR}/${base}.tar.gz"

    echo ">> 系统 CMake 缺失或低于 ${ARIA2_NEXT_MIN_CMAKE}，正在下载官方静态版 CMake ${tag} (${arch})..." >&2
    mkdir -p "${ARIA2_NEXT_TOOLS_DIR}"
    if ! download_with_proxy_fallback "Kitware/CMake/releases/download/v${tag}/${base}.tar.gz" "${pkg}"; then
        echo ">> !! CMake 下载失败，请检查网络后重试。" >&2
        return 1
    fi
    rm -rf "${ARIA2_NEXT_TOOLS_DIR}/cmake" "${ARIA2_NEXT_TOOLS_DIR}/${base}"
    if ! tar -xzf "${pkg}" -C "${ARIA2_NEXT_TOOLS_DIR}"; then
        echo ">> !! CMake 解压失败。" >&2
        rm -f "${pkg}"
        return 1
    fi
    rm -f "${pkg}"
    mv "${ARIA2_NEXT_TOOLS_DIR}/${base}" "${ARIA2_NEXT_TOOLS_DIR}/cmake" 2>/dev/null || true
    if [ ! -x "${ARIA2_NEXT_TOOLS_DIR}/cmake/bin/cmake" ]; then
        echo ">> !! CMake 安装失败 (未找到 bin/cmake)。" >&2
        return 1
    fi
    printf '%s' "${ARIA2_NEXT_TOOLS_DIR}/cmake/bin/cmake"
}

# 安装源码编译所需工具链(按发行版映射包名)，并校验关键命令
ensure_build_toolchain() {
    local pkgs="" tool="" have_cc="" have_cxx=""
    local -a missing=()

    if command -v apt-get >/dev/null 2>&1; then
        pkgs="cmake ninja-build make perl gcc g++ pkg-config binutils curl tar"
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        pkgs="cmake ninja-build make perl gcc gcc-c++ pkgconf-pkg-config binutils curl tar"
    elif command -v pacman >/dev/null 2>&1; then
        pkgs="cmake ninja make perl gcc pkgconf binutils curl tar"
    elif command -v zypper >/dev/null 2>&1; then
        pkgs="cmake ninja make perl gcc gcc-c++ pkg-config binutils curl tar"
    fi

    if [ -n "$pkgs" ]; then
        echo ">> 正在检查/安装编译工具链: ${pkgs}"
        install_packages $pkgs || true
    fi

    for tool in cc gcc clang; do
        if command -v "$tool" >/dev/null 2>&1; then have_cc="$tool"; break; fi
    done
    for tool in c++ g++ clang++; do
        if command -v "$tool" >/dev/null 2>&1; then have_cxx="$tool"; break; fi
    done
    [ -n "$have_cc" ] || missing+=("C 编译器(gcc/clang)")
    [ -n "$have_cxx" ] || missing+=("C++ 编译器(g++/clang++)")
    for tool in make perl tar; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        missing+=("curl 或 wget")
    fi
    if ! command -v pkg-config >/dev/null 2>&1 && ! command -v pkgconf >/dev/null 2>&1; then
        echo ">> 提示: 未检测到 pkg-config/pkgconf，部分内置依赖可能配置失败。"
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo ">> !! 缺少编译所需工具: ${missing[*]}"
        echo "   请手动安装后重试 (Ubuntu/Debian: sudo apt install build-essential cmake ninja-build pkg-config perl binutils)"
        return 1
    fi
    return 0
}

# 目录可用空间(GB，向下取整)；目录尚不存在时回溯到最近的父目录
dir_free_gb() {
    local path="${1%/}"
    while [ -n "$path" ] && [ ! -d "$path" ]; do
        path="$(dirname "$path")"
    done
    [ -d "$path" ] || return 0
    df -Pk "$path" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}'
}

# 源码编译并安装 aria2-next；成功返回 0
build_aria2_next_from_source() {
    echo ""
    echo "=========== 源码编译安装 aria2-next ==========="

    if ! aria2_next_asset_suffix >/dev/null 2>&1; then
        echo ">> !! 当前架构 $(uname -m) 不在项目维护的构建矩阵内 (仅 x86_64 / aarch64)。"
        echo "   请参考 https://github.com/${ARIA2_NEXT_REPO} 的 Build 章节手动编译。"
        return 1
    fi

    local glibc_have="" free_gb=""
    glibc_have="$(detect_glibc_version)"
    echo ">> 当前 glibc: ${glibc_have:-未知} (官方预编译要求 >= ${ARIA2_NEXT_MIN_GLIBC})"
    echo ">> 编译方式: 官方 superbuild，依赖库全部来自源码 third_party，无需额外开发库"
    echo ">> 预计耗时 30-90 分钟；需要磁盘约 ${ARIA2_BUILD_MIN_FREE_GB}GB、内存峰值 2-4GB"

    free_gb="$(dir_free_gb "${ARIA2_CONF_DIR}")"
    if [ -n "$free_gb" ] && [ "$free_gb" -lt "$ARIA2_BUILD_MIN_FREE_GB" ]; then
        echo ">> !! 警告: ${ARIA2_CONF_DIR} 所在分区可用空间约 ${free_gb}GB，低于建议的 ${ARIA2_BUILD_MIN_FREE_GB}GB。"
        echo "   内置的 OpenSSL / libtorrent / FFmpeg / GPAC 体量较大，可能因磁盘写满而中途失败。"
    fi

    read -rp "确认开始源码编译? [Y/n 默认: Y]: " CONFIRM_BUILD
    CONFIRM_BUILD="${CONFIRM_BUILD:-Y}"
    if [[ ! "$CONFIRM_BUILD" =~ ^[Yy]$ ]]; then
        echo ">> 已取消源码编译。"
        return 1
    fi

    install_packages curl wget python3 tar findutils
    ensure_build_toolchain || return 1

    local cmake_bin=""
    if ! cmake_bin="$(resolve_cmake_bin)"; then
        echo ">> !! 无法获得 CMake >= ${ARIA2_NEXT_MIN_CMAKE}，源码编译中止。"
        return 1
    fi
    echo ">> 使用 CMake: ${cmake_bin} (版本 $(cmake_cmd_version "$cmake_bin"))"

    local tag="" ver="" tarball="" src_root="" build_dir=""
    tag="$(resolve_aria2_next_tag)"
    ver="${tag#v}"
    mkdir -p "${ARIA2_NEXT_BUILD_ROOT}"
    tarball="${ARIA2_NEXT_BUILD_ROOT}/aria2-next-${ver}.tar.gz"
    src_root="${ARIA2_NEXT_BUILD_ROOT}/aria2-next-${ver}"
    build_dir="${ARIA2_NEXT_BUILD_ROOT}/out-${ver}"

    if [ ! -d "${src_root}/third_party" ]; then
        echo ">> 正在下载 aria2-next ${tag} 源码包 (含内置依赖源码，体积较大)..."
        rm -rf "${src_root}"
        if ! download_with_proxy_fallback "${ARIA2_NEXT_REPO}/archive/refs/tags/${tag}.tar.gz" "${tarball}"; then
            echo ">> !! 源码包下载失败，请检查网络后重试。"
            return 1
        fi
        if ! tar -xzf "${tarball}" -C "${ARIA2_NEXT_BUILD_ROOT}"; then
            echo ">> !! 源码包解压失败。"
            rm -f "${tarball}"
            return 1
        fi
        rm -f "${tarball}"
    else
        echo ">> 已存在源码目录，跳过下载: ${src_root}"
    fi
    # 解压目录名与预期不一致时，直接在解压根目录下定位 third_party 所属目录
    if [ ! -d "${src_root}/third_party" ]; then
        local found=""
        found=$(find "${ARIA2_NEXT_BUILD_ROOT}" -maxdepth 2 -type d -name third_party 2>/dev/null | head -n1 || true)
        if [ -n "$found" ]; then
            src_root="$(dirname "$found")"
            echo ">> 源码目录已解析为: ${src_root}"
        fi
    fi
    if [ ! -d "${src_root}/third_party" ]; then
        echo ">> !! 源码目录不完整 (缺少 third_party): ${src_root}"
        return 1
    fi

    local -a gen_args=()
    local jobs=2 ram_mb=0
    if command -v ninja >/dev/null 2>&1; then
        gen_args=(-G Ninja)
    else
        gen_args=(-G "Unix Makefiles")
        echo ">> 提示: 未检测到 ninja，改用 Unix Makefiles 生成器。"
    fi

    jobs="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2')"
    [[ "$jobs" =~ ^[0-9]+$ ]] || jobs=2
    ram_mb=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || printf '0')
    [[ "$ram_mb" =~ ^[0-9]+$ ]] || ram_mb=0
    if [ "$ram_mb" -gt 0 ] && [ "$ram_mb" -lt 4096 ] && [ "$jobs" -gt 2 ]; then
        jobs=2
        echo ">> 可用内存较低 (${ram_mb}MB)，并行任务数已降为 2 以避免编译期内存不足。"
    fi

    echo ">> 正在配置构建 (Release / LTO 已关闭以降低内存占用与耗时)..."
    if ! ( cd "${src_root}" && PREFIX="${build_dir}/dependencies" \
            "$cmake_bin" -S . -B "${build_dir}" "${gen_args[@]}" \
                -DCMAKE_BUILD_TYPE=Release \
                -DARIA2_RELEASE_SIZE_OPTIMIZED=ON \
                -DARIA2_RELEASE_LTO=OFF \
                -DBUILD_TESTING=OFF \
                -DCMAKE_SKIP_RPATH=ON ); then
        echo ">> !! CMake 配置失败，请查看上方错误信息。"
        return 1
    fi

    echo ">> 正在编译 (并行 ${jobs})。这一步耗时最长；中断后重跑本功能会复用已编译的中间产物。"
    if ! "$cmake_bin" --build "${build_dir}" --target aria2_project -j"${jobs}"; then
        echo ">> !! 编译失败，请查看上方错误信息。"
        echo "   源码与中间产物已保留在 ${ARIA2_NEXT_BUILD_ROOT}，修复问题后可重新执行本功能。"
        return 1
    fi

    local built="${build_dir}/aria2-next"
    if [ ! -x "$built" ]; then
        echo ">> !! 未找到编译产物: ${built}"
        return 1
    fi
    if ! "$built" --version >/dev/null 2>&1; then
        echo ">> !! 编译产物无法在本机执行。"
        return 1
    fi

    mkdir -p "${ARIA2C_BIN_DIR}"
    if [ -w "${ARIA2C_BIN_DIR}" ]; then
        cp -f "$built" "${ARIA2C_BIN}"
        chmod +x "${ARIA2C_BIN}" 2>/dev/null || true
    else
        ${SUDO_CMD} cp -f "$built" "${ARIA2C_BIN}"
        ${SUDO_CMD} chmod +x "${ARIA2C_BIN}" 2>/dev/null || true
    fi

    ARIA2_INSTALL_NOTE="本机源码编译"
    echo ""
    echo ">> [成功] 已安装源码编译版 aria2-next: ${ARIA2C_BIN}"
    "${ARIA2C_BIN}" --version 2>/dev/null | head -n 3 | sed 's/^/   /' || true

    echo ""
    read -rp "是否删除编译目录 (源码+中间产物，可释放数 GB 空间)? [y/N 默认: N]: " CLEAN_BUILD
    CLEAN_BUILD="${CLEAN_BUILD:-N}"
    if [[ "$CLEAN_BUILD" =~ ^[Yy]$ ]]; then
        rm -rf "${ARIA2_NEXT_BUILD_ROOT}"
        echo ">> 已删除编译目录。"
    else
        echo ">> 已保留编译目录 (可随时手动删除): ${ARIA2_NEXT_BUILD_ROOT}"
    fi
    return 0
}

# ==================== 模块 1: 安装 / 重新配置 Aria2 后端 ====================
install_aria2() {
    echo ""
    echo "=========================================="
    if [ -f "${ARIA2C_BIN}" ]; then
        echo "            重新配置 Aria2 后端           "
    else
        echo "            安装 / 配置 Aria2 后端        "
    fi
    echo "=========================================="

    local CURRENT_DIR=""
    local CURRENT_PORT=""
    local CURRENT_SECRET=""
    if [ -f "${CONF_FILE}" ]; then
        CURRENT_DIR=$(grep -E "^dir=" "${CONF_FILE}" 2>/dev/null | cut -d'=' -f2- | tr -d '\r')
        CURRENT_PORT=$(grep -E "^rpc-listen-port=" "${CONF_FILE}" 2>/dev/null | cut -d'=' -f2- | tr -d '\r')
        CURRENT_SECRET=$(grep -E "^rpc-secret=" "${CONF_FILE}" 2>/dev/null | cut -d'=' -f2- | tr -d '\r')
    fi

    local DEF_DIR="${CURRENT_DIR:-$DEFAULT_DOWNLOAD_DIR}"
    local DEF_PORT="${CURRENT_PORT:-$DEFAULT_PORT}"

    read -rp "请输入下载目录路径 [默认: ${DEF_DIR}]: " INPUT_DIR
    DOWNLOAD_DIR="${INPUT_DIR:-$DEF_DIR}"
    DOWNLOAD_DIR="${DOWNLOAD_DIR%/}"

    read -rp "请输入 Aria2 RPC 监听端口 [默认: ${DEF_PORT}]: " INPUT_PORT
    RPC_PORT="${INPUT_PORT:-$DEF_PORT}"

    while true; do
        if [ -n "$CURRENT_SECRET" ]; then
            read -rp "请输入 RPC 密钥 (rpc-secret) [默认保留当前设置]: " INPUT_SECRET || { echo ""; echo ">> 输入已结束，已取消操作。"; return 1; }
            RPC_SECRET="${INPUT_SECRET:-$CURRENT_SECRET}"
        else
            read -rp "请输入 RPC 密钥 (rpc-secret，不能为空): " RPC_SECRET || { echo ""; echo ">> 输入已结束，已取消操作。"; return 1; }
        fi

        if [ -n "$RPC_SECRET" ]; then
            break
        fi
        echo "RPC 密钥不能为空，请重新输入！"
    done
    # ---- 运行方式选择: 本机二进制(systemd) / Docker 容器 ----
    local PREV_RUN_MODE="${ARIA2_RUN_MODE}"
    echo ""
    echo "请选择 Aria2 运行方式:"
    echo "  1. 本机二进制 + systemd 服务 (默认；预编译安装，glibc 过旧则源码编译)"
    echo "  2. Docker 容器 (使用官方镜像，无需本机编译，适合 glibc 过旧的环境)"
    local RUN_MODE_DEFAULT="1"
    is_docker_mode && RUN_MODE_DEFAULT="2"
    read -rp "请选择 [1-2 默认: ${RUN_MODE_DEFAULT}]: " RUN_MODE_CHOICE
    RUN_MODE_CHOICE="${RUN_MODE_CHOICE:-$RUN_MODE_DEFAULT}"
    if [ "$RUN_MODE_CHOICE" = "2" ]; then
        ARIA2_RUN_MODE="docker"
    else
        ARIA2_RUN_MODE="systemd"
    fi

    # 运行方式发生切换时，先清理另一种方式的实例，避免 RPC 端口冲突
    if [ "${PREV_RUN_MODE}" != "${ARIA2_RUN_MODE}" ]; then
        if is_docker_mode; then
            if [ -f "${SYSTEMD_DIR}/aria2.service" ] || ${SYSTEMCTL_CMD} is-active --quiet aria2.service 2>/dev/null; then
                echo ">> 检测到本机 systemd 服务，正在停止并禁用以避免端口冲突..."
                ${SYSTEMCTL_CMD} stop aria2.service 2>/dev/null || true
                ${SYSTEMCTL_CMD} disable aria2.service 2>/dev/null || true
            fi
        else
            if docker_ensure && docker_container_exists; then
                echo ">> 检测到旧的 aria2 Docker 容器 ${ARIA2_DOCKER_NAME}，正在删除以避免端口冲突..."
                $DOCKER_CMD rm -f "${ARIA2_DOCKER_NAME}" >/dev/null 2>&1 || true
            fi
        fi
    fi

    if is_docker_mode; then
        read -rp "Docker 镜像地址 [默认: ${ARIA2_DOCKER_IMAGE}]: " INPUT_DOCKER_IMAGE
        ARIA2_DOCKER_IMAGE="${INPUT_DOCKER_IMAGE:-$ARIA2_DOCKER_IMAGE}"
        read -rp "镜像标签 (tag) [默认: ${ARIA2_DOCKER_TAG}]: " INPUT_DOCKER_TAG
        ARIA2_DOCKER_TAG="${INPUT_DOCKER_TAG:-$ARIA2_DOCKER_TAG}"
        read -rp "容器名称 [默认: ${ARIA2_DOCKER_NAME}]: " INPUT_DOCKER_NAME
        ARIA2_DOCKER_NAME="${INPUT_DOCKER_NAME:-$ARIA2_DOCKER_NAME}"
    fi

    echo ""
    read -rp "是否顺带安装/更新 AriaNg Web 前端 (Caddy 反代模式)? [y/N 默认: N]: " WITH_ARIANG
    WITH_ARIANG="${WITH_ARIANG:-N}"

    echo ""
    echo "=== Aria2 配置概要 ==="
    echo "运行模式: $([ "$IS_ROOT" = true ] && echo "Root 系统模式" || echo "普通用户模式 ($CURRENT_USER)")"
    echo "运行方式: $(is_docker_mode && echo "Docker 容器 (${ARIA2_DOCKER_IMAGE}:${ARIA2_DOCKER_TAG})" || echo "本机二进制 + systemd 服务")"
    echo "Aria2 后端: $(aria2_backend_text)"
    echo "下载目录: ${DOWNLOAD_DIR}"
    echo "RPC 端口: ${RPC_PORT}"
    echo "RPC 密钥: ${RPC_SECRET}"
    echo "顺带配置 AriaNg: $([[ "$WITH_ARIANG" =~ ^[Yy]$ ]] && echo "是" || echo "否")"
    echo "Trackers 自动更新: 默认开启 (周期: $(tracker_interval_text "$(current_tracker_interval)")，可在主菜单 4 调整)"
    echo "全局最大上传限制: 2M"
    echo "全局下载速度限制: 不限速 (0)"
    echo "BT 默认做种策略: 分享率达到 1.0 停止做种"
    echo "断点/恢复状态目录: ${STATE_DIR} (aria2-next 原生恢复数据)"
    echo "吸血 Peer 防火墙: 默认自动开启 (ipset + iptables 拦截)"
    echo "======================"
    read -rp "确认应用并保存配置? [Y/n 默认: Y]: " CONFIRM
    CONFIRM="${CONFIRM:-Y}"
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "已取消操作。"
        return 0
    fi
    if is_docker_mode; then
        if ! docker_ensure; then
            echo ">> 未检测到可用的 Docker，正在尝试自动安装 (系统源不提供时需手动安装)..."
            for _pkg in docker.io moby-engine docker; do
                install_packages "$_pkg" >/dev/null 2>&1 || true
                ${SUDO_CMD} systemctl enable --now docker >/dev/null 2>&1 || true
                docker_ensure && break
            done
        fi
        if ! docker_ensure; then
            echo ""
            echo ">> !! 未检测到可用的 Docker (命令缺失 / 守护进程未运行 / 当前用户无权限)。"
            echo "   请手动安装并启动 Docker:"
            echo "     Ubuntu/Debian : sudo apt install -y docker.io && sudo systemctl enable --now docker"
            echo "     RHEL/Rocky 9  : sudo dnf install -y moby-engine (需 EPEL) 或安装官方 docker-ce"
            echo "   若当前用户无权限，可加入 docker 组后重新登录:"
            echo "     sudo usermod -aG docker ${CURRENT_USER}"
            echo "   也可以退出本功能，改用『本机二进制 (预编译 / 源码编译)』方案。"
            return 1
        fi
        install_packages curl python3
        echo ">> 已选择 Docker 运行方式 (${DOCKER_CMD})，跳过本机二进制安装与编译。"
    else

    local NEED_DOWNLOAD=true
    if [ -f "${ARIA2C_BIN}" ] && [ -x "${ARIA2C_BIN}" ]; then
        local CUR_FLAVOR=""
        CUR_FLAVOR="$(detect_aria2_flavor)"
        NEED_DOWNLOAD=false
        if [ "$CUR_FLAVOR" != "next" ]; then
            echo ""
            echo ">> 检测到已有 Aria2 二进制 (来源: ${CUR_FLAVOR})，而本脚本已统一改用 aria2-next。"
            echo "   注意: 本脚本生成的配置含 aria2-next 专属项 (state-dir)，旧版 aria2 无法解析，"
            echo "         且 aria2-next 不再生成 .aria2 断点文件、也不导入旧版 session/断点状态。"
            read -rp "是否安装/替换为 aria2-next? [y/N 默认: N]: " SWITCH_BACKEND
            SWITCH_BACKEND="${SWITCH_BACKEND:-N}"
            if [[ "$SWITCH_BACKEND" =~ ^[Yy]$ ]]; then
                NEED_DOWNLOAD=true
            else
                echo ">> 已取消：未安装替代二进制，本次配置中止。"
                return 1
            fi
        else
            echo ""
            echo ">> 检测到 ${ARIA2C_BIN} 已存在，跳过重新下载二进制程序。"
        fi
    fi

    if [ "$NEED_DOWNLOAD" = true ]; then
        install_packages curl wget python3
        if aria2_next_supported; then
            install_aria2_binary || { echo ">> [失败] Aria2 二进制安装失败，已中止本次配置。"; return 1; }
            ARIA2_INSTALL_NOTE="官方预编译"
        else
            echo ""
            echo ">> 无法直接使用 aria2-next 官方预编译产物: $(aria2_next_unsupported_reason)"
            echo "   说明: 官方 Linux 预编译仅覆盖 x86_64 / aarch64，并以 Ubuntu 22.04 为基线"
            echo "         (glibc ${ARIA2_NEXT_MIN_GLIBC}+)；glibc 更旧的系统 (如 RHEL/Rocky/Alma 9 为 2.34) 无法运行。"
            echo ""
            echo "   可选方案:"
            echo "     1. 本机源码编译 aria2-next (推荐；旧 glibc 上保留 aria2-next 的官方路径)"
            echo "     2. 取消本次配置 (可重新运行主菜单 1，在『运行方式』处改选 Docker 容器运行)"
            read -rp "请选择 [1-2 默认: 1]: " BUILD_FALLBACK
            BUILD_FALLBACK="${BUILD_FALLBACK:-1}"
            if [ "$BUILD_FALLBACK" != "1" ]; then
                echo ">> 已取消，未做任何变更。"
                return 1
            fi
            build_aria2_next_from_source || { echo ">> [失败] 源码编译未完成，已中止本次配置。"; return 1; }
        fi
    fi

    # 本脚本生成的配置含 aria2-next 专属项(state-dir)，必须确认最终二进制确实是 aria2-next
    local FINAL_FLAVOR=""
    FINAL_FLAVOR="$(detect_aria2_flavor)"
    if [ "$FINAL_FLAVOR" != "next" ]; then
        echo ""
        echo ">> [中止] 当前 ${ARIA2C_BIN} 不是 aria2-next (识别结果: ${FINAL_FLAVOR})。"
        echo "   旧版 aria2 无法解析本脚本生成的配置 (state-dir 等专属项)，服务会启动失败。"
        echo "   请改用源码编译或替换为 aria2-next 后重新运行本功能。"
        return 1
    fi

    fi   # end of systemd-mode binary preparation

    mkdir -p "${DOWNLOAD_DIR}"
    mkdir -p "${ARIA2_CONF_DIR}"
    mkdir -p "${STATE_DIR}"
    touch "${SESSION_FILE}"
    touch "${LOG_FILE}"

    echo ">> 写入/更新 aria2.conf..."
    cat > "${CONF_FILE}" <<EOF
## 日志设置 ##
log=${LOG_FILE}
log-level=warn

## 文件保存设置 ##
dir=${DOWNLOAD_DIR}
disk-cache=64M
file-allocation=falloc
continue=true

## 下载与速度设置 ##
## 注: aria2-next 的 HTTP(S) 分片/连接数由引擎自适应管理，
##     旧的 split / min-split-size / max-connection-per-server 已不再支持；
##     如需限制单任务并发连接数，可自行启用 stream-max-connections。
max-concurrent-downloads=5
disable-ipv6=true
max-overall-upload-limit=2M
max-upload-limit=2M
max-overall-download-limit=0
max-download-limit=0

## 做种与分享率设置 ##
seed-time=0
seed-ratio=1.0

## 会话与断点设置 (aria2-next: 原生恢复数据存于 state-dir) ##
input-file=${SESSION_FILE}
save-session=${SESSION_FILE}
save-session-interval=60
state-dir=${STATE_DIR}

## RPC 设置 ##
enable-rpc=true
rpc-allow-origin-all=true
rpc-listen-all=true
rpc-listen-port=${RPC_PORT}
rpc-secret=${RPC_SECRET}

## BT/PT 设置 ##
follow-torrent=mem
bt-tracker=
EOF

    ensure_tracker_script

    if is_docker_mode; then
        # ---- Docker 模式: 拉取镜像并按当前配置启动容器 ----
        save_run_mode
        echo ">> 正在拉取镜像 ${ARIA2_DOCKER_IMAGE}:${ARIA2_DOCKER_TAG}..."
        if ! $DOCKER_CMD pull "${ARIA2_DOCKER_IMAGE}:${ARIA2_DOCKER_TAG}"; then
            echo ">> !! 镜像拉取失败，请检查网络或镜像地址后重试。"
            return 1
        fi
        docker_apply_container || return 1

        # Trackers 定时更新单元在两种模式下通用 (脚本内部按模式选择重启方式)
        write_tracker_timer_units
        ${SYSTEMCTL_CMD} daemon-reload 2>/dev/null || true
        ${SYSTEMCTL_CMD} enable --now aria2-update-tracker.timer 2>/dev/null || true
    else
    save_run_mode
    [ "$IS_ROOT" = false ] && mkdir -p "${SYSTEMD_DIR}"

    if [ "$IS_ROOT" = true ]; then
        ${SUDO_CMD} bash -c "cat > '${SYSTEMD_DIR}/aria2.service'" <<EOF
[Unit]
Description=Aria2c Download Manager
After=network.target

[Service]
Type=simple
User=root
LimitNOFILE=65535
ExecStart=${ARIA2C_BIN} --conf-path=${CONF_FILE}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
    else
        cat > "${SYSTEMD_DIR}/aria2.service" <<EOF
[Unit]
Description=Aria2c Download Manager
After=network.target

[Service]
Type=simple
LimitNOFILE=65535
ExecStart=${ARIA2C_BIN} --conf-path=${CONF_FILE}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
    fi

    # Trackers 自动更新单元: 周期沿用已保存的值(未设置过则为默认每周 1w)
    write_tracker_timer_units

    ${SYSTEMCTL_CMD} daemon-reload
    ${SYSTEMCTL_CMD} enable --now aria2.service
    ${SYSTEMCTL_CMD} restart aria2.service
    ${SYSTEMCTL_CMD} enable --now aria2-update-tracker.timer
    fi   # end of systemd-mode service bring-up

    echo ">> 正在同步 Trackers 列表..."
    bash "${TRACKER_SCRIPT}" 2>/dev/null || true

    echo ">> 正在默认初始化开启吸血 Peer 防火墙拦截 (ipset + iptables)..."
    install_packages ipset iptables
    ensure_blocker_script

    ${SUDO_CMD} bash -c "cat > /etc/systemd/system/aria2-peer-blocker.service" <<EOF
[Unit]
Description=Update Aria2 Peer Blacklist to Linux Firewall (ipset)
After=network.target

[Service]
Type=oneshot
ExecStart=${BLOCKER_SCRIPT}
EOF

    ${SUDO_CMD} bash -c "cat > /etc/systemd/system/aria2-peer-blocker.timer" <<EOF
[Unit]
Description=Daily update of Aria2 Peer Blacklist

[Timer]
OnBootSec=15min
OnUnitActiveSec=24h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    ${SUDO_CMD} systemctl daemon-reload
    ${SUDO_CMD} systemctl enable --now aria2-peer-blocker.timer
    bash "${BLOCKER_SCRIPT}" 2>/dev/null || true

    if [ "$IS_ROOT" = false ] && command -v loginctl &>/dev/null; then
        sudo loginctl enable-linger "${CURRENT_USER}" 2>/dev/null || true
    fi

    echo ""
    echo ">> Aria2 后端配置并启动成功！"
    if is_docker_mode; then
        echo "   运行方式: Docker 容器 ${ARIA2_DOCKER_NAME} (${ARIA2_DOCKER_IMAGE}:${ARIA2_DOCKER_TAG})"
    elif [ -n "${ARIA2_INSTALL_NOTE:-}" ]; then
        echo "   二进制来源: aria2-next (${ARIA2_INSTALL_NOTE})"
    fi
    echo "   下载目录: ${DOWNLOAD_DIR}"
    echo "   RPC 端口: ${RPC_PORT}"
    echo "   RPC 密钥: ${RPC_SECRET}"
    echo "   做种策略: 分享率达到 1.0 自动停止"
    echo "   吸血拦截: 已自动启用每日封禁"
    echo "   服务状态: $(get_aria2_status)"

    if [[ "$WITH_ARIANG" =~ ^[Yy]$ ]]; then
        install_ariang "${RPC_PORT}"
    fi
}

# ==================== 模块 2: Aria2 常用核心设置 (下载目录/并发/做种/限速/占位清理) ====================
manage_core_settings() {
    if [ ! -f "${CONF_FILE}" ]; then
        echo "未检测到配置文件: ${CONF_FILE}，请先执行安装 Aria2！"
        return 1
    fi

    while true; do
        local cur_dir cur_concurrent cur_up_limit cur_down_limit cur_seed_time cur_seed_ratio cur_state_dir cur_listen_port
        cur_dir=$(get_current_download_dir)
        cur_concurrent=$(get_conf_value "max-concurrent-downloads" "5")
        cur_up_limit=$(get_conf_value "max-overall-upload-limit" "2M")
        cur_down_limit=$(get_conf_value "max-overall-download-limit" "0")
        cur_seed_time=$(get_conf_value "seed-time" "0")
        cur_seed_ratio=$(get_conf_value "seed-ratio" "1.0")
        cur_state_dir=$(get_conf_value "state-dir" "${STATE_DIR}")
        cur_listen_port=$(get_conf_value "listen-port" "6881")

        echo ""
        echo "=========================================="
        echo "        Aria2 常用下载与做种核心配置      "
        echo "=========================================="
        echo " 当前参数状态:"
        echo "  1. 默认下载目录:           ${cur_dir}"
        echo "  2. 最大同时下载任务数:     ${cur_concurrent}"
        echo "  3. 全局最大下载限速:       $([ "$cur_down_limit" == "0" ] && echo "不限制" || echo "${cur_down_limit}")"
        echo "  4. 全局最大上传限速:       $([ "$cur_up_limit" == "0" ] && echo "不限制" || echo "${cur_up_limit}")"
        if [ "$cur_seed_ratio" != "0.0" ]; then
            echo "  5. BT 做种策略:            分享率达到 ${cur_seed_ratio} 停止做种"
        elif [ "$cur_seed_time" != "0" ]; then
            echo "  5. BT 做种策略:            做种持续 ${cur_seed_time} 分钟停止"
        else
            echo "  5. BT 做种策略:            下载完成立即停止做种"
        fi
        echo "  6. 断点/恢复状态目录:      ${cur_state_dir}"
        echo "  7. BT 监听端口:            ${cur_listen_port}"
        echo "------------------------------------------"
        echo " 8. 一键快捷配置向导 (交互式快速配置以上所有项)"
        echo " 0. 保存并返回主菜单"
        echo "=========================================="
        read -rp "请选择需要修改的配置项 [0-8 默认: 0]: " SET_OPT
        SET_OPT="${SET_OPT:-0}"

        case "$SET_OPT" in
            1)
                read -rp "请输入新的下载目录绝对路径 [留空取消]: " NEW_DIR
                if [ -n "$NEW_DIR" ]; then
                    NEW_DIR="${NEW_DIR%/}"
                    mkdir -p "${NEW_DIR}"
                    update_conf_kv "dir" "${NEW_DIR}"
                    echo ">> 下载目录已更新为: ${NEW_DIR}"
                fi
                ;;
            2)
                read -rp "请输入最大同时下载任务数 (默认 5) [当前: ${cur_concurrent}]: " NEW_CONCURRENT
                if [ -n "$NEW_CONCURRENT" ] && [[ "$NEW_CONCURRENT" =~ ^[0-9]+$ ]]; then
                    update_conf_kv "max-concurrent-downloads" "${NEW_CONCURRENT}"
                    echo ">> 最大同时下载任务数已更新为: ${NEW_CONCURRENT}"
                fi
                ;;
            3)
                read -rp "请输入全局最大下载限速 (例如 10M, 5M, 0 为不限速) [当前: ${cur_down_limit}]: " NEW_DOWN
                if [ -n "$NEW_DOWN" ]; then
                    update_conf_kv "max-overall-download-limit" "${NEW_DOWN}"
                    update_conf_kv "max-download-limit" "${NEW_DOWN}"
                    echo ">> 下载限速已更新为: ${NEW_DOWN}"
                fi
                ;;
            4)
                read -rp "请输入全局最大上传限速 (例如 2M, 500K, 0 为不限速) [当前: ${cur_up_limit}]: " NEW_UP
                if [ -n "$NEW_UP" ]; then
                    update_conf_kv "max-overall-upload-limit" "${NEW_UP}"
                    update_conf_kv "max-upload-limit" "${NEW_UP}"
                    echo ">> 上传限速已更新为: ${NEW_UP}"
                fi
                ;;
            5)
                echo ""
                echo "请选择 BT 做种模式:"
                echo " 1. 分享率做种 (达到指定倍数后停止 / 默认: 1.0)"
                echo " 2. 时间做种 (到达设定分钟后自动停止)"
                echo " 3. 下载完成立即停止做种 (不浪费上传带宽)"
                read -rp "请选择模式 [1-3 默认: 1]: " SEED_CHOICE
                SEED_CHOICE="${SEED_CHOICE:-1}"
                if [ "$SEED_CHOICE" == "1" ]; then
                    read -rp "请输入分享率阈值 (例如 1.0 或 2.0) [默认: 1.0]: " INPUT_RATIO
                    INPUT_RATIO="${INPUT_RATIO:-1.0}"
                    update_conf_kv "seed-ratio" "${INPUT_RATIO}"
                    update_conf_kv "seed-time" "0"
                    echo ">> 已配置为分享率达到 ${INPUT_RATIO} 后停止。"
                elif [ "$SEED_CHOICE" == "2" ]; then
                    read -rp "请输入做种时间 (单位: 分钟) [默认: 30]: " INPUT_TIME
                    INPUT_TIME="${INPUT_TIME:-30}"
                    update_conf_kv "seed-time" "${INPUT_TIME}"
                    update_conf_kv "seed-ratio" "0.0"
                    echo ">> 已配置为完成做种 ${INPUT_TIME} 分钟后停止。"
                elif [ "$SEED_CHOICE" == "3" ]; then
                    update_conf_kv "seed-time" "0"
                    update_conf_kv "seed-ratio" "0.0"
                    echo ">> 已配置为下载完成后立即停止做种。"
                fi
                ;;
            6)
                read -rp "请输入新的断点/恢复状态目录绝对路径 [留空取消，当前: ${cur_state_dir}]: " NEW_STATE_DIR
                if [ -n "$NEW_STATE_DIR" ]; then
                    NEW_STATE_DIR="${NEW_STATE_DIR%/}"
                    mkdir -p "${NEW_STATE_DIR}"
                    update_conf_kv "state-dir" "${NEW_STATE_DIR}"
                    echo ">> 断点/恢复状态目录已更新为: ${NEW_STATE_DIR}"
                fi
                ;;
            7)
                read -rp "请输入 BT 监听端口 (支持范围如 6881-6999) [留空取消，当前: ${cur_listen_port}]: " NEW_LISTEN
                if [ -n "$NEW_LISTEN" ]; then
                    update_conf_kv "listen-port" "${NEW_LISTEN}"
                    echo ">> BT 监听端口已更新为: ${NEW_LISTEN} (需在防火墙/路由器上放行才能提高连通性)"
                fi
                ;;
            8)
                echo ""
                echo "--- 开始交互式向导配置 ---"
                read -rp "1. 默认下载目录 [当前: ${cur_dir}]: " IN_DIR
                [ -n "$IN_DIR" ] && IN_DIR="${IN_DIR%/}" && mkdir -p "${IN_DIR}" && update_conf_kv "dir" "${IN_DIR}"

                read -rp "2. 同时下载任务数 [当前: ${cur_concurrent}]: " IN_CONCURRENT
                [ -n "$IN_CONCURRENT" ] && update_conf_kv "max-concurrent-downloads" "${IN_CONCURRENT}"

                read -rp "3. 全局最大下载限速 (0为不限速) [当前: ${cur_down_limit}]: " IN_DOWN
                [ -n "$IN_DOWN" ] && update_conf_kv "max-overall-download-limit" "${IN_DOWN}" && update_conf_kv "max-download-limit" "${IN_DOWN}"

                read -rp "4. 全局最大上传限速 (例如 2M, 0为不限速) [当前: ${cur_up_limit}]: " IN_UP
                [ -n "$IN_UP" ] && update_conf_kv "max-overall-upload-limit" "${IN_UP}" && update_conf_kv "max-upload-limit" "${IN_UP}"

                read -rp "5. BT 分享率做种阈值 (默认 1.0, 设为 0 表示不借带宽下载完即停) [当前: ${cur_seed_ratio}]: " IN_RATIO
                IN_RATIO="${IN_RATIO:-1.0}"
                update_conf_kv "seed-ratio" "${IN_RATIO}"
                update_conf_kv "seed-time" "0"

                read -rp "6. 断点/恢复状态目录 [当前: ${cur_state_dir}]: " IN_STATE_DIR
                [ -n "$IN_STATE_DIR" ] && mkdir -p "${IN_STATE_DIR}" && update_conf_kv "state-dir" "${IN_STATE_DIR}"

                read -rp "7. BT 监听端口 [当前: ${cur_listen_port}]: " IN_LISTEN
                [ -n "$IN_LISTEN" ] && update_conf_kv "listen-port" "${IN_LISTEN}"

                echo ">> 向导配置已完整写入！"
                ;;
            0)
                echo ">> 正在重启 Aria2 服务以应用修改..."
                svc_restart
                echo ">> Aria2 服务重启完毕，配置已生效！"
                break
                ;;
            *)
                echo "无效选项，请重新选择。"
                ;;
        esac
    done
}

# ==================== 模块 3: 单独设置/更新 Trackers ====================
update_trackers_menu() {
    echo ""
    echo "=========================================="
    echo "        手动更新 / 设置 BT Trackers       "
    echo "=========================================="

    if [ ! -f "${CONF_FILE}" ]; then
        echo "未检测到配置文件: ${CONF_FILE}，请先安装 Aria2！"
        return 1
    fi

    echo "当前自动拉取模式: $(tracker_mode_text)"
    echo ""
    echo "请选择操作:"
    echo " 1. 立即从网络自动拉取最新 Trackers (双源合并去重，可选 best / all)"
    echo " 2. 手动自定义输入 Trackers 列表"
    echo " 0. 返回上级菜单"
    read -rp "请选择 [0-2 默认: 0]: " TRACKER_CHOICE
    TRACKER_CHOICE="${TRACKER_CHOICE:-0}"

    if [ "$TRACKER_CHOICE" == "0" ]; then
        return 0
    elif [ "$TRACKER_CHOICE" == "1" ]; then
        echo ""
        echo "请选择 Tracker 列表类型 (xiu2 与 ngosang 两个源均使用同一类型):"
        echo " 1. best 精选列表 (体积小、质量高，推荐) [默认]"
        echo " 2. all  全量列表 (数量最多，体积较大)"
        read -rp "请选择 [1-2 默认: 1]: " TRACKER_LIST_CHOICE
        TRACKER_LIST_CHOICE="${TRACKER_LIST_CHOICE:-1}"

        local tracker_mode="best"
        if [ "$TRACKER_LIST_CHOICE" == "2" ]; then
            tracker_mode="all"
        elif [ "$TRACKER_LIST_CHOICE" != "1" ]; then
            echo ">> 无效选项，按默认 best 处理。"
        fi

        ensure_tracker_script "$tracker_mode"
        echo ">> 拉取模式已设为 $(tracker_mode_text)，正在执行 Tracker 更新脚本..."
        bash "${TRACKER_SCRIPT}"
    elif [ "$TRACKER_CHOICE" == "2" ]; then
        echo ""
        echo "请输入或粘贴 Tracker 列表 (可为逗号分隔，也可为多行粘贴，输入完成后在新行输入 EOF 并回车结束):"
        USER_TRACKERS=""
        while IFS= read -r line; do
            [ "$line" = "EOF" ] && break
            USER_TRACKERS="${USER_TRACKERS}${line},"
        done
        
        formatted_trackers=$(echo "${USER_TRACKERS}" | tr -d '\r' | sed 's/#.*//g' | tr '\n' ',' | sed 's/,,*/,/g; s/^,//; s/,$//')

        if [ -z "$formatted_trackers" ]; then
            echo "输入内容为空，未做任何修改。"
            return 0
        fi

        update_conf_kv "bt-tracker" "${formatted_trackers}"

        svc_restart
        echo ">> 自定义 Trackers 已成功写入并重启 Aria2 服务！"
    else
        echo "无效选项。"
        return 1
    fi
}

# ==================== 模块 4: Trackers 自动更新定时器管理 ====================
manage_tracker_timer() {
    echo ""
    echo "=========================================="
    echo "     BT Trackers 自动更新 定时器管理       "
    echo "=========================================="

    IS_ACTIVE=false
    if ${SYSTEMCTL_CMD} is-active --quiet aria2-update-tracker.timer 2>/dev/null; then
        IS_ACTIVE=true
    fi

    echo -n "当前 Trackers 自动更新定时器状态: "
    if [ "$IS_ACTIVE" = true ]; then
        echo -e "\033[32m已启用 (Active)\033[0m"
    else
        echo -e "\033[31m未启用 (Inactive / Stopped)\033[0m"
    fi
    echo "当前自动拉取模式: $(tracker_mode_text)  (如需切换 best / all 请使用主菜单 3)"
    echo "当前更新周期: $(tracker_interval_text "$(current_tracker_interval)")"
    echo ""

    echo " 1. 启用并开启开机自启 (Enable & Start)"
    echo " 2. 停用并关闭开机自启 (Disable & Stop)"
    echo " 3. 查看定时器运行与下次触发时间"
    echo " 4. 设置自动更新周期 (默认每周，支持自定义)"
    echo " 0. 返回上级菜单"
    read -rp "请选择操作 [0-4 默认: 0]: " TIMER_CHOICE
    TIMER_CHOICE="${TIMER_CHOICE:-0}"

    case "$TIMER_CHOICE" in
        1)
            # 不带参数调用: 沿用当前 best/all 选择(尚无脚本时默认 best)，不会静默改回 best
            ensure_tracker_script
            # 同样沿用已保存的更新周期(从未设置过则为默认每周)
            write_tracker_timer_units

            ${SYSTEMCTL_CMD} daemon-reload
            ${SYSTEMCTL_CMD} enable --now aria2-update-tracker.timer
            echo ">> Trackers 自动更新定时器已成功启用！"
            echo ">> 当前周期: $(tracker_interval_text "$(current_tracker_interval)")"
            ;;
        2)
            echo ">> 正在停止并禁用 Trackers 定时器..."
            ${SYSTEMCTL_CMD} stop aria2-update-tracker.timer 2>/dev/null || true
            ${SYSTEMCTL_CMD} disable aria2-update-tracker.timer 2>/dev/null || true
            echo ">> Trackers 自动更新定时器已停用。"
            ;;
        3)
            echo ""
            ${SYSTEMCTL_CMD} list-timers aria2-update-tracker.timer || true
            ;;
        4)
            echo ""
            echo "请选择 Trackers 自动更新周期:"
            echo " 1. 每 12 小时 (12h)"
            echo " 2. 每天 (24h)"
            echo " 3. 每 3 天 (72h)"
            echo " 4. 每周 (1w) [默认]"
            echo " 5. 每两周 (2w)"
            echo " 6. 自定义周期 (systemd 时间格式)"
            echo " 0. 取消"
            read -rp "请选择 [0-6 默认: 4]: " TIMER_INTERVAL_CHOICE
            TIMER_INTERVAL_CHOICE="${TIMER_INTERVAL_CHOICE:-4}"

            local new_interval="" custom_interval=""
            case "$TIMER_INTERVAL_CHOICE" in
                1) new_interval="12h" ;;
                2) new_interval="24h" ;;
                3) new_interval="72h" ;;
                4) new_interval="1w" ;;
                5) new_interval="2w" ;;
                6)
                    while true; do
                        read -rp "请输入自定义周期 (数字+单位，如 6h / 8h / 3d / 2w；直接回车取消): " custom_interval
                        custom_interval=$(printf '%s' "$custom_interval" | tr -d ' \r' | tr 'A-Z' 'a-z')
                        if [ -z "$custom_interval" ]; then
                            echo ">> 已取消，更新周期未修改。"
                            return 0
                        fi
                        if [[ ! "$custom_interval" =~ ^[0-9]+(s|min|h|d|w|m)$ ]]; then
                            echo ">> 格式不正确，请使用 <数字><单位>；单位可为 s / min / h / d / w / m。"
                            continue
                        fi
                        if [[ "$custom_interval" =~ ^0+(s|min|h|d|w|m)$ ]]; then
                            echo ">> 周期必须大于 0，请重新输入。"
                            continue
                        fi
                        new_interval="$custom_interval"
                        break
                    done
                    ;;
                0) echo ">> 已取消，更新周期未修改。"; return 0 ;;
                *) echo ">> 无效选项，更新周期未修改。"; return 1 ;;
            esac

            write_tracker_timer_units "$new_interval"
            ${SYSTEMCTL_CMD} daemon-reload 2>/dev/null || true
            if [ "$IS_ACTIVE" = true ]; then
                ${SYSTEMCTL_CMD} restart aria2-update-tracker.timer 2>/dev/null || true
                echo ">> 更新周期已设为 $(tracker_interval_text "$new_interval")，定时器已重启生效。"
            else
                echo ">> 更新周期已设为 $(tracker_interval_text "$new_interval")。"
                echo "   提示: 定时器当前未启用，可先用选项 1 启用后生效。"
            fi
            ;;
        0)
            return 0
            ;;
        *)
            echo "无效选项。"
            ;;
    esac
}

# ==================== 模块 5: 内核级吸血 Peer 拦截管理 (ipset + iptables) ====================
manage_peer_blocker() {
    echo ""
    echo "=========================================="
    echo "    BT 吸血 Peer 防火墙拦截 (ipset + iptables)  "
    echo "=========================================="

    IS_BLOCKER_ACTIVE=false
    if systemctl is-active --quiet aria2-peer-blocker.timer 2>/dev/null; then
        IS_BLOCKER_ACTIVE=true
    fi

    echo -n "当前吸血 Peer 防火墙状态: "
    if [ "$IS_BLOCKER_ACTIVE" = true ]; then
        echo -e "\033[32m已开启 (每日定时更新拦截库)\033[0m"
    else
        echo -e "\033[31m未开启 (Inactive)\033[0m"
    fi
    echo ""

    echo " 1. 开启防火墙拦截 (安装依赖、立即载入黑名单并启用每日定时更新)"
    echo " 2. 关闭防火墙拦截 (清除 iptables 拦截规则、清空 ipset 集合并停用更新)"
    echo " 3. 立即手动执行一次更新"
    echo " 4. 查看当前拦截规则与定时任务状态"
    echo " 0. 返回上级菜单"
    read -rp "请选择操作 [0-4 默认: 0]: " PEER_CHOICE
    PEER_CHOICE="${PEER_CHOICE:-0}"

    case "$PEER_CHOICE" in
        1)
            install_packages ipset iptables
            ensure_blocker_script

            echo ">> 正在配置系统级每日定时更新服务..."
            ${SUDO_CMD} bash -c "cat > /etc/systemd/system/aria2-peer-blocker.service" <<EOF
[Unit]
Description=Update Aria2 Peer Blacklist to Linux Firewall (ipset)
After=network.target

[Service]
Type=oneshot
ExecStart=${BLOCKER_SCRIPT}
EOF

            ${SUDO_CMD} bash -c "cat > /etc/systemd/system/aria2-peer-blocker.timer" <<EOF
[Unit]
Description=Daily update of Aria2 Peer Blacklist

[Timer]
OnBootSec=15min
OnUnitActiveSec=24h
Persistent=true

[Install]
WantedBy=timers.target
EOF

            ${SUDO_CMD} systemctl daemon-reload
            ${SUDO_CMD} systemctl enable --now aria2-peer-blocker.timer

            echo ">> 正在首次拉取并挂载吸血 Peer 黑名单到内核防火墙..."
            bash "${BLOCKER_SCRIPT}"
            echo ""
            echo ">> 吸血 Peer 防火墙已正式开启！系统将每天自动拉取最新封禁 IP。"
            ;;
        2)
            echo ">> 正在停止并禁用每日定时器..."
            ${SUDO_CMD} systemctl stop aria2-peer-blocker.timer 2>/dev/null || true
            ${SUDO_CMD} systemctl disable aria2-peer-blocker.timer 2>/dev/null || true
            ${SUDO_CMD} rm -f /etc/systemd/system/aria2-peer-blocker.service
            ${SUDO_CMD} rm -f /etc/systemd/system/aria2-peer-blocker.timer
            ${SUDO_CMD} systemctl daemon-reload

            echo ">> 正在清理 iptables 拦截链与 ipset 集合..."
            ${SUDO_CMD} iptables -D INPUT -m set --match-set aria2_ban_v4 src -j DROP 2>/dev/null || true
            if command -v ip6tables &>/dev/null; then
                ${SUDO_CMD} ip6tables -D INPUT -m set --match-set aria2_ban_v6 src -j DROP 2>/dev/null || true
            fi
            ${SUDO_CMD} ipset destroy aria2_ban_v4 2>/dev/null || true
            ${SUDO_CMD} ipset destroy aria2_ban_v6 2>/dev/null || true

            echo ">> 吸血 Peer 防火墙拦截已彻底关闭并恢复环境。"
            ;;
        3)
            ensure_blocker_script
            echo ">> 正在执行手动更新..."
            bash "${BLOCKER_SCRIPT}"
            ;;
        4)
            local _pb_tmp=""
            _pb_tmp=$(mktemp -d)

            { ${SUDO_CMD} iptables -L INPUT -n -v 2>/dev/null | grep "aria2_ban" || echo "未找到 IPv4 拦截规则"; } > "${_pb_tmp}/ipt4.txt" 2>&1
            preview_file_paged "iptables 拦截规则 (IPv4)" "${_pb_tmp}/ipt4.txt" 20
            if command -v ip6tables >/dev/null 2>&1; then
                { ${SUDO_CMD} ip6tables -L INPUT -n -v 2>/dev/null | grep "aria2_ban" || echo "未找到 IPv6 拦截规则"; } > "${_pb_tmp}/ipt6.txt" 2>&1
                preview_file_paged "iptables 拦截规则 (IPv6)" "${_pb_tmp}/ipt6.txt" 20
            fi

            echo ""
            echo "=== ipset 集合概况 ==="
            ${SUDO_CMD} ipset list aria2_ban_v4 -terse 2>/dev/null || echo "aria2_ban_v4 集合不存在"
            ${SUDO_CMD} ipset list aria2_ban_v6 -terse 2>/dev/null || echo "aria2_ban_v6 集合不存在"

            # 完整黑名单可能上万条，改为分页查看 (随时可输入 q 退出)
            local _pb_view=""
            if ${SUDO_CMD} ipset list aria2_ban_v4 >/dev/null 2>&1; then
                read -rp "是否分页查看完整 IPv4 黑名单? [y/N 默认: N]: " _pb_view || true
                if [[ "${_pb_view:-N}" =~ ^[Yy]$ ]]; then
                    ${SUDO_CMD} ipset list aria2_ban_v4 2>/dev/null > "${_pb_tmp}/ban4.txt"
                    preview_file_paged "IPv4 黑名单 (完整)" "${_pb_tmp}/ban4.txt" 20
                fi
            fi
            _pb_view=""
            if ${SUDO_CMD} ipset list aria2_ban_v6 >/dev/null 2>&1; then
                read -rp "是否分页查看完整 IPv6 黑名单? [y/N 默认: N]: " _pb_view || true
                if [[ "${_pb_view:-N}" =~ ^[Yy]$ ]]; then
                    ${SUDO_CMD} ipset list aria2_ban_v6 2>/dev/null > "${_pb_tmp}/ban6.txt"
                    preview_file_paged "IPv6 黑名单 (完整)" "${_pb_tmp}/ban6.txt" 20
                fi
            fi

            echo ""
            { systemctl list-timers aria2-peer-blocker.timer 2>&1 || true; } > "${_pb_tmp}/timer.txt"
            preview_file_paged "定时器运行状态" "${_pb_tmp}/timer.txt" 20
            rm -rf "${_pb_tmp}"
            ;;
        0)
            return 0
            ;;
        *)
            echo "无效选项。"
            ;;
    esac
}

# ==================== 模块 6: 迁移未完成下载任务到新磁盘 ====================
migrate_downloads() {
    echo ""
    echo "=========================================="
    echo "       迁移 Aria2 下载任务到新磁盘        "
    echo "=========================================="

    if [ ! -f "${CONF_FILE}" ]; then
        echo "错误: 未找到配置文件 ${CONF_FILE}，请确认 Aria2 是否已安装。"
        return 1
    fi

    echo "请先选择迁移范围:"
    echo " 1. 仅迁移未完成的下载任务 (按 Aria2 RPC 清单识别数据，并带上种子元数据)"
    echo " 2. 迁移整个下载目录的所有数据 (包含已完成与未完成，自动识别元数据)"
    echo " 3. 仅迁移指定文件/任务 (按关键词匹配，自动识别元数据)"
    echo " 0. 返回上级菜单"
    read -rp "请选择 [0-3 默认: 0]: " MIGRATE_TYPE
    MIGRATE_TYPE="${MIGRATE_TYPE:-0}"

    if [ "$MIGRATE_TYPE" == "0" ]; then
        return 0
    fi

    if [[ ! "$MIGRATE_TYPE" =~ ^[123]$ ]]; then
        echo "无效选项，已取消迁移。"
        return 1
    fi

    install_packages findutils python3
    check_cmds find || return 1
    ensure_rsync || return 1

    FILE_KEYWORD=""
    if [ "$MIGRATE_TYPE" == "3" ]; then
        read -rp "请输入要迁移的文件名关键字 (例如: debian.iso): " FILE_KEYWORD
        if [ -z "$FILE_KEYWORD" ]; then
            echo "关键字不能为空，已取消迁移。"
            return 1
        fi
    fi

    CURRENT_DIR=$(get_current_download_dir)
    echo ""
    echo "当前默认下载目录为: ${CURRENT_DIR}"
    read -rp "请输入源下载目录 [默认: ${CURRENT_DIR}]: " SRC_DIR
    SRC_DIR="${SRC_DIR:-$CURRENT_DIR}"
    SRC_DIR="${SRC_DIR%/}"

    if [ ! -d "${SRC_DIR}" ]; then
        echo "错误: 源目录 ${SRC_DIR} 不存在！"
        return 1
    fi

    while true; do
        read -rp "请输入目标新磁盘目录绝对路径 (例如: /mnt/disk2/Downloads): " DEST_DIR || { echo ""; echo ">> 输入已结束，已取消迁移。"; return 1; }
        DEST_DIR="${DEST_DIR%/}"
        if [ -z "$DEST_DIR" ]; then
            echo "目标路径不能为空，请重新输入！"
            continue
        fi
        if check_transfer_dest "${SRC_DIR}" "${DEST_DIR}"; then
            break
        fi
        echo "请重新输入目标路径。"
    done

    # ---- 未完成任务清单必须在 Aria2 运行期间查询；且先让用户确认后再停服搬运 ----
    local pending_tmp="" pending_file=""
    local SRC_REAL=""
    SRC_REAL="$(realpath "${SRC_DIR}" 2>/dev/null || true)"
    [ -n "$SRC_REAL" ] || SRC_REAL="${SRC_DIR}"
    declare -a PENDING_PATHS=()
    if [ "$MIGRATE_TYPE" == "1" ]; then
        echo ">> 正在通过 RPC 检索未完成 (进行中 / 等待 / 暂停 / 未完成已停止) 任务的数据..."
        # aria2-next 不再生成 .aria2 控制文件，未完成任务只能以 RPC 任务清单为准
        local scan_rc=0
        pending_tmp=$(mktemp -d)
        pending_file="${pending_tmp}/paths.list"
        rpc_unfinished_paths_to "${pending_file}" || scan_rc=$?
        if [ "$scan_rc" -ne 0 ]; then
            echo ""
            echo ">> [失败] 未能从 Aria2 获取未完成任务清单，未做任何迁移。"
            echo "   ---- 连接诊断 ----"
            rpc_diagnose || true
            rm -rf "${pending_tmp}"
            return 1
        fi

        if [ -s "${pending_file}" ]; then
            mapfile -d '' -t PENDING_PATHS < "${pending_file}" 2>/dev/null || PENDING_PATHS=()
        fi
        rm -rf "${pending_tmp}"
        pending_tmp=""

        if [ ${#PENDING_PATHS[@]} -eq 0 ]; then
            echo ""
            echo ">> 未检索到可迁移的未完成任务数据文件。"
            echo "   说明: 未完成但磁盘上尚无数据(例如刚添加、还没开始下载)的任务无需迁移；"
            echo "         aria2-next 的断点/恢复数据存于 ${STATE_DIR}，不随下载目录迁移。"
            echo "   若上方诊断显示任务数与实际不符，请先用主菜单 9 -> 3 做健康诊断。"
            return 0
        fi

        # 待处理清单确认 (此时服务仍在运行，取消后无任何副作用)
        local _disp=""
        declare -a PENDING_DISPLAY=()
        for _disp in "${PENDING_PATHS[@]}"; do
            case "$_disp" in
                "${SRC_DIR}"/*) _disp="${_disp#"${SRC_DIR}/"}" ;;
            esac
            case "$_disp" in
                "${SRC_REAL}"/*) _disp="${_disp#"${SRC_REAL}/"}" ;;
            esac
            PENDING_DISPLAY+=("$_disp")
        done
        if ! confirm_paged_list PENDING_PATHS "待迁移的未完成任务数据文件" 15 PENDING_DISPLAY; then
            echo ">> 已取消迁移 (Aria2 服务未受影响)。"
            return 0
        fi
    fi

    stop_aria2_safely

    mkdir -p "${DEST_DIR}"
    if [ "$IS_ROOT" = false ]; then
        ${SUDO_CMD} chown -R "${CURRENT_USER}:${CURRENT_USER}" "${DEST_DIR}" 2>/dev/null || true
    fi
    chmod 755 "${DEST_DIR}" 2>/dev/null || true

    declare -a MIGRATED_FILES=()
    local MIGRATE_OK=0 MIGRATE_FAIL=0

    case "$MIGRATE_TYPE" in
        1)
            local _pp="" _rel="" _dest_subdir="" _ok=0 _fail=0

            echo ""
            echo ">> 发现 ${#PENDING_PATHS[@]} 个未完成任务数据文件，开始断点同步..."
            for _pp in "${PENDING_PATHS[@]}"; do
                case "$_pp" in
                    "${SRC_REAL}"/*) _rel="${_pp#"${SRC_REAL}/"}" ;;
                    "${SRC_DIR}"/*) _rel="${_pp#"${SRC_DIR}/"}" ;;
                    *) echo "   - 跳过 (不在源目录内): ${_pp}"; continue ;;
                esac
                _dest_subdir=$(dirname "${DEST_DIR}/${_rel}")
                mkdir -p "${_dest_subdir}"

                if copy_path "${_pp}" "${_dest_subdir}" && [ -e "${_dest_subdir}/$(basename "${_pp}")" ]; then
                    MIGRATED_FILES+=("${_pp}")
                    _ok=$((_ok + 1))
                else
                    echo "   !! [失败] 同步未确认: ${_pp}"
                    _fail=$((_fail + 1))
                fi

                if [ -f "${_pp}.torrent" ]; then
                    if copy_path "${_pp}.torrent" "${_dest_subdir}" && [ -e "${_dest_subdir}/$(basename "${_pp}").torrent" ]; then
                        MIGRATED_FILES+=("${_pp}.torrent")
                    fi
                fi
            done
            echo ">> 数据同步结果: 成功 ${_ok} 个 / 失败 ${_fail} 个"
            MIGRATE_OK=$_ok
            MIGRATE_FAIL=$_fail
            if [ "$_fail" -gt 0 ]; then
                echo "   提示: 失败项未被计入清理清单，源文件会保留在 ${SRC_DIR}。"
            fi

            while IFS= read -r tor; do
                if [ -f "$tor" ]; then
                    copy_path "$tor" "${DEST_DIR}" && MIGRATED_FILES+=("$tor")
                fi
            done < <(find "${SRC_DIR}" -maxdepth 1 -name "*.torrent")

            ;;

        2)
            declare -a TOP_ITEMS=()
            local _t=""
            while IFS= read -r _t; do
                [ -n "$_t" ] && TOP_ITEMS+=("$_t")
            done < <(find "${SRC_DIR}" -mindepth 1 -maxdepth 1)

            if [ ${#TOP_ITEMS[@]} -eq 0 ]; then
                echo ">> 源目录下没有任何内容，无需迁移。"
                svc_start
                return 0
            fi

            declare -a TOP_DISPLAY=()
            for _t in "${TOP_ITEMS[@]}"; do
                TOP_DISPLAY+=("$(basename "$_t")")
            done
            if ! confirm_paged_list TOP_ITEMS "将完整同步以下顶层条目(含其全部内容)到 ${DEST_DIR}" 15 TOP_DISPLAY; then
                echo ">> 已取消迁移，Aria2 服务已恢复。"
                svc_start
                return 0
            fi

            echo ">> 正在完整断点同步下载目录下全部数据..."
            copy_tree_contents "${SRC_DIR}" "${DEST_DIR}" || {
                echo ">> [失败] 目录同步未成功，已中止后续的路径切换与清理 (源数据保持原样)。"
                svc_start
                return 1
            }
            while IFS= read -r item; do
                [ -e "$item" ] && MIGRATED_FILES+=("$item")
            done < <(find "${SRC_DIR}" -mindepth 1 -maxdepth 1)
            ;;

        3)
            declare -a MATCH_ITEMS=()
            local _f=""
            while IFS= read -r _f; do
                [ -n "$_f" ] && MATCH_ITEMS+=("$_f")
            done < <(find "${SRC_DIR}" -name "*${FILE_KEYWORD}*" ! -name "*.aria2" ! -name "*.torrent")
            while IFS= read -r _f; do
                [ -n "$_f" ] && MATCH_ITEMS+=("$_f")
            done < <(find "${SRC_DIR}" -maxdepth 1 -name "*${FILE_KEYWORD}*.torrent")

            if [ ${#MATCH_ITEMS[@]} -eq 0 ]; then
                echo "未匹配到任何包含关键字 [${FILE_KEYWORD}] 的文件。"
                svc_start
                return 0
            fi

            declare -a MATCH_DISPLAY=()
            for _f in "${MATCH_ITEMS[@]}"; do
                MATCH_DISPLAY+=("${_f#"${SRC_DIR}/"}")
            done
            if ! confirm_paged_list MATCH_ITEMS "关键字 [${FILE_KEYWORD}] 匹配到的文件" 15 MATCH_DISPLAY; then
                echo ">> 已取消迁移，Aria2 服务已恢复。"
                svc_start
                return 0
            fi

            echo ">> 正在根据关键字 [${FILE_KEYWORD}] 断点同步..."
            local _rel3="" _sub3="" _ok3=0 _fail3=0
            for _f in "${MATCH_ITEMS[@]}"; do
                _rel3="${_f#"${SRC_DIR}/"}"
                _sub3=$(dirname "${DEST_DIR}/${_rel3}")
                mkdir -p "${_sub3}"

                if copy_path "${_f}" "${_sub3}" && [ -e "${_sub3}/$(basename "${_f}")" ]; then
                    MIGRATED_FILES+=("${_f}")
                    _ok3=$((_ok3 + 1))
                else
                    echo "   !! [失败] 同步未确认: ${_f}"
                    _fail3=$((_fail3 + 1))
                fi

                if [ -f "${_f}.torrent" ]; then
                    copy_path "${_f}.torrent" "${_sub3}" && MIGRATED_FILES+=("${_f}.torrent")
                fi
            done
            echo ">> 数据同步结果: 成功 ${_ok3} 个 / 失败 ${_fail3} 个"
            MIGRATE_OK=$_ok3
            MIGRATE_FAIL=$_fail3
            ;;
    esac

    # 全部失败时不要在“没搬成数据”的前提下改写路径/清理，否则会把任务指到空目录
    if [ "$MIGRATE_TYPE" != "2" ] && [ "$MIGRATE_FAIL" -gt 0 ] && [ "$MIGRATE_OK" -eq 0 ]; then
        echo ""
        echo ">> [中止] 没有任何文件同步成功，已放弃后续的路径切换与清理 (源数据保持原样)。"
        svc_start
        return 1
    fi

    if [ -f "${SESSION_FILE}" ] && [ -s "${SESSION_FILE}" ]; then
        echo ">> 正在更新会话文件 (${SESSION_FILE}) 中的路径映射..."
        cp "${SESSION_FILE}" "${SESSION_FILE}.bak"
        replace_literal_in_file "${SESSION_FILE}" "${SRC_DIR}" "${DEST_DIR}"
    fi

    echo ""
    read -rp "是否将未来默认下载目录也同步修改为新路径? [Y/n 默认: Y]: " SYNC_DEFAULT
    SYNC_DEFAULT="${SYNC_DEFAULT:-Y}"
    if [[ "$SYNC_DEFAULT" =~ ^[Yy]$ ]]; then
        update_conf_kv "dir" "${DEST_DIR}"
        echo ">> 已更新 aria2.conf 默认下载目录为: ${DEST_DIR}"
    fi

    echo ">> 正在启动 Aria2 服务恢复下载..."
    svc_start

    echo ""
    echo ">> 迁移完成！Aria2 已重新载入元数据并开始自检校验断点。"
    echo ""

    if [ "$MIGRATE_TYPE" == "1" ] || [ "$MIGRATE_TYPE" == "3" ]; then
        read -rp "是否删除源磁盘上对应的旧数据 (含数据与关联种子) 以释放空间? [Y/n 默认: Y]: " CLEAN_OLD
        CLEAN_OLD="${CLEAN_OLD:-Y}"
    else
        read -rp "是否清空源下载目录的所有文件以释放空间? [y/N 默认: N]: " CLEAN_OLD
        CLEAN_OLD="${CLEAN_OLD:-N}"
    fi

    if [[ "$CLEAN_OLD" =~ ^[Yy]$ ]]; then
        if [ "$MIGRATE_TYPE" == "2" ]; then
            read -rp "警告: 即将清空目录 ${SRC_DIR} 下的所有文件，确认继续? [y/N 默认: N]: " CONFIRM_CLEAN
            CONFIRM_CLEAN="${CONFIRM_CLEAN:-N}"
            if [[ "$CONFIRM_CLEAN" =~ ^[Yy]$ ]]; then
                rm -rf "${SRC_DIR:?}"/*
                echo ">> 原磁盘目录内容已完全清空。"
            fi
        else
            echo ">> 正在清理已迁移的原文件及关联种子文件..."
            eval "UNIQUE_FILES=($(printf "%q\n" "${MIGRATED_FILES[@]}" | sort -u))"
            for f in "${UNIQUE_FILES[@]}"; do
                if [ -e "$f" ]; then
                    rm -rf "$f"
                fi
            done
            echo ">> 原磁盘相关数据已彻底清理完毕。"
        fi
    else
        echo ">> 已保留原磁盘上的文件。"
    fi
}

# ==================== 模块 7: 转移已完成下载 / 游离文件到新磁盘 (释放下载空间) ====================
archive_completed_files() {
    echo ""
    echo "=========================================="
    echo "   转移下载数据到新磁盘 (释放下载空间)    "
    echo "=========================================="

    if [ ! -f "${CONF_FILE}" ]; then
        echo "错误: 未找到配置文件 ${CONF_FILE}，请确认 Aria2 是否已安装。"
        return 1
    fi

    install_packages findutils python3 curl
    check_cmds find python3 || return 1
    ensure_rsync || return 1

    if ! svc_is_active; then
        echo ">> 检测到 Aria2 服务未运行，正在启动以调取任务状态..."
        svc_start
        sleep 1
    fi

    local CURRENT_DIR SRC_DIR DEST_DIR ARCHIVE_MODE
    CURRENT_DIR=$(get_current_download_dir)
    read -rp "请输入源下载目录绝对路径 [默认: ${CURRENT_DIR}]: " SRC_DIR
    SRC_DIR="${SRC_DIR:-$CURRENT_DIR}"
    SRC_DIR="${SRC_DIR%/}"

    if [ ! -d "${SRC_DIR}" ]; then
        echo "错误: 源下载目录 ${SRC_DIR} 不存在！"
        return 1
    fi

    while true; do
        read -rp "请输入转移存放的目标新磁盘目录 (绝对路径，例如 /mnt/disk2/Downloads): " DEST_DIR || { echo ""; echo ">> 输入已结束，已取消操作。"; return 1; }
        DEST_DIR="${DEST_DIR%/}"
        if [ -z "$DEST_DIR" ]; then
            echo "目标目录不能为空，请重新输入！"
            continue
        fi
        if check_transfer_dest "${SRC_DIR}" "${DEST_DIR}"; then
            break
        fi
        echo "请重新输入目标目录。"
    done

    if [ "$IS_ROOT" = false ]; then
        ${SUDO_CMD} chown -R "${CURRENT_USER}:${CURRENT_USER}" "${DEST_DIR}" 2>/dev/null || true
    fi
    chmod 755 "${DEST_DIR}" 2>/dev/null || true

    echo ""
    echo ">> 请选择要转移的内容:"
    echo "   1. 仅转移 Aria2 已完成的任务 (含做种 / 已暂停，原有功能)"
    echo "   2. 仅转移游离文件/目录 (不被任何 Aria2 任务管理，如已清除记录或手动放入)"
    echo "   3. 两者依次处理 (先转移已完成任务，再转移游离文件)"
    read -rp "请输入模式编号 [1-3 默认: 1]: " ARCHIVE_MODE
    ARCHIVE_MODE="${ARCHIVE_MODE:-1}"
    if [[ ! "$ARCHIVE_MODE" =~ ^[123]$ ]]; then
        echo ">> 无效模式，已取消。"
        return 0
    fi

    if [ "$ARCHIVE_MODE" != "2" ]; then
        _transfer_completed_tasks "$SRC_DIR" "$DEST_DIR"
    fi
    if [ "$ARCHIVE_MODE" != "1" ]; then
        _transfer_orphan_files "$SRC_DIR" "$DEST_DIR"
    fi
}

# ==================== 模块 7-1: 转移 Aria2 已完成的任务数据 ====================
_transfer_completed_tasks() {
    local SRC_DIR="$1"
    local DEST_DIR="$2"

    echo ""
    echo "---- [已完成任务] 源: ${SRC_DIR}  -->  目标: ${DEST_DIR} ----"
    echo ">> 正在向 Aria2 RPC 查询已完成 (含做种 / 已暂停) 的任务清单..."
    local running_aria2
    running_aria2=$(ps -ef 2>/dev/null | grep '[a]ria2c' | head -n 1 || true)

    local scan_tmp files_file records_file scan_rc
    scan_tmp=$(mktemp -d)
    files_file="${scan_tmp}/files.list"
    records_file="${scan_tmp}/tasks.rec"

    # 通过 RPC 批量处理 GID：aria2.forceRemove (解除占用) / aria2.removeDownloadResult (清除记录)
    _aria2_gid_action() {
        local gids_file="$1"
        local method="$2"
        local label="$3"
        [ -s "${gids_file}" ] || return 0
        ARIA2_CONF_FILE="${CONF_FILE}" ARIA2_GIDS_FILE="${gids_file}" ARIA2_GID_METHOD="${method}" ARIA2_GID_LABEL="${label}" \
            python3 - <<'PYEOF' || true
import json
import os
import subprocess
import urllib.request


def read_conf(key, default):
    try:
        with open(os.environ.get("ARIA2_CONF_FILE", ""), "r", encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key_name, value = line.split("=", 1)
                if key_name.strip() == key:
                    return value.strip()
    except OSError:
        pass
    return default


port = read_conf("rpc-listen-port", "6800") or "6800"
secret = read_conf("rpc-secret", "")
url = "http://127.0.0.1:" + port + "/jsonrpc"
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
method = os.environ.get("ARIA2_GID_METHOD") or "aria2.forceRemove"
label = os.environ.get("ARIA2_GID_LABEL") or "处理"

with open(os.environ["ARIA2_GIDS_FILE"], "rb") as fh:
    gids = [item.decode("utf-8", "surrogateescape") for item in fh.read().split(b"\x00") if item]


def call(body):
    """先 urllib，失败再 curl；返回 (响应, 错误描述)。"""
    first_error = ""
    try:
        req = urllib.request.Request(url, data=body.encode("utf-8"), headers={"Content-Type": "application/json"})
        with opener.open(req, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8", "replace")), None
    except Exception as exc:
        first_error = str(exc)
    try:
        proc = subprocess.run(["curl", "-sS", "-m", "10", "--noproxy", "*", "-X", "POST",
                               "-H", "Content-Type: application/json", "--data-binary", "@-", url],
                              input=body.encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=20)
        if proc.returncode != 0:
            return None, f"{first_error}; curl 退出码 {proc.returncode}"
        return json.loads(proc.stdout.decode("utf-8", "replace")), None
    except Exception as exc2:
        return None, f"{first_error}; curl: {exc2}"


results = []
success = 0
for gid in gids:
    params = ["token:" + secret] if secret else []
    params.append(gid)
    body = json.dumps({"jsonrpc": "2.0", "id": "gid_action", "method": method, "params": params})
    data, err = call(body)
    if err:
        results.append(f"   !! GID {gid} {label}失败: {err}")
        continue
    if isinstance(data, dict) and data.get("error"):
        info = data["error"] if isinstance(data["error"], dict) else {}
        results.append(f"   !! GID {gid} {label}失败: {info.get('message', '')}")
        continue
    success += 1

for line in results:
    print(line)
print(f">> {label}: 成功 {success} / {len(gids)} 个任务。")
PYEOF
        return 0
    }

    scan_rc=0
    ARIA2_CONF_FILE="${CONF_FILE}" ARIA2_SRC_DIR="${SRC_DIR}" ARIA2_OUT_DIR="${scan_tmp}" \
        python3 - <<'PYEOF' || scan_rc=$?
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

CONF_FILE = os.environ.get("ARIA2_CONF_FILE", "")
SRC_DIR = os.path.realpath(os.environ.get("ARIA2_SRC_DIR", "."))
OUT_DIR = os.environ.get("ARIA2_OUT_DIR", ".")
RPC_TIMEOUT = 20
FILE_PREVIEW_LIMIT = 15
FIELD_SEP = "\x1f"
STATUS_TEXT = {
    "active": "下载中/做种",
    "waiting": "排队中",
    "paused": "已暂停",
    "complete": "已完成",
    "error": "出错",
    "removed": "已移除",
}


def read_conf(key, default):
    """直接读取 aria2.conf，避免 shell 侧 cut 截断含等号的密钥。"""
    try:
        with open(CONF_FILE, "r", encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key_name, value = line.split("=", 1)
                if key_name.strip() == key:
                    return value.strip()
    except OSError:
        pass
    return default


def num(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def human(size):
    units = ["B", "KB", "MB", "GB", "TB"]
    value = float(size)
    for unit in units:
        if value < 1024 or unit == units[-1]:
            return f"{value:.1f} {unit}"
        value = value / 1024
    return f"{value:.1f} TB"


RPC_PORT = read_conf("rpc-listen-port", "6800") or "6800"
RPC_SECRET = read_conf("rpc-secret", "")
RPC_URL = "http://127.0.0.1:" + RPC_PORT + "/jsonrpc"
# 显式使用空代理，防止本地 127.0.0.1 请求被系统 http_proxy 劫持
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
TRANSPORT = ["urllib"]
NOTES = []


def build_body(method, params=None):
    call_params = ["token:" + RPC_SECRET] if RPC_SECRET else []
    if params:
        call_params.extend(params)
    return json.dumps({"jsonrpc": "2.0", "id": "archive_scan", "method": method, "params": call_params})


def call_urllib(body):
    req = urllib.request.Request(RPC_URL, data=body.encode("utf-8"), headers={"Content-Type": "application/json"})
    try:
        with OPENER.open(req, timeout=RPC_TIMEOUT) as resp:
            return resp.read().decode("utf-8", "replace"), None
    except urllib.error.HTTPError as exc:
        return None, f"HTTP {exc.code}"
    except urllib.error.URLError as exc:
        return None, f"无法连接 127.0.0.1:{RPC_PORT} ({getattr(exc, 'reason', exc)})"
    except Exception as exc:
        return None, f"{type(exc).__name__}: {exc}"


def call_curl(body):
    """curl 直连 RPC：绕过 urllib 可能遇到的代理 / SSL / 环境差异问题。"""
    try:
        proc = subprocess.run(["curl", "-sS", "-m", str(RPC_TIMEOUT), "--noproxy", "*", "-X", "POST",
                               "-H", "Content-Type: application/json", "--data-binary", "@-", RPC_URL],
                              input=body.encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=RPC_TIMEOUT + 10)
    except FileNotFoundError:
        return None, "未找到 curl 命令"
    except Exception as exc:
        return None, f"curl 执行异常: {exc}"
    if proc.returncode != 0:
        return None, f"curl 退出码 {proc.returncode} ({proc.stderr.decode('utf-8', 'replace').strip()})"
    return proc.stdout.decode("utf-8", "replace"), None


def parse_response(raw):
    try:
        data = json.loads(raw)
    except Exception:
        return None, f"响应不是合法 JSON: {raw[:200]}"
    if not isinstance(data, dict):
        return None, "响应格式异常"
    if data.get("error"):
        err = data["error"] if isinstance(data["error"], dict) else {}
        return None, f"RPC 拒绝请求 [{err.get('code', '?')}] {err.get('message', '')}"
    return data.get("result"), None


def rpc(method, params=None):
    """返回 (结果, 错误描述)；urllib 失败时自动回退 curl，绝不静默吞掉错误。"""
    body = build_body(method, params)
    if TRANSPORT[0] == "curl":
        raw, err = call_curl(body)
        if err is None:
            return parse_response(raw)
        return None, err
    raw, err = call_urllib(body)
    if err is None:
        return parse_response(raw)
    raw2, err2 = call_curl(body)
    if err2 is None:
        TRANSPORT[0] = "curl"
        NOTES.append(f"urllib 直连失败 ({err})，已自动改用 curl 与 RPC 通信")
        return parse_response(raw2)
    return None, f"{err}；curl 回退亦失败: {err2}"


def files_of(task):
    files = task.get("files")
    return files if isinstance(files, list) else []


def torrent_name(task):
    info = task.get("bittorrent")
    if isinstance(info, dict):
        inner = info.get("info")
        if isinstance(inner, dict) and inner.get("name"):
            return inner["name"]
    return ""


def task_name(task):
    name = torrent_name(task)
    if name:
        return name
    for f in files_of(task):
        path = f.get("path") or ""
        if path:
            return os.path.basename(path)
    return task.get("gid") or "未知任务"


def task_progress(task):
    total = 0
    done = 0
    for f in files_of(task):
        total += num(f.get("length"))
        done += num(f.get("completedLength"))
    return total, done


def is_completed(task):
    """与 AriaNg 一致的完成判定: 做种中 / 状态为 complete / 任务级进度已跑满。"""
    if task.get("seeder") == "true":
        return True
    if (task.get("status") or "") == "complete":
        return True
    total = num(task.get("totalLength"))
    done = num(task.get("completedLength"))
    return total > 0 and done >= total


def inside_src(real_path):
    if real_path == SRC_DIR:
        return False
    return real_path.startswith(SRC_DIR + os.sep)


def find_torrent(task, picked_files):
    """找出与任务同名的 .torrent 元数据文件 (必须在源目录内)，找不到返回空串。"""
    name = torrent_name(task)
    if not name:
        return ""
    candidates = []
    task_dir = task.get("dir") or ""
    if task_dir:
        candidates.append(os.path.join(task_dir, name + ".torrent"))
    # 单文件种子: <文件>.torrent；多文件种子: 数据根目录同级的 <根目录名>.torrent
    for path in picked_files[:1]:
        candidates.append(path + ".torrent")
        parent = os.path.dirname(path)
        while parent.startswith(SRC_DIR) and parent != SRC_DIR:
            if os.path.basename(parent) == name:
                candidates.append(parent + ".torrent")
                break
            parent = os.path.dirname(parent)
    for candidate in candidates:
        real = os.path.realpath(candidate)
        if os.path.isfile(real) and inside_src(real):
            return os.path.relpath(real, SRC_DIR)
    return ""


def status_text(status):
    return STATUS_TEXT.get(status, status)


version, ver_err = rpc("aria2.getVersion")
if ver_err:
    print(f"!! 无法从 Aria2 获取任务状态: {ver_err}", file=sys.stderr)
    print(f"   RPC 端点: {RPC_URL}", file=sys.stderr)
    if "Unauthorized" in ver_err or "拒绝请求" in ver_err:
        print("   常见原因: aria2.conf 里的 rpc-secret 与正在运行的 Aria2 实际使用的密钥不一致。", file=sys.stderr)
    else:
        print("   常见原因: Aria2 服务未运行 / rpc-listen-port 与运行中的实例不一致 / 端口未监听。", file=sys.stderr)
    sys.exit(1)

lines = []
version_text = "版本未知"
if isinstance(version, dict):
    version_text = version.get("version", "版本未知")
secret_text = "已匹配 rpc-secret" if RPC_SECRET else "未设置 rpc-secret"
lines.append(f">> RPC 连接正常: 127.0.0.1:{RPC_PORT} (aria2 {version_text}, {secret_text})")
for note in NOTES:
    lines.append(f">> 提示: {note}")

groups = []
incomplete_tasks = []
seen_paths = set()
skipped_missing = 0
skipped_outside = 0
query_errors = 0

for method, params, label in (("aria2.tellActive", None, "进行中"),
                              ("aria2.tellWaiting", [0, 1000], "等待/暂停"),
                              ("aria2.tellStopped", [0, 2000], "已停止")):
    tasks, err = rpc(method, params)
    if err:
        query_errors += 1
        lines.append(f"   !! {method} 查询失败: {err}")
        continue
    if not isinstance(tasks, list):
        tasks = []

    counts = {}
    completed_count = 0
    for task in tasks:
        status = task.get("status") or "?"
        counts[status] = counts.get(status, 0) + 1
        if not is_completed(task):
            incomplete_tasks.append((task_name(task), status, task_progress(task)))
            continue
        completed_count += 1
        picked_files = []
        size = 0
        for f in files_of(task):
            path = f.get("path") or ""
            if not path:
                continue
            real = os.path.realpath(path)
            if real in seen_paths:
                continue
            if not inside_src(real):
                skipped_outside += 1
                continue
            if not os.path.isfile(real):
                skipped_missing += 1
                continue
            seen_paths.add(real)
            picked_files.append(real)
            try:
                size += os.path.getsize(real)
            except OSError:
                pass
        if picked_files:
            # 种子文件探测失败不应影响转移，任何异常都按“无同名种子”处理
            try:
                torrent_file = find_torrent(task, picked_files)
            except Exception:
                torrent_file = ""
            groups.append((task_name(task), status, task.get("gid") or "",
                           picked_files, method != "aria2.tellStopped", size, torrent_file))

    counts_text = ", ".join(f"{status_text(key)}:{count}" for key, count in sorted(counts.items()))
    lines.append(f">> {label}: 共 {len(tasks)} 个任务 ({counts_text or '无'}), 其中已 100% 完成 {completed_count} 个")

if query_errors:
    lines.append(f"   !! 有 {query_errors} 项 RPC 查询失败，任务清单可能不完整。")

total_files = 0
total_size = 0
lines.append("")
lines.append(f">> 源目录: {SRC_DIR}")
if groups:
    for _name, _status, _gid, picked_files, _removable, _size, _torrent in groups:
        total_files += len(picked_files)
        total_size += _size
    lines.append(f">> 以下任务已 100% 下载完成，可转移 ({len(groups)} 个)，明细将分页展示：")
    lines.append(f">> 合计: {len(groups)} 个任务 / {total_files} 个文件 / {human(total_size)}")
else:
    lines.append(">> 没有找到已完全下载完成的任务数据。")

if skipped_outside:
    lines.append(f">> 提示: 有 {skipped_outside} 个已完成文件不在源目录内，已跳过。")
if skipped_missing:
    lines.append(f">> 提示: 有 {skipped_missing} 个已完成文件在磁盘上不存在，已跳过。")

if incomplete_tasks and not groups:
    lines.append("")
    lines.append(">> Aria2 中未判定为完成的任务 (最多显示 15 个，便于与 AriaNg 对照):")
    for name, status, progress in incomplete_tasks[:15]:
        total, done = progress
        percent = (done * 100.0 / total) if total > 0 else 0.0
        lines.append(f"   - [{status_text(status)}] {name}  {percent:.1f}%")
    if len(incomplete_tasks) > 15:
        lines.append(f"   ... 以及其余 {len(incomplete_tasks) - 15} 个任务")

# 每个任务一条展示行(供 bash 侧分页预览)；顺序与 tasks.rec 一致
with open(os.path.join(OUT_DIR, "tasks.disp"), "w", encoding="utf-8") as fh:
    for group in groups:
        name, status, _gid, picked_files, removable, size, _torrent = group
        marker = "  << 做种/暂停中，转移前会先停止它" if removable else ""
        fh.write("[%s] %s — %d 个文件 / %s%s\n"
                 % (status_text(status), name, len(picked_files), human(size), marker))

# 先落盘再输出报告: 即使报告文本出错，也不会影响已确认的转移清单
with open(os.path.join(OUT_DIR, "files.list"), "wb") as fh:
    for _name, _status, _gid, picked_files, _removable, _size, _torrent in groups:
        for path in picked_files:
            fh.write(os.path.relpath(path, SRC_DIR).encode("utf-8", "surrogateescape") + b"\x00")

# 每个任务一条记录: 序号 / 名称 / 状态 / GID / 是否仍在运行(需先解除占用) / 文件数 / 字节数 / 同名种子文件
with open(os.path.join(OUT_DIR, "tasks.rec"), "wb") as fh:
    for index, group in enumerate(groups, start=1):
        name, status, gid, picked_files, removable, size, torrent = group
        fields = [str(index), name, status, gid, "1" if removable else "0",
                  str(len(picked_files)), str(size), torrent]
        fh.write(FIELD_SEP.join(fields).encode("utf-8", "surrogateescape") + b"\x00")

for line in lines:
    print(line)
PYEOF

    if [ "$scan_rc" -ne 0 ]; then
        echo ""
        echo ">> [失败] 未能从 Aria2 取得任务状态，未做任何转移。请按上方提示排查后重试。"
        echo "   ---- 诊断信息 ----"
        echo "   使用的配置文件: ${CONF_FILE}"
        if [ -n "${running_aria2}" ]; then
            echo "   运行中的 Aria2: ${running_aria2}"
        else
            echo "   运行中的 Aria2: 未检测到 aria2c 进程"
        fi
        if command -v ss >/dev/null 2>&1; then
            local listen_ports
            listen_ports=$(ss -tln 2>/dev/null | grep -oE '(127\.0\.0\.1|0\.0\.0\.0|\*):[0-9]+' | sort -u | paste -sd ' ' - 2>/dev/null || true)
            if [ -n "${listen_ports}" ]; then
                echo "   本机监听端口: ${listen_ports}"
            fi
        fi
        echo "   ------------------"
        rpc_diagnose || true
        echo "   ------------------"
        rm -rf "${scan_tmp}"
        return 1
    fi

    declare -a ALL_FILES=() TASK_RECORDS=()
    if [ -s "${files_file}" ]; then
        if ! mapfile -d '' -t ALL_FILES < "${files_file}" 2>/dev/null; then
            echo "   !! 当前 bash 版本过低 (需要 4.4+ 才能按 NUL 解析文件清单)，请升级 bash 后重试。"
            rm -rf "${scan_tmp}"
            return 1
        fi
    fi
    if [ -s "${records_file}" ]; then
        mapfile -d '' -t TASK_RECORDS < "${records_file}" 2>/dev/null || TASK_RECORDS=()
    fi

    local FILE_COUNT=${#ALL_FILES[@]}
    local TASK_TOTAL=${#TASK_RECORDS[@]}

    if [ "$FILE_COUNT" -eq 0 ] || [ "$TASK_TOTAL" -eq 0 ]; then
        echo ""
        echo ">> 没有可转移的数据: Aria2 中没有已 100% 完成、且数据位于 ${SRC_DIR} 内的任务。"
        echo "   (对比上方各项统计: 若 AriaNg 明明显示已完成却统计为 0，说明脚本连到的 Aria2 实例与 AriaNg 不是同一个，或源目录选错了。)"
        rm -rf "${scan_tmp}"
        return 0
    fi

    # 解析每个任务的元数据 (序号 / 名称 / 状态 / GID / 是否需解除占用 / 文件数 / 字节数)
    declare -a T_NAME=() T_STATUS=() T_GID=() T_REMOVABLE=() T_COUNT=() T_SIZE=() T_TORRENT=()
    local rec r_index r_name r_status r_gid r_removable r_count r_size r_torrent
    local SUM_FILES=0
    for rec in "${TASK_RECORDS[@]}"; do
        IFS=$'\x1f' read -r r_index r_name r_status r_gid r_removable r_count r_size r_torrent <<< "$rec"
        T_NAME+=("$r_name")
        T_STATUS+=("$r_status")
        T_GID+=("$r_gid")
        T_REMOVABLE+=("$r_removable")
        T_COUNT+=("${r_count:-0}")
        T_SIZE+=("${r_size:-0}")
        T_TORRENT+=("${r_torrent:-}")
        SUM_FILES=$((SUM_FILES + ${r_count:-0}))
    done

    if [ "$SUM_FILES" -ne "$FILE_COUNT" ]; then
        echo ""
        echo ">> [失败] 任务清单与文件清单数量不一致 (任务记录 ${SUM_FILES} 个文件 / 清单 ${FILE_COUNT} 个文件)，为避免误移已中止。"
        rm -rf "${scan_tmp}"
        return 1
    fi

    # 分页预览可转移任务清单 (仅预览，随后仍可按编号选择子集)
    declare -a TASK_DISPLAY=()
    if [ -s "${scan_tmp}/tasks.disp" ]; then
        mapfile -t TASK_DISPLAY < "${scan_tmp}/tasks.disp" 2>/dev/null || TASK_DISPLAY=()
    fi
    if [ "${#TASK_DISPLAY[@]}" -gt 0 ]; then
        confirm_paged_list T_NAME "已 100% 下载完成、可转移的任务" 15 TASK_DISPLAY view || true
    fi

    echo ""
    read -rp "请输入要转移的任务编号 (空格或逗号分隔，例如 1 3 5；直接回车 = 全部 ${TASK_TOTAL} 个): " SELECTION
    declare -A CHOSEN_MAP=()
    local i token
    if [ -z "$SELECTION" ]; then
        for ((i=0; i<TASK_TOTAL; i++)); do
            CHOSEN_MAP[$i]=1
        done
    else
        local -a TOKENS=()
        read -ra TOKENS <<< "${SELECTION//,/ }"
        for token in "${TOKENS[@]}"; do
            if [[ ! "$token" =~ ^[0-9]+$ ]]; then
                echo "   >> 忽略无效编号: ${token}"
                continue
            fi
            if [ "$token" -lt 1 ] || [ "$token" -gt "$TASK_TOTAL" ]; then
                echo "   >> 忽略超出范围的编号: ${token} (有效范围 1-${TASK_TOTAL})"
                continue
            fi
            CHOSEN_MAP[$((token - 1))]=1
        done
    fi

    if [ ${#CHOSEN_MAP[@]} -eq 0 ]; then
        echo ">> 未选择任何任务，已取消。"
        rm -rf "${scan_tmp}"
        return 0
    fi

    # 按任务切片出实际要转移的文件，并挑出需要先解除占用 / 之后清除记录的 GID
    declare -a COMPLETED_FILES=() FORCE_GIDS=() ALL_GIDS=()
    local offset=0 count chosen_count=0 chosen_bytes=0
    for ((i=0; i<TASK_TOTAL; i++)); do
        count="${T_COUNT[$i]}"
        if [ -n "${CHOSEN_MAP[$i]}" ]; then
            if [ "$count" -gt 0 ]; then
                COMPLETED_FILES+=("${ALL_FILES[@]:offset:count}")
            fi
            chosen_count=$((chosen_count + 1))
            chosen_bytes=$((chosen_bytes + T_SIZE[i]))
            if [ -n "${T_GID[$i]}" ]; then
                ALL_GIDS+=("${T_GID[$i]}")
                if [ "${T_REMOVABLE[$i]}" = "1" ]; then
                    FORCE_GIDS+=("${T_GID[$i]}")
                fi
            fi
        fi
        offset=$((offset + count))
    done

    # 可选: 连同同名 .torrent 元数据一起转移 (默认不搬，仍可用主菜单 9 -> 1 清理)
    declare -a TORRENT_FILES=()
    declare -A TORRENT_SEEN=()
    local torrent_path
    for ((i=0; i<TASK_TOTAL; i++)); do
        [ -n "${CHOSEN_MAP[$i]}" ] || continue
        torrent_path="${T_TORRENT[$i]}"
        [ -n "$torrent_path" ] || continue
        [ -n "${TORRENT_SEEN[$torrent_path]}" ] && continue
        TORRENT_SEEN[$torrent_path]=1
        TORRENT_FILES+=("$torrent_path")
    done

    if [ ${#TORRENT_FILES[@]} -gt 0 ]; then
        echo ""
        echo ">> 检测到 ${#TORRENT_FILES[@]} 个已选任务带有同名 .torrent 元数据文件："
        confirm_paged_list TORRENT_FILES "同名 .torrent 元数据文件" 15 "" view || true
        read -rp "是否连同这些 .torrent 一并转移到新磁盘? [y/N 默认: N]: " MOVE_TORRENTS
        MOVE_TORRENTS="${MOVE_TORRENTS:-N}"
        if [[ "$MOVE_TORRENTS" =~ ^[Yy]$ ]]; then
            COMPLETED_FILES+=("${TORRENT_FILES[@]}")
            echo ">> 已加入转移清单。"
        else
            echo ">> 已跳过 .torrent (可稍后用主菜单 9 -> 1 清理已完成任务的种子文件)。"
        fi
    fi

    local SEL_FILES=${#COMPLETED_FILES[@]}
    local SEL_GB
    SEL_GB=$(awk "BEGIN {printf \"%.2f\", ${chosen_bytes}/1024/1024/1024}")
    echo ""
    echo ">> 已选择 ${chosen_count} 个任务 / ${SEL_FILES} 个文件 / 约 ${SEL_GB} GB"
    if [ "$SEL_FILES" -gt 0 ]; then
        confirm_paged_list COMPLETED_FILES "以下文件将被转移到 ${DEST_DIR} (相对路径)" 15 "" view || true
    fi
    if [ ${#FORCE_GIDS[@]} -gt 0 ]; then
        echo ">> 其中以下任务仍在做种/暂停中，转移前会先停止它们 (之后需重新添加种子才能继续做种):"
        local -a FORCE_NAMES=()
        for ((i=0; i<TASK_TOTAL; i++)); do
            if [ -n "${CHOSEN_MAP[$i]}" ] && [ "${T_REMOVABLE[$i]}" = "1" ]; then
                FORCE_NAMES+=("${T_NAME[$i]}")
            fi
        done
        if [ "${#FORCE_NAMES[@]}" -gt 0 ]; then
            confirm_paged_list FORCE_NAMES "做种/暂停中、转移前会被停止的任务" 15 "" view || true
        fi
    fi

    read -rp "确认开始同步移动以上已完成任务的数据到 ${DEST_DIR}? [Y/n 默认: Y]: " CONFIRM_MOVE
    CONFIRM_MOVE="${CONFIRM_MOVE:-Y}"
    if [[ ! "$CONFIRM_MOVE" =~ ^[Yy]$ ]]; then
        echo ">> 操作已取消。"
        rm -rf "${scan_tmp}"
        return 0
    fi

    if [ ${#FORCE_GIDS[@]} -gt 0 ]; then
        printf '%s\0' "${FORCE_GIDS[@]}" > "${scan_tmp}/force.gids"
        echo ">> 正在安全解除做种 / 暂停任务的文件占用..."
        _aria2_gid_action "${scan_tmp}/force.gids" "aria2.forceRemove" "解除占用"
    fi

    echo ">> 正在同步数据并保持相对目录层级结构..."
    declare -a VERIFIED_FILES=() FAILED_FILES=()
    local it dest_path src_size dest_size
    for it in "${COMPLETED_FILES[@]}"; do
        echo "   -> 正在转移: ${it}..."
        # 以 <源目录>/./<相对路径> 传入: -R 会把 ./ 之后的部分作为目标相对路径，
        # 与当前工作目录无关 (旧实现依赖 cd，一旦目标目录写成相对路径就会把文件复制回源目录)
        if ! copy_path "${SRC_DIR}/./${it}" "${DEST_DIR}"; then
            echo "   !! [失败] 复制返回非零"
            FAILED_FILES+=("$it")
            continue
        fi
        dest_path="${DEST_DIR}/${it}"
        if [ ! -e "$dest_path" ]; then
            echo "   !! [失败] 目标位置未找到文件"
            FAILED_FILES+=("$it")
            continue
        fi
        src_size=$(stat -c %s "${SRC_DIR}/${it}" 2>/dev/null || stat -f %z "${SRC_DIR}/${it}" 2>/dev/null || echo "")
        dest_size=$(stat -c %s "$dest_path" 2>/dev/null || stat -f %z "$dest_path" 2>/dev/null || echo "")
        if [ -n "$src_size" ] && [ -n "$dest_size" ] && [ "$src_size" != "$dest_size" ]; then
            echo "   !! [失败] 大小不一致 (源 ${src_size} / 目标 ${dest_size})"
            FAILED_FILES+=("$it")
            continue
        fi
        VERIFIED_FILES+=("$it")
    done

    echo ""
    echo ">> 同步结果: 已确认 ${#VERIFIED_FILES[@]} 个文件落入 ${DEST_DIR}"
    if [ ${#FAILED_FILES[@]} -gt 0 ]; then
        echo ">> [警告] ${#FAILED_FILES[@]} 个文件未能确认同步成功，它们不会被从源磁盘删除:"
        for it in "${FAILED_FILES[@]:0:10}"; do
            echo "   - ${it}"
        done
        if [ ${#FAILED_FILES[@]} -gt 10 ]; then
            echo "   ... 以及其余 $(( ${#FAILED_FILES[@]} - 10 )) 个"
        fi
    fi
    if [ ${#VERIFIED_FILES[@]} -eq 0 ]; then
        echo ""
        echo ">> [中止] 没有任何文件确认同步成功，已跳过后续清理 (源文件全部保留)。"
        echo "   请检查目标磁盘是否可写/剩余空间，或上方复制错误信息。"
        rm -rf "${scan_tmp}"
        return 1
    fi

    read -rp "是否彻底删除原路径 (${SRC_DIR}) 上已确认转移的文件以释放空间? [Y/n 默认: Y]: " CLEAN_SRC
    CLEAN_SRC="${CLEAN_SRC:-Y}"
    if [[ "$CLEAN_SRC" =~ ^[Yy]$ ]]; then
        echo ">> 正在清理原路径上的已转移数据 (仅限已确认同步成功的文件)..."
        local removed=0 skipped_del=0
        for it in "${VERIFIED_FILES[@]}"; do
            if [ ! -e "${DEST_DIR}/${it}" ]; then
                echo "   - 跳过 (目标侧已不可见，安全起见不删除源): ${it}"
                skipped_del=$((skipped_del + 1))
                continue
            fi
            if rm -f "${SRC_DIR}/${it}"; then
                removed=$((removed + 1))
            else
                echo "   !! 删除失败: ${it}"
                skipped_del=$((skipped_del + 1))
            fi
        done
        find "${SRC_DIR}" -mindepth 1 -type d -empty -delete 2>/dev/null || true

        # 旧版本安装遗留的 .aria2 控制文件 (aria2-next 不再生成)，数据已不在原盘的一并清掉
        while IFS= read -r ctl; do
            if [ ! -e "${ctl%.aria2}" ]; then
                rm -f "$ctl"
            fi
        done < <(find "${SRC_DIR}" -type f -name "*.aria2" 2>/dev/null)

        echo ">> 已删除源文件 ${removed} 个${skipped_del:+ (跳过 ${skipped_del} 个)}，原磁盘空间已释放。"

        # 原文件已删除，Aria2 里的这些记录已失效 (AriaNg 会显示文件缺失)，可选择一并清除
        if [ ${#FAILED_FILES[@]} -gt 0 ]; then
            echo ""
            echo ">> 提示: 由于有文件未确认同步成功，本次不清除 Aria2 中的任务记录 (避免丢失续传信息)。"
        elif [ ${#ALL_GIDS[@]} -gt 0 ]; then
            echo ""
            echo ">> 提示: 这些任务的原文件已删除，Aria2 中仍保留其记录 (会显示在 AriaNg 的『已停止』列表且文件缺失)。"
            read -rp "是否同时清除这些任务的下载记录? [Y/n 默认: Y]: " PURGE_RECORDS
            PURGE_RECORDS="${PURGE_RECORDS:-Y}"
            if [[ "$PURGE_RECORDS" =~ ^[Yy]$ ]]; then
                printf '%s\0' "${ALL_GIDS[@]}" > "${scan_tmp}/purge.gids"
                _aria2_gid_action "${scan_tmp}/purge.gids" "aria2.removeDownloadResult" "清除记录"
            else
                echo ">> 已保留 Aria2 中的下载记录。"
            fi
        fi
    else
        echo ">> 已保留源磁盘上的文件 (Aria2 中的任务记录也保持原样)。"
    fi

    rm -rf "${scan_tmp}"
}

# ==================== 模块 7-2: 转移游离文件/目录 (不被 Aria2 任务管理) ====================
_transfer_orphan_files() {
    local SRC_DIR="$1"
    local DEST_DIR="$2"

    echo ""
    echo "---- [游离文件] 源: ${SRC_DIR}  -->  目标: ${DEST_DIR} ----"
    echo ">> 正在扫描源目录: 找出不被任何 Aria2 任务管理的游离目标..."

    local scan_tmp scan_rc
    scan_tmp=$(mktemp -d)
    scan_rc=0
    ARIA2_CONF_FILE="${CONF_FILE}" ARIA2_SRC_DIR="${SRC_DIR}" ARIA2_OUT_DIR="${scan_tmp}" \
        python3 - <<'PYEOF' || scan_rc=$?
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

CONF_FILE = os.environ.get("ARIA2_CONF_FILE", "")
SRC_DIR = os.path.realpath(os.environ.get("ARIA2_SRC_DIR", "."))
OUT_DIR = os.environ.get("ARIA2_OUT_DIR", ".")
RPC_TIMEOUT = 20
FIELD_SEP = "\x1f"


def read_conf(key, default):
    try:
        with open(CONF_FILE, "r", encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key_name, value = line.split("=", 1)
                if key_name.strip() == key:
                    return value.strip()
    except OSError:
        pass
    return default


def human(size):
    value = float(size)
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if value < 1024 or unit == "TB":
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} TB"


RPC_PORT = read_conf("rpc-listen-port", "6800") or "6800"
RPC_SECRET = read_conf("rpc-secret", "")
RPC_URL = "http://127.0.0.1:" + RPC_PORT + "/jsonrpc"
# 显式使用空代理，防止本地 127.0.0.1 请求被系统 http_proxy 劫持
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
TRANSPORT = ["urllib"]


def build_body(method, params=None):
    call_params = ["token:" + RPC_SECRET] if RPC_SECRET else []
    if params:
        call_params.extend(params)
    return json.dumps({"jsonrpc": "2.0", "id": "orphan_scan", "method": method, "params": call_params})


def call_urllib(body):
    req = urllib.request.Request(RPC_URL, data=body.encode("utf-8"), headers={"Content-Type": "application/json"})
    try:
        with OPENER.open(req, timeout=RPC_TIMEOUT) as resp:
            return resp.read().decode("utf-8", "replace"), None
    except urllib.error.HTTPError as exc:
        return None, f"HTTP {exc.code}"
    except urllib.error.URLError as exc:
        return None, f"无法连接 127.0.0.1:{RPC_PORT} ({getattr(exc, 'reason', exc)})"
    except Exception as exc:
        return None, f"{type(exc).__name__}: {exc}"


def call_curl(body):
    """curl 直连 RPC：绕过 urllib 可能遇到的代理 / 环境差异问题。"""
    try:
        proc = subprocess.run(["curl", "-sS", "-m", str(RPC_TIMEOUT), "--noproxy", "*", "-X", "POST",
                               "-H", "Content-Type: application/json", "--data-binary", "@-", RPC_URL],
                              input=body.encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=RPC_TIMEOUT + 10)
    except FileNotFoundError:
        return None, "未找到 curl 命令"
    except Exception as exc:
        return None, f"curl 执行异常: {exc}"
    if proc.returncode != 0:
        return None, f"curl 退出码 {proc.returncode} ({proc.stderr.decode('utf-8', 'replace').strip()})"
    return proc.stdout.decode("utf-8", "replace"), None


def parse_response(raw):
    try:
        data = json.loads(raw)
    except Exception:
        return None, f"响应不是合法 JSON: {raw[:200]}"
    if not isinstance(data, dict):
        return None, "响应格式异常"
    if data.get("error"):
        err = data["error"] if isinstance(data["error"], dict) else {}
        return None, f"RPC 拒绝请求 [{err.get('code', '?')}] {err.get('message', '')}"
    return data.get("result"), None


def rpc(method, params=None):
    """返回 (结果, 错误描述)；urllib 失败时自动回退 curl。"""
    body = build_body(method, params)
    if TRANSPORT[0] == "curl":
        raw, err = call_curl(body)
        if err is None:
            return parse_response(raw)
        return None, err
    raw, err = call_urllib(body)
    if err is None:
        return parse_response(raw)
    raw2, err2 = call_curl(body)
    if err2 is None:
        TRANSPORT[0] = "curl"
        return parse_response(raw2)
    return None, f"{err}；curl 回退亦失败: {err2}"


version, ver_err = rpc("aria2.getVersion")
if ver_err:
    print(f"!! 无法从 Aria2 获取任务状态: {ver_err}", file=sys.stderr)
    print(f"   RPC 端点: {RPC_URL}", file=sys.stderr)
    print("   常见原因: 服务未运行 / rpc-listen-port 与运行中实例不一致 / rpc-secret 不匹配。", file=sys.stderr)
    sys.exit(1)


def clean_metadata_name(raw_name):
    """清理 [METADATA] 虚拟文件名，提取真实番号/文件名。
    例如: [METADATA][javdb.com]SNOS-134-C.torrent -> SNOS-134-C
    """
    name = re.sub(r"^(\[[^\]]+\])+", "", raw_name).strip()
    for ext in [".torrent.无码破解", ".torrent"]:
        if name.endswith(ext):
            name = name[:-len(ext)]
    return name


managed_names = set()
task_count = 0
query_errors = 0
for method, params in (("aria2.tellActive", None),
                       ("aria2.tellWaiting", [0, 10000]),
                       ("aria2.tellStopped", [0, 10000])):
    tasks, err = rpc(method, params)
    if err:
        query_errors += 1
        continue
    if not isinstance(tasks, list):
        continue
    for task in tasks:
        task_count += 1
        task_dir = task.get("dir") or ""
        task_dir_real = os.path.realpath(task_dir) if task_dir else SRC_DIR
        # BT 任务名提取
        info = task.get("bittorrent")
        bt_name = ""
        if isinstance(info, dict):
            inner = info.get("info")
            if isinstance(inner, dict):
                bt_name = inner.get("name") or ""
        if bt_name and task_dir_real == SRC_DIR:
            managed_names.add(bt_name.lower())
        # 文件列表路径提取
        files = task.get("files")
        if not isinstance(files, list):
            continue
        for f in files:
            raw_path = (f or {}).get("path") or ""
            if not raw_path:
                continue
            if raw_path.startswith("[METADATA]"):
                clean_name = clean_metadata_name(raw_path)
                if clean_name:
                    managed_names.add(clean_name.lower())
                continue
            if not os.path.isabs(raw_path):
                real_path = os.path.realpath(os.path.join(task_dir_real, raw_path))
            else:
                real_path = os.path.realpath(raw_path)
            if real_path == SRC_DIR or real_path.startswith(SRC_DIR + os.sep):
                rel_path = os.path.relpath(real_path, SRC_DIR)
                managed_names.add(rel_path.split(os.sep)[0].lower())


def tree_size(path):
    if os.path.isfile(path):
        try:
            return os.path.getsize(path)
        except OSError:
            return 0
    total = 0
    for root, _dirs, files in os.walk(path, onerror=lambda _e: None):
        for name in files:
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                pass
    return total


try:
    entries = sorted(os.listdir(SRC_DIR))
except OSError as exc:
    print(f"!! 无法读取源目录 {SRC_DIR}: {exc}", file=sys.stderr)
    sys.exit(1)

# 磁盘上旧版遗留的 .aria2 控制文件: aria2-next 不再生成，这里仅作为兼容保留的保护规则
legacy_controls = {item[:-6].lower() for item in entries if item.endswith(".aria2")}
records = []
skipped_managed = 0
for item in entries:
    item_lower = item.lower()
    # 规则 1: 忽略隐藏文件、种子文件与旧版遗留的 .aria2 控制文件
    if item.startswith(".") or item.endswith(".aria2") or item.endswith(".torrent"):
        continue
    # 规则 2: 命中 RPC 任务清单（含 [METADATA] 提取名）
    if item_lower in managed_names or item_lower in legacy_controls:
        skipped_managed += 1
        continue
    # 规则 3: 去掉包装前缀后再比对一次 (如 [98t.tv]xxx)
    clean_item = re.sub(r"^(\[[^\]]+\])+", "", item).strip().lower()
    if clean_item in managed_names or clean_item in legacy_controls:
        skipped_managed += 1
        continue
    full_path = os.path.join(SRC_DIR, item)
    records.append((item, os.path.isdir(full_path), tree_size(full_path)))

total_bytes = sum(size for _n, _d, size in records)
lines = []
lines.append(">> 游离判定依据: 不在任何 Aria2 任务清单内 (进行中 / 等待中 / 已停止)。")
lines.append(f">> 源目录: {SRC_DIR}")
lines.append(f">> RPC 任务总数: {task_count} 个 (解析出受管理名称 {len(managed_names)} 个)")
if legacy_controls:
    lines.append(f">> 旧版遗留 .aria2 控制基准名: {len(legacy_controls)} 个 (已一并纳入保护)")
lines.append(f">> 已按 Aria2 管理状态跳过: {skipped_managed} 项")
if query_errors:
    lines.append(f"   !! 有 {query_errors} 项 RPC 查询失败，游离判定可能不准，请留意误判。")
if records:
    lines.append(f">> 发现游离文件/目录: {len(records)} 个 (约 {human(total_bytes)})")
else:
    lines.append(">> 未发现游离文件/目录。")

# 先落盘再输出报告: 即使报告文本出错，也不影响已确认的转移清单
with open(os.path.join(OUT_DIR, "orphans.rec"), "wb") as fh:
    for index, (name, is_dir, size) in enumerate(records, start=1):
        fields = [str(index), name, "1" if is_dir else "0", str(size), human(size)]
        fh.write(FIELD_SEP.join(fields).encode("utf-8", "surrogateescape") + b"\x00")

for line in lines:
    print(line)
PYEOF

    if [ "$scan_rc" -ne 0 ]; then
        echo ""
        echo ">> [失败] 游离文件扫描未完成 (RPC 或文件系统异常)，未做任何转移。"
        rm -rf "${scan_tmp}"
        return 1
    fi

    local orphans_file="${scan_tmp}/orphans.rec"
    if [ ! -s "${orphans_file}" ]; then
        echo ""
        echo ">> 没有发现游离文件/目录: 目录内所有内容都已被 Aria2 任务管理。"
        rm -rf "${scan_tmp}"
        return 0
    fi

    declare -a ORPHAN_RECS=()
    mapfile -d '' -t ORPHAN_RECS < "${orphans_file}" 2>/dev/null || ORPHAN_RECS=()
    local ORPHAN_TOTAL=${#ORPHAN_RECS[@]}
    if [ "$ORPHAN_TOTAL" -eq 0 ]; then
        echo ""
        echo ">> 没有发现游离文件/目录。"
        rm -rf "${scan_tmp}"
        return 0
    fi

    declare -a O_NAME=() O_ISDIR=() O_BYTES=() O_HUMAN=()
    local rec r_index r_name r_isdir r_bytes r_human total_bytes=0
    for rec in "${ORPHAN_RECS[@]}"; do
        IFS=$'\x1f' read -r r_index r_name r_isdir r_bytes r_human <<< "$rec"
        O_NAME+=("$r_name")
        O_ISDIR+=("$r_isdir")
        O_BYTES+=("${r_bytes:-0}")
        O_HUMAN+=("${r_human:-未知}")
        total_bytes=$((total_bytes + ${r_bytes:-0}))
    done

    local total_gb
    total_gb=$(awk "BEGIN {printf \"%.2f\", ${total_bytes}/1024/1024/1024}")

    # 统一用可翻页的清单一并完成预览与确认
    local i kind
    declare -a O_DISPLAY=()
    for ((i=0; i<ORPHAN_TOTAL; i++)); do
        if [ "${O_ISDIR[$i]}" = "1" ]; then kind="[目录]"; else kind="[文件]"; fi
        O_DISPLAY+=("${kind} ${O_NAME[$i]} (${O_HUMAN[$i]})")
    done

    echo ""
    echo ">> 共发现 ${ORPHAN_TOTAL} 个游离目标 / 约 ${total_gb} GB"
    if ! confirm_paged_list O_NAME "不被 Aria2 任务管理的游离文件/目录 (将同步到 ${DEST_DIR})" 15 O_DISPLAY; then
        echo ">> 操作已取消。"
        rm -rf "${scan_tmp}"
        return 0
    fi

    declare -a TRANSFER_FAILED=()
    local name _dest_check
    echo ""
    echo ">> 正在同步游离数据到新磁盘 (保持相对目录层级)..."
    for ((i=0; i<ORPHAN_TOTAL; i++)); do
        name="${O_NAME[$i]}"
        echo "   -> 正在转移: ${name}..."
        # 以 ${SRC_DIR}/./ 形式传入，-R 会以 ./ 之后的部分作为目标相对路径
        if ! copy_path "${SRC_DIR}/./${name}" "${DEST_DIR}"; then
            echo "   !! [失败] 同步出错: ${name}"
            TRANSFER_FAILED+=("$name")
            continue
        fi
        # 二次确认: 目标侧必须真实存在，否则不进入清理清单
        _dest_check="${DEST_DIR}/${name}"
        if [ ! -e "$_dest_check" ]; then
            echo "   !! [失败] 目标位置未找到: ${name}"
            TRANSFER_FAILED+=("$name")
        fi
    done

    if [ ${#TRANSFER_FAILED[@]} -gt 0 ]; then
        echo ""
        echo ">> 警告: 有 ${#TRANSFER_FAILED[@]} 项同步失败，后续清理会跳过这些项:"
        for name in "${TRANSFER_FAILED[@]}"; do
            echo "   - ${name}"
        done
    fi

    echo ""
    echo ">> [完成] 游离数据同步结束。"
    read -rp "是否删除源目录 (${SRC_DIR}) 中已转移的游离文件/目录以释放空间? [Y/n 默认: Y]: " CLEAN_ORPHAN_SRC
    CLEAN_ORPHAN_SRC="${CLEAN_ORPHAN_SRC:-Y}"
    if [[ ! "$CLEAN_ORPHAN_SRC" =~ ^[Yy]$ ]]; then
        echo ">> 已保留源目录上的游离文件 (请确认新磁盘数据完整后自行清理)。"
        rm -rf "${scan_tmp}"
        return 0
    fi

    declare -A FAILED_MAP=()
    for name in "${TRANSFER_FAILED[@]}"; do
        FAILED_MAP["$name"]=1
    done

    echo ">> 正在清理源目录中的已转移游离目标..."
    local removed=0 skipped=0
    for ((i=0; i<ORPHAN_TOTAL; i++)); do
        name="${O_NAME[$i]}"
        if [ -n "${FAILED_MAP[$name]}" ]; then
            echo "   - 跳过 (同步失败，未删除): ${name}"
            skipped=$((skipped + 1))
            continue
        fi
        if [ ! -e "${DEST_DIR}/${name}" ]; then
            echo "   - 跳过 (目标侧已不可见，安全起见不删除源): ${name}"
            skipped=$((skipped + 1))
            continue
        fi
        if rm -rf -- "${SRC_DIR}/${name}"; then
            echo "   - 已删除: ${name}"
            removed=$((removed + 1))
        else
            echo "   !! 删除失败: ${name}"
            skipped=$((skipped + 1))
        fi
    done

    echo ""
    echo ">> [成功] 已删除 ${removed} 项游离目标，源磁盘空间已释放。"
    if [ "$skipped" -gt 0 ]; then
        echo "   提示: 有 ${skipped} 项被跳过 (同步失败或删除失败)，请在源目录中手动确认。"
    fi

    rm -rf "${scan_tmp}"
}

# ==================== 模块 8: 恢复未完成下载 / 重试异常停止的任务 ====================
scan_and_resume_torrents() {
    if [ ! -f "${CONF_FILE}" ]; then
        echo "错误: 未找到配置文件 ${CONF_FILE}，请先确认 Aria2 是否已安装。"
        return 1
    fi

    install_packages curl python3

    if ! command -v python3 >/dev/null 2>&1; then
        echo "错误: 未检测到 python3，无法解析 Aria2 RPC 状态，请先安装 python3 后重试。"
        return 1
    fi
    check_cmds curl find || return 1

    local RPC_PORT RPC_SECRET
    RPC_PORT=$(grep -E "^rpc-listen-port=" "${CONF_FILE}" | cut -d'=' -f2- | tr -d ' \r')
    RPC_PORT="${RPC_PORT:-$DEFAULT_PORT}"
    RPC_SECRET=$(grep -E "^rpc-secret=" "${CONF_FILE}" | cut -d'=' -f2- | tr -d ' \r')

    if ! svc_is_active; then
        echo ">> 检测到 Aria2 服务未运行，正在启动..."
        svc_start
        sleep 1
    fi

    local SUB_CHOICE
    while true; do
        echo ""
        echo "=========================================="
        echo "       恢复 / 重试未完成的下载任务        "
        echo "=========================================="
        echo " 1. 扫描目录并恢复未完成种子断点下载 (重新注入 .torrent)"
        echo " 2. 一键继续下载异常停止的任务 (报错 / 未完成，如磁盘写满导致)"
        echo " 0. 返回上级菜单"
        echo "=========================================="
        read -rp "请选择操作 [0-2 默认: 0]: " SUB_CHOICE
        SUB_CHOICE="${SUB_CHOICE:-0}"

        case "$SUB_CHOICE" in
            1) resume_torrents_from_dir || true ;;
            2) resume_stopped_tasks || true ;;
            0) return 0 ;;
            *) echo "无效选项，请重新选择。"; continue ;;
        esac

        pause_menu
    done
}

# ==================== 模块 8-1: 扫描目录并重新注入 .torrent 恢复断点 ====================
resume_torrents_from_dir() {
    install_packages curl findutils coreutils
    check_cmds base64 curl find || return 1

    local CURRENT_DIR
    CURRENT_DIR=$(get_current_download_dir)
    read -rp "请输入要扫描的种子所在目录 [默认: ${CURRENT_DIR}]: " TARGET_SCAN_DIR
    TARGET_SCAN_DIR="${TARGET_SCAN_DIR:-$CURRENT_DIR}"
    TARGET_SCAN_DIR="${TARGET_SCAN_DIR%/}"

    if [ ! -d "${TARGET_SCAN_DIR}" ]; then
        echo "错误: 目录 ${TARGET_SCAN_DIR} 不存在！"
        return 1
    fi

    echo ""
    rpc_diagnose || true
    echo ""

    echo ">> 正在扫描 ${TARGET_SCAN_DIR} 下的 .torrent 种子文件 (最多 3 层子目录)..."
    mapfile -t TORRENT_FILES < <(find "${TARGET_SCAN_DIR}" -maxdepth 3 -type f -name "*.torrent")

    if [ ${#TORRENT_FILES[@]} -eq 0 ]; then
        echo "提示: 在该目录下未找到任何 .torrent 文件，无法按种子重新注入。"
        echo "   注意: aria2-next 已移除 bt-save-metadata，磁力链任务通常不会再在下载目录留下 .torrent 文件；"
        echo "         这类未完成任务请改用 本菜单 -> 2『一键继续下载异常停止的任务』(基于 RPC，无需种子文件)。"
        return 0
    fi

    echo ">> 找到 ${#TORRENT_FILES[@]} 个种子文件。"

    declare -a TORRENT_DISPLAY=()
    local _tor=""
    for _tor in "${TORRENT_FILES[@]}"; do
        TORRENT_DISPLAY+=("${_tor#"${TARGET_SCAN_DIR}/"}")
    done
    if ! confirm_paged_list TORRENT_FILES "以下种子将被重新注入 Aria2 (先校验后继续下载)" 15 TORRENT_DISPLAY; then
        echo ">> 已取消注入。"
        return 0
    fi

    echo ">> 正在校验未完成状态并注入 Aria2..."

    local resumed_count=0
    for tor in "${TORRENT_FILES[@]}"; do
        echo ">> 正在推送种子: $(basename "$tor")..."
        tor_b64=$(base64 -w 0 "$tor" 2>/dev/null || base64 "$tor" | tr -d '\r\n')
        
        if [ -n "$RPC_SECRET" ]; then
            payload=$(cat <<EOF
{
  "jsonrpc": "2.0",
  "id": "resume_task",
  "method": "aria2.addTorrent",
  "params": [
    "token:${RPC_SECRET}",
    "${tor_b64}",
    [],
    {"dir": "${TARGET_SCAN_DIR}"}
  ]
}
EOF
)
        else
            payload=$(cat <<EOF
{
  "jsonrpc": "2.0",
  "id": "resume_task",
  "method": "aria2.addTorrent",
  "params": [
    "${tor_b64}",
    [],
    {"dir": "${TARGET_SCAN_DIR}"}
  ]
}
EOF
)
        fi

        resp=$(curl -s -m 10 -X POST "http://127.0.0.1:${RPC_PORT}/jsonrpc" -d "${payload}" || true)
        
        if echo "$resp" | grep -q '"result"'; then
            echo "   [成功] 任务已载入，已自动在目录 ${TARGET_SCAN_DIR} 开始哈希校验！"
            resumed_count=$((resumed_count + 1))
        else
            err_msg=$(printf '%s' "$resp" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p' || true)
            echo "   [失败] 注入失败: ${err_msg:-$resp}"
            if [ -z "$resp" ]; then
                echo "          (无响应: 请确认 Aria2 服务与 RPC 端口正常)"
            fi
        fi
    done

    echo ""
    echo ">> 处理完毕！共成功推送并激活 ${resumed_count} 个未完成任务。"
    echo ">> 请打开 AriaNg 查看任务列表，任务会先进行“检查中 (Checking)”，自检完成后将自动断点续传。"
}

# ==================== 模块 8-2: 一键继续下载异常停止的任务 ====================
# 说明: aria2 的 aria2.unpause 仅适用于 paused 状态，对已停止(error/removed)的任务会直接拒绝，
#       因此这里按原任务信息重新加入下载队列。aria2-next 无 .aria2 控制文件，断点数据存于
#       state-dir，重加后 Aria2 会自动做完整性校验并续传已下载的分片。
resume_stopped_tasks() {
    echo ""
    echo "---- [异常停止任务] 一键继续下载 ----"
    echo ">> 正在分析 Aria2『已停止』列表: 只筛选未下载完整(报错 / 被移除 / 磁盘写满等)的任务..."
    echo "   (正常下载完成的 100% 任务会被自动跳过)"

    local scan_tmp scan_rc
    scan_tmp=$(mktemp -d)
    scan_rc=0
    # 注意: python3 是从 stdin(即 heredoc)读取脚本的，所以交互提示必须放在 bash 侧，
    #       否则 python 里的 input() 会直接读到 EOF，导致静默取消、任务永远加不进去。
    ARIA2_CONF_FILE="${CONF_FILE}" ARIA2_OUT_DIR="${scan_tmp}" \
        python3 - <<'PYEOF' || scan_rc=$?
import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

CONF_FILE = os.environ.get("ARIA2_CONF_FILE", "")
OUT_DIR = os.environ.get("ARIA2_OUT_DIR", ".")
RPC_TIMEOUT = 20

RED = "\033[0;31m"
GREEN = "\033[0;32m"
YELLOW = "\033[0;33m"
CYAN = "\033[0;36m"
NC = "\033[0m"


def read_conf(key, default):
    try:
        with open(CONF_FILE, "r", encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                name, value = line.split("=", 1)
                if name.strip() == key:
                    return value.strip()
    except OSError:
        pass
    return default


def num(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def human(size):
    value = float(size)
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if value < 1024 or unit == "TB":
            return "%.1f %s" % (value, unit)
        value = value / 1024
    return "%.1f TB" % value


RPC_PORT = read_conf("rpc-listen-port", "6800") or "6800"
RPC_SECRET = read_conf("rpc-secret", "")
RPC_URL = "http://127.0.0.1:" + RPC_PORT + "/jsonrpc"
# 显式使用空代理，防止本地 127.0.0.1 请求被系统 http_proxy 劫持
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
TRANSPORT = ["urllib"]


def make_body(method, params):
    call_params = ["token:" + RPC_SECRET] if RPC_SECRET else []
    if params:
        call_params.extend(params)
    return json.dumps({"jsonrpc": "2.0", "id": "resume_stopped", "method": method, "params": call_params})


def call_urllib(body):
    req = urllib.request.Request(RPC_URL, data=body.encode("utf-8"), headers={"Content-Type": "application/json"})
    try:
        with OPENER.open(req, timeout=RPC_TIMEOUT) as resp:
            return resp.read().decode("utf-8", "replace"), None
    except urllib.error.HTTPError as exc:
        return None, "HTTP %s" % exc.code
    except urllib.error.URLError as exc:
        return None, "无法连接 127.0.0.1:%s (%s)" % (RPC_PORT, getattr(exc, "reason", exc))
    except Exception as exc:
        return None, "%s: %s" % (type(exc).__name__, exc)


def call_curl(body):
    try:
        proc = subprocess.run(["curl", "-sS", "-m", str(RPC_TIMEOUT), "--noproxy", "*", "-X", "POST",
                               "-H", "Content-Type: application/json", "--data-binary", "@-", RPC_URL],
                              input=body.encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=RPC_TIMEOUT + 10)
    except FileNotFoundError:
        return None, "未找到 curl 命令"
    except Exception as exc:
        return None, "curl 执行异常: %s" % exc
    if proc.returncode != 0:
        return None, "curl 退出码 %s" % proc.returncode
    return proc.stdout.decode("utf-8", "replace"), None


def parse_resp(raw):
    try:
        data = json.loads(raw)
    except Exception:
        return None, "响应不是合法 JSON: %s" % raw[:120]
    if not isinstance(data, dict):
        return None, "响应格式异常"
    if data.get("error"):
        err = data["error"] if isinstance(data["error"], dict) else {}
        return None, "[%s] %s" % (err.get("code", "?"), err.get("message", ""))
    return data.get("result"), None


def rpc(method, params=None):
    """返回 (结果, 错误描述)；urllib 失败时自动回退 curl。"""
    body = make_body(method, params)
    if TRANSPORT[0] == "curl":
        raw, err = call_curl(body)
        if err is None:
            return parse_resp(raw)
        return None, err
    raw, err = call_urllib(body)
    if err is None:
        return parse_resp(raw)
    raw2, err2 = call_curl(body)
    if err2 is None:
        TRANSPORT[0] = "curl"
        return parse_resp(raw2)
    return None, "%s；curl 回退亦失败: %s" % (err, err2)


def torrent_name(task):
    bt = task.get("bittorrent")
    if isinstance(bt, dict):
        inner = bt.get("info")
        if isinstance(inner, dict) and inner.get("name"):
            return inner["name"]
    return ""


def task_name(task):
    name = torrent_name(task)
    if name:
        return name
    files = task.get("files")
    if isinstance(files, list):
        for f in files:
            path = (f or {}).get("path") or ""
            if path:
                return os.path.basename(path)
    return task.get("gid") or "未知任务"


def task_progress(task):
    total = num(task.get("totalLength"))
    done = num(task.get("completedLength"))
    if total <= 0:
        total = 0
        done = 0
        files = task.get("files")
        if isinstance(files, list):
            for f in files:
                total += num((f or {}).get("length"))
                done += num((f or {}).get("completedLength"))
    return total, done


def is_normal_complete(task):
    """是否为『正常下载完整』: 状态 complete 或仍处于做种状态。"""
    if task.get("seeder") == "true":
        return True
    return (task.get("status") or "").strip() == "complete"


def classify(task):
    """判定已停止的任务是否需要继续下载，返回 (是否重试, 跳过原因)。"""
    status = (task.get("status") or "").strip()
    if is_normal_complete(task):
        return False, "正常下载完成"
    total, done = task_progress(task)
    full = total > 0 and done >= total
    if status == "error":
        # 报错停下的一律视为未完成(磁盘写满 / 校验失败 / 中断等，进度也可能刚好 100%)
        return True, ""
    if status == "removed":
        # 被移除: 未下载完整的需要继续，进度已满的视为正常收尾
        if full:
            return False, "已移除且进度已满"
        return True, ""
    if full:
        return False, "状态未知且进度已满"
    return True, ""


def flatten_trackers(task):
    result = []
    seen = set()
    bt = task.get("bittorrent")
    announce = bt.get("announceList") if isinstance(bt, dict) else None
    if isinstance(announce, list):
        for tier in announce:
            if not isinstance(tier, list):
                continue
            for uri in tier:
                if isinstance(uri, str) and uri and uri not in seen:
                    seen.add(uri)
                    result.append(uri)
    return result


def file_uris(task):
    result = []
    seen = set()
    files = task.get("files")
    if isinstance(files, list):
        for f in files:
            uris = (f or {}).get("uris")
            if not isinstance(uris, list):
                continue
            for u in uris:
                uri = (u or {}).get("uri")
                if uri and uri not in seen:
                    seen.add(uri)
                    result.append(uri)
    return result


def find_local_torrent(task):
    """尽可能找到本地 .torrent 元数据，用它重加比磁力链接更可靠。"""
    candidates = []
    gid = task.get("gid") or ""
    if gid:
        opt, _err = rpc("aria2.getOption", [gid])
        if isinstance(opt, dict) and opt.get("torrent-file"):
            candidates.append(opt["torrent-file"])
    dirpath = task.get("dir") or ""
    name = torrent_name(task)
    info_hash = task.get("infoHash") or ""
    if dirpath:
        if name:
            candidates.append(os.path.join(dirpath, name + ".torrent"))
        if info_hash:
            candidates.append(os.path.join(dirpath, info_hash + ".torrent"))
    files = task.get("files")
    if isinstance(files, list):
        for f in files:
            path = (f or {}).get("path") or ""
            if path:
                candidates.append(path + ".torrent")
    for candidate in candidates:
        try:
            if candidate and os.path.isfile(candidate):
                return candidate
        except OSError:
            continue
    return ""


def build_readd(task):
    """返回 (method, params, desc)；无法自动重试时 method 为 None。"""
    options = {}
    dirpath = task.get("dir") or ""
    if dirpath:
        options["dir"] = dirpath

    torrent_file = find_local_torrent(task)
    if torrent_file:
        try:
            with open(torrent_file, "rb") as fh:
                payload = base64.b64encode(fh.read()).decode("ascii")
            return "aria2.addTorrent", [payload, [], options], "本地种子 %s" % torrent_file
        except OSError:
            pass

    info_hash = task.get("infoHash") or ""
    if info_hash:
        parts = ["magnet:?xt=urn:btih:" + info_hash]
        name = torrent_name(task)
        if name:
            parts.append("dn=" + urllib.parse.quote(name))
        for tracker in flatten_trackers(task)[:20]:
            parts.append("tr=" + urllib.parse.quote(tracker, safe=""))
        return "aria2.addUri", [["&".join(parts)], options], "磁力链接(基于 infoHash)"

    uris = file_uris(task)
    if uris:
        files = task.get("files")
        if isinstance(files, list) and len(files) == 1 and dirpath:
            path = (files[0] or {}).get("path") or ""
            if path:
                rel = os.path.relpath(path, dirpath)
                if rel != "." and not rel.startswith(".."):
                    options["out"] = rel
        return "aria2.addUri", [uris, options], "%d 个下载链接" % len(uris)

    return None, None, "缺少种子 / 链接信息，无法自动重试"


version, ver_err = rpc("aria2.getVersion")
if ver_err:
    print("!! 无法从 Aria2 获取任务状态: %s" % ver_err)
    print("   RPC 端点: %s" % RPC_URL)
    print("   常见原因: 服务未运行 / rpc-listen-port 或 rpc-secret 与运行中的实例不一致。")
    sys.exit(1)

stopped, stop_err = rpc("aria2.tellStopped", [0, 10000])
if stop_err:
    print("!! 查询『已停止』列表失败: %s" % stop_err)
    sys.exit(1)
if not isinstance(stopped, list):
    stopped = []

STATUS_TEXT = {"error": "错误", "removed": "已移除", "complete": "已完成"}

candidates = []
skipped_reasons = {}
for task in stopped:
    need_retry, skip_reason = classify(task)
    if not need_retry:
        skipped_reasons[skip_reason] = skipped_reasons.get(skip_reason, 0) + 1
        continue
    total, done = task_progress(task)
    candidates.append((task, max(total - done, 0)))

# 先落盘: 候选 GID 列表 + 每个可重试任务的 JSON-RPC 请求体(供 bash 侧直接发送)
req_dir = os.path.join(OUT_DIR, "req")
try:
    os.makedirs(req_dir, exist_ok=True)
except OSError:
    pass

try:
    with open(os.path.join(OUT_DIR, "stopped.gids"), "wb") as fh:
        for task, _left in candidates:
            gid = task.get("gid") or ""
            if gid:
                fh.write(gid.encode("utf-8", "surrogateescape") + b"\x00")
except OSError as exc:
    print("!! 无法写入临时文件: %s" % exc)
    sys.exit(1)

for task, _left in candidates:
    gid = task.get("gid") or ""
    if not gid:
        continue
    method, params, desc = build_readd(task)
    if method is None:
        continue
    add_params = ["token:" + RPC_SECRET] if RPC_SECRET else []
    add_params.extend(params)
    purge_params = ["token:" + RPC_SECRET] if RPC_SECRET else []
    purge_params.append(gid)
    try:
        with open(os.path.join(req_dir, gid + ".add.json"), "w", encoding="utf-8") as fh:
            fh.write(json.dumps({"jsonrpc": "2.0", "id": "readd", "method": method, "params": add_params}))
        with open(os.path.join(req_dir, gid + ".purge.json"), "w", encoding="utf-8") as fh:
            fh.write(json.dumps({"jsonrpc": "2.0", "id": "purge", "method": "aria2.removeDownloadResult", "params": purge_params}))
        with open(os.path.join(req_dir, gid + ".meta"), "w", encoding="utf-8") as fh:
            status_text = STATUS_TEXT.get(task.get("status") or "", task.get("status") or "?")
            note = (task.get("errorMessage") or "").strip()
            if (task.get("status") or "") == "removed":
                note = (note + " " if note else "") + "该任务是被移除的(可能由手动操作或转移脚本触发)"
            fh.write("\x1f".join([task_name(task), desc, status_text,
                                   (human(_left) if _left > 0 else "未知"), note]))
    except OSError:
        pass

skip_text = "、".join("%s x%d" % (k, v) for k, v in sorted(skipped_reasons.items())) if skipped_reasons else "无"
print(">> RPC 连接正常: 127.0.0.1:%s" % RPC_PORT)
print(">> 已停止任务 %d 个: 跳过 %s，需继续下载 %d 个。"
      % (len(stopped), skip_text, len(candidates)))

if not candidates:
    print("")
    print("%s>> 无需处理: 已停止列表中不存在『未下载完整』的任务。%s" % (GREEN, NC))
    print("   提示: 若刚刚发生过磁盘写满等错误，请先释放空间，再重新执行本功能。")
    sys.exit(0)

print("")
print(">> 以下任务已停止但并未下载完整，可尝试重新加入下载队列 (清单较长时会分页展示)。")
for _gid in [t.get("gid") or "" for t, _left in candidates]:
    if _gid and not os.path.isfile(os.path.join(req_dir, _gid + ".add.json")):
        print("   提示: 部分任务缺少种子/链接信息，无法自动重试，详情见下方清单。")
        break


PYEOF

    if [ "$scan_rc" -ne 0 ]; then
        echo ""
        echo ">> [失败] 任务扫描未完成 (请查看上方 Python 报错信息) 或无法连接 Aria2，未做任何变更。"
        echo "   ---- 连接诊断 ----"
        rpc_diagnose || true
        rm -rf "${scan_tmp}"
        return 1
    fi

    local gids_file="${scan_tmp}/stopped.gids"
    if [ ! -s "${gids_file}" ]; then
        rm -rf "${scan_tmp}"
        return 0
    fi

    declare -a CAND_GIDS=()
    mapfile -d '' -t CAND_GIDS < "${gids_file}" 2>/dev/null || CAND_GIDS=()
    local total=${#CAND_GIDS[@]}
    if [ "$total" -eq 0 ]; then
        rm -rf "${scan_tmp}"
        return 0
    fi

    # 分页预览候选清单 (仅查看，不在此处确认)
    declare -a CAND_DISPLAY=()
    local _g="" _m="" _n="" _d="" _st="" _lf="" _nt=""
    for _g in "${CAND_GIDS[@]}"; do
        _m=""
        _n=""; _d=""; _st=""; _lf=""; _nt=""
        [ -f "${scan_tmp}/req/${_g}.meta" ] && _m="$(cat "${scan_tmp}/req/${_g}.meta" 2>/dev/null || true)"
        if [ -n "$_m" ]; then
            IFS=$'\x1f' read -r _n _d _st _lf _nt <<< "$_m"
        fi
        [ -n "$_n" ] || _n="$_g"
        [ -n "$_d" ] || _d="未知来源"
        [ -n "$_lf" ] || _lf="未知"
        _lf="${_lf#剩余 }"
        if [ -z "$_m" ]; then
            _nt="缺少种子/链接信息，无法自动重试"
        fi
        CAND_DISPLAY+=("[${_st:-?}] ${_n} — 剩余 ${_lf}${_nt:+ · ${_nt}} (${_d})")
    done
    confirm_paged_list CAND_GIDS "异常停止且未下载完整的任务" 15 CAND_DISPLAY view || true

    local SELECTION
    read -rp "请输入要重试的任务编号 (空格或逗号分隔；直接回车 = 全部 ${total} 个；输入 0 取消): " SELECTION || true
    SELECTION="${SELECTION:-}"
    if [ "$SELECTION" = "0" ]; then
        echo ">> 操作已取消。"
        rm -rf "${scan_tmp}"
        return 0
    fi

    declare -a CHOSEN_GIDS=()
    local token
    if [ -z "$SELECTION" ]; then
        CHOSEN_GIDS=("${CAND_GIDS[@]}")
    else
        local -a TOKENS=()
        read -ra TOKENS <<< "${SELECTION//,/ }"
        for token in "${TOKENS[@]}"; do
            if [[ ! "$token" =~ ^[0-9]+$ ]]; then
                echo "   >> 忽略无效编号: ${token}"
                continue
            fi
            if [ "$token" -lt 1 ] || [ "$token" -gt "$total" ]; then
                echo "   >> 忽略超出范围的编号: ${token} (有效范围 1-${total})"
                continue
            fi
            CHOSEN_GIDS+=("${CAND_GIDS[$((token - 1))]}")
        done
    fi

    if [ ${#CHOSEN_GIDS[@]} -eq 0 ]; then
        echo ">> 未选择任何任务，操作已取消。"
        rm -rf "${scan_tmp}"
        return 0
    fi

    local CONFIRM
    read -rp "确认重新加入以上 ${#CHOSEN_GIDS[@]} 个任务以继续下载? [Y/n 默认: Y]: " CONFIRM || true
    CONFIRM="${CONFIRM:-Y}"
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo ">> 操作已取消。"
        rm -rf "${scan_tmp}"
        return 0
    fi

    echo ""
    echo ">> 正在重新加入任务 (已下载的数据会断点续传保留，不会从头重新下载)..."
    local ok_count=0 fail_count=0
    local gid meta name desc tstatus tleft tnote add_body purge_body resp new_gid err_msg
    for gid in "${CHOSEN_GIDS[@]}"; do
        meta="$(cat "${scan_tmp}/req/${gid}.meta" 2>/dev/null || true)"
        name=""; desc=""; tstatus=""; tleft=""; tnote=""
        if [ -n "$meta" ]; then
            IFS=$'\x1f' read -r name desc tstatus tleft tnote <<< "$meta"
        fi
        [ -n "$name" ] || name="$gid"
        [ -n "$desc" ] || desc="未知来源"

        add_body="${scan_tmp}/req/${gid}.add.json"
        if [ ! -f "${add_body}" ]; then
            echo "   [!] ${name}: 无法自动重试 (缺少种子 / 链接信息)"
            fail_count=$((fail_count + 1))
            continue
        fi

        resp=$(curl -sS -m 20 -X POST -H "Content-Type: application/json" \
            --data-binary @"${add_body}" "http://127.0.0.1:${RPC_PORT}/jsonrpc" 2>/dev/null || true)

        if printf '%s' "${resp}" | grep -q '"result"'; then
            new_gid=$(printf '%s' "${resp}" | sed -n 's/.*"result":"\([^"]*\)".*/\1/p' || true)
            ok_count=$((ok_count + 1))
            echo "   [成功] ${name}: 已重新加入下载队列 [${desc}] -> 新 GID ${new_gid:-未知}"
            # 旧记录已失效，清理以免在『已停止』列表里重复出现
            purge_body="${scan_tmp}/req/${gid}.purge.json"
            if [ -f "${purge_body}" ]; then
                curl -sS -m 20 -X POST -H "Content-Type: application/json" \
                    --data-binary @"${purge_body}" "http://127.0.0.1:${RPC_PORT}/jsonrpc" >/dev/null 2>&1 || true
            fi
        else
            err_msg=$(printf '%s' "${resp}" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p' || true)
            fail_count=$((fail_count + 1))
            echo "   [失败] ${name}: 重新加入失败 (${err_msg:-RPC 无有效响应})"
            if [ -z "${resp}" ]; then
                echo "          (提示: 无法连接 RPC，请确认 Aria2 正在运行)"
            fi
        fi
    done

    echo ""
    if [ "$ok_count" -gt 0 ]; then
        echo ">> [完成] ${ok_count} 个任务已重新加入下载队列，正在断点续传。"
    fi
    if [ "$fail_count" -gt 0 ]; then
        echo ">> [注意] 有 ${fail_count} 个任务未能自动重试，请参考上方原因处理。"
    fi
    echo ">> 可打开 AriaNg 查看: 任务会先『检查中 (Checking)』，随后自动断点续传。"

    rm -rf "${scan_tmp}"
}

# ==================== 模块 9: 实用辅助与清理工具箱 ====================
manage_utils_menu() {
    while true; do
        echo ""
        echo "=========================================="
        echo "        Aria2 辅助运维与清理工具箱        "
        echo "=========================================="
        echo " 1. 清理已完成任务的 .torrent 种子文件 (保留正在下载的种子)"
        echo " 2. 刷新会话/清理历史记录 (停启服务并重置 session)"
        echo " 3. 一键服务与网络健康诊断 (检查端口、进程、防火墙与定时器)"
        echo " 0. 返回上级菜单"
        echo "=========================================="
        read -rp "请选择操作 [0-3 默认: 0]: " UTIL_CHOICE
        UTIL_CHOICE="${UTIL_CHOICE:-0}"

        case "$UTIL_CHOICE" in
            1)
                install_packages findutils coreutils
                check_cmds find || continue
                DEFAULT_CLEAN_DIR=$(get_current_download_dir)
                read -rp "请输入要清理的下载目录路径 [默认: ${DEFAULT_CLEAN_DIR}]: " SCAN_DIR
                SCAN_DIR="${SCAN_DIR:-$DEFAULT_CLEAN_DIR}"
                SCAN_DIR="${SCAN_DIR%/}"

                if [ ! -d "${SCAN_DIR}" ]; then
                    echo "错误: 目录 ${SCAN_DIR} 不存在！"
                    continue
                fi

                echo ">> 正在通过 Aria2 RPC 获取进行中/等待中的任务清单..."
                declare -A ACTIVE_NAMES=()
                local _n=""
                while IFS= read -r _n; do
                    [ -n "$_n" ] && ACTIVE_NAMES["$_n"]=1
                done < <(rpc_active_managed_names 2>/dev/null || true)
                if [ ${#ACTIVE_NAMES[@]} -eq 0 ]; then
                    echo "   提示: 未获取到活动任务清单(服务未运行或 RPC 不可用)，为安全起见本次不执行删除。"
                    continue
                fi

                echo ">> 正在扫描并分析 ${SCAN_DIR} 下的种子文件状态..."
                mapfile -t ALL_TORRENTS < <(find "${SCAN_DIR}" -type f -name "*.torrent")

                if [ ${#ALL_TORRENTS[@]} -eq 0 ]; then
                    echo "提示: 在指定目录下没有找到任何 .torrent 文件。"
                    continue
                fi

                declare -a SAFE_TO_DELETE=()
                local _tname=""
                for tor in "${ALL_TORRENTS[@]}"; do
                    base_name="${tor%.torrent}"
                    _tname=$(printf '%s' "$(basename "$base_name")" | tr '[:upper:]' '[:lower:]')
                    # 保护策略(aria2-next 无 .aria2 控制文件，以 RPC 清单为准):
                    #   1) 名称命中进行中/等待中任务
                    #   2) aria2 自己保存的 <sha1>.torrent 元数据
                    #   3) 旧版安装遗留的 .aria2 控制文件
                    if [ -n "${ACTIVE_NAMES[$_tname]}" ]; then
                        continue
                    fi
                    if [[ "$_tname" =~ ^[0-9a-f]{40}$ ]]; then
                        continue
                    fi
                    if [ -f "${base_name}.aria2" ] || [ -f "${tor}.aria2" ]; then
                        continue
                    fi

                    SAFE_TO_DELETE+=("${tor}")
                done

                if [ ${#SAFE_TO_DELETE[@]} -eq 0 ]; then
                    echo ">> 扫描完成！未检测到可清理的已完成种子 (所有种子任务均正在下载中或未找到对应项)。"
                    continue
                fi

                declare -a DEL_DISPLAY=()
                local _it=""
                for _it in "${SAFE_TO_DELETE[@]}"; do
                    DEL_DISPLAY+=("${_it#"${SCAN_DIR}/"}")
                done
                if confirm_paged_list SAFE_TO_DELETE "已下载完成 / 无活跃下载任务的种子文件 (将被删除)" 15 DEL_DISPLAY; then
                    for item in "${SAFE_TO_DELETE[@]}"; do
                        rm -f "$item"
                    done
                    echo ">> 清理完成！已释放空间。"
                else
                    echo ">> 操作已取消。"
                fi
                ;;

            2)
                echo ">> 正在安全压缩与清理 aria2.session 会话..."
                stop_aria2_safely
                if [ -f "${SESSION_FILE}" ]; then
                    cp "${SESSION_FILE}" "${SESSION_FILE}.bak"
                    echo ">> 已备份原会话为: ${SESSION_FILE}.bak"
                fi
                svc_start
                echo ">> Aria2 服务已重启，会话记录已刷新。"
                ;;

            3)
                echo ""
                echo "=== Aria2 服务与网络健康诊断 ==="
                echo "1. Aria2 核心服务状态: "
                if svc_is_active; then
                    echo -e "\033[32m[运行中]\033[0m"
                else
                    echo -e "\033[31m[未运行]\033[0m"
                fi

                echo -n "2. RPC 端口监听: "
                RPC_P=$(grep -E "^rpc-listen-port=" "${CONF_FILE}" 2>/dev/null | cut -d'=' -f2- | tr -d ' \r')
                RPC_P="${RPC_P:-6800}"
                if ss -tuln | grep -q ":${RPC_P} "; then
                    echo -e "\033[32m[端口 ${RPC_P} 正常监听]\033[0m"
                else
                    echo -e "\033[33m[端口 ${RPC_P} 未检测到监听]\033[0m"
                fi

                echo -n "3. Caddy 反代前端状态: "
                if ${SUDO_CMD} systemctl is-active --quiet caddy 2>/dev/null; then
                    echo -e "\033[32m[运行中]\033[0m"
                else
                    echo -e "\033[37m[未安装或未运行]\033[0m"
                fi

                echo -n "4. Trackers 定时更新 ($(tracker_interval_text "$(current_tracker_interval)")): "
                if ${SYSTEMCTL_CMD} is-active --quiet aria2-update-tracker.timer 2>/dev/null; then
                    echo -e "\033[32m[已启用]\033[0m"
                else
                    echo -e "\033[31m[未启用]\033[0m"
                fi

                echo -n "5. 吸血 Peer 防火墙拦截: "
                if systemctl is-active --quiet aria2-peer-blocker.timer 2>/dev/null; then
                    echo -e "\033[32m[已开启]\033[0m"
                else
                    echo -e "\033[37m[未开启]\033[0m"
                fi

                echo -n "6. BT 自动筛选下载服务: "
                if ${SYSTEMCTL_CMD} is-active --quiet aria2-filter.service 2>/dev/null; then
                    echo -e "\033[32m[已开启]\033[0m"
                else
                    echo -e "\033[37m[未开启]\033[0m"
                fi
                echo "================================"
                ;;

            0)
                break
                ;;

            *)
                echo "无效选项。"
                ;;
        esac
    done
}

# ==================== 模块 10: 日志查看与故障排查 ====================
manage_logs_menu() {
    while true; do
        echo ""
        echo "=========================================="
        echo "        Aria2 日志排查与故障分析          "
        echo "=========================================="
        echo " 1. 实时跟踪 Aria2 运行日志 (aria2.log 最后50行/动态)"
        echo " 2. 查看 Systemd 服务崩溃/启动日志 (journalctl 最近记录)"
        echo " 3. 前台单次测试启动 Aria2 (精准定位段错误 SEGV 与配置解析异常)"
        echo " 4. 查看 Trackers 自动更新日志 (最近执行记录)"
        echo " 5. 查看 吸血 Peer 防火墙更新日志 (最近执行记录)"
        echo " 6. 查看 Caddy 反代 Web 前端日志"
        echo " 7. 查看 BT 自动筛选服务运行日志"
        echo " 0. 返回上级菜单"
        echo "=========================================="
        read -rp "请选择操作 [0-7 默认: 0]: " LOG_CHOICE
        LOG_CHOICE="${LOG_CHOICE:-0}"

        case "$LOG_CHOICE" in
            1)
                echo ""
                if [ ! -f "${LOG_FILE}" ]; then
                    echo "提示: 当前未检测到日志文件: ${LOG_FILE} (可能尚未产生日志或未完成安装)"
                else
                    local _lt="" _follow=""
                    _lt=$(mktemp)
                    tail -n 200 "${LOG_FILE}" > "${_lt}" 2>&1 || true
                    preview_file_paged "aria2.log 最近 200 行" "${_lt}" 30
                    rm -f "${_lt}"
                    read -rp "是否继续实时跟踪日志 (按 Ctrl+C 退出跟踪)? [y/N 默认: N]: " _follow || true
                    if [[ "${_follow:-N}" =~ ^[Yy]$ ]]; then
                        echo ">> 正在实时跟踪 ${LOG_FILE} (按 Ctrl+C 退出)..."
                        tail -n 0 -f "${LOG_FILE}" || true
                    fi
                fi
                ;;
            2)
                echo ""
                local _lt2=""
                _lt2=$(mktemp)
                if is_docker_mode; then
                    { svc_logs 2>&1 || true; } > "${_lt2}"
                    preview_file_paged "容器 ${ARIA2_DOCKER_NAME} 最近日志" "${_lt2}" 30
                else
                    {
                        ${SYSTEMCTL_CMD} status aria2.service --no-pager -l 2>&1 || true
                        echo ""
                        echo ">> journalctl 最近 40 行错误信息:"
                        svc_logs 2>&1 || true
                    } > "${_lt2}"
                    preview_file_paged "Aria2 服务状态与最近日志" "${_lt2}" 30
                fi
                rm -f "${_lt2}"
                ;;
            3)
                echo ""
                if is_docker_mode; then
                    echo ">> Docker 模式下无法前台运行 (容器已由 Docker 托管)。"
                    echo "   如需前台调试，请使用:"
                    echo "     docker run --rm -it --network host -e PUID=\$(id -u) -e PGID=\$(id -g) \\"
                    echo "       -v ${ARIA2_CONF_DIR}:${ARIA2_CONF_DIR} -v $(get_current_download_dir):$(get_current_download_dir) \\"
                    echo "       ${ARIA2_DOCKER_IMAGE}:${ARIA2_DOCKER_TAG} --conf-path=${CONF_FILE}"
                else
                    echo ">> 正在临时停止后台服务准备前台测试..."
                    ${SYSTEMCTL_CMD} stop aria2.service 2>/dev/null || true
                    sleep 0.5
                    echo ">> 开始前台执行: ${ARIA2C_BIN} --conf-path=${CONF_FILE}"
                    echo ">> 提示: 按 Ctrl+C 即可终止前台运行并自动恢复后台守护进程。"
                    echo "---------------------------------------------------------"
                    if [ -x "${ARIA2C_BIN}" ]; then
                        "${ARIA2C_BIN}" --conf-path="${CONF_FILE}" || true
                    else
                        echo "错误: 未找到可执行文件 ${ARIA2C_BIN}"
                    fi
                    echo "---------------------------------------------------------"
                    echo ">> 正在恢复后台 Aria2 服务..."
                    ${SYSTEMCTL_CMD} start aria2.service
                    echo ">> 后台服务已恢复。"
                fi
                ;;
            4)
                local _lt4=""
                _lt4=$(mktemp)
                if [ "$IS_ROOT" = true ]; then
                    { journalctl -u aria2-update-tracker.service -n 60 --no-pager 2>&1 || true; } > "${_lt4}"
                else
                    { journalctl --user -u aria2-update-tracker.service -n 60 --no-pager 2>&1 || true; } > "${_lt4}"
                fi
                preview_file_paged "Tracker 更新服务最近记录" "${_lt4}" 30
                rm -f "${_lt4}"
                ;;
            5)
                local _lt5=""
                _lt5=$(mktemp)
                { ${SUDO_CMD} journalctl -u aria2-peer-blocker.service -n 60 --no-pager 2>/dev/null || echo "尚未配置或未运行该服务"; } > "${_lt5}"
                preview_file_paged "吸血 Peer 防火墙更新记录" "${_lt5}" 30
                rm -f "${_lt5}"
                ;;
            6)
                local _lt6=""
                _lt6=$(mktemp)
                { ${SUDO_CMD} journalctl -u caddy -n 60 --no-pager 2>/dev/null || echo "尚未安装 Caddy 服务"; } > "${_lt6}"
                preview_file_paged "Caddy 服务日志" "${_lt6}" 30
                rm -f "${_lt6}"
                ;;
            7)
                local _lt7="" _follow7=""
                _lt7=$(mktemp)
                if [ "$IS_ROOT" = true ]; then
                    { journalctl -u aria2-filter.service -n 40 --no-pager 2>&1 || true; } > "${_lt7}"
                else
                    { journalctl --user -u aria2-filter.service -n 40 --no-pager 2>&1 || true; } > "${_lt7}"
                fi
                preview_file_paged "BT 自动筛选守护进程日志" "${_lt7}" 30
                rm -f "${_lt7}"
                read -rp "是否继续实时跟踪该日志 (按 Ctrl+C 退出跟踪)? [y/N 默认: N]: " _follow7 || true
                if [[ "${_follow7:-N}" =~ ^[Yy]$ ]]; then
                    if [ "$IS_ROOT" = true ]; then
                        journalctl -u aria2-filter.service -n 0 -f
                    else
                        journalctl --user -u aria2-filter.service -n 0 -f
                    fi
                fi
                ;;
            0)
                break
                ;;
            *)
                echo "无效选项。"
                ;;
        esac
    done
}

# ==================== 模块 11: 单独安装/更新 AriaNg (使用 Caddy) ====================
install_ariang() {
    local target_rpc_port="$1"

    echo ""
    echo "=========================================="
    echo "     安装 / 更新 AriaNg 前端 (Caddy 反代)  "
    echo "=========================================="

    if [ -z "$target_rpc_port" ]; then
        if [ -f "${CONF_FILE}" ]; then
            target_rpc_port=$(grep -E "^rpc-listen-port=" "${CONF_FILE}" | cut -d'=' -f2- | tr -d ' \r')
        fi
        target_rpc_port="${target_rpc_port:-$DEFAULT_PORT}"
        read -rp "请输入后端的 Aria2 RPC 端口 [默认: ${target_rpc_port}]: " INPUT_TARGET_PORT
        target_rpc_port="${INPUT_TARGET_PORT:-$target_rpc_port}"
    fi

    read -rp "请输入 AriaNg 网页访问端口 [默认: ${DEFAULT_ARIANG_PORT}]: " INPUT_ARIANG_PORT
    ARIANG_PORT="${INPUT_ARIANG_PORT:-$DEFAULT_ARIANG_PORT}"

    ensure_caddy
    install_packages curl wget unzip

    echo ">> 正在从 GitHub 官方 API 探测 AriaNg 最新版本..."
    ARIANG_API="https://api.github.com/repos/mayswind/AriaNg/releases/latest"
    ARIANG_TAG=$(curl -sSL --connect-timeout 10 -m 20 "${ARIANG_API}" | grep -Po '"tag_name":\s*"\K[^"]*' || true)

    if [ -z "$ARIANG_TAG" ]; then
        echo ">> 提示: 获取官方 API 失败或受速率限制，启用兜底版本 1.3.14"
        ARIANG_TAG="1.3.14"
    else
        echo ">> 成功获取到最新版本: ${ARIANG_TAG}"
    fi

    echo ">> 正在下载 AriaNg (${ARIANG_TAG} All-In-One)..."
    mkdir -p "${ARIANG_DIR}"
    chmod o+rx "${USER_HOME}" "${ARIA2_CONF_DIR}" "${ARIANG_DIR}" 2>/dev/null || true

    ARIANG_DL_URL="${GH_PROXY}/mayswind/AriaNg/releases/download/${ARIANG_TAG}/AriaNg-${ARIANG_TAG}-AllInOne.zip"
    TMP_ARIANG=$(mktemp -d)
    wget -q --show-progress -O "${TMP_ARIANG}/ariang.zip" "${ARIANG_DL_URL}"
    unzip -qo "${TMP_ARIANG}/ariang.zip" -d "${ARIANG_DIR}"
    chmod -R o+r "${ARIANG_DIR}"
    rm -rf "${TMP_ARIANG}"

    echo ">> 配置 Caddyfile (route 优先反代: :${ARIANG_PORT} -> RPC: ${target_rpc_port})..."
    ${SUDO_CMD} mkdir -p /etc/caddy
    ${SUDO_CMD} bash -c "cat > /etc/caddy/Caddyfile" <<EOF
:${ARIANG_PORT} {
    route {
        reverse_proxy /jsonrpc* 127.0.0.1:${target_rpc_port}
        root * ${ARIANG_DIR}
        file_server
    }
}
EOF

    echo ">> 启动 / 重启 Caddy 服务..."
    ${SUDO_CMD} systemctl daemon-reload
    ${SUDO_CMD} systemctl enable --now caddy
    ${SUDO_CMD} systemctl restart caddy

    echo ""
    echo ">> AriaNg (${ARIANG_TAG}) 配置完成并已启动！"
    echo "=========================================="
    echo "单端口 SSH 隧道建立命令 (本地电脑执行):"
    echo "  ssh -L 127.0.0.1:${ARIANG_PORT}:127.0.0.1:${ARIANG_PORT} ${CURRENT_USER}@<你的服务器IP>"
    echo ""
    echo "本地浏览器设置方式:"
    echo "  1. 打开 http://127.0.0.1:${ARIANG_PORT}"
    echo "  2. 点击左侧 [AriaNg 设置] -> 切换到 [RPC (localhost:6800)] 标签页"
    echo "  3. 修改项:"
    echo "     - Aria2 RPC 地址:      127.0.0.1 (或 localhost)"
    echo "     - Aria2 RPC 端口:      ${ARIANG_PORT}  (务必改成 ${ARIANG_PORT}，非 6800)"
    echo "     - Aria2 RPC 请求路径:  jsonrpc"
    echo "     - Aria2 RPC 密钥:      输入你在 aria2.conf 中设置的 rpc-secret"
    echo "  4. 刷新页面，即可成功连接！"
    echo "=========================================="
}

# ==================== 模块 12: 单独卸载 AriaNg ====================
uninstall_ariang() {
    echo ""
    echo "=========================================="
    echo "            卸载 AriaNg 前端              "
    echo "=========================================="
    read -rp "确定要卸载 AriaNg 前端吗? [y/N 默认: N]: " CONFIRM
    CONFIRM="${CONFIRM:-N}"
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "已取消。"
        return 0
    fi

    echo ">> 正在停止并禁用 caddy 服务..."
    ${SUDO_CMD} systemctl stop caddy 2>/dev/null || true
    ${SUDO_CMD} systemctl disable caddy 2>/dev/null || true

    echo ">> 正在清理 Caddyfile 与 AriaNg 静态文件..."
    ${SUDO_CMD} rm -f /etc/caddy/Caddyfile
    rm -rf "${ARIANG_DIR}"

    remove_caddy_package

    echo ">> AriaNg 前端卸载流程已完成。"
}

# ==================== 模块 14: BT 自动筛选下载管理 (支持按大小及格式过滤) ====================
manage_video_filter() {
    echo ""
    echo "=========================================="
    echo "       BT 自动筛选下载管理 (大小与类型过滤)  "
    echo "=========================================="

    if [ ! -f "${CONF_FILE}" ]; then
        echo "错误: 未找到配置文件 ${CONF_FILE}，请先安装 Aria2！"
        return 1
    fi

    local IS_FILTER_ACTIVE=false
    if ${SYSTEMCTL_CMD} is-active --quiet aria2-filter.service 2>/dev/null; then
        IS_FILTER_ACTIVE=true
    fi

    echo -n "当前自动筛选守护服务状态: "
    if [ "$IS_FILTER_ACTIVE" = true ]; then
        echo -e "\033[32m已启用 (正在实时过滤新下载任务)\033[0m"
    else
        echo -e "\033[31m未启用 (Inactive)\033[0m"
    fi
    echo ""

    echo " 1. 开启 / 重新配置自动筛选守护服务"
    echo " 2. 停止并禁用自动筛选守护服务"
    echo " 3. 查看实时筛选过滤日志"
    echo " 0. 返回上级菜单"
    read -rp "请选择操作 [0-3 默认: 0]: " FILTER_CHOICE
    FILTER_CHOICE="${FILTER_CHOICE:-0}"

    case "$FILTER_CHOICE" in
        1)
            install_packages python3
            
            read -rp "请输入需要保留的文件最小体积 (MB) [默认: 50]: " INPUT_MIN_MB
            INPUT_MIN_MB="${INPUT_MIN_MB:-50}"
            if ! [[ "$INPUT_MIN_MB" =~ ^[0-9]+$ ]] || [ "$INPUT_MIN_MB" -le 0 ]; then
                echo ">> 输入无效，已回退为默认值 50 MB。"
                INPUT_MIN_MB=50
            fi

            echo ""
            echo "请选择文件类型过滤模式:"
            echo " 1. 仅按体积筛选所有类型 (默认: 只要 >= ${INPUT_MIN_MB}MB 的文件都下载，不限类型)"
            echo " 2. 仅下载常见视频格式 (mp4, mkv, ts, avi, mov, flv, wmv, m4v, rmvb, iso)"
            echo " 3. 自定义需要保留的文件后缀名 (如: mp4,mkv,zip,iso)"
            read -rp "请选择 [1-3 默认: 1]: " TYPE_CHOICE
            TYPE_CHOICE="${TYPE_CHOICE:-1}"

            TARGET_EXTS="ALL"
            if [ "$TYPE_CHOICE" == "2" ]; then
                TARGET_EXTS=".mp4,.mkv,.ts,.avi,.mov,.flv,.wmv,.m4v,.rmvb,.iso"
            elif [ "$TYPE_CHOICE" == "3" ]; then
                read -rp "请输入自定义文件后缀名 (英文逗号分隔，例如: mp4,mkv,zip): " USER_EXTS
                if [ -n "$USER_EXTS" ]; then
                    TARGET_EXTS="$USER_EXTS"
                else
                    echo ">> 输入为空，将默认保留所有大于 ${INPUT_MIN_MB}MB 的文件。"
                    TARGET_EXTS="ALL"
                fi
            fi

            local NEED_RESTART_ARIA2=false

            # 注: 旧版的 bt-remove-unselected-file 已被 aria2-next 移除，
            #     未勾选文件由 RPC select-file 控制，不再下载到磁盘。
            if ! grep -q "^max-overall-upload-limit=" "${CONF_FILE}"; then
                echo "max-overall-upload-limit=2M" >> "${CONF_FILE}"
                echo "max-upload-limit=2M" >> "${CONF_FILE}"
                NEED_RESTART_ARIA2=true
            fi

            if [ "$NEED_RESTART_ARIA2" = true ]; then
                svc_restart
            fi

            ensure_filter_script "${INPUT_MIN_MB}" "${TARGET_EXTS}"
            [ "$IS_ROOT" = false ] && mkdir -p "${SYSTEMD_DIR}"

            # Docker 模式下不存在 aria2.service 单元，用 Wants/After docker 代替 Requires，
            # 避免筛选守护因缺少依赖单元而无法启动 (筛选器通过本地 RPC 与容器通信)
            local FILTER_DEP_LINES="After=network.target aria2.service
Requires=aria2.service"
            if is_docker_mode; then
                FILTER_DEP_LINES="After=network.target docker.service
Wants=docker.service"
            fi

            cat > "${SYSTEMD_DIR}/aria2-filter.service" <<EOF
[Unit]
Description=Aria2 BT Automatic Filter Daemon
${FILTER_DEP_LINES}

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${FILTER_SCRIPT}
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

            ${SYSTEMCTL_CMD} daemon-reload
            ${SYSTEMCTL_CMD} enable --now aria2-filter.service
            ${SYSTEMCTL_CMD} restart aria2-filter.service

            echo ""
            echo ">> BT 自动筛选服务已成功配置并启动！"
            echo "   体积阈值: >= ${INPUT_MIN_MB} MB"
            if [ "$TARGET_EXTS" == "ALL" ]; then
                echo "   格式过滤: 任意格式 (只要满足大小即可)"
            else
                echo "   格式过滤: 仅限 [${TARGET_EXTS}]"
            fi
            echo "   未选文件: 通过 RPC select-file 勾选，未勾选文件不会下载 (aria2-next 原生)"
            echo "   上传限速: 全局最大 2MB/s (max-overall-upload-limit=2M)"
            ;;
        2)
            echo ">> 正在停止并禁用筛选守护服务..."
            ${SYSTEMCTL_CMD} stop aria2-filter.service 2>/dev/null || true
            ${SYSTEMCTL_CMD} disable aria2-filter.service 2>/dev/null || true
            rm -f "${SYSTEMD_DIR}/aria2-filter.service"
            ${SYSTEMCTL_CMD} daemon-reload
            echo ">> 自动筛选服务已关闭。"
            ;;
        3)
            local _fv="" _follow_fv=""
            _fv=$(mktemp)
            if [ "$IS_ROOT" = true ]; then
                { journalctl -u aria2-filter.service -n 60 --no-pager 2>&1 || true; } > "${_fv}"
            else
                { journalctl --user -u aria2-filter.service -n 60 --no-pager 2>&1 || true; } > "${_fv}"
            fi
            preview_file_paged "BT 自动筛选守护进程日志" "${_fv}" 30
            rm -f "${_fv}"
            read -rp "是否继续实时跟踪日志 (按 Ctrl+C 退出跟踪)? [y/N 默认: N]: " _follow_fv || true
            if [[ "${_follow_fv:-N}" =~ ^[Yy]$ ]]; then
                echo ">> 正在实时跟踪 (按 Ctrl+C 退出)..."
                if [ "$IS_ROOT" = true ]; then
                    journalctl -u aria2-filter.service -n 0 -f
                else
                    journalctl --user -u aria2-filter.service -n 0 -f
                fi
            fi
            ;;
        0)
            return 0
            ;;
        *)
            echo "无效选项。"
            ;;
    esac
}

# ==================== 模块 15: 扫描并清理小文件工具 (支持分页预览 / 自动跳过 .torrent) ====================
clean_small_files_menu() {
    echo ""
    echo "=========================================="
    echo "      清理下载目录下的小文件 (防误删)     "
    echo "=========================================="

    local DEF_CLEAN_DIR
    install_packages findutils coreutils
    check_cmds find stat || return 1
    DEF_CLEAN_DIR=$(get_current_download_dir)

    read -rp "请输入要扫描清理的目录路径 [默认: ${DEF_CLEAN_DIR}]: " TARGET_DIR
    TARGET_DIR="${TARGET_DIR:-$DEF_CLEAN_DIR}"
    TARGET_DIR="${TARGET_DIR%/}"

    if [ ! -d "${TARGET_DIR}" ]; then
        echo "错误: 目录 '${TARGET_DIR}' 不存在！"
        return 1
    fi

    read -rp "请输入文件大小门槛 (小于该大小的文件将被清理, 单位 MB) [默认: 50]: " SIZE_MB
    SIZE_MB="${SIZE_MB:-50}"

    if ! [[ "$SIZE_MB" =~ ^[0-9]+$ ]] || [ "$SIZE_MB" -le 0 ]; then
        echo "错误: 请输入有效的正整数！"
        return 1
    fi

    echo ""
    echo ">> 正在扫描目录: ${TARGET_DIR}"
    echo ">> 过滤条件: 体积严格小于 ${SIZE_MB}MB (即 $((SIZE_MB * 1024 * 1024)) 字节, 自动保护 .torrent 种子及正在下载中的任务)..."

    declare -A ACTIVE_TASKS
    local _act="" _real=""
    # aria2-next 不再生成 .aria2 控制文件，改用 RPC 任务清单的绝对路径保护未完成数据
    while IFS= read -r _act; do
        [ -n "$_act" ] && ACTIVE_TASKS["$_act"]=1
    done < <(rpc_active_file_paths 2>/dev/null || true)
    if [ ${#ACTIVE_TASKS[@]} -eq 0 ]; then
        echo "   提示: 未获取到 Aria2 活动任务清单 (服务未运行 / RPC 不可达，或当前确实没有正在下载的任务)。"
        read -rp "   继续扫描可能误删正在下载的数据，是否继续? [y/N 默认: N]: " CONTINUE_NO_GUARD
        if [[ ! "${CONTINUE_NO_GUARD:-N}" =~ ^[Yy]$ ]]; then
            echo ">> 已中止，未删除任何文件。"
            return 0
        fi
    fi

    declare -a FILES_TO_DELETE=()
    local TOTAL_BYTES=0
    # find 的 -size 是“向上取整”的单位语义 (例如 -size -50M 实际会漏掉 49.0~49.99MB 的文件)，
    # 无法精确表达“小于 N 字节”。这里先用 -(SIZE_MB+1)M 粗筛 (结果是精确判定的超集)，
    # 再按 stat 得到的真实字节数逐文件精确比较。
    local SIZE_BYTES=$((SIZE_MB * 1024 * 1024))
    local COARSE_MB=$((SIZE_MB + 1))

    while IFS= read -r file; do
        # .torrent 种子与旧版遗留的 .aria2 控制文件一律跳过:
        # 种子元数据统一由主菜单 [9 -> 1] 的专用清理功能处理，避免误删有效种子
        if [[ "$file" == *.aria2 ]] || [[ "$file" == *.torrent ]]; then
            continue
        fi
        # 正在下载 (进行中 / 等待中) 任务的数据文件不删除
        _real=$(realpath "$file" 2>/dev/null || printf '%s' "$file")
        if [ -n "${ACTIVE_TASKS[$_real]}" ] || [ -n "${ACTIVE_TASKS[$file]}" ]; then
            continue
        fi

        local f_size
        f_size=$(stat -c %s "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null || echo 0)
        [[ "$f_size" =~ ^[0-9]+$ ]] || f_size=0
        # 精确判定: 只保留严格小于阈值的文件
        if [ "$f_size" -ge "$SIZE_BYTES" ]; then
            continue
        fi

        FILES_TO_DELETE+=("$file")
        TOTAL_BYTES=$((TOTAL_BYTES + f_size))
    done < <(find "${TARGET_DIR}" -type f -size -"${COARSE_MB}"M 2>/dev/null)

    local FILE_COUNT=${#FILES_TO_DELETE[@]}
    if [ "$FILE_COUNT" -eq 0 ]; then
        echo ""
        echo ">> 扫描完成: 未找到任何严格小于 ${SIZE_MB}MB (${SIZE_BYTES} 字节) 的文件。"
        return 0
    fi

    local TOTAL_HUMAN
    TOTAL_HUMAN=$(awk "BEGIN {printf \"%.2f\", ${TOTAL_BYTES}/1024/1024}")
    echo ""
    echo ">> 扫描完成！共找到 ${FILE_COUNT} 个符合条件的文件 (总计约 ${TOTAL_HUMAN} MB)。"

    # 统一用可翻页清单预览并确认 (条目本身即绝对路径)
    if ! confirm_paged_list FILES_TO_DELETE "严格小于 ${SIZE_MB}MB (${SIZE_BYTES} 字节) 的文件 (将被删除)" 15 ""; then
        echo ">> 操作已取消，未删除任何文件。"
        return 0
    fi

    echo ">> 正在删除文件..."
    for file in "${FILES_TO_DELETE[@]}"; do
        rm -f "$file"
    done

    read -rp "是否顺带清理因删除小文件后遗留的空文件夹? [Y/n 默认: Y]: " CLEAN_EMPTY_DIR
    CLEAN_EMPTY_DIR="${CLEAN_EMPTY_DIR:-Y}"
    if [[ "$CLEAN_EMPTY_DIR" =~ ^[Yy]$ ]]; then
        find "${TARGET_DIR}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        echo ">> 空文件夹已同步清理完毕。"
    fi

    echo ""
    echo ">> [成功] 已清理 ${FILE_COUNT} 个小文件，释放空间约 ${TOTAL_HUMAN} MB！"
    echo "   提示: .torrent 种子文件与正在下载中的任务数据已自动跳过，如需清理种子请使用主菜单 [9 -> 1]。"
}

# ==================== 模块 13: 完整卸载 (全部组件) ====================
uninstall_all() {
    echo ""
    echo "=========================================="
    echo "        卸载 Aria2 与 AriaNg 全部组件     "
    echo "=========================================="
    read -rp "确定要卸载所有相关服务吗? [y/N 默认: N]: " CONFIRM_UNINSTALL
    CONFIRM_UNINSTALL="${CONFIRM_UNINSTALL:-N}"
    if [[ ! "$CONFIRM_UNINSTALL" =~ ^[Yy]$ ]]; then
        echo "已取消卸载。"
        return 0
    fi

    echo ">> 正在停止并禁用 Aria2、定时器、筛选守护 与 Caddy 服务..."
    svc_stop
    ${SYSTEMCTL_CMD} stop aria2-update-tracker.timer 2>/dev/null || true
    ${SYSTEMCTL_CMD} stop aria2-update-tracker.service 2>/dev/null || true
    ${SYSTEMCTL_CMD} stop aria2-filter.service 2>/dev/null || true
    ${SUDO_CMD} systemctl stop aria2-peer-blocker.timer 2>/dev/null || true
    ${SUDO_CMD} systemctl stop aria2-peer-blocker.service 2>/dev/null || true
    ${SUDO_CMD} systemctl stop caddy 2>/dev/null || true

    ${SYSTEMCTL_CMD} disable aria2.service 2>/dev/null || true
    ${SYSTEMCTL_CMD} disable aria2-update-tracker.timer 2>/dev/null || true
    ${SYSTEMCTL_CMD} disable aria2-update-tracker.service 2>/dev/null || true
    ${SYSTEMCTL_CMD} disable aria2-filter.service 2>/dev/null || true
    ${SUDO_CMD} systemctl disable aria2-peer-blocker.timer 2>/dev/null || true
    ${SUDO_CMD} systemctl disable aria2-peer-blocker.service 2>/dev/null || true
    ${SUDO_CMD} systemctl disable caddy 2>/dev/null || true

    echo ">> 正在删除 systemd 服务配置文件..."
    ${SUDO_CMD} rm -f "${SYSTEMD_DIR}/aria2.service"
    ${SUDO_CMD} rm -f "${SYSTEMD_DIR}/aria2-update-tracker.service"
    ${SUDO_CMD} rm -f "${SYSTEMD_DIR}/aria2-update-tracker.timer"
    ${SUDO_CMD} rm -f "${SYSTEMD_DIR}/aria2-filter.service"
    ${SUDO_CMD} rm -f /etc/systemd/system/aria2-peer-blocker.service
    ${SUDO_CMD} rm -f /etc/systemd/system/aria2-peer-blocker.timer
    ${SUDO_CMD} rm -f /etc/caddy/Caddyfile
    ${SYSTEMCTL_CMD} daemon-reload
    ${SUDO_CMD} systemctl daemon-reload 2>/dev/null || true

    if command -v ipset &>/dev/null; then
        echo ">> 正在注销内核防火墙规则..."
        ${SUDO_CMD} iptables -D INPUT -m set --match-set aria2_ban_v4 src -j DROP 2>/dev/null || true
        if command -v ip6tables &>/dev/null; then
            ${SUDO_CMD} ip6tables -D INPUT -m set --match-set aria2_ban_v6 src -j DROP 2>/dev/null || true
        fi
        ${SUDO_CMD} ipset destroy aria2_ban_v4 2>/dev/null || true
        ${SUDO_CMD} ipset destroy aria2_ban_v6 2>/dev/null || true
    fi

    echo ">> 正在删除 aria2c 二进制文件..."
    rm -f "${ARIA2C_BIN}"
    ${SUDO_CMD} rm -f /usr/bin/aria2c /usr/local/bin/aria2c 2>/dev/null || true

    if is_docker_mode; then
        if docker_ensure; then
            echo ">> 正在删除 Docker 容器 ${ARIA2_DOCKER_NAME}..."
            $DOCKER_CMD rm -f "${ARIA2_DOCKER_NAME}" >/dev/null 2>&1 || true
            read -rp "是否同时删除镜像 ${ARIA2_DOCKER_IMAGE}:${ARIA2_DOCKER_TAG}? [y/N 默认: N]: " DEL_IMAGE
            DEL_IMAGE="${DEL_IMAGE:-N}"
            if [[ "$DEL_IMAGE" =~ ^[Yy]$ ]]; then
                $DOCKER_CMD rmi "${ARIA2_DOCKER_IMAGE}:${ARIA2_DOCKER_TAG}" >/dev/null 2>&1 || true
                echo "   镜像已删除。"
            fi
        else
            echo ">> 提示: Docker 不可用，请自行清理容器: docker rm -f ${ARIA2_DOCKER_NAME}"
        fi
        rm -f "${ARIA2_MODE_FILE}" 2>/dev/null || true
    fi

    local CUR_STATE_DIR
    CUR_STATE_DIR=$(get_conf_value "state-dir" "${STATE_DIR}")
    read -rp "是否删除配置及脚本目录 (${ARIA2_CONF_DIR})? [y/N 默认: N]: " DEL_CONFIG
    DEL_CONFIG="${DEL_CONFIG:-N}"
    if [[ "$DEL_CONFIG" =~ ^[Yy]$ ]]; then
        rm -rf "${ARIA2_CONF_DIR}"
        echo "已清理配置目录: ${ARIA2_CONF_DIR}"
    fi

    # aria2-next 的断点/恢复数据目录可能被自定义到其他路径，需单独确认
    if [ -n "${CUR_STATE_DIR}" ] && [ -d "${CUR_STATE_DIR}" ] && [ "${CUR_STATE_DIR}" != "${ARIA2_CONF_DIR}" ]; then
        read -rp "是否同时删除断点/恢复状态目录 (${CUR_STATE_DIR})? [y/N 默认: N]: " DEL_STATE
        DEL_STATE="${DEL_STATE:-N}"
        if [[ "$DEL_STATE" =~ ^[Yy]$ ]]; then
            rm -rf "${CUR_STATE_DIR}"
            echo "已清理断点状态目录: ${CUR_STATE_DIR}"
        fi
    fi

    read -rp "是否清理下载目录? (强烈建议保留) [y/N 默认: N]: " DEL_DOWNLOADS
    DEL_DOWNLOADS="${DEL_DOWNLOADS:-N}"
    if [[ "$DEL_DOWNLOADS" =~ ^[Yy]$ ]]; then
        read -rp "请输入要清空的下载目录绝对路径: " TARGET_DL_DIR
        if [ -n "$TARGET_DL_DIR" ] && [ -d "$TARGET_DL_DIR" ] && [ "$TARGET_DL_DIR" != "/" ] && [ "$TARGET_DL_DIR" != "$USER_HOME" ]; then
            rm -rf "${TARGET_DL_DIR}"
            echo "已删除: ${TARGET_DL_DIR}"
        fi
    fi

    remove_caddy_package

    echo ""
    echo ">> 所有组件与定时器卸载完成。"
}

# ==================== 主入口循环菜单 ====================
# 载入持久化的运行方式(systemd / docker)，供状态展示与服务控制使用
load_run_mode

while true; do
    echo ""
    echo "=========================================="
    echo -e "   ${BOLD}Aria2 & AriaNg 管理脚本${NC}"
    echo "   身份: $([ "$IS_ROOT" = true ] && echo "Root (系统级服务)" || echo "普通用户 ${CURRENT_USER} (用户级服务)")"
    echo "   版本: $(get_aria2_version_text)"
    echo "=========================================="
    echo -e " 服务状态: $(get_aria2_status)    开机自启: $(get_aria2_boot_status)"
    if [ -f "${CONF_FILE}" ]; then
        RPC_P=$(get_conf_value "rpc-listen-port" "6800")
        RPC_SEC=$(get_conf_value "rpc-secret" "未设置")
        DOWN_LIMIT=$(get_conf_value "max-overall-download-limit" "0")
        UP_LIMIT=$(get_conf_value "max-overall-upload-limit" "未限制")
        echo " 下载路径: $(get_current_download_dir)    RPC 端口: ${RPC_P}    RPC 密钥: ${RPC_SEC}"
        echo " 下载限速: $([ "$DOWN_LIMIT" == "0" ] && echo "不限制" || echo "$DOWN_LIMIT")    上传限速: $([ "$UP_LIMIT" == "0" ] && echo "不限制" || echo "$UP_LIMIT")"
    fi
    echo "------------------------------------------"
    MENU_ITEM1=""
    if [ -f "${ARIA2C_BIN}" ] || (is_docker_mode && docker_container_exists); then
        MENU_ITEM1="重新配置 Aria2 后端 (自动带入当前设置)"
    else
        MENU_ITEM1="安装 / 配置 Aria2 后端 (本机预编译 / 源码编译 / Docker 容器)"
    fi
    echo " 1. ${MENU_ITEM1}"
    echo " 2. Aria2 常用核心设置 (下载目录 / 并发数 / 做种 / 上下载限速 / 断点状态目录 / BT 端口)"
    echo " 3. 手动更新 / 设置 BT Trackers (双源拉取 best/all / 自定义)"
    echo " 4. 启用 / 停用 Trackers 自动更新 (默认每周，可设周期)"
    echo " 5. BT 吸血 Peer 防火墙拦截管理 (ipset+iptables / 默认开启 / 每日更新)"
    echo " 6. 迁移下载任务到新磁盘 (迁移 未完成 / 全部 任务并切换工作路径)"
    echo " 7. 转移已完成下载到新磁盘 (含做种与已暂停任务 / 可清理游离文件)"
    echo " 8. 恢复 / 重试未完成的下载 (扫描种子断点续传 / 一键重试异常停止)"
    echo " 9. Aria2 实用辅助与清理工具箱 (清理已完成种子 / 会话刷新 / 健康自检)"
    echo " 10. Aria2 日志排查与故障分析 (实时日志 / 崩溃溯源 / 前台单测)"
    echo " 11. 单独安装 / 更新 AriaNg 前端 (Caddy 反代模式)"
    echo " 12. 单独卸载 AriaNg 前端"
    echo " 13. BT 自动筛选下载管理 (支持按大小及自定义后缀过滤)"
    echo " 14. 扫描并清理下载目录下的小文件 (支持翻页预览 / 防误删)"
    echo " 15. 完整卸载 (Aria2 + AriaNg + 防火墙规则 + 服务全清)"
    echo " 0. 退出"
    echo "=========================================="
    read -rp "请输入操作编号 [0-15 默认: 0]: " MENU_CHOICE
    MENU_CHOICE="${MENU_CHOICE:-0}"

    case "$MENU_CHOICE" in
        1) install_aria2 || true ;;
        2) manage_core_settings || true ;;
        3) update_trackers_menu || true ;;
        4) manage_tracker_timer || true ;;
        5) manage_peer_blocker || true ;;
        6) migrate_downloads || true ;;
        7) archive_completed_files || true ;;
        8) scan_and_resume_torrents || true ;;
        9) manage_utils_menu || true ;;
        10) manage_logs_menu || true ;;
        11) install_ariang || true ;;
        12) uninstall_ariang || true ;;
        13) manage_video_filter || true ;;
        14) clean_small_files_menu || true ;;
        15) uninstall_all || true ;;
        0) echo "已退出。"; exit 0 ;;
        *) echo "无效选项，请重新选择。" ;;
    esac

    if [[ "${MENU_CHOICE:-0}" != "0" ]]; then
        pause_menu
    fi
done