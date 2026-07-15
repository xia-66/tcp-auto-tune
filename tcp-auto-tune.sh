#!/usr/bin/env bash

set -e

# ==========================================================
# Auto TCP Tuning Script for Proxy Node
# Debian 11/12, Ubuntu 20.04+
# Auto bandwidth test, auto RTT test, auto BBR/fq tuning
# ==========================================================

SYSCTL_CONF="/etc/sysctl.d/99-tcp-tuning.conf"
BACKUP_DIR="/root/tcp-tuning-backup"
TC_SERVICE="/etc/systemd/system/tc-upload-limit.service"

# 是否自动设置上传限速
# 1 = 开启，0 = 关闭
AUTO_TC_LIMIT=1

# 上传限速比例，默认实测上传的 95%
TC_LIMIT_PERCENT=95

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
PLAIN="\033[0m"

info() {
    echo -e "${GREEN}[INFO]${PLAIN} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${PLAIN} $1"
}

error() {
    echo -e "${RED}[ERROR]${PLAIN} $1"
}

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "请使用 root 用户运行脚本"
        exit 1
    fi
}

check_system() {
    info "检测系统信息..."
    echo "Kernel: $(uname -r)"
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "OS: $PRETTY_NAME"
    fi
}

install_deps() {
    info "检查并安装依赖..."

    export DEBIAN_FRONTEND=noninteractive

    NEED_UPDATE=0

    for cmd in ip tc ping python3; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            NEED_UPDATE=1
        fi
    done

    if ! command -v speedtest-cli >/dev/null 2>&1; then
        NEED_UPDATE=1
    fi

    if [[ "$NEED_UPDATE" -eq 1 ]]; then
        apt-get update
    fi

    if ! command -v ip >/dev/null 2>&1 || ! command -v tc >/dev/null 2>&1; then
        apt-get install -y iproute2
    fi

    if ! command -v ping >/dev/null 2>&1; then
        apt-get install -y iputils-ping
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        apt-get install -y python3
    fi

    if ! command -v speedtest-cli >/dev/null 2>&1; then
        apt-get install -y speedtest-cli
    fi
}

check_bbr_support() {
    info "检测 BBR 支持情况..."

    local available
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)

    if echo "$available" | grep -qw "bbr"; then
        info "当前内核支持 BBR: $available"
    else
        error "当前内核不支持 BBR，请升级内核"
        exit 1
    fi
}

backup_config() {
    mkdir -p "$BACKUP_DIR"

    local now
    now=$(date +"%Y%m%d-%H%M%S")

    if [[ -f "$SYSCTL_CONF" ]]; then
        cp "$SYSCTL_CONF" "$BACKUP_DIR/99-tcp-tuning.conf.$now.bak"
        info "已备份旧 sysctl 配置到: $BACKUP_DIR/99-tcp-tuning.conf.$now.bak"
    fi

    if [[ -f "$TC_SERVICE" ]]; then
        cp "$TC_SERVICE" "$BACKUP_DIR/tc-upload-limit.service.$now.bak"
        info "已备份旧 tc 服务到: $BACKUP_DIR/tc-upload-limit.service.$now.bak"
    fi
}

detect_iface() {
    info "自动识别默认出口网卡..."

    IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')

    if [[ -z "$IFACE" ]]; then
        IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    fi

    if [[ -z "$IFACE" ]]; then
        error "无法自动识别默认网卡"
        exit 1
    fi

    info "默认出口网卡: $IFACE"
}

auto_speedtest() {
    info "开始自动测速，这一步可能需要 30~90 秒..."
    warn "测速会消耗一定流量，并且结果会受 speedtest 节点影响。"

    SPEED_JSON=$(mktemp)

    if speedtest-cli --json > "$SPEED_JSON" 2>/dev/null; then
        DOWN_MBPS=$(python3 - "$SPEED_JSON" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d=json.load(f)
print(max(1, int(d.get("download", 0) / 1000000)))
PY
)
        UP_MBPS=$(python3 - "$SPEED_JSON" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d=json.load(f)
print(max(1, int(d.get("upload", 0) / 1000000)))
PY
)
        SPEED_PING=$(python3 - "$SPEED_JSON" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d=json.load(f)
print(int(float(d.get("ping", 0)) + 0.5))
PY
)
        SPEED_SERVER=$(python3 - "$SPEED_JSON" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d=json.load(f)
server=d.get("server", {})
sponsor=server.get("sponsor", "unknown")
name=server.get("name", "unknown")
country=server.get("country", "unknown")
print(f"{sponsor} / {name} / {country}")
PY
)
        rm -f "$SPEED_JSON"

        info "测速节点: $SPEED_SERVER"
        info "实测下载: ${DOWN_MBPS} Mbps"
        info "实测上传: ${UP_MBPS} Mbps"
        info "测速节点 Ping: ${SPEED_PING} ms"
    else
        rm -f "$SPEED_JSON"
        warn "自动测速失败，将使用保守默认值：下载 100M / 上传 50M"
        DOWN_MBPS=100
        UP_MBPS=50
        SPEED_PING=150
    fi
}

