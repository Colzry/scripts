#!/usr/bin/env bash
set -euo pipefail

# ======================= 环境模式与路径自动判定 =======================
DOWNLOAD_PROXY="https://gitpy.223327.xyz/"
GITHUB_REPO="rathole-org/rathole"

# 终端色彩输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ACME_HOME="${HOME}/.acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"

if [[ $EUID -eq 0 ]]; then
    IS_ROOT=true
    SYSTEMCTL_CMD="systemctl"
    JOURNALCTL_CMD="journalctl"
    BIN_PATH="/usr/local/bin/rathole"
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
    if [[ ":$PATH:" != *":${HOME}/.local/bin:"* ]]; then
        export PATH="${HOME}/.local/bin:$PATH"
    fi
fi

CERTS_DIR="${CONFIG_DIR}/certs"
CLIENT_SERVICE_FILE="${SYSTEMD_DIR}/rathole-client@.service"
SERVER_SERVICE_FILE="${SYSTEMD_DIR}/rathole-server@.service"

# ======================= 依赖检查 =======================
check_dependencies() {
    for cmd in curl jq unzip systemctl openssl socat; do
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
                echo -e "${YELLOW}提示: 未检测到 $cmd，如需申请证书或解压请确保系统已就绪。${NC}"
            fi
        fi
    done
}

mkdir -p "$CONFIG_DIR"
mkdir -p "$CERTS_DIR"
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
ExecStart=/usr/local/bin/rathole -c /etc/rathole/%i.toml

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
ExecStart=/usr/local/bin/rathole -s /etc/rathole/%i.toml

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

        if command -v loginctl &>/dev/null; then
            loginctl enable-linger "$USER" 2>/dev/null || true
        fi
    fi

    $SYSTEMCTL_CMD daemon-reload
}

# ======================= Acme.sh 管理模块 =======================
ensure_acme_installed() {
    if [[ ! -f "$ACME_BIN" ]]; then
        echo -e "${YELLOW}未检测到 acme.sh，正在执行官方脚本安装...${NC}"
        read -rp "请输入申请证书所需的邮箱 (例如 admin@example.com): " acme_email
        [[ -z "$acme_email" ]] && acme_email="admin@example.com"
        curl https://get.acme.sh | sh -s email="$acme_email"
        echo -e "${GREEN}✓ acme.sh 安装完成，正在设置默认 CA 为 Let's Encrypt...${NC}"
        "$ACME_BIN" --set-default-ca --server letsencrypt
    fi
}

