#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
#  FileBrowser Quantum 管理脚本 (基于开源项目 gtsteffaniak/filebrowser)
#  功能: 安装/更新、配置(全局设置 + 源目录增删改)、账号管理、停用/启用、
#        状态查看、卸载
#  项目地址: https://github.com/gtsteffaniak/filebrowser
#  官方文档: https://filebrowserquantum.com
# ===========================================================================

DOWNLOAD_PROXY="https://gitpy.223327.xyz/"
GITHUB_REPO="gtsteffaniak/filebrowser"
SERVICE_NAME="filebrowser"

# ---------------------------- 终端色彩定义 ----------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---------------------------- 环境模式与路径判定 ----------------------------
# 当前执行用户（精简环境下可能不存在 USER 变量）
CURRENT_USER="${USER:-$(id -un 2>/dev/null || printf 'user')}"

if [[ $EUID -eq 0 ]]; then
    IS_ROOT=true
    SYSTEMCTL_CMD="systemctl"
    JOURNALCTL_CMD="journalctl"
    SUDO_CMD=""
    BIN_DIR="/usr/local/bin"
    WORK_DIR="/opt/filebrowser"
    SYSTEMD_DIR="/etc/systemd/system"
    SERVICE_WANTED_BY="multi-user.target"
    DEFAULT_DATA_DIR="/srv"
    LINGER_HINT=""
else
    IS_ROOT=false
    SYSTEMCTL_CMD="systemctl --user"
    JOURNALCTL_CMD="journalctl --user"
    SUDO_CMD=""
    BIN_DIR="${HOME}/.local/bin"
    WORK_DIR="${HOME}/.filebrowser"
    SYSTEMD_DIR="${HOME}/.config/systemd/user"
    SERVICE_WANTED_BY="default.target"
    DEFAULT_DATA_DIR="${HOME}/data"
    LINGER_HINT="loginctl enable-linger ${CURRENT_USER}"

    mkdir -p "${BIN_DIR}"
    if [[ ":$PATH:" != *":${BIN_DIR}:"* ]]; then
        export PATH="${BIN_DIR}:$PATH"
    fi
fi

BIN_PATH="${BIN_DIR}/filebrowser"
CONFIG_FILE="${WORK_DIR}/config.yaml"
SETTINGS_FILE="${WORK_DIR}/settings.conf"
SOURCES_FILE="${WORK_DIR}/sources.conf"
SERVICE_FILE="${SYSTEMD_DIR}/${SERVICE_NAME}.service"

RUN_MODE_TEXT="$([ "$IS_ROOT" = true ] && echo "Root (系统级服务)" || echo "普通用户 ${CURRENT_USER} (用户级服务)")"

# 本脚本通过 systemd 托管服务
if ! command -v systemctl >/dev/null 2>&1; then
    echo -e "${RED}[-] 未检测到 systemctl，本脚本依赖 systemd 托管 FileBrowser 服务。${NC}"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        echo "提示: macOS 可手动下载二进制运行，或使用 Docker / launchd 托管。"
    fi
    exit 1
fi

# ===========================================================================
#                              通用交互辅助
# ===========================================================================

# 读取一行输入（失败即退出，避免 EOF 造成死循环），用法: prompt "提示" 变量名
prompt() {
    local __text="$1" __var="$2" __val=""
    if ! read -rp "$__text" __val; then
        echo ""
        echo -e "${YELLOW}输入已中断，退出脚本。${NC}"
        exit 0
    fi
    printf -v "$__var" '%s' "$__val"
}

# 读取密码（不回显），用法: prompt_secret "提示" 变量名
prompt_secret() {
    local __text="$1" __var="$2" __val=""
    if ! read -rsp "$__text" __val; then
        echo ""
        echo -e "${YELLOW}输入已中断，退出脚本。${NC}"
        exit 0
    fi
    echo ""
    printf -v "$__var" '%s' "$__val"
}

# 暂停并等待用户回车
pause_menu() {
    local __dummy=""
    read -rp "按回车键返回菜单..." __dummy || exit 0
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

download_file() {
    local url="$1" dest="$2"
    if command_exists curl; then
        curl -fL --connect-timeout 15 -m 600 --retry 2 -o "$dest" "$url"
    elif command_exists wget; then
        wget -q --timeout=60 -O "$dest" "$url"
    else
        echo -e "${RED}[-] 系统缺少 curl / wget，无法下载。${NC}" >&2
        return 1
    fi
}

# YAML 双引号转义
yaml_quote() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}

# 将用户输入转换为 YAML 布尔值
yaml_bool() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on|y) printf 'true\n' ;;
        *) printf 'false\n' ;;
    esac
}

# 文件大小（字节）
file_size() {
    local f="$1"
    if stat -c%s "$f" >/dev/null 2>&1; then
        stat -c%s "$f"
    else
        stat -f%z "$f"
    fi
}

