#!/bin/sh
# bootstrap/_lib.sh —— 全局定义 + 基础设施
#
# 拆分自 crowdsec-lxc-bootstrap.sh（2026-11-10）。内容：
#   · 文件头说明、全部路径与阈值变量（LXC_PATH / ROOTFS / STATE_DIR / 各 *_FILE）
#   · log / run / run_svc / ct / _wait / atomic_write
#   · 容器查询（ct_running / ct_exists / ct_pid）、nft 查询
#   · 跨组共享的判定辅助（被两个及以上组调用的那些）
# 被谁用：bootstrap.sh、_dag.sh、每个 */step.sh —— 所有入口第一行都 source 它。

#!/bin/sh
# 【2026-11-07.2245】固件版本标记 —— 与 crowdsec-lxc-bootstrap.sh 的 SCRIPT_VER 同步，每次改脚本一起改
# crowdsec-lxc-bootstrap（旁路由版）
# 适用拓扑：单臂旁路由——所有物理网口桥进 br-lan，WAN/WAN6 一律禁用，
#   出口走上游网关，本机不拨号、不跑 DHCP 服务（lan.ignore=1）。
# 八组链：NETBASE → INSTALL → PREP → CAPIBLOCK → BOOT → LOGCONF → LAPI →
#   BOUNCERVERIFY → ENROLL（顺序由 GROUP_SEQ 决定），
#   每组执行前校验所有前置组已置位，全通才置位，失败不置位。
#   唯一真实的硬顺序：NETBASE → INSTALL + PREP → CAPIBLOCK → BOOT →
#   (LOGCONF | LAPI) → BOUNCERVERIFY → ENROLL
#   （config.yaml / acquis / resolv.conf / 网络文件都是 crowdsec 与 systemd 启动时读一次，
#     所以「改静态配置」必须排在开机之前；LOGCONF 与 LAPI 之间没有依赖）。
# 【职责边界 v.180.157】本脚本只做六件事：网络配置（含防火墙）、网桥配置、
#   容器网络配置、lxc 与 bouncer 恢复、crowdsec 容器恢复、crowdsec 与 bouncer 的本地联动配置。
#   smartdns 整套移出 —— 恢复 / 配置 / 状态验证归 pkg-restore-smartdns.sh
#   （--config / --repair）与 crowdsec-lxc-probe.sh，本脚本一行都不碰。
# 【网络侧：验证 + 修改】v.95 起，网络/防火墙节点不再"只验不写"：verify 不符就 build 改回来，
#   然后 uci commit + 按组 reload 让改动真正生效（commit 只落盘，reload 才生效）。
#   不设回滚：改完复核仍不过 → ensure 判 hard，引导终止。
#   分组 reload：network → network reload；dhcp → dnsmasq restart；
#                firewall → firewall reload（fw4 重建整张 nft 表）。
#   脚本会写的东西（按配置面分）：
#     · /etc/config/network   桥端口 / lan 静态地址 / 删 wan+wan6 段 / lxcbr0 段与地址
#     · /etc/config/dhcp      lan.ignore（关 DHCP / RA / authoritative）
#     · 必备组件            lxc：pkg_base 只判不装，缺则从只读基座 /rom 装回
#                             （不联网：包在 /rom/root/pkg-cache，走 file:// 本地源）
#     · /etc/config/firewall  lxc zone + 3 条 forwarding / wan·lan input / SNAT /
#                             docker zone + 3 条 rule（仅装了 dockerd 时）
#     · /proc/sys/net/ipv4/ip_forward  置 1（写完必须回读，读不回来判失败）
#     · /etc/config/dropbear  服务绑定接口（局部 commit + reload）
#     · /etc/config/system    log_ip/log_port（日志推送到容器）
#     · /etc/config/crowdsec  api_url/api_key（bouncer 注册）
#   改网络前有「不自杀」保护（_net_write_guard + SSH 来源判定），但仍需自担风险：
#   把 br-lan 或 lan 地址改错，本会话可能直接失联。
#   WAN 段：必须整段删除（不是 disabled=1）——新 nft 后台不认可 disabled 标志，
#   段只要还在就会按 proto/device 起接口并挂 WAN zone，旁路由就名不副实。
#   你要恢复拨号在 LuCI 新建 WAN 即可，脚本下次引导会再删（旁路由语义闭环）。
# 【退出即恢复】v.98 起，脚本无论怎么退出（正常 return / exit N / Ctrl-C / kill /
#   SSH 断线），都会走同一套恢复逻辑，不留半截置位：
#     ① 进程内变量 GSET_<组> / _done_<节点> / _dirty_<节点> / _failed ← 归零
#     ② 内核态 ip_forward ← 若本轮由脚本从 0 改成 1、且最终没写 installed 标记，
#        则还原为原值（引导成功则保留 1，那是期望稳态）
#     ③ 磁盘标记 reinstall_pending ← 刻意不清（它就是靠"崩溃后残留"计失败次数），
#        只在日志里交代它现在的状态
#   实现要点：EXIT + INT + TERM + HUP 四个 trap 都装；信号处理里必须把 EXIT trap
#   也摘掉，否则 exit 会二次触发 EXIT、恢复逻辑跑两遍（这个坑踩过一次）。
#   顺序：先做重装失败计数、再做恢复——反了的话计数会读到已被清空的状态。

SCRIPT_VER="2026.11.10"

LXC_NAME="${LXC_NAME:-ubuntu}"
CS_HOME="${CS_HOME:-/etc/crowdsec}"
LXC_PATH="${LXC_PATH:-/srv/lxc}"
ROOTFS="$LXC_PATH/$LXC_NAME/rootfs"
CFG="$LXC_PATH/$LXC_NAME/config"
TARBALL="${TARBALL:-$CS_HOME/lxc-crowdsec.tar.gz}"
LEGACY_TARBALL="/opt/lxc-ubuntu.tar.gz"
# 【v.108.56】容器固定文件常驻 /rom 只读基底，可变部分走 overlay 可写层。
# upper/work 必须在 /overlay（f2fs）：overlay 的 upperdir 不能是另一个 overlayfs，
# 而 /srv 就叠在 rootfs overlay 上（真机实测 rc=32 "not supported as upperdir"）。
ROM_BASE="${CS_ROM_BASE:-/rom/srv/lxc/ubuntu/base}"
OVL_UPPER="${CS_OVL_UPPER:-/overlay/lxc-upper}"
OVL_WORK="${CS_OVL_WORK:-/overlay/lxc-work}"
LAPI_PORT="${LAPI_PORT:-8080}"
BOUNCER_NAME="${BOUNCER_NAME:-openwrt-fw}"
ENROLL_KEY_FILE="${ENROLL_KEY_FILE:-/etc/config/crowdsec_enroll_key.txt}"
# 【v.108.52】注册码「保险柜」：注册成功后不再 rm 掉 key，而是移到同名 .keep（600）。
# 为什么改：v.99 起「注册成功即删」是为了不让明文 key 留在公开固件上，但 key 同时也是
# 设备唯一的自愈凭据 —— 网页端手滑关闭实例后 re_enroll 读不到 key，只能重刷固件。
# 折中：留在 /etc/config（sysupgrade 默认保留 → 升级后自愈能力不丢），但不参与固件分发，
# 且日志里只出现路径不出现内容。
ENROLL_KEY_KEEP="${ENROLL_KEY_KEEP:-${ENROLL_KEY_FILE}.keep}"
# 【v.108.54】「已提交、等网页 Accept」的判定改成「按开机计」。
# 演进过程：
#   v.108.52：未注册就判失败 → 每次复验都重新提交，网页堆 pending；
#   v.108.53：落盘标记 + 永不自动重试 → 网页误点「拒绝」后永久失联，只能 SSH 删文件；
#   v.108.54：**每次开机允许尝试一次**。同一开机内靠进程变量 _ENROLL_TRIED 只提交一次，
#             重启即刷新状态 —— 误点拒绝/误删后重启一次就自动回来，不需要任何手工命令。
# 落盘文件仍保留，但只用于「记录上次提交时间、便于排查」，不再当闸门。
ENROLL_SUBMIT_FILE="${ENROLL_SUBMIT_FILE:-/etc/config/crowdsec_enroll_submitted}"
_ENROLL_TRIED=0
_ENROLL_WAIT_LOGGED=0
MAX_WAIT="${MAX_WAIT:-60}"
SLEEP=5
CROWDSEC_CFG="$ROOTFS/etc/crowdsec/config.yaml"
CSCLI=/usr/bin/cscli
# 【v.108.28】lxc-auto 的服务脚本与配置文件路径。抽成变量不是为了可配，
# 而是为了让「配置空了会不会被补」这件事能被真的跑出来验（指到临时文件）。
LXC_AUTO_INIT="${CS_LXC_AUTO_INIT:-/etc/init.d/lxc-auto}"
LXC_AUTO_CFG="${CS_LXC_AUTO_CFG:-/etc/config/lxc-auto}"
# 只读基准：guard 拿它当"原样"的比对源，这里拿它当"服务脚本被删了去哪捞回来"。
LXC_AUTO_ROM="${CS_LXC_AUTO_ROM:-/rom}"