ping_one() {
    local host="$1"
    local result

    result=$(ping -c 5 -w 8 "$host" 2>/dev/null | awk -F'/' '/rtt|round-trip/ {print int($5+0.5)}' || true)

    if [[ "$result" =~ ^[0-9]+$ ]] && [[ "$result" -gt 0 ]]; then
        echo "$result"
    else
        echo ""
    fi
}

auto_rtt_test() {
    info "开始自动 RTT 测试..."

    # 代理节点常见目标：
    # 如果你的节点服务中国大陆用户，223.5.5.5 / 119.29.29.29 / 114.114.114.114 更有参考价值
    # 同时加入 1.1.1.1 / 8.8.8.8 作为全球可达参考
    TARGETS=(
        "223.5.5.5"
        "119.29.29.29"
        "114.114.114.114"
        "1.1.1.1"
        "8.8.8.8"
    )

    RTT_LIST=()

    for target in "${TARGETS[@]}"; do
        rtt=$(ping_one "$target")
        if [[ -n "$rtt" ]]; then
            info "Ping $target: ${rtt} ms"
            RTT_LIST+=("$rtt")
        else
            warn "Ping $target 失败，跳过"
        fi
    done

    if [[ "${#RTT_LIST[@]}" -eq 0 ]]; then
        warn "所有 RTT 测试失败，使用测速节点 Ping 或默认 RTT"
        if [[ "$SPEED_PING" =~ ^[0-9]+$ ]] && [[ "$SPEED_PING" -gt 0 ]]; then
            RTT_MS="$SPEED_PING"
        else
            RTT_MS=150
        fi
    else
        # 代理节点通常更关心到主要用户方向的 RTT。
        # 这里取可用 RTT 的较大值，避免 buffer 估算过小。
        RTT_MS=$(printf "%s\n" "${RTT_LIST[@]}" | sort -n | tail -1)
    fi

    # 如果 RTT 太小，但测速节点 ping 明显更大，则取更大的那个
    if [[ "$SPEED_PING" =~ ^[0-9]+$ ]] && [[ "$SPEED_PING" -gt "$RTT_MS" ]]; then
        RTT_MS="$SPEED_PING"
    fi

    # 限制极端值
    if [[ "$RTT_MS" -lt 5 ]]; then
        RTT_MS=5
    fi

    if [[ "$RTT_MS" -gt 500 ]]; then
        RTT_MS=500
    fi

    info "最终用于计算的 RTT: ${RTT_MS} ms"
}

calc_buffer() {
    info "根据带宽和 RTT 自动计算 TCP buffer..."

    local max_mbps
    if [[ "$DOWN_MBPS" -ge "$UP_MBPS" ]]; then
        max_mbps="$DOWN_MBPS"
    else
        max_mbps="$UP_MBPS"
    fi

    # BDP_KB = Mbps * ms / 8
    BDP_KB=$((max_mbps * RTT_MS / 8))
    BDP_MB=$((BDP_KB / 1024))

    # 根据带宽分档
    if [[ "$max_mbps" -le 100 ]]; then
        BUFFER_MB=64
        DEFAULT_MB=1
    elif [[ "$max_mbps" -le 500 ]]; then
        BUFFER_MB=128
        DEFAULT_MB=1
    elif [[ "$max_mbps" -le 1000 ]]; then
        BUFFER_MB=256
        DEFAULT_MB=4
    elif [[ "$max_mbps" -le 2500 ]]; then
        BUFFER_MB=256
        DEFAULT_MB=4
    elif [[ "$max_mbps" -le 5000 ]]; then
        BUFFER_MB=512
        DEFAULT_MB=4
    else
        BUFFER_MB=512
        DEFAULT_MB=8
    fi

    # RTT 特别高时适当提高
    if [[ "$RTT_MS" -ge 250 && "$max_mbps" -ge 500 && "$BUFFER_MB" -lt 256 ]]; then
        BUFFER_MB=256
    fi

    if [[ "$RTT_MS" -ge 250 && "$max_mbps" -ge 1000 && "$BUFFER_MB" -lt 512 ]]; then
        BUFFER_MB=512
    fi

    RMEM_MAX=$((BUFFER_MB * 1024 * 1024))
    WMEM_MAX=$((BUFFER_MB * 1024 * 1024))
    DEFAULT_BUF=$((DEFAULT_MB * 1024 * 1024))

    info "计算结果："
    echo "下载带宽: ${DOWN_MBPS} Mbps"
    echo "上传带宽: ${UP_MBPS} Mbps"
    echo "RTT: ${RTT_MS} ms"
    echo "估算 BDP: ${BDP_KB} KB / 约 ${BDP_MB} MB"
    echo "TCP buffer max: ${BUFFER_MB} MB"
    echo "TCP buffer default: ${DEFAULT_MB} MB"
}