# 探测 HTTP 状态码，失败输出 000
http_status() {
    local url="$1" code=""
    if command_exists curl; then
        code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url" 2>/dev/null) || code=""
    elif command_exists wget; then
        code=$(wget -q -S -O /dev/null -T 5 "$url" 2>&1 | awk '/HTTP\//{c=$2} END{print c}') || code=""
    fi
    [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
    printf '%s' "$code"
}

# ===========================================================================
#                              服务状态探测
# ===========================================================================

is_installed() {
    [[ -x "$BIN_PATH" ]]
}

is_service_active() {
    $SYSTEMCTL_CMD is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null
}

is_service_enabled() {
    $SYSTEMCTL_CMD is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null
}

# 已安装的二进制版本号，未安装或读取失败时返回非 0
installed_version() {
    is_installed || return 1
    local out=""
    out=$("$BIN_PATH" version 2>/dev/null \
        | sed -nE '/[Vv]ersion[[:space:]]*:/{s/.*[Vv]ersion[[:space:]]*:[[:space:]]*//;p;q}') || true
    out="${out//$'\r'/}"
    [[ -n "$out" ]] || return 1
    printf '%s' "$out"
}

installed_version_text() {
    local ver=""
    if ver=$(installed_version); then
        printf '%s' "$ver"
    else
        printf '未安装'
    fi
}

# 运行状态（带颜色）
service_state_text() {
    if ! is_installed; then
        printf '%b' "${YELLOW}未安装${NC}"
    elif is_service_active; then
        printf '%b' "${GREEN}运行中${NC}"
    else
        printf '%b' "${RED}已停止${NC}"
    fi
}

# 开机自启状态（带颜色）
service_boot_text() {
    if ! is_installed; then
        printf '%b' "${YELLOW}未安装${NC}"
    elif is_service_enabled; then
        printf '%b' "${GREEN}已启用${NC}"
    else
        printf '%b' "${RED}已停用${NC}"
    fi
}

# 检测端口是否已处于监听状态（无法检测时视为成功）
check_port_listening() {
    local port="$1"
    [[ -n "$port" ]] || return 0
    if command_exists ss; then
        if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"; then
            return 0
        fi
        return 1
    elif command_exists netstat; then
        if netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"; then
            return 0
        fi
        return 1
    fi
    return 0
}

# 检查 HTTP 服务是否可访问
check_http_service() {
    local port="$1" base="$2" code=""
    [[ -n "$port" ]] || return 0
    code=$(http_status "http://127.0.0.1:${port}${base}")
    if [[ "$code" =~ ^(200|30[0-9]|40[0-9])$ ]]; then
        echo -e "${GREEN}[✓] HTTP 自检通过 (状态码 ${code})${NC}"
        return 0
    fi
    echo -e "${YELLOW}[!] HTTP 自检异常 (状态码 ${code})，请查看日志排查。${NC}"
    return 1
}

# ===========================================================================
#                          配置读写 (settings.conf)
# ===========================================================================

get_setting() {
    local key="$1" default="$2" val=""
    if [[ -f "$SETTINGS_FILE" ]]; then
        val=$(grep -E "^${key}=" "$SETTINGS_FILE" 2>/dev/null | tail -n1 | cut -d'=' -f2-) || true
    fi
    if [[ -n "$val" ]]; then
        printf '%s' "$val"
    else
        printf '%s' "$default"
    fi
}

set_setting() {
    local key="$1" val="$2" tmp=""
    mkdir -p "$WORK_DIR"
    touch "$SETTINGS_FILE"
    if grep -qE "^${key}=" "$SETTINGS_FILE" 2>/dev/null; then
        tmp=$(mktemp)
        if SET_KEY="$key" SET_VAL="$val" awk '
            BEGIN { prefix = ENVIRON["SET_KEY"] "=" }
            index($0, prefix) == 1 { print prefix ENVIRON["SET_VAL"]; next }
            { print }
        ' "$SETTINGS_FILE" > "$tmp"; then
            mv -f "$tmp" "$SETTINGS_FILE"
        else
            rm -f "$tmp"
            return 1
        fi
    else
        printf '%s=%s\n' "$key" "$val" >> "$SETTINGS_FILE"
    fi
}

# 配置是否已初始化
config_exists() {
    [[ -f "$SETTINGS_FILE" ]]
}

# ===========================================================================
#                        源目录管理 (sources.conf)
#  存储格式（每行一个源）: 名称|路径|只读(true/false)|默认启用(true/false)
# ===========================================================================

SRC_NAME=""
SRC_PATH=""
SRC_READONLY=""
SRC_ENABLED=""

sources_count() {
    [[ -f "$SOURCES_FILE" ]] || { printf '0'; return 0; }
    local c=""
    c=$(grep -c . "$SOURCES_FILE" 2>/dev/null) || true
    printf '%s' "${c:-0}"
}

parse_source_line() {
    local line="$1" rest=""
    SRC_NAME="${line%%|*}"
    rest="${line#*|}"
    SRC_PATH="${rest%%|*}"
    rest="${rest#*|}"
    SRC_READONLY="${rest%%|*}"
    SRC_ENABLED="${rest#*|}"
}

# 源名称是否已存在
source_exists() {
    local name="$1"
    [[ -f "$SOURCES_FILE" ]] || return 1
    awk -F'|' -v n="$name" '$1 == n { found = 1 } END { exit found ? 0 : 1 }' "$SOURCES_FILE"
}

# 路径是否已被添加
source_path_exists() {
    local path="$1"
    [[ -f "$SOURCES_FILE" ]] || return 1
    awk -F'|' -v p="$path" '$2 == p { found = 1 } END { exit found ? 0 : 1 }' "$SOURCES_FILE"
}

# 按行号（从 1 开始）替换源记录
update_source_line() {
    local idx="$1" newline="$2" tmp=""
    tmp=$(mktemp)
    if UPD_LINE="$newline" awk -v n="$idx" '
        NR == n { print ENVIRON["UPD_LINE"]; next }
        { print }
    ' "$SOURCES_FILE" > "$tmp"; then
        mv -f "$tmp" "$SOURCES_FILE"
    else
        rm -f "$tmp"
        return 1
    fi
}

# 按行号（从 1 开始）删除源记录
delete_source_line() {
    local idx="$1" tmp=""
    tmp=$(mktemp)
    if awk -v n="$idx" 'NR != n' "$SOURCES_FILE" > "$tmp"; then
        mv -f "$tmp" "$SOURCES_FILE"
    else
        rm -f "$tmp"
        return 1
    fi
}

# 列出所有源目录（带颜色与编号）
list_sources_detail() {
    local line="" i=0 flags=""
    if [[ "$(sources_count)" -eq 0 ]]; then
        echo -e "${RED}当前没有任何源目录，FileBrowser 在缺少源目录时无法启动！${NC}"
        return 1
    fi

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        i=$((i + 1))
        parse_source_line "$line"
        flags=""
        [[ "$SRC_READONLY" == "true" ]] && flags="${CYAN}只读${NC}"
        if [[ "$SRC_ENABLED" == "true" ]]; then
            flags="${flags:+${flags} / }${GREEN}新用户默认可见${NC}"
        else
            flags="${flags:+${flags} / }${YELLOW}新用户默认不可见${NC}"
        fi
        echo -e " [${CYAN}${i}${NC}] 名称: ${GREEN}${SRC_NAME}${NC}    属性: ${flags}"
        echo -e "      路径: ${SRC_PATH}"
        if [[ -d "$SRC_PATH" ]]; then
            echo -e "      状态: ${GREEN}目录存在${NC}"
        else
            echo -e "      状态: ${RED}目录不存在${NC}"
        fi
        echo "      ------------------------------------"
    done < "$SOURCES_FILE"
    return 0
}

# 交互选择源编号，结果写入 SELECTED_SOURCE_INDEX
SELECTED_SOURCE_INDEX=0
select_source_index() {
    list_sources_detail || return 1
    local idx=""
    prompt "请输入要操作的源目录编号 [0 取消]: " idx
    if [[ ! "$idx" =~ ^[0-9]+$ ]] || [[ "$idx" -eq 0 ]]; then
        echo -e "${YELLOW}已取消。${NC}"
        return 1
    fi
    if [[ "$idx" -gt "$(sources_count)" ]]; then
        echo -e "${RED}[-] 编号超出范围。${NC}"
        return 1
    fi
    SELECTED_SOURCE_INDEX="$idx"
    return 0
}

# 校验源名称与路径，结果写入 SRC_NAME / SRC_PATH
ask_source_name_path() {
    local default_name="$1" default_path="$2" input=""
    while true; do
        prompt "源目录路径 (服务器上的绝对路径) [默认: ${default_path}]: " input
        SRC_PATH="${input:-$default_path}"
        if [[ -z "$SRC_PATH" || "$SRC_PATH" == *"|"* ]]; then
            echo -e "${RED}路径不能为空且不能包含 | 字符。${NC}"
            continue
        fi
        if [[ "$SRC_PATH" != /* ]]; then
            echo -e "${RED}请填写绝对路径 (以 / 开头)。${NC}"
            continue
        fi
        break
    done

    while true; do
        prompt "源目录显示名称 [默认: ${default_name}]: " input
        SRC_NAME="${input:-$default_name}"
        if [[ -z "$SRC_NAME" || "$SRC_NAME" == *"|"* ]]; then
            echo -e "${RED}名称不能为空且不能包含 | 字符。${NC}"
            continue
        fi
        break
    done
}

# ===========================================================================
#                        生成 config.yaml 配置文件
# ===========================================================================

render_config() {
    mkdir -p "$WORK_DIR"
    if [[ -f "$CONFIG_FILE" ]]; then
        cp -f "$CONFIG_FILE" "${CONFIG_FILE}.bak" 2>/dev/null || true
    fi

    local listen="" port="" base_url="" database="" cache_dir="" site_name="" log_levels="" ffmpeg_path=""
    local cert="" key="" y_tls="" y_update_check=""

    listen=$(get_setting listen "0.0.0.0")
    port=$(get_setting port "8080")
    base_url=$(get_setting baseURL "/")
    database=$(get_setting database "${WORK_DIR}/database.db")
    cache_dir=$(get_setting cacheDir "${WORK_DIR}/cache")
    site_name=$(get_setting siteName "FileBrowser Quantum")
    log_levels=$(get_setting logLevels "info|warning|error")
    ffmpeg_path=$(get_setting ffmpegPath "")
    cert=$(get_setting tlsCert "${WORK_DIR}/cert.pem")
    key=$(get_setting tlsKey "${WORK_DIR}/key.pem")
    y_tls=$(yaml_bool "$(get_setting tls false)")
    y_update_check=$(yaml_bool "$(get_setting disableUpdateCheck false)")

    mkdir -p "$cache_dir" 2>/dev/null || true
    mkdir -p "$(dirname "$database")" 2>/dev/null || true

    {
        echo "# ==============================================================="
        echo "# FileBrowser Quantum 配置文件"
        echo "# 由 filebrowser_manager.sh 于 $(date '+%Y-%m-%d %H:%M:%S') 自动生成"
        echo "# 手工修改的内容可能在下次执行管理脚本时被覆盖"
        echo "# 文档: https://filebrowserquantum.com"
        echo "# ==============================================================="
        echo "server:"
        echo "  listen: $(yaml_quote "$listen")"
        echo "  port: ${port}"
        echo "  baseURL: $(yaml_quote "$base_url")"
        echo "  database: $(yaml_quote "$database")"
        echo "  cacheDir: $(yaml_quote "$cache_dir")"
        echo "  disableUpdateCheck: ${y_update_check}"
        if [[ "$y_tls" == "true" ]]; then
            echo "  tlsCert: $(yaml_quote "$cert")"
            echo "  tlsKey: $(yaml_quote "$key")"
        fi
        echo "  logging:"
        echo "    - levels: $(yaml_quote "$log_levels")"
        echo "      output: \"stdout\""
        echo "  sources:"
        if [[ "$(sources_count)" -eq 0 ]]; then
            echo "    []"
        else
            local line=""
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                parse_source_line "$line"
                echo "    - name: $(yaml_quote "$SRC_NAME")"
                echo "      path: $(yaml_quote "$SRC_PATH")"
                echo "      config:"
                if [[ "$SRC_READONLY" == "true" ]]; then
                    echo "        readOnly: true"
                fi
                if [[ "$SRC_ENABLED" == "true" ]]; then
                    echo "        defaultEnabled: true"
                fi
                if [[ "$SRC_READONLY" != "true" && "$SRC_ENABLED" != "true" ]]; then
                    echo "        denyByDefault: false"
                fi
            done < "$SOURCES_FILE"
        fi
        echo "auth:"
        echo "  methods:"
        echo "    password:"
        echo "      enabled: true"
        echo "frontend:"
        echo "  name: $(yaml_quote "$site_name")"
        if [[ -n "$ffmpeg_path" ]]; then
            echo "integrations:"
            echo "  media:"
            echo "    ffmpegPath: $(yaml_quote "$ffmpeg_path")"
            echo "    debug: false"
            echo "    extractEmbeddedSubtitles: false"
        fi
    } > "$CONFIG_FILE"

    echo -e "${GREEN}[✓] 配置文件已生成: ${CONFIG_FILE}${NC}"
    warn_if_no_source
}

# 重启服务使配置生效（服务未安装时静默跳过）
restart_service_if_possible() {
    if ! is_installed || [[ ! -f "$SERVICE_FILE" ]]; then
        return 0
    fi
    $SYSTEMCTL_CMD daemon-reload 2>/dev/null || true
    if ! $SYSTEMCTL_CMD restart "${SERVICE_NAME}.service" 2>/dev/null; then
        echo -e "${YELLOW}[!] 服务重启失败，请检查配置后执行: ${SYSTEMCTL_CMD} status ${SERVICE_NAME}${NC}"
        return 1
    fi
    echo -e "${GREEN}[✓] 服务已重启以应用新配置。${NC}"
    return 0
}

# 配置变更后询问是否重启服务
ask_restart_service() {
    if ! is_installed || [[ ! -f "$SERVICE_FILE" ]]; then
        return 0
    fi
    local choice=""
    prompt "是否立即重启服务以应用配置? [Y/n 默认: Y]: " choice
    if [[ "$choice" =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}提示: 配置已保存，稍后可在菜单中停用/启用服务使其生效。${NC}"
        return 0
    fi
    restart_service_if_possible || true
}

# 提示没有源目录的风险
warn_if_no_source() {
    if [[ "$(sources_count)" -eq 0 ]]; then
        echo -e "${RED}警告: 当前没有任何源目录，FileBrowser 将无法启动！${NC}"
    fi
}

# ===========================================================================
#                          平台识别与版本查询
# ===========================================================================

# 输出形如 linux-amd64 / linux-armv7 的产物标识
detect_platform() {
    local os="" arch=""
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os" in
        linux|darwin) ;;
        *)
            echo -e "${RED}[-] 暂不支持的平台: ${os} (本脚本仅适配 Linux / macOS)${NC}" >&2
            return 1
            ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)            arch="amd64" ;;
        aarch64|arm64)           arch="arm64" ;;
        armv6*)                  arch="armv6" ;;
        armv7*|armv8l)           arch="armv7" ;;
        *)
            echo -e "${RED}[-] 无法识别 CPU 架构: $(uname -m)${NC}" >&2
            return 1
            ;;
    esac

    # 官方仅提供以下平台产物
    case "${os}-${arch}" in
        linux-amd64|linux-arm64|linux-armv6|linux-armv7|darwin-amd64|darwin-arm64) ;;
        *)
            echo -e "${RED}[-] 官方未提供 ${os}-${arch} 的二进制产物，请参考官方文档手动部署。${NC}" >&2
            return 1
            ;;
    esac

    printf '%s-%s' "$os" "$arch"
}

# 查询最新 Release 标签，失败返回非 0
# 注意: 下载代理通常只代理 github.com / raw.githubusercontent.com，
#      不代理 api.github.com，因此优先从 releases 页面重定向中解析版本号。
fetch_latest_tag() {
    local tag="" effective="" \
        page_url="https://github.com/${GITHUB_REPO}/releases/latest" \
        api_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

    # 1) 经代理访问 releases/latest，从重定向后的地址中提取标签
    effective=$(curl -sIL --connect-timeout 10 -m 30 -o /dev/null -w '%{url_effective}' \
        "${DOWNLOAD_PROXY}${page_url}" 2>/dev/null) || effective=""
    tag=$(printf '%s' "$effective" | sed -nE 's#.*/releases/tag/([^/?#]+).*#\1#p')

    # 2) 直连 GitHub API
    if [[ -z "$tag" ]]; then
        tag=$(curl -fsSL --connect-timeout 10 -m 30 "$api_url" 2>/dev/null \
            | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | sed -nE 's/.*"([^"]*)"$/\1/p;q') || tag=""
    fi

    # 3) 直连 releases 页面
    if [[ -z "$tag" ]]; then
        effective=$(curl -sIL --connect-timeout 10 -m 30 -o /dev/null -w '%{url_effective}' \
            "$page_url" 2>/dev/null) || effective=""
        tag=$(printf '%s' "$effective" | sed -nE 's#.*/releases/tag/([^/?#]+).*#\1#p')
    fi

    [[ -n "$tag" ]] || return 1
    printf '%s' "$tag"
}

# ===========================================================================
#                            FFmpeg 探测与安装
# ===========================================================================

install_ffmpeg() {
    if command_exists ffmpeg; then
        echo -e "${GREEN}[✓] 检测到系统已存在 FFmpeg: $(ffmpeg -version 2>/dev/null | head -n1)${NC}"
        return 0
    fi

    echo "[*] 尝试安装 FFmpeg..."
    if [[ "$IS_ROOT" == false ]]; then
        if command_exists sudo; then
            echo "提示: 普通用户安装系统级 FFmpeg 需要提权..."
            SUDO_CMD="sudo"
        else
            echo -e "${YELLOW}[-] 当前用户无 root 权限且未检测到 sudo，跳过 FFmpeg 安装。${NC}"
            return 1
        fi
    fi

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}" in
            ubuntu|debian)
                $SUDO_CMD apt-get update -y
                $SUDO_CMD apt-get install -y ffmpeg
                ;;
            centos|rhel|almalinux|rocky)
                $SUDO_CMD dnf install -y epel-release || $SUDO_CMD yum install -y epel-release || true
                $SUDO_CMD dnf install -y ffmpeg || $SUDO_CMD yum install -y ffmpeg || true
                ;;
            fedora)
                $SUDO_CMD dnf install -y ffmpeg
                ;;
            arch|manjaro)
                $SUDO_CMD pacman -Sy --noconfirm ffmpeg
                ;;
            alpine)
                $SUDO_CMD apk update
                $SUDO_CMD apk add ffmpeg
                ;;
            *)
                echo -e "${YELLOW}[-] 无法自动识别当前系统的包管理器，请手动安装 ffmpeg。${NC}"
                return 1
                ;;
        esac
    else
        echo -e "${YELLOW}[-] 无法获取系统发行版信息，跳过 FFmpeg 安装。${NC}"
        return 1
    fi

    if command_exists ffmpeg; then
        echo -e "${GREEN}[✓] FFmpeg 安装成功！${NC}"
        return 0
    fi
    echo -e "${YELLOW}[-] FFmpeg 安装未完成，本次跳过媒体增强。${NC}"
    return 1
}

