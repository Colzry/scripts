#!/usr/bin/env bash
set -e

# ==================== 环境与权限自适应 ====================
CURRENT_USER="$USER"
USER_HOME="$HOME"
IS_ROOT=false

if [ "$EUID" -eq 0 ]; then
    IS_ROOT=true
    SUDO_CMD=""
    SYSTEMD_DIR="/etc/systemd/system"
    SYSTEMCTL_CMD="systemctl"
else
    IS_ROOT=false
    SUDO_CMD="sudo"
    SYSTEMD_DIR="${USER_HOME}/.config/systemd/user"
    SYSTEMCTL_CMD="systemctl --user"
fi

DEFAULT_DOWNLOAD_DIR="${USER_HOME}/Downloads"
DEFAULT_PORT="6800"
DEFAULT_ARIANG_PORT="6880"
GH_PROXY="https://gitpy.223327.xyz/https://github.com"
ARIANG_DIR="${USER_HOME}/.aria2/ariang"

# ==================== 基础依赖检测 ====================
install_packages() {
    local pkgs=("$@")
    echo ">> 检查并安装依赖: ${pkgs[*]}..."
    if command -v apt-get &>/dev/null; then
        ${SUDO_CMD} apt-get update -y && ${SUDO_CMD} apt-get install -y "${pkgs[@]}"
    elif command -v pacman &>/dev/null; then
        ${SUDO_CMD} pacman -Sy --noconfirm "${pkgs[@]}"
    elif command -v dnf &>/dev/null; then
        ${SUDO_CMD} dnf install -y "${pkgs[@]}"
    fi
}