# ---- 重装自愈（escalation tier 3）持久状态 ----
# 唯一持久位 installed：本流程曾完整跑通（online_client 放出步之后置位；
# enroll 需网站人工 Accept，不算安装成功判据）。_done_* 保持内存语义不变。
# STATE_DIR 落在 rootfs 同级：tier-3 抹 rootfs 不波及；删容器才随之消失。
STATE_DIR="${CS_BOOTSTRAP_STATE:-$LXC_PATH/$LXC_NAME/.bootstrap}"
STAMP_FILE="$STATE_DIR/installed"
REINSTALL_FAIL_FILE="$STATE_DIR/reinstall_fail"
REINSTALL_PENDING_FILE="$STATE_DIR/reinstall_pending"
CRED_BACKUP_DIR="$STATE_DIR/cred-backup"
# 【v.108.51】凭据的「活过刷机」那一份：/srv/lxc 既不 /etc/sysupgrade.conf，也不在
# 任何 /lib/upgrade/keep.d 里 —— 刷机时整个容器连同凭据一起消失（真机核对 2026-10-22：
# sysupgrade.conf 只有 /etc/crowdsec/lxc-crowdsec.tar.gz 与 lxc-ubuntu.tar.gz 两条，
# keep.d 33 项全是包名，没有一个覆盖 /srv）。
# 而 /etc/config 由 base-files-essential 保留，所以持久副本放这里：
# 刷机后 rootfs 重解压、凭据为空时由 _cred_restore 放回去，console 侧实例身份不变，
# 不用重新 register/enroll，也不会在 console 里多出一条 offline 记录。
CRED_KEEP_FILE="${CS_BOOTSTRAP_CRED_KEEP:-/etc/config/crowdsec_credentials_keep.yaml}"
# 【v.108.25】静态配置的 sha 基线：只覆盖脚本自己写的那几份文件（主配置 / 采集源 /
# 两个解析器）。跑完一轮后记下它们长什么样，之后每次 verify 重算比对 ——
# 「文件在、结构对」不等于「内容还是我写的那份」，被人改过一个字符也算不符。
# 不比整目录指纹：目录里多一个用户自己加的解析器，不该被判定为不符。
CFG_SHA_FILE="$STATE_DIR/cfg_sha"
# 【v.108.18】「重启之后才重置，一次」的判据：boot_id 认「本次开机的首跑」。
# 开机首跑允许重置；探针在运行期重跑 bootstrap 时 boot_id 不变、标记已写好 →
# 不是首跑 → 只修不重置（运行期抹 rootfs 会中断正在跑的容器，多半也只需修）。
# 首次安装（从未有 installed 标记）由 _stamp_present 那道门挡住，同样不重置。
BOOT_ID_FILE="$STATE_DIR/boot_id"
# 【v.108.19】重置额度记账：内容 = 上一次「用掉重置权」时的 boot_id。
# 与 boot_id 不同 = 本次开机还没用过额度 → 可以重置一次；相同 = 已用过 → 拒绝。
RESET_BOOT_FILE="$STATE_DIR/reset_boot"
# 【v.108.20】「抹盘后断电」的续做计数：rootfs 已经没了，重建是唯一恢复途径，
# 不能把它当成「又一次失败」拒掉；但真遇到每解压必断电的环境，也要有个上限收口。
INTR_FILE="$STATE_DIR/reinstall_intr"
INTR_MAX="${CS_BOOTSTRAP_INTR_MAX:-3}"
# 【v.108.61】LAPI 自愈第三档（丢可写层）的记账：一行 = <boot_id> <次数> <上次时刻> <诊断签名>
# 三个门缺一不可，理由见 _l3_gate：
#   次数 —— 锚在 boot_id 上，只有「重启设备」才归零；**「恢复」不归零**。
#           若拿「恢复正常」当重置条件，就会变成「坏→丢层→好→再坏→再丢」的周期性抹盘。
#   时间 —— 两次丢层至少隔 6 小时，挡的是「重启循环里每次开机都白得一次机会」。
#   签名 —— 同一个根因上次丢完没好，再丢一次不会有不同结果（v.106 那条原则的延伸）。
L3_STATE="$STATE_DIR/reinstall_l3"
L3_MAX="${CS_BOOTSTRAP_L3_MAX:-1}"
L3_GAP="${CS_BOOTSTRAP_L3_GAP:-21600}"
# 【v.108.21】柔性节点：build 修不回来时只记账、不中止引导。
# 只给「差一点点时机」的节点用，不能拿来掩盖真故障：
#   bouncer_verify 要的是「bouncer 已经成功拉过一次 LAPI」，而首次心跳有 10s 周期延迟，
#   60s 窗口内拉不到就把整轮引导判死、连 installed 都不写 → 探针永远 wait-install。
#   LAPI 是否对外开放已经由 verify_lapi_fetch（宿主侧探测）硬性把关，这里再卡一次
#   只会把「还没到时候」变成「永久停摆」。长期监视本来就是探针的职责。
#   【v.108.49】enroll 加进来：它是「网站侧人工 Accept」这一段外部流程，本地只能
#   把注册码交上去，是否 authenticated 由用户在 console 里点确认决定。注册码错的
#   时候不该让整轮引导死掉、连 installed 都不写（那会让探针每 5 分钟重跑全量）。
SOFT_NODES="${CS_BOOTSTRAP_SOFT_NODES:-bouncer_verify enroll}"
# 【v.108.33】本轮 build 过的节点（flush 清脏标记前记一笔），收尾复核要用。
_built_nodes=""
_BS_FIRST_RUN=0
REINSTALL_MAX="${CS_BOOTSTRAP_REINSTALL_MAX:-1}"   # 连续重装失败达到即停机转人工；0=总开关
# 【v.108.17】默认从 2 收到 1：口径是「运行期只重置一次」。重装跑的是同一套脚本、
# 同一份镜像，第二次只是在同样的前提下再失败一遍，还要多抹一次现场。一次不成即停。
# 同一次运行内的「只重置一次」另由 CS_BOOTSTRAP_REINSTALL 那道防递归门保证
# （重装 exec 出来的进程不会再触发重装）。
_CRED_REL="etc/crowdsec/online_api_credentials.yaml"
_bs_stamped=0

# 【v.108.46】容器网段固定：唯一权威是 rootfs-skel/etc/crowdsec-net.conf，
# 构建期由它写进 tarball 与固件 /rom 两处（同字节），由 crowdsec-guard 逐字节保护。
# 这里直接给常量，不再每轮 sed 解析 —— 解析出来的永远是这两个值；而启动早期
# $ROOTFS 常常还没解压，解析必然落空、回落到同一个常量，等于绕一圈回到原地。
# 容器 DNS 同样固定为网桥 IP：容器查路由器 dnsmasq，上游 DNS 由路由器自己跟。
: "${CONTAINER_IP:=10.1.0.10}"
: "${BRIDGE_IP:=10.1.0.1}"

log() { echo "[$(date '+%F %T')] $*"; }

# ---- 日志封顶（v.108.59）----
# 三处日志里只有这一个没有上限：rc.local 与探针都用 >> 追加同一份文件，
# 而 /root 在 overlay 上层，写进去都是 flash。阈值取 1MB（约十几轮完整引导），
# 超限保留最后 2000 行 —— 一次完整引导约 600~900 行，留够「上一轮 + 这一轮」
# 好对照，常态占用回落到几十 KB。
# 只在真引导开始时截一次：截得太勤会把「上一轮怎么失败的」抹掉，那正是最该看的。
BOOT_LOG="${CS_BOOTSTRAP_LOG:-/root/crowdsec-lxc-bootstrap.log}"
BOOT_LOG_MAX="${CS_BOOTSTRAP_LOG_MAX:-1048576}"
BOOT_LOG_KEEP="${CS_BOOTSTRAP_LOG_KEEP:-2000}"
_boot_log_trim() {
    [ -f "$BOOT_LOG" ] || return 0
    _bl_sz=$(wc -c <"$BOOT_LOG" 2>/dev/null) || return 0
    [ -n "$_bl_sz" ] || return 0
    [ "$_bl_sz" -gt "$BOOT_LOG_MAX" ] 2>/dev/null || return 0
    tail -n "$BOOT_LOG_KEEP" "$BOOT_LOG" >"$BOOT_LOG.tmp" 2>/dev/null || {
        rm -f "$BOOT_LOG.tmp" 2>/dev/null
        return 0
    }
    mv -f "$BOOT_LOG.tmp" "$BOOT_LOG" 2>/dev/null || return 0
    log "【日志】$BOOT_LOG 超过 ${BOOT_LOG_MAX} 字节，已截断为最后 ${BOOT_LOG_KEEP} 行"
    return 0
}

case "$0" in
    /*) _SELF="$0" ;;
    */*) _SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")" ;;
    *) _SELF="$(command -v "$0" 2>/dev/null)" ;;
esac
[ -n "$_SELF" ] && chmod +x "$_SELF" 2>/dev/null
chmod +x /etc/rc.local 2>/dev/null

