#!/usr/bin/env bash
set -e

# ----------------- 环境初始化与权限适配 -----------------
IS_ROOT=false
if [ "$EUID" -eq 0 ]; then
    IS_ROOT=true
fi

# 根据当前用户类型设置基础路径与 systemd 模式
if [ "$IS_ROOT" = true ]; then
    DEFAULT_WORK_DIR="/opt/filebrowser"
    DEFAULT_DATA_PATH="/srv"
    BIN_DIR="/usr/local/bin"
    SYSTEMD_SERVICE_FILE="/etc/systemd/system/filebrowser.service"
    SYSTEMCTL_CMD="systemctl"
else
    DEFAULT_WORK_DIR="$HOME/.filebrowser"
    DEFAULT_DATA_PATH="$HOME/data"
    BIN_DIR="$HOME/.local/bin"
    SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
    SYSTEMD_SERVICE_FILE="$SYSTEMD_USER_DIR/filebrowser.service"
    SYSTEMCTL_CMD="systemctl --user"

    # 确保用户的 ~/.local/bin 包含在 PATH 中
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        export PATH="$HOME/.local/bin:$PATH"
    fi
fi

BIN_PATH="$BIN_DIR/filebrowser"

# ----------------- FFmpeg 探测与安装 -----------------
install_ffmpeg() {
    if command -v ffmpeg >/dev/null 2>&1; then
        echo "[✓] 检测到系统已存在 FFmpeg: $(ffmpeg -version | head -n 1)"
        return 0
    fi

    echo "[*] 尝试安装 FFmpeg..."
    
    # 构建执行命令前缀（如果非 root 且有 sudo 权限则用 sudo）
    SUDO_CMD=""
    if [ "$IS_ROOT" = false ]; then
        if command -v sudo >/dev/null 2>&1; then
            echo "提示：普通用户安装系统级 FFmpeg 需要提权..."
            SUDO_CMD="sudo"
        else
            echo "[-] 当前用户无 root 权限且未检测到 sudo，无法安装系统 FFmpeg。跳过 FFmpeg 集成。"
            return 1
        fi
    fi

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian)
                $SUDO_CMD apt-get update -y
                $SUDO_CMD apt-get install -y ffmpeg
                ;;
            centos|rhel|almalinux|rocky)
                $SUDO_CMD dnf install -y epel-release || $SUDO_CMD yum install -y epel-release || true
                $SUDO_CMD dnf install -y ffmpeg || $SUDO_CMD yum install -y ffmpeg || {
                    echo "警告：直接安装失败，尝试启用 RPM Fusion 仓库..."
                    $SUDO_CMD dnf install -y --nogpgcheck https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-$(rpm -E %rhel).noarch.rpm || true
                    $SUDO_CMD dnf install -y ffmpeg
                }
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
                echo "[-] 无法自动识别当前系统的包管理器，请手动安装 ffmpeg 后重新配置。"
                return 1
                ;;
        esac
    else
        echo "[-] 无法获取系统发行版信息，跳过 FFmpeg 安装。"
        return 1
    fi

    if command -v ffmpeg >/dev/null 2>&1; then
        echo "[✓] FFmpeg 安装成功！"
        return 0
    else
        echo "[-] FFmpeg 安装未完成，跳过此配置。"
        return 1
    fi
}

