#!/bin/bash

# ====================================================================================================
# Shadowsocks-Rust 服务管理脚本
# 支持系统: Debian 10+ / Ubuntu 18.04+ / Alpine 3.12+ / CentOS 7+ ...
# ====================================================================================================

# 1. 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[31m[ERROR] 此脚本必须以 root 权限运行！请使用 sudo -i 切换到 root 用户后重试。\033[0m"
    exit 1
fi

# 全局路径变量定义
CONF_DIR="/etc/shadowsocks-rust"
CONF_FILE="${CONF_DIR}/config.json"
SYSTEMD_FILE="/etc/systemd/system/shadowsocks-rust.service"
OPENRC_FILE="/etc/init.d/shadowsocks-rust"
BIN_PATH="/usr/local/bin/ssserver"
TMP_DIR=""

# 各 minor 分支终态修正版（Patch Release）+ 最新分支的预设兜底列表
# 兜底列表必须从上游当前最新 Tag 开始，否则 API 受限时会跳过新版直接降级
FALLBACK_LIST="v1.25.0 v1.24.0 v1.23.5 v1.23.4 v1.22.0 v1.21.2 v1.20.4 v1.19.4 v1.18.4"

# 个人偏好的加密方式：版本轮询时按「完整方法名精确比对」判定，不做子串包含匹配
# 否则 2022-blake3-aes-128-gcm 也会被当成 aes-128-gcm
PREFERRED_METHOD="aes-128-gcm"

# 全局中断与清理机制：Ctrl+C / TERM 触发时静默清理临时文件后立即退出（不打印任何提示）
# 注意：临时目录里可能堆积着多个已下载的软件包，必须无条件清理，不能因为静默而省略
cleanup_on_exit() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
    TMP_DIR=""
}

cleanup_on_interrupt() {
    cleanup_on_exit
    trap - INT TERM EXIT
    echo ""    # 仅换行，不打印任何提示文字，避免 shell 提示符黏在 ^C 后面
    exit 130
}

# 绑定全局 Trap 信号
trap cleanup_on_interrupt INT TERM
trap cleanup_on_exit EXIT

# 判断当前 PID 1 是否为 systemd：仅凭 systemctl 存在会被容器/自编译环境误导
has_systemd() {
    [[ -d /run/systemd/system ]]
}

# 自动检测并放行系统本地防火墙端口
open_port() {
    local port=$1
    echo "[STEP] 正在检查并自动放行系统本地防火墙端口 $port ..."

    # 1. 检测并放行 UFW (Ubuntu / Debian)
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$port"/tcp >/dev/null 2>&1
        ufw allow "$port"/udp >/dev/null 2>&1
        echo -e "\033[32m[SUCCESS] 已通过 UFW 自动放行端口 $port (TCP/UDP)\033[0m"
    fi

    # 2. 检测并放行 Firewalld (CentOS / RHEL / Fedora)
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
        firewall-cmd --zone=public --add-port="$port"/tcp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port="$port"/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        echo -e "\033[32m[SUCCESS] 已通过 Firewalld 自动放行端口 $port (TCP/UDP)\033[0m"
    fi

    # 3. 通用 iptables / ip6tables 规则写入 (兜底处理)
    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
        iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null
        if command -v ip6tables >/dev/null 2>&1; then
            ip6tables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
            ip6tables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null
        fi
    fi
}

# 卸载时回收 open_port 写入的端口规则（删除不存在的规则只会报错，无需额外判断）
close_port() {
    local port=$1
    echo "[STEP] 正在回收防火墙端口 $port 的放行规则 ..."

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw delete allow "$port"/tcp >/dev/null 2>&1
        ufw delete allow "$port"/udp >/dev/null 2>&1
        echo -e "\033[32m[SUCCESS] 已移除 UFW 中端口 $port 的放行规则\033[0m"
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
        firewall-cmd --zone=public --remove-port="$port"/tcp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --remove-port="$port"/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        echo -e "\033[32m[SUCCESS] 已移除 Firewalld 中端口 $port 的放行规则\033[0m"
    fi

    if command -v iptables >/dev/null 2>&1; then
        # -D 每次只删一条同规则，循环删净（上限 5 次，避免死循环）
        local i
        for i in 1 2 3 4 5; do
            iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || break
        done
        for i in 1 2 3 4 5; do
            iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || break
        done
        if command -v ip6tables >/dev/null 2>&1; then
            for i in 1 2 3 4 5; do
                ip6tables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || break
            done
            for i in 1 2 3 4 5; do
                ip6tables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || break
            done
        fi
    fi
}

