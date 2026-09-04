# netMonitor — 流量监控自动部署脚本

针对 **GCP / Oracle Cloud** 的 Linux 实例（Ubuntu/Debian apt 系）的流量监控与自动止损脚本。
通过监控网卡出站流量 (TX)，超限后**双向封网**（INPUT + OUTPUT 全部 DROP，仅保留 SSH / DNS / lo），并通过 TG 通知状态变化。

> 注意：仅适用于 Debian/Ubuntu（使用 `apt-get`、`systemctl`、`crontab`）。**不支持 Alpine**（其使用 `apk` / OpenRC / `crond`）。

---

## 一、脚本用途与选择

| 脚本 | 用途 | 是否发 TG 通知 |
|------|------|----------------|
| `net_iptables.sh` | 基础版：超限封网 + 每月自动重置 | 否 |
| `net_iptables_tg.sh` | TG 通知版：在基础版功能上，额外在断网时/网络恢复时发送 Telegram 消息 | 是 |

**如何选择：**
- 只需要封网止损、不需要消息告警 → 用 `net_iptables.sh`
- 希望超限/恢复时收到 TG 通知 → 用 `net_iptables_tg.sh`（须先填 TG 常量）

两个脚本都**同时支持 GCP 和 Oracle**，用 `PLATFORM` 常量区分平台，无需维护两套文件。

---

## 二、共通常量（两个脚本均适用）

| 常量 | 说明 | 默认 |
|------|------|------|
| `PLATFORM` | 平台标识：`GCP` 或 `ORACLE` | `GCP` |
| `LIMIT` | 出站流量上限（GB），超限触发封网。留空则按平台自动 | GCP=`180`，ORACLE=`9216`(9TB) |
| `SSH_PORT` | 封网后仅放行的 SSH 管理端口 | `22` |
| `DNS_SERVERS` | 封网后允许的 DNS 服务器 | `8.8.8.8 1.1.1.1` |

`LIMIT` 自动取值逻辑：

```
PLATFORM=GCP    -> LIMIT=180    (不做强制，支持手动覆盖)
PLATFORM=ORACLE -> LIMIT=9216   (9TB，贴近免费层约10TB额度)
```

> 若想手动指定一个固定上限，直接给 `LIMIT` 赋值即可（如 `LIMIT=500`）。

### ORACLE 平台额外行为
当 `PLATFORM=ORACLE` 时，部署脚本会自动**停用 firewalld / ufw**，并清空 iptables 现有规则，避免与脚本的 iptables 规则冲突（Oracle 实例常预装 ufw）。GCP 平台不做此处理。

---

## 三、TG 通知版专属常量（仅 `net_iptables_tg.sh`）

| 常量 | 说明 |
|------|------|
| `TELEGRAM_BOT_TOKEN` | Telegram Bot 的 token（`@BotFather` 创建，**必填**） |
| `TELEGRAM_CHAT_ID` | 接收通知的 chat id（**必填**） |
| `PLATFORM` | 影响通知标题、CPU 行、上限默认值 |

> 两个 TG 常量默认值为空，**部署前必须填入**，否则通知不会发送。

`PLATFORM` 对 TG 通知的影响：

| 特性 | `GCP` | `ORACLE` |
|------|-------|----------|
| 标题 | `🎮 GCP 流量报告` | `🎮 ORACLE 流量报告` |
| CPU 行 | 无 | `🌐 CPU: AMD/ARM` |
| 上限默认 | 180GB | 9TB(9216GB) |

---

## 四、部署与使用

### 1. 前置准备
- 以 **root** 身份执行（脚本开头会检查）。
- 选择目标平台，修改脚本顶部的 `PLATFORM`；若用 TG 版，填入 `TELEGRAM_BOT_TOKEN`、`TELEGRAM_CHAT_ID`。

### 2. 执行部署
```bash
# 基础版，目标为 GCP
bash net_iptables.sh

# TG 通知版，目标为 Oracle（先改 PLATFORM=ORACLE 并填 TG 常量）
bash net_iptables_tg.sh
```

部署过程会：
1. 自动探测默认网卡（`ip route` 默认路由段）
2. 安装依赖：`vnstat`、`bc`（TG 版还会装 `curl`）
3. 初始化并启动 vnStat 数据库
4. 生成两个运行时脚本并写入 `/root/`：
   - `/root/check_traffic.sh` — 流量检查 & 封网
   - `/root/reset_network.sh` — 每月重置
5. 配置 crontab（自动去重）

### 3. 生成的定时任务（crontab）
| 计划 | 命令 | 说明 |
|------|------|------|
| 每 **5 分钟** (`*/5 * * * *`) | `/root/check_traffic.sh` | 定时读取流量，超限即封网 |
| 每月 **1 号 00:00** (`0 0 1 * *`) | `/root/reset_network.sh` | 每月重置流量/日志并解除封网 |

> 即 `check_traffic.sh` 每 5 分钟执行一次；`reset_network.sh` 每月 1 号零点执行一次。如需调整频率，改部署脚本里对应的 crontab 行后重新部署。

### 4. 封网策略（全局封锁，仅影响本脚本，不干扰其他程序）
超限后，本脚本**只操作自己创建的 `TRAFFIC_BLOCKED` 链**，不改全局默认策略、不全局清空，**不影响其他程序已有的 iptables 规则**。封网范围覆盖 **INPUT / OUTPUT / FORWARD 三条链**，实现真正全局封锁。