# ===========================================================================
#                        安装 / 更新 FileBrowser 二进制
# ===========================================================================

download_and_install_binary() {
    local platform="$1" tmp="" size=0 archive_url="" direct_url=""
    mkdir -p "$BIN_DIR"
    tmp=$(mktemp)

    archive_url="${DOWNLOAD_PROXY}https://github.com/${GITHUB_REPO}/releases/latest/download/${platform}-filebrowser"
    direct_url="https://github.com/${GITHUB_REPO}/releases/latest/download/${platform}-filebrowser"

    echo "[*] 正在下载 ${platform} 二进制 (约 25MB，经代理: ${DOWNLOAD_PROXY})..."
    if ! download_file "$archive_url" "$tmp"; then
        echo -e "${YELLOW}[!] 代理下载失败，尝试直连 GitHub...${NC}"
        rm -f "$tmp"
        tmp=$(mktemp)
        if ! download_file "$direct_url" "$tmp"; then
            echo -e "${RED}[-] 下载失败，请检查网络或手动下载: ${direct_url}${NC}"
            rm -f "$tmp"
            return 1
        fi
    fi

    # 代理异常时可能返回 HTML 错误页，这里做基本校验
    size=$(file_size "$tmp")
    if [[ -z "$size" || "$size" -lt 1000000 ]]; then
        echo -e "${RED}[-] 下载内容异常 (大小 ${size} 字节)，安装包可能无效。${NC}"
        rm -f "$tmp"
        return 1
    fi

    chmod 755 "$tmp"
    mv -f "$tmp" "$BIN_PATH"
    echo -e "${GREEN}[✓] 已安装到 ${BIN_PATH}${NC}"
    return 0
}

