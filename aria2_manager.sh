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

ARIA2_CONF_DIR="${USER_HOME}/.aria2"
CONF_FILE="${ARIA2_CONF_DIR}/aria2.conf"
SESSION_FILE="${ARIA2_CONF_DIR}/aria2.session"
TRACKER_SCRIPT="${ARIA2_CONF_DIR}/scripts/update_tracker.sh"
DEFAULT_DOWNLOAD_DIR="${USER_HOME}/Downloads"
DEFAULT_PORT="6800"
DEFAULT_ARIANG_PORT="6880"
GH_PROXY="https://gitpy.223327.xyz/https://github.com"
ARIANG_DIR="${ARIA2_CONF_DIR}/ariang"

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
        ${SUDO_CMD} apt-get update -y
        ${SUDO_CMD} apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg
        curl -1sLf --connect-timeout 10 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | ${SUDO_CMD} gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf --connect-timeout 10 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | ${SUDO_CMD} tee /etc/apt/sources.list.d/caddy-stable.list
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
list=\$( (curl -sSL --connect-timeout 10 -m 30 "\${TRACKER_URL1}"; echo ""; curl -sSL --connect-timeout 10 -m 30 "\${TRACKER_URL2}") | tr -d '\r' | sed '/^$/d' | sort -u | paste -sd "," - )

if [ -z "\$list" ]; then
    echo "获取失败，列表为空。"
    exit 1
fi

if grep -q "^bt-tracker=" "\$CONF_FILE"; then
    sed -i "s|^bt-tracker=.*|bt-tracker=\${list}|g" "\$CONF_FILE"
else
    echo "bt-tracker=\${list}" >> "\$CONF_FILE"
fi

echo "Tracker 更新成功！已自动去重合并。"
${SYSTEMCTL_CMD} restart aria2.service
EOF
    chmod +x "${TRACKER_SCRIPT}"
}

# ==================== 模块 1: 安装 Aria2 后端 ====================
install_aria2() {
    echo ""
    echo "=========================================="
    echo "            安装 / 配置 Aria2 后端        "
    echo "=========================================="

    read -rp "请输入下载目录路径 [默认: ${DEFAULT_DOWNLOAD_DIR}]: " INPUT_DIR
    DOWNLOAD_DIR="${INPUT_DIR:-$DEFAULT_DOWNLOAD_DIR}"
    DOWNLOAD_DIR="${DOWNLOAD_DIR%/}"

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
    read -rp "是否顺带安装 AriaNg Web 前端 (Caddy 反代模式)? [y/N 默认: N]: " WITH_ARIANG
    WITH_ARIANG="${WITH_ARIANG:-N}"

    echo ""
    echo "=== Aria2 配置概要 ==="
    echo "运行模式: $([ "$IS_ROOT" = true ] && echo "Root 系统模式" || echo "普通用户模式 ($CURRENT_USER)")"
    echo "下载目录: ${DOWNLOAD_DIR}"
    echo "RPC 端口: ${RPC_PORT}"
    echo "RPC 密钥: ${RPC_SECRET}"
    echo "顺带安装 AriaNg: $([[ "$WITH_ARIANG" =~ ^[Yy]$ ]] && echo "是" || echo "否")"
    echo "Tracker 自动更新: 默认开启 (每日定时)"
    echo "种子文件保留: 默认关闭 (下载后自动删除种子)"
    echo "======================"
    read -rp "确认开始安装 Aria2? [Y/n 默认: Y]: " CONFIRM
    CONFIRM="${CONFIRM:-Y}"
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "已取消安装。"
        return 0
    fi

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

    mkdir -p "${DOWNLOAD_DIR}"
    mkdir -p "${ARIA2_CONF_DIR}"
    touch "${SESSION_FILE}"

    echo ">> 写入 aria2.conf..."
    cat > "${CONF_FILE}" <<EOF
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
bt-tracker=
EOF

    ensure_tracker_script

    [ "$IS_ROOT" = false ] && mkdir -p "${SYSTEMD_DIR}"

    ${SUDO_CMD} bash -c "cat > '${SYSTEMD_DIR}/aria2.service'" <<EOF
[Unit]
Description=Aria2c Download Manager
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/aria2c --conf-path=${CONF_FILE}
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
ExecStart=${TRACKER_SCRIPT}
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

    ${SYSTEMCTL_CMD} daemon-reload
    ${SYSTEMCTL_CMD} enable --now aria2.service
    ${SYSTEMCTL_CMD} enable --now aria2-update-tracker.timer

    bash "${TRACKER_SCRIPT}" 2>/dev/null || true

    if [ "$IS_ROOT" = false ] && command -v loginctl &>/dev/null; then
        sudo loginctl enable-linger "${CURRENT_USER}" 2>/dev/null || true
    fi

    echo ""
    echo ">> Aria2 后端已部署成功！"
    echo "   RPC 端口: ${RPC_PORT}"
    echo "   RPC 密钥: ${RPC_SECRET}"
    echo "   Tracker 自动更新定时器已就绪并开机启动。"
    echo "   BT 种子自动清理配置已生效。"

    if [[ "$WITH_ARIANG" =~ ^[Yy]$ ]]; then
        install_ariang "${RPC_PORT}"
    fi
}

