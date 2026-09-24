#!/usr/bin/env bash
set -euo pipefail

# ======================= 环境模式与路径自动判定 =======================
DOWNLOAD_PROXY="https://gitpy.223327.xyz/"
GITHUB_REPO="rathole-org/rathole"

# 终端色彩定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
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
# 客户端 / 服务端配置分目录存放，避免同目录下互相混淆
CLIENT_CONFIG_DIR="${CONFIG_DIR}/client"
SERVER_CONFIG_DIR="${CONFIG_DIR}/server"
CLIENT_SERVICE_FILE="${SYSTEMD_DIR}/rathole-client@.service"
SERVER_SERVICE_FILE="${SYSTEMD_DIR}/rathole-server@.service"

# ======================= 交互状态文本辅助函数 =======================
# 执行身份说明文本 (Root 系统级 / 普通用户 用户级)
rathole_mode_text() {
    if [[ "$IS_ROOT" == true ]]; then
        printf 'Root (系统级服务)'
    else
        printf '普通用户 %s (用户级服务)' "${USER:-$(id -un 2>/dev/null || printf 'user')}"
    fi
}

# 是否已安装 (以可执行文件为准)
rathole_installed() {
    [[ -x "$BIN_PATH" ]]
}

# 版本号文本 (仅保留版本号, 未安装或解析失败时输出 未安装)
rathole_version_text() {
    local out=""
    if rathole_installed; then
        out=$("$BIN_PATH" --version 2>/dev/null | head -n1) || out=""
    fi
    out="${out//$'\r'/}"
    out=$(printf '%s' "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*' | head -n1 || true)
    if [[ -n "$out" ]]; then
        printf '%s' "$out"
    else
        printf '未安装'
    fi
}

# 配置文件数量 (client + server 子目录)
rathole_config_count() {
    local count=0 f=""
    for f in "$CLIENT_CONFIG_DIR"/*.toml "$SERVER_CONFIG_DIR"/*.toml; do
        [[ -e "$f" ]] || continue
        count=$(( count + 1 ))
    done
    printf '%s' "$count"
}

# 指定角色子目录下的配置数量
rathole_config_count_role() {
    local dir="$1" count=0 f=""
    for f in "$dir"/*.toml; do
        [[ -e "$f" ]] || continue
        count=$(( count + 1 ))
    done
    printf '%s' "$count"
}

# 汇总所有实例名 (配置文件为准, systemd 单元兜底, 去重排序)
rathole_instance_names() {
    local -a names=()
    local f="" name="" unit=""

    for f in "$CLIENT_CONFIG_DIR"/*.toml "$SERVER_CONFIG_DIR"/*.toml; do
        [[ -e "$f" ]] || continue
        name=$(basename "$f" .toml)
        [[ -n "$name" ]] || continue
        names+=("$name")
    done

    while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        name="${unit%.service}"
        name="${name#rathole-client@}"
        name="${name#rathole-server@}"
        [[ -n "$name" ]] || continue
        names+=("$name")
    done < <($SYSTEMCTL_CMD list-units --type=service --all --no-legend 2>/dev/null \
        | awk '/rathole-client@|rathole-server@/{for (i = 1; i <= NF; i++) if ($i ~ /^rathole-(client|server)@/) { print $i; break }}' || true)

    if [[ ${#names[@]} -eq 0 ]]; then
        return 0
    fi
    printf '%s\n' "${names[@]}" | sort -u
}

# 统计实例状态: 输出 "运行中数 实例总数 已自启数"
# 同一实例名对应 client/server 两个单元, 任一运行即视为该实例运行中
rathole_instance_stats() {
    local -a names=()
    local name="" unit="" running=0 total=0 enabled=0 is_run=false is_en=false

    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        names+=("$name")
    done < <(rathole_instance_names)

    total=${#names[@]}
    if (( total > 0 )); then
        for name in "${names[@]}"; do
            is_run=false
            is_en=false
            for unit in "rathole-client@${name}" "rathole-server@${name}"; do
                if $SYSTEMCTL_CMD is-active --quiet "$unit" 2>/dev/null; then
                    is_run=true
                fi
                if $SYSTEMCTL_CMD is-enabled --quiet "$unit" 2>/dev/null; then
                    is_en=true
                fi
            done
            if [[ "$is_run" == true ]]; then
                running=$((running + 1))
            fi
            if [[ "$is_en" == true ]]; then
                enabled=$((enabled + 1))
            fi
        done
    fi

    printf '%s %s %s\n' "$running" "$total" "$enabled"
}

# 实例运行状态文本
rathole_service_state_text() {
    if ! rathole_installed; then
        printf '%b' "${YELLOW}未安装${NC}"
        return 0
    fi

    local stats="" running=0 total=0
    stats=$(rathole_instance_stats)
    running="${stats%% *}"
    total="${stats#* }"
    total="${total%% *}"
    running="${running:-0}"
    total="${total:-0}"

    if (( total == 0 )); then
        printf '%b' "${YELLOW}未配置${NC} (共 ${total} 个实例)"
    elif (( running == total )); then
        printf '%b' "${GREEN}运行中 ${running}/${total}${NC}"
    elif (( running == 0 )); then
        printf '%b' "${RED}已停止 0/${total}${NC}"
    else
        printf '%b' "${YELLOW}部分运行 ${running}/${total}${NC}"
    fi
}

# 实例开机自启状态文本
rathole_boot_state_text() {
    if ! rathole_installed; then
        printf '%b' "${YELLOW}未安装${NC}"
        return 0
    fi

    local stats="" enabled=0 total=0
    stats=$(rathole_instance_stats)
    enabled="${stats##* }"
    total="${stats#* }"
    total="${total%% *}"
    enabled="${enabled:-0}"
    total="${total:-0}"

    if (( total == 0 )); then
        printf '%b' "${RED}已停用 0/0${NC}"
    elif (( enabled == total )); then
        printf '%b' "${GREEN}已启用 ${enabled}/${total}${NC}"
    elif (( enabled == 0 )); then
        printf '%b' "${RED}已停用 0/${total}${NC}"
    else
        printf '%b' "${YELLOW}部分启用 ${enabled}/${total}${NC}"
    fi
}

# ======================= 交互校验工具函数 =======================
pause_menu() {
    local __dummy=""
    read -rp "按回车键返回菜单..." __dummy || exit 0
}

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

# 智能处理 local_addr：如果只输入纯数字端口，自动补全为 127.0.0.1:端口
prompt_local_addr() {
    local prompt_msg="$1"
    local var_name="$2"
    local val=""
    while true; do
        read -rp "$prompt_msg" val
        val=$(echo "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [[ -z "$val" ]]; then
            echo -e "${RED}该项为必填项，内容不能为空，请重新输入！${NC}"
            continue
        fi

        if [[ "$val" =~ ^[0-9]+$ ]]; then
            val="127.0.0.1:${val}"
            echo -e "${YELLOW}检测到仅输入端口，已自动补全本地地址: ${val}${NC}"
        fi

        printf -v "$var_name" '%s' "$val"
        break
    done
}

# 解析 acme.sh 中的 ReloadCmd（自动处理 Base64 编码格式）
parse_reload_cmd() {
    local raw_cmd="$1"
    if [[ "$raw_cmd" =~ __ACME_BASE64__START_(.+)__ACME_BASE64__END_ ]]; then
        echo "${BASH_REMATCH[1]}" | base64 -d 2>/dev/null || echo "$raw_cmd"
    else
        echo "$raw_cmd"
    fi
}

# ======================= 终端精准居中对齐工具 =======================
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
    for cmd in curl jq unzip systemctl openssl socat base64; do
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
mkdir -p "$CLIENT_CONFIG_DIR"
mkdir -p "$SERVER_CONFIG_DIR"
mkdir -p "$CERTS_DIR"
mkdir -p "$SYSTEMD_DIR"
check_dependencies

# ======================= 强制重写并同步 Systemd 模板 =======================
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
ExecStart=/usr/local/bin/rathole -c /etc/rathole/client/%i.toml

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
ExecStart=/usr/local/bin/rathole -s /etc/rathole/server/%i.toml

[Install]
WantedBy=multi-user.target
EOF

        # 兼容性软链接：若系统历史残留 /usr/bin/rathole 路径，避免报错
        if [[ -f "/usr/local/bin/rathole" && ! -f "/usr/bin/rathole" ]]; then
            ln -sf /usr/local/bin/rathole /usr/bin/rathole 2>/dev/null || true
        fi
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
ExecStart=%h/.local/bin/rathole -c %h/.local/etc/rathole/client/%i.toml

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
ExecStart=%h/.local/bin/rathole -s %h/.local/etc/rathole/server/%i.toml

[Install]
WantedBy=default.target
EOF

        if command -v loginctl &>/dev/null; then
            loginctl enable-linger "$USER" 2>/dev/null || true
        fi
    fi

    $SYSTEMCTL_CMD daemon-reload
}

# ======================= 旧版扁平配置自动迁移 =======================
# 历史版本把 client / server 的 .toml 直接放在 $CONFIG_DIR 下，这里按角色归档到 client/ 与 server/
RATHOLE_MIGRATED_COUNT=0
migrate_flat_rathole_configs() {
    local f="" name="" dest="" role_hint=""
    for f in "$CONFIG_DIR"/*.toml; do
        [[ -e "$f" ]] || continue
        name=$(basename "$f")
        if grep -q "^\[client\]" "$f" 2>/dev/null; then
            dest="${CLIENT_CONFIG_DIR}/${name}"
        elif grep -q "^\[server\]" "$f" 2>/dev/null; then
            dest="${SERVER_CONFIG_DIR}/${name}"
        else
            dest="${CLIENT_CONFIG_DIR}/${name}"
            role_hint=" (角色无法识别，暂归入 client/)"
        fi
        if [[ -e "$dest" ]]; then
            dest="${dest%.toml}.from-flat.toml"
        fi
        if ! mv -f "$f" "$dest" 2>/dev/null; then
            echo -e "${RED}!! 归档失败，保留原位置: ${f}${NC}"
            continue
        fi
        echo -e "${GREEN}✓ 已归档配置: ${name} -> ${dest}${NC}${role_hint}"
        RATHOLE_MIGRATED_COUNT=$(( RATHOLE_MIGRATED_COUNT + 1 ))
        role_hint=""
    done
    if [[ "$RATHOLE_MIGRATED_COUNT" -gt 0 ]]; then
        echo -e "${CYAN}>> 已将 ${RATHOLE_MIGRATED_COUNT} 个旧版配置按角色归档到 client/ 与 server/ 子目录。${NC}"
    fi
}

# 迁移后重启仍在运行的实例，使其加载新的 -c / -s 配置路径
restart_instances_after_migration() {
    [[ "$RATHOLE_MIGRATED_COUNT" -gt 0 ]] || return 0
    local name="" unit="" state="" restarted=0
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        for unit in "rathole-client@${name}" "rathole-server@${name}"; do
            state=$($SYSTEMCTL_CMD is-active "$unit" 2>/dev/null | head -n 1 | tr -d ' \r\n' || true)
            if [[ "$state" == "active" ]]; then
                $SYSTEMCTL_CMD restart "$unit" 2>/dev/null || true
                echo -e "${GREEN}✓ 已重启实例以加载新配置路径: ${unit}${NC}"
                restarted=$(( restarted + 1 ))
            fi
        done
    done < <(rathole_instance_names)
    if [[ "$restarted" -gt 0 ]]; then
        echo -e "${CYAN}>> 共重启 ${restarted} 个实例。${NC}"
    fi
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
        echo -e "\n${CYAN}================ Acme.sh 证书与 Hook 管理面板 ================${NC}"
        echo "1. 安装 / 重新安装 Acme.sh 并配置 Let's Encrypt CA"
        echo "2. 申请证书 (80 端口 Standalone 独立验证模式)"
        echo "3. 申请证书 (自定义端口 Standalone 验证，如 88)"
        echo "4. 转换 PKCS#12 (.p12) 并挂载续期重启钩子 (Hook)"
        echo "5. 查看已挂载的续期钩子 (Hook 详情)"
        echo "6. 取消 / 清除域名的续期钩子"
        echo "7. 查看已申请的域名证书列表"
        echo "8. 删除 / 撤销已申请的域名证书"
        echo "0. 返回上级菜单"
        echo "=============================================================="
        read -rp "请输入选项 [0-8]: " acme_choice

        case "$acme_choice" in
            1)
                ensure_acme_installed
                "$ACME_BIN" --set-default-ca --server letsencrypt
                echo -e "${GREEN}✓ Acme.sh 已初始化且默认 CA 已切至 Let's Encrypt${NC}"
                ;;
            2)
                ensure_acme_installed
                prompt_required "请输入要申请证书的完整域名 (例如 example.com): " domain_name
                echo -e "${BLUE}开始申请证书 (请确保本地 80 端口空闲)...${NC}"
                "$ACME_BIN" --issue -d "$domain_name" --standalone
                ;;
            3)
                ensure_acme_installed
                prompt_required "请输入要申请证书的完整域名 (例如 example.com): " domain_name
                prompt_required "请输入验证端口 [例如 88]: " http_port
                echo -e "${BLUE}开始申请证书 (监听端口: ${http_port})...${NC}"
                "$ACME_BIN" --issue -d "$domain_name" --standalone --httpport "$http_port"
                ;;
            4)
                ensure_acme_installed
                prompt_required "请输入已申请证书的域名 (例如 example.com): " cert_domain
                read -rp "请输入导出 PKCS#12 的密码 [默认 rathole_pass_123]: " p12_pass
                p12_pass=${p12_pass:-rathole_pass_123}
                read -rp "关联的 Rathole 配置服务名称 (用于更新后重启实例，例如 server): " svc_instance
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
                echo -e "${GREEN}✓ PKCS#12 转换完成并成功挂载续期 Hook！${NC}"
                ;;
            5)
                echo -e "\n${BLUE}--- 当前已挂载的续期 Hook 列表 ---${NC}"
                if [[ ! -d "$ACME_HOME" ]]; then
                    echo -e "${YELLOW}未检测到 Acme.sh 目录。${NC}"
                    continue
                fi

                local found_any=false
                for conf_file in "$ACME_HOME"/*/*.conf; do
                    [[ -f "$conf_file" ]] || continue
                    local d_dir
                    d_dir=$(dirname "$conf_file")
                    local d_name
                    d_name=$(basename "$d_dir")

                    local raw_cmd
                    raw_cmd=$(grep "^Le_ReloadCmd=" "$conf_file" | cut -d'=' -f2- | tr -d "'\"" || true)

                    if [[ -n "$raw_cmd" ]]; then
                        local real_cmd
                        real_cmd=$(parse_reload_cmd "$raw_cmd")
                        found_any=true
                        echo -e "域名目录: ${CYAN}${d_name}${NC}"
                        echo -e "挂载命令: ${YELLOW}${real_cmd}${NC}"
                        echo "--------------------------------------------------------"
                    fi
                done

                if [[ "$found_any" == false ]]; then
                    echo -e "${YELLOW}暂无任何域名挂载续期 Hook。${NC}"
                fi
                ;;
            6)
                echo -e "\n${BLUE}--- 取消/清除域名续期 Hook ---${NC}"
                if [[ ! -d "$ACME_HOME" ]]; then
                    echo -e "${YELLOW}未检测到 Acme.sh 目录。${NC}"
                    continue
                fi

                local hook_domains=()
                local hook_is_ecc=()
                for conf_file in "$ACME_HOME"/*/*.conf; do
                    [[ -f "$conf_file" ]] || continue
                    local d_dir
                    d_dir=$(dirname "$conf_file")
                    local d_name
                    d_name=$(basename "$d_dir")

                    local raw_cmd
                    raw_cmd=$(grep "^Le_ReloadCmd=" "$conf_file" | cut -d'=' -f2- | tr -d "'\"" || true)

                    if [[ -n "$raw_cmd" ]]; then
                        local domain_pure="${d_name%_ecc}"
                        hook_domains+=("$domain_pure")
                        if [[ "$d_name" == *"_ecc"* ]]; then
                            hook_is_ecc+=("true")
                        else
                            hook_is_ecc+=("false")
                        fi
                    fi
                done

                if [[ ${#hook_domains[@]} -eq 0 ]]; then
                    echo -e "${YELLOW}当前未检测到任何已挂载 Hook 的域名。${NC}"
                    continue
                fi

                echo "已挂载 Hook 的域名清单:"
                for i in "${!hook_domains[@]}"; do
                    local idx=$((i + 1))
                    local ecc_tag=""
                    [[ "${hook_is_ecc[$i]}" == "true" ]] && ecc_tag=" (ECC)"
                    echo -e "  [${CYAN}${idx}${NC}] ${hook_domains[$i]}${ecc_tag}"
                done
                echo "----------------------------------------"

                read -rp "请选择要清除 Hook 的域名 [输入序号或域名, 0 取消]: " del_hook_input
                [[ "$del_hook_input" == "0" || -z "$del_hook_input" ]] && continue

                local target_domain=""
                local target_ecc=false

                if [[ "$del_hook_input" =~ ^[0-9]+$ ]] && (( del_hook_input >= 1 && del_hook_input <= ${#hook_domains[@]} )); then
                    local sel_idx=$((del_hook_input - 1))
                    target_domain="${hook_domains[$sel_idx]}"
                    [[ "${hook_is_ecc[$sel_idx]}" == "true" ]] && target_ecc=true
                else
                    target_domain="$del_hook_input"
                    [[ -d "${ACME_HOME}/${target_domain}_ecc" ]] && target_ecc=true
                fi

                local is_ecc_flag=""
                [[ "$target_ecc" == true ]] && is_ecc_flag="--ecc"

                "$ACME_BIN" --install-cert -d "$target_domain" $is_ecc_flag --reloadcmd ""
                echo -e "${GREEN}✓ 已成功清除域名 [${target_domain}] 的续期 Hook！${NC}"
                ;;
            7)
                if [[ -f "$ACME_BIN" ]]; then
                    "$ACME_BIN" --list
                else
                    echo -e "${YELLOW}尚未安装 acme.sh${NC}"
                fi
                ;;
            8)
                echo -e "\n${BLUE}--- 删除 / 撤销已申请的域名证书 ---${NC}"
                if [[ ! -f "$ACME_BIN" ]]; then
                    echo -e "${YELLOW}尚未安装 acme.sh${NC}"
                    continue
                fi

                local cert_domains=()
                local cert_dirs=()
                local cert_is_ecc=()

                for d in "$ACME_HOME"/*; do
                    [[ -d "$d" ]] || continue
                    local bname
                    bname=$(basename "$d")
                    if [[ "$bname" =~ ^(ca|deploy|dnsapi|notify)$ ]]; then
                        continue
                    fi

                    if [[ -f "$d/fullchain.cer" || -f "$d/${bname}.conf" ]]; then
                        local pure_d="${bname%_ecc}"
                        cert_domains+=("$pure_d")
                        cert_dirs+=("$d")
                        if [[ "$bname" == *"_ecc"* ]]; then
                            cert_is_ecc+=("true")
                        else
                            cert_is_ecc+=("false")
                        fi
                    fi
                done

                if [[ ${#cert_domains[@]} -eq 0 ]]; then
                    echo -e "${YELLOW}当前未在 ${ACME_HOME} 下找到任何已申请的域名证书。${NC}"
                    continue
                fi

                echo "已申请的证书清单:"
                for i in "${!cert_domains[@]}"; do
                    local idx=$((i + 1))
                    local ecc_tag=""
                    [[ "${cert_is_ecc[$i]}" == "true" ]] && ecc_tag=" (ECC)"
                    echo -e "  [${CYAN}${idx}${NC}] ${cert_domains[$i]}${ecc_tag}"
                done
                echo "----------------------------------------"

                read -rp "请选择要删除的域名证书 [输入序号或域名, 0 取消]: " rm_cert_input
                [[ "$rm_cert_input" == "0" || -z "$rm_cert_input" ]] && continue

                local target_rm_domain=""
                local target_rm_ecc=false
                local target_rm_dir=""

                if [[ "$rm_cert_input" =~ ^[0-9]+$ ]] && (( rm_cert_input >= 1 && rm_cert_input <= ${#cert_domains[@]} )); then
                    local s_idx=$((rm_cert_input - 1))
                    target_rm_domain="${cert_domains[$s_idx]}"
                    target_rm_dir="${cert_dirs[$s_idx]}"
                    [[ "${cert_is_ecc[$s_idx]}" == "true" ]] && target_rm_ecc=true
                else
                    target_rm_domain="$rm_cert_input"
                    if [[ -d "${ACME_HOME}/${target_rm_domain}_ecc" ]]; then
                        target_rm_dir="${ACME_HOME}/${target_rm_domain}_ecc"
                        target_rm_ecc=true
                    elif [[ -d "${ACME_HOME}/${target_rm_domain}" ]]; then
                        target_rm_dir="${ACME_HOME}/${target_rm_domain}"
                        target_rm_ecc=false
                    else
                        echo -e "${RED}未找到指定域名证书目录！${NC}"
                        continue
                    fi
                fi

                read -rp "确认彻底从 Acme 移除并删除域名 [${target_rm_domain}] 的本地证书？(y/N): " confirm_rm
                if [[ "$confirm_rm" == "y" || "$confirm_rm" == "Y" ]]; then
                    local rm_ecc_flag=""
                    [[ "$target_rm_ecc" == true ]] && rm_ecc_flag="--ecc"

                    "$ACME_BIN" --remove -d "$target_rm_domain" $rm_ecc_flag 2>/dev/null || true

                    if [[ -d "$target_rm_dir" ]]; then
                        rm -rf "$target_rm_dir"
                    fi

                    local matched_p12="${CERTS_DIR}/${target_rm_domain}.p12"
                    if [[ -f "$matched_p12" ]]; then
                        rm -f "$matched_p12"
                        echo -e "${YELLOW}已同步清理 Rathole 证书目录下的: ${matched_p12}${NC}"
                    fi

                    echo -e "${GREEN}✓ 域名 [${target_rm_domain}] 的证书及续期任务已成功彻底删除！${NC}"
                else
                    echo -e "${YELLOW}操作已取消。${NC}"
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
    read -rp "请手动指定要安装的版本号 (例如 v0.5.0，直接回车取消): " manual_tag
    if [[ -n "$manual_tag" ]]; then
        LATEST_TAG="$manual_tag"
        return 0
    fi

    return 1
}

# ======================= 下载与安装 =======================
install_or_update() {
    echo -e "${BLUE}===> 正在检查 Rathole 官方最新稳定版...${NC}"
    if ! get_latest_release_tag; then
        echo -e "${RED}获取最新版本失败。${NC}"
        return
    fi

    local current_ver=""
    if [[ -f "$BIN_PATH" ]]; then
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

    local display_latest_tag="$LATEST_TAG"
    [[ "$display_latest_tag" != v* ]] && display_latest_tag="v${display_latest_tag}"
    echo -e "目标安装版本: ${GREEN}${display_latest_tag}${NC}"

    if [[ -n "$current_ver" && "$current_ver" == "$display_latest_tag" ]]; then
        read -rp "当前版本已是最新 (${current_ver})，是否覆盖重装？(y/N): " force_reinstall
        if [[ "$force_reinstall" != "y" && "$force_reinstall" != "Y" ]]; then
            return
        fi
    fi

    mkdir -p "$(dirname "$BIN_PATH")"

    local raw_download_url="https://github.com/${GITHUB_REPO}/releases/download/${LATEST_TAG}/rathole-x86_64-unknown-linux-gnu.zip"
    local proxy_download_url="${DOWNLOAD_PROXY}${raw_download_url}"

    echo -e "${BLUE}通过下载代理拉取: ${proxy_download_url}${NC}"

    local tmp_dir
    tmp_dir=$(mktemp -d)

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

# ======================= 添加主配置文件 =======================
add_config() {
    echo -e "\n${BLUE}--- 添加 Rathole 主配置文件 ---${NC}"
    
    echo "请选择配置角色类型:"
    echo "1. 服务端 (Server)"
    echo "2. 客户端 (Client)"
    local role_choice=""
    while [[ "$role_choice" != "1" && "$role_choice" != "2" ]]; do
        read -rp "输入选项 [1-2]: " role_choice
    done

    local role_str="Server"
    [[ "$role_choice" == "2" ]] && role_str="Client"
    echo -e "已选择角色: ${CYAN}${role_str}${NC}"

    prompt_required "请输入该 [${role_str}] 配置文件名称 (无需后缀，例如 app1): " conf_name
    local role_dir="$SERVER_CONFIG_DIR"
    local other_dir="$CLIENT_CONFIG_DIR"
    [[ "$role_choice" == "2" ]] && { role_dir="$CLIENT_CONFIG_DIR"; other_dir="$SERVER_CONFIG_DIR"; }
    local target_file="${role_dir}/${conf_name}.toml"
    if [[ -f "$target_file" ]]; then
        echo -e "${RED}错误: ${role_str} 配置文件 ${conf_name}.toml 已存在！${NC}"
        return
    fi
    if [[ -f "${other_dir}/${conf_name}.toml" ]]; then
        echo -e "${YELLOW}提示: 同名配置已存在于另一角色目录（${other_dir}），本次将写入 ${role_dir}/ 互不影响。${NC}"
    fi

    echo -e "\n选择底层通道传输加密模式 (Transport Layer):"
    echo "1. Plain (常规明文直连通道)"
    echo "2. Noise (Noise Protocol 加密，轻量安全免配置证书)"
    echo "3. TLS / mTLS (基于 TLS 证书的高强度加密)"
    read -rp "输入传输层选项 [1-3, 默认 1]: " transport_choice
    transport_choice=${transport_choice:-1}

    echo -e "\n选择首个转发服务的协议类型:"
    echo "说明: 即使底层使用 TLS 隧道，Rathole 仍可在隧道内部多路复用转发 UDP 流量"
    echo "1. TCP"
    echo "2. UDP"
    read -rp "输入协议类型 [1-2, 默认 1]: " proto_choice
    local svc_type="tcp"
    [[ "$proto_choice" == "2" ]] && svc_type="udp"

    case "$role_choice" in
        1)
            read -rp "服务端监听端口 (接收客户端连接) [默认 2333]: " bind_port
            bind_port=${bind_port:-2333}
            prompt_required "首个转发服务名称 (例如 web_app): " svc_name
            prompt_required "对外暴露公网监听端口 (bind_addr 端口, 例如 8080): " svc_bind_port
            prompt_required "服务共享鉴权密钥 (token): " svc_token

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
                echo -e "\n${CYAN}--- 服务端 TLS 证书载入方式 ---${NC}"
                echo "1. 使用 PKCS#12 格式证书 (.p12 格式)"
                echo "2. 使用 PEM 格式证书 (.cer / .crt 和 .key 文件)"
                read -rp "请选择证书载入格式 [1-2, 默认 1]: " cert_format
                cert_format=${cert_format:-1}

                if [[ "$cert_format" == "1" ]]; then
                    echo "系统已检测到的 .p12 证书:"
                    local p12_files=("$CERTS_DIR"/*.p12)
                    if [[ -e "${p12_files[0]}" ]]; then
                        for pf in "${p12_files[@]}"; do
                            echo " - $pf"
                        done
                    fi
                    prompt_required "请输入 .p12 证书路径: " p12_path
                    prompt_required "请输入 .p12 证书密码: " p12_pwd
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
                    prompt_required "TLS 证书全链路径 (cert/fullchain.cer): " tls_cert
                    prompt_required "TLS 私钥路径 (key): " tls_key
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
            prompt_required "服务端公网 IP 或域名 (例如 example.com): " server_host
            read -rp "服务端监听端口 [默认 2333]: " server_port
            server_port=${server_port:-2333}
            prompt_required "首个转发服务名称 (须与服务端一致): " svc_name
            prompt_local_addr "本地目标服务地址 (支持输入 3389 或 127.0.0.1:3389): " local_addr
            prompt_required "服务共享鉴权密钥 (token, 须与服务端一致): " svc_token

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
                echo -e "\n${CYAN}--- 客户端 TLS 证书验证与 SNI 设定 ---${NC}"
                echo "1. 默认权威 CA 校验 (推荐: 信任系统 Let's Encrypt / ZeroSSL 证书库，自动匹配连接域名)"
                echo "2. 指定预期域名 (SNI 模式: 当服务端是按域名签发，但连接地址填写的是 IP 时使用)"
                echo "3. 指定私有根证书路径 (Custom CA: 针对自签名根证书文件进行校验)"
                read -rp "请选择客户端 TLS 验证方式 [1-3, 默认 1]: " tls_client_mode
                tls_client_mode=${tls_client_mode:-1}

                case "$tls_client_mode" in
                    2)
                        prompt_required "请输入服务端的预期域名 (SNI，例如 example.com): " custom_sni
                        cat <<EOF >> "$target_file"

[client.transport]
type = "tls"
[client.transport.tls]
trusted_root = "${custom_sni}"
EOF
                        ;;
                    3)
                        prompt_required "请输入根证书文件绝对路径 (例如 /etc/ssl/certs/ca-certificates.crt): " custom_ca_path
                        cat <<EOF >> "$target_file"

[client.transport]
type = "tls"
[client.transport.tls]
trusted_root = "${custom_ca_path}"
EOF
                        ;;
                    *)
                        cat <<EOF >> "$target_file"

[client.transport]
type = "tls"
[client.transport.tls]
EOF
                        ;;
                esac
            fi

            cat <<EOF >> "$target_file"

[client.services.${svc_name}]
type = "${svc_type}"
local_addr = "${local_addr}"
token = "${svc_token}"
EOF
            echo -e "${GREEN}✓ 客户端配置生成成功: ${target_file}${NC}"
            ;;
    esac
}

# ======================= 追加转发端口/服务 =======================
append_service_config() {
    echo -e "\n${BLUE}--- 向现有配置追加转发端口/服务 ---${NC}"
    local roles=() names=() files=()
    local f="" n=""
    for f in "$CLIENT_CONFIG_DIR"/*.toml; do
        [[ -e "$f" ]] || continue
        roles+=("client"); names+=("$(basename "$f" .toml)"); files+=("$f")
    done
    for f in "$SERVER_CONFIG_DIR"/*.toml; do
        [[ -e "$f" ]] || continue
        roles+=("server"); names+=("$(basename "$f" .toml)"); files+=("$f")
    done

    if [[ ${#names[@]} -eq 0 ]]; then
        echo -e "${YELLOW}未检索到任何配置文件，请先添加主配置文件！${NC}"
        return
    fi

    echo "现有配置文件清单 (带角色标注):"
    local idx=0 role_text=""
    for ((idx=0; idx<${#names[@]}; idx++)); do
        if [[ "${roles[$idx]}" == "server" ]]; then role_text="Server"; else role_text="Client"; fi
        echo -e "  [${CYAN}$((idx+1))${NC}] ${names[$idx]}  ${YELLOW}(${role_text})${NC}"
    done
    echo "----------------------------------------"

    read -rp "请选择要追加服务的配置文件 [序号 或 角色/名称(如 server/app1), 0 取消]: " target_input
    [[ "$target_input" == "0" || -z "$target_input" ]] && return

    local conf_idx=-1 want_role="" want_name=""
    if [[ "$target_input" =~ ^[0-9]+$ ]] && (( target_input >= 1 && target_input <= ${#names[@]} )); then
        conf_idx=$((target_input - 1))
    else
        want_name="$target_input"
        if [[ "$target_input" == */* ]]; then
            want_role="${target_input%%/*}"
            want_name="${target_input#*/}"
        fi
        for ((idx=0; idx<${#names[@]}; idx++)); do
            [[ "${names[$idx]}" == "$want_name" ]] || continue
            if [[ -z "$want_role" || "$want_role" == "${roles[$idx]}" ]]; then
                conf_idx=$idx
                break
            fi
        done
    fi

    if (( conf_idx < 0 )); then
        echo -e "${RED}未找到指定配置文件: ${target_input}${NC}"
        return
    fi

    local conf_name="${names[$conf_idx]}"
    local target_file="${files[$conf_idx]}"
    if [[ ! -f "$target_file" ]]; then
        echo -e "${RED}未找到指定配置文件: ${target_file}${NC}"
        return
    fi

    local is_server=false
    local is_client=false
    grep -q "^\[server\]" "$target_file" && is_server=true
    grep -q "^\[client\]" "$target_file" && is_client=true

    if [[ "$is_server" == false && "$is_client" == false ]]; then
        echo -e "${RED}无法解析此配置文件的角色架构（缺少 [server] 或 [client] 标头）。${NC}"
        return
    fi

    echo -e "\n${CYAN}>>> 正在向 [${conf_name}] 追加转发服务 <<<${NC}"
    echo "选择追加服务的协议类型:"
    echo "1. TCP"
    echo "2. UDP"
    read -rp "输入协议类型 [1-2, 默认 1]: " proto_choice
    local svc_type="tcp"
    [[ "$proto_choice" == "2" ]] && svc_type="udp"

    prompt_required "新转发服务名称 (例如 RDP 或 ssh_service): " new_svc_name

    if grep -q "services\.${new_svc_name}\]" "$target_file"; then
        echo -e "${RED}错误: 服务名称 [${new_svc_name}] 在当前配置文件中已存在！${NC}"
        return
    fi

    if [[ "$is_server" == true ]]; then
        prompt_required "对外暴露公网监听端口 (bind_addr 端口, 例如 3389): " svc_bind_port
        prompt_required "服务共享鉴权密钥 (token): " svc_token

        cat <<EOF >> "$target_file"

[server.services.${new_svc_name}]
type = "${svc_type}"
bind_addr = "0.0.0.0:${svc_bind_port}"
token = "${svc_token}"
EOF
        echo -e "${GREEN}✓ 服务端映射 [${new_svc_name}] 已成功追加到 ${target_file}${NC}"
        
        local unit_name="rathole-server@${conf_name}"
        if [[ $($SYSTEMCTL_CMD is-active "$unit_name" 2>/dev/null) == "active" ]]; then
            read -rp "检测到该服务正在运行，是否立即重启使其生效？(Y/n): " restart_now
            if [[ "$restart_now" != "n" && "$restart_now" != "N" ]]; then
                $SYSTEMCTL_CMD restart "$unit_name"
                echo -e "${GREEN}✓ 服务 ${unit_name} 已完成重启。${NC}"
            fi
        fi

    elif [[ "$is_client" == true ]]; then
        prompt_local_addr "本地目标服务地址 (输入纯端口如 3389 自动补全 127.0.0.1:3389): " local_addr
        prompt_required "服务共享鉴权密钥 (token, 须与服务端一致): " svc_token

        cat <<EOF >> "$target_file"

[client.services.${new_svc_name}]
type = "${svc_type}"
local_addr = "${local_addr}"
token = "${svc_token}"
EOF
        echo -e "${GREEN}✓ 客户端映射 [${new_svc_name}] 已成功追加到 ${target_file}${NC}"

        local unit_name="rathole-client@${conf_name}"
        if [[ $($SYSTEMCTL_CMD is-active "$unit_name" 2>/dev/null) == "active" ]]; then
            read -rp "检测到该服务正在运行，是否立即重启使其生效？(Y/n): " restart_now
            if [[ "$restart_now" != "n" && "$restart_now" != "N" ]]; then
                $SYSTEMCTL_CMD restart "$unit_name"
                echo -e "${GREEN}✓ 服务 ${unit_name} 已完成重启。${NC}"
            fi
        fi
    fi
}

# ======================= 删除配置及关联服务 =======================
delete_config() {
    echo -e "\n${BLUE}--- 删除 Rathole 配置文件 ---${NC}"
    local roles=() names=() files=()
    local f="" n=""
    for f in "$CLIENT_CONFIG_DIR"/*.toml; do
        [[ -e "$f" ]] || continue
        roles+=("client"); names+=("$(basename "$f" .toml)"); files+=("$f")
    done
    for f in "$SERVER_CONFIG_DIR"/*.toml; do
        [[ -e "$f" ]] || continue
        roles+=("server"); names+=("$(basename "$f" .toml)"); files+=("$f")
    done

    if [[ ${#names[@]} -eq 0 ]]; then
        echo -e "${YELLOW}未找到任何 .toml 配置文件。${NC}"
        return
    fi

    echo "现有配置文件清单 (带角色标注):"
    local idx=0 role_text=""
    for ((idx=0; idx<${#names[@]}; idx++)); do
        if [[ "${roles[$idx]}" == "server" ]]; then role_text="Server"; else role_text="Client"; fi
        echo -e "  [${CYAN}$((idx+1))${NC}] ${names[$idx]}  ${YELLOW}(${role_text})${NC}"
    done
    echo "----------------------------------------"

    read -rp "请输入要删除的配置 [序号 或 角色/名称(如 server/app1), 0 取消]: " del_input
    [[ "$del_input" == "0" || -z "$del_input" ]] && return

    local del_idx=-1 want_role="" want_name=""
    if [[ "$del_input" =~ ^[0-9]+$ ]] && (( del_input >= 1 && del_input <= ${#names[@]} )); then
        del_idx=$((del_input - 1))
    else
        want_name="$del_input"
        if [[ "$del_input" == */* ]]; then
            want_role="${del_input%%/*}"
            want_name="${del_input#*/}"
        fi
        for ((idx=0; idx<${#names[@]}; idx++)); do
            [[ "${names[$idx]}" == "$want_name" ]] || continue
            if [[ -z "$want_role" || "$want_role" == "${roles[$idx]}" ]]; then
                del_idx=$idx
                break
            fi
        done
    fi

    if (( del_idx < 0 )); then
        echo -e "${RED}未找到指定配置: ${del_input}${NC}"
        return
    fi

    local del_name="${names[$del_idx]}"
    local del_role="${roles[$del_idx]}"
    local target_file="${files[$del_idx]}"
    local unit_name="rathole-client@${del_name}"
    [[ "$del_role" == "server" ]] && unit_name="rathole-server@${del_name}"

    read -rp "确认彻底停止关联服务并删除 ${del_name}.toml (${del_role})？(y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        $SYSTEMCTL_CMD stop "$unit_name" 2>/dev/null || true
        $SYSTEMCTL_CMD disable "$unit_name" 2>/dev/null || true
        rm -f "$target_file"
        echo -e "${GREEN}✓ 配置及服务已成功移除: ${target_file}${NC}"
    else
        echo -e "${YELLOW}操作已取消。${NC}"
    fi
}

# ======================= 状态看板与智能角色自启菜单 =======================
manage_services() {
    local mode_tag="用户模式"
    [[ "$IS_ROOT" == true ]] && mode_tag="Root 全局模式"
    echo -e "\n${BLUE}--- 实例运行状态看板 [${mode_tag}] ---${NC}"

    local roles=() names=() files=()
    local f="" name=""
    for f in "$CLIENT_CONFIG_DIR"/*.toml; do
        [[ -e "$f" ]] || continue
        roles+=("client"); names+=("$(basename "$f" .toml)"); files+=("$f")
    done
    for f in "$SERVER_CONFIG_DIR"/*.toml; do
        [[ -e "$f" ]] || continue
        roles+=("server"); names+=("$(basename "$f" .toml)"); files+=("$f")
    done

    if [[ ${#names[@]} -eq 0 ]]; then
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

    local idx=0
    for ((idx=0; idx<${#names[@]}; idx++)); do
        name="${names[$idx]}"

        local role="" unit=""
        if [[ "${roles[$idx]}" == "server" ]]; then
            role="Server"
            unit="rathole-server@${name}"
        else
            role="Client"
            unit="rathole-client@${name}"
        fi

        local active_status="inactive"
        local enabled_status="disabled"

        active_status=$($SYSTEMCTL_CMD is-active "$unit" 2>/dev/null | head -n 1 | tr -d ' \r\n' || true)
        enabled_status=$($SYSTEMCTL_CMD is-enabled "$unit" 2>/dev/null | head -n 1 | tr -d ' \r\n' || true)

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

        print_cell "[$((idx+1))]" "[$((idx+1))]" "$W_IDX"
        print_cell "$name" "$name" "$W_NAME"
        print_cell "$role" "$role" "$W_TYPE"
        print_cell "$active_status" "$active_colored" "$W_STATUS"
        print_cell "$enabled_status" "$enabled_colored" "$W_ENABLED"
        echo
    done
    echo "----------------------------------------------------------------------------------"

    read -rp "请输入要操作的配置 [序号 或 角色/名称(如 server/app1), 0 返回]: " user_input
    [[ "$user_input" == "0" || -z "$user_input" ]] && return

    local op_idx=-1 want_role="" want_name=""
    if [[ "$user_input" =~ ^[0-9]+$ ]] && (( user_input >= 1 && user_input <= ${#names[@]} )); then
        op_idx=$((user_input - 1))
    else
        want_name="$user_input"
        if [[ "$user_input" == */* ]]; then
            want_role="${user_input%%/*}"
            want_name="${user_input#*/}"
        fi
        for ((idx=0; idx<${#names[@]}; idx++)); do
            [[ "${names[$idx]}" == "$want_name" ]] || continue
            if [[ -z "$want_role" || "$want_role" == "${roles[$idx]}" ]]; then
                op_idx=$idx
                break
            fi
        done
    fi

    if (( op_idx < 0 )); then
        echo -e "${RED}未找到配置: ${user_input}${NC}"
        return
    fi

    local op_name="${names[$op_idx]}"
    local selected_file="${files[$op_idx]}"
    local detected_role="Server"
    local target_unit="rathole-server@${op_name}"
    if [[ "${roles[$op_idx]}" == "client" ]]; then
        detected_role="Client"
        target_unit="rathole-client@${op_name}"
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
        0)
            return
            ;;
        *)
            echo -e "${RED}无效选项${NC}"
            ;;
    esac
}

# ======================= 完整卸载 Rathole =======================
uninstall_rathole() {
    echo ""
    echo "=========================================="
    echo -e "          ${BOLD}卸载 Rathole${NC}"
    echo "=========================================="
    echo "执行身份: $(rathole_mode_text)"

    if ! rathole_installed; then
        echo -e "${YELLOW}[-] 未检测到已安装的 Rathole。${NC}"
        return 0
    fi

    local confirm=""
    read -rp "确定要卸载 Rathole 吗? [y/N]: " confirm || true
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}已取消卸载。${NC}"
        return 0
    fi

    echo "[1/4] 停止并禁用所有实例服务..."
    local -a units=()
    local f="" name="" unit=""
    for f in "$CLIENT_CONFIG_DIR"/*.toml; do
        [[ -e "$f" ]] || continue
        name=$(basename "$f" .toml)
        [[ -n "$name" ]] || continue
        units+=("rathole-client@${name}")
    done
    for f in "$SERVER_CONFIG_DIR"/*.toml; do
        [[ -e "$f" ]] || continue
        name=$(basename "$f" .toml)
        [[ -n "$name" ]] || continue
        units+=("rathole-server@${name}")
    done
    # 兜底补充：配置文件已被删除但 systemd 单元仍残留的情况
    while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        units+=("$unit")
    done < <($SYSTEMCTL_CMD list-units --type=service --all --no-legend 2>/dev/null \
        | awk '/rathole-client@|rathole-server@/{for (i = 1; i <= NF; i++) if ($i ~ /^rathole-(client|server)@/) { print $i; break }}' || true)

    if [[ ${#units[@]} -gt 0 ]]; then
        for unit in "${units[@]}"; do
            $SYSTEMCTL_CMD stop "$unit" 2>/dev/null || true
            $SYSTEMCTL_CMD disable "$unit" 2>/dev/null || true
        done
    fi

    echo "[2/4] 清除 systemd 模板单元与二进制文件..."
    rm -f "$CLIENT_SERVICE_FILE" "$SERVER_SERVICE_FILE"
    $SYSTEMCTL_CMD daemon-reload 2>/dev/null || true
    $SYSTEMCTL_CMD reset-failed 'rathole-client@*' 'rathole-server@*' 2>/dev/null || true
    rm -f "$BIN_PATH"

    echo "[3/4] 处理配置目录 (含 certs 与 PKCS#12 产物)..."
    local del_conf=""
    read -rp "是否删除配置目录 ${CONFIG_DIR} (含 certs 与 PKCS#12 产物)? [y/N]: " del_conf || true
    if [[ "$del_conf" =~ ^[Yy]$ ]]; then
        if [[ -z "$CONFIG_DIR" || "$CONFIG_DIR" == "/" || "$CONFIG_DIR" == "/root" || "$CONFIG_DIR" == "/etc" || "$CONFIG_DIR" == "/usr" || "$CONFIG_DIR" == "/var" || "$CONFIG_DIR" == "/home" || "$CONFIG_DIR" == "$HOME" ]]; then
            echo -e "${RED}警告: 检测到关键系统/家目录，禁止整目录删除！请手动处理其中的文件。${NC}"
        elif [[ ! -d "$CONFIG_DIR" ]]; then
            echo -e "${YELLOW}[-] 配置目录不存在，跳过删除。${NC}"
        else
            rm -rf "$CONFIG_DIR"
            echo -e "${GREEN}[✓] 已删除配置目录: ${CONFIG_DIR}${NC}"
        fi
    else
        echo "[-] 保留配置目录: ${CONFIG_DIR}"
    fi

    echo "[4/4] 清理完成。"
    echo -e "${YELLOW}提示: acme.sh 的续期 Hook 不会随本次卸载自动清理，可稍后使用菜单 6 进行清理。${NC}"

    echo ""
    echo "=========================================="
    echo -e "        ${GREEN}Rathole 已成功卸载完成！${NC}"
    echo "=========================================="
    return 0
}

# ======================= 主菜单 =======================
menu() {
    local choice=""
    while true; do
        echo ""
        echo "=========================================="
        echo -e "   ${BOLD}Rathole 管理脚本${NC}"
        echo "   身份: $(rathole_mode_text)"
        echo "   版本: $(rathole_version_text)"
        echo "=========================================="
        echo -e " 服务状态: $(rathole_service_state_text)    开机自启: $(rathole_boot_state_text)"
        echo " 配置文件数量: $(rathole_config_count) (客户端 $(rathole_config_count_role "$CLIENT_CONFIG_DIR") / 服务端 $(rathole_config_count_role "$SERVER_CONFIG_DIR"))"
        echo " 配置目录: ${CONFIG_DIR} (client / server)    二进制: ${BIN_PATH}"
        echo "------------------------------------------"
        echo " 1. 检查最新版本并安装/更新 Rathole"
        echo " 2. 添加新的主配置文件 (新建通道与基础服务)"
        echo " 3. 向现有配置追加转发端口/服务"
        echo " 4. 删除配置文件并清理服务"
        echo " 5. 服务启停控制与状态看板 (支持运行/自启管理)"
        echo " 6. Acme.sh 证书申请与管理 (支持 PKCS#12 转换与续期挂载)"
        echo " 7. 完整卸载 Rathole (停止并删除所有实例服务/单元/二进制)"
        echo " 0. 退出"
        echo "=========================================="
        read -rp "请输入操作编号 [0-7 默认: 0]: " choice
        choice="${choice:-0}"

        case "$choice" in
            1) install_or_update || true ;;
            2) add_config || true ;;
            3) append_service_config || true ;;
            4) delete_config || true ;;
            5) manage_services || true ;;
            6) acme_manager || true ;;
            7) uninstall_rathole || true ;;
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

# 无论何时运行，强制同步刷新 Systemd 模板，防止残留旧路径问题
migrate_flat_rathole_configs
init_systemd_templates
restart_instances_after_migration

menu