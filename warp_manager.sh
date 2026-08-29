#!/bin/bash
# Cloudflare WARP 管理工具 (Deeply Optimized Version)
# 功能：安装/配置 WARP IPv6（支持 WARP+）、卸载接口、卸载脚本、检测状态、自动检测异常重启、流媒体解锁检测
# 接口名 warp，保留本地 IPv4，自动检测架构，支持开机自启，安装后自动注册 02 命令

# --- 全局变量与常量 ---

# 确保以 root 权限运行
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[31m错误：此脚本需要 root 权限，请使用 sudo bash $0 运行。\033[0m"
    exit 1
fi

SERVICE_NAME="warp-monitor.service"
STREAM_SERVICE_NAME="warp-stream-monitor.service"
SCRIPT_URL="https://raw.githubusercontent.com/geniuszerotwo/warp-unlock/main/warp_manager.sh"
WGCF_DIR="/etc/wireguard/wgcf"
WARP_CONF="/etc/wireguard/warp.conf"
STREAM_CONF="/etc/wireguard/warp_stream.conf"
COOKIE_CACHE="/etc/wireguard/disney_cookies.txt"

# --- 辅助函数 ---

# 输出带颜色的文本
color_echo() {
    local color_map
    declare -A color_map=(
        ["red"]="31"
        ["green"]="32"
        ["yellow"]="33"
        ["blue"]="34"
        ["purple"]="35"
        ["cyan"]="36"
    )
    if [[ -n "${color_map[$1]}" ]]; then
        echo -e "\033[${color_map[$1]}m$2\033[0m"
    else
        echo "$2"
    fi
}

# 检查 systemd 服务状态
check_service_status() {
    local service="$1"
    local name="$2"
    if [[ -z "$service" ]]; then
        echo "$(color_echo yellow "$name: 未配置服务名 ⚠️")"
        return
    fi
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo "$(color_echo green "$name: 运行中 ✅")"
    else
        echo "$(color_echo red "$name: 未运行 ❌")"
    fi
}

# 检查 WARP 状态（优化探测效率，避免超时卡死菜单）
check_warp_status() {
    local status ipv4_info ipv6_info ipv4 ipv6 isp4 isp6 country4 country6
    local svc_name="${SERVICE_NAME:-warp-monitor.service}"
    local stream_svc_name="${STREAM_SERVICE_NAME:-warp-stream-monitor.service}"

    # 检查 WARP 接口
    if ip link show warp >/dev/null 2>&1; then
        status="$(color_echo green "运行中 ✅")"
    else
        status="$(color_echo red "未运行 ❌")"
    fi

    # 检查 jq 是否安装
    if ! command -v jq &> /dev/null; then
        ipv4="$(color_echo yellow "未安装 jq，建议通过菜单 [1] 优先安装")"
        isp4="未知"
        country4="未知"
        ipv6="$(color_echo yellow "未安装 jq")"
        isp6="未知"
        country6="未知"
    else
        # IPv4 检测 (带快速超时)
        ipv4_info=$(curl -4 -s --max-time 3 "http://ip-api.com/json/?fields=query,org,country" 2>/dev/null || echo "")
        if [[ -n "$ipv4_info" && "$ipv4_info" != *"fail"* ]]; then
            ipv4=$(echo "$ipv4_info" | jq -r '.query // "不可用"' 2>/dev/null)
            isp4=$(echo "$ipv4_info" | jq -r '.org // "未知服务商"' 2>/dev/null)
            country4=$(echo "$ipv4_info" | jq -r '.country // "未知地区"' 2>/dev/null)
        else
            # 备选探测
            ipv4=$(curl -4 -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "不可用")
            isp4="未知服务商"
            country4="未知地区"
        fi

        # IPv6 检测（优先尝试 ifconfig.co，备选 ipify）
        ipv6_info=$(curl -6 -s --max-time 3 "https://ifconfig.co/json" 2>/dev/null || echo "")
        if [[ -n "$ipv6_info" && "$ipv6_info" != *"error"* ]]; then
            ipv6=$(echo "$ipv6_info" | jq -r '.ip // "不可用"' 2>/dev/null)
            isp6=$(echo "$ipv6_info" | jq -r '.asn_org // "未知服务商"' 2>/dev/null)
            country6=$(echo "$ipv6_info" | jq -r '.country // "未知地区"' 2>/dev/null)
        else
            ipv6=$(curl -6 -s --max-time 3 https://api64.ipify.org 2>/dev/null || echo "不可用")
            isp6="未知服务商"
            country6="未知地区"
        fi
    fi

    # 输出结果
    echo "============================================================"
    echo " Cloudflare WARP 核心看板: $status"
    echo " 出口 IPv4: $ipv4 ($isp4, $country4)"
    echo " 出口 IPv6: $ipv6 ($isp6, $country6)"
    echo "------------------------------------------------------------"
    check_service_status "$svc_name" " 接口异常保活服务"
    check_service_status "$stream_svc_name" " 流媒体解锁监控服务"
    echo "============================================================"
}

# 流媒体检测核心函数：Netflix 检测（修复重定向地区识别与重复请求）
check_netflix_core() {
    local iface_arg="$1"
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
    local sg_id="81215567"
    local orig_id="80018499"
    local resp_sg resp_orig code_sg code_orig url_sg url_orig region

    # 1. 检查新加坡独占影片 (测试完整解锁)
    resp_sg=$(curl -6 $iface_arg -A "$ua" -sL --max-time 8 -w "%{http_code}\n%{url_effective}" -o /dev/null "https://www.netflix.com/title/${sg_id}" 2>/dev/null)
    code_sg=$(echo "$resp_sg" | sed -n '1p')
    url_sg=$(echo "$resp_sg" | sed -n '2p')

    if [ "$code_sg" = "200" ]; then
        region=$(echo "$url_sg" | sed -nE 's#.*netflix\.com/([a-z]{2})(/.*)?#\1#p' | tr '[:lower:]' '[:upper:]')
        region=${region:-"US"}
        echo "√(完整解锁, $region)"
        return 0
    fi

    # 2. 检查自制剧影片 (测试是否仅自制剧)
    resp_orig=$(curl -6 $iface_arg -A "$ua" -sL --max-time 8 -w "%{http_code}\n%{url_effective}" -o /dev/null "https://www.netflix.com/title/${orig_id}" 2>/dev/null)
    code_orig=$(echo "$resp_orig" | sed -n '1p')
    url_orig=$(echo "$resp_orig" | sed -n '2p')

    if [ "$code_orig" = "200" ]; then
        region=$(echo "$url_orig" | sed -nE 's#.*netflix\.com/([a-z]{2})(/.*)?#\1#p' | tr '[:lower:]' '[:upper:]')
        region=${region:-"US"}
        echo "×(仅自制剧, $region)"
        return 2
    fi

    echo "×(未解锁)"
    return 1
}

# 流媒体检测核心函数：Disney+ 检测
check_disney_core() {
    local iface_arg="$1"
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
    local cache_file="$COOKIE_CACHE"

    mkdir -p /etc/wireguard
    # 缓存 Disney Cookie（带源站与国内镜像双重兜底）
    if [ ! -s "$cache_file" ]; then
        curl -fsL --max-time 10 "https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/cookies" -o "$cache_file" 2>/dev/null || \
        curl -fsL --max-time 10 "https://ghfast.top/https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/cookies" -o "$cache_file" 2>/dev/null
    fi

    if [ ! -s "$cache_file" ]; then
        echo "×(Cookie模版缺失)"
        return 1
    fi

    local pre_assertion assertion pre_cookie disney_cookie token_content is_banned is_403
    local fake_content refresh_token disney_content tmp_result region in_supported

    pre_assertion=$(curl -6 $iface_arg -A "$ua" -fsL --max-time 10 \
        -X POST "https://disney.api.edge.bamgrid.com/devices" \
        -H "authorization: Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" \
        -H "content-type: application/json; charset=UTF-8" \
        -d '{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}' 2>/dev/null)

    assertion=$(echo "$pre_assertion" | jq -r '.assertion // empty' 2>/dev/null)
    if [ -z "$assertion" ]; then
        echo "×(未解锁)"
        return 1
    fi

    pre_cookie=$(sed -n '1p' "$cache_file" 2>/dev/null)
    disney_cookie=$(echo "$pre_cookie" | sed "s/DISNEYASSERTION/$assertion/g")

    token_content=$(curl -6 $iface_arg -A "$ua" -fsL --max-time 10 \
        -X POST "https://disney.api.edge.bamgrid.com/token" \
        -H "authorization: Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" \
        -d "$disney_cookie" 2>/dev/null)

    is_banned=$(echo "$token_content" | grep 'forbidden-location')
    is_403=$(echo "$token_content" | grep '403 ERROR')
    if [ -n "$is_banned$is_403" ]; then
        echo "×(地区限制)"
        return 1
    fi

    fake_content=$(sed -n '8p' "$cache_file" 2>/dev/null)
    refresh_token=$(echo "$token_content" | jq -r '.refresh_token // empty' 2>/dev/null)
    disney_content=$(echo "$fake_content" | sed "s/ILOVEDISNEY/$refresh_token/g")

    tmp_result=$(curl -6 $iface_arg -A "$ua" -fsL --max-time 10 \
        -X POST "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql" \
        -H "authorization: ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" \
        -d "$disney_content" 2>/dev/null)

    region=$(echo "$tmp_result" | jq -r '[.. | .countryCode? | select(type == "string")][0] // empty' 2>/dev/null)
    in_supported=$(echo "$tmp_result" | jq -r '[.. | .inSupportedLocation? | select(type == "boolean")][0] // empty' 2>/dev/null)

    if [[ -n "$region" && "$in_supported" == "true" ]]; then
        echo "√($region)"
        return 0
    else
        echo "×(未解锁)"
        return 1
    fi
}

# 流媒体检测核心函数：YouTube 检测
check_youtube_core() {
    local iface_arg="$1"
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
    local yt_html region

    yt_html=$(curl -6 $iface_arg -A "$ua" -sL --max-time 8 "https://www.youtube.com/premium" 2>/dev/null)
    if echo "$yt_html" | grep -q "Premium is not available in your country"; then
        echo "×(不支持 Premium)"
        return 1
    fi
    region=$(echo "$yt_html" | grep -oE '"countryCode":"[^"]+"' | head -1 | cut -d'"' -f4)
    if [[ -z "$region" ]]; then
        region=$(curl -6 $iface_arg -A "$ua" -sL --max-time 5 "https://www.youtube.com" 2>/dev/null | grep -oE '"GL":"[^"]+"' | head -1 | cut -d'"' -f4)
    fi
    if [[ -n "$region" ]]; then
        echo "√($region)"
        return 0
    else
        echo "√(可用)"
        return 0
    fi
}

# 发送 Telegram 消息辅助函数
send_telegram_msg() {
    local text="$1"
    local token="$2"
    local chat_id="$3"
    local api_base="${4:-https://api.telegram.org}"

    if [[ -z "$token" || -z "$chat_id" ]]; then
        return 1
    fi

    api_base="${api_base%/}"

    local res
    res=$(curl -s -X POST "${api_base}/bot${token}/sendMessage" \
        -d chat_id="${chat_id}" \
        -d text="${text}" \
        --max-time 10 2>/dev/null)

    if echo "$res" | grep -q '"ok":true'; then
        return 0
    else
        return 1
    fi
}

# --- 菜单功能函数 ---

# 显示菜单
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
    echo ""
    echo "  0) 退出"
    echo "============================================================"
}

# 1. 安装/配置 WARP
install_warp() {
    color_echo green "=== 更新系统包并安装必要依赖 ==="
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -y
        sudo apt-get install -y curl wget net-tools wireguard-tools jq resolvconf openresolv iproute2
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y epel-release
        sudo dnf install -y curl wget net-tools wireguard-tools jq systemd-resolved iproute
    elif command -v yum &> /dev/null; then
        sudo yum install -y epel-release
        sudo yum install -y curl wget net-tools wireguard-tools jq iproute
    elif command -v zypper &> /dev/null; then
        sudo zypper in -y curl wget net-tools wireguard-tools jq openresolv iproute2
    elif command -v apk &> /dev/null; then
        sudo apk add curl wget net-tools wireguard-tools jq openresolv iproute2
    else
        color_echo red "无法识别包管理器，请确保系统中已安装: curl, wget, wireguard-tools, jq, resolvconf"
    fi

    color_echo green "=== 检测 CPU 架构 ==="
    local ARCH=$(uname -m)
    local WGCF_ARCH=""
    case "$ARCH" in
        x86_64)        WGCF_ARCH="amd64" ;;
        aarch64|arm64) WGCF_ARCH="arm64" ;;
        armv7l|armv6l) WGCF_ARCH="armv7" ;;
        i386|i686)     WGCF_ARCH="386" ;;
        *) color_echo red "不支持的 CPU 架构: $ARCH"; read -p "按回车返回菜单..."; return ;;
    esac
    echo "检测到架构: $ARCH -> 匹配 wgcf_${WGCF_ARCH}"

    color_echo green "=== 获取 wgcf 最新版本并下载 ==="
    local WGCF_VER=""
    # 策略 1: 解析 GitHub 302 标头获取版本（不受 GitHub API 60次/小时频控限制）
    WGCF_VER=$(curl -sIL -o /dev/null -w '%{url_effective}' https://github.com/ViRb3/wgcf/releases/latest 2>/dev/null | grep -oE 'v[0-9]+(\.[0-9]+)+' | head -1)
    # 策略 2: 若失败则走 GitHub API
    if [[ -z "$WGCF_VER" ]]; then
        WGCF_VER=$(curl -s https://api.github.com/repos/ViRb3/wgcf/releases/latest 2>/dev/null | jq -r '.tag_name // empty')
    fi
    # 策略 3: 官方固定版本保底
    if [[ -z "$WGCF_VER" ]]; then
        WGCF_VER="v2.2.24"
        color_echo yellow "未能动态获取版本号，使用已知最新稳定版本: $WGCF_VER"
    fi

    local FILE="wgcf_${WGCF_VER#v}_linux_${WGCF_ARCH}"
    local URL="https://github.com/ViRb3/wgcf/releases/download/${WGCF_VER}/${FILE}"
    local MIRROR_URL="https://ghfast.top/${URL}"

    echo "正在下载: $URL"
    if ! wget -O wgcf "$URL" 2>/dev/null; then
        echo "官方源下载超时，正在尝试通过镜像节点加速下载..."
        if ! wget -O wgcf "$MIRROR_URL" 2>/dev/null; then
            color_echo red "wgcf 下载失败，请检查服务器网络连接。"
            read -p "按回车返回菜单..."
            return
        fi
    fi
    chmod +x wgcf
    sudo mv wgcf /usr/local/bin/

    color_echo green "=== 注册与配置 WARP 账户 ==="
    sudo mkdir -p "$WGCF_DIR"

    # 如果当前工作目录已有现成的 wgcf-account.toml，提示可直接复用
    if [[ -f "./wgcf-account.toml" && ! -f "$WGCF_DIR/wgcf-account.toml" ]]; then
        read -p "检测到当前目录存在 wgcf-account.toml，是否直接复用? (Y/n): " reuse_local
        if [[ ! "$reuse_local" =~ ^[Nn]$ ]]; then
            sudo cp -f ./wgcf-account.toml "$WGCF_DIR/"
            color_echo green "已复制本地账号配置至 $WGCF_DIR"
        fi
    fi

    pushd "$WGCF_DIR" > /dev/null

    if [ ! -f wgcf-account.toml ]; then
        echo "正在向 Cloudflare 注册新设备..."
        if ! wgcf register --accept-tos; then
            color_echo red "WARP 账号注册失败！通常是 Cloudflare 对该机房 IP 限制了注册频次 (429 Too Many Requests)。"
            color_echo yellow "💡 解决方案提示："
            color_echo yellow "1. 稍后重新运行菜单 [1] 重试。"
            color_echo yellow "2. 在本地电脑运行 wgcf 注册，将生成的 wgcf-account.toml 上传到 $WGCF_DIR。"
            popd > /dev/null
            read -p "按回车返回菜单..."
            return
        fi
    else
        color_echo green "已存在 WARP 账户配置文件 (wgcf-account.toml)"
    fi

    read -p "是否输入 WARP+ License Key 进行绑定升级? (y/N): " use_warp_plus
    if [[ "$use_warp_plus" =~ ^[Yy]$ ]]; then
        read -p "请输入你的 WARP+ License Key: " warp_plus_key
        if [[ -n "$warp_plus_key" ]]; then
            sed -i "s/license_key = .*/license_key = \"$warp_plus_key\"/" wgcf-account.toml
            color_echo green "正在向 Cloudflare 同步更新 WARP+ 授权 (wgcf update)..."
            if wgcf update; then
                color_echo green "✅ WARP+ 密钥验证并同步成功！"
            else
                color_echo yellow "⚠️ 密钥同步返回警告，请核对 License Key 是否准确。"
            fi
        fi
    fi

    color_echo green "=== 生成 WireGuard 配置文件 ==="
    rm -f wgcf-profile.conf
    if ! wgcf generate; then
        color_echo red "生成 WireGuard 配置文件失败！"
        popd > /dev/null
        read -p "按回车返回菜单..."
        return
    fi

    color_echo green "=== 处理配置路由：IPv6 全局走 WARP，IPv4 保留本地原生出口 ==="
    local WARP_IPV4
    WARP_IPV4=$(grep '^Address' wgcf-profile.conf | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | head -1)
    if [[ -n "$WARP_IPV4" ]]; then
        sed -i "s#0\.0\.0\.0/0#${WARP_IPV4}#g" wgcf-profile.conf
    fi

    # 安全注释 DNS 行，防止 resolvconf 缺失导致启动崩溃，同时避免劫持云厂商内网 DNS
    sed -i 's/^DNS = /# DNS = /g' wgcf-profile.conf

    # 停止已有旧接口并部署新配置
    sudo wg-quick down warp 2>/dev/null || true
    sudo mv -f wgcf-profile.conf /etc/wireguard/warp.conf
    popd > /dev/null

    color_echo green "=== 启用 WireGuard warp 接口 ==="
    if sudo wg-quick up warp; then
        color_echo green "WARP 接口已成功启动！"
    else
        color_echo red "WARP 接口启动失败，请检查 WireGuard 模块支持。"
    fi

    color_echo green "=== 设置 warp 接口开机自启 ==="
    sudo systemctl enable wg-quick@warp 2>/dev/null || true

    sleep 2
    check_warp_status
    read -p "按回车返回菜单..."
}

# 2. 手动刷新 WARP 接口并获取新 IP
refresh_warp_ip() {
    color_echo green "=== 正在刷新 WARP 接口以轮换出口 IPv6 ==="
    if ! ip link show warp >/dev/null 2>&1; then
        color_echo yellow "warp 接口当前未运行，尝试启动..."
        sudo wg-quick up warp 2>/dev/null || { color_echo red "启动失败，请先通过选项 [1] 进行安装配置！"; read -p "按回车返回菜单..."; return; }
    else
        echo "正在重新连接接口..."
        sudo wg-quick down warp >/dev/null 2>&1 || true
        sleep 2
        sudo wg-quick up warp >/dev/null 2>&1 || { color_echo red "重新连接失败，请检查 /etc/wireguard/warp.conf！"; read -p "按回车返回菜单..."; return; }
    fi

    sleep 2
    local new_ip
    new_ip=$(curl -6 --interface warp -s --max-time 4 https://ifconfig.co 2>/dev/null || curl -6 --interface warp -s --max-time 4 https://api64.ipify.org 2>/dev/null || echo "不可用")
    color_echo green "已成功重置 WARP 接口，当前新 IPv6: $new_ip"
    echo "------------------------------------------------------------"
    echo -n "Netflix 解锁测试: "
    check_netflix_core "--interface warp"
    echo -n "Disney+ 解锁测试: "
    check_disney_core "--interface warp"
    echo "------------------------------------------------------------"
    read -p "按回车返回菜单..."
}

# 3. 卸载 WARP 接口
uninstall_warp_interface() {
    color_echo yellow "=== 停止并删除 WARP 接口与相关配置 ==="
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl stop "$STREAM_SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$STREAM_SERVICE_NAME" 2>/dev/null || true

    sudo wg-quick down warp 2>/dev/null || true
    sudo systemctl disable wg-quick@warp 2>/dev/null || true
    sudo rm -f /etc/wireguard/warp.conf
    sudo rm -rf "$WGCF_DIR"
    color_echo green "WARP 网络接口及配置文件已彻底卸载"
    read -p "按回车返回菜单..."
}

# 4. 卸载脚本与快捷命令
uninstall_script() {
    color_echo red "=== 卸载脚本和快捷命令 ==="
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl stop "$STREAM_SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$STREAM_SERVICE_NAME" 2>/dev/null || true
    sudo rm -f /etc/systemd/system/"$SERVICE_NAME"
    sudo rm -f /etc/systemd/system/"$STREAM_SERVICE_NAME"
    sudo rm -f /usr/local/bin/warp-monitor.sh
    sudo rm -f /usr/local/bin/warp-stream-monitor.sh
    sudo rm -f /usr/local/bin/02
    sudo rm -f /usr/local/bin/warp_manager.sh
    sudo systemctl daemon-reload
    color_echo green "已彻底清理 02 快捷命令、所有守护进程和本地脚本文件"
    exit 0
}

# 5. 一键检测流媒体解锁状态
instant_stream_test() {
    color_echo green "=== 正在进行流媒体全面解锁检测 (通过 IPv6) ==="
    local iface_arg=""
    if ip link show warp >/dev/null 2>&1; then
        iface_arg="--interface warp"
        echo "检测方式: 通过 WARP 专用接口 (warp)"
    else
        color_echo yellow "提示：warp 接口未处于活动状态，将直接通过服务器默认 IPv6 路由检测。"
    fi

    echo "正在探测出口 IPv6 信息..."
    local ipv6_out
    ipv6_out=$(curl -6 $iface_arg -s --max-time 4 https://ifconfig.co 2>/dev/null || curl -6 $iface_arg -s --max-time 4 https://api64.ipify.org 2>/dev/null || echo "不可用")
    echo -e "出口 IPv6: \033[36m$ipv6_out\033[0m"
    echo "------------------------------------------------------------"

    echo -n "Netflix 解锁状态: "
    local nf_res
    nf_res=$(check_netflix_core "$iface_arg")
    echo "$nf_res"

    echo -n "Disney+ 解锁状态: "
    local ds_res
    ds_res=$(check_disney_core "$iface_arg")
    echo "$ds_res"

    echo -n "YouTube 区域状态: "
    local yt_res
    yt_res=$(check_youtube_core "$iface_arg")
    echo "$yt_res"
    echo "------------------------------------------------------------"
    read -p "按回车返回菜单..."
}

# 6. 开启流媒体解锁自动监控 (支持仅NF/仅Disney/双解锁)
enable_stream_monitor() {
    color_echo green "=== 开启流媒体解锁监控与自动刷换 IP ==="

    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        color_echo yellow "检测到普通接口异常监控 ($SERVICE_NAME) 正在运行。"
        color_echo yellow "为防止双守护进程同时重启接口产生冲突，已自动为您关闭接口异常监控服务。"
        sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    fi

    echo "请选择监控目标与换 IP 策略:"
    echo " 1) 仅解锁 Netflix (完整解锁，含非自制剧)"
    echo " 2) 仅解锁 Disney+"
    echo " 3) 双解锁 (必须同时解锁 Netflix + Disney+)"
    read -p "请输入选项 [1-3, 默认 1]: " unlock_choice
    unlock_choice=${unlock_choice:-1}
    if [[ ! "$unlock_choice" =~ ^[1-3]$ ]]; then
        unlock_choice=1
    fi

    local default_tg="n"
    local default_token=""
    local default_chat_id=""
    local default_api_base="https://api.telegram.org"
    if [[ -f "$STREAM_CONF" ]]; then
        source "$STREAM_CONF"
        if [[ "$TG_ENABLED" == "yes" ]]; then
            default_tg="y"
            default_token="$TG_TOKEN"
            default_chat_id="$TG_CHAT_ID"
            default_api_base="${TG_API_BASE:-https://api.telegram.org}"
        fi
    fi

    read -p "是否启用 Telegram 告警推送? (y/N) [当前: ${default_tg}]: " use_tg
    use_tg=${use_tg:-$default_tg}
    local tg_enabled="no"
    local tg_token="$default_token"
    local tg_chat_id="$default_chat_id"
    local tg_api_base="$default_api_base"

    if [[ "$use_tg" =~ ^[Yy]$ ]]; then
        read -p "请输入 Telegram Bot Token [默认: $default_token]: " input_token
        tg_token=${input_token:-$default_token}
        read -p "请输入 Telegram Chat ID [默认: $default_chat_id]: " input_chat
        tg_chat_id=${input_chat:-$default_chat_id}
        read -p "请输入 Telegram API 反代地址 (回车使用官方源: https://api.telegram.org): " input_api
        tg_api_base=${input_api:-$default_api_base}

        if [[ -n "$tg_token" && -n "$tg_chat_id" ]]; then
            tg_enabled="yes"
            read -p "是否现在发送一条测试消息检验连通性? (y/N): " test_send
            if [[ "$test_send" =~ ^[Yy]$ ]]; then
                echo "正在向 Telegram 发送测试消息..."
                if send_telegram_msg "🎉 [WARP-STREAM] Telegram 告警测试消息已送达！监控配置生效。" "$tg_token" "$tg_chat_id" "$tg_api_base"; then
                    color_echo green "✅ Telegram 测试消息发送成功！"
                else
                    color_echo red "❌ 测试消息发送失败，请检查 Token、Chat ID 或网络是否可直连 Telegram API。"
                fi
            fi
        else
            color_echo yellow "未完整填写 Token 或 Chat ID，Telegram 推送未启用。"
        fi
    fi

    sudo mkdir -p /etc/wireguard
    sudo tee "$STREAM_CONF" > /dev/null <<EOF
UNLOCK_TARGET="${unlock_choice}"
TG_ENABLED="${tg_enabled}"
TG_TOKEN="${tg_token}"
TG_CHAT_ID="${tg_chat_id}"
TG_API_BASE="${tg_api_base}"
EOF

    sudo tee /usr/local/bin/warp-stream-monitor.sh > /dev/null <<'EOF'
#!/bin/bash
IFACE="warp"
UA_Browser="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
NIC="--interface $IFACE"
RETRY_COOLDOWN=10
MAX_CONSEC_FAILS=10
PAUSE_ON_MANY_FAILS=1800
SLEEP_WHEN_UNLOCKED=1800
LOG_PREFIX="[WARP-STREAM]"
COOKIE_CACHE="/etc/wireguard/disney_cookies.txt"
STREAM_CONF="/etc/wireguard/warp_stream.conf"

UNLOCK_TARGET="1"
TG_ENABLED="no"
TG_TOKEN=""
TG_CHAT_ID=""
TG_API_BASE="https://api.telegram.org"

if [[ -f "$STREAM_CONF" ]]; then
    source "$STREAM_CONF"
fi

log() { echo "$(date '+%F %T') ${LOG_PREFIX} $*"; }

tg_send() {
    if [[ "$TG_ENABLED" != "yes" || -z "$TG_TOKEN" || -z "$TG_CHAT_ID" ]]; then
        return 0
    fi
    local text="$1"
    local api="${TG_API_BASE:-https://api.telegram.org}"
    api="${api%/}"
    for i in 1 2 3; do
        curl -s -X POST "${api}/bot${TG_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT_ID}" \
            -d text="${text}" >/dev/null 2>&1 && break
        sleep 1
    done
}

get_ipv6() {
    local ip
    ip=$(curl -6 $NIC -A "$UA_Browser" -fsL --max-time 5 https://ifconfig.co 2>/dev/null || curl -6 $NIC -A "$UA_Browser" -fsL --max-time 5 https://api64.ipify.org 2>/dev/null || echo "不可用")
    echo "$ip"
}

check_warp_ipv6() {
    local ip
    ip=$(get_ipv6)
    if [[ "$ip" == "不可用" || -z "$ip" ]]; then
        log "⚠️ WARP 接口当前 IPv6 不通，正在尝试重置接口..."
        wg-quick down $IFACE >/dev/null 2>&1
        sleep 2
        wg-quick up $IFACE >/dev/null 2>&1
        sleep $RETRY_COOLDOWN
        ip=$(get_ipv6)
        if [[ "$ip" == "不可用" || -z "$ip" ]]; then
            log "❌ 接口重启后仍不可用，进入冷却 ${PAUSE_ON_MANY_FAILS} 秒..."
            sleep $PAUSE_ON_MANY_FAILS
            return 1
        fi
    fi
    return 0
}

check_netflix() {
    local sg_id="81215567"
    local orig_id="80018499"
    local resp_sg resp_orig code_sg code_orig url_sg url_orig region

    resp_sg=$(curl -6 $NIC -A "$UA_Browser" -sL --max-time 8 -w "%{http_code}\n%{url_effective}" -o /dev/null "https://www.netflix.com/title/${sg_id}" 2>/dev/null)
    code_sg=$(echo "$resp_sg" | sed -n '1p')
    url_sg=$(echo "$resp_sg" | sed -n '2p')

    if [ "$code_sg" = "200" ]; then
        region=$(echo "$url_sg" | sed -nE 's#.*netflix\.com/([a-z]{2})(/.*)?#\1#p' | tr '[:lower:]' '[:upper:]')
        region=${region:-"US"}
        echo "√(完整, $region)"
        return 0
    fi

    resp_orig=$(curl -6 $NIC -A "$UA_Browser" -sL --max-time 8 -w "%{http_code}\n%{url_effective}" -o /dev/null "https://www.netflix.com/title/${orig_id}" 2>/dev/null)
    code_orig=$(echo "$resp_orig" | sed -n '1p')
    url_orig=$(echo "$resp_orig" | sed -n '2p')

    if [ "$code_orig" = "200" ]; then
        region=$(echo "$url_orig" | sed -nE 's#.*netflix\.com/([a-z]{2})(/.*)?#\1#p' | tr '[:lower:]' '[:upper:]')
        region=${region:-"US"}
        echo "×(仅自制剧, $region)"
        return 2
    fi

    echo "×"
    return 1
}

check_disney() {
    if [ ! -s "$COOKIE_CACHE" ]; then
        curl -fsL --max-time 10 "https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/cookies" -o "$COOKIE_CACHE" 2>/dev/null || \
        curl -fsL --max-time 10 "https://ghfast.top/https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/cookies" -o "$COOKIE_CACHE" 2>/dev/null
    fi

    if [ ! -s "$COOKIE_CACHE" ]; then
        echo "×"
        return 1
    fi

    local pre_assertion assertion pre_cookie disney_cookie token_content is_banned is_403
    local fake_content refresh_token disney_content tmp_result region in_supported

    pre_assertion=$(curl -6 $NIC -A "$UA_Browser" -fsL --max-time 10 \
        -X POST "https://disney.api.edge.bamgrid.com/devices" \
        -H "authorization: Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" \
        -H "content-type: application/json; charset=UTF-8" \
        -d '{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}' 2>/dev/null)

    assertion=$(echo "$pre_assertion" | jq -r '.assertion // empty' 2>/dev/null)
    if [ -z "$assertion" ]; then
        echo "×"
        return 1
    fi

    pre_cookie=$(sed -n '1p' "$COOKIE_CACHE" 2>/dev/null)
    disney_cookie=$(echo "$pre_cookie" | sed "s/DISNEYASSERTION/$assertion/g")

    token_content=$(curl -6 $NIC -A "$UA_Browser" -fsL --max-time 10 \
        -X POST "https://disney.api.edge.bamgrid.com/token" \
        -H "authorization: Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" \
        -d "$disney_cookie" 2>/dev/null)

    is_banned=$(echo "$token_content" | grep 'forbidden-location')
    is_403=$(echo "$token_content" | grep '403 ERROR')
    if [ -n "$is_banned$is_403" ]; then
        echo "×"
        return 1
    fi

    fake_content=$(sed -n '8p' "$COOKIE_CACHE" 2>/dev/null)
    refresh_token=$(echo "$token_content" | jq -r '.refresh_token // empty' 2>/dev/null)
    disney_content=$(echo "$fake_content" | sed "s/ILOVEDISNEY/$refresh_token/g")

    tmp_result=$(curl -6 $NIC -A "$UA_Browser" -fsL --max-time 10 \
        -X POST "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql" \
        -H "authorization: ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" \
        -d "$disney_content" 2>/dev/null)

    region=$(echo "$tmp_result" | jq -r '[.. | .countryCode? | select(type == "string")][0] // empty' 2>/dev/null)
    in_supported=$(echo "$tmp_result" | jq -r '[.. | .inSupportedLocation? | select(type == "boolean")][0] // empty' 2>/dev/null)

    if [[ -n "$region" && "$in_supported" == "true" ]]; then
        echo "√($region)"
        return 0
    else
        echo "×"
        return 1
    fi
}

fail_count=0
while true; do
    if ! check_warp_ipv6; then
        continue
    fi

    ipv6=$(get_ipv6)
    target_unlocked=0
    status_summary=""

    if [ "$UNLOCK_TARGET" = "1" ]; then
        # 仅 Netflix
        nf_status=$(check_netflix)
        nf_ok=$?
        status_summary="Netflix: $nf_status"
        if [ $nf_ok -eq 0 ]; then target_unlocked=1; fi
    elif [ "$UNLOCK_TARGET" = "2" ]; then
        # 仅 Disney+
        ds_status=$(check_disney)
        ds_ok=$?
        status_summary="Disney+: $ds_status"
        if [ $ds_ok -eq 0 ]; then target_unlocked=1; fi
    else
        # 双解锁
        nf_status=$(check_netflix)
        nf_ok=$?
        ds_status=$(check_disney)
        ds_ok=$?
        status_summary="Netflix: $nf_status, Disney+: $ds_status"
        if [ $nf_ok -eq 0 ] && [ $ds_ok -eq 0 ]; then target_unlocked=1; fi
    fi

    if [ $target_unlocked -eq 0 ]; then
        ((fail_count++))
        log "[IPv6: $ipv6] ❌ 未满足解锁要求 ($status_summary)，第 $fail_count 次未命中 → 正在刷新 WARP 接口换 IP..."
        if [ "$fail_count" -eq 1 ]; then
            tg_send "⚠️ WARP 未解锁：IPv6=$ipv6 | $status_summary | 时间=$(date '+%F %T')"
        fi
        wg-quick down $IFACE >/dev/null 2>&1
        sleep 2
        wg-quick up $IFACE >/dev/null 2>&1
        sleep $RETRY_COOLDOWN

        if [ "$fail_count" -ge "$MAX_CONSEC_FAILS" ]; then
            log "⚠️ 连续换 IP 达到 ${MAX_CONSEC_FAILS} 次未命中目标，进入冷却 ${PAUSE_ON_MANY_FAILS} 秒..."
            tg_send "🚨 WARP 连续未解锁已达 ${MAX_CONSEC_FAILS} 次，暂停 ${PAUSE_ON_MANY_FAILS} 秒后继续重试（IPv6=$ipv6）"
            rm -f "$COOKIE_CACHE"
            sleep $PAUSE_ON_MANY_FAILS
            fail_count=0
        fi
    else
        log "[IPv6: $ipv6] ✅ 目标流媒体已成功解锁 ($status_summary)，${SLEEP_WHEN_UNLOCKED} 秒后将再次巡检"
        if [ $fail_count -gt 0 ]; then
            tg_send "✅ WARP 已成功解锁：IPv6=$ipv6 | $status_summary | 时间=$(date '+%F %T')"
        fi
        fail_count=0
        sleep $SLEEP_WHEN_UNLOCKED
    fi
done
EOF
    sudo chmod +x /usr/local/bin/warp-stream-monitor.sh

    sudo tee /etc/systemd/system/$STREAM_SERVICE_NAME > /dev/null <<EOF
[Unit]
Description=WARP 流媒体解锁检测与自动换IP守护服务
After=network.target network-online.target

[Service]
ExecStart=/usr/local/bin/warp-stream-monitor.sh
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now $STREAM_SERVICE_NAME

    color_echo green "流媒体解锁监控服务已成功开启并在后台自愈运行！"
    echo "=== 正在打印实时日志（按 Ctrl+C 退出日志流，监控将继续后台运行） ==="
    sudo journalctl -u $STREAM_SERVICE_NAME -f -n 20
}

# 7. 停止流媒体解锁检测
disable_stream_monitor() {
    color_echo yellow "=== 停止流媒体解锁监控 ==="
    sudo systemctl stop $STREAM_SERVICE_NAME 2>/dev/null || true
    sudo systemctl disable $STREAM_SERVICE_NAME 2>/dev/null || true
    sudo rm -f /etc/systemd/system/$STREAM_SERVICE_NAME
    sudo rm -f /usr/local/bin/warp-stream-monitor.sh
    sudo systemctl daemon-reload
    color_echo green "流媒体解锁监控服务已停止"
    read -p "按回车返回菜单..."
}

# 8. 查看流媒体监控实时运行日志
view_stream_logs() {
    color_echo green "=== 查看流媒体监控实时日志 (Ctrl+C 退出查看) ==="
    if ! systemctl is-active --quiet "$STREAM_SERVICE_NAME" 2>/dev/null; then
        color_echo yellow "注意：流媒体监控服务当前并未运行。"
    fi
    sudo journalctl -u "$STREAM_SERVICE_NAME" -f -n 30
}

# 9. 开启接口异常保活监控
enable_auto_restart() {
    if systemctl is-active --quiet "$STREAM_SERVICE_NAME" 2>/dev/null; then
        color_echo yellow "检测到流媒体监控服务 ($STREAM_SERVICE_NAME) 正在运行。"
        color_echo yellow "流媒体监控服务已包含接口连通性自愈功能，无需重复启用基础保活。"
        read -p "是否仍然强制开启基础保活? (y/N): " force_enable
        if [[ ! "$force_enable" =~ ^[Yy]$ ]]; then
            return
        fi
    fi

    read -p "请输入检测间隔（秒，建议 60~300）: " interval
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 10 ]; then
        color_echo red "检测间隔必须是 >=10 的数字"
        read -p "按回车返回菜单..."
        return
    fi

    color_echo green "=== 配置接口异常检测并自动重启（间隔 ${interval} 秒） ==="
    sudo tee /usr/local/bin/warp-monitor.sh > /dev/null <<EOF
#!/bin/bash
while true; do
    if ! ip link show warp >/dev/null 2>&1 || ! curl -6 -s --max-time 5 https://ifconfig.co >/dev/null 2>&1; then
        echo "\$(date '+%F %T') [WARP-MONITOR] 检测到 WARP 接口异常，正在执行重启..."
        wg-quick down warp 2>/dev/null || true
        sleep 2
        wg-quick up warp
    fi
    sleep ${interval}
done
EOF
    sudo chmod +x /usr/local/bin/warp-monitor.sh

    sudo tee /etc/systemd/system/$SERVICE_NAME > /dev/null <<EOF
[Unit]
Description=WARP 接口保活与自动重启守护进程
After=network.target network-online.target

[Service]
ExecStart=/usr/local/bin/warp-monitor.sh
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now $SERVICE_NAME
    color_echo green "接口保活监控已开启，每 ${interval} 秒检测一次 WARP 状态"
    read -p "按回车返回菜单..."
}

# 10. 停止自动检测功能
disable_auto_restart() {
    color_echo yellow "=== 停止 WARP 接口异常保活监控 ==="
    sudo systemctl stop $SERVICE_NAME 2>/dev/null || true
    sudo systemctl disable $SERVICE_NAME 2>/dev/null || true
    sudo rm -f /etc/systemd/system/$SERVICE_NAME
    sudo rm -f /usr/local/bin/warp-monitor.sh
    sudo systemctl daemon-reload
    color_echo green "接口保活监控已停止"
    read -p "按回车返回菜单..."
}

# 11. 配置 / 测试 Telegram 告警推送
config_telegram() {
    color_echo green "=== 配置 / 测试 Telegram 告警推送 ==="
    local cur_enabled="未配置"
    local cur_token=""
    local cur_chat=""
    local cur_api="https://api.telegram.org"
    if [[ -f "$STREAM_CONF" ]]; then
        source "$STREAM_CONF"
        if [[ "$TG_ENABLED" == "yes" ]]; then
            cur_enabled="已启用 ✅"
            cur_token="$TG_TOKEN"
            cur_chat="$TG_CHAT_ID"
            cur_api="${TG_API_BASE:-https://api.telegram.org}"
        else
            cur_enabled="未启用 ❌"
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
    read -p "请选择操作 [0-3]: " tg_op

    case "$tg_op" in
        1)
            read -p "请输入 Telegram Bot Token: " new_token
            read -p "请输入 Telegram Chat ID: " new_chat
            read -p "请输入 Telegram API 反代地址 (直接回车保持默认: https://api.telegram.org): " new_api
            new_api=${new_api:-https://api.telegram.org}

            if [[ -z "$new_token" || -z "$new_chat" ]]; then
                color_echo red "Token 与 Chat ID 不能为空！"
                read -p "按回车返回..."
                return
            fi

            sudo mkdir -p /etc/wireguard
            local unlock_val="1"
            if [[ -f "$STREAM_CONF" ]]; then
                source "$STREAM_CONF"
                unlock_val="${UNLOCK_TARGET:-1}"
            fi

            sudo tee "$STREAM_CONF" > /dev/null <<EOF
UNLOCK_TARGET="${unlock_val}"
TG_ENABLED="yes"
TG_TOKEN="${new_token}"
TG_CHAT_ID="${new_chat}"
TG_API_BASE="${new_api}"
EOF
            color_echo green "Telegram 推送配置已更新！"
            read -p "是否立即测试发信? (y/N): " test_it
            if [[ "$test_it" =~ ^[Yy]$ ]]; then
                if send_telegram_msg "🔔 [WARP 管理工具] Telegram 推送配置测试成功！" "$new_token" "$new_chat" "$new_api"; then
                    color_echo green "✅ 测试消息发送成功！"
                else
                    color_echo red "❌ 发送失败，请检查网络端点与凭证。"
                fi
            fi
            read -p "按回车返回..."
            ;;
        2)
            if [[ -z "$cur_token" || -z "$cur_chat" ]]; then
                color_echo red "尚未配置 Telegram Token 或 Chat ID，请先进行配置。"
            else
                echo "正在发送测试消息..."
                if send_telegram_msg "🔔 [WARP 管理工具] Telegram 推送连通性测试消息。" "$cur_token" "$cur_chat" "$cur_api"; then
                    color_echo green "✅ 测试消息发送成功！"
                else
                    color_echo red "❌ 测试消息发送失败，请检查网络连接。"
                fi
            fi
            read -p "按回车返回..."
            ;;
        3)
            if [[ -f "$STREAM_CONF" ]]; then
                sed -i 's/^TG_ENABLED=.*/TG_ENABLED="no"/' "$STREAM_CONF"
            fi
            color_echo green "已禁用 Telegram 推送通知"
            read -p "按回车返回..."
            ;;
        *) return ;;
    esac
}

