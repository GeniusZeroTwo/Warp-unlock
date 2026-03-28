#!/bin/bash
# Cloudflare WARP 管理工具
# 功能：安装/配置 WARP IPv6（支持 WARP+）、卸载接口、卸载脚本、检测状态、自动检测异常重启、流媒体解锁检测
# 接口名 warp，保留本地 IPv4，自动检测架构，支持开机自启，安装后自动注册 02 命令

# --- 全局变量与常量 ---
# 标准 WARP 监控服务名
SERVICE_NAME="warp-monitor.service"
# 流媒体解锁监控服务名
STREAM_SERVICE_NAME="warp-stream-monitor.service"
# 统一设置 Netflix 新加坡独占影片 ID
# 注意：此ID可能会随时间失效，建议定期检查
NETFLIX_SG_ID="81215567"

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

# 检查 systemd 服务状态（内置，避免未定义报错）
check_service_status() {
    local service="$1"
    local name="$2"
    if [[ -z "$service" ]]; then
        echo "$(color_echo yellow "$name: 未配置服务名 ⚠️")"
        return
    fi
    if systemctl is-active --quiet "$service"; then
        echo "$(color_echo green "$name: 运行中 ✅")"
    else
        echo "$(color_echo red "$name: 未运行 ❌")"
    fi
}

# 检查 WARP 状态
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

    # IPv4 检测
    ipv4_info=$(curl -4 -s --max-time 5 "http://ip-api.com/json/?fields=query,org,country" || echo "")
    if [[ -n "$ipv4_info" && "$ipv4_info" != *"fail"* ]]; then
        ipv4=$(echo "$ipv4_info" | jq -r '.query // "不可用"')
        isp4=$(echo "$ipv4_info" | jq -r '.org // "未知服务商"')
        country4=$(echo "$ipv4_info" | jq -r '.country // "未知地区"')
    else
        ipv4="不可用"
        isp4="未知服务商"
        country4="未知地区"
    fi

    # IPv6 检测（自动切换 API）
    ipv6_info=$(curl -6 -s --max-time 5 "http://ip-api.com/json/?fields=query,org,country" || echo "")
    if [[ -n "$ipv6_info" && "$ipv6_info" != *"fail"* ]]; then
        ipv6=$(echo "$ipv6_info" | jq -r '.query // "不可用"')
        isp6=$(echo "$ipv6_info" | jq -r '.org // "未知服务商"')
        country6=$(echo "$ipv6_info" | jq -r '.country // "未知地区"')
    else
        ipv6_info=$(curl -6 -s --max-time 5 "https://ifconfig.co/json" || echo "")
        if [[ -n "$ipv6_info" && "$ipv6_info" != *"error"* ]]; then
            ipv6=$(echo "$ipv6_info" | jq -r '.ip // "不可用"')
            isp6=$(echo "$ipv6_info" | jq -r '.asn_org // "未知服务商"')
            country6=$(echo "$ipv6_info" | jq -r '.country // "未知地区"')
        else
            ipv6="不可用"
            isp6="未知服务商"
            country6="未知地区"
        fi
    fi

    # 输出结果
    echo "=== WARP 状态: $status ==="
    echo "出口 IPv4: $ipv4 ($isp4, $country4)"
    echo "出口 IPv6: $ipv6 ($isp6, $country6)"
    echo "------------------------------"
    check_service_status "$svc_name" "接口异常检测服务"
    check_service_status "$stream_svc_name" "流媒体解锁检测服务"
    echo "=============================="
}



# --- 菜单功能函数 ---

# 显示菜单
show_menu() {
    clear
    check_warp_status
    echo "    Cloudflare WARP 管理菜单"
    echo "=============================="
    echo "1) 安装/配置 WARP IPv6"
    echo "2) 卸载 WARP 接口"
    echo "3) 卸载脚本和快捷命令"
    echo "4) 检测 WARP 状态"
    echo "5) 开启检测接口异常并自动重启"
    echo "6) 停止自动检测功能"
    echo "7) 开启流媒体解锁检测（Netflix & Disney+）"
    echo "8) 停止流媒体解锁检测"
    echo "0) 退出"
    echo "=============================="
}

