#!/usr/bin/env bash
set -euo pipefail

# ======================= 环境模式与路径自动判定 =======================
PROXY_PREFIX="https://gitpy.223327.xyz/"
GITHUB_REPO="rathole-org/rathole"

# 终端色彩输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ $EUID -eq 0 ]]; then
    IS_ROOT=true
    SYSTEMCTL_CMD="systemctl"
    JOURNALCTL_CMD="journalctl"
    BIN_PATH="/usr/bin/rathole"
    CONFIG_DIR="/etc/rathole"
    SYSTEMD_DIR="/etc/systemd/system"
else
    IS_ROOT=false
    SYSTEMCTL_CMD="systemctl --user"
    JOURNALCTL_CMD="journalctl --user"
    BIN_PATH="${HOME}/.local/bin/rathole"
    CONFIG_DIR="${HOME}/.local/etc/rathole"
    SYSTEMD_DIR="${HOME}/.config/systemd/user"
    mkdir -p "${HOME}/.local/bin"
    # 确保用户 local bin 在 PATH 中
    if [[ ":$PATH:" != *":${HOME}/.local/bin:"* ]]; then
        export PATH="${HOME}/.local/bin:$PATH"
    fi
fi

CLIENT_SERVICE_FILE="${SYSTEMD_DIR}/rathole-client@.service"
SERVER_SERVICE_FILE="${SYSTEMD_DIR}/rathole-server@.service"

# ======================= 依赖检查 =======================
check_dependencies() {
    for cmd in curl jq unzip systemctl; do
        if ! command -v "$cmd" &>/dev/null; then
            if [[ "$IS_ROOT" == true ]]; then
                echo -e "${YELLOW}缺少依赖 $cmd，正在自动安装...${NC}"
                if command -v apt &>/dev/null; then
                    apt update && apt install -y "$cmd"
                elif command -v dnf &>/dev/null; then
                    dnf install -y "$cmd"
                elif command -v yum &>/dev/null; then
                    yum install -y "$cmd"
                else
                    echo -e "${RED}无法自动安装 $cmd，请手动安装后重试。${NC}"
                    exit 1
                fi
            else
                echo -e "${RED}错误: 系统缺少命令 '$cmd'。作为非 root 用户无法直接安装，请联系管理员或使用包管理器安装该依赖。${NC}"
                exit 1
            fi
        fi
    done
}

mkdir -p "$CONFIG_DIR"
mkdir -p "$SYSTEMD_DIR"
check_dependencies

# ======================= Systemd 模板初始化 =======================
init_systemd_templates() {
    if [[ "$IS_ROOT" == true ]]; then
        cat <<'EOF' > "$CLIENT_SERVICE_FILE"
[Unit]
Description=Rathole Client Service (%i)
After=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
ExecStart=/usr/bin/rathole -c /etc/rathole/%i.toml

[Install]
WantedBy=multi-user.target
EOF

        cat <<'EOF' > "$SERVER_SERVICE_FILE"
[Unit]
Description=Rathole Server Service (%i)
After=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
ExecStart=/usr/bin/rathole -s /etc/rathole/%i.toml

[Install]
WantedBy=multi-user.target
EOF
    else
        cat <<'EOF' > "$CLIENT_SERVICE_FILE"
[Unit]
Description=Rathole Client User Service (%i)
After=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
ExecStart=%h/.local/bin/rathole -c %h/.local/etc/rathole/%i.toml

[Install]
WantedBy=default.target
EOF

        cat <<'EOF' > "$SERVER_SERVICE_FILE"
[Unit]
Description=Rathole Server User Service (%i)
After=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
ExecStart=%h/.local/bin/rathole -s %h/.local/etc/rathole/%i.toml

[Install]
WantedBy=default.target
EOF

        # 非 root 用户开启 linger，确保退出终端后服务仍然常驻后台运行
        if command -v loginctl &>/dev/null; then
            loginctl enable-linger "$USER" 2>/dev/null || true
        fi
    fi

    $SYSTEMCTL_CMD daemon-reload
}