# ==================== 安装 Caddy ====================
ensure_caddy() {
    if command -v caddy &>/dev/null; then
        echo ">> Caddy 已安装，跳过安装步骤。"
        return 0
    fi

    echo ">> 正在安装 Caddy..."
    if command -v apt-get &>/dev/null; then
        ${SUDO_CMD} apt-get update -y
        ${SUDO_CMD} apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | ${SUDO_CMD} gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | ${SUDO_CMD} tee /etc/apt/sources.list.d/caddy-stable.list
        ${SUDO_CMD} apt-get update -y
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

# ==================== 模块 1: 安装 Aria2 后端 ====================
install_aria2() {
    echo ""
    echo "=========================================="
    echo "            安装 / 配置 Aria2 后端        "
    echo "=========================================="

    read -rp "请输入下载目录路径 [默认: ${DEFAULT_DOWNLOAD_DIR}]: " INPUT_DIR
    DOWNLOAD_DIR="${INPUT_DIR:-$DEFAULT_DOWNLOAD_DIR}"

    read -rp "请输入 Aria2 RPC 监听端口 [默认: ${DEFAULT_PORT}]: " INPUT_PORT
    RPC_PORT="${INPUT_PORT:-$DEFAULT_PORT}"

    while true; do
        read -rp "请输入 RPC 密钥 (rpc-secret，不能为空): " RPC_SECRET
        if [ -n "$RPC_SECRET" ]; then
            break
        fi
        echo "RPC 密钥不能为空，请重新输入！"
    done

    echo ""
    read -rp "是否顺带安装 AriaNg Web 前端 (Caddy 反代模式)? (y/N): " WITH_ARIANG

    echo ""
    echo "=== Aria2 配置概要 ==="
    echo "运行模式: $([ "$IS_ROOT" = true ] && echo "Root 系统模式" || echo "普通用户模式 ($CURRENT_USER)")"
    echo "下载目录: ${DOWNLOAD_DIR}"
    echo "RPC 端口: ${RPC_PORT}"
    echo "RPC 密钥: ${RPC_SECRET}"
    echo "顺带安装 AriaNg: $([[ "$WITH_ARIANG" =~ ^[Yy]$ ]] && echo "是" || echo "否")"
    echo "======================"
    read -rp "确认开始安装 Aria2? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "已取消安装。"
        return 0
    fi

    # 安装依赖与二进制文件
    install_packages curl wget tar
    echo ">> 正在下载 Aria2 增强版..."
    ARIA2_URL="${GH_PROXY}/P3TERX/Aria2-Pro-Core/releases/download/1.36.0_2021.08.22/aria2-1.36.0-static-linux-amd64.tar.gz"
    TMP_DIR=$(mktemp -d)
    wget -q --show-progress -O "${TMP_DIR}/aria2.tar.gz" "${ARIA2_URL}"

    echo ">> 解压并安装到 /usr/bin/aria2c..."
    tar -zxvf "${TMP_DIR}/aria2.tar.gz" -C "${TMP_DIR}"
    ${SUDO_CMD} mv "${TMP_DIR}/aria2c" /usr/bin/aria2c
    ${SUDO_CMD} chmod +x /usr/bin/aria2c
    rm -rf "${TMP_DIR}"

    # 创建必要目录与配置
    mkdir -p "${DOWNLOAD_DIR}"
    mkdir -p "${USER_HOME}/.aria2/scripts"
    touch "${USER_HOME}/.aria2/aria2.session"

    echo ">> 写入 aria2.conf..."
    cat > "${USER_HOME}/.aria2/aria2.conf" <<EOF
## 文件保存设置 ##
dir=${DOWNLOAD_DIR}
disk-cache=64M
file-allocation=falloc
continue=true

## 下载连接设置 ##
max-concurrent-downloads=5
max-connection-per-server=64
min-split-size=4M
split=64
disable-ipv6=true

## 进度保存设置 ##
input-file=${USER_HOME}/.aria2/aria2.session
save-session=${USER_HOME}/.aria2/aria2.session
save-session-interval=60

## RPC 设置 ##
enable-rpc=true
rpc-allow-origin-all=true
rpc-listen-all=true
rpc-listen-port=${RPC_PORT}
rpc-secret=${RPC_SECRET}

## BT/PT 设置 ##
bt-tracker=
EOF

    # Tracker 脚本
    cat > "${USER_HOME}/.aria2/scripts/update_tracker.sh" <<EOF
#!/usr/bin/env bash
CONF_FILE="${USER_HOME}/.aria2/aria2.conf"
TRACKER_URL="https://bitbucket.org/xiu2/trackerslistcollection/raw/master/best.txt"

list=\$(curl -sSL "\${TRACKER_URL}" | sed '/^$/d' | paste -sd "," -)
if [ -z "\$list" ]; then
    exit 1
fi

if grep -q "^bt-tracker=" "\$CONF_FILE"; then
    sed -i "s|^bt-tracker=.*|bt-tracker=\${list}|g" "\$CONF_FILE"
else
    echo "bt-tracker=\${list}" >> "\$CONF_FILE"
fi

${SYSTEMCTL_CMD} restart aria2.service
EOF
    chmod +x "${USER_HOME}/.aria2/scripts/update_tracker.sh"

    # 注册 Systemd 服务
    [ "$IS_ROOT" = false ] && mkdir -p "${SYSTEMD_DIR}"

    ${SUDO_CMD} bash -c "cat > '${SYSTEMD_DIR}/aria2.service'" <<EOF
[Unit]
Description=Aria2c Download Manager
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/aria2c --conf-path=${USER_HOME}/.aria2/aria2.conf
Restart=on-failure

[Install]
WantedBy=default.target
EOF

    ${SUDO_CMD} bash -c "cat > '${SYSTEMD_DIR}/aria2-update-tracker.service'" <<EOF
[Unit]
Description=Update Aria2 BT Trackers
After=network.target

[Service]
Type=oneshot
ExecStart=${USER_HOME}/.aria2/scripts/update_tracker.sh
EOF

    ${SUDO_CMD} bash -c "cat > '${SYSTEMD_DIR}/aria2-update-tracker.timer'" <<EOF
[Unit]
Description=Run Aria2 Tracker Update Daily

[Timer]
OnBootSec=10min
OnUnitActiveSec=24h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # 启动与使能
    ${SYSTEMCTL_CMD} daemon-reload
    ${SYSTEMCTL_CMD} enable --now aria2.service
    ${SYSTEMCTL_CMD} enable --now aria2-update-tracker.timer

    # 首次尝试拉取 Tracker
    bash "${USER_HOME}/.aria2/scripts/update_tracker.sh" 2>/dev/null || true

    if [ "$IS_ROOT" = false ] && command -v loginctl &>/dev/null; then
        sudo loginctl enable-linger "${CURRENT_USER}" 2>/dev/null || true
    fi

    echo ""
    echo ">> Aria2 后端已部署成功！"
    echo "   RPC 端口: ${RPC_PORT}"
    echo "   RPC 密钥: ${RPC_SECRET}"

    # 级联安装前端
    if [[ "$WITH_ARIANG" =~ ^[Yy]$ ]]; then
        install_ariang "${RPC_PORT}"
    fi
}

# ==================== 模块 2: 单独安装/配置 AriaNg (使用 Caddy) ====================
install_ariang() {
    local target_rpc_port="$1"

    echo ""
    echo "=========================================="
    echo "     安装 / 配置 AriaNg 前端 (Caddy 反代)  "
    echo "=========================================="

    # 如果没有传入端口，则从配置文件读取或交互询问
    if [ -z "$target_rpc_port" ]; then
        if [ -f "${USER_HOME}/.aria2/aria2.conf" ]; then
            target_rpc_port=$(grep -E "^rpc-listen-port=" "${USER_HOME}/.aria2/aria2.conf" | cut -d'=' -f2 | tr -d ' \r')
        fi
        target_rpc_port="${target_rpc_port:-$DEFAULT_PORT}"
        read -rp "请输入后端的 Aria2 RPC 端口 [默认: ${target_rpc_port}]: " INPUT_TARGET_PORT
        target_rpc_port="${INPUT_TARGET_PORT:-$target_rpc_port}"
    fi

    read -rp "请输入 AriaNg 网页访问端口 [默认: ${DEFAULT_ARIANG_PORT}]: " INPUT_ARIANG_PORT
    ARIANG_PORT="${INPUT_ARIANG_PORT:-$DEFAULT_ARIANG_PORT}"

    ensure_caddy
    install_packages curl wget unzip

    echo ">> 正在下载 AriaNg (All-In-One)..."
    mkdir -p "${ARIANG_DIR}"
    # 确保 Caddy 服务用户（通常为 caddy 或 www-data）有读取静态文件的目录权限
    chmod o+rx "${USER_HOME}" "${USER_HOME}/.aria2" "${ARIANG_DIR}" 2>/dev/null || true

    ARIANG_DL_URL="${GH_PROXY}/mayswind/AriaNg/releases/download/1.3.7/AriaNg-1.3.7-AllInOne.zip"
    TMP_ARIANG=$(mktemp -d)
    wget -q --show-progress -O "${TMP_ARIANG}/ariang.zip" "${ARIANG_DL_URL}"
    unzip -qo "${TMP_ARIANG}/ariang.zip" -d "${ARIANG_DIR}"
    chmod -R o+r "${ARIANG_DIR}"
    rm -rf "${TMP_ARIANG}"

    echo ">> 配置 Caddyfile (端口: ${ARIANG_PORT} -> RPC: ${target_rpc_port})..."
    ${SUDO_CMD} mkdir -p /etc/caddy
    ${SUDO_CMD} bash -c "cat > /etc/caddy/Caddyfile" <<EOF
:${ARIANG_PORT} {
    root * ${ARIANG_DIR}
    file_server

    handle /jsonrpc* {
        reverse_proxy 127.0.0.1:${target_rpc_port}
    }
}
EOF

    echo ">> 启动 / 重启 Caddy 服务..."
    ${SUDO_CMD} systemctl daemon-reload
    ${SUDO_CMD} systemctl enable --now caddy
    ${SUDO_CMD} systemctl restart caddy

    echo ""
    echo ">> AriaNg (Caddy 反代) 配置完成并已启动！"
    echo "=========================================="
    echo "单端口 SSH 隧道映射方式:"
    echo "  只需在本地电脑执行这一条命令:"
    echo "  ssh -L ${ARIANG_PORT}:localhost:${ARIANG_PORT} ${CURRENT_USER}@<你的服务器IP>"
    echo ""
    echo "本地浏览器设置方式:"
    echo "  1. 打开 http://localhost:${ARIANG_PORT}"
    echo "  2. 点击左侧 [AriaNg 设置] -> 顶部 [RPC (localhost:6800)] 标签"
    echo "  3. 修改以下项:"
    echo "     - Aria2 RPC 地址:      localhost"
    echo "     - Aria2 RPC 端口:      ${ARIANG_PORT}  (务必改成 ${ARIANG_PORT}，非 6800)"
    echo "     - Aria2 RPC 请求路径:  jsonrpc"
    echo "     - Aria2 RPC 密钥:      输入你在 aria2.conf 中设置的 rpc-secret"
    echo "=========================================="
}

# ==================== 模块 3: 单独卸载 AriaNg ====================
uninstall_ariang() {
    echo ""
    read -rp "确定要卸载 AriaNg 前端与停止 Caddy 吗? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "已取消。"
        return 0
    fi

    echo ">> 正在停止并禁用 caddy 服务..."
    ${SUDO_CMD} systemctl stop caddy 2>/dev/null || true
    ${SUDO_CMD} systemctl disable caddy 2>/dev/null || true

    echo ">> 正在清理 Caddyfile 与 AriaNg 静态目录..."
    ${SUDO_CMD} rm -f /etc/caddy/Caddyfile
    rm -rf "${ARIANG_DIR}"

    echo ">> AriaNg 前端已完全卸载。"
}

# ==================== 模块 4: 完整卸载 (全部组件) ====================
uninstall_all() {
    echo ""
    echo "=========================================="
    echo "        卸载 Aria2 与 AriaNg 全部组件     "
    echo "=========================================="
    read -rp "确定要卸载所有相关服务吗? (y/N): " CONFIRM_UNINSTALL
    if [[ ! "$CONFIRM_UNINSTALL" =~ ^[Yy]$ ]]; then
        echo "已取消卸载。"
        return 0
    fi

    echo ">> 正在停止并禁用 Aria2 与 Caddy 服务..."
    ${SYSTEMCTL_CMD} stop aria2.service 2>/dev/null || true
    ${SYSTEMCTL_CMD} stop aria2-update-tracker.timer 2>/dev/null || true
    ${SYSTEMCTL_CMD} stop aria2-update-tracker.service 2>/dev/null || true
    ${SUDO_CMD} systemctl stop caddy 2>/dev/null || true

    ${SYSTEMCTL_CMD} disable aria2.service 2>/dev/null || true
    ${SYSTEMCTL_CMD} disable aria2-update-tracker.timer 2>/dev/null || true
    ${SYSTEMCTL_CMD} disable aria2-update-tracker.service 2>/dev/null || true
    ${SUDO_CMD} systemctl disable caddy 2>/dev/null || true

    echo ">> 正在删除 systemd 服务配置文件..."
    ${SUDO_CMD} rm -f "${SYSTEMD_DIR}/aria2.service"
    ${SUDO_CMD} rm -f "${SYSTEMD_DIR}/aria2-update-tracker.service"
    ${SUDO_CMD} rm -f "${SYSTEMD_DIR}/aria2-update-tracker.timer"
    ${SUDO_CMD} rm -f /etc/caddy/Caddyfile
    ${SYSTEMCTL_CMD} daemon-reload

    echo ">> 正在删除 aria2c 二进制文件..."
    if [ -f "/usr/bin/aria2c" ]; then
        ${SUDO_CMD} rm -f /usr/bin/aria2c
    fi

    read -rp "是否删除配置及脚本目录 (${USER_HOME}/.aria2)? (y/N): " DEL_CONFIG
    if [[ "$DEL_CONFIG" =~ ^[Yy]$ ]]; then
        rm -rf "${USER_HOME}/.aria2"
        echo "已清理配置目录: ${USER_HOME}/.aria2"
    fi

    read -rp "是否清理下载目录? (强烈建议输入 n 保留已有文件) (y/N): " DEL_DOWNLOADS
    if [[ "$DEL_DOWNLOADS" =~ ^[Yy]$ ]]; then
        read -rp "请输入要清空的下载目录绝对路径: " TARGET_DL_DIR
        if [ -n "$TARGET_DL_DIR" ] && [ -d "$TARGET_DL_DIR" ] && [ "$TARGET_DL_DIR" != "/" ] && [ "$TARGET_DL_DIR" != "$USER_HOME" ]; then
            rm -rf "${TARGET_DL_DIR}"
            echo "已删除: ${TARGET_DL_DIR}"
        fi
    fi

    echo ""
    echo ">> 所有组件卸载完成。"
}

# ==================== 主入口菜单 ====================
echo "=========================================="
echo "          Aria2 & AriaNg 综合管理          "
echo "  当前用户: ${CURRENT_USER} ($([ "$IS_ROOT" = true ] && echo "Root 模式" || echo "普通用户模式"))"
echo "=========================================="
echo " 1. 安装 / 重新配置 Aria2 后端 (可选是否带前端)"
echo " 2. 单独安装 / 更新 AriaNg 前端 (Caddy 反代模式)"
echo " 3. 单独卸载 AriaNg 前端"
echo " 4. 完整卸载 (Aria2 + AriaNg + 服务全部清除)"
echo " 0. 退出"
echo "=========================================="
read -rp "请选择操作 [0-4]: " MENU_CHOICE

case "$MENU_CHOICE" in
    1)
        install_aria2
        ;;
    2)
        install_ariang
        ;;
    3)
        uninstall_ariang
        ;;
    4)
        uninstall_all
        ;;
    0)
        echo "已退出。"
        exit 0
        ;;
    *)
        echo "无效选项，已退出。"
        exit 1
        ;;
esac