# 【v.108.66】外层 attach 超时：平时 10s，容器刚起来那一段单独一个上限。
# 【v.108.70】启动窗口那档 60s→30s、窗口 120s→60s。原来的 60s 是 v.108.52 在
# 「怕首次 attach 等 PID1 就绪被截断」时取的保守值，不是量出来的。现在有实测：
# 本机 attach + cscli 0.07~0.38s，纯 shell 更低；容器刚启动时最慢的是 PID1 就绪和
# cgroup 视图，也在个位数秒内返回。30s 已是实测值的近百倍，60s 只买来「卡住时白等
# 一分钟」，而这一分钟正好把探针 tick 一起堵住。
# 两个数各自管什么：
#   · 容器启动成功后 CT_BOOT_GRACE 秒内（默认 60）→ 用 CT_TIMEOUT_BOOT（30s），
#     覆盖 PID1 就绪、cgroup 视图、首轮网络检查这些必然要等的地方；
#   · 窗口之外（正常引导后半段、探针重跑、人工调用）→ 用 CT_TIMEOUT（10s）。
# 三个数都可用同名环境变量覆盖。真机若出现「首次 attach 被判超时」，先用
# CT_TIMEOUT_BOOT=60 CT_BOOT_GRACE=120 复现原状，再判断是值不够还是别的原因，
# 不要直接把这个数改回去掩盖问题。
# 【v.108.70】内层 cscli 收到 8s（下面各处 `timeout 8 $CSCLI`）。原来外层 10s、
# 内层也是 10s，两边同时到点，外层先杀 lxc-attach，内层的 rc=124 和它已经打出来的
# 输出就全丢了，日志只剩一句「attach 超时」—— 分不清是 cscli 卡住还是 attach 卡住。
# 内层小 2s，让它先退出并把真实原因带回来。
CT_TIMEOUT="${CT_TIMEOUT:-10}"
CT_TIMEOUT_BOOT="${CT_TIMEOUT_BOOT:-30}"
CT_BOOT_GRACE="${CT_BOOT_GRACE:-60}"
_CT_BOOT_UNTIL=0
ct() {
    _ct_to="$CT_TIMEOUT"
    if [ "${_CT_BOOT_UNTIL:-0}" -gt 0 ] && [ "$(date +%s)" -lt "$_CT_BOOT_UNTIL" ]; then
        _ct_to="$CT_TIMEOUT_BOOT"
    fi
    # 【2026-11-10.0315】第四条硬依赖 timeout 的位置（前三处是 run/run_svc/run_tar）。
    # 真机实测 line 225: timeout: not found → rc=127，于是每一处 ct / _ct_env
    # 都变成「立刻 127 失败」，PREP 的容器网络探针、LOGCONF、LAPI、enroll 全受影响。
    # _run_capped 定义在下方（第 246 行后），但 shell 函数是调用期求值，
    # 所有 ct 调用都发生在主流程（文件末尾），定义顺序不构成问题。
    _run_capped "$_ct_to" lxc-attach -P "$LXC_PATH" -n "$LXC_NAME" -- "$@"
}

