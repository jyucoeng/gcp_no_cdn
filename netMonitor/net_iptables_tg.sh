#!/bin/bash

# ==========================================
# 流量监控自动部署脚本 (Telegram 通知版 / 通用 GCP & Oracle)
# 功能：
# 1. 自动获取网卡，只监控出站流量 (TX)
# 2. 超限后双向封网 (INPUT + OUTPUT 全部 DROP)，仅保留 SSH / DNS / lo
# 3. 每月重置流量并删除旧的监控日志
# 4. TG 通知：
#    - 断网之前发送一条 "正常 ---> 断网" 通知
#    - 每月1号恢复网络时发送一条 "断网----网络恢复" 通知
# 5. 封网使用专属自定义链 TRAFFIC_BLOCKED + 注释，便于识别
# 6. 平台差异通过 PLATFORM 区分 (标题/CPU行/上报上限)：
#    - PLATFORM=GCP    -> 🎮 GCP 流量报告，无 CPU 行，上限默认 180GB
#    - PLATFORM=ORACLE -> 🎮 ORACLE 流量报告，含 CPU 行(AMD/ARM)，上限默认 9TB(9216GB)
# ==========================================

# ==========================================
# 可配置常量 (部署前请按需修改)
# ==========================================
# 平台标识: GCP 或 ORACLE (决定标题、CPU 行、上限默认值)
PLATFORM="GCP"

# 出站流量上限 (GB)，超过该值触发封网
# 留空时按 PLATFORM 自动设置: GCP=180, ORACLE=9216
LIMIT=""

# SSH 端口，封网后仅放行此端口用于远程管理
SSH_PORT=22
# DNS 服务器，封网后允许的 DNS 查询 (用于解析，保持基本可用)
DNS_SERVERS="8.8.8.8 1.1.1.1"

# ---- Telegram 通知 (必填，部署前务必填入) ----
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
# ==========================================

# 若未手动设置 LIMIT，则按平台取默认值
if [ -z "$LIMIT" ]; then
    if [ "$PLATFORM" = "ORACLE" ]; then
        LIMIT=9216
    else
        LIMIT=180
    fi
fi

# 确保状态目录存在
mkdir -p /var/lib/traffic_monitor

# 1. 检查 Root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 权限运行此脚本。"
    exit 1
fi

# 2. 自动获取默认网卡名称
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

if [ -z "$INTERFACE" ]; then
    echo "错误：无法自动检测到网卡名称，请手动修改脚本中的 INTERFACE 变量。"
    exit 1
fi

echo "--> 检测到当前主网卡为: $INTERFACE"

# 3. 安装依赖工具 (含 curl 用于 TG 通知)
echo "--> 正在更新软件源并安装工具..."
apt-get update -y
apt-get install vnstat bc curl -y

# 4. 配置并启动 vnStat
echo "--> 配置 vnStat..."
# 尝试添加接口
if ! vnstat --add -i "$INTERFACE" 2>/dev/null; then
    echo "    (接口可能已存在，跳过添加)"
fi

systemctl enable vnstat
systemctl restart vnstat

# 等待服务启动并生成初始数据库
sleep 5
vnstat -i "$INTERFACE" > /dev/null 2>&1

# 5. 生成监控脚本 (/root/check_traffic.sh)
echo "--> 生成监控脚本 /root/check_traffic.sh..."
cat > /root/check_traffic.sh <<EOF
#!/bin/bash

# 强制使用标准区域设置
export LC_ALL=C

# 配置
LOG_FILE="/var/log/traffic_monitor.log"
INTERFACE="$INTERFACE"
LIMIT=$LIMIT
SSH_PORT=$SSH_PORT
DNS_SERVERS="$DNS_SERVERS"
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
PLATFORM="$PLATFORM"
# 状态标记文件 (记录当前网络状态 normal/blocked，同一事件周期只发一次通知)
STATE_FILE="/var/lib/traffic_monitor/state"

# 日志记录函数 (保持原格式)
log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" >> "\$LOG_FILE"
}

# 权限检查
if [ "\$(id -u)" -ne 0 ]; then
    echo "错误：需要 root 权限"
    exit 1
fi

