#!/bin/sh
# bootstrap/prep/step.sh —— PREP 组（prep）
#
# 两步结构：
#   第一步 --check   只检测，一个字节都不写。逐节点跑 verify_<node>，
#                    全部达标返回 0；有不过的把它们打在 stderr 并返回 1。
#   第二步 --fix     只修「检测不过」的那些（内部走 ensure，先查后改），
#                    修完复检一次；仍不过返回 1。
#
# 本组节点（按 DAG 顺序）：ct_net cgroup_mount ct_bootlink ct_resolv
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

MY_GROUP="PREP"
MY_NODES="ct_net cgroup_mount ct_bootlink ct_resolv"

verify_sub_ct_net() {
    if _is_minimal_init; then
        # 极简版：静态网络写在一份 shell 变量文件里，由 /etc/init.d/netconf 在 rcS 里套用。
        # 判据同 systemd 版一样是「三问齐全」，只是取值方式不同：
        #   systemd → Address=/Gateway=/DNS= ；极简版 → ADDRESS=/GATEWAY=/DNS=
        _vs_net="$ROOTFS/etc/crowdsec-net.conf"
        [ -f "$_vs_net" ] || return 1
        grep -qx "ADDRESS=${CONTAINER_IP}/24" "$_vs_net" 2>/dev/null || return 1
        grep -qx "GATEWAY=${BRIDGE_IP}" "$_vs_net" 2>/dev/null || return 1
        grep -qx "DNS=${BRIDGE_IP}" "$_vs_net" 2>/dev/null || return 1
        return 0
    fi
    [ -f "$ROOTFS/etc/systemd/network/10-eth0.network" ] || return 1
    grep -q "Address=${CONTAINER_IP}/24" "$ROOTFS/etc/systemd/network/10-eth0.network" 2>/dev/null || return 1
    grep -q "Gateway=${BRIDGE_IP}" "$ROOTFS/etc/systemd/network/10-eth0.network" 2>/dev/null || return 1
    grep -q "DNS=${BRIDGE_IP}" "$ROOTFS/etc/systemd/network/10-eth0.network" 2>/dev/null || return 1
}
verify_sub_ct_bootlink() {
    if _is_minimal_init; then
        # 极简版没有 systemd，自启语义换成 inittab + init.d：
        #   · /etc/inittab 在 —— 有 init 的启动表，PID1 起来才走得下去；
        #   · /etc/init.d/crowdsec 非空 —— 容器的全部意义，缺了必须当场判不符（同 systemd 版口径）；
        #   · /etc/init.d/rcS 可执行 —— sysinit 入口，缺了网络/syslog 都不起。
        [ -s "$ROOTFS/etc/inittab" ] || return 1
        [ -s "$ROOTFS/etc/init.d/crowdsec" ] || return 1
        [ -x "$ROOTFS/etc/init.d/rcS" ] || return 1
        [ "$(cat "$ROOTFS/etc/hostname" 2>/dev/null)" = "crowdsec" ] || return 1
        _vb_mid=$(tr -d ' \t\r\n' < "$ROOTFS/etc/machine-id" 2>/dev/null)
        printf '%s' "$_vb_mid" | grep -qE '^[0-9a-f]{32}$' || return 1
        return 0
    fi
    _wants="$ROOTFS/etc/systemd/system/multi-user.target.wants"
    for _svc in systemd-networkd crowdsec; do
        if [ ! -f "$ROOTFS/lib/systemd/system/$_svc.service" ]; then
            # 原来这里无条件 continue：服务文件不在就跳过整套检查，函数照样返回 0。
            # 后果是「容器里没有 crowdsec」被判成「自启已就绪」—— 容器起来了、
            # verify 说没问题，直到阶段 3 的 LAPI 探测才炸，中间几十分钟全是假绿。
            # crowdsec 是这台容器的全部意义，缺了必须当场判不符；
            # systemd-networkd 可以被别的网络管理器替代，缺了不拦（配置由 ct_net 管）。
            if [ "$_svc" = "crowdsec" ]; then
                log "[自启] 容器内缺 crowdsec.service，判定不符"
                return 1
            fi
            continue
        fi
        [ -L "$_wants/$_svc.service" ] || return 1
    done
    [ "$(cat "$ROOTFS/etc/hostname" 2>/dev/null)" = "crowdsec" ] || return 1
    _vb_mid=$(tr -d ' \t\r\n' < "$ROOTFS/etc/machine-id" 2>/dev/null)
    printf '%s' "$_vb_mid" | grep -qE '^[0-9a-f]{32}$' || return 1
}
# 容器 resolv.conf 的期望值恒为网桥 IP：极简版是构建期静态文件（nameserver 写死），
# systemd 版由 setup_resolv 按同一个值写。两种 init 期望一致，一条判断就够。
verify_sub_ct_resolv() {
    [ "$(cat "$ROOTFS/etc/resolv.conf" 2>/dev/null)" = "nameserver ${BRIDGE_IP}" ]
}
_ct_ping_ok() {
    _cpk_h="$1"
    _ct_env "ping -c 1 -W 2 $_cpk_h" >/dev/null 2>&1 && return 0
    _ct_env "ping -c 1 -w 3 $_cpk_h" >/dev/null 2>&1 && return 0
    sleep 1
    _ct_env "ping -c 1 $_cpk_h" >/dev/null 2>&1 && return 0
    return 1
}
# 【v.108.52】ping 失败时的分层诊断：attach 本身通不通、三种写法的 rc 与输出各是什么。
# 只在失败路径调用（成功一次就 return，零额外开销），日志里带 rc，便于下次一眼定位。
_ct_ping_diag() {
    _cpd_h="$1"
    _cpd_t="$(_ct_env "true" 2>&1)"; _cpd_trc=$?
    log "[网络]   attach 探针 rc=$_cpd_trc ${_cpd_t:-（无输出）}"
    _cpd_a="$(_ct_env "ping -c 1 -W 2 $_cpd_h" 2>&1)"; _cpd_arc=$?
    log "[网络]   ping -c 1 -W 2 → rc=$_cpd_arc $(printf '%s' "$_cpd_a" | tr '\n' ' ' | cut -c1-200)"
    _cpd_b="$(_ct_env "ping -c 1 -w 3 $_cpd_h" 2>&1)"; _cpd_brc=$?
    log "[网络]   ping -c 1 -w 3 → rc=$_cpd_brc $(printf '%s' "$_cpd_b" | tr '\n' ' ' | cut -c1-200)"
    _cpd_c="$(_ct_env "ping -c 1 $_cpd_h" 2>&1)"; _cpd_crc=$?
    log "[网络]   ping -c 1     → rc=$_cpd_crc $(printf '%s' "$_cpd_c" | tr '\n' ' ' | cut -c1-200)"
    return 0
}
_host_ping_ok() {
    run ping -c 1 -W 2 "$1" >/dev/null 2>&1 && return 0
    sleep 1
    run ping -c 1 "$1" >/dev/null 2>&1
}
verify_ct_net_ping() {
    ct_running || return 0          # 未启动：不判 ping，交给后续组
    if ! _host_ping_ok "$CONTAINER_IP"; then
        log "[网络] 宿主机 ping 容器 $CONTAINER_IP 失败（仅告警，不计入不符）"
        _ct_ping_diag "$CONTAINER_IP"
        return 0
    fi
    if ! _ct_ping_ok "$BRIDGE_IP"; then
        # 【v.108.52】ping 从「硬判据」降为「告警」。
        # 真机（24.10，2026-10-22）：人手 lxc-attach 进容器 ping 网桥 1/1 通，脚本在
        # 同一时刻用同一条命令却 rc=1；而 _ct_env "echo hi"、"command -v ping" 都 rc=0，
        # ct ls 也 rc=0 —— 失败夹在「attach 成功」与「ping 返回」之间，既不是防火墙
        # （input_lxc 已是 jump accept，forward_lan 有 lan2lxc 且无 l4proto），也不是 DNS。
        # 既然文件内容核对（verify_sub_ct_net）才是硬判据，ping 就不该让整轮引导 exit 1：
        # 那会把「一次手工重跑」变成「构建后始终不符 → 引导失败」的假故障。
        # 保留完整诊断输出，下次真出问题能一眼定位是哪一层。
        log "[网络] 容器 ping 网桥 $BRIDGE_IP 失败（仅告警，不计入不符；静态内容已核对）"
        _ct_ping_diag "$BRIDGE_IP"
    fi
    return 0
}
verify_ct_net() {
    verify_sub_ct_net && verify_ct_net_ping
}
build_ct_net() {
    setup_container_network || return 1
    # 容器已在跑的情况下文件改了需要生效：尝试不重启地拉起网络
    if ct_running; then
        if _is_minimal_init; then
            # 极简版没有 networkd：netconf 用 `ip ... replace` 套用，幂等、不会断掉已有连接
            _ct_env "/etc/init.d/netconf restart" >/dev/null 2>&1 || true
        else
            _ct_env "systemctl restart systemd-networkd" >/dev/null 2>&1 || true
        fi
        # 【v.108.50】改完文件不等于通了。真机上「每轮判不符 → 每轮重建一次」的根因
        # 往往是 veth 已经从 lxcbr0 上掉了（netifd 重建过网桥），而 netconf restart
        # 只套用地址、不负责把端口接回去。这里接回去再验一次：修好了下一轮自然通过，
        # 修不好也要把话说出来，不许假绿。
        if ! verify_ct_net_ping; then
            log "[网络] 重建后仍不通，检查 veth 是否掉线并尝试重接"
            _reattach_ct_veth || true
            verify_ct_net_ping || log "[网络] veth 重接后仍不通（宿主机侧链路问题，等下次网络重载/重启）"
        fi
    fi
    return 0
}

