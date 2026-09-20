#!/usr/bin/env bash
set -euo pipefail

# ===========================================================================
#  WebDAV 管理脚本 (基于开源项目 hacdias/webdav)
#  功能: 安装/更新、配置(全局设置 + 账号增删改)、停用/启用、卸载、状态查看
#  项目地址: https://github.com/hacdias/webdav
# ===========================================================================

DOWNLOAD_PROXY="https://gitpy.223327.xyz/"
GITHUB_REPO="hacdias/webdav"
SERVICE_NAME="webdav"

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
    BIN_DIR="/usr/local/bin"
    CONFIG_DIR="/etc/webdav"
    SYSTEMD_DIR="/etc/systemd/system"
    SERVICE_WANTED_BY="multi-user.target"
    DEFAULT_DATA_DIR="/srv/webdav"
    LINGER_HINT=""
else
    IS_ROOT=false
    SYSTEMCTL_CMD="systemctl --user"
    JOURNALCTL_CMD="journalctl --user"
    BIN_DIR="${HOME}/.local/bin"
    CONFIG_DIR="${HOME}/.config/webdav"
    SYSTEMD_DIR="${HOME}/.config/systemd/user"
    SERVICE_WANTED_BY="default.target"
    DEFAULT_DATA_DIR="${HOME}/webdav"
    LINGER_HINT="loginctl enable-linger ${CURRENT_USER}"

    mkdir -p "${BIN_DIR}"
    if [[ ":$PATH:" != *":${BIN_DIR}:"* ]]; then
        export PATH="${BIN_DIR}:$PATH"
    fi
fi

BIN_PATH="${BIN_DIR}/webdav"
CONFIG_FILE="${CONFIG_DIR}/config.yml"
SETTINGS_FILE="${CONFIG_DIR}/settings.conf"
USERS_FILE="${CONFIG_DIR}/users.conf"
SERVICE_FILE="${SYSTEMD_DIR}/${SERVICE_NAME}.service"

RUN_MODE_TEXT="$([ "$IS_ROOT" = true ] && echo "Root (系统级服务)" || echo "普通用户 ${CURRENT_USER} (用户级服务)")"

# 本脚本通过 systemd 托管服务
if ! command -v systemctl >/dev/null 2>&1; then
    echo -e "${RED}[-] 未检测到 systemctl，本脚本依赖 systemd 托管 WebDAV 服务。${NC}"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        echo "提示: macOS 请使用 brew install webdav 安装，并通过 launchd 管理服务。"
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
        curl -fL --connect-timeout 15 -m 300 --retry 2 -o "$dest" "$url"
    elif command_exists wget; then
        wget -q --timeout=30 -O "$dest" "$url"
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
    out=$("$BIN_PATH" version 2>/dev/null | head -n1) || return 1
    out=$(printf '%s' "$out" | sed -E 's/.*[Vv]ersion:[[:space:]]*//')
    [[ -n "$out" ]] || return 1
    printf '%s' "$out"
}