# ORACLE 平台: 每次检查前确认 firewalld / ufw 未启用，否则停用
if [ "\$PLATFORM" = "ORACLE" ]; then
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        systemctl stop firewalld 2>/dev/null
        log "运行时停用了 firewalld。"
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'active'; then
        ufw --force disable >/dev/null 2>&1
        log "运行时停用了 ufw。"
    fi
fi

# ==========================================
# 工具函数：获取本机公网 IPv4 并打码 + 国家/城市
# IP 打码规则: 152.69.206.146 -> 152.69.***.146
# ==========================================
get_ip_and_loc() {
    # 调用 ip-api.com 获取 IPv4 及地区信息 (最多重试 3 次)
    local geo
    for _try in 1 2 3; do
        geo=\$(curl -s --max-time 5 "http://ip-api.com/json/?fields=query,countryCode,city" 2>/dev/null)
        [ -n "\$geo" ] && break
        sleep 2
    done
    local ip city cc
    ip=\$(echo "\$geo" | sed -n 's/.*"query":"\([^"]*\)".*/\1/p')
    city=\$(echo "\$geo" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')
    cc=\$(echo "\$geo" | sed -n 's/.*"countryCode":"\([^"]*\)".*/\1/p')

    # 若未获取到则使用备用方式取 IP (备份，不做多次重试)
    if [ -z "\$ip" ]; then
        ip=\$(curl -4 -s --max-time 5 "https://api.ipify.org" 2>/dev/null)
    fi

    # 打码: 只保留第1、2、4 段，第3段替换为 ***(如 152.69.***.146)
    local masked
    masked=\$(echo "\$ip" | awk -F. 'NF==4 {print \$1"."\$2".***."\$4; exit} {print \$ip}')

    # 定位降级: 城市-国家 / 国家 / unknown
    local loc
    if [ -n "\$city" ] && [ -n "\$cc" ]; then
        loc="\${city}-\${cc}"          # 例: Osaka-JP
    elif [ -n "\$cc" ]; then
        loc="\$cc"                      # 例: JP
    else
        loc="unknown"
    fi

    # 输出: masked|loc|ip
    echo "\${masked}|\${loc}|\${ip}"
}

# ==========================================
# 工具函数：发送 Telegram 通知
# ==========================================
tg_send() {
    local msg="\$1"
    curl -s --max-time 10 -X POST \
        "https://api.telegram.org/bot\${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="\${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=\${msg}" >/dev/null 2>&1
}

# ==========================================
# 获取当月累计出站流量 (返回原始字节数)
# ==========================================
get_monthly_tx() {
    # vnstat 月度数据 TX (单位字节，取当月)
    local month_tx
    month_tx=\$(vnstat -i "\$INTERFACE" --oneline b 2>/dev/null | cut -d ';' -f 10)
    if [ -z "\$month_tx" ] || ! [[ "\$month_tx" =~ ^[0-9]+$ ]]; then
        month_tx=0
    fi
    echo "\$month_tx"
}

# ==========================================
# 流量格式化: 按 MB -> GB -> TB 层级递进
# 输入: 字节数  输出: 如 512.00MB / 123.45GB / 1.23TB
# 规则: <1GB 用 MB; 1GB~1024GB 用 GB; >=1024GB 用 TB
# ==========================================
format_traffic() {
    local bytes b
    bytes="\$1"
    case "\$bytes" in
        ''|*[!0-9]*) bytes=0 ;;
    esac
    b=\$(echo "scale=2; \$bytes / 1073741824" | bc)   # 换算成 GB
    if [ \$(echo "\$b < 1" | bc) -eq 1 ]; then
        # 不足 1GB -> MB
        echo "\$(echo "scale=2; \$bytes / 1048576" | bc)MB"
    elif [ \$(echo "\$b < 1024" | bc) -eq 1 ]; then
        # 1GB ~ 1024GB -> GB
        echo "\${b}GB"
    else
        # >= 1024GB (1TB) -> TB
        echo "\$(echo "scale=2; \$bytes / 1073741824 / 1024" | bc)TB"
    fi
}

# ==========================================
# 工具函数：判定 CPU 类型 (AMD / ARM) —— 仅 ORACLE 平台需要
# AMD 判定: 型号/架构含 AMD/EPYC; ARM 判定: 架构为 aarch64/arm
# ==========================================
get_cpu_type() {
    local arch ctype
    arch=\$(uname -m)
    ctype=\$(lscpu 2>/dev/null | awk -F: '/^Vendor ID|^型号名称|^Model name/ {print \$2}' | head -n1)
    if [[ "\$arch" == aarch64 || "\$arch" == arm* ]]; then
        echo "ARM"
    elif echo "\$arch \$ctype" | grep -qi "amd\|epyc"; then
        echo "AMD"
    else
        echo "AMD"
    fi
}

# ==========================================
# 获取流量数据 (强制使用 'b' 参数获取字节单位)
# ==========================================
VNSTAT_RAW=\$(vnstat -i "\$INTERFACE" --oneline b 2>/dev/null)

# 提取出站流量 (TX)，第 10 个字段
TX_BYTES=\$(echo "\$VNSTAT_RAW" | cut -d ';' -f 10)

# 如果获取失败或为空，默认为 0
if [[ -z "\$TX_BYTES" ]]; then
    TX_BYTES=0
fi

# 将字节转换为 GB (1 GB = 1073741824 Bytes)
TX_GB=\$(echo "scale=2; \$TX_BYTES / 1073741824" | bc)

# ==========================================
# 1. 终端直接输出 (显示精确数值)
# ==========================================
echo "========================================"
echo " 网卡接口    : \$INTERFACE"
echo " 当前时间    : \$(date '+%Y-%m-%d %H:%M:%S')"
echo " 精确出站(TX): \$TX_BYTES Bytes"
echo " 换算出站(TX): \$TX_GB GB"
echo " 流量上限    : \$LIMIT GB"
echo "========================================"

# ==========================================
# 2. 日志记录与限制逻辑
# ==========================================

log "当前出站流量: \$TX_GB GB (限制: \$LIMIT GB)"

# 读取当月状态 (默认 normal)
CUR_MONTH=\$(date '+%Y-%m')
[ -f "\$STATE_FILE" ] && . "\$STATE_FILE"
[ -z "\$STATE" ] && STATE=normal
[ -z "\$MONTH" ] && MONTH="\$CUR_MONTH"
# 若跨月，重置到普通状态 (新一轮计费周期)
if [ "\$MONTH" != "\$CUR_MONTH" ]; then
    STATE=normal
    MONTH="\$CUR_MONTH"
    BLOCKED_TIME=""
    BLOCKED_TX=""
    RESTORED_TIME=""
fi

# 保存当月状态到文件
save_state() {
    cat > "\$STATE_FILE" <<STATE_EOF
MONTH=\$MONTH
STATE=\$STATE
BLOCKED_TIME=\$BLOCKED_TIME
BLOCKED_TX=\$BLOCKED_TX
RESTORED_TIME=\$RESTORED_TIME
STATE_EOF
}

# 检查是否超限
if [ \$(echo "\$TX_GB >= \$LIMIT" | bc) -eq 1 ]; then
    echo "状态: [警告] 流量已超限，正在封网..."
    log "警告：流量超出限制！正在执行封禁策略..."

    # ---- 仅当本次由正常转为断网时才发送断网通知 (同一事件周期只发一次) ----
    if [ "\$STATE" != "blocked" ]; then
        STATE=blocked
        BLOCKED_TIME=\$(date '+%Y-%m-%d %H:%M:%S')
        BLOCKED_TX="\$TX_BYTES"
        save_state

        # 断网之前发送 TG 通知
        read -r MASKED_IP LOC FULL_IP <<< "\$(get_ip_and_loc)"
        RUN_TIME=\$(date '+%Y-%m-%d %H:%M:%S')
        MONTH_TX=\$TX_BYTES
        # CPU 行 (仅 ORACLE 显示)
        CPU_LINE=""
        if [ "\$PLATFORM" = "ORACLE" ]; then
            CPU_LINE="
🌐 CPU: \$(get_cpu_type)"
        fi

        # 组装通知文本 (ORACLE 时含 CPU 行)
TG_MSG="🎮 \$PLATFORM 流量报告（断网通知）

🌐 本机IP: \$MASKED_IP (\$LOC)
🕐 运行时间: \$RUN_TIME
📚 网络状态: 正常 ---> 断网
🌐 本月流量: \$(format_traffic "\$MONTH_TX") / 上限: \$LIMIT GB\${CPU_LINE}"

        tg_send "\$TG_MSG"
        log "已发送断网 TG 通知。"
    else
        echo "    (本周期已发送断网通知，跳过。)"
        log "本周期已发送断网通知，跳过。"
    fi

    # ---- 封禁策略 (双向封锁，仅影响本脚本内容) ----
    # 不改变全局默认策略(-P)、不全局清空(-F/-X)，只操作自家 TRAFFIC_BLOCKED 链，
    # 避免影响其他程序/服务已有的 iptables 规则。
    # 创建或复用自家链 (已存在则清空重建)
    iptables -N TRAFFIC_BLOCKED 2>/dev/null || iptables -F TRAFFIC_BLOCKED

    # 在 TRAFFIC_BLOCKED 链内定义放行规则
    # 放行已建立的连接 (关键: 确保封网瞬间不打断当前 SSH 会话)
    iptables -A TRAFFIC_BLOCKED -m state --state ESTABLISHED,RELATED -j ACCEPT
    # 放行 SSH 管理端口
    iptables -A TRAFFIC_BLOCKED -p tcp --dport "\$SSH_PORT" -j ACCEPT
    # 放行 DNS 查询 (保证域名解析可用)
    for DNS in \$DNS_SERVERS; do
        iptables -A TRAFFIC_BLOCKED -p udp --dport 53 -d "\$DNS" -j ACCEPT
        iptables -A TRAFFIC_BLOCKED -p tcp --dport 53 -d "\$DNS" -j ACCEPT
    done
    # 放行 ICMP (ping)
    iptables -A TRAFFIC_BLOCKED -p icmp -j ACCEPT
    # 放行 loopback
    iptables -A TRAFFIC_BLOCKED -i lo -j ACCEPT
    # 链内兜底 DROP: 未放行的流量在此终结，不回到主链(不影响其他规则)
    iptables -A TRAFFIC_BLOCKED -j DROP

    # 在主链最顶部各插入一条跳转到 TRAFFIC_BLOCKED (仅本脚本三条)
    # 覆盖 INPUT / OUTPUT / FORWARD，实现真正全局封网；
    # 用 -I 1 插到最前，确保封网生效；不动各链已有的其他规则与默认策略
    iptables -I INPUT   1 -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
    iptables -I OUTPUT  1 -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
    iptables -I FORWARD 1 -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED

    log "网络已限制 (TRAFFIC_BLOCKED 全局封锁，仅保留 SSH / DNS / lo)。"
else
    echo "状态: [正常] 流量未超限。"

    # 若曾在断网状态，但当前流量已回落则状态归位 normal (不发恢复通知，恢复通知由 reset 触发)
    if [ "\$STATE" = "blocked" ]; then
        STATE=normal
        save_state
        log "检测到流量回落，状态恢复正常。"
    else
        log "流量正常。"
    fi
fi
EOF

# 6. 生成重置脚本 (/root/reset_network.sh)
echo "--> 生成重置脚本 /root/reset_network.sh..."
cat > /root/reset_network.sh <<EOF
#!/bin/bash

RESET_LOG="/var/log/network_reset.log"
TRAFFIC_LOG="/var/log/traffic_monitor.log"
INTERFACE="$INTERFACE"
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
PLATFORM="$PLATFORM"
LIMIT=$LIMIT
# 状态标记文件 (与 check_traffic.sh 共用)
STATE_FILE="/var/lib/traffic_monitor/state"

log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" >> "\$RESET_LOG"
}