# 首次配置向导
initial_config_wizard() {
    echo ""
    echo "------------------------------------------"
    echo -e "         ${BOLD}FileBrowser 基础配置向导${NC}"
    echo "------------------------------------------"
    echo "工作目录: ${WORK_DIR}"

    local listen="" port="" base_url="" src_path="" site_name="" enable_ff=""
    prompt "监听地址 [默认: 0.0.0.0]: " listen
    listen="${listen:-0.0.0.0}"

    while true; do
        prompt "Web 访问端口 [默认: 8080]: " port
        port="${port:-8080}"
        if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 && "$port" -le 65535 ]]; then
            break
        fi
        echo -e "${RED}端口必须是 1-65535 之间的数字。${NC}"
    done

    prompt "URL 前缀 (反代子路径时填写，如 /files) [默认: /]: " base_url
    base_url="${base_url:-/}"

    prompt "站点名称 (浏览器标题/PWA 名称) [默认: FileBrowser Quantum]: " site_name
    site_name="${site_name:-FileBrowser Quantum}"

    set_setting listen "$listen"
    set_setting port "$port"
    set_setting baseURL "$base_url"
    set_setting siteName "$site_name"
    set_setting database "$(get_setting database "${WORK_DIR}/database.db")"
    set_setting cacheDir "$(get_setting cacheDir "${WORK_DIR}/cache")"
    set_setting logLevels "$(get_setting logLevels "info|warning|error")"
    set_setting disableUpdateCheck "$(get_setting disableUpdateCheck false)"
    set_setting tls "$(get_setting tls false)"
    set_setting tlsCert "$(get_setting tlsCert "${WORK_DIR}/cert.pem")"
    set_setting tlsKey "$(get_setting tlsKey "${WORK_DIR}/key.pem")"
    mkdir -p "$(get_setting cacheDir "${WORK_DIR}/cache")" 2>/dev/null || true

    echo ""
    echo "------------------------------------------"
    echo -e "         ${BOLD}配置第一个源目录${NC}"
    echo "------------------------------------------"
    touch "$SOURCES_FILE"
    if [[ "$(sources_count)" -eq 0 ]]; then
        ask_source_name_path "$(basename "${DEFAULT_DATA_DIR%/}")" "$DEFAULT_DATA_DIR"
        local ro="" en=""
        prompt "该源是否只读 (不允许修改/上传)? [y/N 默认: N]: " ro
        prompt "新用户默认是否可见该源? [Y/n 默认: Y]: " en
        local src_ro="false" src_en="true"
        [[ "$ro" =~ ^[Yy]$ ]] && src_ro="true"
        [[ "$en" =~ ^[Nn]$ ]] && src_en="false"
        mkdir -p "$SRC_PATH" 2>/dev/null || true
        printf '%s|%s|%s|%s\n' "$SRC_NAME" "$SRC_PATH" "$src_ro" "$src_en" >> "$SOURCES_FILE"
        echo -e "${GREEN}[✓] 已添加源目录: ${SRC_NAME} -> ${SRC_PATH}${NC}"
    else
        echo "[-] 已存在源目录配置，跳过创建 (可在主菜单的源目录管理中调整)。"
    fi

    echo ""
    prompt "是否启用 FFmpeg (视频/图片转码与缩略图增强)? [y/N 默认: N]: " enable_ff
    if [[ "$enable_ff" =~ ^[Yy]$ ]]; then
        if install_ffmpeg; then
            set_setting ffmpegPath "$(dirname "$(command -v ffmpeg)")"
            echo -e "${GREEN}[✓] 已启用 FFmpeg: $(get_setting ffmpegPath "")${NC}"
        else
            set_setting ffmpegPath ""
            echo -e "${YELLOW}[!] FFmpeg 未启用。${NC}"
        fi
    else
        set_setting ffmpegPath "$(get_setting ffmpegPath "")"
    fi

    render_config
}