# 【v.108.66】宿主侧外部命令统一超时（A 方案：分三档，不搞一刀切）
# 为什么分档：容器内命令都能 10s，因为它们是「读一个结果」；宿主侧有三类本来就是
# 「重活」，10s 一砍就变成假失败，而假失败比不设超时更糟 ——
#   · firewall reload 会重建整张 nft 表，砍在中间留下的是半张表（转发可能直接断）；
#   · network reload 让 netifd 拆了重加 lxcbr0，砍断等于网络停在半路；
#   · tar -tzf / -xzf 是 100MB 级本地 I/O，10s 必然被砍 —— 一旦真走到解压兜底，
#     10s 就等于让这条路永远失败。
# 所以：
#   run      10s  常规外部命令（lxc-* / uci / nft list / ip / mount / umount /
#                 ping / wget / pgrep / log·logd·dropbear reload）
#   run_svc  60s  重建类与启动类（firewall / network / dnsmasq reload|restart、
#                 lxc-auto start、crowdsec-firewall-bouncer 的 init.d 启停）
#   run_tar  不限（TAR_TIMEOUT=0）tar 校验与解压
# 显式豁免：ping 自带 -W、wget 自带 --timeout 的仍套 run（外层只兜 DNS 卡死），
# 两者不冲突 —— 内层先到点，外层 10s 只是最后的网。
RUN_TIMEOUT="${RUN_TIMEOUT:-10}"
SVC_TIMEOUT="${SVC_TIMEOUT:-60}"
TAR_TIMEOUT="${TAR_TIMEOUT:-0}"
# ---- 【2026-11-10.0310】timeout 兜底（与 rc.local 同一套降级逻辑）----
# 真机实测（192.168.1.201，2026-11-10 03:03）：
#   command -v timeout → rc=127；/bin/timeout 与 /usr/bin/timeout 都不存在；
#   busybox --list | grep -c timeout → 0
# 原实现 run/run_svc/run_tar 每一处都硬依赖 timeout，而全脚本有 300+ 个调用点
# 走的正是这三个函数。结果就是：第一条 `run uci show network` 返回 127 →
# 被判「无法解析 /etc/config/network」→ 直接 exit 1 →
# 28 个小步骤一个都没跑（网络没设、容器没起、guard 没装、smartdns 没配）。
# 现场症状：日志只有一行【前置检查】，Router IP 停在出厂值，页面全绿但什么也没发生。
#
# 这里改成：有 timeout 就用 timeout（行为与原来完全一致）；
# 没有就退化成「后台跑 + 看门狗 sleep/kill」，超时被杀统一换算成 124，
# 保持与 GNU timeout 相同的退出码语义，上层判断不用改。
_BS_TO_PROBED=""
_BS_TO_MISS=""
_run_capped() {
    _bs_cap="$1"; shift
    if [ -z "$_BS_TO_PROBED" ]; then
        if command -v timeout >/dev/null 2>&1; then
            _BS_TO_PROBED=1
        else
            _BS_TO_PROBED=0
            if [ -z "$_BS_TO_MISS" ]; then
                _BS_TO_MISS=1
                echo "[$(date '+%F %T')] 【timeout】固件里没有 timeout 命令，已降级为看门狗模式（功能不变）" >>"$BOOT_LOG" 2>/dev/null
            fi
        fi
    fi
    if [ "$_BS_TO_PROBED" = "1" ]; then
        timeout "$_bs_cap" "$@"
        return $?
    fi
    _bs_tf="/tmp/.bs_cap_$$"
    rm -f "$_bs_tf"
    "$@" &
    _bs_p=$!
    (
        _bs_i=0
        while [ "$_bs_i" -lt "$_bs_cap" ]; do
            kill -0 "$_bs_p" 2>/dev/null || exit 0
            sleep 1
            _bs_i=$((_bs_i + 1))
        done
        : >"$_bs_tf"
        kill -TERM "$_bs_p" 2>/dev/null
        sleep 1
        kill -KILL "$_bs_p" 2>/dev/null
    ) &
    _bs_w=$!
    wait "$_bs_p" 2>/dev/null
    _bs_rc=$?
    kill -TERM "$_bs_w" 2>/dev/null
    wait "$_bs_w" 2>/dev/null
    if [ -f "$_bs_tf" ]; then
        rm -f "$_bs_tf"
        return 124
    fi
    return "$_bs_rc"
}
run() { _run_capped "$RUN_TIMEOUT" "$@"; }
run_svc() { _run_capped "$SVC_TIMEOUT" "$@"; }
run_tar() {
    if [ "${TAR_TIMEOUT:-0}" = "0" ]; then
        "$@"
    else
        _run_capped "$TAR_TIMEOUT" "$@"
    fi
}
ct_running() { run lxc-ls -P "$LXC_PATH" --running 2>/dev/null | grep -qw "$LXC_NAME"; }
ct_exists() { run lxc-info -P "$LXC_PATH" -n "$LXC_NAME" >/dev/null 2>&1; }
ct_pid() { run lxc-info -P "$LXC_PATH" -n "$LXC_NAME" 2>/dev/null | sed -n 's/^PID:[[:space:]]*//p' | head -n1; }
_pgrep_bouncer() { run pgrep -f "crowdsec-firewall-bouncer" >/dev/null 2>&1; }
_ct_env() { ct sh -c 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; '"$1"; }

# ---- 容器 init 类型判别（v.109-min）----
# 本仓库有两种 rootfs 产物，同一份引导脚本必须都能带：
#   · systemd 版（lxc-ubuntu.tar.gz，历史产物）：PID1=systemd，网络走 systemd-networkd，
#     自启走 multi-user.target.wants 软链，cgroup 需要宿主提供 name=systemd 层级；
#   · 极简版（lxc-crowdsec.tar.gz，C 方案）：PID1=busybox init，网络走 /etc/crowdsec-net.conf
#     + /etc/init.d/netconf，自启走 /etc/inittab + /etc/init.d/crowdsec，不需要 cgroup 层级。
# 判据取「inittab 在 + 没有 systemd 二进制」两条同时成立，而不是只看 inittab：
# 只判 inittab 会把「ubuntu rootfs 里恰好有个 inittab」误判成极简版。
# rootfs 可能在脚本启动后才解压出来，所以这里必须是函数、不能是启动期求值。
_is_minimal_init() {
    [ -f "$ROOTFS/etc/inittab" ] || return 1
    [ ! -e "$ROOTFS/lib/systemd/systemd" ] || return 1
    return 0
}

# 容器内 crowdsec 重启：两种 init 统一入口。
# systemd 版原先是 systemctl → service → init.d 三级回落；极简版没有 systemctl/service，
# 直接落到 /etc/init.d/crowdsec。抽成一个函数是为了让 4 个调用点行为一致
# （原先只有 _ensure_lapi_exposed 写了 init.d 回落，enroll 之后的重启在极简版里是空转）。
_ct_restart_crowdsec() {
    _ct_env 'systemctl restart crowdsec' >/dev/null 2>&1 \
        || _ct_env 'service crowdsec restart' >/dev/null 2>&1 \
        || _ct_env '/etc/init.d/crowdsec restart' >/dev/null 2>&1
}

cs_active_on_host() { _pgrep_bouncer; }
nft_table_ready() { run nft list table ip crowdsec >/dev/null 2>&1; }

# 宿主机 bouncer 服务控制（v.99-bp.1）
# OpenWrt/ImmortalWrt 没有 Debian/Ubuntu 的 `service` 包装器，只有 /etc/init.d/<name> <action>。
BOUNCER_INIT="${BOUNCER_INIT:-/etc/init.d/crowdsec-firewall-bouncer}"
bouncer_svc() {
    [ -x "$BOUNCER_INIT" ] || { log "[bouncer] $BOUNCER_INIT 不存在（crowdsec-firewall-bouncer 未进固件）"; return 1; }
    run_svc "$BOUNCER_INIT" "$1" || { log "[bouncer] $BOUNCER_INIT $1 返回非零"; return 1; }
    return 0
}

ct_force_stop() {
    ct_running || return 0
    _r=0
    while [ "$_r" -lt 3 ]; do
        _r=$((_r+1))
        run lxc-stop -P "$LXC_PATH" -n "$LXC_NAME" -k >/dev/null 2>&1
        _i=0
        while ct_running; do
            _i=$((_i+1))
            if [ "$_i" -ge 12 ]; then
                _pid="$(ct_pid)"
                [ -n "$_pid" ] && kill -9 "$_pid" 2>/dev/null
                sleep 1
            fi
            [ "$_i" -ge 24 ] && break
            sleep 2
        done
        ct_running || return 0
        [ "$_r" -ge 3 ] && break
        log "第 $_r 轮强制停止未成功，继续停止（最多 3 轮）"
        sleep 2
    done
    log "容器 3 轮强制停止仍未停止"
    return 1
}

_wait() {
    _wf="$1"; _wn="${2:-$MAX_WAIT}"
    _wi=0
    until "$_wf"; do
        _wi=$((_wi+1))
        [ "$_wi" -ge "$_wn" ] && return 1
        sleep $SLEEP
    done
    return 0
}
_wait_ct_running() { _wait ct_running 12; }

# ---- 原子写（v.79：防半截文件——第一次写入时断电，旧方案会留下内容不齐的正式文件，
# 而 verify 若只验文件名会误判「就绪」，带着坏文件启动必失败）----
atomic_write() {
    _aw_path="$1"; _aw_needle="$2"
    cat > "$_aw_path.tmp" 2>/dev/null || { rm -f "$_aw_path.tmp" 2>/dev/null; return 1; }
    [ -s "$_aw_path.tmp" ] || { rm -f "$_aw_path.tmp" 2>/dev/null; return 1; }
    if [ -n "$_aw_needle" ] && ! grep -q "$_aw_needle" "$_aw_path.tmp" 2>/dev/null; then
        rm -f "$_aw_path.tmp" 2>/dev/null
        return 1
    fi
    mv -f "$_aw_path.tmp" "$_aw_path" 2>/dev/null || { rm -f "$_aw_path.tmp" 2>/dev/null; return 1; }
}

_reattach_ct_veth() {
    run ip link show lxcbr0 >/dev/null 2>&1 || return 1
    # 已经有端口挂着了：说明没掉，什么都不用做
    ip -d link show master lxcbr0 2>/dev/null | grep -q 'veth' && return 0
    ct_running || return 0
    _rv_idx=$(ct sh -c 'cat /sys/class/net/eth0/ifindex' 2>/dev/null | tr -dc '0-9')
    [ -n "$_rv_idx" ] || { log "[网桥] 容器 eth0 ifindex 取不到，放弃重接（veth 对端无法确认）"; return 1; }
    for _rv_v in /sys/class/net/veth*; do
        [ -e "$_rv_v" ] || continue
        [ "$(cat "$_rv_v/iflink" 2>/dev/null)" = "$_rv_idx" ] || continue
        _rv_n=$(basename "$_rv_v")
        run ip link set "$_rv_n" master lxcbr0 2>/dev/null || continue
        run ip link set "$_rv_n" up 2>/dev/null || true
        run ip link set lxcbr0 up 2>/dev/null || true
        log "[网桥] 容器 veth 掉线，已重接回 lxcbr0（宿主 $_rv_n ↔ 容器 eth0 if${_rv_idx}）"
        # 立刻用 ping 证明修好了；修不好也要说出来，不能假绿
        _rv_i=0
        while [ "$_rv_i" -lt 10 ]; do
            run ping -c 1 -W 1 "$CONTAINER_IP" >/dev/null 2>&1 && { log "[网桥] 重接后 ping $CONTAINER_IP 已通"; return 0; }
            _rv_i=$((_rv_i+1)); sleep 1
        done
        log "[网桥] 重接后仍 ping 不通 $CONTAINER_IP（可能还有防火墙/路由问题，不在此函数职责内）"
        return 1
    done
    log "[网桥] 未找到与容器 eth0 if${_rv_idx} 配对的宿主 veth（容器网络需重启容器恢复）"
    return 1
}

_pkgcache_feed_ensure() {
    _pkgcache_resolve || return 1
    # apk 的源列表是 /etc/apk/repositories，一行一个 URL，没有 "src/gz 名字" 前缀。
    # 清理只删自己那条（以 file:// 开头且含 apk-cache 的整行），别动官方源。
    _pcf_conf="${PKG_CACHE_CONF:-/etc/apk/repositories}"
    _pcf_dir="${_pcf_conf%/*}"
    _pcf_tmp="$_pcf_conf.tmp.$$"
    mkdir -p "$_pcf_dir" 2>/dev/null
    if [ -f "$_pcf_conf" ]; then
        # 只认「目录名以 apk-cache / pkg-cache 结尾」的 file:// 行：
        # 不靠路径里出现字样（PKG_CACHE 一改路径就会漏删、越挂越多），
        # 也不无脑删所有 file://（用户自己挂 /mnt/usb/pkgs 那种源不该被清）。
        grep -vE '^file://.*/(apk|pkg)-cache/?$' "$_pcf_conf" > "$_pcf_tmp" 2>/dev/null
        [ -f "$_pcf_tmp" ] || return 1
    else
        : > "$_pcf_tmp" 2>/dev/null || return 1
    fi
    printf 'file://%s\n' "$_PKG_CACHE_ACT" >> "$_pcf_tmp" 2>/dev/null || return 1
    cat "$_pcf_tmp" > "$_pcf_conf" 2>/dev/null || { rm -f "$_pcf_tmp"; return 1; }
    rm -f "$_pcf_tmp"
    log "[PKG] 已挂载本地 apk 源：file://$_PKG_CACHE_ACT"
    return 0
}

# 让 opkg 认识这个源。优先直接铺索引到 lists 目录 —— opkg update 会去连所有
# 远程源，离线时白等几十秒，而本地索引根本不需要联网。
_pkgcache_lists() {
    # apk 不需要铺索引：它直接读源目录里的 packages.adb，没有 opkg 那种
    # /var/opkg-lists 中间层，也就不存在「被 opkg update 清掉」的问题。
    # 【v.180.198】原来这行后面跟着整套 opkg 铺设逻辑（cp Packages → lists/pkgcache
    # + 铺 .sig），判据写死成 apk 之后那套永远不可达，已整段删除。
    # 函数保留是因为调用点还在，留着恒真返回，调用点不必改。
    return 0
}

# 【v.180.198】本函数原本就是「apk 上恒返回 0」+ 一段不可达的 opkg 自愈逻辑，
# 现在收敛成一句。它防的是 opkg 的 /var/opkg-lists 被 update 清空，
# apk 根本没有这个中间层，也就没有这种坏法。
_pkgcache_lists_ensure() {
    return 0
}

# 【v.180.198】这里原本是 opkg 的两条装回路径说明（ipk 直装 / 本地源 +
# --no-check-signature）以及配套的 _PKG_SIGOPT 变量。25.12 只有 apk，
# 那两条路整段删除，变量也一并去掉 —— opkg 的版本在自己的 24.10 仓库里。

# apk 侧装回。25.12 真机实测（apk-tools 3.0.5）把原来两条路全否了：
#   ① `apk add <绝对路径.apk>`：依赖要「从源里取」，--no-network 一句
#      "masked in: --no-network" 连 file:// 一起屏蔽 → 必失败（rc=17）。
#   ② `--repository file://<目录>`：只按 v2 布局找 <目录>/<arch>/APKINDEX.tar.gz，
#      我们的索引是 <目录>/packages.adb → 报 "No such file"。
# 现在只走一条：repositories 文件里写 `file://<目录>/packages.adb`，用
# --repositories-file 只喂本地这一个源。唯一源是本地 → 不会联网，
# 不需要 --no-network，也就不会被 mask。
# 记账位置与 opkg 不同（apk 写 /etc/apk/world），对外效果一样：
# 包管理器认这个包是装着的，LuCI 软件包页面看得见。
_lxc_missing_deps() {
    _LXC_MISSING=""
    # 【2026-11-09.2245】判据从「只看一次冒烟」扩成「冒烟 + 文件清单」。
    # 旧注释（2026-10-31.0256）称「任一件被删，lxc-start --version 都会留下痕迹」，
    # 2026-11-09 真机实测不成立（192.168.1.201 / lxc 7.0.0）：
    #   五件套是五个独立二进制（inode 2998/2999/2995/480/2982，62816~75104 B），
    #   rm /usr/bin/lxc-attach 后 lxc-start --version 照打 7.0.0、rc=0。
    # 所以冒烟只验得动 lxc-start 自身与 liblxc 断链，判不出 stop/ls/info/attach 被删。
    # 而这些正是 last_pull 依赖的：attach 一缺，_ct_env 直接 127。
    # --lxc-files 读 /rom/lib/apk/packages/lxc*.list 逐条 [ -e ]，34 个包。
    # 2026-11-09 真机实测：50 次 2 s，即 40 ms/次（纯扫描约 6 ms，其余是 sh 进程启动）。
    # 只在引导里跑（开机 / 每 30 分钟体检 / 修复），不进探针每轮。
    # 三态：0 齐全、1 有缺、2 判不了（只读基底没有清单）—— 2 不阻塞引导。
    case "$(lxc-start --version 2>&1)" in
        *"Error loading"*|*"No such file"*|*"not found"*|*"cannot open shared object"*)
            _LXC_MISSING=" lxc(缺件或动态库)" ;;
    esac
    if [ -z "$_LXC_MISSING" ] && [ -x /usr/sbin/pkg-restore.sh ]; then
        _lxd_f="$(/usr/sbin/pkg-restore.sh --lxc-files 2>/dev/null)"; _lxd_rc=$?
        if [ "$_lxd_rc" = "1" ]; then
            _lxd_f=$(printf '%s' "$_lxd_f" | tr '\n' ',')
            _LXC_MISSING=" lxc(文件缺:${_lxd_f%,})"
        elif [ "$_lxd_rc" = "2" ]; then
            # 【2026-11-09】rc=2 = 只读基底里没有 apk 清单（老固件），文件级判据无从下手。
            # 不阻塞引导，但必须留一行痕迹：否则「二进制被删」在这类机器上永远静默。
            log "[PKG] 只读基底缺 apk 清单（/rom/lib/apk/packages），文件级判据不可用；本条只判冒烟"
        fi
    fi
    [ -z "$_LXC_MISSING" ]
}