# ==================== 模块 2: 单独修改下载目录 ====================
modify_download_dir() {
    echo ""
    echo "=========================================="
    echo "         单独配置 Aria2 下载目录          "
    echo "=========================================="

    if [ ! -f "${CONF_FILE}" ]; then
        echo "未检测到配置文件: ${CONF_FILE}，请先执行安装 Aria2！"
        return 1
    fi

    CURRENT_DIR=$(grep -E "^dir=" "${CONF_FILE}" | cut -d'=' -f2 | tr -d '\r')
    echo "当前默认下载目录: ${CURRENT_DIR:-未设置}"
    echo ""

    read -rp "请输入新的下载目录绝对路径 [留空取消]: " NEW_DIR
    if [ -z "$NEW_DIR" ]; then
        echo "输入为空，未做任何修改。"
        return 0
    fi
    NEW_DIR="${NEW_DIR%/}"

    echo ">> 正在检查并创建目录: ${NEW_DIR}..."
    mkdir -p "${NEW_DIR}"

    if grep -q "^dir=" "${CONF_FILE}"; then
        sed -i "s|^dir=.*|dir=${NEW_DIR}|g" "${CONF_FILE}"
    else
        echo "dir=${NEW_DIR}" >> "${CONF_FILE}"
    fi

    echo ">> 正在重启 Aria2 服务以应用新路径..."
    ${SYSTEMCTL_CMD} restart aria2.service

    echo ""
    echo ">> 默认下载目录已成功修改为: ${NEW_DIR}"
    echo ">> Aria2 服务重启完成。"
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
    read -rp "请选择 [1-2 默认: 1]: " TRACKER_CHOICE
    TRACKER_CHOICE="${TRACKER_CHOICE:-1}"

    if [ "$TRACKER_CHOICE" == "1" ]; then
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
        
        formatted_trackers=$(echo "${USER_TRACKERS}" | tr -d '\r' | tr '\n' ',' | sed 's/,,*/,/g; s/^,//; s/,$//')

        if [ -z "$formatted_trackers" ]; then
            echo "输入内容为空，未做任何修改。"
            return 0
        fi

        if grep -q "^bt-tracker=" "${CONF_FILE}"; then
            sed -i "s|^bt-tracker=.*|bt-tracker=${formatted_trackers}|g" "${CONF_FILE}"
        else
            echo "bt-tracker=${formatted_trackers}" >> "${CONF_FILE}"
        fi

        ${SYSTEMCTL_CMD} restart aria2.service
        echo ">> 自定义 Trackers 已成功写入并重启 Aria2 服务！"
    else
        echo "无效选项。"
        return 1
    fi
}

