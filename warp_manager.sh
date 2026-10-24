#!/bin/bash
# Cloudflare WARP 管理工具 (Deeply Optimized Version)
# 功能：安装/配置 WARP IPv6（支持 WARP+）、卸载接口、卸载脚本、检测状态、自动检测异常重启、流媒体解锁检测
# 接口名 warp，保留本地 IPv4，自动检测架构，支持开机自启，安装后自动注册 02 命令

# --- 全局变量与常量 ---

# 确保以 root 权限运行
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[31m错误：此脚本需要 root 权限，请使用 root 用户或 sudo bash $0 运行。\033[0m"
    exit 1
fi

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

SERVICE_NAME="warp-monitor.service"
STREAM_SERVICE_NAME="warp-stream-monitor.service"
SCRIPT_URL="https://raw.githubusercontent.com/geniuszerotwo/warp-unlock/main/warp_manager.sh"
MIRROR_PREFIX="https://ghfast.top/"
WGCF_DIR="/etc/wireguard/wgcf"
WARP_CONF="/etc/wireguard/warp.conf"
STREAM_CONF="/etc/wireguard/warp_stream.conf"
COOKIE_CACHE="/etc/wireguard/disney_cookies.txt"
KEEPALIVE_CONF="/etc/wireguard/warp_keepalive.conf"
HY2_DEFAULT_CONF="/etc/hysteria/config.yaml"
UA_BROWSER="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

# 看板 IP 状态内存缓存（避免每次返回菜单重复网络请求卡顿）
CACHED_IPV4_LINE=""
CACHED_IPV6_LINE=""
CACHE_TIMESTAMP=0
CACHE_TTL=60

# --- 基础辅助函数 ---

color_echo() {
    local color="$1"
    local text="$2"
    local code=""
    case "$color" in
        red)    code="31" ;;
        green)  code="32" ;;
        yellow) code="33" ;;
        blue)   code="34" ;;
        purple) code="35" ;;
        cyan)   code="36" ;;
    esac
    if [[ -n "$code" ]]; then
        echo -e "\033[${code}m${text}\033[0m"
    else
        echo "$text"
    fi
}

invalidate_status_cache() {
    CACHE_TIMESTAMP=0
}

# --- 服务管理兼容层 (支持 Systemd 与 Alpine OpenRC) ---

is_systemd() {
    command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

is_openrc() {
    command -v rc-service >/dev/null 2>&1
}

service_is_active() {
    local svc="$1"
    local base="${svc%.service}"
    if is_systemd; then
        systemctl is-active --quiet "$svc" 2>/dev/null
    elif is_openrc; then
        rc-service "$base" status >/dev/null 2>&1
    else
        pgrep -f "/usr/local/bin/${base}.sh" >/dev/null 2>&1
    fi
}

check_service_status() {
    local service="$1"
    local name="$2"
    if [[ -z "$service" ]]; then
        echo "$(color_echo yellow "$name: 未配置服务名 ⚠️")"
        return
    fi
    if service_is_active "$service"; then
        echo "$(color_echo green "$name: 运行中 ✅")"
    else
        echo "$(color_echo red "$name: 未运行 ❌")"
    fi
}

install_and_start_service() {
    local svc="$1"
    local desc="$2"
    local exec_script="$3"
    local base="${svc%.service}"

    if is_systemd; then
        cat > "/etc/systemd/system/${svc}" <<EOF
[Unit]
Description=${desc}
After=network.target network-online.target

[Service]
Type=simple
ExecStart=${exec_script}
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now "$svc" >/dev/null 2>&1
        systemctl restart "$svc" >/dev/null 2>&1
    elif is_openrc; then
        cat > "/etc/init.d/${base}" <<EOF
#!/sbin/openrc-run
description="${desc}"
command="${exec_script}"
command_background="yes"
pidfile="/run/${base}.pid"
output_log="/var/log/${base}.log"
error_log="/var/log/${base}.log"

depend() {
    need net
}
EOF
        chmod +x "/etc/init.d/${base}"
        rc-update add "$base" default >/dev/null 2>&1 || true
        rc-service "$base" restart >/dev/null 2>&1
    else
        pkill -f "$exec_script" 2>/dev/null || true
        nohup "$exec_script" >> "/var/log/${base}.log" 2>&1 &
    fi
}

stop_and_remove_service() {
    local svc="$1"
    local exec_script="$2"
    local base="${svc%.service}"

    if is_systemd; then
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}"
        systemctl daemon-reload 2>/dev/null || true
    elif is_openrc; then
        rc-service "$base" stop 2>/dev/null || true
        rc-update del "$base" default 2>/dev/null || true
        rm -f "/etc/init.d/${base}"
    fi
    if [[ -n "$exec_script" ]]; then
        pkill -f "$exec_script" 2>/dev/null || true
        rm -f "$exec_script"
    fi
}

follow_service_logs() {
    local svc="$1"
    local lines="${2:-30}"
    local base="${svc%.service}"

    # 捕获 Ctrl+C 信号，防止退出日志流时直接终止整个管理脚本
    trap ':' INT
    if is_systemd; then
        journalctl -u "$svc" -f -n "$lines"
    else
        local logfile="/var/log/${base}.log"
        touch "$logfile"
        tail -n "$lines" -f "$logfile"
    fi
    trap - INT
    echo ""
}

# --- 网络与 IP 探测函数 ---

# 快速获取出口 IPv6 地址（优先 Cloudflare Trace，免除第三方限流，带多级兜底）
get_warp_ipv6_ip() {
    local iface_arg="$1"
    local ip=""
    local trace_out

    trace_out=$(curl -6 $iface_arg -A "$UA_BROWSER" -fsL --max-time 3 "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null || \
                curl -6 $iface_arg -A "$UA_BROWSER" -fsL --max-time 3 "https://[2606:4700:4700::1111]/cdn-cgi/trace" 2>/dev/null)
    if [[ -n "$trace_out" ]]; then
        ip=$(echo "$trace_out" | sed -n 's/^ip=//p' | head -1)
    fi

    if [[ -z "$ip" ]]; then
        ip=$(curl -6 $iface_arg -A "$UA_BROWSER" -fsL --max-time 4 "https://api64.ipify.org" 2>/dev/null || \
             curl -6 $iface_arg -A "$UA_BROWSER" -fsL --max-time 4 "https://ifconfig.co" 2>/dev/null)
    fi

    echo "${ip:-不可用}"
}

# 探测 IPv4 摘要信息
probe_ipv4_line() {
    local ipv4 isp4 country4 ipv4_info trace4
    if command -v jq >/dev/null 2>&1; then
        ipv4_info=$(curl -4 -s --max-time 2 "http://ip-api.com/json/?fields=status,query,org,country" 2>/dev/null || echo "")
        if [[ -n "$ipv4_info" && "$ipv4_info" == *'"status":"success"'* ]]; then
            ipv4=$(echo "$ipv4_info" | jq -r '.query // "不可用"' 2>/dev/null)
            isp4=$(echo "$ipv4_info" | jq -r '.org // "未知服务商"' 2>/dev/null)
            country4=$(echo "$ipv4_info" | jq -r '.country // "未知地区"' 2>/dev/null)
            echo "${ipv4} (${isp4}, ${country4})"
            return
        fi
    fi

    trace4=$(curl -4 -s --max-time 2 "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null || echo "")
    if [[ -n "$trace4" ]]; then
        ipv4=$(echo "$trace4" | sed -n 's/^ip=//p' | head -1)
        country4=$(echo "$trace4" | sed -n 's/^loc=//p' | head -1)
        if [[ -n "$ipv4" ]]; then
            echo "${ipv4} (${country4:-未知地区})"
            return
        fi
    fi

    ipv4=$(curl -4 -s --max-time 2 "https://api.ipify.org" 2>/dev/null || echo "不可用")
    echo "${ipv4} (未知服务商, 未知地区)"
}

# 探测 IPv6 摘要信息
probe_ipv6_line() {
    local ipv6 isp6 country6 trace6 warp_mode ipv6_info

    # 优先使用 Cloudflare Trace (速度快、无频控、直接识别 WARP / WARP+)
    trace6=$(curl -6 -s --max-time 2 "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null || \
             curl -6 -s --max-time 2 "https://[2606:4700:4700::1111]/cdn-cgi/trace" 2>/dev/null || echo "")
    if [[ -n "$trace6" ]]; then
        ipv6=$(echo "$trace6" | sed -n 's/^ip=//p' | head -1)
        country6=$(echo "$trace6" | sed -n 's/^loc=//p' | head -1)
        warp_mode=$(echo "$trace6" | sed -n 's/^warp=//p' | head -1)
        if [[ -n "$ipv6" ]]; then
            case "$warp_mode" in
                plus) isp6="Cloudflare WARP+" ;;
                on)   isp6="Cloudflare WARP" ;;
                *)    isp6="原生/其他 IPv6" ;;
            esac
            echo "${ipv6} (${isp6}, ${country6:-未知地区})"
            return
        fi
    fi

    if command -v jq >/dev/null 2>&1; then
        ipv6_info=$(curl -6 -s --max-time 3 "https://ifconfig.co/json" 2>/dev/null || echo "")
        if [[ -n "$ipv6_info" && "$ipv6_info" != *"error"* ]]; then
            ipv6=$(echo "$ipv6_info" | jq -r '.ip // "不可用"' 2>/dev/null)
            isp6=$(echo "$ipv6_info" | jq -r '.asn_org // "未知服务商"' 2>/dev/null)
            country6=$(echo "$ipv6_info" | jq -r '.country // "未知地区"' 2>/dev/null)
            echo "${ipv6} (${isp6}, ${country6})"
            return
        fi
    fi

    ipv6=$(curl -6 -s --max-time 2 "https://api64.ipify.org" 2>/dev/null || echo "不可用")
    echo "${ipv6} (未知服务商, 未知地区)"
}