# 全量记账判据（v.180.164，C 方案）：/rom 里带过的 lxc 全家桶是否全在册。
# 与 _lxc_missing_deps 并行，两条都要满足，各防一种故障：
#   · _lxc_missing_deps  判「能不能跑」——五个核心 applet 在 + liblxc 能加载。
#                        防「记账在、二进制被删」；但它看不见 snapshot / monitor /
#                        usernsexec 这类非核心 applet（缺了照样能起容器）。
#   · _lxc_missing_pkgs  判「在不在册」——含元包 lxc、liblxc、全部 applet。
#                        防「整包被删」，这是 opkg remove --force-depends 的典型结果。
# 枚举与判已装都委托 pkg-restore.sh --lxc-missing：那条与 --lxc 的恢复清单
# 共用同一份枚举（_pr_lxc_names），不在这里再写一遍通配 —— 两处实现迟早漂移，
# 加包时漏一处就是「判得出、装不回」。
# 没有这个接口时保守放过（老固件退回 v.180.163 行为，不因缺接口而硬失败）。
_lxc_missing_pkgs() {
    [ -x /usr/sbin/pkg-restore.sh ] || return 0
    _LXC_MISSING_PKGS=$(/usr/sbin/pkg-restore.sh --lxc-missing 2>/dev/null)
    [ -z "$_LXC_MISSING_PKGS" ]
}

# 必备组件总闸门（v.180.102，v.180.157 收窄为只管 lxc）：lxc 五件套齐全返回 0，
# 否则返回 1，缺失清单留在 _PKG_MISSING。只读不写，verify / build 共用。
# 【v.180.157】smartdns 已整套移出 bootstrap（归 pkg-restore-smartdns.sh + 探针），
# 本闸门恢复成「只守 lxc」—— 它的全部意义就是保证 pkg_base 之后容器起得来。
# 【v.180.164】从「只判命令可用」扩成两条并行：见 _lxc_missing_deps 与 _lxc_missing_pkgs。
_pkg_missing_all() {
    _PKG_MISSING=""
    _LXC_MISSING_PKGS=""
    _lxc_missing_deps || _PKG_MISSING="$_LXC_MISSING"
    _lxc_missing_pkgs || _PKG_MISSING="$_PKG_MISSING $_LXC_MISSING_PKGS"
    [ -z "$_PKG_MISSING" ]
}






# 探测 network.wan / network.wan6 段是否仍存在，存在则回显段名。
# 用 uci show 而不是 uci get network.wan：后者依赖"段存在但无 option 时的返回"，
# 在精简 uci（busybox 版、测试 mock）里两段式路径一律 exit 1，会把"存在"误判成"不存在"。
_BS_FLAG_NOW() { date "+$_FLAG_TS_FMT"; }
verify_sub_cs_acquis() {
    _a="$ROOTFS/etc/crowdsec/acquis.d/router.yaml"
    [ -s "$_a" ] || return 1
    # 一条命令整体校验：5 个顶层键齐全即内容完整（无需逐 needle 对）
    [ "$(grep -cE '^(source|listen_addr|listen_port|protocol|labels):' "$_a" 2>/dev/null)" = 5 ] || return 1
    _d="$ROOTFS/etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml"
    [ -s "$_d" ] || return 1
    grep -q "openwrt/dropbear-logs" "$_d" 2>/dev/null || return 1
    # v.84：一条命令整体校验规则条数（对齐手动配置期 grep -c 'value: ssh_failed-auth' == 3）
    [ "$(grep -c 'value: ssh_failed-auth' "$_d" 2>/dev/null)" = 3 ] || return 1
    [ "$(grep -c 'value: ssh_auth_success' "$_d" 2>/dev/null)" = 2 ] || return 1
    _w="$ROOTFS/etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml"
    [ -s "$_w" ] || return 1
    # 一条命令整体校验：3 个顶层键齐全即内容完整
    [ "$(grep -cE '^(name|description|whitelist):' "$_w" 2>/dev/null)" = 3 ] || return 1
    # 【v.108.25】最后过一遍 sha：上面全是「结构对不对」，这一条是「内容还是不是
    # 我上次写的那份」。解析器少一个字节（注释被删、缩进被编辑器改）结构判据照样过，
    # 但规则可能已经不生效了 —— 那种失效不会报错，只会让日志解析悄悄变空。
    verify_cfg_sha || { log "[日志] 解析器/配置 sha 与基线不符（内容被改动）"; return 1; }
}

# ============================================================================
# v.93-bp：8 组重组后的新节点实现
# 设计原则：静态配置全部在 ct_boot 之前写完（容器启动后改文件不重载不生效）