install_or_update_filebrowser() {
    echo ""
    echo "=========================================="
    echo -e "      ${BOLD}安装 / 更新 FileBrowser 服务${NC}"
    echo "=========================================="
    echo "执行身份: ${RUN_MODE_TEXT}"
    echo "工作目录: ${WORK_DIR}"

    local platform="" cur_ver="" latest_tag=""
    platform=$(detect_platform) || return 1

    cur_ver=$(installed_version) || cur_ver=""
    latest_tag=$(fetch_latest_tag) || latest_tag=""

    echo "目标平台:   ${platform}"
    echo "当前版本:   ${cur_ver:-未安装}"
    echo "最新版本:   ${latest_tag:-未知 (将直接拉取 latest 产物)}"
    echo "------------------------------------------"

    local need_download=true skip_download=false
    if [[ -n "$cur_ver" && -n "$latest_tag" && "$cur_ver" == "$latest_tag" ]]; then
        local choice=""
        prompt "当前已是最新版本 ${cur_ver}，是否重新下载安装? [y/N 默认: N]: " choice
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            need_download=false
            skip_download=true
            echo -e "${GREEN}[✓] 跳过下载，继续服务配置。${NC}"
        fi
    fi

    echo ""
    echo "[1/4] 准备目录与二进制程序..."
    mkdir -p "$WORK_DIR"
    if [[ "$need_download" == true ]]; then
        download_and_install_binary "$platform" || return 1
    elif [[ "$skip_download" == true ]]; then
        echo "[-] 保留现有二进制: ${BIN_PATH}"
    fi

    echo ""
    echo "[2/4] 检查配置..."
    touch "$SOURCES_FILE"
    if config_exists; then
        echo "已检测到配置文件: ${CONFIG_FILE}"
        local reconf="" addsrc=""
        prompt "是否重新执行基础配置向导 (覆盖现有全局设置)? [y/N 默认: N]: " reconf
        if [[ "$reconf" =~ ^[Yy]$ ]]; then
            initial_config_wizard
        else
            prompt "是否需要新增源目录? [y/N 默认: N]: " addsrc
            if [[ "$addsrc" =~ ^[Yy]$ ]]; then
                add_source_interactive || true
            fi
            render_config
        fi
    else
        if [[ -f "$CONFIG_FILE" ]]; then
            echo -e "${YELLOW}提示: 检测到已有 config.yaml 但非本脚本生成，将备份为 config.yaml.bak 后重新生成。${NC}"
        fi
        initial_config_wizard
    fi

    echo ""
    echo "[3/4] 写入 systemd 服务文件..."
    mkdir -p "$SYSTEMD_DIR"
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=FileBrowser Quantum
Documentation=https://filebrowserquantum.com
After=network.target

[Service]
Type=simple
WorkingDirectory=${WORK_DIR}
ExecStart=${BIN_PATH} -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=${SERVICE_WANTED_BY}
EOF
    echo "[✓] 服务文件: ${SERVICE_FILE}"

    echo ""
    echo "[4/4] 启用并启动服务..."
    $SYSTEMCTL_CMD daemon-reload 2>/dev/null || true
    if ! $SYSTEMCTL_CMD enable "${SERVICE_NAME}.service" 2>/dev/null; then
        echo -e "${YELLOW}[!] 设置开机自启失败，请检查 systemd 环境。${NC}"
    fi
    if ! $SYSTEMCTL_CMD start "${SERVICE_NAME}.service" 2>/dev/null; then
        $SYSTEMCTL_CMD restart "${SERVICE_NAME}.service" 2>/dev/null || true
    fi

    # 普通用户需要常驻会话支持，否则退出 SSH 后服务会被终止
    if [[ "$IS_ROOT" == false ]] && command_exists loginctl; then
        echo "提示: 启用用户常驻进程 (Linger)，保证退出 SSH 后服务继续运行..."
        loginctl enable-linger "$CURRENT_USER" 2>/dev/null \
            || echo -e "${YELLOW}注意: 未能自动开启 linger，可联系管理员执行: sudo ${LINGER_HINT}${NC}"
    fi

    sleep 2
    local port="" base_url=""
    port=$(get_setting port "8080")
    base_url=$(get_setting baseURL "/")
    echo ""
    echo "=========================================="
    echo -e "       ${GREEN}FileBrowser 安装/更新完成！${NC}"
    echo "=========================================="
    echo -e " 服务状态: $(service_state_text)    开机自启: $(service_boot_text)"

    if ! check_port_listening "$port"; then
        echo -e "${YELLOW}[!] 未检测到端口 ${port} 处于监听状态，请查看日志排查。${NC}"
    else
        check_http_service "$port" "$base_url" || true
    fi

    echo " 可执行文件: ${BIN_PATH}"
    echo " 配置文件:   ${CONFIG_FILE}"
    echo " 数据目录:   ${WORK_DIR} (数据库 + 缓存)"
    echo " 访问地址:   http://<服务器IP>:${port}${base_url}"
    local i=0 line=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        i=$((i + 1))
        parse_source_line "$line"
        echo " 源目录 ${i}:   ${SRC_NAME} -> ${SRC_PATH}"
    done < "$SOURCES_FILE"
    echo -e " 初始账号:   ${YELLOW}admin / admin${NC} (首次启动自动创建，请登录后立即修改)"
    echo " 管理命令:"
    if [[ "$IS_ROOT" == true ]]; then
        echo "   查看状态: systemctl status ${SERVICE_NAME}"
        echo "   查看日志: journalctl -u ${SERVICE_NAME} -f"
    else
        echo "   查看状态: systemctl --user status ${SERVICE_NAME}"
        echo "   查看日志: journalctl --user -u ${SERVICE_NAME} -f"
    fi
    echo "=========================================="
    return 0
}

# ===========================================================================
#                            全局配置管理
# ===========================================================================

edit_setting() {
    local key="$1" desc="$2" current="$3" input=""
    prompt "${desc} [当前: ${current}] (留空保持不变): " input
    if [[ -z "$input" ]]; then
        echo -e "${YELLOW}[-] 未修改。${NC}"
        return 1
    fi
    set_setting "$key" "$input"
    echo -e "${GREEN}[✓] 已更新 ${key} = ${input}${NC}"
    return 0
}

edit_port_setting() {
    local current="" input=""
    current=$(get_setting port "8080")
    while true; do
        prompt "Web 访问端口 [当前: ${current}] (留空保持不变): " input
        if [[ -z "$input" ]]; then
            echo -e "${YELLOW}[-] 未修改。${NC}"
            return 1
        fi
        if [[ "$input" =~ ^[0-9]+$ ]] && [[ "$input" -ge 1 && "$input" -le 65535 ]]; then
            break
        fi
        echo -e "${RED}端口必须是 1-65535 之间的数字。${NC}"
    done
    set_setting port "$input"
    echo -e "${GREEN}[✓] 已更新 port = ${input}${NC}"
    return 0
}

# 交互切换某个布尔配置项（留空保持不变）
toggle_setting() {
    local key="$1" desc="$2" current="" input=""
    current=$(yaml_bool "$(get_setting "$key" false)")
    prompt "是否启用${desc}? [y/N 默认保持当前(${current})]: " input
    if [[ -z "$input" ]]; then
        echo -e "${YELLOW}[-] 未修改。${NC}"
        return 1
    fi
    if [[ "$input" =~ ^[Yy]$ ]]; then
        set_setting "$key" true
        echo -e "${GREEN}[✓] 已启用 ${key}。${NC}"
    else
        set_setting "$key" false
        echo -e "${GREEN}[✓] 已关闭 ${key}。${NC}"
    fi
    return 0
}

edit_tls_setting() {
    local current="" choice=""
    current=$(yaml_bool "$(get_setting tls false)")
    echo "当前 HTTPS(TLS) 状态: ${current}"
    prompt "是否启用 TLS (https)? [y/N 默认保持当前]: " choice
    if [[ -z "$choice" ]]; then
        echo -e "${YELLOW}[-] 未修改。${NC}"
        return 1
    fi

    if [[ "$choice" =~ ^[Yy]$ ]]; then
        local cert="" key=""
        cert=$(get_setting tlsCert "${WORK_DIR}/cert.pem")
        key=$(get_setting tlsKey "${WORK_DIR}/key.pem")
        prompt "证书文件路径 [默认: ${cert}]: " cert
        cert="${cert:-$(get_setting tlsCert "${WORK_DIR}/cert.pem")}"
        prompt "私钥文件路径 [默认: ${key}]: " key
        key="${key:-$(get_setting tlsKey "${WORK_DIR}/key.pem")}"
        set_setting tls true
        set_setting tlsCert "$cert"
        set_setting tlsKey "$key"
        echo -e "${GREEN}[✓] 已启用 TLS，证书: ${cert}${NC}"
    else
        set_setting tls false
        echo -e "${GREEN}[✓] 已关闭 TLS。${NC}"
    fi
    return 0
}

show_config_file() {
    echo ""
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}未找到配置文件: ${CONFIG_FILE}${NC}"
        return 1
    fi
    echo "------------------------------------------"
    echo "配置文件: ${CONFIG_FILE}"
    echo "------------------------------------------"
    cat "$CONFIG_FILE"
    echo "------------------------------------------"
    echo "备注: 账号与权限信息保存在数据库 ${WORK_DIR} 中，不在本文件内。"
    return 0
}