# 检查 WARP 状态（支持并发探测与内存缓存，秒开菜单）
check_warp_status() {
    local status now
    local svc_name="${SERVICE_NAME:-warp-monitor.service}"
    local stream_svc_name="${STREAM_SERVICE_NAME:-warp-stream-monitor.service}"

    if ip link show warp >/dev/null 2>&1; then
        status="$(color_echo green "运行中 ✅")"
    else
        status="$(color_echo red "未运行 ❌")"
    fi

    now=$(date +%s)
    if [[ -z "$CACHED_IPV4_LINE" || -z "$CACHED_IPV6_LINE" || $((now - CACHE_TIMESTAMP)) -ge $CACHE_TTL ]]; then
        local tmp_dir
        tmp_dir=$(mktemp -d 2>/dev/null || echo "/tmp/warp_status_$$")
        mkdir -p "$tmp_dir"

        probe_ipv4_line > "$tmp_dir/v4" &
        probe_ipv6_line > "$tmp_dir/v6" &
        wait

        CACHED_IPV4_LINE=$(cat "$tmp_dir/v4" 2>/dev/null || echo "不可用")
        CACHED_IPV6_LINE=$(cat "$tmp_dir/v6" 2>/dev/null || echo "不可用")
        CACHE_TIMESTAMP=$(date +%s)
        rm -rf "$tmp_dir"
    fi

    echo "============================================================"
    echo " Cloudflare WARP 核心看板: $status"
    echo " 出口 IPv4: $CACHED_IPV4_LINE"
    echo " 出口 IPv6: $CACHED_IPV6_LINE"
    echo "------------------------------------------------------------"
    check_service_status "$svc_name" " 接口异常保活服务"
    check_service_status "$stream_svc_name" " 流媒体解锁监控服务"
    check_hy2_ai_status
    echo "============================================================"
}

# 自动探测 Hysteria 2 配置文件路径
find_hy2_config() {
    if [[ -f "$HY2_DEFAULT_CONF" ]]; then
        echo "$HY2_DEFAULT_CONF"
        return
    fi
    local svc conf_from_svc
    for svc in hysteria-server.service hysteria.service hy2.service; do
        if [[ -f "/etc/systemd/system/${svc}" ]]; then
            conf_from_svc=$(grep -E 'ExecStart=' "/etc/systemd/system/${svc}" 2>/dev/null | grep -oE '(--config|-c)[= ]+[^ ]+' | awk '{print $NF}' | tr -d '"' | head -1)
            if [[ -n "$conf_from_svc" && -f "$conf_from_svc" ]]; then
                echo "$conf_from_svc"
                return
            fi
        fi
    done
    for conf_from_svc in /etc/hysteria/server.yaml /usr/local/etc/hysteria/config.yaml; do
        if [[ -f "$conf_from_svc" ]]; then
            echo "$conf_from_svc"
            return
        fi
    done
    echo "$HY2_DEFAULT_CONF"
}

# 看板展示 Hysteria 2 AI 与流媒体分流状态
check_hy2_ai_status() {
    local hy2_conf
    hy2_conf=$(find_hy2_config)
    if [[ ! -f "$hy2_conf" ]]; then
        echo "$(color_echo yellow " Hysteria2 分流状态: 未检测到配置文件 ⚪")"
    elif grep -q '# \[WARP-' "$hy2_conf" 2>/dev/null; then
        local has_ai=0 has_stream=0
        grep -q '# \[WARP-AI\]' "$hy2_conf" 2>/dev/null && has_ai=1
        grep -q '# \[WARP-STREAM\]' "$hy2_conf" 2>/dev/null && has_stream=1
        if [[ $has_ai -eq 1 && $has_stream -eq 1 ]]; then
            echo "$(color_echo green " Hysteria2 分流状态: 已启用 (AI + 流媒体 -> IPv6) ✅")"
        elif [[ $has_ai -eq 1 ]]; then
            echo "$(color_echo green " Hysteria2 分流状态: 已启用 (仅 AI -> IPv6) ✅")"
        elif [[ $has_stream -eq 1 ]]; then
            echo "$(color_echo green " Hysteria2 分流状态: 已启用 (仅流媒体 -> IPv6) ✅")"
        else
            echo "$(color_echo green " Hysteria2 分流状态: 已启用 ✅")"
        fi
    else
        echo "$(color_echo red " Hysteria2 分流状态: 未启用 ❌")"
    fi
}

# --- 流媒体检测与 Telegram 核心函数 (主菜单与守护进程共用) ---

# Netflix 检测
# 参数1: 网卡参数 (如 "--interface warp")
# 参数2: 输出模式 ("compact" 用于守护进程日志，默认用于交互菜单)
check_netflix_core() {
    local iface_arg="$1"
    local mode="${2:-full}"
    local sg_id="81215567"
    local orig_id="80018499"
    local resp_sg resp_orig code_sg code_orig url_sg url_orig region

    # 1. 检查非自制独占影片 (测试完整解锁)
    resp_sg=$(curl -6 $iface_arg -A "$UA_BROWSER" -sL --max-time 8 -w "%{http_code}\n%{url_effective}" -o /dev/null "https://www.netflix.com/title/${sg_id}" 2>/dev/null)
    code_sg=$(echo "$resp_sg" | sed -n '1p')
    url_sg=$(echo "$resp_sg" | sed -n '2p')

    if [[ "$code_sg" == "200" ]]; then
        region=$(echo "$url_sg" | sed -nE 's#.*netflix\.com/([a-z]{2})(/.*)?#\1#p' | tr '[:lower:]' '[:upper:]')
        region=${region:-"US"}
        if [[ "$mode" == "compact" ]]; then
            echo "√(完整, $region)"
        else
            echo "√(完整解锁, $region)"
        fi
        return 0
    fi

    # 2. 检查自制剧影片 (测试是否仅自制剧)
    resp_orig=$(curl -6 $iface_arg -A "$UA_BROWSER" -sL --max-time 8 -w "%{http_code}\n%{url_effective}" -o /dev/null "https://www.netflix.com/title/${orig_id}" 2>/dev/null)
    code_orig=$(echo "$resp_orig" | sed -n '1p')
    url_orig=$(echo "$resp_orig" | sed -n '2p')

    if [[ "$code_orig" == "200" ]]; then
        region=$(echo "$url_orig" | sed -nE 's#.*netflix\.com/([a-z]{2})(/.*)?#\1#p' | tr '[:lower:]' '[:upper:]')
        region=${region:-"US"}
        echo "×(仅自制剧, $region)"
        return 2
    fi

    if [[ "$mode" == "compact" ]]; then
        echo "×"
    else
        echo "×(未解锁)"
    fi
    return 1
}

# Disney+ 检测
check_disney_core() {
    local iface_arg="$1"
    local mode="${2:-full}"
    local cache_file="$COOKIE_CACHE"

    mkdir -p /etc/wireguard
    if [[ ! -s "$cache_file" ]]; then
        curl -fsL --max-time 10 "https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/cookies" -o "$cache_file" 2>/dev/null || \
        curl -fsL --max-time 10 "${MIRROR_PREFIX}https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/cookies" -o "$cache_file" 2>/dev/null
    fi

    if [[ ! -s "$cache_file" ]]; then
        [[ "$mode" == "compact" ]] && echo "×" || echo "×(Cookie模版缺失)"
        return 1
    fi

    local pre_assertion assertion pre_cookie disney_cookie token_content is_banned is_403
    local fake_content refresh_token disney_content tmp_result region in_supported

    pre_assertion=$(curl -6 $iface_arg -A "$UA_BROWSER" -fsL --max-time 10 \
        -X POST "https://disney.api.edge.bamgrid.com/devices" \
        -H "authorization: Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" \
        -H "content-type: application/json; charset=UTF-8" \
        -d '{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}' 2>/dev/null)

    assertion=$(echo "$pre_assertion" | jq -r '.assertion // empty' 2>/dev/null)
    if [[ -z "$assertion" ]]; then
        [[ "$mode" == "compact" ]] && echo "×" || echo "×(未解锁)"
        return 1
    fi

    pre_cookie=$(sed -n '1p' "$cache_file" 2>/dev/null)
    disney_cookie=$(echo "$pre_cookie" | sed "s/DISNEYASSERTION/$assertion/g")

    token_content=$(curl -6 $iface_arg -A "$UA_BROWSER" -fsL --max-time 10 \
        -X POST "https://disney.api.edge.bamgrid.com/token" \
        -H "authorization: Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" \
        -d "$disney_cookie" 2>/dev/null)

    is_banned=$(echo "$token_content" | grep 'forbidden-location')
    is_403=$(echo "$token_content" | grep '403 ERROR')
    if [[ -n "$is_banned$is_403" ]]; then
        [[ "$mode" == "compact" ]] && echo "×" || echo "×(地区限制)"
        return 1
    fi

    fake_content=$(sed -n '8p' "$cache_file" 2>/dev/null)
    refresh_token=$(echo "$token_content" | jq -r '.refresh_token // empty' 2>/dev/null)
    disney_content=$(echo "$fake_content" | sed "s/ILOVEDISNEY/$refresh_token/g")

    tmp_result=$(curl -6 $iface_arg -A "$UA_BROWSER" -fsL --max-time 10 \
        -X POST "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql" \
        -H "authorization: ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" \
        -d "$disney_content" 2>/dev/null)

    region=$(echo "$tmp_result" | jq -r '[.. | .countryCode? | select(type == "string")][0] // empty' 2>/dev/null)
    in_supported=$(echo "$tmp_result" | jq -r '[.. | .inSupportedLocation? | select(type == "boolean")][0] // empty' 2>/dev/null)

    if [[ -n "$region" && "$in_supported" == "true" ]]; then
        echo "√($region)"
        return 0
    else
        [[ "$mode" == "compact" ]] && echo "×" || echo "×(未解锁)"
        return 1
    fi
}

