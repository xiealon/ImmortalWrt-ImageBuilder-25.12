#!/bin/sh
# bootstrap/boot/step.sh —— BOOT 组（boot）
#
# 两步结构：
#   第一步 --check   只检测，一个字节都不写。逐节点跑 verify_<node>，
#                    全部达标返回 0；有不过的把它们打在 stderr 并返回 1。
#   第二步 --fix     只修「检测不过」的那些（内部走 ensure，先查后改），
#                    修完复检一次；仍不过返回 1。
#
# 本组节点（按 DAG 顺序）：ct_boot
#
# 用法：
#   ./step.sh --check          检测本组
#   ./step.sh --fix            修本组（只动不过的节点）
#   ./step.sh --node <名字>    只处理单个节点（--check-node / --fix-node 同理）

_here=$(cd "$(dirname "$0")" && pwd)
# 【2026-11-10 修】不能无条件用 "$_here/.." 找依赖。
# 直接执行时 $0 是 .../bootstrap/<组>/step.sh → _here 是组目录 → ".." 才对。
# 但被 main.sh 或驱动脚本 source 时，$0 指向调用者 → _here 已经等于 bootstrap 根，
# 再拼 ".." 就指到 /usr/sbin 去了，_lib.sh 找不到 → 非交互 shell 直接退出。
# 这就是 --full 模式一直跑不通的根因。用目录名判定，两种情形都覆盖。
case "${_here##*/}" in
net|install|prep|capiblock|boot|logconf|lapi|bouncer|enroll) _BS_HOME=$(cd "$_here/.." && pwd) ;;
*) _BS_HOME="$_here" ;;
esac
. "$_BS_HOME/_lib.sh"
. "$_BS_HOME/_dag.sh"
# ensure 在硬失败时会调 full_reinstall —— 它在 selfheal/step.sh 里。
# 不 source 的话，重装判定走了、动作却是 "full_reinstall: not found"，
# 现场什么都没抹、日志只说一句 hard 终止，等于重装机制整条消失。
. "$_BS_HOME/selfheal/step.sh"

MY_GROUP="BOOT"
MY_NODES="ct_boot"

verify_ct_cgroup() {
    ct_running || return 1
    # 极简版：系统里没有任何 cgroup 消费者，PID1 是 busybox init。
    # 这一节改成「PID1 是活的 init」，而不是「能读 cgroup.procs」——后者在
    # 没有 cgroup v1 层级的宿主上本来就不成立（CGROUP_DEVICE 未开）。
    if _is_minimal_init; then
        _ct_init=$(_ct_env 'cat /proc/1/comm 2>/dev/null' 2>/dev/null | tr -d '\r' | head -n1)
        case "$_ct_init" in
            init|busybox|sh) return 0 ;;
        esac
        log "[init] 容器内 PID 1 不是 busybox init（实际「${_ct_init:-空}」）"
        return 1
    fi
    # ① 容器内能读到 cgroup 的组织文件：能读 = 这层确实挂进容器且是活的
    if ! _ct_env 'test -r /sys/fs/cgroup/systemd/cgroup.procs || test -r /sys/fs/cgroup/cgroup.procs' \
            >/dev/null 2>&1; then
        log "[cgroup] 容器内读不到 cgroup.procs（cgroup 视图没进容器）"
        return 1
    fi
    # ② PID 1 必须是 systemd：挂载形态不对时 systemd 会在挂载阶段报
    #    Failed to mount API filesystems 然后 Exiting PID 1，容器随即退出。
    #    容器还在跑但 PID 1 不是 systemd，说明根本没按 lxc.init.cmd 引导。
    _ct_init=$(_ct_env 'cat /proc/1/comm 2>/dev/null' 2>/dev/null | tr -d '\r' | head -n1)
    if [ "$_ct_init" != "systemd" ]; then
        log "[cgroup] 容器内 PID 1 不是 systemd（实际「${_ct_init:-空}」）"
        return 1
    fi
    return 0
}

# ---- PREP / ct_bootlink：容器内自启软链 + 机器身份 ----
verify_ct_boot() { ct_running; }