# ---- PREP / ct_net：容器网络静态文件（IP / 网关 / DNS）+ 双向连通性 ----
# 文件正确只是"配置对"，ping 通才是"真的通"。两个方向都要验：
# 容器内 ping 的一次尝试：写法依次降级。
# 真机现象（24.10，2026-10-22）：脚本判「容器 ping 网桥失败」，人手进容器 ping 却是通的。
# 两种原因都会造成假失败，且都不该判「不符」：
#   · 极简 rootfs 的 busybox ping 未必认 `-W`（老版本只有 `-w`），选项错 → rc≠0；
#   · veth 刚被 netifd 重建过时，第一次 ping 常因邻居表还没建立而丢包。
# 口径：先严后宽，中间隔 1 秒，任一写法通即算通。
verify_acquis() {
    verify_sub_cs_acquis
}
_ensure_lxc_auto() {
    _ea_init="$LXC_AUTO_INIT"
    if [ ! -x "$_ea_init" ]; then
        log "[lxc-auto] 服务脚本缺失（固件未带 files/etc/init.d/lxc-auto），改走直接 lxc-start"
        return 1
    fi
    _ea_dirty=0
    # ① 容器名：服务按 /etc/config/lxc-auto 里的 name 启动，没有段/名字不符都拉不起来
    _ea_name=$(run uci -q get lxc-auto.@container[0].name 2>/dev/null)
    if [ "$_ea_name" != "$LXC_NAME" ]; then
        if run uci -q get lxc-auto.@container[0] >/dev/null 2>&1; then
            run uci -q set "lxc-auto.@container[0].name=$LXC_NAME"
        else
            run uci -q add lxc-auto container
            run uci -q set "lxc-auto.@container[-1].name=$LXC_NAME"
        fi
        _ea_dirty=1
        log "[lxc-auto] /etc/config/lxc-auto 已补写容器 $LXC_NAME（原为「${_ea_name:-空}」）"
    fi
    # ② timeout：镜像固化的就是 300，被改过即异常（影响 lxc-stop 的等待时长，
    #    写太短会在容器还没退干净时就当它停了）。名字对了也要查这一项。
    _ea_to=$(uci -q get lxc-auto.@container[0].timeout 2>/dev/null)
    if [ "$_ea_to" != "300" ]; then
        run uci -q set "lxc-auto.@container[0].timeout=300"
        _ea_dirty=1
        log "[lxc-auto] timeout 已校正为 300（原为「${_ea_to:-空}」）"
    fi
    # ③ 执行面（v.108.12）：files/etc/init.d/lxc-auto 的 start_container() 里有
    #    `config_list_foreach "$cfg" command run_command` —— 段里只要出现
    #    `list command '...'`，开机就会以 root 执行它。镜像固化的容器段没有这一项，
    #    出现即为被注入（别的脚本写坏 / 从别处拷来的配置），必须清掉。
    #    只清 @container[0]：镜像只认这一个段，用户自己加的段不归本脚本管。
    if run uci -q get lxc-auto.@container[0].command >/dev/null 2>&1; then
        run uci -q delete lxc-auto.@container[0].command
        _ea_dirty=1
        log "[lxc-auto] 已删除 @container[0].command：lxc-auto 会把它当命令以 root 执行，而镜像配置里没有这一项"
    fi
    # ④ 多余段：只告警、不删。删掉别人加的容器段属于破坏性操作，
    #    和「只维护第一段」的边界冲突，交给人判断。
    if run uci -q get lxc-auto.@container[1] >/dev/null 2>&1; then
        log "[lxc-auto] 注意：/etc/config/lxc-auto 里还有第 2 个 container 段，本脚本只维护第一段，不当处置"
    fi
    if [ "$_ea_dirty" = 1 ]; then
        run uci -q commit lxc-auto \
            || { log "[lxc-auto] 写 /etc/config/lxc-auto 失败"; return 1; }
    fi
    # ② 服务必须 enabled：disabled 时 S99 不拉起，重启后容器就不在了
    if ! "$_ea_init" enabled 2>/dev/null; then
        "$_ea_init" enable >/dev/null 2>&1 \
            || { log "[lxc-auto] enable 失败"; return 1; }
        log "[lxc-auto] 服务已 enable（开机 S99 自动拉起容器）"
    fi
    return 0
}

# ---- PREP / lxc_auto：/etc/config/lxc-auto 真的写着容器段（v.108.28）----
#
# 为什么需要这个节点：`_ensure_lxc_auto` 原来只被 `build_ct_boot` 调到，而
# build_ct_boot 能不能跑到，取决于 `verify_ct_boot`（= 容器在不在跑）。
# 于是有一种现场完全静默：**容器好好跑着，而 /etc/config/lxc-auto 是空的
# （或被 overlay 清掉、被还原成 lxc-auto 包自带的注释模板）** ——
# verify_ct_boot 说「容器在跑，达标」，build_ct_boot 根本不执行，没人写配置。
# 这个口子一直藏到下次重启才炸：S99 lxc-auto 遍历不到 container 段，
# `start()` 一声不响 return 0，容器不起来，人才发现配置早没了。
# 所以把「配置在不在」从「容器在不在」里剥出来单独判，运行期也验、也补。
#
# 该文件仍**不进 GUARD_FILES**（v.108.8 的决定不变）：guard 的基准是 /rom，
# 而 /rom 里是 lxc-auto 包的注释模板，纳进去等于每轮把写好的配置打回注释态。
# 它归 bootstrap 管，不归 guard 管 —— 这个节点就是那句话的落地。
#
# ★ 但**服务脚本本身**（/etc/init.d/lxc-auto）是另一回事：它在 GUARD_FILES 里，
#   受只读基准 /rom 保护，被改/被删都会被 guard 拷回来（连 overlay 的 whiteout 都处理了）。
#   所以「服务脚本不存在」不是「固件没带」，而是「被删了、guard 还没跑到」——
#   必须判不符，并且自己从 /rom 恢复一次（不把「guard 与本脚本谁先跑」当运气）。
#   guard 恢复的是**文件**，恢复不了 **enable 状态**（/etc/rc.d/S99lxc-auto 不在清单里），
#   所以下面那条 `enabled` 判据是必需的、不是多余的。
verify_lapi_reachable() {
    run wget -qO- --timeout=3 "http://${CONTAINER_IP}:${LAPI_PORT}/health" 2>/dev/null \
        | grep -q '"status"'
}

# 让 8080 真正对路由器开放：探测 → 不通就重启容器内 crowdsec 再探测。
# 「改文件」和「进程认这份文件」是两件事：容器一直在跑时，只有重启才重新读 listen_uri。
# 【v.108.23】文件本身已由 LOGCONF 组的 logconf 节点写入并复核过；这里开头的
# ensure_listen_uri 是幂等兜底（运行期重跑、文件被人动过时还有一次自愈机会）。
_ensure_lapi_exposed() {
    ensure_listen_uri || return 1
    if verify_lapi_reachable; then
        log "[LAPI] 8080 已对路由器开放（${CONTAINER_IP}:${LAPI_PORT}）"
        return 0
    fi
    log "[LAPI] 路由器侧探测不通（容器内 LAPI 可能仍只监听 127.0.0.1），重启容器内 crowdsec"
    _ct_restart_crowdsec \
        || log "[LAPI] 容器内 crowdsec 重启命令均失败"
    _lw=0
    while [ "$_lw" -lt "$MAX_WAIT" ]; do
        if verify_lapi_reachable; then
            log "[LAPI] 重启后 8080 已对路由器开放"
            return 0
        fi
        sleep "$SLEEP" 2>/dev/null || sleep 1
        _lw=$((_lw + SLEEP))
    done
    log "[LAPI] 重启后 ${MAX_WAIT}s 内 8080 仍不可达（查容器内 firewall 与 crowdsec 监听地址）"
    return 1
}

ensure_online_client_off() {
    [ -f "$CROWDSEC_CFG" ] || { log "[配置] config.yaml 缺失"; return 1; }

    sed -i -E \
        -e "s|^([[:space:]]*)online_client:.*|\\1# online_client: # Central API credentials disabled by bootstrap|" \
        -e "s|^([[:space:]]*)credentials_path:.*online_api_credentials.yaml.*|\\1# credentials_path: /etc/crowdsec/online_api_credentials.yaml|" \
        "$CROWDSEC_CFG" 2>/dev/null

    sed -i -E \
        -e "/^[[:space:]]*client:/,/^[[:space:]]*server:/ s|^([[:space:]]*)#[[:space:]]*credentials_path:.*|\1credentials_path: /etc/crowdsec/local_api_credentials.yaml|" \
        "$CROWDSEC_CFG" 2>/dev/null

    if grep -qE "^[[:space:]]*# online_client:" "$CROWDSEC_CFG" 2>/dev/null; then
        log "[配置] online_client 已注释，LAPI 不再强依赖中央 API 认证"
        return 0
    fi
    log "[配置] online_client 注释失败"
    return 1
}

_ensure_bouncer_service() {
    if cs_active_on_host && nft_table_ready; then
        return 0
    fi
    bouncer_svc enable || true
    bouncer_svc restart || true
    sleep 3
    if cs_active_on_host && nft_table_ready; then
        log "[bouncer] 已生效"
    else
        log "[bouncer] 重启后仍未就绪"
    fi
    return 0
}

# 宿主机 bouncer 服务重启（v.94）：填完 api_key 后必须让进程重新读 uci。
# 与 _ensure_bouncer_service 的分工：
_bouncer_service_restart() {
    if ! cs_active_on_host; then
        # 还没起来：交给 _ensure_bouncer_service 的 enable+restart，这里不抢跑
        log "[bouncer] 宿主机 bouncer 未运行，交由服务拉起流程处理"
        return 0
    fi
    bouncer_svc restart \
        || { log "[bouncer] 重启宿主机 bouncer 服务失败（新 api_key 可能未生效）"; return 1; }
    # 给进程重新读 key + 建 nft 表留时间，最多 10 秒
    _br_i=0
    while [ "$_br_i" -lt 10 ]; do
        cs_active_on_host && nft_table_ready && {
            log "[bouncer] 宿主机 bouncer 已重载（新 api_key 生效）"
            return 0
        }
        _br_i=$((_br_i+1))
        sleep 1 2>/dev/null || sleep 1
    done
    log "[bouncer] 宿主机 bouncer 重载后 10 秒内 nft 表仍未就位（不阻断，交由 BOUNCERVERIFY 判定）"
    return 0
}

