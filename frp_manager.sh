#!/usr/bin/env bash
set -euo pipefail

# ======================= 环境模式与路径自动判定 =======================
DOWNLOAD_PROXY="https://gitpy.223327.xyz/"
GITHUB_REPO="fatedier/frp"

# 终端色彩定义
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
    BIN_DIR="/usr/local/bin"
    CONFIG_DIR="/etc/frp"
    SYSTEMD_DIR="/etc/systemd/system"
else
    IS_ROOT=false
    SYSTEMCTL_CMD="systemctl --user"
    JOURNALCTL_CMD="journalctl --user"
    BIN_DIR="${HOME}/.local/bin"
    CONFIG_DIR="${HOME}/.local/etc/frp"
    SYSTEMD_DIR="${HOME}/.config/systemd/user"
    mkdir -p "${BIN_DIR}"
    if [[ ":$PATH:" != *":${BIN_DIR}:"* ]]; then
        export PATH="${BIN_DIR}:$PATH"
    fi
fi

FRPS_BIN="${BIN_DIR}/frps"
FRPC_BIN="${BIN_DIR}/frpc"
CERTS_DIR="${CONFIG_DIR}/certs"
CLIENT_SERVICE_FILE="${SYSTEMD_DIR}/frpc@.service"
SERVER_SERVICE_FILE="${SYSTEMD_DIR}/frps@.service"