# ==================== 模块 4: 自动更新 Trackers 开关管理 ====================
manage_tracker_timer() {
    echo ""
    echo "=========================================="
    echo "     BT Trackers 自动更新 定时器管理       "
    echo "=========================================="

    IS_ACTIVE=false
    if ${SYSTEMCTL_CMD} is-active --quiet aria2-update-tracker.timer 2>/dev/null; then
        IS_ACTIVE=true
    fi

    echo -n "当前自动更新定时器状态: "
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
    read -rp "请选择操作 [0-3]: " TIMER_CHOICE

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
Description=Run Aria2 Tracker Update Daily

[Timer]
OnBootSec=10min
OnUnitActiveSec=24h
Persistent=true

[Install]
WantedBy=timers.target
EOF

            ${SYSTEMCTL_CMD} daemon-reload
            ${SYSTEMCTL_CMD} enable --now aria2-update-tracker.timer
            echo ">> 自动更新定时器已成功启用！"
            ;;
        2)
            echo ">> 正在停止并禁用定时器..."
            ${SYSTEMCTL_CMD} stop aria2-update-tracker.timer 2>/dev/null || true
            ${SYSTEMCTL_CMD} disable aria2-update-tracker.timer 2>/dev/null || true
            echo ">> 自动更新定时器已停用。"
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