# YouTube 检测
check_youtube_core() {
    local iface_arg="$1"
    local yt_html region

    yt_html=$(curl -6 $iface_arg -A "$UA_BROWSER" -sL --max-time 8 "https://www.youtube.com/premium" 2>/dev/null)
    if echo "$yt_html" | grep -q "Premium is not available in your country"; then
        echo "×(不支持 Premium)"
        return 1
    fi
    region=$(echo "$yt_html" | grep -oE '"countryCode":"[^"]+"' | head -1 | cut -d'"' -f4)
    if [[ -z "$region" ]]; then
        region=$(curl -6 $iface_arg -A "$UA_BROWSER" -sL --max-time 5 "https://www.youtube.com" 2>/dev/null | grep -oE '"GL":"[^"]+"' | head -1 | cut -d'"' -f4)
    fi
    if [[ -n "$region" ]]; then
        echo "√($region)"
        return 0
    else
        echo "√(可用)"
        return 0
    fi
}

# 发送 Telegram 消息（使用 --data-urlencode 防止特殊字符截断，支持重试）
send_telegram_msg() {
    local text="$1"
    local token="$2"
    local chat_id="$3"
    local api_base="${4:-https://api.telegram.org}"
    local retries="${5:-1}"

    if [[ -z "$token" || -z "$chat_id" ]]; then
        return 1
    fi

    api_base="${api_base%/}"
    local i res
    for ((i = 1; i <= retries; i++)); do
        res=$(curl -s -X POST "${api_base}/bot${token}/sendMessage" \
            --data-urlencode "chat_id=${chat_id}" \
            --data-urlencode "text=${text}" \
            --max-time 10 2>/dev/null)
        if echo "$res" | grep -q '"ok":true'; then
            return 0
        fi
        [[ $i -lt $retries ]] && sleep 1
    done
    return 1
}

# 保存流媒体与 Telegram 配置文件（收紧权限为 600）
save_stream_conf() {
    local unlock_target="$1"
    local tg_enabled="$2"
    local tg_token="$3"
    local tg_chat_id="$4"
    local tg_api_base="$5"

    mkdir -p /etc/wireguard
    cat > "$STREAM_CONF" <<EOF
UNLOCK_TARGET="${unlock_target}"
TG_ENABLED="${tg_enabled}"
TG_TOKEN="${tg_token}"
TG_CHAT_ID="${tg_chat_id}"
TG_API_BASE="${tg_api_base}"
EOF
    chmod 600 "$STREAM_CONF"
}

# --- 内置守护进程模式 (消除重复代码，动态热加载配置) ---

run_stream_daemon() {
    local iface="warp"
    local nic="--interface $iface"
    local retry_cooldown=10
    local max_consec_fails=10
    local pause_on_many_fails=1800
    local sleep_when_unlocked=1800
    local log_prefix="[WARP-STREAM]"
    local fail_count=0
    local current_ipv6=""

    log_msg() { echo "$(date '+%F %T') ${log_prefix} $*"; }

    while true; do
        # 每轮循环动态加载配置文件，菜单 [11] 修改 Telegram 配置后立即生效
        UNLOCK_TARGET="1"
        TG_ENABLED="no"
        TG_TOKEN=""
        TG_CHAT_ID=""
        TG_API_BASE="https://api.telegram.org"
        if [[ -f "$STREAM_CONF" ]]; then
            # shellcheck disable=SC1090
            source "$STREAM_CONF"
        fi

        # 检查接口连通性并获取当前 IPv6（单次探测复用，避免重复请求）
        current_ipv6=""
        if ip link show "$iface" >/dev/null 2>&1; then
            current_ipv6=$(get_warp_ipv6_ip "$nic")
        fi

        if [[ -z "$current_ipv6" || "$current_ipv6" == "不可用" ]]; then
            log_msg "⚠️ WARP 接口当前 IPv6 不通，正在尝试重置接口..."
            wg-quick down "$iface" >/dev/null 2>&1 || true
            sleep 2
            wg-quick up "$iface" >/dev/null 2>&1 || true
            sleep "$retry_cooldown"
            current_ipv6=$(get_warp_ipv6_ip "$nic")
            if [[ -z "$current_ipv6" || "$current_ipv6" == "不可用" ]]; then
                log_msg "❌ 接口重启后仍不可用，进入冷却 ${pause_on_many_fails} 秒..."
                sleep "$pause_on_many_fails"
                continue
            fi
        fi

        local target_unlocked=0
        local status_summary=""
        local nf_status ds_status nf_ok ds_ok

        if [[ "$UNLOCK_TARGET" == "1" ]]; then
            nf_status=$(check_netflix_core "$nic" "compact")
            nf_ok=$?
            status_summary="Netflix: $nf_status"
            [[ $nf_ok -eq 0 ]] && target_unlocked=1
        elif [[ "$UNLOCK_TARGET" == "2" ]]; then
            ds_status=$(check_disney_core "$nic" "compact")
            ds_ok=$?
            status_summary="Disney+: $ds_status"
            [[ $ds_ok -eq 0 ]] && target_unlocked=1
        else
            nf_status=$(check_netflix_core "$nic" "compact")
            nf_ok=$?
            ds_status=$(check_disney_core "$nic" "compact")
            ds_ok=$?
            status_summary="Netflix: $nf_status, Disney+: $ds_status"
            [[ $nf_ok -eq 0 && $ds_ok -eq 0 ]] && target_unlocked=1
        fi

        if [[ $target_unlocked -eq 0 ]]; then
            ((fail_count++))
            log_msg "[IPv6: $current_ipv6] ❌ 未满足解锁要求 ($status_summary)，第 $fail_count 次未命中 → 正在刷新 WARP 接口换 IP..."
            if [[ $fail_count -eq 1 && "$TG_ENABLED" == "yes" ]]; then
                send_telegram_msg "⚠️ WARP 未解锁：IPv6=$current_ipv6 | $status_summary | 时间=$(date '+%F %T')" "$TG_TOKEN" "$TG_CHAT_ID" "$TG_API_BASE" 3
            fi

            wg-quick down "$iface" >/dev/null 2>&1 || true
            sleep 2
            wg-quick up "$iface" >/dev/null 2>&1 || true
            sleep "$retry_cooldown"

            if [[ $fail_count -ge $max_consec_fails ]]; then
                log_msg "⚠️ 连续换 IP 达到 ${max_consec_fails} 次未命中目标，进入冷却 ${pause_on_many_fails} 秒..."
                if [[ "$TG_ENABLED" == "yes" ]]; then
                    send_telegram_msg "🚨 WARP 连续未解锁已达 ${max_consec_fails} 次，暂停 ${pause_on_many_fails} 秒后继续重试（IPv6=$current_ipv6）" "$TG_TOKEN" "$TG_CHAT_ID" "$TG_API_BASE" 3
                fi
                rm -f "$COOKIE_CACHE"
                sleep "$pause_on_many_fails"
                fail_count=0
            fi
        else
            log_msg "[IPv6: $current_ipv6] ✅ 目标流媒体已成功解锁 ($status_summary)，${sleep_when_unlocked} 秒后将再次巡检"
            if [[ $fail_count -gt 0 && "$TG_ENABLED" == "yes" ]]; then
                send_telegram_msg "✅ WARP 已成功解锁：IPv6=$current_ipv6 | $status_summary | 时间=$(date '+%F %T')" "$TG_TOKEN" "$TG_CHAT_ID" "$TG_API_BASE" 3
            fi
            fail_count=0
            sleep "$sleep_when_unlocked"
        fi
    done
}

run_keepalive_daemon() {
    local interval="${1:-60}"
    if [[ -f "$KEEPALIVE_CONF" ]]; then
        # shellcheck disable=SC1090
        source "$KEEPALIVE_CONF"
        interval="${KEEPALIVE_INTERVAL:-$interval}"
    fi
    [[ ! "$interval" =~ ^[0-9]+$ || "$interval" -lt 10 ]] && interval=60

    while true; do
        local ip=""
        if ip link show warp >/dev/null 2>&1; then
            ip=$(get_warp_ipv6_ip "--interface warp")
        fi
        if [[ -z "$ip" || "$ip" == "不可用" ]]; then
            echo "$(date '+%F %T') [WARP-MONITOR] 检测到 WARP 接口异常，正在执行重启..."
            wg-quick down warp 2>/dev/null || true
            sleep 2
            wg-quick up warp 2>/dev/null || true
        fi
        sleep "$interval"
    done
}