# 自动适配包管理器安装依赖
install_dependencies() {
    echo "[STEP] 正在检查并安装所需依赖包..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl tar xz-utils jq >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk update >/dev/null 2>&1
        apk add --no-cache curl tar xz jq bash coreutils >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl tar xz jq >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y epel-release >/dev/null 2>&1
        yum install -y curl tar xz jq >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm curl tar xz jq >/dev/null 2>&1
    else
        echo -e "\033[33m[WARN] 未找到常见的包管理器，请确保已手动安装 curl, tar, xz, jq\033[0m"
    fi
}

# 判断服务是否在运行
is_service_running() {
    if has_systemd && systemctl is-active --quiet shadowsocks-rust 2>/dev/null; then
        return 0
    elif command -v rc-service >/dev/null 2>&1 && rc-service shadowsocks-rust status 2>/dev/null | grep -q "started"; then
        return 0
    elif pgrep -f "$BIN_PATH" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

start_service_cmd() {
    if has_systemd; then
        systemctl start shadowsocks-rust
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service shadowsocks-rust start
    elif [[ -x "$OPENRC_FILE" ]]; then
        "$OPENRC_FILE" start
    fi
}

stop_service_cmd() {
    if has_systemd; then
        systemctl stop shadowsocks-rust
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service shadowsocks-rust stop
    elif [[ -x "$OPENRC_FILE" ]]; then
        "$OPENRC_FILE" stop
    fi
}

get_installed_version() {
    if [[ -f "$BIN_PATH" ]]; then
        local ver
        ver=$($BIN_PATH --version 2>/dev/null | awk '{print $2}')
        [[ -n "$ver" && "$ver" != v* ]] && ver="v${ver}"
        echo "${ver:-未知}"
    else
        echo ""
    fi
}

is_newer_version() {
    local new_ver="${1#v}"
    local cur_ver="${2#v}"
    [[ "$new_ver" == "$cur_ver" ]] && return 1
    local highest
    highest=$(printf "%s\n%s" "$new_ver" "$cur_ver" | sort -V | tail -n1)
    [[ "$highest" == "$new_ver" ]] && return 0 || return 1
}

# AEAD-2022 (SIP022) 的 password 必须是 base64 编码、且解码后长度等于该方法的 key 长度，
# 普通 ASCII 口令会让 ssserver 启动即失败，因此单独识别与生成
method_key_len() {
    case "$1" in
        2022-blake3-aes-128-gcm) echo 16 ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) echo 32 ;;
        *) echo 0 ;;
    esac
}

# 生成指定字节数的 base64 随机密钥（不依赖 openssl，BusyBox 环境同样可用）
rand_psk() {
    head -c "$1" /dev/urandom | base64 | tr -d '\n'
}

# 校验口令是否已是合法 base64 且解码长度符合要求
is_valid_psk() {
    local got
    got=$(printf '%s' "$1" | base64 -d 2>/dev/null | wc -c | tr -d '[:space:]')
    [[ -n "$got" && "$got" -eq "$2" ]]
}

# JSON 字符串转义（无 jq 时的兜底，避免密码含引号/反斜杠写出非法配置）
json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

get_supported_methods() {
    local target_bin="${1:-$BIN_PATH}"
    local raw_methods
    raw_methods=$($target_bin --help 2>&1 | tr '\n' ' ' | grep -oiE "possible values: [^]]+" | sed 's/[Pp]ossible values: //; s/,/ /g')
    
    if [[ -z "$raw_methods" ]]; then
        raw_methods="aes-128-gcm aes-256-gcm chacha20-ietf-poly1305 2022-blake3-aes-128-gcm 2022-blake3-aes-256-gcm 2022-blake3-chacha20-poly1305 aes-192-gcm sm4-gcm"
    fi

    local method_list=()
    method_list+=("$PREFERRED_METHOD")

    for m in $raw_methods; do
        m=$(echo "$m" | xargs)
        [[ -z "$m" || "$m" == "none" || "$m" == "plain" || "$m" == "$PREFERRED_METHOD" ]] && continue
        method_list+=("$m")
    done

    echo "${method_list[@]}"
}

# 精确判断指定二进制是否支持某个加密方式：必须与方法表里的完整名字完全相等
# 不能用 grep 子串匹配 —— "2022-blake3-aes-128-gcm" 里同样含有 "aes-128-gcm"
supports_method() {
    local target_bin="$1"
    local want="$2"
    local raw_methods m

    raw_methods=$("$target_bin" --help 2>&1 | tr '\n' ' ' | grep -oiE "possible values: [^]]+" | sed 's/[Pp]ossible values: //; s/,/ /g')

    if [[ -z "$raw_methods" ]]; then
        # 方法表解析不出来（上游 help 文案变动）时退回词边界匹配：
        # 前后必须是分隔符，避免把 xxx-aes-128-gcm 之类误判为 aes-128-gcm
        "$target_bin" --help 2>&1 | tr '\n' ' ' \
            | grep -qE "(^|[^[:alnum:]_-])${want//./\\.}([^[:alnum:]_-]|$)"
        return
    fi

    for m in $raw_methods; do
        m=$(echo "$m" | xargs)
        [[ "$m" == "$want" ]] && return 0
    done

    return 1
}