# ======================= 版本检查与自动安装/更新 =======================
get_latest_release_info() {
    local api_url="${PROXY_PREFIX}https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    local release_json
    release_json=$(curl -sSL "$api_url")
    
    LATEST_TAG=$(echo "$release_json" | jq -r '.tag_name // empty')
    if [[ -z "$LATEST_TAG" ]]; then
        echo -e "${RED}获取最新版本号失败，请检查网络或代理连通性。${NC}"
        return 1
    fi
    
    DOWNLOAD_URL=$(echo "$release_json" | jq -r '.assets[] | select(.name | contains("x86_64-unknown-linux-gnu.zip")) | .browser_download_url' | head -n 1)
    if [[ -z "$DOWNLOAD_URL" ]]; then
        DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${LATEST_TAG}/rathole-x86_64-unknown-linux-gnu.zip"
    fi
}

install_or_update() {
    echo -e "${BLUE}===> 正在检测 Rathole 官方最新稳定版...${NC}"
    get_latest_release_info || return

    local current_ver=""
    if [[ -f "$BIN_PATH" ]]; then
        current_ver=$("$BIN_PATH" --version 2>&1 | awk '{print $2}')
        echo -e "当前本地版本: ${YELLOW}v${current_ver}${NC}"
    else
        echo -e "当前本地状态: ${YELLOW}未安装${NC}"
    fi

    echo -e "官方最新版本: ${GREEN}${LATEST_TAG}${NC}"

    if [[ "v${current_ver}" == "${LATEST_TAG}" ]]; then
        read -rp "当前版本已是最新，是否强制重新安装？(y/N): " force_reinstall
        if [[ "$force_reinstall" != "y" && "$force_reinstall" != "Y" ]]; then
            return
        fi
    fi

    local target_url="${PROXY_PREFIX}${DOWNLOAD_URL}"
    echo -e "${BLUE}开始通过加速代理下载: ${target_url}${NC}"
    
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if curl -fSL -o "${tmp_dir}/rathole.zip" "$target_url"; then
        unzip -qo "${tmp_dir}/rathole.zip" -d "$tmp_dir"
        install -m 755 "${tmp_dir}/rathole" "$BIN_PATH"
        rm -rf "$tmp_dir"
        init_systemd_templates
        echo -e "${GREEN}✓ Rathole ${LATEST_TAG} 安装成功！目标路径: ${BIN_PATH}${NC}"
    else
        echo -e "${RED}下载失败，请检查加速源或网络环境。${NC}"
        rm -rf "$tmp_dir"
    fi
}

# ======================= 多协议/多模式配置生成 =======================
add_config() {
    echo -e "\n${BLUE}--- 添加 Rathole 配置文件 ---${NC}"
    read -rp "请输入配置文件名称 (无需后缀，例如 web1): " conf_name
    [[ -z "$conf_name" ]] && echo -e "${RED}名称不能为空！${NC}" && return
    
    local target_file="${CONFIG_DIR}/${conf_name}.toml"
    if [[ -f "$target_file" ]]; then
        echo -e "${RED}错误: 配置文件 ${conf_name}.toml 已存在！${NC}"
        return
    fi

    echo "选择配置角色类型:"
    echo "1. 服务端 (Server)"
    echo "2. 客户端 (Client)"
    read -rp "输入选项 [1-2]: " role_choice

    echo -e "\n选择传输层通道加密模式 (Transport Layer):"
    echo "1. Plain (普通直连，无通道封装)"
    echo "2. Noise (Noise Protocol 加密，免配置证书)"
    echo "3. TLS / mTLS (基于 TLS 证书加密)"
    read -rp "输入传输层选项 [1-3, 默认 1]: " transport_choice
    transport_choice=${transport_choice:-1}

    echo -e "\n选择转发业务协议类型 (Service Type):"
    echo "1. TCP"
    echo "2. UDP"
    read -rp "输入协议类型 [1-2, 默认 1]: " proto_choice
    local svc_type="tcp"
    [[ "$proto_choice" == "2" ]] && svc_type="udp"

    case "$role_choice" in
        1)
            # 服务端参数录入
            read -rp "服务端监听端口 [默认 2333]: " bind_port
            bind_port=${bind_port:-2333}
            read -rp "转发服务名称 (Service Name, 例如 app_tcp): " svc_name
            read -rp "公网访问端口 (bind_addr 端口, 例如 8080): " svc_bind_port
            read -rp "认证密钥 (token): " svc_token

            cat <<EOF > "$target_file"
# Rathole Server Configuration
[server]
bind_addr = "0.0.0.0:${bind_port}"
EOF

            if [[ "$transport_choice" == "2" ]]; then
                cat <<EOF >> "$target_file"