# ======================= 交互校验工具函数 =======================
prompt_required() {
    local prompt_msg="$1"
    local var_name="$2"
    local val=""
    while true; do
        read -rp "$prompt_msg" val
        val=$(echo "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [[ -n "$val" ]]; then
            printf -v "$var_name" '%s' "$val"
            break
        else
            echo -e "${RED}该项为必填项，内容不能为空，请重新输入！${NC}"
        fi
    done
}

prompt_local_port_and_ip() {
    local val=""
    while true; do
        read -rp "本地服务地址或端口 (支持输入 8080 或 127.0.0.1:8080): " val
        val=$(echo "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [[ -z "$val" ]]; then
            echo -e "${RED}该项为必填项，内容不能为空，请重新输入！${NC}"
            continue
        fi

        if [[ "$val" =~ ^[0-9]+$ ]]; then
            LOCAL_IP="127.0.0.1"
            LOCAL_PORT="$val"
            echo -e "${YELLOW}检测到仅输入端口，已自动补全为: ${LOCAL_IP}:${LOCAL_PORT}${NC}"
        elif [[ "$val" =~ ^(.*):([0-9]+)$ ]]; then
            LOCAL_IP="${BASH_REMATCH[1]}"
            LOCAL_PORT="${BASH_REMATCH[2]}"
        else
            echo -e "${RED}格式不正确，请输入端口 (如 80) 或 host:port (如 192.168.1.5:80)！${NC}"
            continue
        fi
        break
    done
}

# ======================= 终端居中对齐工具 =======================
get_str_display_width() {
    local text="$1"
    local total_bytes
    total_bytes=$(printf "%s" "$text" | wc -c)
    local total_chars
    total_chars=$(printf "%s" "$text" | wc -m)
    echo $(( (total_bytes - total_chars) / 2 + total_chars ))
}

print_cell() {
    local plain_txt="$1"
    local colored_txt="$2"
    local col_width="$3"

    local cur_w
    cur_w=$(get_str_display_width "$plain_txt")

    if (( cur_w >= col_width )); then
        printf "%b" "$colored_txt"
        return
    fi

    local pad_total=$(( col_width - cur_w ))
    local pad_left=$(( pad_total / 2 ))
    local pad_right=$(( pad_total - pad_left ))

    printf "%*s%b%*s" "$pad_left" "" "$colored_txt" "$pad_right" ""
}

# ======================= 依赖检查 =======================
check_dependencies() {
    for cmd in curl jq tar systemctl openssl socat; do
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
                echo -e "${YELLOW}提示: 未检测到 $cmd，请确保系统已安装相应依赖。${NC}"
            fi
        fi
    done
}

mkdir -p "$CONFIG_DIR"
mkdir -p "$CERTS_DIR"
mkdir -p "$SYSTEMD_DIR"
check_dependencies

# ======================= 强制重写并同步 Systemd 模板 =======================
init_systemd_templates() {
    if [[ "$IS_ROOT" == true ]]; then
        cat <<'EOF' > "$CLIENT_SERVICE_FILE"
[Unit]
Description=Frp Client Service (%i)
After=network.target syslog.target
Wants=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
ExecStart=/usr/local/bin/frpc -c /etc/frp/%i.toml

[Install]
WantedBy=multi-user.target
EOF

        cat <<'EOF' > "$SERVER_SERVICE_FILE"
[Unit]
Description=Frp Server Service (%i)
After=network.target syslog.target
Wants=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
ExecStart=/usr/local/bin/frps -c /etc/frp/%i.toml

[Install]
WantedBy=multi-user.target
EOF
    else
        cat <<'EOF' > "$CLIENT_SERVICE_FILE"
[Unit]
Description=Frp Client User Service (%i)
After=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
ExecStart=%h/.local/bin/frpc -c %h/.local/etc/frp/%i.toml

[Install]
WantedBy=default.target
EOF

        cat <<'EOF' > "$SERVER_SERVICE_FILE"
[Unit]
Description=Frp Server User Service (%i)
After=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
ExecStart=%h/.local/bin/frps -c %h/.local/etc/frp/%i.toml

[Install]
WantedBy=default.target
EOF

        if command -v loginctl &>/dev/null; then
            loginctl enable-linger "$USER" 2>/dev/null || true
        fi
    fi

    $SYSTEMCTL_CMD daemon-reload
}

# ======================= Acme.sh 管理模块 (已精简) =======================
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
        echo "1. 安装 / 初始化 Acme.sh (配置 Let's Encrypt CA)"
        echo "2. 申请证书并同步到 FRP 目录 (80 端口 Standalone 模式)"
        echo "3. 申请证书并同步到 FRP 目录 (自定义端口 Standalone 模式)"
        echo "4. 查看已申请的域名证书列表"
        echo "5. 删除已申请的域名证书"
        echo "0. 返回上级菜单"
        echo "====================================================="
        read -rp "请输入选项 [0-5]: " acme_choice

        case "$acme_choice" in
            1)
                ensure_acme_installed
                "$ACME_BIN" --set-default-ca --server letsencrypt
                echo -e "${GREEN}✓ Acme.sh 已就绪，默认 CA 已设为 Let's Encrypt${NC}"
                ;;
            2|3)
                ensure_acme_installed
                prompt_required "请输入要申请证书的完整域名 (如 example.com): " domain_name

                local port_param=""
                if [[ "$acme_choice" == "3" ]]; then
                    prompt_required "请输入验证端口 [如 88]: " http_port
                    port_param="--httpport $http_port"
                fi

                echo -e "${BLUE}开始申请证书...${NC}"
                if "$ACME_BIN" --issue -d "$domain_name" --standalone $port_param; then
                    read -rp "关联重启的 FRP 实例名 (若不需要自动重启直接回车): " svc_instance
                    local reload_cmd=""
                    if [[ -n "$svc_instance" ]]; then
                        read -rp "该实例角色 (1. Server / 2. Client) [默认 1]: " svc_role
                        local unit_name="frps@${svc_instance}"
                        [[ "$svc_role" == "2" ]] && unit_name="frpc@${svc_instance}"
                        reload_cmd="${SYSTEMCTL_CMD} restart ${unit_name}"
                    fi

                    local dest_cert="${CERTS_DIR}/${domain_name}.crt"
                    local dest_key="${CERTS_DIR}/${domain_name}.key"

                    "$ACME_BIN" --install-cert -d "$domain_name" --ecc \
                        --key-file "$dest_key" \
                        --fullchain-file "$dest_cert" \
                        ${reload_cmd:+--reloadcmd "$reload_cmd"}

                    echo -e "${GREEN}✓ 证书已部署至: ${CERTS_DIR}${NC}"
                    echo -e "证书路径: ${dest_cert}\n私钥路径: ${dest_key}"
                else
                    echo -e "${RED}证书申请失败，请检查端口是否被占用或域名解析是否正确。${NC}"
                fi
                ;;
            4)
                if [[ -f "$ACME_BIN" ]]; then
                    "$ACME_BIN" --list
                else
                    echo -e "${YELLOW}尚未安装 acme.sh${NC}"
                fi
                ;;
            5)
                echo -e "\n${BLUE}--- 删除域名证书 ---${NC}"
                if [[ ! -f "$ACME_BIN" ]]; then
                    echo -e "${YELLOW}尚未安装 acme.sh${NC}"
                    continue
                fi
                prompt_required "请输入要删除的域名: " rm_domain
                "$ACME_BIN" --remove -d "$rm_domain" --ecc 2>/dev/null || true
                "$ACME_BIN" --remove -d "$rm_domain" 2>/dev/null || true
                rm -rf "${ACME_HOME}/${rm_domain}"*
                rm -f "${CERTS_DIR}/${rm_domain}.crt" "${CERTS_DIR}/${rm_domain}.key"
                echo -e "${GREEN}✓ 域名 [${rm_domain}] 证书已移除${NC}"
                ;;
            0) break ;;
            *) echo -e "${RED}无效输入${NC}" ;;
        esac
    done
}