# ----------------- 卸载流程 -----------------
uninstall_filebrowser() {
    echo "=========================================="
    echo "       FileBrowser Quantum 卸载程序"
    echo "=========================================="
    echo "当前操作模式: $([ "$IS_ROOT" = true ] && echo "Root (全局)" || echo "普通用户 ($USER)")"

    read -rp "确定要卸载 FileBrowser Quantum 吗？[y/N]: " CONFIRM_UNINSTALL
    if [[ ! "$CONFIRM_UNINSTALL" =~ ^[Yy]$ ]]; then
        echo "已取消卸载。"
        exit 0
    fi

    echo "[1/4] 停止并禁用 systemd 服务..."
    if $SYSTEMCTL_CMD is-active --quiet filebrowser.service 2>/dev/null; then
        $SYSTEMCTL_CMD stop filebrowser.service
    fi
    if $SYSTEMCTL_CMD is-enabled --quiet filebrowser.service 2>/dev/null; then
        $SYSTEMCTL_CMD disable filebrowser.service
    fi

    echo "[2/4] 清除服务配置与二进制文件..."
    rm -f "$SYSTEMD_SERVICE_FILE"
    $SYSTEMCTL_CMD daemon-reload 2>/dev/null || true
    $SYSTEMCTL_CMD reset-failed 2>/dev/null || true
    rm -f "$BIN_PATH"

    echo "[3/4] 清理运行工作目录..."
    read -rp "请输入需要清理的工作目录 [默认: $DEFAULT_WORK_DIR]: " INPUT_WORK_DIR
    WORK_DIR_TO_DEL="${INPUT_WORK_DIR:-$DEFAULT_WORK_DIR}"

    if [ -d "$WORK_DIR_TO_DEL" ]; then
        read -rp "是否彻底删除工作目录 $WORK_DIR_TO_DEL (包含数据库和配置)? [y/N]: " DEL_WORK
        if [[ "$DEL_WORK" =~ ^[Yy]$ ]]; then
            rm -rf "$WORK_DIR_TO_DEL"
            echo "[✓] 已删除工作目录: $WORK_DIR_TO_DEL"
        else
            echo "[-] 保留工作目录: $WORK_DIR_TO_DEL"
        fi
    else
        echo "[-] 未检测到工作目录: $WORK_DIR_TO_DEL，跳过清理。"
    fi

    echo "[4/4] 数据存储目录检查..."
    read -rp "是否需要删除存储文件的实际数据目录? [y/N 默认: N]: " DEL_DATA
    if [[ "$DEL_DATA" =~ ^[Yy]$ ]]; then
        read -rp "请输入要彻底清空的数据目录: " TARGET_DATA_PATH
        if [ -n "$TARGET_DATA_PATH" ] && [ -d "$TARGET_DATA_PATH" ]; then
            # 基础目录防护
            if [ "$TARGET_DATA_PATH" = "/" ] || [ "$TARGET_DATA_PATH" = "/root" ] || [ "$TARGET_DATA_PATH" = "$HOME" ]; then
                echo "警告：检测到关键系统/家目录，禁止整目录删除！请手动处理该目录中的文件。"
            else
                rm -rf "$TARGET_DATA_PATH"
                echo "[✓] 已删除数据存储目录: $TARGET_DATA_PATH"
            fi
        else
            echo "[-] 路径无效或目录不存在，跳过删除。"
        fi
    else
        echo "[-] 已保留您的个人数据目录。"
    fi

    echo ""
    echo "=========================================="
    echo "  FileBrowser Quantum 已成功卸载完成！"
    echo "=========================================="
    exit 0
}