configure_filebrowser() {
    if ! config_exists; then
        echo -e "${RED}[-] 未检测到配置 (${SETTINGS_FILE})，请先执行安装。${NC}"
        return 0
    fi

    local choice=""
    while true; do
        echo ""
        echo "=========================================="
        echo -e "      ${BOLD}FileBrowser 全局配置${NC}"
        echo "=========================================="
        echo "  1. 监听地址 (listen)      : $(get_setting listen "0.0.0.0")"
        echo "  2. 访问端口 (port)        : $(get_setting port "8080")"
        echo "  3. URL 前缀 (baseURL)     : $(get_setting baseURL "/")"
        echo "  4. 站点名称 (name)        : $(get_setting siteName "FileBrowser Quantum")"
        echo "  5. 数据库路径 (database)  : $(get_setting database "${WORK_DIR}/database.db")"
        echo "  6. 缓存目录 (cacheDir)    : $(get_setting cacheDir "${WORK_DIR}/cache")"
        echo "  7. 日志级别 (levels)      : $(get_setting logLevels "info|warning|error")"
        echo "  8. HTTPS/TLS (tls)        : $(yaml_bool "$(get_setting tls false)")"
        echo "  9. 关闭更新检查           : $(yaml_bool "$(get_setting disableUpdateCheck false)")"
        echo " 10. FFmpeg 路径 (ffmpegPath): $(get_setting ffmpegPath "<未启用>")"
        echo " 11. 查看当前配置文件"
        echo " 12. 重新生成配置文件"
        echo "  0. 返回上级菜单"
        echo "=========================================="
        prompt "请输入操作编号 [0-12 默认: 0]: " choice
        choice="${choice:-0}"

        local changed=true
        case "$choice" in
            1) edit_setting listen "监听地址 (0.0.0.0 表示全部网卡)" "$(get_setting listen "0.0.0.0")" || changed=false ;;
            2) edit_port_setting || changed=false ;;
            3) edit_setting baseURL "URL 前缀 (如 / 或 /files)" "$(get_setting baseURL "/")" || changed=false ;;
            4) edit_setting siteName "站点名称" "$(get_setting siteName "FileBrowser Quantum")" || changed=false ;;
            5) edit_setting database "数据库文件路径 (.db)" "$(get_setting database "${WORK_DIR}/database.db")" || changed=false ;;
            6) edit_setting cacheDir "缓存目录路径" "$(get_setting cacheDir "${WORK_DIR}/cache")" || changed=false ;;
            7) edit_setting logLevels "日志级别 (info|warning|error|debug 组合)" "$(get_setting logLevels "info|warning|error")" || changed=false ;;
            8) edit_tls_setting || changed=false ;;
            9) toggle_setting disableUpdateCheck "关闭版本更新检查" || changed=false ;;
            10)
                local ff_path="" current_ff=""
                current_ff=$(get_setting ffmpegPath "")
                prompt "FFmpeg 所在目录 (留空表示不启用) [当前: ${current_ff:-<未启用>}]: " ff_path
                if [[ -z "$ff_path" ]]; then
                    set_setting ffmpegPath ""
                    echo -e "${GREEN}[✓] 已关闭 FFmpeg 媒体增强。${NC}"
                elif [[ -x "${ff_path}/ffmpeg" ]]; then
                    set_setting ffmpegPath "$ff_path"
                    echo -e "${GREEN}[✓] 已设置 ffmpegPath = ${ff_path}${NC}"
                else
                    echo -e "${RED}[-] 该目录下未找到可执行的 ffmpeg，未修改。${NC}"
                    changed=false
                fi
                ;;
            11) show_config_file ;;
            12)
                render_config
                changed=false
                ;;
            0) return 0 ;;
            *)
                echo -e "${RED}输入无效，请重新选择。${NC}"
                changed=false
                ;;
        esac

        if [[ "$changed" == true && "$choice" != "11" ]]; then
            render_config >/dev/null
            ask_restart_service
        fi
        if [[ "$choice" != "0" ]]; then
            pause_menu
        fi
    done
}

# ===========================================================================
#                          源目录管理（增 / 改 / 删）
# ===========================================================================

# 新增源目录（供安装流程与源目录管理共用）
add_source_interactive() {
    local default_name="" default_path="" ro="" en=""
    default_name=$(basename "${DEFAULT_DATA_DIR%/}")
    default_path="$DEFAULT_DATA_DIR"

    ask_source_name_path "$default_name" "$default_path"

    if source_exists "$SRC_NAME"; then
        echo -e "${RED}[-] 源名称 ${SRC_NAME} 已存在，请更换。${NC}"
        return 1
    fi
    if source_path_exists "$SRC_PATH"; then
        echo -e "${RED}[-] 路径 ${SRC_PATH} 已添加过，请勿重复添加。${NC}"
        return 1
    fi

    prompt "该源是否只读 (不允许修改/上传)? [y/N 默认: N]: " ro
    prompt "新用户默认是否可见该源? [Y/n 默认: Y]: " en

    local src_ro="false" src_en="true"
    [[ "$ro" =~ ^[Yy]$ ]] && src_ro="true"
    [[ "$en" =~ ^[Nn]$ ]] && src_en="false"

    mkdir -p "$SRC_PATH" 2>/dev/null || true
    touch "$SOURCES_FILE"
    printf '%s|%s|%s|%s\n' "$SRC_NAME" "$SRC_PATH" "$src_ro" "$src_en" >> "$SOURCES_FILE"
    echo -e "${GREEN}[✓] 已添加源目录: ${SRC_NAME} -> ${SRC_PATH}${NC}"
    return 0
}