installed_version_text() {
    local ver=""
    if ver=$(installed_version); then
        printf 'v%s' "${ver#v}"
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
    mkdir -p "$CONFIG_DIR"
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
#                          账号管理 (users.conf)
#  存储格式（每行一个账号）: 用户名|目录|权限|密码
#  密码放在最后一列，因此允许密码中出现 "|" 字符
# ===========================================================================

USER_NAME=""
USER_DIR=""
USER_PERM=""
USER_PASS=""

users_count() {
    [[ -f "$USERS_FILE" ]] || { printf '0'; return 0; }
    local c=""
    c=$(grep -c . "$USERS_FILE" 2>/dev/null) || true
    printf '%s' "${c:-0}"
}

parse_user_line() {
    local line="$1" rest=""
    USER_NAME="${line%%|*}"
    rest="${line#*|}"
    USER_DIR="${rest%%|*}"
    rest="${rest#*|}"
    USER_PERM="${rest%%|*}"
    USER_PASS="${rest#*|}"
}

# 用户名是否已存在
user_exists() {
    local name="$1"
    [[ -f "$USERS_FILE" ]] || return 1
    awk -F'|' -v n="$name" '$1 == n { found = 1 } END { exit found ? 0 : 1 }' "$USERS_FILE"
}

# 按行号（从 1 开始）替换账号记录
update_user_line() {
    local idx="$1" newline="$2" tmp=""
    tmp=$(mktemp)
    if UPD_LINE="$newline" awk -v n="$idx" '
        NR == n { print ENVIRON["UPD_LINE"]; next }
        { print }
    ' "$USERS_FILE" > "$tmp"; then
        mv -f "$tmp" "$USERS_FILE"
    else
        rm -f "$tmp"
        return 1
    fi
}

# 按行号（从 1 开始）删除账号记录
delete_user_line() {
    local idx="$1" tmp=""
    tmp=$(mktemp)
    if awk -v n="$idx" 'NR != n' "$USERS_FILE" > "$tmp"; then
        mv -f "$tmp" "$USERS_FILE"
    else
        rm -f "$tmp"
        return 1
    fi
}

# 打印账号列表（带颜色与编号）
list_users_detail() {
    local line="" i=0 pass_text=""
    if [[ "$(users_count)" -eq 0 ]]; then
        echo -e "${YELLOW}当前没有任何账号，WebDAV 将以匿名方式开放访问，建议至少添加一个账号！${NC}"
        return 1
    fi

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        i=$((i + 1))
        parse_user_line "$line"
        if [[ "$USER_PASS" == "{bcrypt}"* ]]; then
            pass_text="${GREEN}bcrypt 密文${NC}"
        else
            pass_text="${YELLOW}明文 ${USER_PASS}${NC}"
        fi
        echo -e " [${CYAN}${i}${NC}] 用户名: ${GREEN}${USER_NAME}${NC}"
        echo -e "      密码: ${pass_text}"
        echo -e "      目录: ${USER_DIR:-<跟随全局共享目录>}"
        echo -e "      权限: ${USER_PERM:-<跟随全局默认权限>}"
        echo "      ------------------------------------"
    done < "$USERS_FILE"
    return 0
}

# 交互选择账号编号，结果写入 SELECTED_USER_INDEX
SELECTED_USER_INDEX=0
select_user_index() {
    list_users_detail || return 1
    local idx=""
    prompt "请输入要操作的账号编号 [0 取消]: " idx
    if [[ ! "$idx" =~ ^[0-9]+$ ]] || [[ "$idx" -eq 0 ]]; then
        echo -e "${YELLOW}已取消。${NC}"
        return 1
    fi
    if [[ "$idx" -gt "$(users_count)" ]]; then
        echo -e "${RED}[-] 编号超出范围。${NC}"
        return 1
    fi
    SELECTED_USER_INDEX="$idx"
    return 0
}

# 交互输入权限组合，结果写入 NEW_PERMISSIONS
NEW_PERMISSIONS=""
ask_permissions() {
    local default="$1" input=""
    while true; do
        prompt "权限组合 (C创建 R读取 U更新 D删除，可组合，如 CRUD) [默认: ${default}]: " input
        input="${input:-$default}"
        if [[ "$input" =~ ^[CcRrUuDd]+$ ]]; then
            NEW_PERMISSIONS="$(printf '%s' "$input" | tr '[:lower:]' '[:upper:]')"
            return 0
        fi
        echo -e "${RED}格式不正确，请输入 C/R/U/D 的任意组合。${NC}"
    done
}

# 交互输入密码（二次确认），结果写入 NEW_PASSWORD
NEW_PASSWORD=""
ask_new_password() {
    local p1="" p2=""
    while true; do
        prompt_secret "请输入密码 (留空则取消): " p1
        if [[ -z "$p1" ]]; then
            NEW_PASSWORD=""
            return 1
        fi
        prompt_secret "请再次输入密码确认: " p2
        if [[ "$p1" != "$p2" ]]; then
            echo -e "${RED}两次输入的密码不一致，请重新输入。${NC}"
            continue
        fi
        NEW_PASSWORD="$p1"
        return 0
    done
}

# 按需将 NEW_PASSWORD 转换为 bcrypt 密文
maybe_bcrypt_password() {
    [[ -n "$NEW_PASSWORD" ]] || return 0
    is_installed || return 0

    local choice="" hash=""
    prompt "是否使用 bcrypt 加密存储密码? [Y/n 默认: Y]: " choice
    [[ "$choice" =~ ^[Nn]$ ]] && return 0

    if hash=$("$BIN_PATH" bcrypt -- "$NEW_PASSWORD" 2>/dev/null) && [[ -n "$hash" ]]; then
        NEW_PASSWORD="{bcrypt}${hash}"
        echo -e "${GREEN}[✓] 已生成 bcrypt 密文。${NC}"
    else
        echo -e "${YELLOW}[!] bcrypt 加密失败，将以明文形式保存。${NC}"
    fi
    return 0
}

# 提示账号为空的风险
warn_if_no_user() {
    if [[ "$(users_count)" -eq 0 ]]; then
        echo -e "${RED}警告: 当前没有任何账号，任何人无需认证即可访问 WebDAV！${NC}"
    fi
}

# ===========================================================================
#                        生成 config.yml 配置文件
# ===========================================================================

render_config() {
    mkdir -p "$CONFIG_DIR"
    if [[ -f "$CONFIG_FILE" ]]; then
        cp -f "$CONFIG_FILE" "${CONFIG_FILE}.bak" 2>/dev/null || true
    fi

    local address="" port="" directory="" prefix="" permissions="" cert="" key=""
    local y_debug="" y_nosniff="" y_behind="" y_tls="" y_cors=""

    address=$(get_setting address "0.0.0.0")
    port=$(get_setting port "6065")
    directory=$(get_setting directory "$DEFAULT_DATA_DIR")
    prefix=$(get_setting prefix "/")
    permissions=$(get_setting permissions "CRUD")
    cert=$(get_setting cert "${CONFIG_DIR}/cert.pem")
    key=$(get_setting key "${CONFIG_DIR}/key.pem")
    y_debug=$(yaml_bool "$(get_setting debug false)")
    y_nosniff=$(yaml_bool "$(get_setting noSniff false)")
    y_behind=$(yaml_bool "$(get_setting behindProxy false)")
    y_tls=$(yaml_bool "$(get_setting tls false)")
    y_cors=$(yaml_bool "$(get_setting cors false)")

    mkdir -p "$directory" 2>/dev/null || true

    {
        echo "# ==============================================================="
        echo "# WebDAV 配置文件 (hacdias/webdav)"
        echo "# 由 webdav_manager.sh 于 $(date '+%Y-%m-%d %H:%M:%S') 自动生成"
        echo "# 手工修改的内容可能在下次执行管理脚本时被覆盖"
        echo "# ==============================================================="
        echo "address: $(yaml_quote "$address")"
        echo "port: ${port}"
        echo "prefix: $(yaml_quote "$prefix")"
        echo "directory: $(yaml_quote "$directory")"
        echo "permissions: $(yaml_quote "$permissions")"
        echo "debug: ${y_debug}"
        echo "noSniff: ${y_nosniff}"
        echo "behindProxy: ${y_behind}"
        echo "tls: ${y_tls}"
        if [[ "$y_tls" == "true" ]]; then
            echo "cert: $(yaml_quote "$cert")"
            echo "key: $(yaml_quote "$key")"
        fi
        echo ""
        echo "log:"
        echo "  format: console"
        echo "  colors: true"
        echo "  outputs:"
        echo "    - stderr"
        echo ""
        echo "cors:"
        echo "  enabled: ${y_cors}"
        echo ""
        if [[ "$(users_count)" -eq 0 ]]; then
            echo "users: []"
        else
            echo "users:"
            local line=""
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                parse_user_line "$line"
                echo "  - username: $(yaml_quote "$USER_NAME")"
                echo "    password: $(yaml_quote "$USER_PASS")"
                if [[ -n "$USER_PERM" ]]; then
                    echo "    permissions: $(yaml_quote "$USER_PERM")"
                fi
                if [[ -n "$USER_DIR" ]]; then
                    echo "    directory: $(yaml_quote "$USER_DIR")"
                fi
            done < "$USERS_FILE"
        fi
    } > "$CONFIG_FILE"

    echo -e "${GREEN}[✓] 配置文件已生成: ${CONFIG_FILE}${NC}"
    warn_if_no_user
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
        x86_64|amd64)          arch="amd64" ;;
        i386|i486|i586|i686|x86) arch="386" ;;
        aarch64|arm64)         arch="arm64" ;;
        armv5*)                arch="armv5" ;;
        armv6*)                arch="armv6" ;;
        armv7*|armv8l)         arch="armv7" ;;
        mips64el)              arch="mips64le" ;;
        mips64)                arch="mips64" ;;
        mipsel)                arch="mipsle" ;;
        mips)                  arch="mips" ;;
        *)
            echo -e "${RED}[-] 无法识别 CPU 架构: $(uname -m)${NC}" >&2
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
            | head -n1 | sed -E 's/.*"([^"]*)"$/\1/') || tag=""
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
#                        安装 / 更新 WebDAV 二进制
# ===========================================================================