# --- WireGuard 环境与配置生成辅助函数 ---

# 检测并修复容器/内核的 TUN 与用户态 WireGuard 兼容问题
ensure_wireguard_runtime() {
    # 1. 确保 /dev/net/tun 存在
    if [[ ! -c /dev/net/tun ]]; then
        modprobe tun 2>/dev/null || true
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200 2>/dev/null || true
        chmod 600 /dev/net/tun 2>/dev/null || true
    fi
    if [[ ! -c /dev/net/tun ]]; then
        color_echo yellow "⚠️ 警告：当前系统未开启 TUN 模块 (/dev/net/tun)，若为 OpenVZ/LXC 容器请在宿主机后台开启 TUN/TAP！"
    fi

    # 2. 检查内核是否原生支持 wireguard，不支持则自动补齐 wireguard-go / boringtun
    if ! modprobe wireguard 2>/dev/null; then
        if ip link add dev wg_probe_test type wireguard 2>/dev/null; then
            ip link del dev wg_probe_test 2>/dev/null || true
        elif ! command -v wireguard-go >/dev/null 2>&1 && ! command -v boringtun-cli >/dev/null 2>&1 && ! command -v boringtun >/dev/null 2>&1; then
            color_echo yellow "检测到当前内核不支持原生 WireGuard 模块，正在尝试安装用户态 wireguard-go..."
            if command -v apt-get >/dev/null 2>&1; then
                apt-get install -y wireguard-go 2>/dev/null || true
            elif command -v apk >/dev/null 2>&1; then
                apk add wireguard-go 2>/dev/null || true
            fi
        fi
    fi
}

# 从 wgcf 生成并部署 warp.conf (供安装 [1] 与更新密钥 [12] 复用)
generate_and_deploy_warp_conf() {
    (
        cd "$WGCF_DIR" || exit 1
        rm -f wgcf-profile.conf
        if ! wgcf generate; then
            color_echo red "生成 WireGuard 配置文件失败！"
            exit 1
        fi

        local warp_ipv4
        warp_ipv4=$(grep '^Address' wgcf-profile.conf | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | head -1)
        if [[ -n "$warp_ipv4" ]]; then
            sed -i "s#0\.0\.0\.0/0#${warp_ipv4}#g" wgcf-profile.conf
        fi

        # 安全注释 DNS 行，防止 resolvconf 缺失导致启动崩溃，同时避免劫持云厂商内网 DNS
        sed -i 's/^DNS = /# DNS = /g' wgcf-profile.conf

        wg-quick down warp 2>/dev/null || true
        mv -f wgcf-profile.conf "$WARP_CONF"
        chmod 600 "$WARP_CONF"
    )
}

# --- 菜单功能函数 ---

show_menu() {
    clear
    check_warp_status
    echo "               Cloudflare WARP 管理菜单"
    echo "============================================================"
    echo " [基础管理]"
    echo "  1) 安装/配置 WARP IPv6 (保留本地 IPv4)"
    echo "  2) 手动刷新 WARP 接口 (刷换新 IPv6)"
    echo "  3) 卸载 WARP 接口"
    echo "  4) 卸载管理脚本与 02 快捷命令"
    echo ""
    echo " [流媒体解锁与状态]"
    echo "  5) 一键检测流媒体解锁状态 (Netflix / Disney+ / YouTube)"
    echo "  6) 开启流媒体解锁自动监控 (支持仅NF/仅Disney/双解锁换IP)"
    echo "  7) 停止流媒体解锁自动监控"
    echo "  8) 查看流媒体监控实时运行日志"
    echo ""
    echo " [告警与高级配置]"
    echo "  9) 开启接口异常保活监控 (纯接口连通性自动重启)"
    echo " 10) 停止接口异常保活监控"
    echo " 11) 配置 / 测试 Telegram 告警推送"
    echo " 12) 查看 / 绑定 WARP+ 授权密钥 (License Key)"
    echo " 13) 一键配置 Hysteria2 (hy2) AI 与流媒体分流走 IPv6"
    echo "  r) 立即刷新看板 IP 状态缓存"
    echo ""
    echo "  0) 退出"
    echo "============================================================"
}

# 1. 安装/配置 WARP
install_warp() {
    color_echo green "=== 更新系统包并安装必要依赖 ==="
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        # 避免同时指定互斥的 resolvconf 与 openresolv 引发 apt 冲突
        apt-get install -y curl wget net-tools wireguard-tools jq iproute2
        if ! command -v resolvconf >/dev/null 2>&1; then
            apt-get install -y openresolv 2>/dev/null || apt-get install -y resolvconf 2>/dev/null || true
        fi
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y epel-release 2>/dev/null || true
        dnf install -y curl wget net-tools wireguard-tools jq systemd-resolved iproute
    elif command -v yum >/dev/null 2>&1; then
        yum install -y epel-release 2>/dev/null || true
        yum install -y curl wget net-tools wireguard-tools jq iproute
    elif command -v zypper >/dev/null 2>&1; then
        zypper in -y curl wget net-tools wireguard-tools jq openresolv iproute2
    elif command -v apk >/dev/null 2>&1; then
        apk add curl wget net-tools wireguard-tools jq openresolv iproute2 bash
    else
        color_echo red "无法识别包管理器，请确保系统中已安装: curl, wget, wireguard-tools, jq, iproute2"
    fi

    ensure_wireguard_runtime

    color_echo green "=== 检测 CPU 架构 ==="
    local arch wgcf_arch=""
    arch=$(uname -m)
    case "$arch" in
        x86_64)        wgcf_arch="amd64" ;;
        aarch64|arm64) wgcf_arch="arm64" ;;
        armv7l|armv6l) wgcf_arch="armv7" ;;
        i386|i686)     wgcf_arch="386" ;;
        *) color_echo red "不支持的 CPU 架构: $arch"; read -r -p "按回车返回菜单..."; return ;;
    esac
    echo "检测到架构: $arch -> 匹配 wgcf_${wgcf_arch}"

    color_echo green "=== 获取 wgcf 最新版本并下载 ==="
    local wgcf_ver=""
    wgcf_ver=$(curl -sIL --max-time 6 -o /dev/null -w '%{url_effective}' "https://github.com/ViRb3/wgcf/releases/latest" 2>/dev/null | grep -oE 'v[0-9]+(\.[0-9]+)+' | head -1)
    if [[ -z "$wgcf_ver" ]]; then
        wgcf_ver=$(curl -s --max-time 6 "https://api.github.com/repos/ViRb3/wgcf/releases/latest" 2>/dev/null | jq -r '.tag_name // empty')
    fi
    if [[ -z "$wgcf_ver" ]]; then
        wgcf_ver="v2.2.24"
        color_echo yellow "未能动态获取版本号，使用已知最新稳定版本: $wgcf_ver"
    fi

    local file="wgcf_${wgcf_ver#v}_linux_${wgcf_arch}"
    local url="https://github.com/ViRb3/wgcf/releases/download/${wgcf_ver}/${file}"
    local mirror_url="${MIRROR_PREFIX}${url}"
    local tmp_wgcf="/tmp/wgcf.$$"

    echo "正在下载: $url"
    if ! wget -q --timeout=15 -O "$tmp_wgcf" "$url" 2>/dev/null || [[ ! -s "$tmp_wgcf" ]]; then
        echo "官方源下载超时，正在尝试通过镜像节点加速下载..."
        if ! wget -q --timeout=15 -O "$tmp_wgcf" "$mirror_url" 2>/dev/null || [[ ! -s "$tmp_wgcf" ]]; then
            rm -f "$tmp_wgcf"
            color_echo red "wgcf 下载失败，请检查服务器网络连接。"
            read -r -p "按回车返回菜单..."
            return
        fi
    fi
    chmod +x "$tmp_wgcf"
    mv -f "$tmp_wgcf" /usr/local/bin/wgcf

    color_echo green "=== 注册与配置 WARP 账户 ==="
    mkdir -p "$WGCF_DIR"
    chmod 700 "$WGCF_DIR"

    if [[ -f "./wgcf-account.toml" && ! -f "$WGCF_DIR/wgcf-account.toml" ]]; then
        read -r -p "检测到当前目录存在 wgcf-account.toml，是否直接复用? (Y/n): " reuse_local
        if [[ ! "$reuse_local" =~ ^[Nn]$ ]]; then
            cp -f ./wgcf-account.toml "$WGCF_DIR/"
            chmod 600 "$WGCF_DIR/wgcf-account.toml"
            color_echo green "已复制本地账号配置至 $WGCF_DIR"
        fi
    fi

    if [[ ! -f "$WGCF_DIR/wgcf-account.toml" ]]; then
        echo "正在向 Cloudflare 注册新设备..."
        if ! (cd "$WGCF_DIR" && wgcf register --accept-tos); then
            color_echo red "WARP 账号注册失败！通常是 Cloudflare 对该机房 IP 限制了注册频次 (429 Too Many Requests)。"
            color_echo yellow "💡 解决方案提示："
            color_echo yellow "1. 稍后重新运行菜单 [1] 重试。"
            color_echo yellow "2. 在本地电脑运行 wgcf 注册，将生成的 wgcf-account.toml 上传到 $WGCF_DIR。"
            read -r -p "按回车返回菜单..."
            return
        fi
        chmod 600 "$WGCF_DIR/wgcf-account.toml"
    else
        color_echo green "已存在 WARP 账户配置文件 ($WGCF_DIR/wgcf-account.toml)"
        chmod 600 "$WGCF_DIR/wgcf-account.toml"
    fi

    read -r -p "是否输入 WARP+ License Key 进行绑定升级? (y/N): " use_warp_plus
    if [[ "$use_warp_plus" =~ ^[Yy]$ ]]; then
        read -r -p "请输入你的 WARP+ License Key: " warp_plus_key
        if [[ -n "$warp_plus_key" ]]; then
            cp -f "$WGCF_DIR/wgcf-account.toml" "$WGCF_DIR/wgcf-account.toml.bak"
            sed -i "s#^license_key = .*#license_key = '${warp_plus_key}'#" "$WGCF_DIR/wgcf-account.toml"
            color_echo green "正在向 Cloudflare 同步更新 WARP+ 授权 (wgcf update)..."
            if (cd "$WGCF_DIR" && wgcf update); then
                rm -f "$WGCF_DIR/wgcf-account.toml.bak"
                color_echo green "✅ WARP+ 密钥验证并同步成功！"
            else
                mv -f "$WGCF_DIR/wgcf-account.toml.bak" "$WGCF_DIR/wgcf-account.toml"
                color_echo yellow "⚠️ 密钥同步失败，已自动回滚原账户配置，请核对 License Key 是否准确或设备数是否超限。"
            fi
        fi
    fi

    color_echo green "=== 生成 WireGuard 配置文件（IPv6 走 WARP，IPv4 保留本地原生出口） ==="
    if ! generate_and_deploy_warp_conf; then
        read -r -p "按回车返回菜单..."
        return
    fi

    color_echo green "=== 启用 WireGuard warp 接口 ==="
    if wg-quick up warp; then
        color_echo green "WARP 接口已成功启动！"
    else
        color_echo red "WARP 接口启动失败，请检查系统内核 WireGuard 或 TUN 模块支持。"
    fi

    color_echo green "=== 设置 warp 接口开机自启 ==="
    if is_systemd; then
        systemctl enable wg-quick@warp 2>/dev/null || true
    elif is_openrc; then
        mkdir -p /etc/local.d
        cat > /etc/local.d/warp.start <<'EOF'