modify_source_interactive() {
    select_source_index || return 1
    local idx="$SELECTED_SOURCE_INDEX" line=""
    line=$(awk -v n="$idx" 'NR == n' "$SOURCES_FILE")
    parse_source_line "$line"

    local cur_name="$SRC_NAME" cur_path="$SRC_PATH"
    local cur_ro="$SRC_READONLY" cur_en="$SRC_ENABLED"
    echo ""
    echo "正在修改源目录: ${cur_name} (${cur_path})"
    echo "------------------------------------------"

    local input="" new_name="$cur_name" new_path="$cur_path"

    prompt "显示名称 [当前: ${cur_name}] (留空保持不变): " input
    if [[ -n "$input" ]]; then
        if [[ "$input" == *"|"* ]]; then
            echo -e "${RED}名称不能包含 | 字符，保持原名称。${NC}"
        elif [[ "$input" != "$cur_name" ]] && source_exists "$input"; then
            echo -e "${RED}名称 ${input} 已存在，保持原名称。${NC}"
        else
            new_name="$input"
        fi
    fi

    prompt "目录路径 [当前: ${cur_path}] (留空保持不变): " input
    if [[ -n "$input" ]]; then
        if [[ "$input" != /* ]]; then
            echo -e "${RED}请填写绝对路径，保持原路径。${NC}"
        elif [[ "$input" == *"|"* ]]; then
            echo -e "${RED}路径不能包含 | 字符，保持原路径。${NC}"
        else
            new_path="$input"
            mkdir -p "$new_path" 2>/dev/null || true
        fi
    fi

    local new_ro="$cur_ro" new_en="$cur_en"
    prompt "只读模式 [当前: ${cur_ro}] (y=只读 / n=可写 / 留空保持): " input
    if [[ "$input" =~ ^[Yy]$ ]]; then
        new_ro="true"
    elif [[ "$input" =~ ^[Nn]$ ]]; then
        new_ro="false"
    fi

    prompt "新用户默认可见 [当前: ${cur_en}] (y=可见 / n=不可见 / 留空保持): " input
    if [[ "$input" =~ ^[Yy]$ ]]; then
        new_en="true"
    elif [[ "$input" =~ ^[Nn]$ ]]; then
        new_en="false"
    fi

    update_source_line "$idx" "${new_name}|${new_path}|${new_ro}|${new_en}"
    echo -e "${GREEN}[✓] 源目录已更新。${NC}"
    render_config >/dev/null
    ask_restart_service
    return 0
}

delete_source_interactive() {
    select_source_index || return 1
    local idx="$SELECTED_SOURCE_INDEX" line=""
    line=$(awk -v n="$idx" 'NR == n' "$SOURCES_FILE")
    parse_source_line "$line"

    if [[ "$(sources_count)" -le 1 ]]; then
        echo -e "${YELLOW}提示: 删除最后一个源目录后 FileBrowser 将无法启动，请谨慎操作。${NC}"
    fi

    local choice=""
    prompt "确定移除源目录 ${SRC_NAME} (${SRC_PATH}) 吗? 仅从配置中移除，不会删除文件 [y/N]: " choice
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}已取消。${NC}"
        return 1
    fi

    delete_source_line "$idx"
    echo -e "${GREEN}[✓] 已移除源目录: ${SRC_NAME}${NC}"
    render_config >/dev/null
    ask_restart_service
    return 0
}

manage_sources() {
    if ! config_exists; then
        echo -e "${RED}[-] 未检测到配置 (${SETTINGS_FILE})，请先执行安装。${NC}"
        return 0
    fi

    local choice=""
    while true; do
        echo ""
        echo "=========================================="
        echo -e "        ${BOLD}FileBrowser 源目录管理${NC}"
        echo "=========================================="
        echo "  源目录数量: $(sources_count)"
        echo "------------------------------------------"
        list_sources_detail || true
        echo "------------------------------------------"
        echo "  1. 添加源目录"
        echo "  2. 修改源目录"
        echo "  3. 移除源目录"
        echo "  0. 返回上级菜单"
        echo "=========================================="
        prompt "请输入操作编号 [0-3 默认: 0]: " choice
        choice="${choice:-0}"

        case "$choice" in
            1) add_source_interactive && { render_config >/dev/null; ask_restart_service; } ;;
            2) modify_source_interactive || true ;;
            3) delete_source_interactive || true ;;
            0) return 0 ;;
            *) echo -e "${RED}输入无效，请重新选择。${NC}" ;;
        esac
        if [[ "$choice" != "0" ]]; then
            pause_menu
        fi
    done
}

# ===========================================================================
#                     账号管理（官方 CLI: set -u）
#  说明: 用户可在 Web UI 中完整管理；此处提供创建用户 / 重置密码的快捷方式，
#        执行前会临时停止服务，避免数据库被占用。
# ===========================================================================

# 运行 CLI 用户操作: $1=用户名 $2=密码 $3=是否管理员(y/n)
run_cli_user_op() {
    local username="$1" password="$2" as_admin="$3"
    local was_active=false rc=0 out=""

    if ! is_installed; then
        echo -e "${RED}[-] 未检测到 filebrowser 程序，无法执行账号操作。${NC}"
        return 1
    fi
    if ! config_exists; then
        echo -e "${RED}[-] 未检测到配置 (${SETTINGS_FILE})，请先执行安装。${NC}"
        return 1
    fi

    if is_service_active; then
        was_active=true
        echo "[*] 临时停止服务，避免数据库被占用..."
        $SYSTEMCTL_CMD stop "${SERVICE_NAME}.service" 2>/dev/null || true
        sleep 1
    fi

    local args=("set" "-u" "${username},${password}" "-c" "$CONFIG_FILE")
    if [[ "$as_admin" =~ ^[Yy]$ ]]; then
        args=("set" "-u" "${username},${password}" "-a" "-c" "$CONFIG_FILE")
    fi

    out=$("$BIN_PATH" "${args[@]}" 2>&1) || rc=$?
    # 过滤程序自身打印的日志行，只保留关键结果
    printf '%s\n' "$out" | grep -Ev '^\[(DEBUG|INFO|WARN)\]|^[0-9]{4}/[0-9]{2}/[0-9]{2}' || true

    if [[ $rc -eq 0 ]] && printf '%s' "$out" | grep -qiE 'successfully'; then
        echo -e "${GREEN}[✓] 账号操作完成: ${username}${NC}"
    else
        echo -e "${RED}[-] 账号操作失败 (退出码 ${rc})，请检查上方输出。${NC}"
    fi

    if [[ "$was_active" == true ]]; then
        echo "[*] 重新启动服务..."
        $SYSTEMCTL_CMD start "${SERVICE_NAME}.service" 2>/dev/null || true
    fi

    [[ $rc -eq 0 ]]
}

manage_accounts() {
    if ! config_exists; then
        echo -e "${RED}[-] 未检测到配置 (${SETTINGS_FILE})，请先执行安装。${NC}"
        return 0
    fi

    local choice="" username="" p1="" p2="" input_admin=""
    while true; do
        echo ""
        echo "=========================================="
        echo -e "        ${BOLD}FileBrowser 账号管理 (CLI)${NC}"
        echo "=========================================="
        echo "  1. 创建 / 更新普通用户"
        echo "  2. 创建 / 更新管理员用户"
        echo "  3. 重置管理员密码"
        echo "  0. 返回上级菜单"
        echo "------------------------------------------"
        echo -e "${YELLOW}提示: 用户列表、权限、删除等请在 Web UI 的“设置 → 用户”中完成。${NC}"
        echo "=========================================="
        prompt "请输入操作编号 [0-3 默认: 0]: " choice
        choice="${choice:-0}"

        case "$choice" in
            1|2|3)
                if [[ "$choice" == "3" ]]; then
                    local default_admin=""
                    default_admin=$(get_setting adminUsername "admin")
                    prompt "管理员用户名 [默认: ${default_admin}]: " input_admin
                    username="${input_admin:-$default_admin}"
                else
                    while true; do
                        prompt "用户名 [默认: admin]: " username
                        username="${username:-admin}"
                        if [[ -z "$username" || "$username" == *","* ]]; then
                            echo -e "${RED}用户名不能为空且不能包含英文逗号。${NC}"
                            continue
                        fi
                        break
                    done
                fi

                while true; do
                    prompt_secret "密码 (输入时不显示，至少 5 位): " p1
                    if [[ -z "$p1" ]]; then
                        echo -e "${YELLOW}已取消。${NC}"
                        break
                    fi
                    if [[ "${#p1}" -lt 5 ]]; then
                        echo -e "${RED}密码长度至少 5 位 (受 auth.methods.password.minLength 限制)。${NC}"
                        continue
                    fi
                    prompt_secret "请再次输入密码确认: " p2
                    if [[ "$p1" != "$p2" ]]; then
                        echo -e "${RED}两次输入的密码不一致，请重新输入。${NC}"
                        continue
                    fi
                    break
                done
                if [[ -n "$p1" ]]; then
                    local admin_flag="n"
                    [[ "$choice" == "2" || "$choice" == "3" ]] && admin_flag="y"
                    run_cli_user_op "$username" "$p1" "$admin_flag" || true
                fi
                ;;
            0) return 0 ;;
            *) echo -e "${RED}输入无效，请重新选择。${NC}" ;;
        esac
        if [[ "$choice" != "0" ]]; then
            pause_menu
        fi
    done
}

# ===========================================================================
#                            启用 / 停用服务
# ===========================================================================

enable_filebrowser() {
    echo ""
    echo "=========================================="
    echo -e "        ${BOLD}启用 FileBrowser 服务${NC}"
    echo "=========================================="

    if ! is_installed || [[ ! -f "$SERVICE_FILE" ]]; then
        echo -e "${RED}[-] 未检测到完整安装 (缺少二进制或服务文件)，请先执行安装。${NC}"
        return 0
    fi

    $SYSTEMCTL_CMD daemon-reload 2>/dev/null || true
    if ! $SYSTEMCTL_CMD enable "${SERVICE_NAME}.service" 2>/dev/null; then
        echo -e "${YELLOW}[!] 设置开机自启失败，请检查 systemd 环境。${NC}"
    fi
    if ! $SYSTEMCTL_CMD start "${SERVICE_NAME}.service" 2>/dev/null; then
        $SYSTEMCTL_CMD restart "${SERVICE_NAME}.service" 2>/dev/null || true
    fi

    if [[ "$IS_ROOT" == false ]] && command_exists loginctl; then
        loginctl enable-linger "$CURRENT_USER" 2>/dev/null || true
    fi

    sleep 2
    local port="" base_url=""
    port=$(get_setting port "8080")
    base_url=$(get_setting baseURL "/")
    echo -e "${GREEN}[✓] 服务已启用开机自启并尝试启动。${NC}"
    echo -e " 服务状态: $(service_state_text)    开机自启: $(service_boot_text)"

    if ! check_port_listening "$port"; then
        echo -e "${YELLOW}[!] 未检测到端口 ${port} 处于监听状态，请查看日志排查。${NC}"
    else
        check_http_service "$port" "$base_url" || true
    fi
    echo "=========================================="
    return 0
}

disable_filebrowser() {
    echo ""
    echo "=========================================="
    echo -e "        ${BOLD}停用 FileBrowser 服务${NC}"
    echo "=========================================="

    if ! is_installed && [[ ! -f "$SERVICE_FILE" ]]; then
        echo -e "${YELLOW}[-] 未检测到已安装的服务。${NC}"
        return 0
    fi

    if is_service_active; then
        $SYSTEMCTL_CMD stop "${SERVICE_NAME}.service" 2>/dev/null || true
    fi
    if is_service_enabled; then
        $SYSTEMCTL_CMD disable "${SERVICE_NAME}.service" 2>/dev/null || true
    fi
    $SYSTEMCTL_CMD daemon-reload 2>/dev/null || true

    echo -e "${GREEN}[✓] 服务已停止并取消开机自启，数据与配置保持不变。${NC}"
    echo -e " 服务状态: $(service_state_text)    开机自启: $(service_boot_text)"
    echo "=========================================="
    return 0
}

toggle_service() {
    if is_service_enabled; then
        disable_filebrowser
    else
        enable_filebrowser
    fi
    return 0
}

# ===========================================================================
#                          状态 / 日志 / 配置查看
# ===========================================================================

view_status() {
    echo ""
    echo "=========================================="
    echo -e "        ${BOLD}FileBrowser 运行状态${NC}"
    echo "=========================================="
    echo -e " 执行身份:   ${RUN_MODE_TEXT}"
    echo -e " 安装版本:   $(installed_version_text)"
    echo -e " 服务状态:   $(service_state_text)"
    echo -e " 开机自启:   $(service_boot_text)"
    echo -e " 可执行文件: ${BIN_PATH}"
    echo -e " 配置文件:   ${CONFIG_FILE}"
    echo -e " 数据目录:   ${WORK_DIR}"
    echo -e " 数据库:     $(get_setting database "${WORK_DIR}/database.db")"
    echo -e " 缓存目录:   $(get_setting cacheDir "${WORK_DIR}/cache")"
    echo -e " 监听地址:   $(get_setting listen "0.0.0.0"):$(get_setting port "8080")"
    echo -e " 前缀路径:   $(get_setting baseURL "/")"
    echo -e " 源目录数量: $(sources_count)"
    echo -e " FFmpeg:     $(get_setting ffmpegPath "<未启用>")"
    echo -e " TLS:        $(yaml_bool "$(get_setting tls false)")"
    echo "=========================================="

    if ! is_installed; then
        echo -e "${YELLOW}提示: 尚未安装 FileBrowser，请先选择菜单项 1 进行安装。${NC}"
        return 0
    fi

    local port="" base_url="" code=""
    port=$(get_setting port "8080")
    base_url=$(get_setting baseURL "/")
    code=$(http_status "http://127.0.0.1:${port}${base_url}")
    echo -e " HTTP 自检:  http://127.0.0.1:${port}${base_url} -> ${code}"

    echo ""
    echo "----- systemd 服务详情 -----"
    $SYSTEMCTL_CMD --no-pager -l status "${SERVICE_NAME}.service" 2>&1 | head -n 20 || true

    echo ""
    echo "----- 最近 20 行日志 -----"
    if command_exists journalctl; then
        $JOURNALCTL_CMD --no-pager -n 20 -u "${SERVICE_NAME}.service" 2>&1 || true
    else
        echo -e "${YELLOW}未检测到 journalctl，请查看 ${WORK_DIR} 下的日志或使用 journalctl 兼容工具。${NC}"
    fi
    echo "=========================================="
    return 0
}

# ===========================================================================
#                                卸载
# ===========================================================================

uninstall_filebrowser() {
    echo ""
    echo "=========================================="
    echo -e "        ${BOLD}卸载 FileBrowser${NC}"
    echo "=========================================="
    echo "执行身份: ${RUN_MODE_TEXT}"

    if ! is_installed && [[ ! -f "$SERVICE_FILE" ]] && [[ ! -d "$WORK_DIR" ]]; then
        echo -e "${YELLOW}[-] 未检测到已安装的 FileBrowser。${NC}"
        return 0
    fi

    local confirm=""
    prompt "确定要卸载 FileBrowser 吗? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}已取消卸载。${NC}"
        return 0
    fi

    echo "[1/4] 停止并禁用 systemd 服务..."
    if is_service_active; then
        $SYSTEMCTL_CMD stop "${SERVICE_NAME}.service" 2>/dev/null || true
    fi
    if is_service_enabled; then
        $SYSTEMCTL_CMD disable "${SERVICE_NAME}.service" 2>/dev/null || true
    fi

    echo "[2/4] 清除服务配置与二进制文件..."
    rm -f "$SERVICE_FILE"
    $SYSTEMCTL_CMD daemon-reload 2>/dev/null || true
    $SYSTEMCTL_CMD reset-failed "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "$BIN_PATH"

    echo "[3/4] 处理工作目录..."
    local del_work=""
    prompt "是否删除工作目录 ${WORK_DIR} (含 config.yaml / 数据库 / 缓存)? [y/N]: " del_work
    if [[ "$del_work" =~ ^[Yy]$ ]]; then
        rm -rf "$WORK_DIR"
        echo -e "${GREEN}[✓] 已删除工作目录: ${WORK_DIR}${NC}"
    else
        echo "[-] 保留工作目录: ${WORK_DIR}"
    fi

    echo "[4/4] 处理源目录（浏览的数据目录）..."
    local src_paths=() line=""
    if [[ -f "$SOURCES_FILE" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            parse_source_line "$line"
            src_paths+=("$SRC_PATH")
        done < "$SOURCES_FILE"
    fi

    if [[ ${#src_paths[@]} -gt 0 ]]; then
        echo "当前已配置的源目录:"
        local i=0
        for i in "${!src_paths[@]}"; do
            echo "  $((i + 1)). ${src_paths[$i]}"
        done
    else
        echo "[-] 未记录任何源目录。"
    fi

    local del_data="" target=""
    prompt "是否需要删除某个源目录中的数据? [y/N 默认: N]: " del_data
    if [[ "$del_data" =~ ^[Yy]$ ]]; then
        prompt "请输入要彻底删除的数据目录: " target
        if [[ -z "$target" || ! -d "$target" ]]; then
            echo -e "${YELLOW}[-] 路径无效或目录不存在，跳过删除。${NC}"
        elif [[ "$target" == "/" || "$target" == "/root" || "$target" == "/etc" || "$target" == "/usr" || "$target" == "/var" || "$target" == "/home" || "$target" == "$HOME" ]]; then
            echo -e "${RED}警告: 检测到关键系统/家目录，禁止整目录删除！请手动处理其中的文件。${NC}"
        else
            rm -rf "$target"
            echo -e "${GREEN}[✓] 已删除数据目录: ${target}${NC}"
        fi
    else
        echo "[-] 已保留您的数据目录。"
    fi

    echo ""
    echo "=========================================="
    echo -e "       ${GREEN}FileBrowser 已成功卸载完成！${NC}"
    echo "=========================================="
    return 0
}

# ===========================================================================
#                                主菜单
# ===========================================================================

main_menu() {
    local choice=""
    while true; do
        echo ""
        echo "=========================================="
        echo -e "   ${BOLD}FileBrowser Quantum 管理脚本${NC}"
        echo "   身份: ${RUN_MODE_TEXT}"
        echo "   版本: $(installed_version_text)"
        echo "=========================================="
        echo -e " 服务状态: $(service_state_text)    开机自启: $(service_boot_text)"
        echo " 监听地址: $(get_setting listen "0.0.0.0"):$(get_setting port "8080")   源目录数量: $(sources_count)"
        echo "------------------------------------------"
        echo " 1. 安装 / 更新 FileBrowser"
        echo " 2. 配置 FileBrowser (全局设置)"
        if is_service_enabled; then
            echo " 3. 停用 FileBrowser 服务 (停止并取消开机自启)"
        else
            echo " 3. 启用 FileBrowser 服务"
        fi
        echo " 4. 源目录管理 (添加 / 修改 / 删除)"
        echo " 5. 账号管理 (创建用户 / 重置密码)"
        echo " 6. 查看运行状态 / 日志"
        echo " 7. 卸载 FileBrowser"
        echo " 0. 退出"
        echo "=========================================="
        prompt "请输入操作编号 [0-7 默认: 0]: " choice
        choice="${choice:-0}"

        case "$choice" in
            1) install_or_update_filebrowser || true ;;
            2) configure_filebrowser ;;
            3) toggle_service ;;
            4) manage_sources ;;
            5) manage_accounts ;;
            6) view_status ;;
            7) uninstall_filebrowser ;;
            0)
                echo "退出脚本。"
                exit 0
                ;;
            *) echo -e "${RED}输入无效，请重新选择。${NC}" ;;
        esac

        if [[ "$choice" != "0" ]]; then
            pause_menu
        fi
    done
}

main_menu
