#!/usr/bin/env bash
set -e

# 确保以普通用户运行
if [ "$EUID" -eq 0 ]; then
    echo "请不要直接以 root 用户运行此脚本，建议使用普通用户执行（脚本涉及用户级 systemd，提权步骤会调用 sudo）。"
    exit 1
fi

CURRENT_USER="$USER"
USER_HOME="$HOME"
DEFAULT_DOWNLOAD_DIR="${USER_HOME}/Downloads"
DEFAULT_PORT="6800"
DEFAULT_ARIANG_PORT="6880"
GH_PROXY="https://gitpy.223327.xyz/https://github.com"
SYSTEMD_USER_DIR="${USER_HOME}/.config/systemd/user"

# ==================== 卸载模块 ====================
do_uninstall() {
    echo ""
    echo "=========================================="
    echo "            Aria2 & AriaNg 卸载           "
    echo "=========================================="
    read -rp "确定要卸载 Aria2 及其相关服务吗? (y/N): " CONFIRM_UNINSTALL
    if [[ ! "$CONFIRM_UNINSTALL" =~ ^[Yy]$ ]]; then
        echo "已取消卸载。"
        exit 0
    fi

    echo ">> 正在停止并禁用 systemd 服务..."
    # 停止服务（忽略不存在时的报错）
    systemctl --user stop aria2.service 2>/dev/null || true
    systemctl --user stop aria2-update-tracker.timer 2>/dev/null || true
    systemctl --user stop aria2-update-tracker.service 2>/dev/null || true
    systemctl --user stop ariang.service 2>/dev/null || true

    systemctl --user disable aria2.service 2>/dev/null || true
    systemctl --user disable aria2-update-tracker.timer 2>/dev/null || true
    systemctl --user disable aria2-update-tracker.service 2>/dev/null || true
    systemctl --user disable ariang.service 2>/dev/null || true

    echo ">> 正在删除 systemd 服务配置文件..."
    rm -f "${SYSTEMD_USER_DIR}/aria2.service"
    rm -f "${SYSTEMD_USER_DIR}/aria2-update-tracker.service"
    rm -f "${SYSTEMD_USER_DIR}/aria2-update-tracker.timer"
    rm -f "${SYSTEMD_USER_DIR}/ariang.service"
    systemctl --user daemon-reload

    echo ">> 正在移除主程序二进制文件 (/usr/bin/aria2c)..."
    if [ -f "/usr/bin/aria2c" ]; then
        sudo rm -f /usr/bin/aria2c
    fi

    # 询问是否删除配置及脚本文件
    read -rp "是否删除 Aria2 配置文件及更新脚本 (~/.aria2)? (y/N): " DEL_CONFIG
    if [[ "$DEL_CONFIG" =~ ^[Yy]$ ]]; then
        rm -rf "${USER_HOME}/.aria2"
        echo "已清理配置目录: ${USER_HOME}/.aria2"
    else
        echo "已保留配置目录: ${USER_HOME}/.aria2"
    fi

    # 询问是否清理已下载的文件
    read -rp "是否清理下载目录? (强烈建议输入 n 保留已有文件) (y/N): " DEL_DOWNLOADS
    if [[ "$DEL_DOWNLOADS" =~ ^[Yy]$ ]]; then
        read -rp "请输入要清空的下载目录绝对路径: " TARGET_DL_DIR
        if [ -d "$TARGET_DL_DIR" ] && [ "$TARGET_DL_DIR" != "/" ] && [ "$TARGET_DL_DIR" != "$USER_HOME" ]; then
            rm -rf "${TARGET_DL_DIR}"
            echo "已删除下载目录: ${TARGET_DL_DIR}"
        else
            echo "路径无效或属于关键系统目录，已跳过下载目录清理。"
        fi
    fi

    echo ""
    echo "=========================================="
    echo "          Aria2 与相关组件卸载完成!       "
    echo "=========================================="
    exit 0
}

