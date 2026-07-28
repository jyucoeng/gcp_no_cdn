#!/bin/bash

# 【需改1】：IP 文件路径（改成你机器上存 IP 列表的实际路径），记得提前把这个json文件放到你指定的文件夹（请注意：这个文件夹不需要你自己去创建，而是你google账号的名字，所以你不能瞎写）去。
IP_FILE="/home/yunxiao/akamai_firewall_rule.json"

# 【可改2】：规则名称前缀（建议个性化一点，避免和别人的冲突）
RULE_PREFIX="no-akamai"

# 【一般不改】：指定使用的网络名称（GCP 默认是 default）
NETWORK="default"

# 【一般不改】：出站规则（也可设置为 INGRESS 代表入站）
DIRECTION="EGRESS"

# 【可改3】：优先级（0～65535，数字越小优先级越高）
PRIORITY=1000

# 【需改4】：目标实例标签（只有打上这个标签的实例才会应用该规则）
TARGET_TAGS="no-cdn"

# 【一般不改】：动作设为 deny 表示阻止流量
ACTION="deny"

# 【可改5】：协议类型，"all" 表示所有协议；也可以是 tcp/udp/icmp 等
PROTOCOL="all"

# 检查 jq 是否可用
if ! command -v jq &> /dev/null; then
    echo "错误：需要安装 jq 工具来解析 JSON 文件"
    exit 1
fi

# 使用 jq 解析 JSON 文件并读取 IP 列表到数组
mapfile -t IPS < <(jq -r '.destinationRanges[]' "$IP_FILE")

# 每条防火墙规则最多允许 256 个 IP
MAX_IP=256
TOTAL_IP=${#IPS[@]}
NUM_RULES=$(( (TOTAL_IP + MAX_IP - 1) / MAX_IP ))

echo "总IP数: $TOTAL_IP, 需要创建规则数: $NUM_RULES"

# 分批创建防火墙规则
for ((i=0; i<NUM_RULES; i++)); do
    start=$((i * MAX_IP))
    end=$((start + MAX_IP))
    if [ $end -gt $TOTAL_IP ]; then
        end=$TOTAL_IP
    fi

    # 提取当前批次 IP 子集
    IP_SUBLIST=$(printf ",%s" "${IPS[@]:$start:$((end - start))}")
    IP_SUBLIST=${IP_SUBLIST:1}

    # 规则名称增加编号
    RULE_NAME="${RULE_PREFIX}-${i}"

    echo "创建防火墙规则 $RULE_NAME，包含IP数: $((end - start))"

    # 创建防火墙规则命令
    gcloud compute firewall-rules create "$RULE_NAME" \
      --network "$NETWORK" \
      --direction "$DIRECTION" \
      --priority "$PRIORITY" \
      --target-tags "$TARGET_TAGS" \
      --action "$ACTION" \
      --rules "$PROTOCOL" \
      --destination-ranges "$IP_SUBLIST"
done