print_status_line() {
    if [[ ! -f "$BIN_PATH" ]]; then
        local status_text="\033[31m未安装\033[0m"
        printf "║  服务状态: %b%43s ║\n" "$status_text" ""
        return
    fi

    local ver_str
    ver_str=$(get_installed_version)

    local status_text=""
    if is_service_running; then
        status_text="\033[32m● 运行中\033[0m"
    else
        status_text="\033[31m● 已停止\033[0m"
    fi

    local pad_len=$((21 - ${#ver_str}))
    (( pad_len < 0 )) && pad_len=0

    printf "║  服务状态: %b (Shadowsocks-rust-%s)%*s ║\n" "$status_text" "$ver_str" "$pad_len" ""
}

# 检索版本列表（优先 API 并带 User-Agent，防封限流下自动走 302 重定向网页提取最新 Tag）
fetch_version_list() {
    local api_releases
    api_releases=$(curl -s --max-time 10 \
        -H "User-Agent: Shadowsocks-Rust-Updater/1.0" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases?per_page=30" \
        | jq -r '.[] | select(.prerelease == false) | .tag_name' 2>/dev/null | grep -E '^v[0-9]+' | grep -v 'null')

    if [[ -n "$api_releases" ]]; then
        echo "API_SUCCESS"
        echo "$api_releases"
        return
    fi

    # API 请求受限时，通过常规网页 302 重定向提取最新 Tag
    local latest_tag
    latest_tag=$(curl -sIL -o /dev/null -w "%{url_effective}" --max-time 10 \
        -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)" \
        "https://github.com/shadowsocks/shadowsocks-rust/releases/latest" 2>/dev/null | sed 's|.*/tag/||')

    if [[ -n "$latest_tag" && "$latest_tag" =~ ^v[0-9]+ ]]; then
        echo "REDIRECT_SUCCESS"
        echo "$latest_tag $FALLBACK_LIST" | tr ' ' '\n' | awk '!seen[$0]++'
    else
        echo "API_FAILED"
        echo "$FALLBACK_LIST" | tr ' ' '\n'
    fi
}

# 核心下载核验函数（带 -fL 容错：sha256 校验 + 解压即删压缩包 / 校验不符合即删二进制）
download_and_verify() {
    local target_ver="$1"
    local ss_arch="$2"
    local tmp_dir="$3"

    local fname="shadowsocks-${target_ver}.${ss_arch}.tar.xz"
    local pkg_file="${tmp_dir}/${fname}"
    local bin_file="${tmp_dir}/ssserver"

    rm -f "$pkg_file" "${pkg_file}.sha256" "$bin_file"

    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${target_ver}/${fname}"
    
    curl -fL -s --connect-timeout 10 --max-time 60 \
        -H "User-Agent: Shadowsocks-Rust-Updater/1.0" \
        -o "$pkg_file" "$url"

    if [[ $? -ne 0 || ! -s "$pkg_file" ]]; then
        echo " │  └─ [SKIP] 下载失败或此版本缺少该架构包，删除缓存并跳过..."
        rm -f "$pkg_file"
        return 1
    fi

    # 官方 release 每个 asset 都附带 .sha256 旁文件，校验通过后才允许解包
    if command -v sha256sum >/dev/null 2>&1; then
        if curl -fsL -s --max-time 20 -o "${pkg_file}.sha256" "${url}.sha256" && [[ -s "${pkg_file}.sha256" ]]; then
            if ! ( cd "$tmp_dir" && sha256sum -c "${fname}.sha256" >/dev/null 2>&1 ); then
                echo -e " │  └─ \033[31m[FAIL] sha256 校验不通过，丢弃该包并跳过...\033[0m"
                rm -f "$pkg_file" "${pkg_file}.sha256"
                return 1
            fi
        else
            echo -e " │  └─ \033[33m[WARN] 未取到 sha256 校验文件，跳过完整性校验\033[0m"
        fi
    else
        echo -e " │  └─ \033[33m[WARN] 系统缺少 sha256sum，跳过完整性校验\033[0m"
    fi
    rm -f "${pkg_file}.sha256"

    tar -xf "$pkg_file" -C "$tmp_dir" ssserver 2>/dev/null
    rm -f "$pkg_file"

    if [[ -f "$bin_file" ]]; then
        chmod +x "$bin_file"
        if supports_method "$bin_file" "$PREFERRED_METHOD"; then
            return 0
        else
            echo -e " │  └─ \033[33m[UNSUPPORTED] 版本 $target_ver 的方法表中没有 $PREFERRED_METHOD，清理文件并测试下一版本...\033[0m"
            rm -f "$bin_file"
            return 1
        fi
    else
        echo " │  └─ [SKIP] 解压失败，跳过..."
        return 1
    fi
}

# 1. 安装 Shadowsocks-Rust
install_ss() {
    echo -e "\n══════════════════════════════════════════════════════════════"
    echo "         安装 Shadowsocks-Rust 服务端"
    echo -e "══════════════════════════════════════════════════════════════"
    
    # 覆盖安装保护：旧配置里有正在使用的端口/密码，静默覆盖会让已发出的客户端全部失效
    if [[ -f "$CONF_FILE" ]]; then
        echo -e "\033[33m[WARN] 检测到已有配置: $CONF_FILE\033[0m"
        echo -e "\033[33m       继续安装会重新生成端口/密码，现有客户端将全部失效。\033[0m"
        read -p "  是否继续覆盖安装? [y/N]: " OVERWRITE_CONFIRM
        if [[ ! "$OVERWRITE_CONFIRM" =~ ^[Yy]$ ]]; then
            echo "  已取消安装，现有配置未改动。"
            return
        fi
        CONF_BAK="${CONF_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$CONF_FILE" "$CONF_BAK" && echo -e "\033[32m[INFO] 原配置已备份: $CONF_BAK\033[0m"
    fi

    install_dependencies

    echo "[STEP] 正在自动检索系统架构..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)   SS_ARCH="x86_64-unknown-linux-musl" ;;
        aarch64|arm64)  SS_ARCH="aarch64-unknown-linux-musl" ;;
        armv7l|armhf)   SS_ARCH="armv7-unknown-linux-musleabihf" ;;
        armv6l)         SS_ARCH="arm-unknown-linux-musleabihf" ;;
        i386|i686)      SS_ARCH="i686-unknown-linux-musl" ;;
        loongarch64)    SS_ARCH="loongarch64-unknown-linux-musl" ;;
        riscv64)        SS_ARCH="riscv64gc-unknown-linux-musl" ;;
        *) echo -e "\033[31m[ERROR] 暂不支持的架构: $ARCH\033[0m"; return ;;
    esac
    echo "[INFO] 检测到架构: $ARCH (优先采用 Musl 静态编译包)"

    echo "[STEP] 正在获取 Release 版本列表..."
    
    FETCH_RES=$(fetch_version_list)
    FETCH_STATUS=$(echo "$FETCH_RES" | head -n1)
    ALL_RELEASES=$(echo "$FETCH_RES" | tail -n +2)

    case "$FETCH_STATUS" in
        API_SUCCESS)
            FETCH_MSG="【GitHub API 实时获取】"
            echo -e "\033[32m[INFO] 成功从 GitHub API 实时获取完整版本列表！\033[0m"
            ;;
        REDIRECT_SUCCESS)
            FETCH_MSG="【302 重定向锁定最新 Tag + 本地兜底】"
            echo -e "\033[33m[WARN] GitHub API 限流，成功通过 302 重定向锁定网页最新 Tag！\033[0m"
            ;;
        *)
            FETCH_MSG="【本地预设兜底版本】"
            echo -e "\033[33m[WARN] API 与重定向均失败，改用本地预设兜底版本列表...\033[0m"
            ;;
    esac

    TMP_DIR=$(mktemp -d -p /var/tmp 2>/dev/null || mktemp -d)
    FOUND_VER=""

    echo "[STEP] 从最新版本开始逐个下载，并精确核验方法表中是否含 $PREFERRED_METHOD..."
    for VER in $ALL_RELEASES; do
        echo " ├─ 正在核验版本: $VER ..."
        if download_and_verify "$VER" "$SS_ARCH" "$TMP_DIR"; then
            FOUND_VER="$VER"
            echo -e " │  └─ \033[32m[MATCH] 校验通过！$FETCH_MSG 版本 $VER 的方法表中含 $PREFERRED_METHOD！\033[0m"
            break
        fi
    done

    if [[ -z "$FOUND_VER" ]]; then
        echo -e "\033[31m[ERROR] 未能在版本列表中找到任何方法表内含 $PREFERRED_METHOD 的版本！\033[0m"
        cleanup_on_exit
        TMP_DIR=""
        return
    fi

    echo -e "\n──────────────────────────────────────────────────────────────"
    echo "  交互设置 (准备配置 Shadowsocks-Rust $FOUND_VER)"
    echo "──────────────────────────────────────────────────────────────"
    
    while :; do
        read -rp "  输入服务端口 [1-65535] (默认: 56688): " PORT
        PORT=${PORT:-56688}
        if [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )); then
            PORT=$((10#$PORT))
            break
        fi
        echo -e "  \033[31m端口非法，请输入 1-65535 之间的数字。\033[0m"
    done

    RAND_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    read -rp "  输入连接密码 (默认随机生成): " PASSWORD
    if [[ -z "$PASSWORD" ]]; then
        PASSWORD="$RAND_PASS"
        PW_IS_RANDOM=1
    else
        PW_IS_RANDOM=0
    fi

    TMP_BIN="${TMP_DIR}/ssserver"
    METHODS=($(get_supported_methods "$TMP_BIN"))

    echo -e "\n  选择加密方式 (当前版本共支持 ${#METHODS[@]} 种):"
    local idx=1
    for m in "${METHODS[@]}"; do
        if [[ "$m" == "$PREFERRED_METHOD" ]]; then
            echo "    ${idx}) ${m} (推荐，老旧客户端完美兼容)"
        else
            echo "    ${idx}) ${m}"
        fi
        ((idx++))
    done

    read -p "  请选择 [1-${#METHODS[@]}] (默认: 1): " METHOD_CHOICE
    METHOD_CHOICE=${METHOD_CHOICE:-1}

    if [[ "$METHOD_CHOICE" =~ ^[0-9]+$ ]] && (( METHOD_CHOICE >= 1 && METHOD_CHOICE <= ${#METHODS[@]} )); then
        METHOD="${METHODS[$((METHOD_CHOICE-1))]}"
    else
        METHOD="$PREFERRED_METHOD"
    fi

    # AEAD-2022 的 password 必须是 base64、且解码长度等于 key 长度，否则 ssserver 启动即失败
    METHOD_KEY_LEN=$(method_key_len "$METHOD")
    if (( METHOD_KEY_LEN > 0 )); then
        if [[ "${PW_IS_RANDOM:-0}" -eq 1 ]]; then
            PASSWORD=$(rand_psk "$METHOD_KEY_LEN")
            echo -e "  \033[33m[INFO] $METHOD 使用 ${METHOD_KEY_LEN} 字节 base64 随机密钥作为密码。\033[0m"
        elif ! is_valid_psk "$PASSWORD" "$METHOD_KEY_LEN"; then
            PASSWORD=$(rand_psk "$METHOD_KEY_LEN")
            echo -e "  \033[33m[WARN] $METHOD 要求 ${METHOD_KEY_LEN} 字节的 base64 密钥，已用随机密钥替换你输入的口令。\033[0m"
        fi
    fi

    echo -e "\n  选择传输模式:"
    echo "    1) TCP + UDP (推荐)"
    echo "    2) 仅 TCP"
    echo "    3) 仅 UDP"
    read -p "  请选择 [1-3] (默认: 1): " MODE_CHOICE
    case "$MODE_CHOICE" in
        2) MODE="tcp_only" ;;
        3) MODE="udp_only" ;;
        *) MODE="tcp_and_udp" ;;
    esac

    echo "[STEP] 生成配置文件..."
    mkdir -p "$CONF_DIR"

    # 监听地址自适应：内核具备 IPv6 栈时用 "::"（默认双栈，同时接受 IPv4），
    # 否则退化为 "0.0.0.0"，避免在禁用 IPv6 的机器上 bind 失败导致服务起不来
    local listen_addr="::"
    if [[ ! -e /proc/net/if_inet6 ]]; then
        listen_addr="0.0.0.0"
        echo -e "  \033[33m[INFO] 未检测到系统 IPv6 栈，监听地址自动改用 0.0.0.0\033[0m"
    fi

    # 用 jq 生成 JSON，避免密码含引号/反斜杠时写出非法配置；无 jq 时退回手工转义
    if command -v jq >/dev/null 2>&1; then
        if ! jq -n --argjson port "$PORT" --arg server "$listen_addr" --arg pw "$PASSWORD" --arg method "$METHOD" --arg mode "$MODE" \
            '{server: $server, server_port: $port, password: $pw, method: $method, mode: $mode, fast_open: false}' \
            > "${CONF_FILE}.tmp"; then
            echo -e "\033[31m[ERROR] 配置生成失败，安装已中止（现有安装未被改动）。\033[0m"
            rm -f "${CONF_FILE}.tmp"
            return
        fi
    else
        cat <<EOF > "${CONF_FILE}.tmp"
{
    "server": "$listen_addr",
    "server_port": $PORT,
    "password": "$(json_escape "$PASSWORD")",
    "method": "$(json_escape "$METHOD")",
    "mode": "$(json_escape "$MODE")",
    "fast_open": false
}
EOF
    fi

    echo "[STEP] 部署二进制文件..."
    if ! mv "${TMP_DIR}/ssserver" "$BIN_PATH"; then
        echo -e "\033[31m[ERROR] 二进制部署失败（可能正在被占用或磁盘已满），安装已中止。\033[0m"
        rm -f "${CONF_FILE}.tmp"
        cleanup_on_exit
        return
    fi
    chmod +x "$BIN_PATH"

    mv -f "${CONF_FILE}.tmp" "$CONF_FILE"
    chmod 600 "$CONF_FILE"

    cleanup_on_exit
    TMP_DIR=""

    # 自动放行端口
    open_port "$PORT"

    echo "[STEP] 配置系统自启服务..."
    if has_systemd; then
        cat <<EOF > "$SYSTEMD_FILE"
[Unit]
Description=Shadowsocks-Rust Server
After=network.target

[Service]
Type=simple
User=root
Group=root
LimitNOFILE=512000
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks-rust/config.json
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable shadowsocks-rust >/dev/null 2>&1
    elif command -v rc-update >/dev/null 2>&1; then
        cat <<EOF > "$OPENRC_FILE"
#!/sbin/openrc-run
name="Shadowsocks-Rust Server"
description="Shadowsocks-Rust Service"
supervisor="supervise-daemon"
command="/usr/local/bin/ssserver"
command_args="-c /etc/shadowsocks-rust/config.json"
pidfile="/run/shadowsocks-rust.pid"

depend() {
    need net
    after firewall
}
EOF
        chmod +x "$OPENRC_FILE"
        rc-update add shadowsocks-rust default >/dev/null 2>&1
    fi

    echo "[STEP] 启动 Shadowsocks-Rust 服务..."
    start_service_cmd

    if is_service_running; then
        echo -e "\033[32m[SUCCESS] Shadowsocks-Rust 安装并启动成功！\033[0m"
        show_config
    else
        echo -e "\033[31m[ERROR] 服务启动失败，请选择菜单 [8] 查看运行日志。\033[0m"
    fi
}

# 2. 更新 Shadowsocks-Rust
update_ss() {
    if [[ ! -f "$BIN_PATH" ]]; then
        echo -e "\033[31m[ERROR] 未检测到已安装的 Shadowsocks-Rust！\033[0m"
        return
    fi

    CURRENT_VER=$(get_installed_version)
    echo -e "[STEP] 当前已安装版本: \033[36m$CURRENT_VER\033[0m"

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)   SS_ARCH="x86_64-unknown-linux-musl" ;;
        aarch64|arm64)  SS_ARCH="aarch64-unknown-linux-musl" ;;
        armv7l|armhf)   SS_ARCH="armv7-unknown-linux-musleabihf" ;;
        armv6l)         SS_ARCH="arm-unknown-linux-musleabihf" ;;
        i386|i686)      SS_ARCH="i686-unknown-linux-musl" ;;
        loongarch64)    SS_ARCH="loongarch64-unknown-linux-musl" ;;
        riscv64)        SS_ARCH="riscv64gc-unknown-linux-musl" ;;
        *) echo -e "\033[31m[ERROR] 暂不支持的架构: $ARCH\033[0m"; return ;;
    esac

    echo "[STEP] 正在获取 Release 版本列表..."
    
    FETCH_RES=$(fetch_version_list)
    FETCH_STATUS=$(echo "$FETCH_RES" | head -n1)
    ALL_RELEASES=$(echo "$FETCH_RES" | tail -n +2)

    case "$FETCH_STATUS" in
        API_SUCCESS)
            FETCH_MSG="【GitHub API 实时获取】"
            echo -e "\033[32m[INFO] 成功从 GitHub API 实时获取完整版本列表！\033[0m"
            ;;
        REDIRECT_SUCCESS)
            FETCH_MSG="【302 重定向锁定最新 Tag + 本地兜底】"
            echo -e "\033[33m[WARN] GitHub API 限流，成功通过 302 重定向锁定网页最新 Tag！\033[0m"
            ;;
        *)
            FETCH_MSG="【本地预设兜底版本】"
            echo -e "\033[33m[WARN] API 与重定向均失败，改用本地预设兜底版本列表...\033[0m"
            ;;
    esac

    TMP_DIR=$(mktemp -d -p /var/tmp 2>/dev/null || mktemp -d)
    FOUND_VER=""

    echo "[STEP] 从最新版本开始逐个校验，检索方法表中含 $PREFERRED_METHOD 的最新版本..."
    for VER in $ALL_RELEASES; do
        echo " ├─ 正在核验版本: $VER ..."
        if download_and_verify "$VER" "$SS_ARCH" "$TMP_DIR"; then
            FOUND_VER="$VER"
            echo -e " │  └─ \033[32m[MATCH] 校验通过！$FETCH_MSG 版本 $VER 的方法表中含 $PREFERRED_METHOD！\033[0m"
            break
        fi
    done

    if [[ -z "$FOUND_VER" ]]; then
        echo -e "\033[31m[ERROR] 未能在版本列表中找到任何方法表内含 $PREFERRED_METHOD 的版本！\033[0m"
        cleanup_on_exit
        TMP_DIR=""
        return
    fi

    if [[ "${FOUND_VER#v}" == "${CURRENT_VER#v}" ]]; then
        echo -e "\033[32m[INFO] 当前已安装版本 ($CURRENT_VER) 即为方法表中含 $PREFERRED_METHOD 的最新版本，无需更新！\033[0m"
        cleanup_on_exit
        TMP_DIR=""
        return
    fi

    if ! is_newer_version "$FOUND_VER" "$CURRENT_VER"; then
        echo -e "\033[33m[WARN] 检索到的最高支持版本 ($FOUND_VER) 低于当前已安装版本 ($CURRENT_VER)，不执行降级。\033[0m"
        echo -e "\033[33m       如需回退到旧版本，请先卸载后重新安装。\033[0m"
        cleanup_on_exit
        TMP_DIR=""
        return
    fi

    echo -e "\033[32m[INFO] 发现方法表中含 $PREFERRED_METHOD 的较新版本: $FOUND_VER (升级自 $CURRENT_VER)，正在应用更新...\033[0m"
    stop_service_cmd
    mv "${TMP_DIR}/ssserver" "$BIN_PATH"
    chmod +x "$BIN_PATH"

    cleanup_on_exit
    TMP_DIR=""

    start_service_cmd
    echo -e "\033[32m[SUCCESS] 更新完成，当前版本已成功升级至: $(get_installed_version)\033[0m"
}