# ======================= 版本检查 =======================
get_latest_release_tag() {
    LATEST_TAG=""
    local ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"

    local api_res
    api_res=$(curl -sSL -m 6 -H "User-Agent: ${ua}" "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null || true)
    if [[ -n "$api_res" ]] && echo "$api_res" | jq -e '.tag_name' &>/dev/null; then
        LATEST_TAG=$(echo "$api_res" | jq -r '.tag_name')
        return 0
    fi

    local redirect_url
    redirect_url=$(curl -sSLI -m 6 -o /dev/null -w "%{url_effective}" "https://github.com/${GITHUB_REPO}/releases/latest" 2>/dev/null || true)
    if [[ "$redirect_url" =~ tag/(v?[0-9].*) ]]; then
        LATEST_TAG="${BASH_REMATCH[1]}"
        return 0
    fi

    echo -e "${YELLOW}未能通过官方直接解析到最新版本号。${NC}"
    read -rp "请手动指定要安装的版本号 (例如 v0.58.1，回车取消): " manual_tag
    if [[ -n "$manual_tag" ]]; then
        LATEST_TAG="$manual_tag"
        return 0
    fi

    return 1
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armhf) echo "arm" ;;
        i386|i686) echo "386" ;;
        mips64le) echo "mips64le" ;;
        mips64) echo "mips64" ;;
        riscv64) echo "riscv64" ;;
        *)
            echo -e "${RED}不支持的系统架构: $arch${NC}" >&2
            return 1
            ;;
    esac
}