# ----------------- 安装流程 -----------------
install_filebrowser() {
    echo "=========================================="
    echo "    FileBrowser Quantum 一键安装配置"
    echo "=========================================="
    echo "运行身份: $([ "$IS_ROOT" = true ] && echo "Root (系统级服务)" || echo "普通用户 $USER (用户级服务)")"

    # 参数交互
    read -rp "是否启用 FFmpeg (视频转码/缩略图支持)? [y/N 默认: N]: " ENABLE_FFMPEG
    ENABLE_FFMPEG="${ENABLE_FFMPEG:-N}"

    read -rp "请输入工作目录 (存放配置与数据库) [默认: $DEFAULT_WORK_DIR]: " WORK_DIR
    WORK_DIR="${WORK_DIR:-$DEFAULT_WORK_DIR}"

    read -rp "请输入要浏览的文件路径 [默认: $DEFAULT_DATA_PATH]: " DATA_PATH
    DATA_PATH="${DATA_PATH:-$DEFAULT_DATA_PATH}"

    read -rp "请输入 Web 访问端口 [默认: 8080]: " PORT
    PORT="${PORT:-8080}"

    # 处理 FFmpeg
    FFMPEG_STATUS="未安装/未启用"
    if [[ "$ENABLE_FFMPEG" =~ ^[Yy]$ ]]; then
        if install_ffmpeg; then
            FFMPEG_BIN_PATH="$(command -v ffmpeg)"
            FFMPEG_DIR="$(dirname "$FFMPEG_BIN_PATH")"
            FFMPEG_STATUS="已启用 ($FFMPEG_DIR)"
        else
            FFMPEG_STATUS="未启用 (安装失败或已跳过)"
        fi
    fi

    echo ""
    echo "配置信息确认："
    echo "- 安装模式:     $([ "$IS_ROOT" = true ] && echo "System" || echo "User ($USER)")"
    echo "- 可执行文件:   $BIN_PATH"
    echo "- 工作目录:     $WORK_DIR"
    echo "- 浏览目录:     $DATA_PATH"
    echo "- 监听端口:     $PORT"
    echo "- FFmpeg 状态:  $FFMPEG_STATUS"
    echo "------------------------------------------"

    # 创建必要目录
    mkdir -p "$WORK_DIR"
    mkdir -p "$DATA_PATH"
    mkdir -p "$BIN_DIR"
    if [ "$IS_ROOT" = false ]; then
        mkdir -p "$SYSTEMD_USER_DIR"
    fi

    echo "[1/4] 正在下载 FileBrowser Quantum 二进制程序..."
    curl -L -o "$BIN_PATH" https://gitpy.223327.xyz/https://github.com/gtsteffaniak/filebrowser/releases/latest/download/linux-amd64-filebrowser

    echo "[2/4] 赋予二进制文件可执行权限..."
    chmod +x "$BIN_PATH"

    echo "[3/4] 正在生成配置文件 $WORK_DIR/config.yaml..."
    cat <<EOF > "$WORK_DIR/config.yaml"
server:
  port: $PORT
  sources:
    - path: "$DATA_PATH"
      config:
        defaultEnabled: true
EOF

    if [[ "$FFMPEG_STATUS" =~ "已启用" ]]; then
cat <<EOF >> "$WORK_DIR/config.yaml"

integrations:
  media:
    ffmpegPath: "$FFMPEG_DIR"
    debug: false
    extractEmbeddedSubtitles: false
EOF
    fi

    echo "[4/4] 配置 systemd 服务..."
    cat <<EOF > "$SYSTEMD_SERVICE_FILE"
[Unit]
Description=FileBrowser Quantum
Documentation=https://filebrowserquantum.com
After=network.target

[Service]
Type=simple
WorkingDirectory=$WORK_DIR
ExecStart=$BIN_PATH -c $WORK_DIR/config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

    echo "正在加载并启动服务..."
    $SYSTEMCTL_CMD daemon-reload
    $SYSTEMCTL_CMD enable filebrowser.service
    $SYSTEMCTL_CMD restart filebrowser.service

    # 普通用户需要常驻会话支持（Linger），否则注销 SSH 后服务会被终止
    if [ "$IS_ROOT" = false ]; then
        if command -v loginctl >/dev/null 2>&1; then
            echo "提示：启用用户常驻进程 (Linger)，保证退出 SSH 后服务继续运行..."
            loginctl enable-linger "$USER" 2>/dev/null || echo "注意：未能自动开启 linger，登出后服务可能挂起，可联系管理员运行：sudo loginctl enable-linger $USER"
        fi
    fi

    echo ""
    echo "=========================================="
    echo "      FileBrowser Quantum 安装成功！"
    echo "=========================================="
    echo "服务状态: $($SYSTEMCTL_CMD is-active filebrowser.service)"
    echo "访问地址: http://<你的服务器IP>:$PORT"
    echo "默认账号: admin"
    echo "默认密码: admin"
    echo "浏览目录: $DATA_PATH"
    echo "工作目录: $WORK_DIR"
    echo "配置文件: $WORK_DIR/config.yaml"
    echo "FFmpeg:   $FFMPEG_STATUS"
    echo "常用命令："
    if [ "$IS_ROOT" = true ]; then
        echo "  - 查看服务状态: systemctl status filebrowser"
        echo "  - 重启服务:     systemctl restart filebrowser"
        echo "  - 查看实时日志: journalctl -u filebrowser -f"
    else
        echo "  - 查看服务状态: systemctl --user status filebrowser"
        echo "  - 重启服务:     systemctl --user restart filebrowser"
        echo "  - 查看实时日志: journalctl --user -u filebrowser -f"
    fi
    echo "=========================================="
}

# ----------------- 菜单入口 -----------------
echo "=========================================="
echo "      FileBrowser Quantum 管理脚本"
echo "      当前执行身份: $([ "$IS_ROOT" = true ] && echo "Root" || echo "普通用户 ($USER)")"
echo "=========================================="
echo " 1. 安装 / 重新配置 FileBrowser Quantum"
echo " 2. 卸载 FileBrowser Quantum"
echo " 0. 退出"
echo "=========================================="
read -rp "请输入操作编号 [1/2/0 默认: 1]: " ACTION_CHOICE
ACTION_CHOICE="${ACTION_CHOICE:-1}"

case "$ACTION_CHOICE" in
    1)
        install_filebrowser
        ;;
    2)
        uninstall_filebrowser
        ;;
    0)
        echo "退出脚本。"
        exit 0
        ;;
    *)
        echo "输入无效，退出脚本。"
        exit 1
        ;;
esac