# 【v.108.58】强制重签 api_key。
# 为什么需要它：verify_bouncer_fill 只看本地 uci 三项（api_url / enabled / api_key 非空），
# 它回答的是「本地配置齐不齐」，不是「这个 key 还被 LAPI 认不认」。于是最典型的一种失效
# 它永远看不见 —— 换固件时 upper 与基底指纹不符、整层丢弃，LAPI 里的 bouncer 记录随之
# 清零，而 /etc/config/crowdsec（含 api_key）在 sysupgrade 保留清单里活了下来。
# 表现就是：每轮引导在 BOUNCERVERIFY 干等 60 秒 → 软失败（SOFT_NODES 不中止）→
# 下一轮重来，日志里没有一处说「key 已经不认了」。
# 复用 _bouncer_register_once：它本身就是「先删同名 → 清理残留坏记录 → add」，
# 等于把旧 key 作废重发，不需要新写一套注册逻辑。
_bp_say() {
    [ "$1" = "${_bp_last_msg:-}" ] && return 0
    _bp_last_msg="$1"
    log "$1"
}

# last_pull 新鲜度判定。返回 0 = 在拉，1 = 失效，2 = 判不了。
# 【2026-11-09 用户定】必须是三态。原来只有 0/1，_lp 为空就 return 1，
# 而 _lp 为空有四种来源：bouncer 真没在拉、lxc-attach 超时(124)、cscli 自己挂、
# 行在但时间戳格式变了。四种全算「停滞」，于是链条变成：
#   一次 10s 容器繁忙 -> 探针判停滞 -> 拉起完整引导 -> build 等 60s 仍判不了
#   -> _force_resign_bouncer 重签 api_key（bouncer 要重新握手）
# 为一个超时赔上整套重签。判不了就只能说「判不了」，不能冒充「坏了」。
bouncer_pulling() {
    _bp_raw="$(_ct_env "$CSCLI bouncers list" 2>/dev/null)"
    _bp_rc=$?
    if [ "$_bp_rc" != "0" ]; then
        _bp_say "[bouncer] last_pull 判不了（cscli 返回 $_bp_rc：124=超时；不是判定为停滞）"
        return 2
    fi
    _lp="$(printf '%s\n' "$_bp_raw" \
        | grep -E "^[[:space:]]*${BOUNCER_NAME}[[:space:]]" \
        | grep -oE "${_TS_RE}Z?" | head -n 1)"
    # 命令成功、列表里根本没有这个 bouncer：是真的没了，不是判不了
    printf '%s\n' "$_bp_raw" | grep -qE "^[[:space:]]*${BOUNCER_NAME}[[:space:]]" || return 1
    if [ -z "$_lp" ]; then
        _bp_say "[bouncer] last_pull 判不了（bouncer 行在、但取不到时间戳）"
        return 2
    fi

    # 阈值：非数字 → 是配置笔误，警告后回落默认（不能静默关闭检查）；
    # 0 → 主动关闭，此时返回 0 是「不查」，日志必须写明，不能跟「查过了，新鲜」混同。
    # （空串在这里到不了：上一行的 ${VAR:-$_BP_DEFAULT_MAX_AGE} 已经把它换成常量值了。）
    _max_age="${BOUNCER_PULL_MAX_AGE:-$_BP_DEFAULT_MAX_AGE}"
    case "$_max_age" in
        *[!0-9]*)
            _bp_say "[bouncer] BOUNCER_PULL_MAX_AGE='$_max_age' 不是数字，回落默认 ${_BP_DEFAULT_MAX_AGE}s"
            _max_age=$_BP_DEFAULT_MAX_AGE
            ;;
    esac
    if [ "$_max_age" -le 0 ]; then
        _bp_say "[bouncer] BOUNCER_PULL_MAX_AGE=$_max_age：last_pull 新鲜度检查已按配置关闭（这是放行，不是判定为新鲜）"
        return 0
    fi

    _now="$(_ct_env "date +%s" 2>/dev/null)"
    # 【v.108.44】_lp 是 crowdsec 打的 ISO8601（形如 2026-10-21T23:59:53Z），
    # 原写法直接 `date -d "$_lp"` —— busybox 的 -d 只吃 `YYYY-MM-DD hh:mm:ss` 这类，
    # 带 T 和 Z 就解析失败，_at 恒为空，于是**每一次**都走下面那条「判不了 → 放行」。
    # 也就是说 last_pull 新鲜度检查从上线起就没真正执行过：日志写「判不了」，
    # 看着像容器里 date 坏了，实际是格式没规整。这种「检查静默失效」比判错更危险 ——
    # bouncer 真停拉了，这里照样说「放行」。
    # 现在把 T 换成空格、去掉尾部 Z；容器无 tzdata、本地即 UTC，epoch 与 date +%s
    # 同一基准，所以两种写法结果等同（-u 不被支持时退回无 -u 仍成立）。
    _lp_norm=$(printf '%s' "$_lp" | sed -e 's/T/ /' -e 's/Z$//')
    _at="$(_ct_env "date -u -d '$_lp_norm' +%s" 2>/dev/null)"
    [ -n "$_at" ] || _at="$(_ct_env "date -d '$_lp_norm' +%s" 2>/dev/null)"
    # 两种失败要分开报：「回显为空」和「格式不认」是两件事，混在一句话里
    # 会把排查方向带偏（真机日志就是这么误导的：now=[…] at=[] 被写成「date 不可用」）。
    if [ -z "$_now" ]; then
        _bp_say "[bouncer] last_pull 判不了（容器内 date +%s 回显为空），本次放行 —— 这不是「新鲜」"
        return 0
    fi
    if [ -z "$_at" ]; then
        _bp_say "[bouncer] last_pull 判不了（容器内 date 解析不了这个时间串：lp=[$_lp] 规整后=[$_lp_norm]），本次放行 —— 这不是「新鲜」"
        return 0
    fi
    if [ $(( _now - _at )) -gt "$_max_age" ]; then
        _bp_say "[bouncer] last_pull 停滞（$_lp，超过 ${_max_age}s），判定失效"
        return 1
    fi
    return 0
}

# 返回 0 = 在，1 = 确实不在，2 = 判不了（cscli 没跑成）。
# 必须分三态：调用方要区分「bouncer 没了」和「容器不理我」——
# 前者该重签 api_key，后者重签毫无意义（僵死容器连 cscli 都调不动）。
verify_cfg_sha() {
    [ -s "$CFG_SHA_FILE" ] || return 0
    [ "$(sed -n '1s/^ver=//p' "$CFG_SHA_FILE" 2>/dev/null)" = "$SCRIPT_VER" ] || return 0
    _cs_now=$(_cfg_sha_now) || return 1
    [ "$_cs_now" = "$(sed -n '2,$p' "$CFG_SHA_FILE" 2>/dev/null)" ]
}

_stamp_present() {
    [ -s "$STAMP_FILE" ]
}