# ======================= 下载与安装 =======================
install_or_update() {
    echo -e "${BLUE}===> 正在检查 FRP 官方最新版本...${NC}"
    if ! get_latest_release_tag; then
        echo -e "${RED}获取最新版本失败。${NC}"
        return
    fi

    local current_ver=""
    if [[ -f "$FRPS_BIN" ]]; then
        local raw_ver
        raw_ver=$("$FRPS_BIN" -v 2>&1 || true)
        if [[ -n "$raw_ver" ]]; then
            current_ver="v${raw_ver#v}"
            echo -e "当前本地安装版本: ${YELLOW}${current_ver}${NC}"
        fi
    else
        echo -e "当前本地状态: ${YELLOW}未安装${NC}"
    fi

    local display_latest_tag="$LATEST_TAG"
    [[ "$display_latest_tag" != v* ]] && display_latest_tag="v${display_latest_tag}"
    echo -e "目标安装版本: ${GREEN}${display_latest_tag}${NC}"

    if [[ -n "$current_ver" && "$current_ver" == "$display_latest_tag" ]]; then
        read -rp "当前版本已是最新 (${current_ver})，是否覆盖重装？(y/N): " force_reinstall
        if [[ "$force_reinstall" != "y" && "$force_reinstall" != "Y" ]]; then
            return
        fi
    fi

    local arch
    arch=$(detect_arch) || return

    local clean_tag="${LATEST_TAG#v}"
    local archive_name="frp_${clean_tag}_linux_${arch}.tar.gz"
    local raw_download_url="https://github.com/${GITHUB_REPO}/releases/download/${LATEST_TAG}/${archive_name}"
    local proxy_download_url="${DOWNLOAD_PROXY}${raw_download_url}"

    echo -e "${BLUE}通过下载代理拉取: ${proxy_download_url}${NC}"

    local tmp_dir
    tmp_dir=$(mktemp -d)

    if curl -fSL -o "${tmp_dir}/frp.tar.gz" "$proxy_download_url"; then
        tar -zxf "${tmp_dir}/frp.tar.gz" -C "$tmp_dir"
        local extracted_dir="${tmp_dir}/frp_${clean_tag}_linux_${arch}"
        install -m 755 "${extracted_dir}/frps" "$FRPS_BIN"
        install -m 755 "${extracted_dir}/frpc" "$FRPC_BIN"
        rm -rf "$tmp_dir"
        init_systemd_templates
        echo -e "${GREEN}✓ FRP ${LATEST_TAG} 安装成功！路径: ${BIN_DIR}/frps 和 ${BIN_DIR}/frpc${NC}"
    else
        echo -e "${YELLOW}代理下载失败，正在尝试官方源直连...${NC}"
        if curl -fSL -o "${tmp_dir}/frp.tar.gz" "$raw_download_url"; then
            tar -zxf "${tmp_dir}/frp.tar.gz" -C "$tmp_dir"
            local extracted_dir="${tmp_dir}/frp_${clean_tag}_linux_${arch}"
            install -m 755 "${extracted_dir}/frps" "$FRPS_BIN"
            install -m 755 "${extracted_dir}/frpc" "$FRPC_BIN"
            rm -rf "$tmp_dir"
            init_systemd_templates
            echo -e "${GREEN}✓ FRP ${LATEST_TAG} 安装成功！${NC}"
        else
            echo -e "${RED}下载失败，请检查网络连接。${NC}"
            rm -rf "$tmp_dir"
        fi
    fi
}

# ======================= 添加主配置文件 =======================
add_config() {
    echo -e "\n${BLUE}--- 添加 FRP 主配置文件 (TOML 规范) ---${NC}"
    
    echo "请选择配置角色类型:"
    echo "1. 服务端 (frps)"
    echo "2. 客户端 (frpc)"
    local role_choice=""
    while [[ "$role_choice" != "1" && "$role_choice" != "2" ]]; do
        read -rp "输入选项 [1-2]: " role_choice
    done

    local role_str="Server"
    [[ "$role_choice" == "2" ]] && role_str="Client"
    echo -e "已选择角色: ${CYAN}${role_str}${NC}"

    prompt_required "请输入配置文件名称 (无需后缀，如 default): " conf_name
    local target_file="${CONFIG_DIR}/${conf_name}.toml"
    if [[ -f "$target_file" ]]; then
        echo -e "${RED}错误: 配置文件 ${conf_name}.toml 已存在！${NC}"
        return
    fi

    case "$role_choice" in
        1)
            read -rp "服务端监听端口 (bindPort) [默认 7000]: " bind_port
            bind_port=${bind_port:-7000}
            prompt_required "认证 Token (auth.token): " auth_token
            
            read -rp "是否开启 HTTP 虚拟主机端口 (vhostHTTPPort，输入 0 跳过) [默认 80]: " vhost_http
            vhost_http=${vhost_http:-80}
            read -rp "是否开启 HTTPS 虚拟主机端口 (vhostHTTPSPort，输入 0 跳过) [默认 443]: " vhost_https
            vhost_https=${vhost_https:-443}

            cat <<EOF > "$target_file"
# FRP Server Configuration (TOML)
bindPort = ${bind_port}