download_and_install_binary() {
    local platform="$1" tmpdir="" tarball="" archive_url="" src="" direct_url=""

    mkdir -p "$BIN_DIR" "$CONFIG_DIR"
    tmpdir=$(mktemp -d)
    tarball="${tmpdir}/webdav.tar.gz"

    archive_url="${DOWNLOAD_PROXY}https://github.com/${GITHUB_REPO}/releases/latest/download/${platform}-webdav.tar.gz"
    direct_url="https://github.com/${GITHUB_REPO}/releases/latest/download/${platform}-webdav.tar.gz"

    echo "[*] 正在下载 ${platform} 二进制包 (经代理: ${DOWNLOAD_PROXY})..."
    if ! download_file "$archive_url" "$tarball"; then
        echo -e "${YELLOW}[!] 代理下载失败，尝试直连 GitHub...${NC}"
        rm -f "$tarball"
        if ! download_file "$direct_url" "$tarball"; then
            echo -e "${RED}[-] 下载失败，请检查网络或手动下载: ${direct_url}${NC}"
            rm -rf "$tmpdir"
            return 1
        fi
    fi

    if ! tar -xzf "$tarball" -C "$tmpdir" 2>/dev/null; then
        echo -e "${RED}[-] 解压失败，安装包可能不完整。${NC}"
        rm -rf "$tmpdir"
        return 1
    fi

    src=$(find "$tmpdir" -type f ! -name '*.tar.gz' -name 'webdav' | head -n1) || true
    if [[ -z "$src" || ! -f "$src" ]]; then
        echo -e "${RED}[-] 安装包中未找到 webdav 可执行文件。${NC}"
        rm -rf "$tmpdir"
        return 1
    fi

    cp -f "$src" "$BIN_PATH"
    chmod 755 "$BIN_PATH"
    rm -rf "$tmpdir"
    echo -e "${GREEN}[✓] 已安装到 ${BIN_PATH}${NC}"
    return 0
}