# ==================== 模块 5: 迁移下载任务 ====================
migrate_downloads() {
    echo ""
    echo "=========================================="
    echo "       迁移 Aria2 下载任务到新磁盘        "
    echo "=========================================="

    if [ ! -f "${CONF_FILE}" ]; then
        echo "错误: 未找到配置文件 ${CONF_FILE}，请确认 Aria2 是否已安装。"
        return 1
    fi

    install_packages rsync findutils

    # 1. 优先选择迁移范围
    echo "请先选择迁移范围:"
    echo " 1. 仅迁移未完成的下载任务 (自动识别 .aria2 校验块、数据与种子元数据)"
    echo " 2. 迁移整个下载目录的所有数据 (包含已完成与未完成，自动识别元数据)"
    echo " 3. 仅迁移指定文件/任务 (按关键词匹配，自动识别元数据)"
    read -rp "请选择 [1-3 默认: 1]: " MIGRATE_TYPE
    MIGRATE_TYPE="${MIGRATE_TYPE:-1}"

    FILE_KEYWORD=""
    if [ "$MIGRATE_TYPE" == "3" ]; then
        read -rp "请输入要迁移的文件名关键字 (例如: debian.iso): " FILE_KEYWORD
        if [ -z "$FILE_KEYWORD" ]; then
            echo "关键字不能为空，已取消迁移。"
            return 1
        fi
    fi

    # 2. 再配置迁移路径
    CURRENT_DIR=$(grep -E "^dir=" "${CONF_FILE}" | cut -d'=' -f2 | tr -d '\r')
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

    # 3. 严格安全停机，防止进程写回覆盖 session
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

            echo ">> 发现 ${#ARIA2_CONTROL_FILES[@]} 个未完成任务，正在同步数据文件、控制文件与种子元数据..."
            for ctl in "${ARIA2_CONTROL_FILES[@]}"; do
                data_target="${ctl%.aria2}"
                rel_ctl="${ctl#"${SRC_DIR}/"}"
                dest_subdir=$(dirname "${DEST_DIR}/${rel_ctl}")
                mkdir -p "${dest_subdir}"

                # 同步控制文件
                rsync -avP "${ctl}" "${dest_subdir}/"
                MIGRATED_FILES+=("${ctl}")

                # 同步数据本体
                if [ -e "${data_target}" ]; then
                    rsync -avP "${data_target}" "${dest_subdir}/"
                    MIGRATED_FILES+=("${data_target}")
                fi

                # 同步同名 .torrent
                if [ -f "${data_target}.torrent" ]; then
                    rsync -avP "${data_target}.torrent" "${dest_subdir}/"
                    MIGRATED_FILES+=("${data_target}.torrent")
                fi
            done

            # 抓取源目录下关联的所有 .torrent 文件并同步
            while IFS= read -r tor; do
                if [ -f "$tor" ]; then
                    rsync -avP "$tor" "${DEST_DIR}/"
                    MIGRATED_FILES+=("$tor")
                fi
            done < <(find "${SRC_DIR}" -maxdepth 1 -name "*.torrent")
            ;;

        2)
            echo ">> 正在完整同步下载目录下全部数据、控制文件与种子元数据..."
            rsync -avP "${SRC_DIR}/" "${DEST_DIR}/"
            while IFS= read -r item; do
                [ -e "$item" ] && MIGRATED_FILES+=("$item")
            done < <(find "${SRC_DIR}" -mindepth 1 -maxdepth 1)
            ;;

        3)
            echo ">> 正在根据关键字 [${FILE_KEYWORD}] 匹配任务并同步..."
            MATCH_FOUND=false
            while IFS= read -r item; do
                MATCH_FOUND=true
                rel_item="${item#"${SRC_DIR}/"}"
                dest_subdir=$(dirname "${DEST_DIR}/${rel_item}")
                mkdir -p "${dest_subdir}"

                rsync -avP "${item}" "${dest_subdir}/"
                MIGRATED_FILES+=("${item}")

                # 自动识别关联的 .aria2 控制文件
                if [ -f "${item}.aria2" ]; then
                    rsync -avP "${item}.aria2" "${dest_subdir}/"
                    MIGRATED_FILES+=("${item}.aria2")
                fi
                # 自动识别关联的 .torrent 种子文件
                if [ -f "${item}.torrent" ]; then
                    rsync -avP "${item}.torrent" "${dest_subdir}/"
                    MIGRATED_FILES+=("${item}.torrent")
                fi
            done < <(find "${SRC_DIR}" -name "*${FILE_KEYWORD}*" ! -name "*.aria2" ! -name "*.torrent")

            while IFS= read -r ext_file; do
                MATCH_FOUND=true
                rsync -avP "${ext_file}" "${DEST_DIR}/"
                MIGRATED_FILES+=("${ext_file}")
            done < <(find "${SRC_DIR}" -maxdepth 1 -name "*${FILE_KEYWORD}*.torrent" -o -name "*${FILE_KEYWORD}*.aria2")

            if [ "$MATCH_FOUND" = false ]; then
                echo "未匹配到任何包含关键字 [${FILE_KEYWORD}] 的文件。"
                ${SYSTEMCTL_CMD} start aria2.service
                return 0
            fi
            ;;
    esac

    # 4. 全面替换 session 会话文件中的路径映射
    if [ -f "${SESSION_FILE}" ] && [ -s "${SESSION_FILE}" ]; then
        echo ">> 正在更新会话文件 (${SESSION_FILE}) 中的路径映射..."
        cp "${SESSION_FILE}" "${SESSION_FILE}.bak"
        sed -i "s|${SRC_DIR}|${DEST_DIR}|g" "${SESSION_FILE}"
    fi

    echo ""
    read -rp "是否将未来默认下载目录也同步修改为新路径? [Y/n 默认: Y]: " SYNC_DEFAULT
    SYNC_DEFAULT="${SYNC_DEFAULT:-Y}"
    if [[ "$SYNC_DEFAULT" =~ ^[Yy]$ ]]; then
        sed -i "s|^dir=.*|dir=${DEST_DIR}|g" "${CONF_FILE}"
        echo ">> 已更新 aria2.conf 默认下载目录为: ${DEST_DIR}"
    fi

    # 5. 重新启动服务
    echo ">> 正在启动 Aria2 服务恢复下载..."
    ${SYSTEMCTL_CMD} start aria2.service

    echo ""
    echo ">> 迁移完成！Aria2 已重新载入元数据并开始自检校验断点。"
    echo ""

    # 6. 安全清理源磁盘旧数据
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