auth.method = "token"
auth.token = "${auth_token}"
EOF

            if [[ "$vhost_http" != "0" && -n "$vhost_http" ]]; then
                echo "vhostHTTPPort = ${vhost_http}" >> "$target_file"
            fi
            if [[ "$vhost_https" != "0" && -n "$vhost_https" ]]; then
                echo "vhostHTTPSPort = ${vhost_https}" >> "$target_file"
            fi

            echo -e "${GREEN}✓ 服务端配置文件生成成功: ${target_file}${NC}"
            ;;

        2)
            prompt_required "服务端连接地址 (serverAddr, 如公网 IP 或域名): " server_addr
            read -rp "服务端连接端口 (serverPort) [默认 7000]: " server_port
            server_port=${server_port:-7000}
            prompt_required "认证 Token (auth.token，须与服务端一致): " auth_token

            echo -e "\n底层传输协议 (transport.protocol):"
            echo "1. tcp (默认标准模式)"
            echo "2. kcp (抗丢包弱网优化)"
            echo "3. quic (基于 UDP 的 QUIC 协议)"
            echo "4. websocket"
            read -rp "选择传输协议 [1-4, 默认 1]: " proto_sel
            local trans_proto="tcp"
            case "$proto_sel" in
                2) trans_proto="kcp" ;;
                3) trans_proto="quic" ;;
                4) trans_proto="websocket" ;;
                *) trans_proto="tcp" ;;
            esac

            read -rp "是否开启 TLS 加密传输连接？(y/N) [默认 N]: " enable_tls
            local tls_setting="false"
            [[ "$enable_tls" == "y" || "$enable_tls" == "Y" ]] && tls_setting="true"

            cat <<EOF > "$target_file"
# FRP Client Configuration (TOML)
serverAddr = "${server_addr}"
serverPort = ${server_port}

auth.method = "token"
auth.token = "${auth_token}"

transport.protocol = "${trans_proto}"
transport.tls.enable = ${tls_setting}
EOF

            read -rp "是否立即配置首个转发代理规则？(Y/n): " init_proxy
            if [[ "$init_proxy" != "n" && "$init_proxy" != "N" ]]; then
                append_client_proxy "$target_file"
            fi

            echo -e "${GREEN}✓ 客户端配置文件生成成功: ${target_file}${NC}"
            ;;
    esac
}

# ======================= 向客户端追加代理规则 =======================
append_client_proxy() {
    local target_file="$1"

    echo -e "\n选择转发代理协议类型:"
    echo "1. TCP (端口映射，如 SSH、RDP)"
    echo "2. UDP (端口映射，如 DNS、游戏服务)"
    echo "3. HTTP (基于域名反向代理)"
    echo "4. HTTPS (支持域名 SNI 透传或证书卸载)"
    read -rp "输入协议类型 [1-4, 默认 1]: " proxy_type_sel

    prompt_required "代理服务名称 (例如 web_home 或 ssh_linux): " proxy_name

    if grep -q "name = \"${proxy_name}\"" "$target_file"; then
        echo -e "${RED}错误: 代理名 [${proxy_name}] 在当前配置文件中已存在！${NC}"
        return
    fi

    prompt_local_port_and_ip

    case "$proxy_type_sel" in
        2)
            prompt_required "服务端远程 UDP 端口 (remotePort, 例如 5353): " remote_port
            cat <<EOF >> "$target_file"

[[proxies]]
name = "${proxy_name}"
type = "udp"
localIP = "${LOCAL_IP}"
localPort = ${LOCAL_PORT}
remotePort = ${remote_port}
EOF
            ;;
        3)
            prompt_required "绑定的自定义域名 (customDomains, 例如 web.example.com): " custom_domains
            cat <<EOF >> "$target_file"

[[proxies]]
name = "${proxy_name}"
type = "http"
localIP = "${LOCAL_IP}"
localPort = ${LOCAL_PORT}
customDomains = ["${custom_domains}"]
EOF
            ;;
        4)
            prompt_required "绑定的自定义域名 (customDomains, 例如 ssl.example.com): " custom_domains
            cat <<EOF >> "$target_file"

[[proxies]]
name = "${proxy_name}"
type = "https"
localIP = "${LOCAL_IP}"
localPort = ${LOCAL_PORT}
customDomains = ["${custom_domains}"]
EOF
            ;;
        *)
            prompt_required "服务端远程 TCP 端口 (remotePort, 例如 60022): " remote_port
            cat <<EOF >> "$target_file"