[server.transport]
type = "noise"
EOF
            elif [[ "$transport_choice" == "3" ]]; then
                read -rp "TLS 证书绝对路径 (如 ${CONFIG_DIR}/server.crt): " tls_cert
                read -rp "TLS 私钥绝对路径 (如 ${CONFIG_DIR}/server.key): " tls_key
                cat <<EOF >> "$target_file"

[server.transport]
type = "tls"
[server.transport.tls]
cert = "${tls_cert}"
key = "${tls_key}"
EOF
            fi

            cat <<EOF >> "$target_file"

[server.services.${svc_name}]
type = "${svc_type}"
bind_addr = "0.0.0.0:${svc_bind_port}"
token = "${svc_token}"
EOF
            echo -e "${GREEN}✓ 服务端配置生成成功: ${target_file}${NC}"
            ;;

        2)
            # 客户端参数录入
            read -rp "服务端 IP 或域名: " server_host
            read -rp "服务端连接端口 [默认 2333]: " server_port
            server_port=${server_port:-2333}
            read -rp "转发服务名称 (须与服务端配置一致): " svc_name
            read -rp "本地目标服务地址 (local_addr, 例如 127.0.0.1:80): " local_addr
            read -rp "认证密钥 (token, 须与服务端一致): " svc_token

            cat <<EOF > "$target_file"
# Rathole Client Configuration
[client]
remote_addr = "${server_host}:${server_port}"
EOF

            if [[ "$transport_choice" == "2" ]]; then
                cat <<EOF >> "$target_file"

[client.transport]
type = "noise"
EOF
            elif [[ "$transport_choice" == "3" ]]; then
                read -rp "服务端 TLS 验证域名 (trusted_root/SNI): " tls_sni
                cat <<EOF >> "$target_file"

[client.transport]
type = "tls"
[client.transport.tls]
trusted_root = "${tls_sni}"
EOF
            fi

            cat <<EOF >> "$target_file"

[client.services.${svc_name}]
type = "${svc_type}"
local_addr = "${local_addr}"
token = "${svc_token}"
EOF
            echo -e "${GREEN}✓ 客户端配置生成成功: ${target_file}${NC}"
            ;;

        *)
            echo -e "${RED}输入无效，返回上层。${NC}"
            return
            ;;
    esac
}