# 首次配置向导
initial_config_wizard() {
    echo ""
    echo "------------------------------------------"
    echo -e "         ${BOLD}WebDAV 基础配置向导${NC}"
    echo "------------------------------------------"

    local address="" port="" directory="" prefix=""
    prompt "监听地址 [默认: 0.0.0.0]: " address
    address="${address:-0.0.0.0}"
    prompt "监听端口 [默认: 6065]: " port
    port="${port:-6065}"
    prompt "共享根目录 [默认: ${DEFAULT_DATA_DIR}]: " directory
    directory="${directory:-$DEFAULT_DATA_DIR}"
    prompt "URL 前缀 (反代子路径时填写，如 /webdav) [默认: /]: " prefix
    prefix="${prefix:-/}"

    while [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; do
        echo -e "${RED}端口必须是 1-65535 之间的数字。${NC}"
        prompt "监听端口 [默认: 6065]: " port
        port="${port:-6065}"
    done

    ask_permissions "CRUD"
    set_setting address "$address"
    set_setting port "$port"
    set_setting directory "$directory"
    set_setting prefix "$prefix"
    set_setting permissions "$NEW_PERMISSIONS"
    set_setting debug "$(get_setting debug false)"
    set_setting noSniff "$(get_setting noSniff false)"
    set_setting behindProxy "$(get_setting behindProxy false)"
    set_setting tls "$(get_setting tls false)"
    set_setting cert "$(get_setting cert "${CONFIG_DIR}/cert.pem")"
    set_setting key "$(get_setting key "${CONFIG_DIR}/key.pem")"
    set_setting cors "$(get_setting cors false)"
    mkdir -p "$directory" 2>/dev/null || true

    echo ""
    echo "------------------------------------------"
    echo -e "         ${BOLD}创建第一个访问账号${NC}"
    echo -e "${YELLOW}WebDAV 在未配置账号时允许匿名访问，建议至少添加一个账号。${NC}"
    echo "------------------------------------------"

    local username=""
    while true; do
        prompt "用户名 [默认: admin]: " username
        username="${username:-admin}"
        if [[ -z "$username" || "$username" == *"|"* ]]; then
            echo -e "${RED}用户名不能为空，且不能包含 | 字符。${NC}"
            continue
        fi
        break
    done

    if ! ask_new_password || [[ -z "$NEW_PASSWORD" ]]; then
        echo -e "${YELLOW}未设置密码，跳过账号创建。${NC}"
    else
        maybe_bcrypt_password
        touch "$USERS_FILE"
        printf '%s|%s|%s|%s\n' "$username" "" "$NEW_PERMISSIONS" "$NEW_PASSWORD" >> "$USERS_FILE"
        echo -e "${GREEN}[✓] 账号 ${username} 已创建。${NC}"
    fi

    render_config
}

install_or_update_webdav() {
    echo ""
    echo "=========================================="
    echo -e "        ${BOLD}安装 / 更新 WebDAV 服务${NC}"
    echo "=========================================="
    echo "执行身份: ${RUN_MODE_TEXT}"

    if ! command_exists tar; then
        echo -e "${RED}[-] 系统缺少 tar 命令，无法解压安装包。${NC}"
        return 1
    fi

    local platform="" cur_ver="" latest_tag="" latest_ver=""
    platform=$(detect_platform) || return 1

    if cur_ver=$(installed_version); then
        cur_ver="${cur_ver#v}"
    else
        cur_ver=""
    fi
    latest_tag=$(fetch_latest_tag) || latest_tag=""
    latest_ver="${latest_tag#v}"

    echo "目标平台:   ${platform}"
    echo "当前版本:   $(installed_version_text)"
    echo "最新版本:   ${latest_tag:-未知 (将直接拉取 latest 产物)}"
    echo "------------------------------------------"

    local need_download=true skip_download=false

    if [[ -n "$cur_ver" && -n "$latest_ver" && "$cur_ver" == "$latest_ver" ]]; then
        local choice=""
        prompt "当前已是最新版本 v${cur_ver}，是否重新下载安装? [y/N 默认: N]: " choice
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            need_download=false
            skip_download=true
            echo -e "${GREEN}[✓] 跳过下载，继续服务配置。${NC}"
        fi
    fi

    echo ""
    echo "[1/4] 准备目录与二进制程序..."
    if [[ "$need_download" == true ]]; then
        download_and_install_binary "$platform" || return 1
    else
        if [[ "$skip_download" == true ]]; then
            echo "[-] 保留现有二进制: ${BIN_PATH}"
        fi
    fi

    echo ""
    echo "[2/4] 检查配置..."
    mkdir -p "$CONFIG_DIR"
    touch "$USERS_FILE"

    if config_exists; then
        echo "已检测到配置文件: ${CONFIG_FILE}"
        local reconf=""
        prompt "是否重新执行基础配置向导 (覆盖现有全局设置)? [y/N 默认: N]: " reconf
        if [[ "$reconf" =~ ^[Yy]$ ]]; then
            initial_config_wizard
        else
            local adduser=""
            prompt "是否需要新增账号? [y/N 默认: N]: " adduser
            if [[ "$adduser" =~ ^[Yy]$ ]]; then
                add_user_interactive || true
            fi
            render_config
        fi
    else
        initial_config_wizard
    fi

    echo ""
    echo "[3/4] 写入 systemd 服务文件..."
    mkdir -p "$SYSTEMD_DIR"
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=WebDAV Server (hacdias/webdav)
Documentation=https://github.com/hacdias/webdav
After=network.target

[Service]
Type=simple
WorkingDirectory=${CONFIG_DIR}
ExecStart=${BIN_PATH} --config ${CONFIG_FILE}
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

    sleep 1
    local port=""
    port=$(get_setting port "6065")
    echo ""
    echo "=========================================="
    echo -e "          ${GREEN}WebDAV 安装/更新完成！${NC}"
    echo "=========================================="
    echo -e " 服务状态: $(service_state_text)    开机自启: $(service_boot_text)"

    if ! check_port_listening "$port"; then
        echo -e "${YELLOW}[!] 未检测到端口 ${port} 处于监听状态，请查看日志排查。${NC}"
    fi

    echo " 可执行文件: ${BIN_PATH}"
    echo " 配置文件:   ${CONFIG_FILE}"
    echo " 共享目录:   $(get_setting directory "$DEFAULT_DATA_DIR")"
    echo " 访问地址:   http://<服务器IP>:${port}$(get_setting prefix "/")"
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
    current=$(get_setting port "6065")
    prompt "监听端口 [当前: ${current}] (留空保持不变): " input
    if [[ -z "$input" ]]; then
        echo -e "${YELLOW}[-] 未修改。${NC}"
        return 1
    fi
    while [[ ! "$input" =~ ^[0-9]+$ ]] || [[ "$input" -lt 1 || "$input" -gt 65535 ]]; do
        echo -e "${RED}端口必须是 1-65535 之间的数字。${NC}"
        prompt "监听端口 [当前: ${current}] (留空保持不变): " input
        [[ -z "$input" ]] && return 1
    done
    set_setting port "$input"
    echo -e "${GREEN}[✓] 已更新 port = ${input}${NC}"
    return 0
}

edit_tls_setting() {
    local current="" choice=""
    current=$(yaml_bool "$(get_setting tls false)")
    echo "当前 TLS 状态: ${current}"
    prompt "是否启用 TLS (https)? [y/N 默认保持当前]: " choice
    if [[ -z "$choice" ]]; then
        echo -e "${YELLOW}[-] 未修改。${NC}"
        return 1
    fi

    if [[ "$choice" =~ ^[Yy]$ ]]; then
        local cert="" key=""
        cert=$(get_setting cert "${CONFIG_DIR}/cert.pem")
        key=$(get_setting key "${CONFIG_DIR}/key.pem")
        prompt "证书文件路径 [默认: ${cert}]: " cert
        cert="${cert:-$(get_setting cert "${CONFIG_DIR}/cert.pem")}"
        prompt "私钥文件路径 [默认: ${key}]: " key
        key="${key:-$(get_setting key "${CONFIG_DIR}/key.pem")}"
        set_setting tls true
        set_setting cert "$cert"
        set_setting key "$key"
        echo -e "${GREEN}[✓] 已启用 TLS，证书: ${cert}${NC}"
    else
        set_setting tls false
        echo -e "${GREEN}[✓] 已关闭 TLS。${NC}"
    fi
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
    echo "备注: 账号密码以 {bcrypt} 开头表示已加密存储。"
    return 0
}

configure_webdav() {
    if ! config_exists; then
        echo -e "${RED}[-] 未检测到配置 (${SETTINGS_FILE})，请先执行安装。${NC}"
        return 0
    fi

    local choice=""
    while true; do
        echo ""
        echo "=========================================="
        echo -e "          ${BOLD}WebDAV 全局配置${NC}"
        echo "=========================================="
        echo "  1. 监听地址 (address)     : $(get_setting address "0.0.0.0")"
        echo "  2. 监听端口 (port)        : $(get_setting port "6065")"
        echo "  3. 共享根目录 (directory) : $(get_setting directory "$DEFAULT_DATA_DIR")"
        echo "  4. URL 前缀 (prefix)      : $(get_setting prefix "/")"
        echo "  5. 默认权限 (permissions) : $(get_setting permissions "CRUD")"
        echo "  6. TLS 加密 (tls)         : $(yaml_bool "$(get_setting tls false)")"
        echo "  7. 调试日志 (debug)       : $(yaml_bool "$(get_setting debug false)")"
        echo "  8. 禁止嗅探 (noSniff)     : $(yaml_bool "$(get_setting noSniff false)")"
        echo "  9. 反向代理 (behindProxy) : $(yaml_bool "$(get_setting behindProxy false)")"
        echo " 10. CORS 跨域 (cors)       : $(yaml_bool "$(get_setting cors false)")"
        echo " 11. 查看当前配置文件"
        echo " 12. 重新生成配置文件"
        echo "  0. 返回上级菜单"
        echo "=========================================="
        prompt "请输入操作编号 [0-12 默认: 0]: " choice
        choice="${choice:-0}"

        local changed=true
        case "$choice" in
            1) edit_setting address "监听地址 (0.0.0.0 表示全部网卡)" "$(get_setting address "0.0.0.0")" || changed=false ;;
            2) edit_port_setting || changed=false ;;
            3)
                local dir="" label=""
                dir=$(get_setting directory "$DEFAULT_DATA_DIR")
                prompt "共享根目录 [当前: ${dir}] (留空保持不变): " label
                if [[ -z "$label" ]]; then
                    echo -e "${YELLOW}[-] 未修改。${NC}"
                    changed=false
                else
                    set_setting directory "$label"
                    mkdir -p "$label" 2>/dev/null || true
                    echo -e "${GREEN}[✓] 已更新 directory = ${label}${NC}"
                fi
                ;;
            4) edit_setting prefix "URL 前缀 (如 / 或 /webdav)" "$(get_setting prefix "/")" || changed=false ;;
            5)
                ask_permissions "$(get_setting permissions "CRUD")"
                set_setting permissions "$NEW_PERMISSIONS"
                echo -e "${GREEN}[✓] 已更新 permissions = ${NEW_PERMISSIONS}${NC}"
                ;;
            6) edit_tls_setting || changed=false ;;
            7) toggle_setting debug "调试日志" || changed=false ;;
            8) toggle_setting noSniff "内容类型嗅探禁用" || changed=false ;;
            9) toggle_setting behindProxy "反向代理模式" || changed=false ;;
            10) toggle_setting cors "CORS 跨域支持" || changed=false ;;
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