# ---- PREP / cgroup_mount：systemd cgroup 挂载点（容器启动前必须就绪）----
# 宿主侧判据（v.108.15）：不只看「这个路径上有没有挂东西」，还要看挂的是什么。
# 只 grep 路径会误判两类：
#   · 子层级挂载 —— /sys/fs/cgroup/systemd/user.slice 含同一段路径前缀
#   · 别的东西被挂到同一路径（tmpfs 等）—— 路径在、类型不对，容器内照样用不了
# 所以按 /proc/mounts 的列逐项比：$2 挂载点、$3 fstype、$4 挂载选项里的 name=systemd。
_cg_host_ok() {
    awk '$2=="/sys/fs/cgroup/systemd" && $3=="cgroup" && $4 ~ /(^|,)name=systemd(,|$)/ {f=1} END{exit !f}' \
        /proc/mounts 2>/dev/null
}

# LXC 以 systemd 方式引导，缺 /sys/fs/cgroup/systemd 容器起不来或起一半就死。
verify_cgroup_mount() {
    # 极简版容器里没有 systemd，也就没有「systemd 自己去 mount cgroup」这一步，
    # 这个宿主侧挂载点对它毫无意义 —— 直接判就绪，避免为了不存在的消费者去动宿主。
    _is_minimal_init && return 0
    # ① 唯一可靠判据：/proc/mounts 里真有这个挂载点，且是 cgroup/name=systemd
    _cg_host_ok && return 0
    # ② 只有「纯 cgroup v2 unified」才允许跳过：内核里压根没有 v1 命名层级时，
    #    容器内 systemd 的 cgroup 视图由 LXC 的 lxc.mount.auto 提供。
    #    v.108.3 之前这里只判 `cgroup2 存在` 就 return 0 —— hybrid 宿主（同时挂了
    #    cgroup v1 和 v2）会因此永远跳过挂载，容器内 systemd 起不来，
    #    而宿主这边判「已就绪」。这就是那条 Failed to mount API filesystems 的来源之一。
    #
    #    【v.108.43】原写法是：
    #        ! grep -qE 'type cgroup[[:space:]]' /proc/mounts
    #    这个条件**恒为真** —— /proc/mounts 的列是
    #        <设备> <挂载点> <fstype> <挂载选项> <dump> <pass>
    #    里面压根没有 "type " 这个字面量（那是 mount(8) 的显示格式，不是 /proc/mounts）。
    #    于是判据退化成「只要 /proc/mounts 里有 cgroup2 就跳过」，
    #    v.108.3 想修的 hybrid 误判其实一直没修上。
    #    首台真机实测正是 hybrid：
    #        cgroup2 /sys/fs/cgroup         cgroup2 ...
    #        cgroup  /sys/fs/cgroup/systemd cgroup  ... name=systemd
    #    而 verify 照样报「就绪」—— 只因为 ① 恰好也命中（name=systemd 真的挂着），
    #    两个判断互相抵消，问题被藏住了。若哪天 name=systemd 没挂，这里就会假绿：
    #    宿主说就绪、build_cgroup_mount 不执行、容器内 systemd 起不来。
    #    改按 fstype 列判：v2 在 且 v1 不在，才算纯 v2。
    if awk 'BEGIN{v1=0;v2=0} $3=="cgroup"{v1=1} $3=="cgroup2"{v2=1} END{exit !(v2 && !v1)}' \
            /proc/mounts 2>/dev/null; then
        return 0
    fi
    # ③ 其余情况（v1 可用但没挂 / hybrid）→ 确实缺，交给 _mount_systemd_cgroup
    return 1
}
build_cgroup_mount() {
    # 极简版不需要这个层级（容器里没有 systemd 去 mount cgroup）：
    # 宿主 CGROUP_DEVICE / CGROUP_FREEZER 都没开，这里少一次 mount 就少一个失败点。
    _is_minimal_init && return 0
    # 不吞返回值：这里挂不上，容器内 systemd 必然报
    # Failed to mount API filesystems 然后 Exiting PID 1，容器永远起不来。
    # 原先无条件 return 0，等于「日志说挂了、退出码说成功」。
    _mount_systemd_cgroup
    return $?
}