#!/bin/sh
wg-quick up warp >/dev/null 2>&1 || true
EOF
        chmod +x /etc/local.d/warp.start
        rc-update add local default 2>/dev/null || true
    fi

    invalidate_status_cache
    sleep 1
    check_warp_status
    read -r -p "按回车返回菜单..."
}

# 2. 手动刷新 WARP 接口并获取新 IP
refresh_warp_ip() {
    color_echo green "=== 正在刷新 WARP 接口以轮换出口 IPv6 ==="
    if ! ip link show warp >/dev/null 2>&1; then
        color_echo yellow "warp 接口当前未运行，尝试启动..."
        wg-quick up warp 2>/dev/null || { color_echo red "启动失败，请先通过选项 [1] 进行安装配置！"; read -r -p "按回车返回菜单..."; return; }
    else
        echo "正在重新连接接口..."
        wg-quick down warp >/dev/null 2>&1 || true
        sleep 2
        wg-quick up warp >/dev/null 2>&1 || { color_echo red "重新连接失败，请检查 /etc/wireguard/warp.conf！"; read -r -p "按回车返回菜单..."; return; }
    fi

    invalidate_status_cache
    sleep 1
    local new_ip
    new_ip=$(get_warp_ipv6_ip "--interface warp")
    color_echo green "已成功重置 WARP 接口，当前新 IPv6: $new_ip"
    echo "------------------------------------------------------------"

    # 并发执行 Netflix 与 Disney+ 测试，大幅缩短等待时间
    local tmp_dir
    tmp_dir=$(mktemp -d 2>/dev/null || echo "/tmp/warp_refresh_$$")
    mkdir -p "$tmp_dir"
    echo "正在并发检测流媒体解锁状态..."
    check_netflix_core "--interface warp" > "$tmp_dir/nf" &
    check_disney_core "--interface warp" > "$tmp_dir/ds" &
    wait

    echo "Netflix 解锁测试: $(cat "$tmp_dir/nf" 2>/dev/null)"
    echo "Disney+ 解锁测试: $(cat "$tmp_dir/ds" 2>/dev/null)"
    rm -rf "$tmp_dir"
    echo "------------------------------------------------------------"
    read -r -p "按回车返回菜单..."
}

# 3. 卸载 WARP 接口
uninstall_warp_interface() {
    color_echo yellow "=== 停止并删除 WARP 接口与相关配置 ==="
    stop_and_remove_service "$SERVICE_NAME" "/usr/local/bin/warp-monitor.sh"
    stop_and_remove_service "$STREAM_SERVICE_NAME" "/usr/local/bin/warp-stream-monitor.sh"

    wg-quick down warp 2>/dev/null || true
    if is_systemd; then
        systemctl disable wg-quick@warp 2>/dev/null || true
    elif is_openrc; then
        rm -f /etc/local.d/warp.start
    fi
    rm -f "$WARP_CONF" "$COOKIE_CACHE" "$KEEPALIVE_CONF"
    rm -rf "$WGCF_DIR"
    invalidate_status_cache
    color_echo green "WARP 网络接口及配置文件已彻底卸载"
    read -r -p "按回车返回菜单..."
}

# 4. 卸载脚本与快捷命令
uninstall_script() {
    color_echo red "=== 卸载脚本和快捷命令 ==="
    stop_and_remove_service "$SERVICE_NAME" "/usr/local/bin/warp-monitor.sh"
    stop_and_remove_service "$STREAM_SERVICE_NAME" "/usr/local/bin/warp-stream-monitor.sh"
    rm -f /usr/local/bin/02
    rm -f /usr/local/bin/warp_manager.sh
    rm -f "$STREAM_CONF" "$KEEPALIVE_CONF" "$COOKIE_CACHE"
    color_echo green "已彻底清理 02 快捷命令、所有守护进程和本地脚本文件"
    exit 0
}

# 5. 一键检测流媒体解锁状态 (三路并发检测)
instant_stream_test() {
    color_echo green "=== 正在进行流媒体全面解锁检测 (通过 IPv6 并发探测) ==="
    local iface_arg=""
    if ip link show warp >/dev/null 2>&1; then
        iface_arg="--interface warp"
        echo "检测方式: 通过 WARP 专用接口 (warp)"
    else
        color_echo yellow "提示：warp 接口未处于活动状态，将直接通过服务器默认 IPv6 路由检测。"
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d 2>/dev/null || echo "/tmp/warp_stream_test_$$")
    mkdir -p "$tmp_dir"

    echo "正在并发探测出口 IPv6 及各大流媒体状态，请稍候..."
    get_warp_ipv6_ip "$iface_arg" > "$tmp_dir/ip" &
    check_netflix_core "$iface_arg" > "$tmp_dir/nf" &
    check_disney_core "$iface_arg" > "$tmp_dir/ds" &
    check_youtube_core "$iface_arg" > "$tmp_dir/yt" &
    wait

    echo -e "出口 IPv6: \033[36m$(cat "$tmp_dir/ip" 2>/dev/null)\033[0m"
    echo "------------------------------------------------------------"
    echo "Netflix 解锁状态: $(cat "$tmp_dir/nf" 2>/dev/null)"
    echo "Disney+ 解锁状态: $(cat "$tmp_dir/ds" 2>/dev/null)"
    echo "YouTube 区域状态: $(cat "$tmp_dir/yt" 2>/dev/null)"
    echo "------------------------------------------------------------"
    rm -rf "$tmp_dir"
    read -r -p "按回车返回菜单..."
}