# ======================= 删除配置及关联服务 =======================
delete_config() {
    echo -e "\n${BLUE}--- 删除 Rathole 配置文件 ---${NC}"
    local files=("$CONFIG_DIR"/*.toml)
    if [[ ! -e "${files[0]}" ]]; then
        echo -e "${YELLOW}未找到任何 .toml 配置文件。${NC}"
        return
    fi

    echo "现有配置文件清单:"
    for f in "${files[@]}"; do
        echo " - $(basename "$f" .toml)"
    done

    read -rp "请输入要删除的配置名称 (无需后缀): " del_name
    local target_file="${CONFIG_DIR}/${del_name}.toml"

    if [[ -f "$target_file" ]]; then
        read -rp "确认彻底停止关联服务并删除 ${del_name}.toml？(y/N): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            $SYSTEMCTL_CMD stop "rathole-client@${del_name}" 2>/dev/null || true
            $SYSTEMCTL_CMD stop "rathole-server@${del_name}" 2>/dev/null || true
            $SYSTEMCTL_CMD disable "rathole-client@${del_name}" 2>/dev/null || true
            $SYSTEMCTL_CMD disable "rathole-server@${del_name}" 2>/dev/null || true
            rm -f "$target_file"
            echo -e "${GREEN}✓ 配置及服务已成功移除。${NC}"
        fi
    else
        echo -e "${RED}未找到指定文件: ${target_file}${NC}"
    fi
}

# ======================= 服务运行与状态控制 =======================
manage_services() {
    echo -e "\n${BLUE}--- 实例运行状态看板 (${IS_ROOT:+全局Root模式}${IS_ROOT:-用户模式}) ---${NC}"
    local files=("$CONFIG_DIR"/*.toml)
    if [[ ! -e "${files[0]}" ]]; then
        echo -e "${YELLOW}当前没有任何配置，请先添加配置后再管理。${NC}"
        return
    fi

    printf "%-18s %-10s %-14s %-14s\n" "配置名称" "配置类型" "Client 状态" "Server 状态"
    echo "--------------------------------------------------------"
    for f in "${files[@]}"; do
        local name
        name=$(basename "$f" .toml)
        local role="未知"
        if grep -q "^\[client\]" "$f"; then role="Client"; fi
        if grep -q "^\[server\]" "$f"; then role="Server"; fi

        local c_status s_status
        c_status=$($SYSTEMCTL_CMD is-active "rathole-client@${name}" 2>/dev/null || echo "inactive")
        s_status=$($SYSTEMCTL_CMD is-active "rathole-server@${name}" 2>/dev/null || echo "inactive")

        printf "%-20s %-12s %-16s %-16s\n" "$name" "$role" "$c_status" "$s_status"
    done
    echo "--------------------------------------------------------"

    read -rp "请输入要操作的配置名称: " op_name
    if [[ ! -f "${CONFIG_DIR}/${op_name}.toml" ]]; then
        echo -e "${RED}配置不存在！${NC}"
        return
    fi

    echo -e "\n请选择针对 [${op_name}] 的操作:"
    echo "1. 启动 Client 服务"
    echo "2. 停止 Client 服务"
    echo "3. 启动 Server 服务"
    echo "4. 停止 Server 服务"
    echo "5. 配置开机自启"
    echo "6. 关闭开机自启"
    echo "7. 实时查看日志"
    read -rp "输入选项 [1-7]: " action_choice

    case "$action_choice" in
        1) $SYSTEMCTL_CMD start "rathole-client@${op_name}" && echo -e "${GREEN}已启动 Client@${op_name}${NC}" ;;
        2) $SYSTEMCTL_CMD stop "rathole-client@${op_name}" && echo -e "${YELLOW}已停止 Client@${op_name}${NC}" ;;
        3) $SYSTEMCTL_CMD start "rathole-server@${op_name}" && echo -e "${GREEN}已启动 Server@${op_name}${NC}" ;;
        4) $SYSTEMCTL_CMD stop "rathole-server@${op_name}" && echo -e "${YELLOW}已停止 Server@${op_name}${NC}" ;;
        5)
            read -rp "选择自启类型 (1: Client, 2: Server): " auto_mode
            [[ "$auto_mode" == "1" ]] && $SYSTEMCTL_CMD enable "rathole-client@${op_name}"
            [[ "$auto_mode" == "2" ]] && $SYSTEMCTL_CMD enable "rathole-server@${op_name}"
            echo -e "${GREEN}已完成开机自启动配置${NC}"
            ;;
        6)
            $SYSTEMCTL_CMD disable "rathole-client@${op_name}" 2>/dev/null || true
            $SYSTEMCTL_CMD disable "rathole-server@${op_name}" 2>/dev/null || true
            echo -e "${YELLOW}已取消开机自启动${NC}"
            ;;
        7)
            echo -e "${BLUE}正在展示日志，按 Ctrl+C 退出追踪...${NC}"
            $JOURNALCTL_CMD -u "rathole-*@${op_name}" -f -n 50
            ;;
        *) echo -e "${RED}无效选项${NC}" ;;
    esac
}

# ======================= 主菜单 =======================
menu() {
    while true; do
        local mode_desc="[Root 系统全局模式]"
        if [[ "$IS_ROOT" == false ]]; then
            mode_desc="[非 Root 用户模式 (${USER})]"
        fi

        echo -e "\n${GREEN}================ Rathole 多实例管理面板 ${mode_desc} ================${NC}"
        echo "1. 检查最新版本并安装/更新"
        echo "2. 添加配置文件 (TCP/UDP, Plain/Noise/TLS)"
        echo "3. 删除配置文件并清理服务"
        echo "4. 服务启停控制与状态看板"
        echo "0. 退出管理脚本"
        echo "========================================================================="
        read -rp "请输入序号 [0-4]: " choice

        case "$choice" in
            1) install_or_update ;;
            2) add_config ;;
            3) delete_config ;;
            4) manage_services ;;
            0) exit 0 ;;
            *) echo -e "${RED}输入无效，请重新输入。${NC}" ;;
        esac
    done
}

# 初始化 Systemd 单元文件
if [[ ! -f "$CLIENT_SERVICE_FILE" || ! -f "$SERVER_SERVICE_FILE" ]]; then
    init_systemd_templates
fi

menu