# 发送 Telegram 通知
tg_send() {
    local msg="\$1"
    curl -s --max-time 10 -X POST \
        "https://api.telegram.org/bot\${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="\${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=\${msg}" >/dev/null 2>&1
}

# 获取本机公网 IPv4 并打码 + 国家/城市
get_ip_and_loc() {
    local geo
    for _try in 1 2 3; do
        geo=\$(curl -s --max-time 5 "http://ip-api.com/json/?fields=query,countryCode,city" 2>/dev/null)
        [ -n "\$geo" ] && break
        sleep 2
    done
    local ip city cc
    ip=\$(echo "\$geo" | sed -n 's/.*"query":"\([^"]*\)".*/\1/p')
    city=\$(echo "\$geo" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')
    cc=\$(echo "\$geo" | sed -n 's/.*"countryCode":"\([^"]*\)".*/\1/p')
    if [ -z "\$ip" ]; then
        ip=\$(curl -4 -s --max-time 5 "https://api.ipify.org" 2>/dev/null)
    fi
    local masked
    masked=\$(echo "\$ip" | awk -F. 'NF==4 {print \$1"."\$2".***."\$4; exit} {print \$ip}')
    local loc
    if [ -n "\$city" ] && [ -n "\$cc" ]; then
        loc="\${city}-\${cc}"
    elif [ -n "\$cc" ]; then
        loc="\$cc"
    else
        loc="unknown"
    fi
    echo "\${masked}|\${loc}|\${ip}"
}

# 获取当月累计出站流量 (返回原始字节数)
get_monthly_tx() {
    local month_tx
    month_tx=\$(vnstat -i "\$INTERFACE" --oneline b 2>/dev/null | cut -d ';' -f 10)
    if [ -z "\$month_tx" ] || ! [[ "\$month_tx" =~ ^[0-9]+$ ]]; then
        month_tx=0
    fi
    echo "\$month_tx"
}

# 流量格式化: 按 MB -> GB -> TB 层级递进
format_traffic() {
    local bytes b
    bytes="\$1"
    case "\$bytes" in
        ''|*[!0-9]*) bytes=0 ;;
    esac
    b=\$(echo "scale=2; \$bytes / 1073741824" | bc)
    if [ \$(echo "\$b < 1" | bc) -eq 1 ]; then
        echo "\$(echo "scale=2; \$bytes / 1048576" | bc)MB"
    elif [ \$(echo "\$b < 1024" | bc) -eq 1 ]; then
        echo "\${b}GB"
    else
        echo "\$(echo "scale=2; \$bytes / 1073741824 / 1024" | bc)TB"
    fi
}

# 判定 CPU 类型 (AMD / ARM)
get_cpu_type() {
    local arch ctype
    arch=\$(uname -m)
    ctype=\$(lscpu 2>/dev/null | awk -F: '/^Vendor ID|^型号名称|^Model name/ {print \$2}' | head -n1)
    if [[ "\$arch" == aarch64 || "\$arch" == arm* ]]; then
        echo "ARM"
    elif echo "\$arch \$ctype" | grep -qi "amd\|epyc"; then
        echo "AMD"
    else
        echo "AMD"
    fi
}

log "开始执行每月网络重置..."

# 0. 读取当月状态
CUR_MONTH=\$(date '+%Y-%m')
[ -f "\$STATE_FILE" ] && . "\$STATE_FILE"
[ -z "\$STATE" ] && STATE=normal
[ -z "\$MONTH" ] && MONTH="\$CUR_MONTH"

# 1. 删除旧的流量监控日志
if [ -f "\$TRAFFIC_LOG" ]; then
    rm -f "\$TRAFFIC_LOG"
    log "已删除旧的流量监控日志: \$TRAFFIC_LOG"
else
    log "流量监控日志不存在，无需删除。"
fi

# 2. 重置防火墙规则
# 只移除本脚本的封网规则 (TRAFFIC_BLOCKED 链及三条跳转规则)，不影响其他程序
iptables -D INPUT    -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED 2>/dev/null
iptables -D OUTPUT   -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED 2>/dev/null
iptables -D FORWARD  -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED 2>/dev/null
# 兜底: 若按上面匹配不到，再按跳转目标删除一遍 (只删自家跳转)
iptables -D INPUT    -j TRAFFIC_BLOCKED 2>/dev/null
iptables -D OUTPUT   -j TRAFFIC_BLOCKED 2>/dev/null
iptables -D FORWARD  -j TRAFFIC_BLOCKED 2>/dev/null
# 清空并删除自家链
iptables -F TRAFFIC_BLOCKED 2>/dev/null
iptables -X TRAFFIC_BLOCKED 2>/dev/null
log "已移除本脚本的封网规则 (TRAFFIC_BLOCKED)，网络恢复。"

# 3. 重置 vnStat 数据库
systemctl stop vnstat
vnstat --remove --force -i "\$INTERFACE"
vnstat --add -i "\$INTERFACE"
systemctl start vnstat

# 强制刷新一次数据以确保数据库建立
sleep 3
vnstat -i "\$INTERFACE" > /dev/null 2>&1

log "vnStat 数据库已重置 (接口: \$INTERFACE)。"

# 4. 网络恢复后发送 TG 通知 (仅当上月处于断网状态时发送一次)
#    在防火墙已全部放开之后发送 (此时网络可用，能获取 IP)
sleep 1

# 判定是否需要发恢复通知: 仅当 STATE=blocked (即上个周期确实断过网) 才需要
NEED_RESTORE=0
if [ "\$STATE" = "blocked" ]; then
    NEED_RESTORE=1
fi

# 更新状态文件: 恢复 -> normal，记录恢复时间，进入新月份周期
STATE=normal
MONTH="\$CUR_MONTH"
RESTORED_TIME=\$(date '+%Y-%m-%d %H:%M:%S')
cat > "\$STATE_FILE" <<STATE_EOF
MONTH=\$MONTH
STATE=\$STATE
BLOCKED_TIME=\$BLOCKED_TIME
BLOCKED_TX=\$BLOCKED_TX
RESTORED_TIME=\$RESTORED_TIME
STATE_EOF

if [ "\$NEED_RESTORE" -eq 1 ]; then
    read -r MASKED_IP LOC FULL_IP <<< "\$(get_ip_and_loc)"
    RUN_TIME=\$(date '+%Y-%m-%d %H:%M:%S')
    MONTH_TX=\$(get_monthly_tx)
    # CPU 行 (仅 ORACLE 显示)
    CPU_LINE=""
    if [ "\$PLATFORM" = "ORACLE" ]; then
        CPU_LINE="
🌐 CPU: \$(get_cpu_type)"
    fi

    TG_MSG="🎮 \$PLATFORM 流量报告（网络恢复通知）

🌐 本机IP: \$MASKED_IP (\$LOC)
🕐 运行时间: \$RUN_TIME
📚 网络状态: 断网----网络恢复
🌐 本月流量: \$(format_traffic "\$MONTH_TX") / 上限: \$LIMIT GB\${CPU_LINE}"

    tg_send "\$TG_MSG"
    log "已发送网络恢复 TG 通知。"
else
    log "上月网络正常，无需发送恢复通知。"
fi
EOF

# 7. 赋予执行权限
chmod +x /root/check_traffic.sh
chmod +x /root/reset_network.sh

# 8. 设置定时任务
echo "--> 更新 Crontab 定时任务..."
crontab -l > /tmp/cron_bk 2>/dev/null

# 清理旧任务，防止重复
sed -i '/check_traffic.sh/d' /tmp/cron_bk
sed -i '/reset_network.sh/d' /tmp/cron_bk

# 添加新任务
# 每5分钟检查一次流量
echo "*/5 * * * * /root/check_traffic.sh" >> /tmp/cron_bk
# 每月1号 00:00 重置网络和日志
echo "0 0 1 * * /root/reset_network.sh" >> /tmp/cron_bk

crontab /tmp/cron_bk
rm /tmp/cron_bk

echo "=========================================="
echo " 安装完成！ (Telegram 通知版 / $PLATFORM)"
echo "=========================================="
echo "您可以手动运行以下命令查看精确流量："
echo "  bash /root/check_traffic.sh"
echo ""
echo "监控日志位置："
echo "  /var/log/traffic_monitor.log"
echo "=========================================="
echo "当前配置："
echo "  平台       : $PLATFORM"
echo "  流量上限   : $LIMIT GB"
echo "  SSH 端口   : $SSH_PORT"
echo "  封网策略   : 超限时双向封锁 (INPUT+OUTPUT DROP)"
echo "             仅保留 SSH / DNS / lo 通行"
echo "  TG 通知    : 断网时 + 每月1号恢复时"
echo "=========================================="