# 安装/配置 WARP
install_warp() {
    color_echo green "=== 更新系统并安装依赖 ==="
    sudo apt update && sudo apt install -y curl wget net-tools wireguard-tools

    color_echo green "=== 检测 CPU 架构 ==="
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)      WGCF_ARCH="amd64" ;;
        aarch64|arm64) WGCF_ARCH="arm64" ;;
        armv7l|armv6l) WGCF_ARCH="armv7" ;;
        i386|i686)   WGCF_ARCH="386" ;;
        *) color_echo red "不支持的架构: $ARCH"; read -p "按回车返回菜单..."; return ;;
    esac
    echo "检测到架构: $ARCH -> 下载 wgcf_${WGCF_ARCH}"

    color_echo green "=== 获取 wgcf 最新版本并下载 ==="
    WGCF_VER=$(curl -s https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep tag_name | cut -d '"' -f4)
    FILE="wgcf_${WGCF_VER#v}_linux_${WGCF_ARCH}"
    URL="https://github.com/ViRb3/wgcf/releases/download/${WGCF_VER}/${FILE}"
    echo "正在下载 $URL"
    if ! wget -O wgcf "$URL"; then
        color_echo red "下载失败，请检查网络或稍后重试。"
        read -p "按回车返回菜单..."
        return
    fi
    chmod +x wgcf
    sudo mv wgcf /usr/local/bin/

    color_echo green "=== 注册 WARP 账户 ==="
    if [ ! -f wgcf-account.toml ]; then
        wgcf register --accept-tos
    fi

    read -p "是否输入 WARP+ License Key? (y/N): " use_warp_plus
    if [[ "$use_warp_plus" =~ ^[Yy]$ ]]; then
        read -p "请输入你的 WARP+ License Key: " warp_plus_key
        sed -i "s/license_key = .*/license_key = \"$warp_plus_key\"/" wgcf-account.toml
        color_echo green "已写入 WARP+ 授权密钥"
    fi

    color_echo green "=== 生成 WireGuard 配置文件 ==="
    wgcf generate

    color_echo green "=== 修改配置文件：IPv6 全局走 WARP，IPv4 保留本地出口 ==="
    WARP_IPV4=$(grep '^Address' wgcf-profile.conf | grep -oP '\d+\.\d+\.\d+\.\d+/\d+')
    sed -i "s#0\.0\.0\.0/0#${WARP_IPV4}#g" wgcf-profile.conf
    sudo mv wgcf-profile.conf /etc/wireguard/warp.conf

    color_echo green "=== 启用 WireGuard 接口 warp ==="
    sudo wg-quick up warp

    color_echo green "=== 设置 warp 接口开机自启 ==="
    sudo systemctl enable wg-quick@warp

    check_warp_status
    read -p "按回车返回菜单..."
}

# 卸载 WARP 接口
uninstall_warp_interface() {
    color_echo yellow "=== 停止并删除 WARP 接口 ==="
    sudo wg-quick down warp 2>/dev/null || true
    sudo systemctl disable wg-quick@warp 2>/dev/null || true
    sudo rm -f /etc/wireguard/warp.conf
    sudo rm -f wgcf-account.toml wgcf-profile.conf
    color_echo green "WARP 接口已卸载"
    read -p "按回车返回菜单..."
}

# 卸载脚本
uninstall_script() {
    color_echo red "=== 卸载脚本和快捷命令 ==="
    sudo rm -f /usr/local/bin/02
    color_echo green "已删除 02 快捷命令"
    echo "请手动删除此脚本文件。"
    read -p "按回车返回菜单..."
}

# 开启自动检测并重启（接口异常）
enable_auto_restart() {
    read -p "请输入检测间隔（秒，建议 60~300）: " interval
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 10 ]; then
        color_echo red "检测间隔必须是 >=10 的数字"
        read -p "按回车返回菜单..."
        return
    fi

    color_echo green "=== 开启 WARP 接口异常检测并自动重启（间隔 ${interval} 秒） ==="
    sudo bash -c "cat > /usr/local/bin/warp-monitor.sh" <<EOF
#!/bin/bash
while true; do
    if ! ip link show warp >/dev/null 2>&1 || ! curl -6 -s --max-time 5 https://ip.gs >/dev/null; then
        echo "\$(date) 检测到 WARP 异常，正在重启接口..."
        wg-quick down warp 2>/dev/null
        wg-quick up warp
    fi
    sleep ${interval}
done
EOF
    sudo chmod +x /usr/local/bin/warp-monitor.sh

    sudo bash -c "cat > /etc/systemd/system/$SERVICE_NAME" <<EOF
[Unit]
Description=WARP 接口监控与自动重启
After=network.target

[Service]
ExecStart=/usr/local/bin/warp-monitor.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now $SERVICE_NAME
    color_echo green "自动检测功能已开启，每 ${interval} 秒检测一次 WARP 状态"
    read -p "按回车返回菜单..."
}