# 6. 开启流媒体解锁自动监控 (支持仅NF/仅Disney/双解锁)
enable_stream_monitor() {
    color_echo green "=== 开启流媒体解锁监控与自动刷换 IP ==="

    if service_is_active "$SERVICE_NAME"; then
        color_echo yellow "检测到普通接口异常监控 ($SERVICE_NAME) 正在运行。"
        color_echo yellow "为防止双守护进程同时重启接口产生冲突，已自动为您关闭接口异常监控服务。"
        stop_and_remove_service "$SERVICE_NAME" "/usr/local/bin/warp-monitor.sh"
    fi

    echo "请选择监控目标与换 IP 策略:"
    echo " 1) 仅解锁 Netflix (完整解锁，含非自制剧)"
    echo " 2) 仅解锁 Disney+"
    echo " 3) 双解锁 (必须同时解锁 Netflix + Disney+)"
    read -r -p "请输入选项 [1-3, 默认 1]: " unlock_choice
    unlock_choice=${unlock_choice:-1}
    if [[ ! "$unlock_choice" =~ ^[1-3]$ ]]; then
        unlock_choice=1
    fi

    local default_tg="n"
    local default_token=""
    local default_chat_id=""
    local default_api_base="https://api.telegram.org"
    if [[ -f "$STREAM_CONF" ]]; then
        # shellcheck disable=SC1090
        source "$STREAM_CONF"
        if [[ "$TG_ENABLED" == "yes" ]]; then
            default_tg="y"
            default_token="$TG_TOKEN"
            default_chat_id="$TG_CHAT_ID"
            default_api_base="${TG_API_BASE:-https://api.telegram.org}"
        fi
    fi

    read -r -p "是否启用 Telegram 告警推送? (y/N) [当前: ${default_tg}]: " use_tg
    use_tg=${use_tg:-$default_tg}
    local tg_enabled="no"
    local tg_token="$default_token"
    local tg_chat_id="$default_chat_id"
    local tg_api_base="$default_api_base"

    if [[ "$use_tg" =~ ^[Yy]$ ]]; then
        read -r -p "请输入 Telegram Bot Token [默认: $default_token]: " input_token
        tg_token=${input_token:-$default_token}
        read -r -p "请输入 Telegram Chat ID [默认: $default_chat_id]: " input_chat
        tg_chat_id=${input_chat:-$default_chat_id}
        read -r -p "请输入 Telegram API 反代地址 (回车使用官方源: https://api.telegram.org): " input_api
        tg_api_base=${input_api:-$default_api_base}

        if [[ -n "$tg_token" && -n "$tg_chat_id" ]]; then
            tg_enabled="yes"
            read -r -p "是否现在发送一条测试消息检验连通性? (y/N): " test_send
            if [[ "$test_send" =~ ^[Yy]$ ]]; then
                echo "正在向 Telegram 发送测试消息..."
                if send_telegram_msg "🎉 [WARP-STREAM] Telegram 告警测试消息已送达！监控配置生效。" "$tg_token" "$tg_chat_id" "$tg_api_base" 2; then
                    color_echo green "✅ Telegram 测试消息发送成功！"
                else
                    color_echo red "❌ 测试消息发送失败，请检查 Token、Chat ID 或网络是否可直连 Telegram API。"
                fi
            fi
        else
            color_echo yellow "未完整填写 Token 或 Chat ID，Telegram 推送未启用。"
        fi
    fi

    save_stream_conf "$unlock_choice" "$tg_enabled" "$tg_token" "$tg_chat_id" "$tg_api_base"

    # 生成轻量包装脚本，直接调用主脚本内置守护模式（消除代码重复）
    cat > /usr/local/bin/warp-stream-monitor.sh <<'EOF'
#!/bin/bash
exec /usr/local/bin/warp_manager.sh --daemon-stream
EOF
    chmod +x /usr/local/bin/warp-stream-monitor.sh

    install_and_start_service "$STREAM_SERVICE_NAME" "WARP 流媒体解锁检测与自动换IP守护服务" "/usr/local/bin/warp-stream-monitor.sh"

    color_echo green "流媒体解锁监控服务已成功开启并在后台自愈运行！"
    echo "=== 正在打印实时日志（按 Ctrl+C 退出日志查看并返回菜单，监控将继续后台运行） ==="
    follow_service_logs "$STREAM_SERVICE_NAME" 20
}

# 7. 停止流媒体解锁检测
disable_stream_monitor() {
    color_echo yellow "=== 停止流媒体解锁监控 ==="
    stop_and_remove_service "$STREAM_SERVICE_NAME" "/usr/local/bin/warp-stream-monitor.sh"
    color_echo green "流媒体解锁监控服务已停止"
    read -r -p "按回车返回菜单..."
}

# 8. 查看流媒体监控实时运行日志
view_stream_logs() {
    color_echo green "=== 查看流媒体监控实时日志 (按 Ctrl+C 退出查看并返回菜单) ==="
    if ! service_is_active "$STREAM_SERVICE_NAME"; then
        color_echo yellow "注意：流媒体监控服务当前并未运行。"
    fi
    follow_service_logs "$STREAM_SERVICE_NAME" 30
}

# 9. 开启接口异常保活监控
enable_auto_restart() {
    if service_is_active "$STREAM_SERVICE_NAME"; then
        color_echo yellow "检测到流媒体监控服务 ($STREAM_SERVICE_NAME) 正在运行。"
        color_echo yellow "流媒体监控服务已包含接口连通性自愈功能，无需重复启用基础保活。"
        read -r -p "是否仍然强制开启基础保活? (y/N): " force_enable
        if [[ ! "$force_enable" =~ ^[Yy]$ ]]; then
            return
        fi
    fi

    read -r -p "请输入检测间隔（秒，建议 60~300，默认 60）: " interval
    interval=${interval:-60}
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -lt 10 ]]; then
        color_echo red "检测间隔必须是 >=10 的数字"
        read -r -p "按回车返回菜单..."
        return
    fi

    color_echo green "=== 配置接口异常检测并自动重启（间隔 ${interval} 秒） ==="
    mkdir -p /etc/wireguard
    echo "KEEPALIVE_INTERVAL=\"${interval}\"" > "$KEEPALIVE_CONF"
    chmod 600 "$KEEPALIVE_CONF"

    cat > /usr/local/bin/warp-monitor.sh <<EOF
#!/bin/bash
exec /usr/local/bin/warp_manager.sh --daemon-keepalive "${interval}"
EOF
    chmod +x /usr/local/bin/warp-monitor.sh

    install_and_start_service "$SERVICE_NAME" "WARP 接口保活与自动重启守护进程" "/usr/local/bin/warp-monitor.sh"
    color_echo green "接口保活监控已开启，每 ${interval} 秒通过 warp 专用接口检测一次连通性"
    read -r -p "按回车返回菜单..."
}

# 10. 停止自动检测功能
disable_auto_restart() {
    color_echo yellow "=== 停止 WARP 接口异常保活监控 ==="
    stop_and_remove_service "$SERVICE_NAME" "/usr/local/bin/warp-monitor.sh"
    rm -f "$KEEPALIVE_CONF"
    color_echo green "接口保活监控已停止"
    read -r -p "按回车返回菜单..."
}

# 11. 配置 / 测试 Telegram 告警推送
config_telegram() {
    color_echo green "=== 配置 / 测试 Telegram 告警推送 ==="
    local cur_enabled="未配置"
    local cur_token=""
    local cur_chat=""
    local cur_api="https://api.telegram.org"
    local cur_unlock="1"
    if [[ -f "$STREAM_CONF" ]]; then
        # shellcheck disable=SC1090
        source "$STREAM_CONF"
        cur_unlock="${UNLOCK_TARGET:-1}"
        if [[ "$TG_ENABLED" == "yes" ]]; then
            cur_enabled="已启用 ✅"
            cur_token="$TG_TOKEN"
            cur_chat="$TG_CHAT_ID"
            cur_api="${TG_API_BASE:-https://api.telegram.org}"
        else
            cur_enabled="未启用 ❌"
            cur_token="$TG_TOKEN"
            cur_chat="$TG_CHAT_ID"
            cur_api="${TG_API_BASE:-https://api.telegram.org}"
        fi
    fi

    echo "当前推送状态: $cur_enabled"
    echo "当前 Chat ID:  ${cur_chat:-未设置}"
    echo "当前 API 端点: $cur_api"
    echo "------------------------------------------------------------"
    echo "1) 修改 Telegram 推送配置"
    echo "2) 发送一条测试消息"
    echo "3) 关闭 Telegram 推送"
    echo "0) 返回上一级"
    echo "------------------------------------------------------------"
    read -r -p "请选择操作 [0-3]: " tg_op

    case "$tg_op" in
        1)
            read -r -p "请输入 Telegram Bot Token [默认: ${cur_token:-无}]: " new_token
            new_token=${new_token:-$cur_token}
            read -r -p "请输入 Telegram Chat ID [默认: ${cur_chat:-无}]: " new_chat
            new_chat=${new_chat:-$cur_chat}
            read -r -p "请输入 Telegram API 反代地址 (直接回车保持默认: $cur_api): " new_api
            new_api=${new_api:-$cur_api}

            if [[ -z "$new_token" || -z "$new_chat" ]]; then
                color_echo red "Token 与 Chat ID 不能为空！"
                read -r -p "按回车返回..."
                return
            fi

            save_stream_conf "$cur_unlock" "yes" "$new_token" "$new_chat" "$new_api"
            color_echo green "Telegram 推送配置已更新！（运行中的监控守护进程将自动热加载新配置）"
            read -r -p "是否立即测试发信? (y/N): " test_it
            if [[ "$test_it" =~ ^[Yy]$ ]]; then
                if send_telegram_msg "🔔 [WARP 管理工具] Telegram 推送配置测试成功！" "$new_token" "$new_chat" "$new_api" 2; then
                    color_echo green "✅ 测试消息发送成功！"
                else
                    color_echo red "❌ 发送失败，请检查网络端点与凭证。"
                fi
            fi
            read -r -p "按回车返回..."
            ;;
        2)
            if [[ -z "$cur_token" || -z "$cur_chat" ]]; then
                color_echo red "尚未配置 Telegram Token 或 Chat ID，请先选择 [1] 进行配置。"
            else
                echo "正在发送测试消息..."
                if send_telegram_msg "🔔 [WARP 管理工具] Telegram 推送连通性测试消息。" "$cur_token" "$cur_chat" "$cur_api" 2; then
                    color_echo green "✅ 测试消息发送成功！"
                else
                    color_echo red "❌ 测试消息发送失败，请检查网络连接。"
                fi
            fi
            read -r -p "按回车返回..."
            ;;
        3)
            if [[ -f "$STREAM_CONF" ]]; then
                save_stream_conf "$cur_unlock" "no" "$cur_token" "$cur_chat" "$cur_api"
            fi
            color_echo green "已禁用 Telegram 推送通知"
            read -r -p "按回车返回..."
            ;;
        *) return ;;
    esac
}