# 12. 查看 / 绑定 WARP+ 授权密钥 (License Key)
manage_warp_plus() {
    color_echo green "=== 查看 / 绑定 WARP+ 授权密钥 (License Key) ==="
    if [ ! -f "$WGCF_DIR/wgcf-account.toml" ]; then
        color_echo red "未找到 $WGCF_DIR/wgcf-account.toml，请先通过菜单 [1] 完成初始化安装！"
        read -p "按回车返回菜单..."
        return
    fi

    local cur_license
    cur_license=$(grep '^license_key' "$WGCF_DIR/wgcf-account.toml" | awk -F '"' '{print $2}')
    echo "当前保存的 License Key: ${cur_license:-"未设置或空"}"
    echo "------------------------------------------------------------"
    read -p "请输入新的 WARP+ License Key (留空取消并返回): " new_license
    if [[ -z "$new_license" ]]; then
        return
    fi

    pushd "$WGCF_DIR" > /dev/null
    sed -i "s/license_key = .*/license_key = \"$new_license\"/" wgcf-account.toml
    color_echo green "正在向 Cloudflare 远端同步更新 WARP+ 凭证 (wgcf update)..."
    if wgcf update; then
        color_echo green "✅ WARP+ 凭证验证并更新成功！"
        echo "正在重新生成 WireGuard 配置文件..."
        rm -f wgcf-profile.conf
        if wgcf generate; then
            local WARP_IPV4
            WARP_IPV4=$(grep '^Address' wgcf-profile.conf | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | head -1)
            if [[ -n "$WARP_IPV4" ]]; then
                sed -i "s#0\.0\.0\.0/0#${WARP_IPV4}#g" wgcf-profile.conf
            fi
            sed -i 's/^DNS = /# DNS = /g' wgcf-profile.conf

            sudo wg-quick down warp 2>/dev/null || true
            sudo mv -f wgcf-profile.conf /etc/wireguard/warp.conf
            sudo wg-quick up warp
            color_echo green "WARP+ 配置已生效，接口已完成平滑重载！"
        fi
    else
        color_echo red "❌ Cloudflare 返回错误，更新失败。请核对 License Key 是否准确。"
    fi
    popd > /dev/null
    read -p "按回车返回菜单..."
}