# 停止自动检测
disable_auto_restart() {
    color_echo yellow "=== 停止 WARP 接口异常检测 ==="
    sudo systemctl disable --now $SERVICE_NAME 2>/dev/null || true
    sudo rm -f /etc/systemd/system/$SERVICE_NAME
    sudo rm -f /usr/local/bin/warp-monitor.sh
    sudo systemctl daemon-reload
    color_echo green "自动检测功能已停止"
    read -p "按回车返回菜单..."
}

# 开启流媒体解锁检测（仅 IPv6）
enable_stream_monitor() {
    color_echo green "=== 开启流媒体解锁检测（仅 IPv6） ==="

    read -p "是否启用 Telegram 推送通知? (y/N): " use_tg
    TG_ENABLED="no"
    TG_TOKEN=""
    TG_CHAT_ID=""
    if [[ "$use_tg" =~ ^[Yy]$ ]]; then
        read -p "请输入 Telegram Bot Token (格式: 123456:ABC-...): " tg_token
        read -p "请输入 Telegram Chat ID: " tg_chat_id
        TG_TOKEN="$tg_token"
        TG_CHAT_ID="$tg_chat_id"
        if [[ -n "$TG_TOKEN" && -n "$TG_CHAT_ID" ]]; then
            TG_ENABLED="yes"
            color_echo green "已启用 Telegram 推送"
        else
            color_echo yellow "未填写完整 Token 或 Chat ID，Telegram 推送未启用"
        fi
    fi

    sudo bash -c "cat > /usr/local/bin/warp-stream-monitor.sh" <<EOF
#!/bin/bash
# WARP 流媒体解锁检测脚本（所有请求通过 \$NIC 发出）
IFACE="warp"  # WARP IPv6 网卡名
UA_Browser="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
NIC="--interface \$IFACE"  # 可替换为代理参数，如 -x socks5://127.0.0.1:40000
RETRY_COOLDOWN=10
MAX_CONSEC_FAILS=10
PAUSE_ON_MANY_FAILS=1800
SLEEP_WHEN_UNLOCKED=1800
LOG_PREFIX="[WARP-STREAM]"

# Telegram 配置（由外部脚本写入）
TG_ENABLED="${TG_ENABLED}"
TG_TOKEN="${TG_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"

log() { echo "\$(date '+%F %T') ${LOG_PREFIX} \$*"; }

tg_send() {
    if [[ "\$TG_ENABLED" != "yes" || -z "\$TG_TOKEN" || -z "\$TG_CHAT_ID" ]]; then
        return 0
    fi
    local text="\$1"
    # 简单重试机制
    for i in 1 2 3; do
        curl -s -X POST "https://api.telegram.org/bot\$TG_TOKEN/sendMessage" -d chat_id="\$TG_CHAT_ID" -d text="\$text" >/dev/null 2>&1 && break
        sleep 1
    done
}

# 获取当前 WARP IPv6 出口地址
get_ipv6() { curl -6 \$NIC -A "\$UA_Browser" -fsL --max-time 5 https://ip.gs || echo "不可用"; }

# 检查 WARP IPv6 是否可用
check_warp_ipv6() {
    local ip
    ip=\$(get_ipv6)
    if [[ "\$ip" == "不可用" || -z "\$ip" ]]; then
        log "⚠️ WARP IPv6 不可用，尝试重启接口..."
        wg-quick down \$IFACE >/dev/null 2>&1
        wg-quick up \$IFACE >/dev/null 2>&1
        sleep \$RETRY_COOLDOWN
        ip=\$(get_ipv6)
        if [[ "\$ip" == "不可用" || -z "\$ip" ]]; then
            log "❌ WARP IPv6 仍不可用，等待 \${PAUSE_ON_MANY_FAILS} 秒后重试..."
            sleep \$PAUSE_ON_MANY_FAILS
            return 1
        fi
    fi
    return 0
}

# Netflix 检测 + 地区获取
check_netflix() {
    local sg_id="81215567"       # 非自制剧 ID
    local original_id="80018499" # 自制剧 ID
    local region_id="\$sg_id"     # 用于获取地区的影片 ID
    local code_sg code_orig region

    code_sg=\$(curl -6 \$NIC -A "\$UA_Browser" -fsL --max-time 10 \
        --write-out "%{http_code}" --output /dev/null \
        "https://www.netflix.com/title/\${sg_id}")
    if [ "\$code_sg" = "200" ]; then
        # 获取地区代码
        region=\$(curl -6 \$NIC -A "\$UA_Browser" -fsL --max-time 10 \
            --write-out "%{redirect_url}" --output /dev/null \
            "https://www.netflix.com/title/\${region_id}" \
            | sed 's/.*com\/\([^\/-]\{2\}\).*/\1/' | tr '[:lower:]' '[:upper:]')
        region=\${region:-"US"}
        echo "√(完整, \$region)"
        return 0
    fi

    code_orig=\$(curl -6 \$NIC -A "\$UA_Browser" -fsL --max-time 10 \
        --write-out "%{http_code}" --output /dev/null \
        "https://www.netflix.com/title/\${original_id}")
    if [ "\$code_orig" = "200" ]; then
        region=\$(curl -6 \$NIC -A "\$UA_Browser" -fsL --max-time 10 \
            --write-out "%{redirect_url}" --output /dev/null \
            "https://www.netflix.com/title/\${original_id}" \
            | sed 's/.*com\/\([^\/-]\{2\}\).*/\1/' | tr '[:lower:]' '[:upper:]')
        region=\${region:-"US"}
        echo "×(仅自制剧, \$region)"
        return 1
    fi

    echo "×"
    return 1
}

# Disney+ 检测
# Disney+ 检测（完整流程）
check_disney() {
    local pre_assertion assertion pre_cookie disney_cookie token_content is_banned is_403
    local fake_content refresh_token disney_content tmp_result region in_supported

    # 1. 模拟浏览器注册设备，获取 assertion
    pre_assertion=\$(curl -6 \$NIC -A "\$UA_Browser" -fsL --max-time 10 \
        -X POST "https://disney.api.edge.bamgrid.com/devices" \
        -H "authorization: Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" \
        -H "content-type: application/json; charset=UTF-8" \
        -d '{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}')

    assertion=\$(echo "\$pre_assertion" | python3 -m json.tool 2>/dev/null | grep assertion | cut -f4 -d'"')
    if [ -z "\$assertion" ]; then
        echo "×"
        return 1
    fi

    # 2. 用 assertion 获取访问 token
    pre_cookie=\$(curl -6 \$NIC -fsL --max-time 10 \
        "https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/cookies" | sed -n '1p')
    disney_cookie=\$(echo "\$pre_cookie" | sed "s/DISNEYASSERTION/\$assertion/g")

    token_content=\$(curl -6 \$NIC -A "\$UA_Browser" -fsL --max-time 10 \
        -X POST "https://disney.api.edge.bamgrid.com/token" \
        -H "authorization: Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" \
        -d "\$disney_cookie")

    # 3. 检查 token 是否被拒绝
    is_banned=\$(echo "\$token_content" | python3 -m json.tool 2>/dev/null | grep 'forbidden-location')
    is_403=\$(echo "\$token_content" | grep '403 ERROR')
    if [ -n "\$is_banned\$is_403" ]; then
        echo "×"
        return 1
    fi

    # 4. 用 refresh_token 调 GraphQL API 获取地区信息
    fake_content=\$(curl -6 \$NIC -fsL --max-time 10 \
        "https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/cookies" | sed -n '8p')
    refresh_token=\$(echo "\$token_content" | python3 -m json.tool 2>/dev/null | grep 'refresh_token' | awk '{print \$2}' | cut -f2 -d'"')
    disney_content=\$(echo "\$fake_content" | sed "s/ILOVEDISNEY/\$refresh_token/g")

    tmp_result=\$(curl -6 \$NIC -A "\$UA_Browser" -fsL --max-time 10 \
        -X POST "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql" \
        -H "authorization: ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" \
        -d "\$disney_content")

    region=\$(echo "\$tmp_result" | python3 -m json.tool 2>/dev/null | grep 'countryCode' | cut -f4 -d'"')
    in_supported=\$(echo "\$tmp_result" | python3 -m json.tool 2>/dev/null | grep 'inSupportedLocation' | awk '{print \$2}' | cut -f1 -d',')

    # 5. 根据地区和支持状态判断是否解锁
    if [[ -n "\$region" && "\$in_supported" == "true" ]]; then
        echo "√(\$region)"
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

    ipv6=\$(get_ipv6)
    nf_status=\$(check_netflix)
    nf_ok=\$?
    ds_status=\$(check_disney)
    ds_ok=\$?
    
    if [ \$nf_ok -ne 0 ] || [ \$ds_ok -ne 0 ]; then
        ((fail_count++))
        log "[IPv6: \$ipv6] ❌ 未解锁（Netflix: \$nf_status, Disney+: \$ds_status），连续失败 \${fail_count} 次 → 更换 WARP IP..."
        # 首次失败或达到阈值时发送 Telegram 通知（如果启用）
        if [ "\$fail_count" -eq 1 ]; then
            tg_send "⚠️ WARP 未解锁：IPv6=\$ipv6 | Netflix=\$nf_status | Disney+=\$ds_status | 时间=\$(date '+%F %T')"
        fi
        wg-quick down \$IFACE >/dev/null 2>&1
        wg-quick up \$IFACE >/dev/null 2>&1
        sleep \$RETRY_COOLDOWN
        if [ "\$fail_count" -ge "\$MAX_CONSEC_FAILS" ]; then
            log "⚠️ 连续失败 \${MAX_CONSEC_FAILS} 次，暂停 \${PAUSE_ON_MANY_FAILS} 秒..."
            tg_send "🚨 WARP 连续未解锁已达 \${MAX_CONSEC_FAILS} 次，暂停 \${PAUSE_ON_MANY_FAILS} 秒后重试（IPv6=\$ipv6）"
            sleep \$PAUSE_ON_MANY_FAILS
            fail_count=0
        fi
    else
        log "[IPv6: \$ipv6] ✅ 已解锁（Netflix: \$nf_status, Disney+: \$ds_status），\${SLEEP_WHEN_UNLOCKED} 秒后检测"
        # 若之前有失败记录，可发送恢复通知（可选）
        if [ \$fail_count -gt 0 ]; then
            tg_send "✅ WARP 已解锁恢复：IPv6=\$ipv6 | Netflix=\$nf_status | Disney+=\$ds_status | 时间=\$(date '+%F %T')"
        fi
        fail_count=0
        sleep \$SLEEP_WHEN_UNLOCKED
    fi
done
EOF
    sudo chmod +x /usr/local/bin/warp-stream-monitor.sh

    sudo bash -c "cat > /etc/systemd/system/$STREAM_SERVICE_NAME" <<EOF
[Unit]
Description=WARP 流媒体解锁检测（仅 IPv6）
After=network.target

[Service]
ExecStart=/usr/local/bin/warp-stream-monitor.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now $STREAM_SERVICE_NAME

    color_echo green "流媒体解锁检测已开启（检测前会确认 WARP IPv6 可用，并显示 Netflix 地区）。未解锁将更换 IP，首次未解锁与达到连续失败阈值时会发送 Telegram 通知（如果已启用）。"
    echo "=== 实时日志（Ctrl+C 退出查看，服务继续后台运行） ==="
    sudo journalctl -u $STREAM_SERVICE_NAME -f -n 0
}


# 停止流媒体解锁检测
disable_stream_monitor() {
    color_echo yellow "=== 停止流媒体解锁检测 ==="
    sudo systemctl disable --now $STREAM_SERVICE_NAME 2>/dev/null || true
    sudo rm -f /etc/systemd/system/$STREAM_SERVICE_NAME
    sudo rm -f /usr/local/bin/warp-stream-monitor.sh
    sudo systemctl daemon-reload
    color_echo green "流媒体解锁功能已停止"
    read -p "按回车返回菜单..."
}

# --- 主逻辑 ---

if [ ! -f /usr/local/bin/02 ]; then
    color_echo yellow "正在创建快捷命令 '02'..."
    sudo bash -c "echo 'bash <(curl -fsSL https://raw.githubusercontent.com/Geniusmmc/Warp-unlock/main/warp_manager.sh)' > /usr/local/bin/02"
    sudo chmod +x /usr/local/bin/02
    color_echo green "快捷命令已创建，之后可直接输入 02 打开 WARP 管理菜单"
fi

if systemctl list-units --type=service | grep -q "$STREAM_SERVICE_NAME"; then
    color_echo yellow "检测到 $STREAM_SERVICE_NAME 服务，正在重新加载并重启..."
    sudo systemctl daemon-reload
    sudo systemctl restart "$STREAM_SERVICE_NAME"
fi

# 主循环
while true; do
    show_menu
    read -p "请选择操作 [0-8]: " choice
    case $choice in
        1) install_warp ;;
        2) uninstall_warp_interface ;;
        3) uninstall_script ;;
        4) check_warp_status; read -p "按回车返回菜单..." ;;
        5) enable_auto_restart ;;
        6) disable_auto_restart ;;
        7) enable_stream_monitor ;;
        8) disable_stream_monitor ;;
        0) exit 0 ;;
        *) color_echo red "无效选项"; read -p "按回车返回菜单..." ;;
    esac
done