# 容器内 cgroup 视图是否真能用（v.108.15）
# 宿主挂对了不等于容器里能用：中间还隔着 LXC 的 mount 准备、容器内 systemd 的引导。
# 这条补的就是中间那段 —— 它只能在容器起来之后跑，所以挂在 ct_boot 尾部。
verify_ct_bootlink() {
    verify_sub_ct_bootlink
}
build_ct_bootlink() {
    setup_container_boot
}

# ---- PREP / ct_resolv：容器内 resolv.conf ----
verify_ct_resolv() {
    verify_sub_ct_resolv
}
build_ct_resolv() {
    setup_resolv
}

# ---- CAPIBLOCK / capi_block：容器启动前注释掉 online_client ----
# 关键：这一步必须在 ct_boot 之前。config.yaml 是 crowdsec 启动时读取的，
# 启动后再改等于没改（服务不重载），新装阶段会因拿不到中央 API 凭证而反复重启。
#
# 【v.108.50】「本轮到底需不需要屏蔽」抽成单独判据，修的是每轮开机的自相矛盾：
#   capi_block 要求 off，capi_release 要求 on —— 同一台机器上这两条不可能同时成立。
#   以前 verify_capi_block 无条件要求 off，于是只要容器已经跑过一轮「放出」，
#   下一轮（探针重跑、阶段 3 的逐节点复验）必然判不符 → 注释 → 紧接着
#   capi_release 又判不符 → 放回 + 重启 crowdsec + 等 8080 回来（真机 29s）。
#   一来一回，日志里就是 _done_capi_block=B 与 _done_capi_release=B 同时出现。
#
#   两种情况下「启动前屏蔽」这个义务本身就不存在：
#   ① 容器已经在跑：启动窗口已经过去，此时注释只在下次重启才生效，
#      而 capi_release 的目标恰恰是 on —— 改了纯属自相矛盾；
#   ② 已装机（有 installed 标记）且 CAPI 凭据文件非空：新装期那个
#      「拿不到凭证 → 引擎反复重启」的前提不成立（空文件才是硬错误），
#      直接带着 on 启动即可，连那一次「放开后重启」都省了。
setup_container_network() {
    [ -d "$ROOTFS" ] || { log "[网络] rootfs 未就绪"; return 1; }
    if _is_minimal_init; then
        # 【v.108.46】极简版的 net.conf 是**静态文件**：构建期由 rootfs-skel 装进 tarball
        # 和固件两处（同字节），由 crowdsec-guard 逐字节保护。
        # 这里不再重写 —— 写了就是 bootstrap 和 guard 抢同一个文件（写 v1、盖回 v2），
        # 每 60 秒一次，正是 v.108.44 那个 flash 磨损事故的形态，只是换了个理由。
        # 只确认它还在：缺了交给 guard 复原，guard 也补不上就交给 _structurally_broken。
        _netfile="$ROOTFS/etc/crowdsec-net.conf"
        if [ -s "$_netfile" ]; then
            log "[网络] 容器静态 IP ${CONTAINER_IP}/24 网关 ${BRIDGE_IP}（静态文件，guard 保护）"
            return 0
        fi
        log "[网络] 缺 /etc/crowdsec-net.conf（静态文件被删？），等 guard 从 /rom 复原"
        return 1
    fi
    _dns="$BRIDGE_IP"
    _netfile="$ROOTFS/etc/systemd/network/10-eth0.network"
    mkdir -p "$(dirname "$_netfile")" 2>/dev/null
    atomic_write "$_netfile" "Address=${CONTAINER_IP}/24" <<EOF || { log "[网络] 容器网络文件写入不完整"; return 1; }
[Match]
Name=eth0

[Network]
Address=${CONTAINER_IP}/24
Gateway=${BRIDGE_IP}
DNS=${_dns}
EOF
    log "[网络] 容器静态 IP ${CONTAINER_IP}/24 网关 ${BRIDGE_IP} DNS ${_dns}"
    return 0
}