# 新增账号（供安装流程与账号管理共用）
add_user_interactive() {
    local username=""
    while true; do
        prompt "用户名 (留空取消): " username
        if [[ -z "$username" ]]; then
            echo -e "${YELLOW}已取消。${NC}"
            return 1
        fi
        if [[ "$username" == *"|"* ]]; then
            echo -e "${RED}用户名不能包含 | 字符。${NC}"
            continue
        fi
        if user_exists "$username"; then
            echo -e "${RED}用户名 ${username} 已存在，请更换。${NC}"
            continue
        fi
        break
    done

    if ! ask_new_password || [[ -z "$NEW_PASSWORD" ]]; then
        echo -e "${YELLOW}已取消。${NC}"
        return 1
    fi
    maybe_bcrypt_password

    local udir=""
    prompt "该账号独立目录 (留空则使用全局共享目录): " udir
    if [[ -n "$udir" ]]; then
        mkdir -p "$udir" 2>/dev/null || true
    fi

    ask_permissions "$(get_setting permissions "CRUD")"

    touch "$USERS_FILE"
    printf '%s|%s|%s|%s\n' "$username" "$udir" "$NEW_PERMISSIONS" "$NEW_PASSWORD" >> "$USERS_FILE"
    echo -e "${GREEN}[✓] 账号 ${username} 已添加。${NC}"
    return 0
}