# 3. 卸载 Shadowsocks-Rust
uninstall_ss() {
    read -p "确定要彻底卸载 Shadowsocks-Rust 吗？[y/N]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        # 端口要在删除配置目录之前读出，否则之后无从得知该回收哪条防火墙规则
        local remove_port=""
        if [[ -f "$CONF_FILE" ]]; then
            if command -v jq >/dev/null 2>&1; then
                remove_port=$(jq -r '.server_port // empty' "$CONF_FILE" 2>/dev/null)
            else
                remove_port=$(grep -oE '"server_port"[[:space:]]*:[[:space:]]*[0-9]+' "$CONF_FILE" 2>/dev/null | grep -oE '[0-9]+$')
            fi
        fi

        stop_service_cmd
        if has_systemd; then
            systemctl disable shadowsocks-rust >/dev/null 2>&1
            rm -f "$SYSTEMD_FILE"
            systemctl daemon-reload
        elif command -v rc-update >/dev/null 2>&1; then
            rc-update del shadowsocks-rust default >/dev/null 2>&1
            rm -f "$OPENRC_FILE"
        fi
        rm -f "$BIN_PATH"
        rm -rf "$CONF_DIR"

        if [[ "$remove_port" =~ ^[0-9]+$ ]]; then
            close_port "$remove_port"
        fi

        echo -e "\033[32m[SUCCESS] Shadowsocks-Rust 卸载完成。\033[0m"
    fi
}