setup_container_boot() {
    [ -d "$ROOTFS" ] || { log "[自启] rootfs 未就绪"; return 1; }
    if _is_minimal_init; then
        # 极简版：自启写在 inittab 里（::sysinit 跑 rcS，::respawn 看住 crowdsec），
        # 没有软链可建。缺 inittab / init.d/crowdsec 说明 rootfs 残缺，必须判失败——
        # 口径与 systemd 版「缺 crowdsec.service 就 return 1」一致。
        [ -s "$ROOTFS/etc/inittab" ] \
            || { log "[自启] 容器内缺 /etc/inittab（rootfs 残缺），无法引导"; return 1; }
        [ -s "$ROOTFS/etc/init.d/crowdsec" ] \
            || { log "[自启] 容器内缺 /etc/init.d/crowdsec（rootfs 残缺）"; return 1; }
        chmod +x "$ROOTFS/etc/init.d/rcS" "$ROOTFS/etc/init.d/crowdsec" \
                 "$ROOTFS/etc/init.d/netconf" "$ROOTFS/etc/init.d/syslogd" \
                 "$ROOTFS/usr/sbin/crowdsec-supervise" 2>/dev/null
        echo "crowdsec" | atomic_write "$ROOTFS/etc/hostname" "crowdsec" || return 1
        _mid=$(cat "$ROOTFS/etc/machine-id" 2>/dev/null | tr -d ' \t\r\n')
        printf '%s' "$_mid" | grep -qE '^[0-9a-f]{32}$' || {
            _mid=$( (tr -d ' \t\r\n' < /etc/machine-id 2>/dev/null | grep -oE '^[0-9a-f]{32}$') )
            [ -n "$_mid" ] || _mid=$(sha256sum /proc/sys/kernel/random/uuid 2>/dev/null | cut -c1-32)
            [ -n "$_mid" ] || _mid=$(date +%s%N 2>/dev/null | sha256sum | cut -c1-32)
            printf '%s\n' "$_mid" | atomic_write "$ROOTFS/etc/machine-id" "" || return 1
        }
        log "[自启] 极简 init：inittab + rcS + init.d/crowdsec 已就绪，hostname/machine-id 已初始化"
        return 0
    fi
    _wants="$ROOTFS/etc/systemd/system/multi-user.target.wants"
    mkdir -p "$_wants" 2>/dev/null
    [ -f "$ROOTFS/lib/systemd/system/systemd-networkd.service" ] \
        && ln -sf /lib/systemd/system/systemd-networkd.service "$_wants/systemd-networkd.service" 2>/dev/null
    # ★ 必须判到底（v.108.15）：ensure() 在 build 成功之后**不复核** verify，
    #   只把节点标成完成。原来这里写 `[ -f ... ] && ln -sf`，crowdsec.service 不在时
    #   短路跳过、函数照样 return 0 —— verify 说「不符」、build 说「修好了」，
    #   两边都没错但结论相反，最终的假绿一路带到阶段 3 才炸。
    [ -f "$ROOTFS/lib/systemd/system/crowdsec.service" ] \
        || { log "[自启] 容器内缺 crowdsec.service（rootfs 残缺），无法建自启软链"; return 1; }
    ln -sf /lib/systemd/system/crowdsec.service "$_wants/crowdsec.service" 2>/dev/null \
        || { log "[自启] 建 crowdsec 自启软链失败（$_wants 不可写？）"; return 1; }
    echo "crowdsec" | atomic_write "$ROOTFS/etc/hostname" "crowdsec" || return 1
    # machine-id 必须是 32 位 hex（systemd 要求）；空文件会让判定永不符 → 每次启动重复构建
    _mid=$(cat "$ROOTFS/etc/machine-id" 2>/dev/null | tr -d ' \t\r\n')
    printf '%s' "$_mid" | grep -qE '^[0-9a-f]{32}$' || {
        _mid=$( (tr -d ' \t\r\n' < /etc/machine-id 2>/dev/null | grep -oE '^[0-9a-f]{32}$') )
        [ -n "$_mid" ] || _mid=$(sha256sum /proc/sys/kernel/random/uuid 2>/dev/null | cut -c1-32)
        [ -n "$_mid" ] || _mid=$(date +%s%N 2>/dev/null | sha256sum | cut -c1-32)
        printf '%s\n' "$_mid" | atomic_write "$ROOTFS/etc/machine-id" "" || return 1
    }
    log "[自启] networkd + crowdsec 软链已建，hostname/machine-id 已初始化"
    return 0
}