modify_user_interactive() {
    select_user_index || return 1
    local idx="$SELECTED_USER_INDEX" line=""
    line=$(awk -v n="$idx" 'NR == n' "$USERS_FILE")
    parse_user_line "$line"

    local cur_name="$USER_NAME" cur_dir="$USER_DIR" cur_perm="$USER_PERM" cur_pass="$USER_PASS"
    echo ""
    echo "正在修改账号: ${cur_name}"
    echo "------------------------------------------"

    local input=""
    prompt "用户名 [当前: ${cur_name}] (留空保持不变): " input
    local new_name="${input:-$cur_name}"
    if [[ "$new_name" != "$cur_name" ]]; then
        if [[ "$new_name" == *"|"* ]]; then
            echo -e "${RED}用户名不能包含 | 字符，保持原用户名。${NC}"
            new_name="$cur_name"
        elif user_exists "$new_name"; then
            echo -e "${RED}用户名 ${new_name} 已存在，保持原用户名。${NC}"
            new_name="$cur_name"
        fi
    fi

    prompt "独立目录 [当前: ${cur_dir:-<全局共享目录>}] (输入 - 清空, 留空保持不变): " input
    local new_dir="$cur_dir"
    if [[ "$input" == "-" ]]; then
        new_dir=""
    elif [[ -n "$input" ]]; then
        new_dir="$input"
        mkdir -p "$new_dir" 2>/dev/null || true
    fi

    prompt "是否修改密码? [y/N 默认: N]: " input
    local new_pass="$cur_pass"
    if [[ "$input" =~ ^[Yy]$ ]]; then
        if ask_new_password && [[ -n "$NEW_PASSWORD" ]]; then
            maybe_bcrypt_password
            new_pass="$NEW_PASSWORD"
        else
            echo -e "${YELLOW}保留原密码。${NC}"
        fi
    fi

    ask_permissions "${cur_perm:-$(get_setting permissions "CRUD")}"
    local new_perm="$NEW_PERMISSIONS"

    update_user_line "$idx" "${new_name}|${new_dir}|${new_perm}|${new_pass}"
    echo -e "${GREEN}[✓] 账号已更新。${NC}"
    render_config >/dev/null
    ask_restart_service
    return 0
}