# ==================== 安装模块 ====================
do_install() {
    echo ""
    echo "=========================================="
    echo "         Aria2 + AriaNg 安装配置          "
    echo "=========================================="

    # 1. 交互收集基础配置
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

    # 交互询问是否安装 AriaNg
    echo ""
    read -rp "是否在本地部署 AriaNg Web 前端? (y/N): " INSTALL_ARIANG
    if [[ "$INSTALL_ARIANG" =~ ^[Yy]$ ]]; then
        read -rp "请输入 AriaNg 网页访问端口 [默认: ${DEFAULT_ARIANG_PORT}]: " INPUT_ARIANG_PORT
        ARIANG_PORT="${INPUT_ARIANG_PORT:-$DEFAULT_ARIANG_PORT}"
    fi

    echo ""
    echo "=== 配置概要 ==="
    echo "执行用户: ${CURRENT_USER}"
    echo "下载目录: ${DOWNLOAD_DIR}"
    echo "RPC 端口: ${RPC_PORT}"
    echo "RPC 密钥: ${RPC_SECRET}"
    if [[ "$INSTALL_ARIANG" =~ ^[Yy]$ ]]; then
        echo "安装前端: 是 (Web访问端口: ${ARIANG_PORT})"
    else
        echo "安装前端: 否"
    fi
    echo "================="
    read -rp "确认开始安装? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "已取消安装。"
        exit 0
    fi

    # 2. 安装必要系统依赖
    echo ">> 检查并安装基础依赖 (curl, wget, tar, unzip)..."
    PKGS="curl wget tar unzip"
    if [[ "$INSTALL_ARIANG" =~ ^[Yy]$ ]]; then
        PKGS="${PKGS} python3"
    fi

    if command -v apt-get &>/dev/null; then
        sudo apt-get update -y && sudo apt-get install -y ${PKGS}
    elif command -v pacman &>/dev/null; then
        sudo pacman -Sy --noconfirm ${PKGS}
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y ${PKGS}
    fi

    # 3. 下载并安装 Aria2 增强版
    echo ">> 正在下载 Aria2 增强版..."
    ARIA2_URL="${GH_PROXY}/P3TERX/Aria2-Pro-Core/releases/download/1.36.0_2021.08.22/aria2-1.36.0-static-linux-amd64.tar.gz"
    TMP_DIR=$(mktemp -d)
    wget -q --show-progress -O "${TMP_DIR}/aria2.tar.gz" "${ARIA2_URL}"

    echo ">> 解压并安装到 /usr/bin/aria2c..."
    tar -zxvf "${TMP_DIR}/aria2.tar.gz" -C "${TMP_DIR}"
    sudo mv "${TMP_DIR}/aria2c" /usr/bin/aria2c
    sudo chmod +x /usr/bin/aria2c
    rm -rf "${TMP_DIR}"

    # 4. 创建配置与环境
    echo ">> 初始化配置目录与文件..."
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

    # 5. 配置 Tracker 自动更新脚本
    echo ">> 生成 Tracker 自动更新脚本..."
    cat > "${USER_HOME}/.aria2/scripts/update_tracker.sh" <<'EOF'
#!/usr/bin/env bash
CONF_FILE="$HOME/.aria2/aria2.conf"
TRACKER_URL="https://bitbucket.org/xiu2/trackerslistcollection/raw/master/best.txt"

echo "正在获取最新 Tracker 列表..."
list=$(curl -sSL "${TRACKER_URL}" | sed '/^$/d' | paste -sd "," -)

if [ -z "$list" ]; then
    echo "获取失败，列表为空。"
    exit 1
fi

if grep -q "^bt-tracker=" "$CONF_FILE"; then
    sed -i "s|^bt-tracker=.*|bt-tracker=${list}|g" "$CONF_FILE"
else
    echo "bt-tracker=${list}" >> "$CONF_FILE"
fi

echo "Tracker 更新成功！"
systemctl --user restart aria2
echo "Aria2 服务已重启生效。"
EOF

    chmod +x "${USER_HOME}/.aria2/scripts/update_tracker.sh"

    # 6. 配置 Systemd 用户级服务
    mkdir -p "${SYSTEMD_USER_DIR}"

    cat > "${SYSTEMD_USER_DIR}/aria2.service" <<EOF
[Unit]
Description=Aria2c Download Manager
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/aria2c --conf-path=%h/.aria2/aria2.conf
Restart=on-failure

[Install]
WantedBy=default.target
EOF

    cat > "${SYSTEMD_USER_DIR}/aria2-update-tracker.service" <<EOF
[Unit]
Description=Update Aria2 BT Trackers
After=network.target

[Service]
Type=oneshot
ExecStart=${USER_HOME}/.aria2/scripts/update_tracker.sh
EOF

    cat > "${SYSTEMD_USER_DIR}/aria2-update-tracker.timer" <<EOF
[Unit]
Description=Run Aria2 Tracker Update Daily

[Timer]
OnBootSec=10min
OnUnitActiveSec=24h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # 7. (可选) 安装与配置 AriaNg
    if [[ "$INSTALL_ARIANG" =~ ^[Yy]$ ]]; then
        echo ">> 正在下载并部署 AriaNg (All-In-One)..."
        ARIANG_DIR="${USER_HOME}/.aria2/ariang"
        mkdir -p "${ARIANG_DIR}"
        
        ARIANG_DL_URL="${GH_PROXY}/mayswind/AriaNg/releases/download/1.3.7/AriaNg-1.3.7-AllInOne.zip"
        TMP_ARIANG=$(mktemp -d)
        wget -q --show-progress -O "${TMP_ARIANG}/ariang.zip" "${ARIANG_DL_URL}"
        unzip -qo "${TMP_ARIANG}/ariang.zip" -d "${ARIANG_DIR}"
        rm -rf "${TMP_ARIANG}"

        cat > "${SYSTEMD_USER_DIR}/ariang.service" <<EOF
[Unit]
Description=AriaNg Web Interface
After=network.target

[Service]
Type=simple
WorkingDirectory=${ARIANG_DIR}
ExecStart=/usr/bin/python3 -m http.server ${ARIANG_PORT} --bind 0.0.0.0
Restart=on-failure

[Install]
WantedBy=default.target
EOF
    fi

    # 8. 启动所有服务
    echo ">> 重载并启动 systemd 服务..."
    systemctl --user daemon-reload
    systemctl --user enable --now aria2.service
    systemctl --user enable --now aria2-update-tracker.timer

    if [[ "$INSTALL_ARIANG" =~ ^[Yy]$ ]]; then
        systemctl --user enable --now ariang.service
    fi

    # 初始化拉取 Tracker
    echo ">> 初始化拉取首次 Tracker 列表..."
    bash "${USER_HOME}/.aria2/scripts/update_tracker.sh" || echo "提示：首次拉取 Tracker 失败，稍后定时器会自动重试。"

    # 保持用户会话常驻
    if command -v loginctl &>/dev/null; then
        sudo loginctl enable-linger "${CURRENT_USER}" 2>/dev/null || true
    fi

    echo ""
    echo "=========================================="
    echo "          安装与配置已完成!                "
    echo "=========================================="
    echo "后端 RPC 连接信息:"
    echo "  端口:        ${RPC_PORT}"
    echo "  密钥(Token): ${RPC_SECRET}"

    if [[ "$INSTALL_ARIANG" =~ ^[Yy]$ ]]; then
        echo ""
        echo "AriaNg 网页访问入口:"
        echo "  访问地址:    http://<你的服务器IP>:${ARIANG_PORT}"
        echo "  初次打开请在 [AriaNg 设置 -> RPC] 中填入上述 RPC 端口与密钥即可连接。"
    fi
    echo "=========================================="
}

# ==================== 主入口菜单 ====================
echo "=========================================="
echo "        Aria2 管理脚本 (安装 / 卸载)       "
echo "=========================================="
echo " 1. 安装 / 重新配置 Aria2 (可选 AriaNg)"
echo " 2. 卸载 Aria2 与相关组件"
echo " 0. 退出"
echo "=========================================="
read -rp "请选择操作 [0-2]: " MENU_CHOICE

case "$MENU_CHOICE" in
    1)
        do_install
        ;;
    2)
        do_uninstall
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