acme_manager() {
    while true; do
        echo -e "\n${CYAN}================ Acme.sh 证书管理面板 ================${NC}"
        echo "1. 安装 / 重新安装 Acme.sh 并配置 Let's Encrypt CA"
        echo "2. 申请证书 (80 端口 Standalone 独立验证模式)"
        echo "3. 申请证书 (自定义端口 Standalone 验证，如 88)"
        echo "4. 为 Rathole 转换 PKCS#12 (.p12) 并挂载续期重启钩子"
        echo "5. 查看已申请的域名证书列表"
        echo "0. 返回上级菜单"
        echo "======================================================"
        read -rp "请输入选项 [0-5]: " acme_choice

        case "$acme_choice" in
            1)
                ensure_acme_installed
                "$ACME_BIN" --set-default-ca --server letsencrypt
                echo -e "${GREEN}✓ Acme.sh 已初始化且默认 CA 已切至 Let's Encrypt${NC}"
                ;;
            2)
                ensure_acme_installed
                read -rp "请输入要申请证书的完整域名: " domain_name
                [[ -z "$domain_name" ]] && echo -e "${RED}域名不能为空！${NC}" && continue
                echo -e "${BLUE}开始申请证书 (请确保本地 80 端口空闲)...${NC}"
                "$ACME_BIN" --issue -d "$domain_name" --standalone
                ;;
            3)
                ensure_acme_installed
                read -rp "请输入要申请证书的完整域名: " domain_name
                read -rp "请输入验证端口 [例如 88]: " http_port
                [[ -z "$domain_name" || -z "$http_port" ]] && echo -e "${RED}域名或端口不能为空！${NC}" && continue
                echo -e "${BLUE}开始申请证书 (监听端口: ${http_port})...${NC}"
                "$ACME_BIN" --issue -d "$domain_name" --standalone --httpport "$http_port"
                ;;
            4)
                ensure_acme_installed
                read -rp "请输入已申请证书的域名 (如 ra.223327.xyz): " cert_domain
                read -rp "请输入导出 PKCS#12 的密码 [默认 rathole_pass_123]: " p12_pass
                p12_pass=${p12_pass:-rathole_pass_123}
                read -rp "关联的 Rathole 配置服务名称 (用于更新后重启实例，如 server): " svc_instance
                svc_instance=${svc_instance:-server}

                local ecc_dir="${ACME_HOME}/${cert_domain}_ecc"
                local standard_dir="${ACME_HOME}/${cert_domain}"
                local source_dir=""

                if [[ -d "$ecc_dir" ]]; then
                    source_dir="$ecc_dir"
                elif [[ -d "$standard_dir" ]]; then
                    source_dir="$standard_dir"
                else
                    echo -e "${RED}未在 ${ACME_HOME} 下找到该域名的证书目录！${NC}"
                    continue
                fi

                local p12_out="${CERTS_DIR}/${cert_domain}.p12"
                echo -e "${BLUE}正在导出证书至: ${p12_out}${NC}"

                openssl pkcs12 -export \
                    -in "${source_dir}/fullchain.cer" \
                    -inkey "${source_dir}/${cert_domain}.key" \
                    -out "$p12_out" \
                    -passout "pass:${p12_pass}"

                local restart_cmd="${SYSTEMCTL_CMD} restart rathole-server@${svc_instance}"
                local reload_hook="openssl pkcs12 -export -in ${source_dir}/fullchain.cer -inkey ${source_dir}/${cert_domain}.key -out ${p12_out} -passout pass:${p12_pass} && ${restart_cmd}"

                local is_ecc_flag=""
                [[ "$source_dir" == *"_ecc"* ]] && is_ecc_flag="--ecc"

                "$ACME_BIN" --install-cert -d "$cert_domain" $is_ecc_flag --reloadcmd "$reload_hook"
                echo -e "${GREEN}✓ PKCS#12 转换完成并成功注入续期 Hook！${NC}"
                ;;
            5)
                if [[ -f "$ACME_BIN" ]]; then
                    "$ACME_BIN" --list
                else
                    echo -e "${YELLOW}尚未安装 acme.sh${NC}"
                fi
                ;;
            0) break ;;
            *) echo -e "${RED}无效输入${NC}" ;;
        esac
    done
}