# --- 初始化环境与快捷命令 ---

init_environment() {
    local script_source="${BASH_SOURCE[0]}"
    if [[ -f "$script_source" ]]; then
        local full_path
        full_path=$(readlink -f "$script_source" 2>/dev/null || echo "$script_source")
        if [[ "$full_path" != "/usr/local/bin/warp_manager.sh" && -d "/usr/local/bin" ]]; then
            sudo cp -f "$full_path" /usr/local/bin/warp_manager.sh 2>/dev/null || true
            sudo chmod +x /usr/local/bin/warp_manager.sh 2>/dev/null || true
        fi
    fi

    if [[ -d "/usr/local/bin" && ! -f "/usr/local/bin/02" ]]; then
        sudo tee /usr/local/bin/02 > /dev/null <<'EOF'
#!/bin/bash
if [ ! -f /usr/local/bin/warp_manager.sh ]; then
    echo "本地未找到 warp_manager.sh，正在自动重新拉取..."
    curl -fsSL "https://raw.githubusercontent.com/geniuszerotwo/warp-unlock/main/warp_manager.sh" -o /usr/local/bin/warp_manager.sh
    chmod +x /usr/local/bin/warp_manager.sh
fi
bash /usr/local/bin/warp_manager.sh
EOF
        sudo chmod +x /usr/local/bin/02 2>/dev/null || true
    fi
}

init_environment

# --- 主循环 ---

while true; do
    show_menu
    read -p "请选择操作 [0-12]: " choice
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
        0)  clear; exit 0 ;;
        *)  color_echo red "无效选项，请输入 0 到 12 之间的数字"; read -p "按回车返回菜单..." ;;
    esac
done
