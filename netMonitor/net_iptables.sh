#!/bin/bash

# ==========================================
# 流量监控自动部署脚本 (通用 GCP & Oracle)
# 功能：
# 1. 自动获取网卡，只监控出站流量 (TX)
# 2. 运行 check_traffic.sh 时终端显示精确流量，日志保留简略信息
# 3. 每月重置流量并删除旧的监控日志
# 4. 超限后双向封网 (INPUT + OUTPUT 全部 DROP)，仅保留 SSH / DNS / lo
# 5. ORACLE 平台自动停用 firewalld / ufw，避免与 iptables 冲突
#
# 平台差异通过 PLATFORM 区分：
#   PLATFORM=GCP    -> 上限默认 180GB
#   PLATFORM=ORACLE -> 上限默认 9TB(9216GB)，并自动停用 firewalld/ufw
# ==========================================

# ==========================================
# 可配置常量 (部署前请按需修改)
# ==========================================
# 平台标识: GCP 或 ORACLE (决定上限默认值、是否停用 firewalld/ufw)
PLATFORM="GCP"

# 出站流量上限 (GB)，超过该值触发封网
# 留空时按 PLATFORM 自动设置: GCP=180, ORACLE=9216
LIMIT=""

# SSH 端口，封网后仅放行此端口用于远程管理
SSH_PORT=22
# DNS 服务器，封网后允许的 DNS 查询 (用于解析，保持基本可用)
DNS_SERVERS="8.8.8.8 1.1.1.1"
# ==========================================

# 若未手动设置 LIMIT，则按平台取默认值
if [ -z "$LIMIT" ]; then
    if [ "$PLATFORM" = "ORACLE" ]; then
        LIMIT=9216
    else
        LIMIT=180
    fi
fi

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

# 3. 安装依赖工具
echo "--> 正在更新软件源并安装工具..."
apt-get update -y
apt-get install vnstat bc -y

# 3.5 停用 firewalld / ufw (仅 ORACLE 平台，避免与 iptables 规则冲突)
if [ "$PLATFORM" = "ORACLE" ]; then
    echo "--> 检查并停用 firewalld / ufw..."
    # 停用 firewalld (RHEL 系)
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        systemctl stop firewalld
        systemctl disable firewalld
        echo "    firewalld 已停用。"
    elif systemctl list-unit-files | grep -q '^firewalld.service'; then
        systemctl disable firewalld 2>/dev/null
    fi
    # 停用 ufw (Ubuntu/Debian 系)
    if command -v ufw >/dev/null 2>&1; then
        ufw --force disable >/dev/null 2>&1
        systemctl disable ufw 2>/dev/null
        echo "    ufw 已停用。"
    fi
    # 注意: 不停用也不再清空现有 iptables 规则，避免影响其他程序
fi

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

# 日志记录函数 (保持原格式)
log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" >> "\$LOG_FILE"
}

# 权限检查
if [ "\$(id -u)" -ne 0 ]; then
    echo "错误：需要 root 权限"
    exit 1
fi

# 获取流量数据 (强制使用 'b' 参数获取字节单位)
# 输出格式示例: 1;ens4;2026-01-15;RX_BYTES;TX_BYTES;...
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
# 2. 日志记录与限制逻辑 (保持简洁)
# ==========================================

log "当前出站流量: \$TX_GB GB (限制: \$LIMIT GB)"

# 检查是否超限
if [ \$(echo "\$TX_GB >= \$LIMIT" | bc) -eq 1 ]; then
    echo "状态: [警告] 流量已超限，正在应用防火墙规则..."
    log "警告：流量超出限制！正在执行封禁策略..."
    
    # 封禁策略 (双向封锁，仅影响本脚本内容)
    # 不改变全局默认策略(-P)、不全局清空(-F/-X)，只操作自家 TRAFFIC_BLOCKED 链，
    # 避免影响其他程序/服务已有的 iptables 规则。
    # 创建或复用自家链 (已存在则清空重建)
    iptables -N TRAFFIC_BLOCKED 2>/dev/null || iptables -F TRAFFIC_BLOCKED

    # ---- 在 TRAFFIC_BLOCKED 链内定义放行规则 ----
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

    # ---- 在主链最顶部各插入一条跳转到 TRAFFIC_BLOCKED (仅本脚本三条) ----
    # 覆盖 INPUT / OUTPUT / FORWARD，实现真正全局封网；
    # 用 -I 1 插到最前，确保封网生效；不动各链已有的其他规则与默认策略
    iptables -I INPUT   1 -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
    iptables -I OUTPUT  1 -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
    iptables -I FORWARD 1 -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED

    log "网络已限制 (TRAFFIC_BLOCKED 全局封锁，仅保留 SSH / DNS / lo)。"
else
    echo "状态: [正常] 流量未超限。"
    log "流量正常。"
fi
EOF

# 6. 生成重置脚本 (/root/reset_network.sh)
echo "--> 生成重置脚本 /root/reset_network.sh..."
cat > /root/reset_network.sh <<EOF
#!/bin/bash

RESET_LOG="/var/log/network_reset.log"
TRAFFIC_LOG="/var/log/traffic_monitor.log"
INTERFACE="$INTERFACE"

log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" >> "\$RESET_LOG"
}

log "开始执行每月网络重置..."

# 1. 删除旧的流量监控日志 (新增功能)
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
echo " 安装完成！ ($PLATFORM)"
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
[ "$PLATFORM" = "ORACLE" ] && echo "  已自动停用 : firewalld / ufw"
echo "=========================================="