write_sysctl_config() {
    info "写入 sysctl TCP 调优配置..."

    cat > "$SYSCTL_CONF" <<EOF
# ==========================================================
# Auto TCP tuning for proxy node
# Generated by tcp-auto-tune.sh
#
# Detected bandwidth:
#   Download: ${DOWN_MBPS} Mbps
#   Upload:   ${UP_MBPS} Mbps
# RTT used: ${RTT_MS} ms
# Estimated BDP: ${BDP_KB} KB
# Buffer max: ${BUFFER_MB} MB
# ==========================================================

# BBR + fq
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP buffer
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${WMEM_MAX}
net.core.rmem_default = ${DEFAULT_BUF}
net.core.wmem_default = ${DEFAULT_BUF}

net.ipv4.tcp_rmem = 4096 ${DEFAULT_BUF} ${RMEM_MAX}
net.ipv4.tcp_wmem = 4096 ${DEFAULT_BUF} ${WMEM_MAX}

# Queue and backlog
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_abort_on_overflow = 0

# Proxy node TCP behavior
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1

# Local port range
net.ipv4.ip_local_port_range = 10240 65535

# File handles
fs.file-max = 1048576
EOF
}

apply_sysctl() {
    info "应用 sysctl 配置..."
    sysctl --system
}

setup_nofile() {
    info "设置 systemd 默认文件句柄限制..."

    mkdir -p /etc/systemd/system.conf.d

    cat > /etc/systemd/system.conf.d/99-nofile.conf <<EOF
[Manager]
DefaultLimitNOFILE=1048576
EOF

    systemctl daemon-reexec

    info "systemd 默认文件句柄已设置为 1048576"
    warn "已经运行的代理服务需要重启后才会继承新的文件句柄限制"
}

setup_tc_limit() {
    if [[ "$AUTO_TC_LIMIT" -ne 1 ]]; then
        warn "未启用自动上传限速"
        return
    fi

    if [[ "$UP_MBPS" -le 5 ]]; then
        warn "上传带宽过低，跳过 tc 限速"
        return
    fi

    TC_LIMIT=$((UP_MBPS * TC_LIMIT_PERCENT / 100))

    if [[ "$TC_LIMIT" -lt 1 ]]; then
        TC_LIMIT=1
    fi

    info "设置上传限速，降低 bufferbloat..."
    info "网卡: $IFACE"
    info "实测上传: ${UP_MBPS} Mbps"
    info "限速比例: ${TC_LIMIT_PERCENT}%"
    info "tc 限速: ${TC_LIMIT} mbit"

    tc qdisc replace dev "$IFACE" root fq maxrate "${TC_LIMIT}mbit"

    cat > "$TC_SERVICE" <<EOF
[Unit]
Description=Upload limit using tc fq maxrate
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/tc qdisc replace dev ${IFACE} root fq maxrate ${TC_LIMIT}mbit
ExecStop=/sbin/tc qdisc del dev ${IFACE} root
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tc-upload-limit.service >/dev/null 2>&1 || true

    info "上传限速已设置，并已创建开机自启服务: tc-upload-limit.service"
}

show_result() {
    echo
    echo "================ TCP 自动调优完成 ================"
    echo

    echo "检测结果："
    echo "下载带宽: ${DOWN_MBPS} Mbps"
    echo "上传带宽: ${UP_MBPS} Mbps"
    echo "RTT: ${RTT_MS} ms"
    echo "默认网卡: ${IFACE}"
    echo "TCP buffer max: ${BUFFER_MB} MB"

    if [[ "$AUTO_TC_LIMIT" -eq 1 ]]; then
        echo "上传限速: ${TC_LIMIT} mbit"
    else
        echo "上传限速: 未启用"
    fi

    echo
    echo "当前拥塞控制："
    sysctl net.ipv4.tcp_congestion_control

    echo
    echo "当前队列算法："
    sysctl net.core.default_qdisc

    echo
    echo "TCP buffer："
    sysctl net.ipv4.tcp_rmem
    sysctl net.ipv4.tcp_wmem

    echo
    echo "MTU probing："
    sysctl net.ipv4.tcp_mtu_probing

    if [[ "$AUTO_TC_LIMIT" -eq 1 ]]; then
        echo
        echo "当前 tc 队列："
        tc qdisc show dev "$IFACE" || true
    fi

    echo
    echo "配置文件: $SYSCTL_CONF"
    echo "备份目录: $BACKUP_DIR"
    echo

    warn "建议重启代理服务，例如 xray、sing-box、hysteria、trojan、ss-server 等。"
    warn "如果发现上传速度被限制得过低，可以关闭 tc 限速或调整限速值。"
}

main() {
    check_root
    check_system
    install_deps
    check_bbr_support
    detect_iface

    echo
    warn "脚本将自动测速并应用代理节点 TCP 调优。"
    warn "默认会把上传限速设置为实测上传的 ${TC_LIMIT_PERCENT}%，用于降低延迟和 bufferbloat。"
    echo
    read -rp "是否继续？[y/N]: " CONFIRM

    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        warn "已取消"
        exit 0
    fi

    backup_config
    auto_speedtest
    auto_rtt_test
    calc_buffer
    write_sysctl_config
    apply_sysctl
    setup_nofile
    setup_tc_limit
    show_result
}

main "$@"