delete_user_interactive() {
    select_user_index || return 1
    local idx="$SELECTED_USER_INDEX" line=""
    line=$(awk -v n="$idx" 'NR == n' "$USERS_FILE")
    parse_user_line "$line"

    local choice=""
    prompt "确定删除账号 ${USER_NAME} 吗? [y/N]: " choice
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}已取消。${NC}"
        return 1
    fi

    delete_user_line "$idx"
    echo -e "${GREEN}[✓] 账号 ${USER_NAME} 已删除。${NC}"
    render_config >/dev/null
    ask_restart_service
    return 0
}

generate_bcrypt_password() {
    if ! is_installed; then
        echo -e "${RED}[-] 未检测到 webdav 程序，无法生成 bcrypt 密文。${NC}"
        return 1
    fi
    local pwd="" choice=""
    prompt_secret "请输入需要加密的密码 (留空取消): " pwd
    if [[ -z "$pwd" ]]; then
        echo -e "${YELLOW}已取消。${NC}"
        return 1
    fi

    local hash=""
    if hash=$("$BIN_PATH" bcrypt -- "$pwd" 2>/dev/null) && [[ -n "$hash" ]]; then
        echo ""
        echo -e "${GREEN}bcrypt 密文:${NC}"
        echo "{bcrypt}${hash}"
        echo ""
        prompt "是否将某个账号的密码更新为该密文? [y/N 默认: N]: " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            select_user_index || return 0
            local idx="$SELECTED_USER_INDEX" line=""
            line=$(awk -v n="$idx" 'NR == n' "$USERS_FILE")
            parse_user_line "$line"
            update_user_line "$idx" "${USER_NAME}|${USER_DIR}|${USER_PERM}|{bcrypt}${hash}"
            echo -e "${GREEN}[✓] 账号 ${USER_NAME} 密码已更新为 bcrypt 密文。${NC}"
            render_config >/dev/null
            ask_restart_service
        fi
    else
        echo -e "${RED}[-] bcrypt 生成失败。${NC}"
        return 1
    fi
    return 0
}

manage_users() {
    if ! config_exists; then
        echo -e "${RED}[-] 未检测到配置 (${SETTINGS_FILE})，请先执行安装。${NC}"
        return 0
    fi

    local choice=""
    while true; do
        echo ""
        echo "=========================================="
        echo -e "          ${BOLD}WebDAV 账号管理${NC}"
        echo "=========================================="
        echo "  账号数量: $(users_count)"
        echo "------------------------------------------"
        list_users_detail || true
        echo "------------------------------------------"
        echo "  1. 添加账号"
        echo "  2. 修改账号"
        echo "  3. 删除账号"
        echo "  4. 生成 bcrypt 加密密码"
        echo "  0. 返回上级菜单"
        echo "=========================================="
        prompt "请输入操作编号 [0-4 默认: 0]: " choice
        choice="${choice:-0}"

        case "$choice" in
            1) add_user_interactive && { render_config >/dev/null; ask_restart_service; } ;;
            2) modify_user_interactive || true ;;
            3) delete_user_interactive || true ;;
            4) generate_bcrypt_password || true ;;
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

enable_webdav() {
    echo ""
    echo "=========================================="
    echo -e "          ${BOLD}启用 WebDAV 服务${NC}"
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

    sleep 1
    local port=""
    port=$(get_setting port "6065")
    echo -e "${GREEN}[✓] 服务已启用开机自启并尝试启动。${NC}"
    echo -e " 服务状态: $(service_state_text)    开机自启: $(service_boot_text)"

    if [[ "$IS_ROOT" == false ]] && command_exists loginctl; then
        loginctl enable-linger "$CURRENT_USER" 2>/dev/null || true
    fi

    if ! check_port_listening "$port"; then
        echo -e "${YELLOW}[!] 未检测到端口 ${port} 处于监听状态，请查看日志排查。${NC}"
    fi
    echo "=========================================="
    return 0
}

disable_webdav() {
    echo ""
    echo "=========================================="
    echo -e "          ${BOLD}停用 WebDAV 服务${NC}"
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

    echo -e "${GREEN}[✓] 服务已停止并取消开机自启，配置与数据保持不变。${NC}"
    echo -e " 服务状态: $(service_state_text)    开机自启: $(service_boot_text)"
    echo "=========================================="
    return 0
}