setup_resolv() {
    [ -d "$ROOTFS" ] || { log "[DNS] rootfs 未就绪"; return 1; }
    _resolv="$ROOTFS/etc/resolv.conf"
    if _is_minimal_init; then
        # 【v.108.46】同上：resolv.conf 也是静态文件（nameserver 固定为网桥 IP）。
        if [ -s "$_resolv" ]; then
            log "[DNS] 容器 resolv.conf 为静态文件（guard 保护）"
            return 0
        fi
        log "[DNS] 缺 /etc/resolv.conf（静态文件被删？），等 guard 从 /rom 复原"
        return 1
    fi
    _dns="$BRIDGE_IP"
    echo "nameserver ${_dns}" | atomic_write "$_resolv" "nameserver" \
        || { log "[DNS] resolv.conf 写入不完整"; return 1; }
    chmod 644 "$_resolv" 2>/dev/null
    log "[DNS] 容器 resolv.conf → ${_dns}"
    return 0
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
        printf '%%s\n' "$_cg_n" >&2
    done
    return 1
}

# ============ 第二步：修复（只动不过的） ============
_fix_group() {
    _fg_n=0
    for _fg_x in $MY_NODES; do
        "verify_$_fg_x" >/dev/null 2>&1 && continue
        _fg_n=$((_fg_n + 1))
        log "[%%s] 修复 %%s" "$MY_GROUP" "$_fg_x"
        ensure "$_fg_x" || log "[%%s] 修复 %%s 未成功（留待复检）" "$MY_GROUP" "$_fg_x"
    done
    [ "$_fg_n" -gt 0 ] || log "[%%s] 无需修复（本组节点全部达标）" "$MY_GROUP"
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