# 容器启动构造步（安装态与重启态共用）：v.81 起并入原 _fix_container_boot 的
# 「验启动链在位才开机」内容级检查——启动链缺失（config 不在/不完整、rootfs 不在）
# 校验 lxc-auto 服务侧配置：容器名必须在 /etc/config/lxc-auto 里、服务必须 enabled。
#
# ★ 必须能"写"，不能只校验（v.108.8）：lxc-auto 包自带的 /etc/config/lxc-auto
#   整份都是注释（#config container / #option name container1 / ...），uci 读出来
#   一行有效配置都没有 → config_foreach 遍历不到 container 段 →
#   /etc/init.d/lxc-auto start() 直接 return 0，一声不响什么都不做，容器开机不常驻。
#   v.108.7 曾假定"名字由镜像固定、运行期与 /rom 一致"，这个前提不成立：
#   workflow 把 custom/ 以 bind mount 挂到 files/etc/config 上（-v custom:...），
#   Docker 的整体遮蔽让仓库里那份 files/etc/config/lxc-auto 根本进不了镜像。
#   现已改由 /etc/uci-defaults/98-lxc-auto.sh 首启写入，这里再兜一层 ——
#   overlay 被清、config 被删、名字被改，都能自愈。
#
# ★ 该文件**不进 GUARD_FILES**：它是运行期 uci 配置。guard 的基准是 /rom，
#   而 /rom 里是包的注释模板，纳进去只会把写好的配置每轮打回注释态。
_purge_legacy_lxcboot() {
    _lb_init=/etc/init.d/lxcboot
    _lb_bak=/root/lxcboot.bak
    _lb_hit=0
    if [ -e "$_lb_init" ]; then
        # 先 disable：正常 init 脚本会自己摘掉 rc.d 链接；不标准的那种摘不掉，下面兜
        "$_lb_init" disable >/dev/null 2>&1 || true
        if cp -f "$_lb_init" "$_lb_bak" 2>/dev/null; then
            :
        else
            log "[遗留] 备份 $_lb_init 失败（原文件仍会被删，如需回滚只能从 /rom 或固件包取）"
        fi
        rm -f "$_lb_init" 2>/dev/null
        _lb_hit=1
    fi
    # rc.d 里的残留链接单独扫一遍：lxcboot 不是标准 uci init，disable 未必摘得干净
    for _lb_l in /etc/rc.d/*lxcboot*; do
        [ -e "$_lb_l" ] || continue
        rm -f "$_lb_l" 2>/dev/null
        _lb_hit=1
    done
    # 删完回读：真删掉了才说成功，别报假绿
    if [ -e "$_lb_init" ]; then
        log "[遗留] 删除 $_lb_init 失败，旧兜底仍在；lxc-auto 已就位，两者会抢同一个容器"
        return 0
    fi
    if [ "$_lb_hit" = 1 ]; then
        log "[遗留] 已清掉 lxcboot 兜底（备份 $_lb_bak）：lxc-auto 链路已就位，双启动器会互相踩"
    fi
    return 0
}

build_ct_boot() {
    # ★ 勿删、勿"优化"：两个 lxc-auto 不是一回事，别再判成"装了又关的自相矛盾"。
    #   · 仓库自带的 files/etc/init.d/lxc-auto：读 /etc/config/lxc-auto 的
    #     `config container` + `option name`，直接 `lxc-start -n <name> -d`，
    #     **不读容器 config 的 lxc.start.auto**；boot() 里还顺带挂 systemd cgroup。
    #     容器常驻走的就是这条 → 必须 enable 并由本脚本拉起它（v.108 回退 v.56 起的禁用）。
    #   · `lxc.start.auto=1`：让容器自己随 lxc-autostart 起，已弃用，与上面那个服务无关。
    # 曾经的做法是「disable lxc-auto + 脚本自己 lxc-start」，副作用是把带 cgroup 挂载的
    # 那个 boot() 一起废掉，且开机自启只剩 rc.local 一条路，失败就再没有别的手接管。
    if ! verify_ct_config; then
        log "[开机] 启动链缺失（容器 config 不在或不完整），不开机"
        return 1
    fi
    if ! verify_rootfs; then
        log "[开机] 启动链缺失（rootfs 不在或不完整），不开机"
        return 1
    fi
    # 【v.108.22】listen_uri 不在这里改。
    # 开机只需要网桥 + systemd cgroup 两个条件（这是容器能不能起来的物理前提）；
    # listen_uri 是 LAPI 对外可达性的事，放进来就把「bouncer 连不上」变成了
    # 「容器不开机」——故障范围被放大，而且用户看到的是一台直接不起机的路由器。
    # 改由 LAPI 组的 _ensure_lapi_exposed 负责（改文件 → 探活 → 不通就重启容器内
    # crowdsec 再探），改坏了最多是 LAPI 这一组失败。
    _mount_systemd_cgroup
    if _ensure_lxc_auto; then
        _purge_legacy_lxcboot
        log "启动容器 $LXC_NAME（经 lxc-auto 服务）"
        run_svc /etc/init.d/lxc-auto start >/dev/null 2>&1 || log "[lxc-auto] start 返回非 0，继续兜底"
    fi
    # 兜底：服务缺失 / 被 disable / start 异常时直接起，不让开机链断在这一步
    ct_running || run lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d >/dev/null 2>&1 || true
    if ! _wait_ct_running; then
        log "首启未拉起，重试 lxc-start -d"
        run lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d >/dev/null 2>&1 || true
        if ! _wait_ct_running; then
            _ct_revive || { log "容器启动修复链无效，引导失败"; return 1; }
        fi
    fi
    # 容器 RUNNING 不等于 cgroup 视图可用：补挂宿主层级 + 重启容器一次，仍不可用就 hard。
    # 放在 ct_boot 而不是 PREP 组，因为容器没起来时容器内无从查起。
    if ! verify_ct_cgroup; then
        log "[cgroup] 容器内 cgroup 视图不可用，补挂宿主层级并重启容器一次"
        _mount_systemd_cgroup || true
        ct_force_stop || true
        run lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d >/dev/null 2>&1 || true
        if ! _wait_ct_running || ! verify_ct_cgroup; then
            log "[cgroup] 容器内 cgroup 视图仍不可用，引导失败"
            return 1
        fi
        log "[cgroup] 补挂并重启后，容器内 cgroup 视图已可用"
    fi
    # 【v.108.66】从这一刻起 CT_BOOT_GRACE 秒内，容器内命令用 60s 超时：
    # PID1 刚就绪，首次 attach（cgroup 视图、网络检查）都可能要等它。
    # 窗口过后自动收紧到 10s —— 探针重跑时容器早已运行，走的就是 10s。
    _CT_BOOT_UNTIL=$(( $(date +%s) + CT_BOOT_GRACE ))
    log "容器已启动"
}

# lxcbr0 网桥 builder（自 setup_bridge 拆出：commit/reload 交由 flush_uci 分组处理）
# 【v.97 修正】这里原本是「只验不写」——只在内核里补一个裸 bridge，不设地址、不写 uci。
# 而 verify_bridge 要求「lxcbr0 存在 + network.lxc.proto=static + 桥上 IP == BRIDGE_IP」三件齐。
# 也就是说首次启动时 build 跑完 verify 依然不过，只是 ensure 不做事后复核所以没报错；
# 后果是容器网络整条链（ct_net / ping 双向）静默失败。v.95 已经把网络侧全部改成
# 「验证 + 修改」，唯独漏了这一个，现在补齐：
#   · uci 侧：network.lxc 段（proto/ipaddr/netmask/device），交给 flush_uci 的 network reload
#   · 内核侧：设备不存在就建，存在则校正地址（先删旧地址再按 uci 加，幂等）
_ct_revive() {
    log "[施救] 容器启动修复链（补挂 cgroup → 重写 config 重启 → 验活；不重建）"

    _mount_systemd_cgroup

    log "[施救] 强停残留 → 重写容器 config → 重启"
    ct_force_stop || true
    write_cfg || true
    run lxc-start -P "$LXC_PATH" -n "$LXC_NAME" -d >/dev/null 2>&1 || true
    if _wait_ct_running; then
        log "[施救] 重写 config 后容器已拉起"
        return 0
    fi
    log "[施救] 重写 config 仍无效（不再重建重装，交由上层 hard 终止）"
    return 1
}



# ============ 第一步：检测（只读） ============
_check_group() {
    _cg_bad=""
    for _cg_n in $MY_NODES; do
        if "verify_$_cg_n" >/dev/null 2>&1; then
            continue
        fi
        _cg_bad="$_cg_bad $_cg_n"
    done
    [ -z "$_cg_bad" ] && return 0
    for _cg_n in $_cg_bad; do
        printf '%s\n' "$_cg_n" >&2
    done
    return 1
}

# ============ 第二步：修复（只动不过的） ============
_fix_group() {
    _fg_n=0
    for _fg_x in $MY_NODES; do
        "verify_$_fg_x" >/dev/null 2>&1 && continue
        _fg_n=$((_fg_n + 1))
        log "[%s] 修复 %s" "$MY_GROUP" "$_fg_x"
        ensure "$_fg_x" || log "[%s] 修复 %s 未成功（留待复检）" "$MY_GROUP" "$_fg_x"
    done
    [ "$_fg_n" -gt 0 ] || log "[%s] 无需修复（本组节点全部达标）" "$MY_GROUP"
    _check_group
}

# 被 source 时不执行入口（main.sh / bootstrap.sh 需要本文件的函数）
if [ "${0##*/}" = "step.sh" ]; then
case "${1:---check}" in
--check)      _check_group && exit 0 || exit 1 ;;
--fix)        _fix_group   && exit 0 || exit 1 ;;
--node)
    _nd="${2:-}"
    [ -n "$_nd" ] || { echo "用法：$0 --node <名字>" >&2; exit 2; }
    case " $MY_NODES " in *" $_nd "*) ;; *) echo "不在本组：$_nd" >&2; exit 2 ;; esac
    "verify_$_nd" >/dev/null 2>&1 && exit 0
    ensure "$_nd" && exit 0 || exit 1
    ;;
--check-node)
    _nd="${2:-}"
    "verify_$_nd" >/dev/null 2>&1 && exit 0 || exit 1
    ;;
--fix-node)
    _nd="${2:-}"
    ensure "$_nd" && exit 0 || exit 1
    ;;
*)
    echo "用法：$0 [--check|--fix|--node <名>|--check-node <名>|--fix-node <名>]" >&2
    exit 2
    ;;
esac
fi