# 4. 启动服务
start_ss() {
    if [[ ! -f "$BIN_PATH" ]]; then
        echo -e "\033[31m未安装 Shadowsocks-Rust，请先进行安装！\033[0m"
        return
    fi
    start_service_cmd
    if is_service_running; then
        echo -e "\033[32m服务启动成功！\033[0m"
    else
        echo -e "\033[31m服务启动失败，请检查日志！\033[0m"
    fi
}

# 5. 停止服务
stop_ss() {
    if [[ ! -f "$BIN_PATH" ]]; then
        echo -e "\033[31m未安装 Shadowsocks-Rust！\033[0m"
        return
    fi
    stop_service_cmd
    echo -e "\033[33m服务已停止。\033[0m"
}

# 6. 重启服务
restart_ss() {
    if [[ ! -f "$BIN_PATH" ]]; then
        echo -e "\033[31m未安装 Shadowsocks-Rust！\033[0m"
        return
    fi
    stop_service_cmd
    sleep 1
    start_service_cmd
    if is_service_running; then
        echo -e "\033[32m服务重启成功！\033[0m"
    else
        echo -e "\033[31m服务重启失败，请检查日志！\033[0m"
    fi
}

# 7. 查看配置及 SS 链接
show_config() {
    if [[ ! -f "$CONF_FILE" ]]; then
        echo -e "\033[31m配置文件不存在或未安装！\033[0m"
        return
    fi
    
    PORT=$(jq -r .server_port "$CONF_FILE")
    PASSWORD=$(jq -r .password "$CONF_FILE")
    METHOD=$(jq -r .method "$CONF_FILE")
    
    IPV4=$(curl -s4 --max-time 3 https://api.ipify.org 2>/dev/null || curl -s4 --max-time 3 https://icanhazip.com 2>/dev/null || echo "YOUR_SERVER_IP")
    IPV6=$(curl -s6 --max-time 3 https://api64.ipify.org 2>/dev/null || curl -s6 --max-time 3 https://icanhazip.com 2>/dev/null)

    RAW_SS_V4="${METHOD}:${PASSWORD}@${IPV4}:${PORT}"
    ENCODED_SS_V4=$(echo -n "$RAW_SS_V4" | base64 -w0 2>/dev/null || echo -n "$RAW_SS_V4" | base64 | tr -d '\n')
    SS_LINK_V4="ss://${ENCODED_SS_V4}#Shadowsocks-Rust-IPV4"

    echo -e "\n──────────────────────────────────────────────────────────────"
    echo "  Shadowsocks-Rust 配置信息"
    echo "──────────────────────────────────────────────────────────────"
    echo "  配置文件路径 : $CONF_FILE"
    echo "  服务器 IPv4  : $IPV4"
    if [[ -n "$IPV6" ]]; then
        echo "  服务器 IPv6  : $IPV6"
    else
        echo "  服务器 IPv6  : 当前服务器无 IPv6"
    fi
    echo "  服务端口     : $PORT"
    echo "  连接密码     : $PASSWORD"
    echo "  加密方式     : $METHOD"
    echo "──────────────────────────────────────────────────────────────"
    echo "  SS 链接 (IPv4) : $SS_LINK_V4"
    if [[ -n "$IPV6" ]]; then
        RAW_SS_V6="${METHOD}:${PASSWORD}@${IPV6}:${PORT}"
        ENCODED_SS_V6=$(echo -n "$RAW_SS_V6" | base64 -w0 2>/dev/null || echo -n "$RAW_SS_V6" | base64 | tr -d '\n')
        SS_LINK_V6="ss://${ENCODED_SS_V6}#Shadowsocks-Rust-IPv6"
        echo "  SS 链接 (IPv6) : $SS_LINK_V6"
    fi
    echo -e "──────────────────────────────────────────────────────────────\n"
}

# 8. 查看运行日志
view_logs() {
    echo -e "\033[36m正在查看运行日志 (按 Ctrl+C 退出)... \033[0m\n"
    if has_systemd && command -v journalctl >/dev/null 2>&1; then
        journalctl -u shadowsocks-rust -n 50 -f
    elif [[ -f "/var/log/messages" ]]; then
        tail -f -n 50 /var/log/messages
    else
        echo -e "\033[33m未检测到 journalctl 或常见日志文件，请通过 systemctl 或 rc-service 检查。 \033[0m"
    fi
}

# 菜单主循环
main_menu() {
    while true; do
        clear
        echo -e "╔══════════════════════════════════════════════════════════════╗"
        echo -e "║                Shadowsocks-Rust 服务管理脚本                 ║"
        echo -e "╠══════════════════════════════════════════════════════════════╣"
        print_status_line
        echo -e "╠══════════════════════════════════════════════════════════════╣"
        echo -e "║  1. 安装 Shadowsocks-Rust                                    ║"
        echo -e "║  2. 更新 Shadowsocks-Rust                                    ║"
        echo -e "║  3. 卸载 Shadowsocks-Rust                                    ║"
        echo -e "╟──────────────────────────────────────────────────────────────╢"
        echo -e "║  4. 启动服务                                                 ║"
        echo -e "║  5. 停止服务                                                 ║"
        echo -e "║  6. 重启服务                                                 ║"
        echo -e "╟──────────────────────────────────────────────────────────────╢"
        echo -e "║  7. 查看配置及 SS 链接 (IPv4 / IPv6)                         ║"
        echo -e "║  8. 查看运行日志                                             ║"
        echo -e "║  0. 退出脚本                                                 ║"
        echo -e "╚══════════════════════════════════════════════════════════════╝"
        
        read -p " 请选择操作 [0-8]: " CHOICE
        case "$CHOICE" in
            1) install_ss ;;
            2) update_ss ;;
            3) uninstall_ss ;;
            4) start_ss ;;
            5) stop_ss ;;
            6) restart_ss ;;
            7) show_config ;;
            8) view_logs ;;
            0) exit 0 ;;
            *) echo -e "\033[31m无效选项，请输入 0-8\033[0m" ;;
        esac
        echo ""
        read -p "按 Enter 键返回主菜单..."
    done
}

main_menu