# 12. 查看 / 绑定 WARP+ 授权密钥 (License Key)
manage_warp_plus() {
    color_echo green "=== 查看 / 绑定 WARP+ 授权密钥 (License Key) ==="
    if [[ ! -f "$WGCF_DIR/wgcf-account.toml" ]]; then
        color_echo red "未找到 $WGCF_DIR/wgcf-account.toml，请先通过菜单 [1] 完成初始化安装！"
        read -r -p "按回车返回菜单..."
        return
    fi

    local cur_license
    cur_license=$(grep '^license_key' "$WGCF_DIR/wgcf-account.toml" | sed -E "s/^license_key *= *['\"]([^'\"]*)['\"].*/\1/")
    echo "当前保存的 License Key: ${cur_license:-未设置或空}"
    echo "------------------------------------------------------------"
    read -r -p "请输入新的 WARP+ License Key (留空取消并返回): " new_license
    if [[ -z "$new_license" ]]; then
        return
    fi

    cp -f "$WGCF_DIR/wgcf-account.toml" "$WGCF_DIR/wgcf-account.toml.bak"
    sed -i "s#^license_key = .*#license_key = '${new_license}'#" "$WGCF_DIR/wgcf-account.toml"
    color_echo green "正在向 Cloudflare 远端同步更新 WARP+ 凭证 (wgcf update)..."
    if (cd "$WGCF_DIR" && wgcf update); then
        rm -f "$WGCF_DIR/wgcf-account.toml.bak"
        color_echo green "✅ WARP+ 凭证验证并更新成功！"
        echo "正在重新生成 WireGuard 配置文件..."
        if generate_and_deploy_warp_conf; then
            wg-quick up warp
            invalidate_status_cache
            color_echo green "WARP+ 配置已生效，接口已完成平滑重载！"
        fi
    else
        mv -f "$WGCF_DIR/wgcf-account.toml.bak" "$WGCF_DIR/wgcf-account.toml"
        color_echo red "❌ Cloudflare 返回错误，已自动回滚原账户配置。请核对 License Key 是否准确或绑定设备数已满。"
    fi
    read -r -p "按回车返回菜单..."
}

# 辅助：清理 Hysteria2 config.yaml 中的旧 outbounds 与 acl 块（并提取非本脚本生成的自定义 ACL 规则）
strip_hy2_outbounds_acl() {
    local conf_file="$1"
    local out_clean="$2"
    local out_custom_acl="$3"

    awk -v custom_out="$out_custom_acl" '
    BEGIN {
        in_block = ""
        in_inline = 0
    }
    /^# === WARP IPv6 分流配置/ { next }
    /^[a-zA-Z0-9_-]+:/ {
        if ($0 ~ /^outbounds:/) {
            in_block = "outbounds"
            in_inline = 0
            next
        } else if ($0 ~ /^acl:/) {
            in_block = "acl"
            in_inline = 0
            next
        } else {
            in_block = ""
            in_inline = 0
        }
    }
    {
        if (in_block == "outbounds") {
            next
        } else if (in_block == "acl") {
            if ($0 ~ /^[ \t]+inline:/) {
                in_inline = 1
                next
            }
            if (in_inline == 1 && $0 ~ /^[ \t]+-[ \t]+/) {
                if ($0 !~ /# \[WARP-/ && $0 !~ /direct\(all\)/ && $0 !~ /default\(all\)/) {
                    print $0 >> custom_out
                }
                next
            }
            if ($0 ~ /^[ \t]+[a-zA-Z0-9_-]+:/) {
                in_inline = 0
            }
            next
        }
        print $0
    }
    ' "$conf_file" > "$out_clean"
}

# 辅助：重启 Hysteria 2 服务并校验状态，若失败则自动回滚配置
restart_and_verify_hy2() {
    local conf_file="$1"
    local bak_file="$2"
    local hy2_svc=""

    for svc in hysteria-server.service hysteria.service hy2.service; do
        if is_systemd && systemctl list-unit-files "$svc" 2>/dev/null | grep -q "${svc%.service}"; then
            hy2_svc="$svc"
            break
        elif [[ -f "/etc/systemd/system/${svc}" || -f "/lib/systemd/system/${svc}" ]]; then
            hy2_svc="$svc"
            break
        fi
    done

    if [[ -n "$hy2_svc" ]] && is_systemd; then
        echo "正在重启 Hysteria 2 服务 ($hy2_svc)..."
        if systemctl restart "$hy2_svc" 2>/dev/null; then
            sleep 1
            if systemctl is-active --quiet "$hy2_svc" 2>/dev/null; then
                color_echo green "✅ Hysteria 2 服务重启成功并正常运行！"
                return 0
            fi
        fi
        color_echo red "❌ Hysteria 2 重启后未能正常运行，正在自动回滚原配置文件..."
        cp -f "$bak_file" "$conf_file"
        systemctl restart "$hy2_svc" 2>/dev/null || true
        color_echo yellow "⚠️ 已恢复至修改前的配置: $conf_file"
        return 1
    elif is_openrc && [[ -f /etc/init.d/hysteria ]]; then
        rc-service hysteria restart 2>/dev/null || true
        color_echo green "✅ 已重启 OpenRC hysteria 服务"
    else
        color_echo yellow "提示：未检测到运行中的 Hysteria 2 systemd 服务，配置文件已写入，请稍后手动重启 Hysteria 2。"
    fi
    return 0
}

# 辅助：下载或更新 Hysteria 2 所需的最新 geosite.dat 规则库
ensure_hy2_geosite() {
    local conf_dir="$1"
    local force_update="${2:-no}"
    local geosite_file="${conf_dir}/geosite.dat"

    if [[ "$force_update" != "yes" && -s "$geosite_file" ]]; then
        return 0
    fi

    echo "正在拉取最新 geosite.dat 规则库 (支持 category-ai-!cn / openai / anthropic / google-gemini)..."
    local tmp_geo="/tmp/geosite.dat.$$"
    local url_loyal="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
    local url_v2fly="https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"

    if curl -fsL --max-time 20 "$url_loyal" -o "$tmp_geo" 2>/dev/null && [[ -s "$tmp_geo" ]]; then
        :
    elif curl -fsL --max-time 20 "${MIRROR_PREFIX}${url_loyal}" -o "$tmp_geo" 2>/dev/null && [[ -s "$tmp_geo" ]]; then
        :
    elif curl -fsL --max-time 20 "$url_v2fly" -o "$tmp_geo" 2>/dev/null && [[ -s "$tmp_geo" ]]; then
        :
    elif curl -fsL --max-time 20 "${MIRROR_PREFIX}${url_v2fly}" -o "$tmp_geo" 2>/dev/null && [[ -s "$tmp_geo" ]]; then
        :
    else
        rm -f "$tmp_geo"
        color_echo yellow "⚠️ 预下载 geosite.dat 超时，将交由 Hysteria 2 启动时自动拉取。"
        return 1
    fi

    mkdir -p "$conf_dir"
    mv -f "$tmp_geo" "$geosite_file"
    chmod 644 "$geosite_file"
    if [[ -d /var/lib/hysteria ]]; then
        cp -f "$geosite_file" /var/lib/hysteria/geosite.dat 2>/dev/null || true
        chmod 644 /var/lib/hysteria/geosite.dat 2>/dev/null || true
    fi
    color_echo green "✅ geosite.dat 规则库已就绪: $geosite_file"
    return 0
}

# 13. 一键配置 Hysteria 2 (hy2) AI 与流媒体分流走 IPv6 (基于 geosite)
config_hy2_ai_routing() {
    color_echo green "=== 一键配置 Hysteria 2 (hy2) AI 与流媒体分流走 IPv6 (GeoSite 模式) ==="
    local hy2_conf
    hy2_conf=$(find_hy2_config)

    if [[ ! -f "$hy2_conf" ]]; then
        color_echo yellow "未在默认位置检测到 Hysteria 2 配置文件 ($hy2_conf)。"
        read -r -p "请输入您的 Hysteria 2 config.yaml 完整路径 (留空返回主菜单): " custom_conf
        if [[ -z "$custom_conf" ]]; then
            return
        fi
        if [[ ! -f "$custom_conf" ]]; then
            color_echo red "错误：找不到文件 $custom_conf"
            read -r -p "按回车返回菜单..."
            return
        fi
        hy2_conf="$custom_conf"
    fi

    local hy2_dir
    hy2_dir=$(dirname "$hy2_conf")

    echo "目标配置文件: $(color_echo cyan "$hy2_conf")"
    if ! ip link show warp >/dev/null 2>&1; then
        color_echo yellow "⚠️ 注意：当前未检测到运行中的 warp 接口，建议先通过菜单 [1] 安装/启动 WARP IPv6。"
    fi
    echo "------------------------------------------------------------"
    echo " 1) 一键开启 AI + 流媒体 (Netflix / 迪士尼 Disney+ / 亚马逊 Prime / YouTube) 走 IPv6 [推荐]"
    echo " 2) 仅开启 AI 平台 (OpenAI / Claude / Gemini / Grok / Perplexity) 分流走 IPv6"
    echo " 3) 仅开启流媒体平台 (Netflix / 迪士尼 Disney+ / 亚马逊 Prime / YouTube) 分流走 IPv6"
    echo " 4) 移除已添加的 Hysteria 2 IPv6 分流规则 (恢复默认直连)"
    echo " 5) 查看当前配置文件中的 outbounds 与 acl 规则"
    echo " 6) 手动更新 geosite.dat 规则库文件"
    echo " 0) 返回主菜单"
    echo "------------------------------------------------------------"
    read -r -p "请选择操作 [0-6, 默认 1]: " hy_op
    hy_op=${hy_op:-1}

    case "$hy_op" in
        1|2|3)
            ensure_hy2_geosite "$hy2_dir" "no"

            local bak_file="${hy2_conf}.bak.$(date +%s)"
            cp -a "$hy2_conf" "$bak_file"

            local tmp_clean="/tmp/hy2_clean.$$"
            local tmp_custom="/tmp/hy2_custom_acl.$$"
            rm -f "$tmp_clean" "$tmp_custom"
            touch "$tmp_custom"

            strip_hy2_outbounds_acl "$hy2_conf" "$tmp_clean" "$tmp_custom"

            # 移除文件末尾多余空行
            sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$tmp_clean" 2>/dev/null || true

            cat >> "$tmp_clean" <<'EOF'