# ==================== 模块 6: 扫描并恢复未完成种子任务 ====================
scan_and_resume_torrents() {
    echo ""
    echo "=========================================="
    echo "    扫描目录并恢复未完成种子断点下载      "
    echo "=========================================="

    if [ ! -f "${CONF_FILE}" ]; then
        echo "错误: 未找到配置文件 ${CONF_FILE}，请先确认 Aria2 是否已安装。"
        return 1
    fi

    install_packages curl

    # 提取当前 RPC 端口与 Secret
    RPC_PORT=$(grep -E "^rpc-listen-port=" "${CONF_FILE}" | cut -d'=' -f2 | tr -d ' \r')
    RPC_PORT="${RPC_PORT:-$DEFAULT_PORT}"
    RPC_SECRET=$(grep -E "^rpc-secret=" "${CONF_FILE}" | cut -d'=' -f2 | tr -d ' \r')

    # 确认 Aria2 进程已在运行
    if ! ${SYSTEMCTL_CMD} is-active --quiet aria2.service 2>/dev/null; then
        echo ">> 检测到 Aria2 服务未运行，正在启动..."
        ${SYSTEMCTL_CMD} start aria2.service
        sleep 1
    fi

    CURRENT_DIR=$(grep -E "^dir=" "${CONF_FILE}" | cut -d'=' -f2 | tr -d '\r')
    read -rp "请输入要扫描的种子所在目录 [默认: ${CURRENT_DIR:-$DEFAULT_DOWNLOAD_DIR}]: " TARGET_SCAN_DIR
    TARGET_SCAN_DIR="${TARGET_SCAN_DIR:-$CURRENT_DIR}"
    TARGET_SCAN_DIR="${TARGET_SCAN_DIR:-$DEFAULT_DOWNLOAD_DIR}"
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
        base_name="${tor%.torrent}"
        # 只要存在同名 .aria2 校验文件，或者对应数据文件/目录存在且未完工
        # 即使被改名，通过 RPC 重新注入种子也会自动匹配当前目录下的同名文件进行分块校验
        echo ">> 正在推送种子: $(basename "$tor")..."
        
        # 将种子转换成 base64
        tor_b64=$(base64 -w 0 "$tor" 2>/dev/null || base64 "$tor" | tr -d '\r\n')
        
        # 构建 RPC 请求体 (aria2.addTorrent)
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

        # 发送 RPC 调用
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

# ==================== 模块 7: 单独安装/更新 AriaNg (使用 Caddy) ====================
install_ariang() {
    local target_rpc_port="$1"

    echo ""
    echo "=========================================="
    echo "     安装 / 更新 AriaNg 前端 (Caddy 反代)  "
    echo "=========================================="

    if [ -z "$target_rpc_port" ]; then
        if [ -f "${CONF_FILE}" ]; then
            target_rpc_port=$(grep -E "^rpc-listen-port=" "${CONF_FILE}" | cut -d'=' -f2 | tr -d ' \r')
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

# ==================== 模块 8: 单独卸载 AriaNg ====================
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

# ==================== 模块 9: 完整卸载 (全部组件) ====================
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
    echo ">> 所有组件卸载完成。"
}

# ==================== 主入口循环菜单 ====================
while true; do
    echo ""
    echo "=========================================="
    echo "          Aria2 & AriaNg 综合管理          "
    echo "  当前用户: ${CURRENT_USER} ($([ "$IS_ROOT" = true ] && echo "Root 模式" || echo "普通用户模式"))"
    echo "=========================================="
    echo " 1. 安装 / 重新配置 Aria2 后端 (默认启用 Tracker 自动更新)"
    echo " 2. 单独修改下载目录"
    echo " 3. 手动更新 / 设置 BT Trackers (双源拉取 / 自定义)"
    echo " 4. 启用 / 停用 Trackers 自动更新 (定时器管理)"
    echo " 5. 迁移下载任务到新磁盘"
    echo " 6. 扫描目录并恢复未完成种子断点下载"
    echo " 7. 单独安装 / 更新 AriaNg 前端 (Caddy 反代模式)"
    echo " 8. 单独卸载 AriaNg 前端"
    echo " 9. 完整卸载 (Aria2 + AriaNg + 服务全部清除)"
    echo " 0. 退出"
    echo "=========================================="
    read -rp "请选择操作 [0-9]: " MENU_CHOICE

    case "$MENU_CHOICE" in
        1) install_aria2 ;;
        2) modify_download_dir ;;
        3) update_trackers_menu ;;
        4) manage_tracker_timer ;;
        5) migrate_downloads ;;
        6) scan_and_resume_torrents ;;
        7) install_ariang ;;
        8) uninstall_ariang ;;
        9) uninstall_all; break ;;
        0) echo "已退出。"; exit 0 ;;
        *) echo "无效选项，请重新选择。" ;;
    esac
done