# ======================= 版本检查（仅直连，绝不走代理） =======================
get_latest_release_tag() {
    LATEST_TAG=""
    local ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"

    # 1. 尝试直接请求 GitHub 官方 API
    local api_res
    api_res=$(curl -sSL -m 6 -H "User-Agent: ${ua}" "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null || true)
    if [[ -n "$api_res" ]] && echo "$api_res" | jq -e '.tag_name' &>/dev/null; then
        LATEST_TAG=$(echo "$api_res" | jq -r '.tag_name')
        return 0
    fi

    # 2. 备选方案：通过官方 releases/latest 302 目标 URL 获取 tag
    local redirect_url
    redirect_url=$(curl -sSLI -m 6 -o /dev/null -w "%{url_effective}" "https://github.com/${GITHUB_REPO}/releases/latest" 2>/dev/null || true)
    if [[ "$redirect_url" =~ tag/(v?[0-9].*) ]]; then
        LATEST_TAG="${BASH_REMATCH[1]}"
        return 0
    fi

    # 3. 容错手动输入
    echo -e "${YELLOW}未能通过官方直接解析到最新版本号。${NC}"
    read -rp "请手动指定要安装的版本号 (例如 v0.5.0，直接回车取消): " manual_tag
    if [[ -n "$manual_tag" ]]; then
        LATEST_TAG="$manual_tag"
        return 0
    fi

    return 1
}

# ======================= 下载与安装（精准提取版本号） =======================
install_or_update() {
    echo -e "${BLUE}===> 正在检查 Rathole 官方最新稳定版...${NC}"
    if ! get_latest_release_tag; then
        echo -e "${RED}获取最新版本失败。${NC}"
        return
    fi

    local current_ver=""
    if [[ -f "$BIN_PATH" ]]; then
        # 执行 rathole -V 并使用正则精准匹配版本号
        local raw_ver
        raw_ver=$("$BIN_PATH" -V 2>&1 || true)
        local parsed_ver
        parsed_ver=$(echo "$raw_ver" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)

        if [[ -n "$parsed_ver" ]]; then
            current_ver="v${parsed_ver}"
            echo -e "当前本地安装版本: ${YELLOW}${current_ver}${NC}"
        else
            echo -e "当前本地安装版本: ${YELLOW}未知版本${NC}"
        fi
    else
        echo -e "当前本地状态: ${YELLOW}未安装${NC}"
    fi

    # 统一确保最新 tag 带 v
    local display_latest_tag="$LATEST_TAG"
    [[ "$display_latest_tag" != v* ]] && display_latest_tag="v${display_latest_tag}"
    echo -e "目标安装版本: ${GREEN}${display_latest_tag}${NC}"

    # 版本对齐对比
    if [[ -n "$current_ver" && "$current_ver" == "$display_latest_tag" ]]; then
        read -rp "当前版本已是最新 (${current_ver})，是否覆盖重装？(y/N): " force_reinstall
        if [[ "$force_reinstall" != "y" && "$force_reinstall" != "Y" ]]; then
            return
        fi
    fi

    # 确保目标安装目录存在
    mkdir -p "$(dirname "$BIN_PATH")"

    # 构造原始下载路径及代理加速下载路径
    local raw_download_url="https://github.com/${GITHUB_REPO}/releases/download/${LATEST_TAG}/rathole-x86_64-unknown-linux-gnu.zip"
    local proxy_download_url="${DOWNLOAD_PROXY}${raw_download_url}"

    echo -e "${BLUE}通过下载代理拉取: ${proxy_download_url}${NC}"

    local tmp_dir
    tmp_dir=$(mktemp -d)

    # 优先走代理下载，如果代理出错则回退到官方直连
    if curl -fSL -o "${tmp_dir}/rathole.zip" "$proxy_download_url"; then
        unzip -qo "${tmp_dir}/rathole.zip" -d "$tmp_dir"
        install -m 755 "${tmp_dir}/rathole" "$BIN_PATH"
        rm -rf "$tmp_dir"
        init_systemd_templates
        echo -e "${GREEN}✓ Rathole ${LATEST_TAG} 安装成功！安装路径: ${BIN_PATH}${NC}"
    else
        echo -e "${YELLOW}代理下载失败，正在尝试直连官方源下载...${NC}"
        if curl -fSL -o "${tmp_dir}/rathole.zip" "$raw_download_url"; then
            unzip -qo "${tmp_dir}/rathole.zip" -d "$tmp_dir"
            install -m 755 "${tmp_dir}/rathole" "$BIN_PATH"
            rm -rf "$tmp_dir"
            init_systemd_templates
            echo -e "${GREEN}✓ Rathole ${LATEST_TAG} 安装成功！${NC}"
        else
            echo -e "${RED}下载失败，请检查网络连接。${NC}"
            rm -rf "$tmp_dir"
        fi
    fi
}

# ======================= 多协议/多模式配置生成 =======================
add_config() {
    echo -e "\n${BLUE}--- 添加 Rathole 配置文件 ---${NC}"
    read -rp "请输入配置文件名称 (无需后缀，例如 app1): " conf_name
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
    echo "1. Plain (常规明文直连)"
    echo "2. Noise (Noise Protocol 加密，轻量安全免配置证书)"
    echo "3. TLS / mTLS (基于 TLS 证书加密)"
    read -rp "输入传输层选项 [1-3, 默认 1]: " transport_choice
    transport_choice=${transport_choice:-1}

    echo -e "\n选择内网穿透协议类型 (Service Type):"
    echo "1. TCP"
    echo "2. UDP"
    read -rp "输入协议类型 [1-2, 默认 1]: " proto_choice
    local svc_type="tcp"
    [[ "$proto_choice" == "2" ]] && svc_type="udp"

    case "$role_choice" in
        1)
            # 服务端
            read -rp "服务端运行监听端口 [默认 2333]: " bind_port
            bind_port=${bind_port:-2333}
            read -rp "转发服务名称 (Service Name, 例如 web_app): " svc_name
            read -rp "对外暴露公网监听端口 (bind_addr 端口, 例如 8080): " svc_bind_port
            read -rp "服务共享鉴权密钥 (token): " svc_token

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
                echo -e "\n${CYAN}--- TLS 证书配置 ---${NC}"
                echo "1. 使用 PKCS#12 格式证书 (.p12)"
                echo "2. 使用 PEM 格式证书 (.cer / .crt 和 .key)"
                read -rp "请选择证书类型 [1-2, 默认 1]: " cert_format
                cert_format=${cert_format:-1}

                if [[ "$cert_format" == "1" ]]; then
                    echo "系统已检测到的 .p12 证书:"
                    local p12_files=("$CERTS_DIR"/*.p12)
                    if [[ -e "${p12_files[0]}" ]]; then
                        for pf in "${p12_files[@]}"; do
                            echo " - $pf"
                        done
                    fi
                    read -rp "请输入 .p12 证书路径: " p12_path
                    read -rp "请输入 .p12 证书密码: " p12_pwd
                    cat <<EOF >> "$target_file"

[server.transport]
type = "tls"
[server.transport.tls.pkcs12]
path = "${p12_path}"
password = "${p12_pwd}"
EOF
                else
                    echo "正在检索 ${ACME_HOME} 中的证书..."
                    if [[ -d "$ACME_HOME" ]]; then
                        find "$ACME_HOME" -maxdepth 2 -name "fullchain.cer" 2>/dev/null || true
                    fi
                    read -rp "TLS 证书全链路径 (cert/fullchain.cer): " tls_cert
                    read -rp "TLS 私钥路径 (key): " tls_key
                    cat <<EOF >> "$target_file"

[server.transport]
type = "tls"
[server.transport.tls]
cert = "${tls_cert}"
key = "${tls_key}"
EOF
                fi
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
            # 客户端
            read -rp "服务端公网 IP 或域名: " server_host
            read -rp "服务端监听端口 [默认 2333]: " server_port
            server_port=${server_port:-2333}
            read -rp "转发服务名称 (须与服务端一致): " svc_name
            read -rp "本地目标服务地址 (local_addr, 例如 127.0.0.1:80): " local_addr
            read -rp "服务共享鉴权密钥 (token, 须与服务端一致): " svc_token

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
                read -rp "服务端 TLS 认证域名 (trusted_root/SNI，例如 example.com): " tls_sni
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
        echo "1. 检查最新版本并安装/更新 Rathole"
        echo "2. 添加配置文件 (TCP/UDP, Plain/Noise/TLS)"
        echo "3. 删除配置文件并清理服务"
        echo "4. 服务启停控制与状态看板"
        echo "5. Acme.sh 证书申请与管理 (支持 PKCS#12 转换与续期挂载)"
        echo "0. 退出管理脚本"
        echo "========================================================================="
        read -rp "请输入序号 [0-5]: " choice

        case "$choice" in
            1) install_or_update ;;
            2) add_config ;;
            3) delete_config ;;
            4) manage_services ;;
            5) acme_manager ;;
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