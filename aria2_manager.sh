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
LOG_FILE="${ARIA2_CONF_DIR}/aria2.log"
TRACKER_SCRIPT="${ARIA2_CONF_DIR}/scripts/update_tracker.sh"
BLOCKER_SCRIPT="${ARIA2_CONF_DIR}/scripts/block_peers.sh"
FILTER_SCRIPT="${ARIA2_CONF_DIR}/scripts/auto_filter_video.py"
DEFAULT_DOWNLOAD_DIR="${USER_HOME}/Downloads"
DEFAULT_PORT="6800"
DEFAULT_ARIANG_PORT="6880"
GH_PROXY="https://gitpy.223327.xyz/https://github.com"
ARIANG_DIR="${ARIA2_CONF_DIR}/ariang"

# ==================== 基础依赖检测 (仅缺失时安装，不刷源) ====================
install_packages() {
    local pkgs=("$@")
    local missing_pkgs=()

    for pkg in "${pkgs[@]}"; do
        if command -v apt-get &>/dev/null; then
            if ! dpkg -s "$pkg" &>/dev/null; then
                missing_pkgs+=("$pkg")
            fi
        elif ! command -v "$pkg" &>/dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [ ${#missing_pkgs[@]} -eq 0 ]; then
        return 0
    fi

    echo ">> 发现缺少依赖，正在安装: ${missing_pkgs[*]}..."
    if command -v apt-get &>/dev/null; then
        # 仅在确实缺包时才刷新一次软件源索引 (安静模式)，日常进入菜单不会触发，避免刷屏
        echo ">> 正在刷新软件源索引 (apt-get update -qq)..."
        ${SUDO_CMD} apt-get update -qq 2>/dev/null || true
        if ! ${SUDO_CMD} apt-get install -y --no-install-recommends "${missing_pkgs[@]}"; then
            echo ">> !! 依赖安装失败: ${missing_pkgs[*]}，请检查网络或软件源后重试。"
            return 1
        fi
    elif command -v pacman &>/dev/null; then
        ${SUDO_CMD} pacman -Sy --noconfirm "${missing_pkgs[@]}"
    elif command -v dnf &>/dev/null; then
        ${SUDO_CMD} dnf install -y "${missing_pkgs[@]}"
    fi
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

# ==================== 进程安全停机与等待 ====================
stop_aria2_safely() {
    echo ">> 正在平稳停止 Aria2 服务以刷新保存 session..."
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

# ==================== 生成 Tracker 更新脚本 ====================
ensure_tracker_script() {
    mkdir -p "${ARIA2_CONF_DIR}/scripts"
    cat > "${TRACKER_SCRIPT}" <<EOF
#!/usr/bin/env bash
CONF_FILE="${CONF_FILE}"
TRACKER_URL1="https://bitbucket.org/xiu2/trackerslistcollection/raw/master/all.txt"
TRACKER_URL2="https://cdn.jsdelivr.net/gh/ngosang/trackerslist@master/trackers_all.txt"

echo "正在从多源获取最新 Tracker 列表..."
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
    ${SYSTEMCTL_CMD} restart aria2.service
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
            read -rp "请输入 RPC 密钥 (rpc-secret) [默认保留当前设置]: " INPUT_SECRET
            RPC_SECRET="${INPUT_SECRET:-$CURRENT_SECRET}"
        else
            read -rp "请输入 RPC 密钥 (rpc-secret，不能为空): " RPC_SECRET
        fi

        if [ -n "$RPC_SECRET" ]; then
            break
        fi
        echo "RPC 密钥不能为空，请重新输入！"
    done

    echo ""
    read -rp "是否顺带安装/更新 AriaNg Web 前端 (Caddy 反代模式)? [y/N 默认: N]: " WITH_ARIANG
    WITH_ARIANG="${WITH_ARIANG:-N}"

    echo ""
    echo "=== Aria2 配置概要 ==="
    echo "运行模式: $([ "$IS_ROOT" = true ] && echo "Root 系统模式" || echo "普通用户模式 ($CURRENT_USER)")"
    echo "下载目录: ${DOWNLOAD_DIR}"
    echo "RPC 端口: ${RPC_PORT}"
    echo "RPC 密钥: ${RPC_SECRET}"
    echo "顺带配置 AriaNg: $([[ "$WITH_ARIANG" =~ ^[Yy]$ ]] && echo "是" || echo "否")"
    echo "Trackers 自动更新: 默认开启 (每日定时)"
    echo "全局最大上传限制: 2M"
    echo "全局下载速度限制: 不限速 (0)"
    echo "BT 默认做种策略: 分享率达到 1.0 停止做种"
    echo "未选文件自动清理: 开启 (bt-remove-unselected-file=true)"
    echo "吸血 Peer 防火墙: 默认自动开启 (ipset + iptables 拦截)"
    echo "======================"
    read -rp "确认应用并保存配置? [Y/n 默认: Y]: " CONFIRM
    CONFIRM="${CONFIRM:-Y}"
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "已取消操作。"
        return 0
    fi

    local NEED_DOWNLOAD=true
    if [ -f "${ARIA2C_BIN}" ] && [ -x "${ARIA2C_BIN}" ]; then
        echo ""
        echo ">> 检测到 ${ARIA2C_BIN} 已存在，跳过重新下载二进制程序。"
        NEED_DOWNLOAD=false
    fi

    if [ "$NEED_DOWNLOAD" = true ]; then
        install_packages curl wget tar python3
        echo ">> 正在下载 Aria2 增强版..."
        ARIA2_URL="${GH_PROXY}/P3TERX/Aria2-Pro-Core/releases/download/1.36.0_2021.08.22/aria2-1.36.0-static-linux-amd64.tar.gz"
        TMP_DIR=$(mktemp -d)
        wget -q --show-progress -O "${TMP_DIR}/aria2.tar.gz" "${ARIA2_URL}"

        echo ">> 解压并安装到 ${ARIA2C_BIN}..."
        tar -zxvf "${TMP_DIR}/aria2.tar.gz" -C "${TMP_DIR}"
        mkdir -p "${ARIA2C_BIN_DIR}"
        mv "${TMP_DIR}/aria2c" "${ARIA2C_BIN}"
        chmod +x "${ARIA2C_BIN}"
        rm -rf "${TMP_DIR}"
    fi

    mkdir -p "${DOWNLOAD_DIR}"
    mkdir -p "${ARIA2_CONF_DIR}"
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

## 下载连接与速度设置 ##
max-concurrent-downloads=5
max-connection-per-server=64
min-split-size=4M
split=64
disable-ipv6=true
max-overall-upload-limit=2M
max-upload-limit=2M
max-overall-download-limit=0
max-download-limit=0

## 做种与分享率设置 ##
seed-time=0
seed-ratio=1.0

## 进度保存设置 ##
input-file=${SESSION_FILE}
save-session=${SESSION_FILE}
save-session-interval=60

## RPC 设置 ##
enable-rpc=true
rpc-allow-origin-all=true
rpc-listen-all=true
rpc-listen-port=${RPC_PORT}
rpc-secret=${RPC_SECRET}

## BT/PT 设置 ##
bt-save-metadata=false
follow-torrent=mem
bt-remove-unselected-file=true
bt-tracker=
EOF

    ensure_tracker_script

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
Description=Run Aria2 Trackers Update Daily

[Timer]
OnBootSec=10min
OnUnitActiveSec=24h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    ${SYSTEMCTL_CMD} daemon-reload
    ${SYSTEMCTL_CMD} enable --now aria2.service
    ${SYSTEMCTL_CMD} restart aria2.service
    ${SYSTEMCTL_CMD} enable --now aria2-update-tracker.timer

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
        local cur_dir cur_concurrent cur_up_limit cur_down_limit cur_seed_time cur_seed_ratio cur_rm_unsel cur_save_meta
        cur_dir=$(get_current_download_dir)
        cur_concurrent=$(get_conf_value "max-concurrent-downloads" "5")
        cur_up_limit=$(get_conf_value "max-overall-upload-limit" "2M")
        cur_down_limit=$(get_conf_value "max-overall-download-limit" "0")
        cur_seed_time=$(get_conf_value "seed-time" "0")
        cur_seed_ratio=$(get_conf_value "seed-ratio" "1.0")
        cur_rm_unsel=$(get_conf_value "bt-remove-unselected-file" "true")
        cur_save_meta=$(get_conf_value "bt-save-metadata" "false")

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
        echo "  6. 清理未选择的占位文件:   $([ "$cur_rm_unsel" == "true" ] && echo "是 (自动删除)" || echo "否 (保留空占位)")"
        echo "  7. 保存磁力下载的种子文件: $([ "$cur_save_meta" == "true" ] && echo "是 (保存 .torrent)" || echo "否 (不保留)")"
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
                read -rp "是否在下载完成后自动删除未勾选的占位文件? [Y/n 默认: Y]: " UNSEL_CHOICE
                UNSEL_CHOICE="${UNSEL_CHOICE:-Y}"
                if [[ "$UNSEL_CHOICE" =~ ^[Yy]$ ]]; then
                    update_conf_kv "bt-remove-unselected-file" "true"
                    echo ">> 已开启: 自动删除未选中的文件占位。"
                else
                    update_conf_kv "bt-remove-unselected-file" "false"
                    echo ">> 已关闭: 保留所有文件的占位。"
                fi
                ;;
            7)
                read -rp "磁力链下载时是否把种子文件 (.torrent) 保存到下载目录? [y/N 默认: N]: " META_CHOICE
                META_CHOICE="${META_CHOICE:-N}"
                if [[ "$META_CHOICE" =~ ^[Yy]$ ]]; then
                    update_conf_kv "bt-save-metadata" "true"
                    echo ">> 已开启: 磁力链解析成功后将保留 .torrent 种子文件。"
                else
                    update_conf_kv "bt-save-metadata" "false"
                    echo ">> 已关闭: 不保留额外种子文件。"
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

                read -rp "6. 自动清理未勾选的多余占位文件? [Y/n 默认: Y]: " IN_RM
                IN_RM="${IN_RM:-Y}"
                [[ "$IN_RM" =~ ^[Yy]$ ]] && update_conf_kv "bt-remove-unselected-file" "true" || update_conf_kv "bt-remove-unselected-file" "false"

                read -rp "7. 保存磁力下载的 .torrent 种子? [y/N 默认: N]: " IN_SAVE_META
                IN_SAVE_META="${IN_SAVE_META:-N}"
                [[ "$IN_SAVE_META" =~ ^[Yy]$ ]] && update_conf_kv "bt-save-metadata" "true" || update_conf_kv "bt-save-metadata" "false"

                echo ">> 向导配置已完整写入！"
                ;;
            0)
                echo ">> 正在重启 Aria2 服务以应用修改..."
                ${SYSTEMCTL_CMD} restart aria2.service
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

    echo "请选择操作:"
    echo " 1. 立即从网络自动拉取最新 Trackers (双源合并去重)"
    echo " 2. 手动自定义输入 Trackers 列表"
    echo " 0. 返回上级菜单"
    read -rp "请选择 [0-2 默认: 0]: " TRACKER_CHOICE
    TRACKER_CHOICE="${TRACKER_CHOICE:-0}"

    if [ "$TRACKER_CHOICE" == "0" ]; then
        return 0
    elif [ "$TRACKER_CHOICE" == "1" ]; then
        ensure_tracker_script
        echo ">> 正在执行 Tracker 更新脚本..."
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

        ${SYSTEMCTL_CMD} restart aria2.service
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
    echo ""

    echo " 1. 启用并开启开机自启 (Enable & Start)"
    echo " 2. 停用并关闭开机自启 (Disable & Stop)"
    echo " 3. 查看定时器运行与下次触发时间"
    echo " 0. 返回上级菜单"
    read -rp "请选择操作 [0-3 默认: 0]: " TIMER_CHOICE
    TIMER_CHOICE="${TIMER_CHOICE:-0}"

    case "$TIMER_CHOICE" in
        1)
            ensure_tracker_script
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
Description=Run Aria2 Trackers Update Daily

[Timer]
OnBootSec=10min
OnUnitActiveSec=24h
Persistent=true

[Install]
WantedBy=timers.target
EOF

            ${SYSTEMCTL_CMD} daemon-reload
            ${SYSTEMCTL_CMD} enable --now aria2-update-tracker.timer
            echo ">> Trackers 自动更新定时器已成功启用！"
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
            echo "=== iptables 拦截规则 ==="
            ${SUDO_CMD} iptables -L INPUT -n -v | grep "aria2_ban" || echo "未找到 IPv4 拦截规则"
            if command -v ip6tables &>/dev/null; then
                ${SUDO_CMD} ip6tables -L INPUT -n -v | grep "aria2_ban" || echo "未找到 IPv6 拦截规则"
            fi
            echo ""
            echo "=== ipset 集合概况 ==="
            ${SUDO_CMD} ipset list aria2_ban_v4 -terse 2>/dev/null || echo "aria2_ban_v4 集合不存在"
            ${SUDO_CMD} ipset list aria2_ban_v6 -terse 2>/dev/null || echo "aria2_ban_v6 集合不存在"
            echo ""
            echo "=== 定时器运行状态 ==="
            systemctl list-timers aria2-peer-blocker.timer || true
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
    echo " 1. 仅迁移未完成的下载任务 (自动识别 .aria2 校验块、数据与种子元数据)"
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

    install_packages rsync findutils

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
        read -rp "请输入目标新磁盘目录绝对路径 (例如: /mnt/disk2/Downloads): " DEST_DIR
        if [ -n "$DEST_DIR" ]; then
            DEST_DIR="${DEST_DIR%/}"
            break
        fi
        echo "目标路径不能为空，请重新输入！"
    done

    stop_aria2_safely

    mkdir -p "${DEST_DIR}"
    if [ "$IS_ROOT" = false ]; then
        ${SUDO_CMD} chown -R "${CURRENT_USER}:${CURRENT_USER}" "${DEST_DIR}" 2>/dev/null || true
    fi
    chmod 755 "${DEST_DIR}" 2>/dev/null || true

    declare -a MIGRATED_FILES=()

    case "$MIGRATE_TYPE" in
        1)
            echo ">> 正在检索未完成任务 (*.aria2)..."
            mapfile -t ARIA2_CONTROL_FILES < <(find "${SRC_DIR}" -name "*.aria2")
            if [ ${#ARIA2_CONTROL_FILES[@]} -eq 0 ]; then
                echo "提示: 在源目录下未找到任何未完成的任务 (*.aria2 文件)。"
                ${SYSTEMCTL_CMD} start aria2.service
                return 0
            fi

            echo ">> 发现 ${#ARIA2_CONTROL_FILES[@]} 个未完成任务，正在断点同步数据、控制文件与种子元数据..."
            for ctl in "${ARIA2_CONTROL_FILES[@]}"; do
                data_target="${ctl%.aria2}"
                rel_ctl="${ctl#"${SRC_DIR}/"}"
                dest_subdir=$(dirname "${DEST_DIR}/${rel_ctl}")
                mkdir -p "${dest_subdir}"

                rsync -avP --partial "${ctl}" "${dest_subdir}/"
                MIGRATED_FILES+=("${ctl}")

                if [ -e "${data_target}" ]; then
                    rsync -avP --partial "${data_target}" "${dest_subdir}/"
                    MIGRATED_FILES+=("${data_target}")
                fi

                if [ -f "${data_target}.torrent" ]; then
                    rsync -avP --partial "${data_target}.torrent" "${dest_subdir}/"
                    MIGRATED_FILES+=("${data_target}.torrent")
                fi
            done

            while IFS= read -r tor; do
                if [ -f "$tor" ]; then
                    rsync -avP --partial "$tor" "${DEST_DIR}/"
                    MIGRATED_FILES+=("$tor")
                fi
            done < <(find "${SRC_DIR}" -maxdepth 1 -name "*.torrent")
            ;;

        2)
            echo ">> 正在完整断点同步下载目录下全部数据..."
            rsync -avP --partial "${SRC_DIR}/" "${DEST_DIR}/"
            while IFS= read -r item; do
                [ -e "$item" ] && MIGRATED_FILES+=("$item")
            done < <(find "${SRC_DIR}" -mindepth 1 -maxdepth 1)
            ;;

        3)
            echo ">> 正在根据关键字 [${FILE_KEYWORD}] 匹配任务并断点同步..."
            MATCH_FOUND=false
            while IFS= read -r item; do
                MATCH_FOUND=true
                rel_item="${item#"${SRC_DIR}/"}"
                dest_subdir=$(dirname "${DEST_DIR}/${rel_item}")
                mkdir -p "${dest_subdir}"

                rsync -avP --partial "${item}" "${dest_subdir}/"
                MIGRATED_FILES+=("${item}")

                if [ -f "${item}.aria2" ]; then
                    rsync -avP --partial "${item}.aria2" "${dest_subdir}/"
                    MIGRATED_FILES+=("${item}.aria2")
                fi
                if [ -f "${item}.torrent" ]; then
                    rsync -avP --partial "${item}.torrent" "${dest_subdir}/"
                    MIGRATED_FILES+=("${item}.torrent")
                fi
            done < <(find "${SRC_DIR}" -name "*${FILE_KEYWORD}*" ! -name "*.aria2" ! -name "*.torrent")

            while IFS= read -r ext_file; do
                MATCH_FOUND=true
                rsync -avP --partial "${ext_file}" "${DEST_DIR}/"
                MIGRATED_FILES+=("${ext_file}")
            done < <(find "${SRC_DIR}" -maxdepth 1 -name "*${FILE_KEYWORD}*.torrent" -o -name "*${FILE_KEYWORD}*.aria2")

            if [ "$MATCH_FOUND" = false ]; then
                echo "未匹配到任何包含关键字 [${FILE_KEYWORD}] 的文件。"
                ${SYSTEMCTL_CMD} start aria2.service
                return 0
            fi
            ;;
    esac

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
    ${SYSTEMCTL_CMD} start aria2.service

    echo ""
    echo ">> 迁移完成！Aria2 已重新载入元数据并开始自检校验断点。"
    echo ""

    if [ "$MIGRATE_TYPE" == "1" ] || [ "$MIGRATE_TYPE" == "3" ]; then
        read -rp "是否删除源磁盘上对应的旧数据 (含数据、.aria2 及种子) 以释放空间? [Y/n 默认: Y]: " CLEAN_OLD
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
            echo ">> 正在清理已迁移的原文件、校验文件及关联种子文件..."
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

    install_packages rsync findutils python3 curl

    if ! ${SYSTEMCTL_CMD} is-active --quiet aria2.service 2>/dev/null; then
        echo ">> 检测到 Aria2 服务未运行，正在启动以调取任务状态..."
        ${SYSTEMCTL_CMD} start aria2.service
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
        read -rp "请输入转移存放的目标新磁盘目录: " DEST_DIR
        if [ -n "$DEST_DIR" ]; then
            DEST_DIR="${DEST_DIR%/}"
            break
        fi
        echo "目标目录不能为空，请重新输入！"
    done

    mkdir -p "${DEST_DIR}"
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
    lines.append(f">> 以下任务已 100% 下载完成，可转移 ({len(groups)} 个):")
    lines.append("--------------------------------------------------")
    for index, group in enumerate(groups, start=1):
        name, status, _gid, picked_files, removable, size, _torrent = group
        total_files += len(picked_files)
        total_size += size
        marker = "  << 做种/暂停中，转移前会先停止它" if removable else ""
        lines.append(f"   [{index:>2}] [{status_text(status)}] {name}  ({len(picked_files)} 个文件 / {human(size)}){marker}")
        if index <= FILE_PREVIEW_LIMIT:
            for path in picked_files[:5]:
                lines.append(f"         · {os.path.relpath(path, SRC_DIR)}")
            if len(picked_files) > 5:
                lines.append(f"         · ... 以及其余 {len(picked_files) - 5} 个文件")
    lines.append("--------------------------------------------------")
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
        echo ">> 检测到 ${#TORRENT_FILES[@]} 个已选任务带有同名 .torrent 元数据文件:"
        for torrent_path in "${TORRENT_FILES[@]:0:10}"; do
            echo "   - ${torrent_path}"
        done
        if [ ${#TORRENT_FILES[@]} -gt 10 ]; then
            echo "   ... 以及其余 $(( ${#TORRENT_FILES[@]} - 10 )) 个"
        fi
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
    if [ ${#FORCE_GIDS[@]} -gt 0 ]; then
        echo ">> 其中以下任务仍在做种/暂停中，转移前会先停止它们 (之后需重新添加种子才能继续做种):"
        for ((i=0; i<TASK_TOTAL; i++)); do
            if [ -n "${CHOSEN_MAP[$i]}" ] && [ "${T_REMOVABLE[$i]}" = "1" ]; then
                echo "   - ${T_NAME[$i]}"
            fi
        done
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
    (
        cd "${SRC_DIR}"
        for it in "${COMPLETED_FILES[@]}"; do
            echo "   -> 正在转移: ${it}..."
            rsync -avP --partial -R "${it}" "${DEST_DIR}/"
        done
    )

    echo ""
    echo ">> [成功] 已完成任务的数据已全部同步到目标新磁盘！"
    read -rp "是否彻底删除原路径 (${SRC_DIR}) 上已转移的文件以释放空间? [Y/n 默认: Y]: " CLEAN_SRC
    CLEAN_SRC="${CLEAN_SRC:-Y}"
    if [[ "$CLEAN_SRC" =~ ^[Yy]$ ]]; then
        echo ">> 正在清理原路径上的已转移数据..."
        for it in "${COMPLETED_FILES[@]}"; do
            rm -f "${SRC_DIR}/${it}"
        done
        find "${SRC_DIR}" -mindepth 1 -type d -empty -delete 2>/dev/null || true

        # 数据已不在原盘上的 .aria2 控制标记属于失效碎片，一并清掉
        while IFS= read -r ctl; do
            if [ ! -e "${ctl%.aria2}" ]; then
                rm -f "$ctl"
            fi
        done < <(find "${SRC_DIR}" -type f -name "*.aria2" 2>/dev/null)

        echo ">> 原磁盘空间已释放！所有正在下载的任务继续正常运行。"

        # 原文件已删除，Aria2 里的这些记录已失效 (AriaNg 会显示文件缺失)，可选择一并清除
        if [ ${#ALL_GIDS[@]} -gt 0 ]; then
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
    echo ">> 正在扫描源目录: 找出不被任何 Aria2 任务管理、且无 .aria2 控制文件的游离目标..."

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
    for ext in [".torrent.无码破解", ".torrent", ".aria2"]:
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

# 磁盘上所有 .aria2 控制文件对应的基准名: 存在即代表任务未完成/仍被接管
control_bases = {item[:-6].lower() for item in entries if item.endswith(".aria2")}
records = []
skipped_managed = 0
for item in entries:
    item_lower = item.lower()
    # 规则 1: 忽略隐藏文件、.aria2 控制文件自身、.torrent 种子文件
    if item.startswith(".") or item.endswith(".aria2") or item.endswith(".torrent"):
        continue
    # 规则 2: 存在同名 .aria2 控制文件，说明任务正在等待/下载/未完成
    if item_lower in control_bases:
        skipped_managed += 1
        continue
    # 规则 3: 命中 RPC 任务清单（含 [METADATA] 提取名）
    if item_lower in managed_names:
        skipped_managed += 1
        continue
    # 规则 4: 去掉包装前缀后再比对一次 (如 [98t.tv]xxx)
    clean_item = re.sub(r"^(\[[^\]]+\])+", "", item).strip().lower()
    if clean_item in managed_names or clean_item in control_bases:
        skipped_managed += 1
        continue
    full_path = os.path.join(SRC_DIR, item)
    records.append((item, os.path.isdir(full_path), tree_size(full_path)))

total_bytes = sum(size for _n, _d, size in records)
lines = []
lines.append(">> 游离判定依据: 不在任何 Aria2 任务清单内，且磁盘上没有同名 .aria2 控制文件。")
lines.append(f">> 源目录: {SRC_DIR}")
lines.append(f">> RPC 任务总数: {task_count} 个 (解析出受管理名称 {len(managed_names)} 个)")
lines.append(f">> 磁盘 .aria2 控制基准名: {len(control_bases)} 个")
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
        echo ">> 没有发现游离文件/目录: 目录内所有内容都已被 Aria2 任务管理或存在 .aria2 控制文件。"
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

    local total_gb page_size=15
    total_gb=$(awk "BEGIN {printf \"%.2f\", ${total_bytes}/1024/1024/1024}")

    local i kind
    if [ "$ORPHAN_TOTAL" -gt "$page_size" ]; then
        read -rp "匹配到的游离目标较多 (${ORPHAN_TOTAL} 项)，是否翻页查看清单? [Y/n 默认: Y]: " VIEW_PAGER
        VIEW_PAGER="${VIEW_PAGER:-Y}"
        if [[ "$VIEW_PAGER" =~ ^[Yy]$ ]]; then
            local current_idx=0 page_total page_no
            page_total=$(( (ORPHAN_TOTAL + page_size - 1) / page_size ))
            while [ "$current_idx" -lt "$ORPHAN_TOTAL" ]; do
                clear 2>/dev/null || true
                page_no=$(( current_idx / page_size + 1 ))
                echo "=== 游离文件/目录清单 (第 ${page_no} / ${page_total} 页，共 ${ORPHAN_TOTAL} 项) ==="
                for ((i=current_idx; i<current_idx+page_size && i<ORPHAN_TOTAL; i++)); do
                    if [ "${O_ISDIR[$i]}" = "1" ]; then kind="[目录]"; else kind="[文件]"; fi
                    printf ' [%d] %s %s (%s)\n' "$((i+1))" "$kind" "${O_NAME[$i]}" "${O_HUMAN[$i]}"
                done
                echo "--------------------------------------------------"
                current_idx=$((current_idx + page_size))
                if [ "$current_idx" -lt "$ORPHAN_TOTAL" ]; then
                    read -rp "按 [Enter] 查看下一页，输入 [q] 退出预览，输入 [g] 直接进入同步: " PAGE_ACTION
                    case "$PAGE_ACTION" in
                        [Qq]) break ;;
                        [Gg]) break ;;
                    esac
                else
                    read -rp "已浏览全部游离目标，按 [Enter] 继续..." __dummy_page
                fi
            done
        fi
    else
        echo ""
        echo "---------------- 游离文件/目录清单 ------------------"
        for ((i=0; i<ORPHAN_TOTAL; i++)); do
            if [ "${O_ISDIR[$i]}" = "1" ]; then kind="[目录]"; else kind="[文件]"; fi
            printf ' [%d] %s %s (%s)\n' "$((i+1))" "$kind" "${O_NAME[$i]}" "${O_HUMAN[$i]}"
        done
        echo "--------------------------------------------------"
    fi

    echo ""
    echo ">> 共发现 ${ORPHAN_TOTAL} 个游离目标 / 约 ${total_gb} GB"
    read -rp "确认开始将这些游离目标同步到 ${DEST_DIR}? [Y/n 默认: Y]: " CONFIRM_ORPHAN
    CONFIRM_ORPHAN="${CONFIRM_ORPHAN:-Y}"
    if [[ ! "$CONFIRM_ORPHAN" =~ ^[Yy]$ ]]; then
        echo ">> 操作已取消。"
        rm -rf "${scan_tmp}"
        return 0
    fi

    declare -a TRANSFER_FAILED=()
    local name
    echo ""
    echo ">> 正在同步游离数据到新磁盘 (保持相对目录层级)..."
    for ((i=0; i<ORPHAN_TOTAL; i++)); do
        name="${O_NAME[$i]}"
        echo "   -> 正在转移: ${name}..."
        # 以 ${SRC_DIR}/./ 形式传入，-R 会以 ./ 之后的部分作为目标相对路径
        if ! rsync -avP --partial -R "${SRC_DIR}/./${name}" "${DEST_DIR}/"; then
            echo "   !! [失败] 同步出错: ${name}"
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

    local RPC_PORT RPC_SECRET
    RPC_PORT=$(grep -E "^rpc-listen-port=" "${CONF_FILE}" | cut -d'=' -f2- | tr -d ' \r')
    RPC_PORT="${RPC_PORT:-$DEFAULT_PORT}"
    RPC_SECRET=$(grep -E "^rpc-secret=" "${CONF_FILE}" | cut -d'=' -f2- | tr -d ' \r')

    if ! ${SYSTEMCTL_CMD} is-active --quiet aria2.service 2>/dev/null; then
        echo ">> 检测到 Aria2 服务未运行，正在启动..."
        ${SYSTEMCTL_CMD} start aria2.service
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
    local CURRENT_DIR
    CURRENT_DIR=$(get_current_download_dir)
    read -rp "请输入要扫描的种子所在目录 [默认: ${CURRENT_DIR}]: " TARGET_SCAN_DIR
    TARGET_SCAN_DIR="${TARGET_SCAN_DIR:-$CURRENT_DIR}"
    TARGET_SCAN_DIR="${TARGET_SCAN_DIR%/}"

    if [ ! -d "${TARGET_SCAN_DIR}" ]; then
        echo "错误: 目录 ${TARGET_SCAN_DIR} 不存在！"
        return 1
    fi

    echo ">> 正在扫描 ${TARGET_SCAN_DIR} 下的 .torrent 种子文件..."
    mapfile -t TORRENT_FILES < <(find "${TARGET_SCAN_DIR}" -maxdepth 2 -name "*.torrent")

    if [ ${#TORRENT_FILES[@]} -eq 0 ]; then
        echo "提示: 在该目录下未找到任何 .torrent 文件。"
        return 0
    fi

    echo ">> 找到 ${#TORRENT_FILES[@]} 个种子文件，正在校验未完成状态并注入 Aria2..."

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
            ((resumed_count++))
        else
            echo "   [失败] 注入失败，RPC 响应: ${resp}"
        fi
    done

    echo ""
    echo ">> 处理完毕！共成功推送并激活 ${resumed_count} 个未完成任务。"
    echo ">> 请打开 AriaNg 查看任务列表，任务会先进行“检查中 (Checking)”，自检完成后将自动断点续传。"
}

# ==================== 模块 8-2: 一键继续下载异常停止的任务 ====================
# 说明: aria2 的 aria2.unpause 仅适用于 paused 状态，对已停止(error/removed)的任务会直接拒绝，
#       因此这里按原任务信息重新加入下载队列(复用 .aria2 断点，不会重新下载已完成的数据)。
resume_stopped_tasks() {
    echo ""
    echo "---- [异常停止任务] 一键继续下载 ----"
    echo ">> 正在分析 Aria2『已停止』列表: 只筛选未下载完整(报错 / 被移除 / 磁盘写满等)的任务..."
    echo "   (正常下载完成的 100% 任务会被自动跳过)"

    ARIA2_CONF_FILE="${CONF_FILE}" python3 - <<'PYEOF'
import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

CONF_FILE = os.environ.get("ARIA2_CONF_FILE", "")
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


def can_retry(task):
    if task.get("infoHash"):
        return True
    return len(file_uris(task)) > 0


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
print(">> 以下任务已停止但并未下载完整，可尝试重新加入下载队列:")
print("   " + "-" * 76)
for index, item in enumerate(candidates, start=1):
    task = item[0]
    left = item[1]
    status = STATUS_TEXT.get(task.get("status") or "", task.get("status") or "?")
    kind = "BT  " if task.get("infoHash") else "HTTP"
    print("   [%2d] [%s] %s %s" % (index, status, kind, task_name(task)))
    print("        剩余约 %s / 目录 %s" % (human(left) if left > 0 else "未知", task.get("dir") or "?"))
    message = (task.get("errorMessage") or "").strip()
    code = (task.get("errorCode") or "").strip()
    if message:
        print("        错误: %s%s" % (message, (" (code %s)" % code) if code else ""))
    if (task.get("status") or "") == "removed":
        print("        %s注意: 该任务是被移除的(可能由手动操作或转移脚本触发)%s" % (YELLOW, NC))
    if not can_retry(task):
        print("        %s无法自动重试: 缺少种子 / 链接信息%s" % (YELLOW, NC))
print("   " + "-" * 76)


def ask(prompt):
    try:
        return input(prompt)
    except (EOFError, KeyboardInterrupt):
        print("")
        return None


answer = ask("请输入要重试的任务编号 (空格或逗号分隔；直接回车 = 全部 %d 个；输入 0 取消): " % len(candidates))
if answer is None:
    print(">> 输入已中断，操作取消。")
    sys.exit(0)
answer = answer.strip()
if answer == "0":
    print(">> 操作已取消。")
    sys.exit(0)

chosen = []
if answer == "":
    chosen = list(range(len(candidates)))
else:
    for token in answer.replace(",", " ").split():
        if not token.isdigit():
            print("   >> 忽略无效编号: %s" % token)
            continue
        number = int(token)
        if number < 1 or number > len(candidates):
            print("   >> 忽略超出范围的编号: %s" % token)
            continue
        if (number - 1) not in chosen:
            chosen.append(number - 1)

if not chosen:
    print(">> 未选择任何任务，操作取消。")
    sys.exit(0)

confirm = ask("确认重新加入以上 %d 个任务以继续下载? [Y/n 默认: Y]: " % len(chosen))
if confirm is None:
    print(">> 输入已中断，操作取消。")
    sys.exit(0)
confirm = confirm.strip().lower()
if confirm and not confirm.startswith("y"):
    print(">> 操作已取消。")
    sys.exit(0)

print("")
print(">> 正在重新加入任务 (已下载的数据通过断点续传保留，不会从头重新下载)...")
ok_count = 0
fail_count = 0
for index in chosen:
    task = candidates[index][0]
    gid = task.get("gid") or ""
    name = task_name(task)

    # 重新取一次最新状态，避免列表展示后状态发生变化
    fresh, fresh_err = rpc("aria2.tellStatus", [gid])
    if fresh_err or not isinstance(fresh, dict):
        print("   %s!!%s %s: 读取任务状态失败 (%s)" % (RED, NC, name, fresh_err or "无数据"))
        fail_count += 1
        continue
    if is_normal_complete(fresh):
        print("   %s✓%s %s: 已下载完整，无需重试" % (GREEN, NC, name))
        continue

    method, params, desc = build_readd(fresh)
    if method is None:
        print("   %s!%s %s: %s" % (YELLOW, NC, name, desc))
        fail_count += 1
        continue

    result, add_err = rpc(method, params)
    if add_err:
        print("   %s!!%s %s: 重新加入失败 (%s)" % (RED, NC, name, add_err))
        fail_count += 1
        continue

    ok_count += 1
    print("   %s✓%s %s: 已重新加入队列 [%s] -> 新 GID %s" % (GREEN, NC, name, desc, result))

    # 旧记录已失效，清理以免在『已停止』列表里重复出现
    _ignored, purge_err = rpc("aria2.removeDownloadResult", [gid])
    if purge_err:
        print("      (提示: 旧记录清理失败: %s，可用菜单 9 -> 3 清理)" % purge_err)

print("")
if ok_count:
    print("%s>> 完成: %d 个任务已重新加入下载队列，正在断点续传。%s" % (GREEN, ok_count, NC))
if fail_count:
    print("%s>> 有 %d 个任务未能自动重试，请参考上方原因处理。%s" % (YELLOW, fail_count, NC))
print(">> 可打开 AriaNg 查看: 任务会先『检查中 (Checking)』，随后自动断点续传。")
PYEOF
}

# ==================== 模块 9: 实用辅助与清理工具箱 ====================
manage_utils_menu() {
    while true; do
        echo ""
        echo "=========================================="
        echo "        Aria2 辅助运维与清理工具箱        "
        echo "=========================================="
        echo " 1. 清理已完成任务的 .torrent 种子文件 (保留正在下载的种子)"
        echo " 2. 清理孤立的 .aria2 校验碎片 (源数据已删除的残留文件)"
        echo " 3. 彻底清空 session 中已完成/已停止的历史任务 (减小体积)"
        echo " 4. 一键服务与网络健康诊断 (检查端口、进程、防火墙与定时器)"
        echo " 0. 返回上级菜单"
        echo "=========================================="
        read -rp "请选择操作 [0-4 默认: 0]: " UTIL_CHOICE
        UTIL_CHOICE="${UTIL_CHOICE:-0}"

        case "$UTIL_CHOICE" in
            1)
                DEFAULT_CLEAN_DIR=$(get_current_download_dir)
                read -rp "请输入要清理的下载目录路径 [默认: ${DEFAULT_CLEAN_DIR}]: " SCAN_DIR
                SCAN_DIR="${SCAN_DIR:-$DEFAULT_CLEAN_DIR}"
                SCAN_DIR="${SCAN_DIR%/}"

                if [ ! -d "${SCAN_DIR}" ]; then
                    echo "错误: 目录 ${SCAN_DIR} 不存在！"
                    continue
                fi

                echo ">> 正在扫描并分析 ${SCAN_DIR} 下的种子文件状态..."
                mapfile -t ALL_TORRENTS < <(find "${SCAN_DIR}" -type f -name "*.torrent")

                if [ ${#ALL_TORRENTS[@]} -eq 0 ]; then
                    echo "提示: 在指定目录下没有找到任何 .torrent 文件。"
                    continue
                fi

                declare -a SAFE_TO_DELETE=()

                for tor in "${ALL_TORRENTS[@]}"; do
                    base_name="${tor%.torrent}"
                    
                    if [ -f "${base_name}.aria2" ] || [ -f "${tor}.aria2" ]; then
                        continue
                    fi

                    SAFE_TO_DELETE+=("${tor}")
                done

                if [ ${#SAFE_TO_DELETE[@]} -eq 0 ]; then
                    echo ">> 扫描完成！未检测到可清理的已完成种子 (所有种子任务均正在下载中或未找到对应项)。"
                    continue
                fi

                echo ""
                echo ">> 找到以下 ${#SAFE_TO_DELETE[@]} 个已下载完成/无活跃下载任务的种子文件:"
                for item in "${SAFE_TO_DELETE[@]}"; do
                    echo "   - $(basename "$item")"
                done
                echo ""
                read -rp "确认彻底删除这些已完成的种子文件? [Y/n 默认: Y]: " CONFIRM_DEL
                CONFIRM_DEL="${CONFIRM_DEL:-Y}"
                if [[ "$CONFIRM_DEL" =~ ^[Yy]$ ]]; then
                    for item in "${SAFE_TO_DELETE[@]}"; do
                        rm -f "$item"
                    done
                    echo ">> 清理完成！已释放空间。"
                else
                    echo ">> 操作已取消。"
                fi
                ;;

            2)
                DEFAULT_CLEAN_DIR=$(get_current_download_dir)
                read -rp "请输入要检查的下载目录路径 [默认: ${DEFAULT_CLEAN_DIR}]: " SCAN_DIR
                SCAN_DIR="${SCAN_DIR:-$DEFAULT_CLEAN_DIR}"
                SCAN_DIR="${SCAN_DIR%/}"

                if [ ! -d "${SCAN_DIR}" ]; then
                    echo "错误: 目录 ${SCAN_DIR} 不存在！"
                    continue
                fi

                echo ">> 正在排查孤立的 .aria2 碎片文件 (对应数据已被手工删除)..."
                mapfile -t ARIA2_FILES < <(find "${SCAN_DIR}" -type f -name "*.aria2")
                declare -a ORPHAN_ARIA2=()

                for ctl in "${ARIA2_FILES[@]}"; do
                    data_file="${ctl%.aria2}"
                    if [ ! -e "${data_file}" ]; then
                        ORPHAN_ARIA2+=("${ctl}")
                    fi
                done

                if [ ${#ORPHAN_ARIA2[@]} -eq 0 ]; then
                    echo ">> 未发现孤立的 .aria2 校验文件，环境干净。"
                else
                    echo ">> 发现以下 ${#ORPHAN_ARIA2[@]} 个孤立碎片:"
                    for f in "${ORPHAN_ARIA2[@]}"; do
                        echo "   - $(basename "$f")"
                    done
                    read -rp "确认删除这些无效的 .aria2 碎片? [Y/n 默认: Y]: " CONFIRM_CLEAN_CTL
                    CONFIRM_CLEAN_CTL="${CONFIRM_CLEAN_CTL:-Y}"
                    if [[ "$CONFIRM_CLEAN_CTL" =~ ^[Yy]$ ]]; then
                        for f in "${ORPHAN_ARIA2[@]}"; do
                            rm -f "$f"
                        done
                        echo ">> 碎片清理完毕！"
                    fi
                fi
                ;;

            3)
                echo ">> 正在安全压缩与清理 aria2.session 会话..."
                stop_aria2_safely
                if [ -f "${SESSION_FILE}" ]; then
                    cp "${SESSION_FILE}" "${SESSION_FILE}.bak"
                    echo ">> 已备份原会话为: ${SESSION_FILE}.bak"
                fi
                ${SYSTEMCTL_CMD} start aria2.service
                echo ">> Aria2 服务已重启，会话记录已刷新。"
                ;;

            4)
                echo ""
                echo "=== Aria2 服务与网络健康诊断 ==="
                echo -n "1. Aria2 核心服务状态: "
                if ${SYSTEMCTL_CMD} is-active --quiet aria2.service 2>/dev/null; then
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

                echo -n "4. Trackers 每日定时更新: "
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
                    echo ">> 正在输出 aria2.log (按 Ctrl+C 退出跟踪):"
                    tail -n 50 -f "${LOG_FILE}" || true
                fi
                ;;
            2)
                echo ""
                echo ">> 正在调取 Systemd 服务最近日志:"
                ${SYSTEMCTL_CMD} status aria2.service --no-pager -l || true
                echo ""
                echo ">> 正在输出 journalctl 最近 40 行错误信息:"
                if [ "$IS_ROOT" = true ]; then
                    journalctl -u aria2.service -n 40 --no-pager
                else
                    journalctl --user -u aria2.service -n 40 --no-pager
                fi
                ;;
            3)
                echo ""
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
                ;;
            4)
                echo ""
                echo ">> 最近一次 Tracker 更新服务运行记录:"
                if [ "$IS_ROOT" = true ]; then
                    journalctl -u aria2-update-tracker.service -n 30 --no-pager
                else
                    journalctl --user -u aria2-update-tracker.service -n 30 --no-pager
                fi
                ;;
            5)
                echo ""
                echo ">> 最近一次吸血 Peer 防火墙更新记录:"
                ${SUDO_CMD} journalctl -u aria2-peer-blocker.service -n 30 --no-pager 2>/dev/null || echo "尚未配置或未运行该服务"
                ;;
            6)
                echo ""
                echo ">> 最近一次 Caddy 服务日志:"
                ${SUDO_CMD} journalctl -u caddy -n 30 --no-pager 2>/dev/null || echo "尚未安装 Caddy 服务"
                ;;
            7)
                echo ""
                echo ">> BT 自动筛选守护进程日志:"
                if [ "$IS_ROOT" = true ]; then
                    journalctl -u aria2-filter.service -n 40 -f
                else
                    journalctl --user -u aria2-filter.service -n 40 -f
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

            if ! grep -q "^bt-remove-unselected-file=" "${CONF_FILE}"; then
                echo "bt-remove-unselected-file=true" >> "${CONF_FILE}"
                NEED_RESTART_ARIA2=true
            elif grep -q "^bt-remove-unselected-file=false" "${CONF_FILE}"; then
                sed -i "s|^bt-remove-unselected-file=.*|bt-remove-unselected-file=true|g" "${CONF_FILE}"
                NEED_RESTART_ARIA2=true
            fi

            if ! grep -q "^max-overall-upload-limit=" "${CONF_FILE}"; then
                echo "max-overall-upload-limit=2M" >> "${CONF_FILE}"
                echo "max-upload-limit=2M" >> "${CONF_FILE}"
                NEED_RESTART_ARIA2=true
            fi

            if [ "$NEED_RESTART_ARIA2" = true ]; then
                ${SYSTEMCTL_CMD} restart aria2.service
            fi

            ensure_filter_script "${INPUT_MIN_MB}" "${TARGET_EXTS}"
            [ "$IS_ROOT" = false ] && mkdir -p "${SYSTEMD_DIR}"

            cat > "${SYSTEMD_DIR}/aria2-filter.service" <<EOF
[Unit]
Description=Aria2 BT Automatic Filter Daemon
After=network.target aria2.service
Requires=aria2.service

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
            echo "   未选文件: 自动清理 (bt-remove-unselected-file=true)"
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
            echo ">> 正在调取筛选守护进程实时日志 (按 Ctrl+C 退出):"
            if [ "$IS_ROOT" = true ]; then
                journalctl -u aria2-filter.service -n 40 -f
            else
                journalctl --user -u aria2-filter.service -n 40 -f
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
    echo ">> 过滤条件: 体积小于 ${SIZE_MB}MB (自动保护 .aria2 / .torrent 及正在下载中的任务)..."

    declare -A ACTIVE_TASKS
    while IFS= read -r ctl; do
        ACTIVE_TASKS["$ctl"]=1
        ACTIVE_TASKS["${ctl%.aria2}"]=1
    done < <(find "${TARGET_DIR}" -type f -name "*.aria2" 2>/dev/null)

    declare -a FILES_TO_DELETE=()
    local TOTAL_BYTES=0

    while IFS= read -r file; do
        # .aria2 校验块、.torrent 种子及活跃任务一律跳过:
        # 种子元数据统一由主菜单 [9 -> 1] 的专用清理功能处理，避免误删有效种子
        if [[ -n "${ACTIVE_TASKS[$file]}" ]] || [[ "$file" == *.aria2 ]] || [[ "$file" == *.torrent ]]; then
            continue
        fi

        FILES_TO_DELETE+=("$file")
        local f_size
        f_size=$(stat -c %s "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null || echo 0)
        TOTAL_BYTES=$((TOTAL_BYTES + f_size))
    done < <(find "${TARGET_DIR}" -type f -size -"${SIZE_MB}"M 2>/dev/null)

    local FILE_COUNT=${#FILES_TO_DELETE[@]}
    if [ "$FILE_COUNT" -eq 0 ]; then
        echo ""
        echo ">> 扫描完成: 未找到任何小于 ${SIZE_MB}MB 的文件。"
        return 0
    fi

    local TOTAL_HUMAN
    TOTAL_HUMAN=$(awk "BEGIN {printf \"%.2f\", ${TOTAL_BYTES}/1024/1024}")
    echo ""
    echo ">> 扫描完成！共找到 ${FILE_COUNT} 个符合条件的文件 (总计约 ${TOTAL_HUMAN} MB)。"

    if [ "$FILE_COUNT" -gt 20 ]; then
        read -rp "匹配到的文件较多 (${FILE_COUNT} 个)，是否翻页查看清单? [y/N 默认: N]: " VIEW_PAGER
        VIEW_PAGER="${VIEW_PAGER:-N}"
        if [[ "$VIEW_PAGER" =~ ^[Yy]$ ]]; then
            local page_size=20
            local current_idx=0
            while [ $current_idx -lt "$FILE_COUNT" ]; do
                clear || true
                echo "=== 待清理文件清单 (第 $((current_idx / page_size + 1)) 页 / 共 $(((FILE_COUNT + page_size - 1) / page_size)) 页) ==="
                for ((i=current_idx; i<current_idx+page_size && i<FILE_COUNT; i++)); do
                    echo " [$((i+1))] ${FILES_TO_DELETE[$i]}"
                done
                echo "--------------------------------------------------"
                current_idx=$((current_idx + page_size))
                if [ $current_idx -lt "$FILE_COUNT" ]; then
                    read -rp "按 [Enter] 查看下一页，或输入 [q] 退出预览: " PAGER_ACTION
                    if [[ "$PAGER_ACTION" =~ ^[Qq]$ ]]; then
                        break
                    fi
                else
                    read -rp "已浏览全部文件，按 [Enter] 继续..." _
                fi
            done
        fi
    else
        echo "---------------- 待清理文件列表 ------------------"
        for ((i=0; i<FILE_COUNT; i++)); do
            echo " [$((i+1))] ${FILES_TO_DELETE[$i]}"
        done
        echo "--------------------------------------------------"
    fi

    echo ""
    read -rp "确认彻底删除以上 ${FILE_COUNT} 个小于 ${SIZE_MB}MB 的文件以释放空间? [y/N 默认: N]: " CONFIRM_DEL
    CONFIRM_DEL="${CONFIRM_DEL:-N}"

    if [[ ! "$CONFIRM_DEL" =~ ^[Yy]$ ]]; then
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
    echo "   提示: .torrent 种子文件已自动跳过，如需清理请使用主菜单 [9 -> 1]。"
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
    ${SYSTEMCTL_CMD} stop aria2.service 2>/dev/null || true
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

    read -rp "是否删除配置及脚本目录 (${ARIA2_CONF_DIR})? [y/N 默认: N]: " DEL_CONFIG
    DEL_CONFIG="${DEL_CONFIG:-N}"
    if [[ "$DEL_CONFIG" =~ ^[Yy]$ ]]; then
        rm -rf "${ARIA2_CONF_DIR}"
        echo "已清理配置目录: ${ARIA2_CONF_DIR}"
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
    echo " 1. $([ -f "${ARIA2C_BIN}" ] && echo "重新配置 Aria2 后端 (自动带入当前设置)" || echo "安装 / 配置 Aria2 后端 (默认启用 Trackers 自动更新)")"
    echo " 2. Aria2 常用核心设置 (下载目录 / 并发数 / 做种 / 上下载限速 / 占位清理)"
    echo " 3. 手动更新 / 设置 BT Trackers (双源拉取 / 自定义)"
    echo " 4. 启用 / 停用 Trackers 自动更新"
    echo " 5. BT 吸血 Peer 防火墙拦截管理 (ipset+iptables / 默认开启 / 每日更新)"
    echo " 6. 迁移下载任务到新磁盘 (迁移 未完成 / 全部 任务并切换工作路径)"
    echo " 7. 转移已完成下载到新磁盘 (含做种与已暂停任务 / 可清理游离文件)"
    echo " 8. 恢复 / 重试未完成的下载 (扫描种子断点续传 / 一键重试异常停止)"
    echo " 9. Aria2 实用辅助与清理工具箱 (清理已完成种子 / 碎片清理 / 健康自检)"
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