# 从 stamp 里取一个 `k=v` 字段。取不到就给空串（调用方要能区分「没这个字段」）。
_wait_capi_net() {
    _wn_max="${1:-30}"
    _wn_dl=$(( $(date +%s) + _wn_max ))
    while [ "$(date +%s)" -lt "$_wn_dl" ]; do
        ct_running || { log "[enroll] 容器已停止，放弃等待 DNS 就绪"; return 1; }
        # getent 在极简版里没有（busybox 1.35 静态版不带该 applet），nslookup 一定有 ——
        # 只写 getent 会让 enroll 永远卡在「30 秒内解析不到」，而容器 DNS 其实是好的。
        _ct_env "timeout 2 getent hosts api.crowdsec.net" >/dev/null 2>&1 && return 0
        _ct_env "timeout 2 nslookup api.crowdsec.net" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# ---- 注册码保管（v.108.52：由「注册成功即删」改为「移入保险柜」）----
# 历史包袱：v.99-bp.1 起注册成功就 rm 掉 key，理由是固件公开下载、明文不该留在设备上。
# 但 key 同时也是设备唯一的自愈凭据 —— 删掉之后网页端一旦把实例关掉/删掉，
# re_enroll 读不到 key 只能放弃，用户只能重刷固件或手动 enroll。
# 现在改为两处存放：
#   主文件 $ENROLL_KEY_FILE       固件里带的（一次性的，注册成功后不再需要）
#   保险柜 $ENROLL_KEY_KEEP(.keep) 600，注册成功后搬到这里，sysupgrade 默认保留
# 读取顺序：主文件 → 保险柜。
_enroll_submit_mark() {
    [ "${_VERIFY_ONLY:-0}" = "1" ] && return 0     # 体检承诺「一个字节都不写」
    printf '%s\n' "$(date +%s)" > "$ENROLL_SUBMIT_FILE" 2>/dev/null \
        && chmod 600 "$ENROLL_SUBMIT_FILE" 2>/dev/null
    return 0
}
re_enroll() {
    log "[enroll] console 未注册，用注册码 enroll（注册码固定有效，可反复使用，不消耗）"

    # v.108.52：主文件缺失时回落到保险柜 —— 网页端把实例关掉后，靠这里自愈。
    _enroll_key_load
    _enroll_key="$_ENROLL_KEY_V"
    if [ -z "$_enroll_key" ]; then
        log "[enroll] 无注册码（$ENROLL_KEY_FILE / $ENROLL_KEY_KEEP 都缺失或为空），放弃 enroll"
        log "[enroll] 补救：网页端 app.crowdsec.net 取注册码后执行 cscli console enroll <key>"
        return 1
    fi

    verify_snat || { log "[enroll] SNAT 缺失/不符，重建"; rebuild snat; }

    if ! _wait_capi_net 30; then
        log "[enroll] 30 秒内仍无法解析 api.crowdsec.net（容器 DNS 未就绪），放弃本次 enroll"
        return 1
    fi

    _cred_file="$ROOTFS/etc/crowdsec/online_api_credentials.yaml"

    # 【v.108.51】凭据还在但 CAPI 明确不认（token 被吊销、实例在 console 里被删）：
    # 不重建就永远 enroll 不了 —— 老逻辑只看「文件非空」，会把坏凭据当好凭据一路用下去。
    if [ -s "$_cred_file" ] && _capi_cred_rejected; then
        log "[enroll] CAPI 拒绝现有凭据（失效/被吊销），删除后重建"
        rm -f "$_cred_file" 2>/dev/null
    fi

    if [ ! -s "$_cred_file" ]; then
        log "[enroll] online_api_credentials.yaml 缺失，先 cscli capi register 注册 CAPI 凭据"
        if ! _capi_reg_out="$(_ct_env "timeout 8 $CSCLI capi register" 2>&1)"; then
            log "[enroll] capi register 失败：$(printf '%s' "$_capi_reg_out" | tr '\n' ' ' | cut -c1-300)"
            return 1
        fi
        log "[enroll] capi register 成功，凭据已写入 online_api_credentials.yaml"
    fi

    # 【v.108.65】这是整个引导里唯一用 5s 的地方，也是唯一「等下去没有意义」的地方：
    # 提交后要等云端应答，而网页端不点 Accept 就会一直停在注册状态（现场遇到过）。
    # 挂住的代价是引导锁不放 + 探针 tick 全被挡。
    # 5s 的依据：① 走到这里说明 _wait_capi_net 已确认 api.crowdsec.net 可解析；
    # ② 注册是 POST，云端 5s 不答再等也不会有结果，只会继续占着锁。
    # 其余几条（console status / capi status / capi register）保持 8s（v.108.70 从 10s 下调，必须短于外层 ct 的 10s）：
    # 它们要的是应答内容，多等几秒才有结果，卡住也不等于「网页没点」。
    # 超时（rc=124）走下面的失败分支：记「注册码未消耗，下次开机重试」，不会重复提交。
    if ! _enroll_out="$(_ct_env "timeout 5 /usr/bin/cscli console enroll \"$_enroll_key\"" 2>&1)"; then
        log "[enroll] enroll 执行失败：$(printf '%s' "$_enroll_out" | tr '\n' ' ' | cut -c1-300)"
        log "[enroll] 注册码未消耗，下次开机重试"
        return 1
    fi
    log "[enroll] enroll 命令返回成功：$(printf '%s' "$_enroll_out" | tr '\n' ' ' | cut -c1-200)"

    # 【v.108.53】提交成功立刻落盘时间戳（备查用；判定靠 _ENROLL_TRIED）。
    _enroll_submit_mark
    log "[enroll] 已记录提交时间（$ENROLL_SUBMIT_FILE）；本次开机不再重复提交（重启可再试一次）"

    # 【v.108.69】原来这里还有一条 `cscli console enable --all`，已删除 —— 不是
    # 「没用」，是反向作用：它把 /etc/crowdsec/console.yaml 的四个共享开关全翻成
    # true（含 share_manual_decisions，即把本机手动封的 IP 上报 CrowdSec 云端），
    # 而 console.yaml 不在 guard 白名单里，60 秒内就被 /rom 只读基底盖回 false。
    # 真机日志（2026-10-24 06:52:18）抓到过这次复原，差异正是
    #   share_manual_decisions: false→true、share_context: false→true。
    # 它从 v.108.49 起一次都没生效过，只多一次写盘 + 一次复原 + 一行日志。
    # 删掉比给它开白名单更对：白名单等于把「手动封禁上报」永久化。
    # 代价：console 网页的「共享统计」保持出厂默认（关）。要开就手动 cscli，
    # 并同时把 console.yaml 加进 guard 白名单，否则 60 秒后仍会被盖回。
    # 【v.108.64】capi status 仍要超时：它问云端，而此刻仍持着引导锁；
    # 失败无害（空就跳过打印），但「挂住」有害（引导锁不放 + 探针 tick 全被挡）。
    _ct_restart_crowdsec || true

    _capi_out="$(_ct_env "timeout 8 $CSCLI capi status" 2>&1)"
    [ -n "$_capi_out" ] && log "[enroll] capi status：$(printf '%s' "$_capi_out" | tr '\n' ' ' | cut -c1-200)"

    _i=0
    while [ "$_i" -lt 2 ]; do
        _i=$((_i+1))
        if console_enroll_ok; then
            log "[enroll] 已注册（Enrolled）；网页端 Accept 后 CAPI 才 authenticated，无需脚本干预"
            _enroll_submit_clear
            _park_enroll_key
            return 0
        fi
        sleep 5
    done

    log "[enroll] enroll 已成功，两轮探测（间隔 5s）后本地仍未显示 Enrolled"
    log "[enroll] 需要前往网站确认接受：请访问 https://app.crowdsec.net 接受该实例（Accept）"
    log "[enroll] 未及时 Accept 前 CAPI 侧可能有报错，属正常过程；Accept 后自动恢复"
    _park_enroll_key
    return 0
}

_mount_systemd_cgroup() {
    _cg=/sys/fs/cgroup/systemd
    # 极简版容器里没有 systemd 会去 mount cgroup，这一层对它不构成前提：
    # 直接在函数入口拦住，所有调用点（开机链、补挂、重装）一次性都覆盖到。
    _is_minimal_init && { log "[cgroup] 极简 init 容器：无需 systemd 命名层级，跳过"; return 0; }
    # 判据必须是「/proc/mounts 里真有这个挂载点」，不能是「目录可写」。
    # /sys/fs/cgroup 本身是 tmpfs，`mkdir -p /sys/fs/cgroup/systemd` 出来的空目录
    # 天然可写，旧写法据此直接 return 0 —— 容器内 systemd 随后自己去 mount 就撞：
    #   Failed to mount cgroup at /sys/fs/cgroup/systemd: Operation not permitted
    #   [!!!!!!] Failed to mount API filesystems.
    # 表现就是容器怎么都起不来，而宿主日志里一片「cgroup 可写，无需挂载」。
    if _cg_host_ok; then
        log "[cgroup] systemd 命名层级已挂载，无需处理"
        return 0
    fi
    # 挂载点被占着但形态不对（别的东西挂上去了 / 挂成了 tmpfs）：
    # 直接 mount 会 EBUSY，必须先卸。卸不掉就如实判失败，别硬报成功。
    if grep -qE "[[:space:]]${_cg}[[:space:]]" /proc/mounts 2>/dev/null; then
        log "[cgroup] ${_cg} 上有挂载但不是 cgroup/name=systemd 层级，先卸载再重挂"
        if ! run umount "$_cg" 2>/dev/null; then
            log "[cgroup] 卸载失败（多半被运行中的容器引用），无法纠正挂载形态"
            return 1
        fi
    fi
    mkdir -p "$_cg" 2>/dev/null
    if run mount -t cgroup -o rw,nosuid,nodev,noexec,relatime,none,name=systemd cgroup "$_cg" 2>/dev/null; then
        # mount 返回 0 不代表挂对了，回读确认形态（不只是「路径存在」）
        if _cg_host_ok; then
            log "[cgroup] 已挂载 systemd 命名层级（容器内 systemd 需要）"
            return 0
        fi
        log "[cgroup] mount 返回 0 但形态不符（不是 cgroup/name=systemd），按失败处理"
        return 1
    fi
    if grep -qE "cgroup2[[:space:]]" /proc/mounts 2>/dev/null; then
        # unified 宿主上 v1 命名层级本就不该存在，挂不上不是「我们没修好」，
        # 容器内 systemd 由 LXC 的 lxc.mount.auto 提供 cgroup 视图。
        # 这种情况不能返回 1 —— 否则 build 失败会按 ensure 的语义直接 hard 终止，
        # 整个 PREP 组后面的节点一个都跑不到。
        log "[cgroup] 宿主是 cgroup v2 unified，跳过 v1 systemd 层级（容器侧由 lxc.mount.auto 负责）"
        return 0
    fi
    log "[cgroup] systemd 命名层级挂载失败（内核缺 CONFIG_CGROUP_* 或该层级已被其它控制器占用）"
    return 1
}

verify_online_client_off() {
    [ -f "$CROWDSEC_CFG" ] || return 1
    ! grep -qE "^[[:space:]]*online_client:" "$CROWDSEC_CFG" 2>/dev/null
}