# === WARP IPv6 分流配置 (由 warp_manager 自动维护) ===
outbounds:
  - name: direct
    type: direct
    direct:
      mode: 46
  - name: warp_v6
    type: direct
    direct:
      mode: 6

acl:
EOF
            if [[ -s "${hy2_dir}/geosite.dat" ]]; then
                echo "  geosite: ${hy2_dir}/geosite.dat" >> "$tmp_clean"
            fi
            echo "  inline:" >> "$tmp_clean"

            # 若用户原先有其他非 WARP 自定义 ACL 规则，优先保留在最前面
            if [[ -s "$tmp_custom" ]]; then
                cat "$tmp_custom" >> "$tmp_clean"
            fi

            # 写入 AI 平台分流规则 (选项 1 或 2)
            if [[ "$hy_op" == "1" || "$hy_op" == "2" ]]; then
                cat >> "$tmp_clean" <<'EOF'
    # --- AI 平台分流 (GeoSite: OpenAI / Claude / Gemini / Grok / Perplexity) ---
    - warp_v6(geosite:category-ai-!cn) # [WARP-AI]
    - warp_v6(geosite:openai) # [WARP-AI]
    - warp_v6(geosite:anthropic) # [WARP-AI]
    - warp_v6(geosite:google-gemini) # [WARP-AI]
    - warp_v6(geosite:google-deepmind) # [WARP-AI]
    - warp_v6(geosite:perplexity) # [WARP-AI]
    - warp_v6(geosite:xai) # [WARP-AI]
EOF
            fi

            # 写入流媒体平台分流规则 (选项 1 或 3)
            if [[ "$hy_op" == "1" || "$hy_op" == "3" ]]; then
                cat >> "$tmp_clean" <<'EOF'
    # --- 流媒体分流 (GeoSite: Netflix / 迪士尼 Disney+ / 亚马逊 Prime & Amazon / YouTube) ---
    - warp_v6(geosite:netflix) # [WARP-STREAM]
    - warp_v6(geosite:disney) # [WARP-STREAM]
    - warp_v6(geosite:primevideo) # [WARP-STREAM]
    - warp_v6(geosite:amazon) # [WARP-STREAM]
    - warp_v6(geosite:youtube) # [WARP-STREAM]
EOF
            fi

            cat >> "$tmp_clean" <<'EOF'
    # --- 默认出站 (优先保留原生 IPv4) ---
    - direct(all) # [WARP-DEFAULT]
EOF

            mv -f "$tmp_clean" "$hy2_conf"
            rm -f "$tmp_custom"
            color_echo green "✅ 已成功将 GeoSite IPv6 分流规则写入 $hy2_conf (原配置已备份至 $bak_file)"
            restart_and_verify_hy2 "$hy2_conf" "$bak_file"
            read -r -p "按回车返回菜单..."
            ;;
        4)
            local bak_file="${hy2_conf}.bak.$(date +%s)"
            cp -a "$hy2_conf" "$bak_file"
            local tmp_clean="/tmp/hy2_clean.$$"
            local tmp_custom="/tmp/hy2_custom_acl.$$"
            rm -f "$tmp_clean" "$tmp_custom"
            touch "$tmp_custom"

            strip_hy2_outbounds_acl "$hy2_conf" "$tmp_clean" "$tmp_custom"
            sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$tmp_clean" 2>/dev/null || true

            if [[ -s "$tmp_custom" ]]; then
                cat >> "$tmp_clean" <<'EOF'

acl:
  inline:
EOF
                cat "$tmp_custom" >> "$tmp_clean"
            fi

            mv -f "$tmp_clean" "$hy2_conf"
            rm -f "$tmp_custom"
            color_echo green "✅ 已移除 Hysteria 2 中的 WARP IPv6 分流配置！"
            restart_and_verify_hy2 "$hy2_conf" "$bak_file"
            read -r -p "按回车返回菜单..."
            ;;
        5)
            echo "------------------------------------------------------------"
            if grep -qE '^(outbounds|acl):' "$hy2_conf" 2>/dev/null; then
                awk '/^(outbounds|acl):/{flag=1} /^[a-zA-Z0-9_-]+:/ && $0 !~ /^(outbounds|acl):/{flag=0} flag{print}' "$hy2_conf"
            else
                color_echo yellow "当前 $hy2_conf 中尚未配置 outbounds 或 acl 规则。"
            fi
            echo "------------------------------------------------------------"
            read -r -p "按回车返回菜单..."
            ;;
        6)
            ensure_hy2_geosite "$hy2_dir" "yes"
            local bak_file="${hy2_conf}.bak.$(date +%s)"
            cp -a "$hy2_conf" "$bak_file"
            restart_and_verify_hy2 "$hy2_conf" "$bak_file"
            rm -f "$bak_file"
            read -r -p "按回车返回菜单..."
            ;;
        *) return ;;
    esac
}

# --- 命令行参数入口 (用于内置守护进程或单命令调用) ---

case "${1:-}" in
    --daemon-stream)
        run_stream_daemon
        exit 0
        ;;
    --daemon-keepalive)
        run_keepalive_daemon "${2:-60}"
        exit 0
        ;;
esac

# --- 初始化环境与快捷命令 ---

init_environment() {
    mkdir -p /usr/local/bin
    local script_source="${BASH_SOURCE[0]:-}"
    local installed_path="/usr/local/bin/warp_manager.sh"

    # 若通过本地普通文件执行，直接同步到 /usr/local/bin/warp_manager.sh
    if [[ -n "$script_source" && -f "$script_source" && ! "$script_source" =~ ^/dev/fd/ && ! "$script_source" =~ ^/proc/ ]]; then
        local full_path
        full_path=$(readlink -f "$script_source" 2>/dev/null || echo "$script_source")
        if [[ "$full_path" != "$installed_path" ]]; then
            cp -f "$full_path" "$installed_path" 2>/dev/null || true
            chmod +x "$installed_path" 2>/dev/null || true
        fi
    elif [[ ! -s "$installed_path" ]]; then
        # 若通过 bash <(curl ...) 或 wget -qO- ... | bash 管道运行，自动持久化脚本到 /usr/local/bin
        curl -fsSL --max-time 10 "$SCRIPT_URL" -o "$installed_path" 2>/dev/null || \
        curl -fsSL --max-time 10 "${MIRROR_PREFIX}${SCRIPT_URL}" -o "$installed_path" 2>/dev/null || \
        wget -qO "$installed_path" "$SCRIPT_URL" 2>/dev/null || true
        chmod +x "$installed_path" 2>/dev/null || true
    fi

    if [[ ! -f "/usr/local/bin/02" ]]; then
        cat > /usr/local/bin/02 <<'EOF'
#!/bin/bash
if [ ! -s /usr/local/bin/warp_manager.sh ]; then
    echo "本地未找到 warp_manager.sh，正在自动重新拉取..."
    curl -fsSL "https://raw.githubusercontent.com/geniuszerotwo/warp-unlock/main/warp_manager.sh" -o /usr/local/bin/warp_manager.sh || \
    curl -fsSL "https://ghfast.top/https://raw.githubusercontent.com/geniuszerotwo/warp-unlock/main/warp_manager.sh" -o /usr/local/bin/warp_manager.sh
    chmod +x /usr/local/bin/warp_manager.sh
fi
exec bash /usr/local/bin/warp_manager.sh "$@"
EOF
        chmod +x /usr/local/bin/02 2>/dev/null || true
    fi
}

init_environment

# 兼容管道运行 (如 wget -qO- ... | bash)：将标准输入重定向回终端，防止 read 遇到 EOF 死循环
if [[ ! -t 0 && -e /dev/tty ]]; then
    exec < /dev/tty
fi

# --- 主循环 ---

while true; do
    show_menu
    if ! read -r -p "请选择操作 [0-13 / r]: " choice; then
        echo ""
        exit 0
    fi
    case "$choice" in
        1)  install_warp ;;
        2)  refresh_warp_ip ;;
        3)  uninstall_warp_interface ;;
        4)  uninstall_script ;;
        5)  instant_stream_test ;;
        6)  enable_stream_monitor ;;
        7)  disable_stream_monitor ;;
        8)  view_stream_logs ;;
        9)  enable_auto_restart ;;
        10) disable_auto_restart ;;
        11) config_telegram ;;
        12) manage_warp_plus ;;
        13) config_hy2_ai_routing ;;
        r|R) invalidate_status_cache ;;
        0)  clear; exit 0 ;;
        *)  color_echo red "无效选项，请输入 0 到 13 之间的数字（或输入 r 刷新状态）"; read -r -p "按回车返回菜单..." ;;
    esac
done