封网时执行：
```bash
# 创建/复用自家链 TRAFFIC_BLOCKED
iptables -N TRAFFIC_BLOCKED 2>/dev/null || iptables -F TRAFFIC_BLOCKED
# 链内放行：已建立连接、SSH、DNS、ICMP、loopback
iptables -A TRAFFIC_BLOCKED -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A TRAFFIC_BLOCKED -p tcp --dport $SSH_PORT -j ACCEPT
iptables -A TRAFFIC_BLOCKED -p udp --dport 53 -d <DNS> -j ACCEPT   # 各 DNS 服务器
iptables -A TRAFFIC_BLOCKED -p icmp -j ACCEPT
iptables -A TRAFFIC_BLOCKED -i lo -j ACCEPT
# 链内兜底 DROP：未放行的流量在本链终结，不回到主链
iptables -A TRAFFIC_BLOCKED -j DROP

# 在三条主链最顶部各插入一条跳转规则（-I 1），实现全局封锁
iptables -I INPUT   1 -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
iptables -I OUTPUT  1 -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
iptables -I FORWARD 1 -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
```

**机制说明：**
- 放行：已建立连接（ESTABLISHED,RELATED）、SSH(`$SSH_PORT`)、DNS(`$DNS_SERVERS`)、ICMP(ping)、loopback。
- 其余未放行的出入站及转发流量，在 `TRAFFIC_BLOCKED` 链内被兜底 `DROP` 拦截 → 达到"全局封锁、仅留 SSH/DNS"效果。
- 因为跳转插在**最顶部**且链内兜底 DROP 是终结动作，其他程序（如程序 a）的 ACCEPT 规则会被本轮封网**覆盖**（但**未被删除**）。
- 默认策略（`-P`）、其他链的内容、其他程序规则全部保持不变。
- 封网规则带明显注释 `TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)`，一眼可识别是程序封网。

**恢复时只删除本脚本的三条跳转 + 自家链（解网=移除本脚本封锁，其他程序自然恢复）：**
```bash
iptables -D INPUT    -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
iptables -D OUTPUT   -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
iptables -D FORWARD  -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
iptables -F TRAFFIC_BLOCKED 2>/dev/null
iptables -X TRAFFIC_BLOCKED 2>/dev/null
```
删除后，其他程序的规则（如程序 a）**自然恢复生效**，无需任何额外处理。

### 5. 手动查看流量
```bash
bash /root/check_traffic.sh
```
终端会显示精确出站字节数/GB；详情日志在 `/var/log/traffic_monitor.log`。

---

## 五、TG 通知与状态机制（仅 `net_iptables_tg.sh`）

### 通知时机
| 时机 | 标题 | 触发条件 |
|------|------|---------|
| 超限断网前 | `🎮 {PLATFORM} 流量报告（断网通知）` | 流量首次 ≥ LIMIT，封网前发送一次 |
| 每月 1 号恢复 | `🎮 {PLATFORM} 流量报告（网络恢复通知)` | 上月曾处于断网状态，本次 reset 恢复后发送一次 |

### 通知内容（模板）
```
🎮 ORACLE 流量报告（断网通知）

🌐 本机IP: 152.69.***.146 (Osaka-JP)
🕐 运行时间: 2026-09-04 10:20:33
📚 网络状态: 正常 ---> 断网
🌐 本月流量: 123.45GB / 上限: 9216 GB
🌐 CPU: AMD        ← 仅 ORACLE 显示
```
- **本机IP**：自动获取公网 IPv4 并打码（`a.b.***.d`），国家/城市取 `ip-api.com`（重试 3 次，失败降级仅显示国家 → `unknown`）
- **本月流量**：按层级自动换算 `MB → GB → TB`（<1GB 用 MB；<1024GB 用 GB；≥1024GB 用 TB）
- **运行时间**：服务器当前时间
- **CPU**（仅 ORACLE）：`aarch64`→ARM；型号含 `AMD`/`EPYC`→AMD

### 状态文件（保证"同一事件周期只发一次"）
状态记录在 `/var/lib/traffic_monitor/state`：
```
MONTH=2026-09      # 当前跟踪月份
STATE=normal       # normal / blocked
BLOCKED_TIME=      # 本月断网时刻
BLOCKED_TX=        # 断网时已用流量(字节)
RESTORED_TIME=     # 恢复时刻
```
- 同一断网周期内（STATE 已为 `blocked`），重复运行 check 时**不再发断网通知**，避免刷屏。
- 每月 reset 恢复后，若上月确实断过网才发恢复通知，并进入新月份周期。

---

## 六、封网后如何手动解锁 / 恢复

每月 1 号 `reset_network.sh` 会自动恢复。
如需手动立即解锁（只删本脚本的规则，不影响其他程序）：
```bash
iptables -D INPUT    -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
iptables -D OUTPUT   -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
iptables -D FORWARD  -m comment --comment "TRAFFIC_BLOCKED: 脚本封网(仅SSH/DNS/lo)" -j TRAFFIC_BLOCKED
iptables -D INPUT    -j TRAFFIC_BLOCKED 2>/dev/null
iptables -D OUTPUT   -j TRAFFIC_BLOCKED 2>/dev/null
iptables -D FORWARD  -j TRAFFIC_BLOCKED 2>/dev/null
iptables -F TRAFFIC_BLOCKED
iptables -X TRAFFIC_BLOCKED
```

---

## 七、文件清单与说明

| 文件 | 说明 |
|------|------|
| `net_iptables.sh` | 基础版（无 TG 通知） |
| `net_iptables_tg.sh` | TG 通知版 |
| `README.md` | 本文档 |

> 旧版本：曾拆分为 GCP / Oracle 两个独立文件，现已合并为单脚本，用 `PLATFORM` 区分，故相关独立文件已移除。