toggle_service() {
    if is_service_enabled; then
        disable_webdav
    else
        enable_webdav
    fi
    return 0
}

# ===========================================================================
#                          状态 / 日志 / 配置查看
# ===========================================================================

view_status() {
    echo ""
    echo "=========================================="
    echo -e "          ${BOLD}WebDAV 运行状态${NC}"
    echo "=========================================="
    echo -e " 执行身份:   ${RUN_MODE_TEXT}"
    echo -e " 安装版本:   $(installed_version_text)"
    echo -e " 服务状态:   $(service_state_text)"
    echo -e " 开机自启:   $(service_boot_text)"
    echo -e " 可执行文件: ${BIN_PATH}"
    echo -e " 配置文件:   ${CONFIG_FILE}"
    echo -e " 共享目录:   $(get_setting directory "$DEFAULT_DATA_DIR")"
    echo -e " 监听地址:   $(get_setting address "0.0.0.0"):$(get_setting port "6065")"
    echo -e " 前缀路径:   $(get_setting prefix "/")"
    echo -e " 账号数量:   $(users_count)"
    echo -e " TLS / CORS: $(yaml_bool "$(get_setting tls false)") / $(yaml_bool "$(get_setting cors false)")"
    echo "=========================================="

    if ! is_installed; then
        echo -e "${YELLOW}提示: 尚未安装 WebDAV，请先选择菜单项 1 进行安装。${NC}"
        return 0
    fi

    echo ""
    echo "----- systemd 服务详情 -----"
    $SYSTEMCTL_CMD --no-pager -l status "${SERVICE_NAME}.service" 2>&1 | head -n 20 || true

    echo ""
    echo "----- 最近 20 行日志 -----"
    $JOURNALCTL_CMD --no-pager -n 20 -u "${SERVICE_NAME}.service" 2>&1 || true
    echo "=========================================="
    return 0
}

# ===========================================================================
#                                卸载
# ===========================================================================

uninstall_webdav() {
    echo ""
    echo "=========================================="
    echo -e "          ${BOLD}卸载 WebDAV${NC}"
    echo "=========================================="
    echo "执行身份: ${RUN_MODE_TEXT}"

    if ! is_installed && [[ ! -f "$SERVICE_FILE" ]] && [[ ! -d "$CONFIG_DIR" ]]; then
        echo -e "${YELLOW}[-] 未检测到已安装的 WebDAV。${NC}"
        return 0
    fi

    local confirm=""
    prompt "确定要卸载 WebDAV 吗? [y/N]: " confirm
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

    echo "[3/4] 处理配置文件..."
    local del_conf=""
    prompt "是否删除配置目录 ${CONFIG_DIR} (含 config.yml / 账号信息)? [y/N]: " del_conf
    if [[ "$del_conf" =~ ^[Yy]$ ]]; then
        rm -rf "$CONFIG_DIR"
        echo -e "${GREEN}[✓] 已删除配置目录: ${CONFIG_DIR}${NC}"
    else
        echo "[-] 保留配置目录: ${CONFIG_DIR}"
    fi

    echo "[4/4] 处理共享数据目录..."
    local data_dir="" target=""
    data_dir=$(get_setting directory "$DEFAULT_DATA_DIR")
    prompt "是否需要删除共享数据目录 [当前记录: ${data_dir}]? [y/N 默认: N]: " DATA_CHECK
    if [[ "${DATA_CHECK:-N}" =~ ^[Yy]$ ]]; then
        prompt "请输入要彻底删除的数据目录 [默认: ${data_dir}]: " target
        target="${target:-$data_dir}"
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
    echo -e "       ${GREEN}WebDAV 已成功卸载完成！${NC}"
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
        echo -e "   ${BOLD}WebDAV 管理脚本${NC} (hacdias/webdav)"
        echo "   身份: ${RUN_MODE_TEXT}"
        echo "   版本: $(installed_version_text)"
        echo "=========================================="
        echo -e " 服务状态: $(service_state_text)    开机自启: $(service_boot_text)"
        echo " 监听地址: $(get_setting address "0.0.0.0"):$(get_setting port "6065")   账号数量: $(users_count)"
        echo "------------------------------------------"
        echo " 1. 安装 / 更新 WebDAV"
        echo " 2. 配置 WebDAV (全局设置)"
        if is_service_enabled; then
            echo " 3. 停用 WebDAV 服务 (停止并取消开机自启)"
        else
            echo " 3. 启用 WebDAV 服务"
        fi
        echo " 4. 账号管理 (添加 / 修改 / 删除 WebDAV 账号)"
        echo " 5. 查看运行状态 / 日志"
        echo " 6. 卸载 WebDAV"
        echo " 0. 退出"
        echo "=========================================="
        prompt "请输入操作编号 [0-6 默认: 0]: " choice
        choice="${choice:-0}"

        case "$choice" in
            1) install_or_update_webdav || true ;;
            2) configure_webdav ;;
            3) toggle_service ;;
            4) manage_users ;;
            5) view_status ;;
            6) uninstall_webdav ;;
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