[[proxies]]
name = "${proxy_name}"
type = "tcp"
localIP = "${LOCAL_IP}"
localPort = ${LOCAL_PORT}
remotePort = ${remote_port}
EOF
            ;;
    esac

    echo -e "${GREEN}✓ 代理映射 [${proxy_name}] 已成功追加到 ${target_file}${NC}"
}

# ======================= 追加代理配置入口 =======================
append_service_config() {
    echo -e "\n${BLUE}--- 向现有客户端配置追加代理规则 ---${NC}"
    local files=("$CONFIG_DIR"/*.toml)
    if [[ ! -e "${files[0]}" ]]; then
        echo -e "${YELLOW}未检索到任何配置文件，请先添加主配置文件！${NC}"
        return
    fi

    echo "现有配置文件清单:"
    local names=()
    local idx=1
    for f in "${files[@]}"; do
        local n
        n=$(basename "$f" .toml)
        names+=("$n")
        echo -e "  [${CYAN}${idx}${NC}] ${n}"
        ((idx++))
    done
    echo "----------------------------------------"

    read -rp "请选择要追加代理规则的客户端配置 [序号或名称, 0 取消]: " target_input
    [[ "$target_input" == "0" || -z "$target_input" ]] && return

    local conf_name=""
    if [[ "$target_input" =~ ^[0-9]+$ ]] && (( target_input >= 1 && target_input <= ${#names[@]} )); then
        conf_name="${names[$((target_input - 1))]}"
    else
        conf_name="$target_input"
    fi

    local target_file="${CONFIG_DIR}/${conf_name}.toml"
    if [[ ! -f "$target_file" ]]; then
        echo -e "${RED}未找到指定配置文件: ${target_file}${NC}"
        return
    fi

    if grep -q "bindPort" "$target_file"; then
        echo -e "${YELLOW}提示: [${conf_name}] 是服务端 (frps) 配置，代理规则通常只需在客户端 (frpc) 追加定义。${NC}"
        return
    fi

    append_client_proxy "$target_file"

    local unit_name="frpc@${conf_name}"
    if [[ $($SYSTEMCTL_CMD is-active "$unit_name" 2>/dev/null) == "active" ]]; then
        read -rp "检测到该服务正在运行，是否立即重启使其生效？(Y/n): " restart_now
        if [[ "$restart_now" != "n" && "$restart_now" != "N" ]]; then
            $SYSTEMCTL_CMD restart "$unit_name"
            echo -e "${GREEN}✓ 服务 ${unit_name} 已成功重启。${NC}"
        fi
    fi
}

# ======================= 删除配置及关联服务 =======================
delete_config() {
    echo -e "\n${BLUE}--- 删除 FRP 配置文件及对应服务 ---${NC}"
    local files=("$CONFIG_DIR"/*.toml)
    if [[ ! -e "${files[0]}" ]]; then
        echo -e "${YELLOW}未找到任何 .toml 配置文件。${NC}"
        return
    fi

    echo "现有配置文件清单:"
    local names=()
    local idx=1
    for f in "${files[@]}"; do
        local n
        n=$(basename "$f" .toml)
        names+=("$n")
        echo -e "  [${CYAN}${idx}${NC}] ${n}"
        ((idx++))
    done
    echo "----------------------------------------"

    read -rp "请输入要删除的配置 [序号或名称, 0 取消]: " del_input
    [[ "$del_input" == "0" || -z "$del_input" ]] && return

    local del_name=""
    if [[ "$del_input" =~ ^[0-9]+$ ]] && (( del_input >= 1 && del_input <= ${#names[@]} )); then
        del_name="${names[$((del_input - 1))]}"
    else
        del_name="$del_input"
    fi

    local target_file="${CONFIG_DIR}/${del_name}.toml"

    if [[ -f "$target_file" ]]; then
        read -rp "确认彻底停止关联服务并删除 ${del_name}.toml？(y/N): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            $SYSTEMCTL_CMD stop "frpc@${del_name}" 2>/dev/null || true
            $SYSTEMCTL_CMD stop "frps@${del_name}" 2>/dev/null || true
            $SYSTEMCTL_CMD disable "frpc@${del_name}" 2>/dev/null || true
            $SYSTEMCTL_CMD disable "frps@${del_name}" 2>/dev/null || true
            rm -f "$target_file"
            echo -e "${GREEN}✓ 配置及服务已成功移除: ${del_name}.toml${NC}"
        else
            echo -e "${YELLOW}操作已取消。${NC}"
        fi
    else
        echo -e "${RED}未找到指定配置文件: ${target_file}${NC}"
    fi
}

# ======================= 状态看板与管理菜单 =======================
manage_services() {
    local mode_tag="用户模式"
    [[ "$IS_ROOT" == true ]] && mode_tag="Root 全局模式"
    echo -e "\n${BLUE}--- 实例运行状态看板 [${mode_tag}] ---${NC}"

    local files=("$CONFIG_DIR"/*.toml)
    if [[ ! -e "${files[0]}" ]]; then
        echo -e "${YELLOW}当前没有任何配置，请先添加配置后再管理。${NC}"
        return
    fi

    local W_IDX=8
    local W_NAME=18
    local W_TYPE=14
    local W_STATUS=18
    local W_ENABLED=16

    print_cell "序号" "序号" "$W_IDX"
    print_cell "配置名称" "配置名称" "$W_NAME"
    print_cell "配置类型" "配置类型" "$W_TYPE"
    print_cell "运行状态" "运行状态" "$W_STATUS"
    print_cell "自启状态" "自启状态" "$W_ENABLED"
    echo
    echo "----------------------------------------------------------------------------------"

    local config_list=()
    local idx=1
    for f in "${files[@]}"; do
        local name
        name=$(basename "$f" .toml)
        config_list+=("$name")

        local role="未知"
        local unit=""
        if grep -q "serverAddr" "$f"; then 
            role="Client (frpc)"
            unit="frpc@${name}"
        elif grep -q "bindPort" "$f"; then 
            role="Server (frps)"
            unit="frps@${name}"
        fi

        local active_status="inactive"
        local enabled_status="disabled"

        if [[ -n "$unit" ]]; then
            active_status=$($SYSTEMCTL_CMD is-active "$unit" 2>/dev/null | head -n 1 | tr -d ' \r\n' || true)
            enabled_status=$($SYSTEMCTL_CMD is-enabled "$unit" 2>/dev/null | head -n 1 | tr -d ' \r\n' || true)
        fi

        [[ -z "$active_status" ]] && active_status="inactive"
        [[ -z "$enabled_status" ]] && enabled_status="disabled"

        local active_colored="$active_status"
        case "$active_status" in
            active)   active_colored="${GREEN}${active_status}${NC}" ;;
            inactive) active_colored="${RED}${active_status}${NC}" ;;
            failed)   active_colored="${RED}${active_status}${NC}" ;;
            *)        active_colored="${YELLOW}${active_status}${NC}" ;;
        esac

        local enabled_colored="$enabled_status"
        case "$enabled_status" in
            enabled)  enabled_colored="${GREEN}${enabled_status}${NC}" ;;
            disabled) enabled_colored="${RED}${enabled_status}${NC}" ;;
            *)        enabled_colored="${YELLOW}${enabled_status}${NC}" ;;
        esac

        print_cell "[$idx]" "[$idx]" "$W_IDX"
        print_cell "$name" "$name" "$W_NAME"
        print_cell "$role" "$role" "$W_TYPE"
        print_cell "$active_status" "$active_colored" "$W_STATUS"
        print_cell "$enabled_status" "$enabled_colored" "$W_ENABLED"
        echo
        ((idx++))
    done
    echo "----------------------------------------------------------------------------------"

    read -rp "请输入要操作的配置 [序号或名称, 0 返回]: " user_input
    [[ "$user_input" == "0" || -z "$user_input" ]] && return

    local op_name=""
    if [[ "$user_input" =~ ^[0-9]+$ ]] && (( user_input >= 1 && user_input <= ${#config_list[@]} )); then
        op_name="${config_list[$((user_input - 1))]}"
    else
        op_name="$user_input"
    fi

    local selected_file="${CONFIG_DIR}/${op_name}.toml"
    if [[ ! -f "$selected_file" ]]; then
        echo -e "${RED}未找到配置: ${op_name}${NC}"
        return
    fi

    local detected_role=""
    if grep -q "bindPort" "$selected_file"; then
        detected_role="Server"
    elif grep -q "serverAddr" "$selected_file"; then
        detected_role="Client"
    else
        echo -e "${YELLOW}未能识别配置角色，请手动指定:${NC}"
        echo "1. 作为 Server (frps) 管理"
        echo "2. 作为 Client (frpc) 管理"
        read -rp "输入选项 [1-2]: " fallback_choice
        [[ "$fallback_choice" == "1" ]] && detected_role="Server" || detected_role="Client"
    fi

    local target_unit=""
    if [[ "$detected_role" == "Server" ]]; then
        target_unit="frps@${op_name}"
    else
        target_unit="frpc@${op_name}"
    fi

    local is_enabled_now
    is_enabled_now=$($SYSTEMCTL_CMD is-enabled "$target_unit" 2>/dev/null | head -n 1 | tr -d ' \r\n' || true)

    local toggle_autostart_desc=""
    if [[ "$is_enabled_now" == "enabled" ]]; then
        toggle_autostart_desc="关闭开机自启 (当前: 已开启)"
    else
        toggle_autostart_desc="开启开机自启 (当前: 已关闭)"
    fi

    echo -e "\n${CYAN}>>> 已选中 [${op_name}] (角色: ${detected_role}) <<<${NC}"
    echo "1. 启动 ${detected_role} 服务"
    echo "2. 停止 ${detected_role} 服务"
    echo "3. 重启 ${detected_role} 服务"
    echo "4. ${toggle_autostart_desc}"
    echo "5. 实时查看运行日志"
    echo "0. 返回上级菜单"
    read -rp "请输入操作序号 [0-5]: " role_act

    case "$role_act" in
        1)
            $SYSTEMCTL_CMD start "$target_unit"
            echo -e "${GREEN}✓ 已启动 ${target_unit}${NC}"
            ;;
        2)
            $SYSTEMCTL_CMD stop "$target_unit"
            echo -e "${YELLOW}✓ 已停止 ${target_unit}${NC}"
            ;;
        3)
            $SYSTEMCTL_CMD restart "$target_unit"
            echo -e "${GREEN}✓ 已重启 ${target_unit}${NC}"
            ;;
        4)
            if [[ "$is_enabled_now" == "enabled" ]]; then
                $SYSTEMCTL_CMD disable "$target_unit"
                echo -e "${YELLOW}✓ 已成功关闭 ${target_unit} 的开机自启${NC}"
            else
                $SYSTEMCTL_CMD enable "$target_unit"
                echo -e "${GREEN}✓ 已成功开启 ${target_unit} 的开机自启${NC}"
            fi
            ;;
        5)
            echo -e "${BLUE}正在追踪 ${target_unit} 日志 (按 Ctrl+C 退出)...${NC}"
            $JOURNALCTL_CMD -u "$target_unit" -f -n 50
            ;;
        0) return ;;
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

        echo -e "\n${GREEN}================ FRP 多实例管理面板 ${mode_desc} ================${NC}"
        echo "1. 检查最新版本并安装/更新 FRP (frps & frpc)"
        echo "2. 添加新的主配置文件 (支持服务端 / 客户端)"
        echo "3. 向现有客户端追加映射规则 (TCP/UDP/HTTP/HTTPS)"
        echo "4. 删除配置文件并清理服务"
        echo "5. 服务启停控制与状态看板 (支持运行/自启管理)"
        echo "6. Acme.sh 证书申请与管理 (支持自动部署到 FRP)"
        echo "0. 退出管理脚本"
        echo "========================================================================="
        read -rp "请输入序号 [0-6]: " choice

        case "$choice" in
            1) install_or_update ;;
            2) add_config ;;
            3) append_service_config ;;
            4) delete_config ;;
            5) manage_services ;;
            6) acme_manager ;;
            0) exit 0 ;;
            *) echo -e "${RED}输入无效，请重新输入。${NC}" ;;
        esac
    done
}

init_systemd_templates
menu