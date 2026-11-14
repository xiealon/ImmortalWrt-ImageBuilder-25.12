#!/bin/sh
# bootstrap/net/step.sh —— NETBASE 组（net）
#
# 两步结构：
#   第一步 --check   只检测，一个字节都不写。逐节点跑 verify_<node>，
#                    全部达标返回 0；有不过的把它们打在 stderr 并返回 1。
#   第二步 --fix     只修「检测不过」的那些（内部走 ensure，先查后改），
#                    修完复检一次；仍不过返回 1。
#
# 本组节点（按 DAG 顺序）：br_lan_ports lan_static dhcp_ignore bridge lxc_auto lxc_zone fwd_rules lan_input snat ip_forward svc_bind docker_fw pkg_base
#
# 用法：
#   ./step.sh --check          检测本组
#   ./step.sh --fix            修本组（只动不过的节点）
#   ./step.sh --node <名字>    只处理单个节点（--check-node / --fix-node 同理）

# 【2026-11-10】脚本根：默认直接从只读基座 /rom 调用。
# 为什么：/rom 是 squashfs 只读分区，脚本本身改不了，天然免疫篡改与误删 ——
#   比「运行副本 + 事后比对恢复」更硬，也省掉每轮 73 次进程比对。
# 需要热修（改脚本立刻生效，不刷机）时，把 CS_SCRIPT_ROOT 设成空串即可退回 /usr/sbin。
SROOT="${CS_SCRIPT_ROOT-/rom}"

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

MY_GROUP="NETBASE"
MY_NODES="br_lan_ports lan_static dhcp_ignore bridge lxc_auto lxc_zone fwd_rules lan_input snat ip_forward svc_bind docker_fw pkg_base"

_lxc_net() {
    echo "$CONTAINER_IP" | awk -F. '{print $1"."$2"."$3".0/24"}'
}

_lan_ip() {
    # SNAT 的目标地址 = 路由器在 LAN 上的管理 IP。
    # 优先读 uci network.lan.ipaddr：它由 build_lan_static 写入并当场 commit，
    # 是「fw4 reload 之后最终会生效、且 nft 规则会按它生成」的那个值 —— 与
    # snat_ip 的语义天然对齐。verify_snat_rule 比对的也是这个值，两边同源，
    # 不会出现「读取端各算各的、互相通过」。
    # 读内核 br-lan 只作为兜底：br-lan 的真实地址要 network reload 之后才更新，
    # 而 reload 在 build_NETBASE 末尾的 flush_uci 里，晚于本节点 —— 此刻读内核
    # 拿到的还是旧地址，反而会把即将失效的 IP 固化进规则。
    _si=$(run uci -q get network.lan.ipaddr 2>/dev/null)
    if [ -z "$_si" ]; then
        _si=$(run ip -4 addr show br-lan 2>/dev/null | sed -n 's/.*inet \([0-9][0-9.]*\)\/.*/\1/p' | head -n1)
        # 必须走 stderr：本函数靠 stdout 的 echo 返回结果，调用方是 $( _lan_ip )，
        # 打到 stdout 的日志会混进返回值，让 snat_ip 变成两行字符串。
        [ -n "$_si" ] && log "[SNAT] 配置里没有 lan 地址，改用 br-lan 实际地址 $_si" >&2
    fi
    [ -n "$_si" ] || { [ -f /etc/config/custom_router_ip.txt ] && _si=$(head -n1 /etc/config/custom_router_ip.txt | tr -d ' \t\r\n'); }
    [ -n "$_si" ] || _si='10.0.0.201'
    echo "$_si"
}

# 读取 custom_*.txt 首行（编译期 Actions 写入 /etc/config，运行时可改文件免重编译）
_read_netconf() {
    [ -f "/etc/config/$1" ] || return 0
    head -n1 "/etc/config/$1" | tr -d ' \t\r\n'
}

# 管理地址期望值唯一推导处（自 99-custom.sh 同源搬迁，v.78-bp 起由 bootstrap 每次开机按需校准）
# 输出一行四值：IP NETMASK GATEWAY DNS；推导规则与原 99-custom.sh 完全一致：
#   默认 10.0.0.201/24 网关 DNS 10.0.0.10；自定义 IP + /24 → 网关 DNS 推导为前三段.1；
#   custom_router_gateway/dns.txt 显式传入时优先级最高
_lan_static_conf() {
    _ls_ip='10.0.0.201'
    _ls_nm="$(_read_netconf custom_router_netmask.txt)"
    [ -n "$_ls_nm" ] || _ls_nm='255.255.255.0'
    _ls_gw='10.0.0.10'
    _ls_dn='10.0.0.10'
    _ls_uip="$(_read_netconf custom_router_ip.txt)"
    if [ -n "$_ls_uip" ]; then
        _ls_ip="$_ls_uip"
        if [ "$_ls_nm" = "255.255.255.0" ]; then
            _ls_gw="$(echo "$_ls_ip" | awk -F. '{print $1"."$2"."$3".1"}')"
            _ls_dn="$_ls_gw"
        fi
    fi
    _ls_ugw="$(_read_netconf custom_router_gateway.txt)"
    if [ -n "$_ls_ugw" ]; then
        _ls_gw="$_ls_ugw"
        [ -n "$(_read_netconf custom_router_dns.txt)" ] || _ls_dn="$_ls_ugw"
    fi
    _ls_udn="$(_read_netconf custom_router_dns.txt)"
    [ -n "$_ls_udn" ] && _ls_dn="$_ls_udn"
    echo "$_ls_ip $_ls_nm $_ls_gw $_ls_dn"
}

# 四值合法性闸门（v.95）：_lan_static_conf 的产出直接喂给 uci，写错就是失联。
# 这里只做「像不像一个能用的地址」的兜底，不做业务校验：
#   · IP / 网关 / DNS 必须是点分四段、每段 0-255
#   · 掩码必须点分四段（常见的 255.255.x.0 系列，也接受非连续掩码，只查格式）
#   · IP 不能是 0.0.0.0 / 255.255.255.255 / .0 网段首地址（不含 .1 之类）
# 任一不过 → 返回 1，由 build_lan_static 判 hard，绝不把坏值写进 uci。
_is_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        { for (i = 1; i <= 4; i++) {
              if ($i !~ /^[0-9]+$/) exit 1
              if ($i + 0 > 255) exit 1
              if (length($i) > 1 && substr($i, 1, 1) == "0") exit 1
          } }
        { exit 0 }'
}
_lan_conf_valid() {
    _lc_ip="$1"; _lc_nm="$2"; _lc_gw="$3"; _lc_dn="$4"
    for _lc_v in "$_lc_ip" "$_lc_nm" "$_lc_gw" "$_lc_dn"; do
        _is_ipv4 "$_lc_v" || return 1
    done
    case "$_lc_ip" in
        0.*|255.255.255.255) return 1 ;;
    esac
    # IP 与网关撞了就没法路由
    [ "$_lc_ip" != "$_lc_gw" ] || return 1
    return 0
}

# 物理网口列表：排除 lo/虚拟/桥接。前缀集合 = 有线（eth*/en*/lan*）+ USB 网卡（usb*）
# + 移动模块数据口（wwan*）；wlan* 不在内——无线走 AP 模式，不是桥的物理口。
# 用于 WAN-input 放行定责：单网口才需放行，多网口必有一个在 LAN，无需放行
_phys_ports() {
    # 这里 ls 是有意的：/sys/class/net 下的名字都是内核起的（eth0/br-lan/…），
    # 不存在空格、换行这类会把 glob 撑坏的情况；换成 glob 反而要处理通配符空匹配。
    # shellcheck disable=SC2010
    ls /sys/class/net/ 2>/dev/null | grep -E '^(eth|en|lan|usb|wwan)' | grep -v -E '(lo|docker|veth|br-|tun|tap)' | sort
}

# 列表归一化：把「多行」或「空格分隔」的列表统一成「排序后的单行」（v.99-bp.1）
# 用途：uci get 一个 list 返回「单行空格分隔」（eth0 eth1），而 _phys_ports 返回「多行」，
# 两者直接比永远不等；归一化后才有可比性。
_norm_list() { ( for _w in $1; do printf '%s\n' "$_w"; done ) | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//'; }

# 按职责(name)定位 firewall zone 的 section 名，不赌 @zone[N] 索引
# （索引会因其他包 insert zone / 定制改序而漂移，name 才是稳定职责标识）
_zone_sec() {
    for _z in $(run uci show firewall 2>/dev/null | grep -E '=zone$' | cut -d. -f2 | cut -d= -f1); do
        [ "$(run uci -q get firewall.$_z.name 2>/dev/null)" = "$1" ] && { echo "$_z"; return 0; }
    done
    return 1
}

# LAN zone 网络接口名唯一出处：按 name 定责取 firewall zone(lan).network 首值
_zone_lan_network() {
    _lz=$(_zone_sec lan) || return 1
    _zn=$(run uci -q get firewall.$_lz.network 2>/dev/null | head -n1)
    [ -n "$_zn" ] || return 1
    echo "$_zn"
}

verify_lxc_zone() {
    # 【v.108.24】按 name 定位段，不赌段名。
    # build_lxc_zone / build_fwd_rules 用 _zone_sec lxc 找段（LuCI 删了重建会变成 @zone[3]/cfg0xxxx），
    # 而这里原来写死 firewall.lxczone —— 用户在界面上明明配好了 lxc zone，
    # verify 却说没有，于是每次开机都重建一遍。判据必须和 builder 用同一个定位方式。
    _vz=$(_zone_sec lxc) || return 1
    [ "$(run uci -q get "firewall.$_vz.network")" = "lxc" ] || return 1
    [ "$(run uci -q get "firewall.$_vz.input")" = "ACCEPT" ] || return 1
    [ "$(run uci -q get "firewall.$_vz.output")" = "ACCEPT" ] || return 1
    [ "$(run uci -q get "firewall.$_vz.forward")" = "ACCEPT" ] || return 1
}

verify_fwd_rules() {
    # 【v.108.24】不只看 src/dest：build 写的四项（段类型 rule / src / dest / target）
    # 必须全部对上。原来只比 src/dest，于是 target 被清掉、段类型被改坏时判「已就绪」，
    # 规则实际是 reject/不生效 —— 容器能起、拉不到日志，症状极难倒推。
    [ "$(run uci -q get firewall.lxc2lan)" = "rule" ] || return 1
    [ "$(run uci -q get firewall.lxc2lan.src)" = "lxc" ] || return 1
    [ "$(run uci -q get firewall.lxc2lan.dest)" = "lan" ] || return 1
    [ "$(run uci -q get firewall.lxc2lan.target)" = "ACCEPT" ] || return 1
    [ "$(run uci -q get firewall.lxc2lan.proto)" = "all" ] || return 1
    [ "$(run uci -q get firewall.lxc2docker)" = "rule" ] || return 1
    [ "$(run uci -q get firewall.lxc2docker.src)" = "lxc" ] || return 1
    [ "$(run uci -q get firewall.lxc2docker.dest)" = "docker" ] || return 1
    [ "$(run uci -q get firewall.lxc2docker.target)" = "ACCEPT" ] || return 1
    [ "$(run uci -q get firewall.lxc2docker.proto)" = "all" ] || return 1
    [ "$(run uci -q get firewall.lxc2vpn)" = "rule" ] || return 1
    [ "$(run uci -q get firewall.lxc2vpn.src)" = "lxc" ] || return 1
    [ "$(run uci -q get firewall.lxc2vpn.dest)" = "vpn" ] || return 1
    [ "$(run uci -q get firewall.lxc2vpn.target)" = "ACCEPT" ] || return 1
    [ "$(run uci -q get firewall.lxc2vpn.proto)" = "all" ] || return 1
    [ "$(run uci -q get firewall.lan2lxc)" = "rule" ] || return 1
    [ "$(run uci -q get firewall.lan2lxc.src)" = "lan" ] || return 1
    [ "$(run uci -q get firewall.lan2lxc.dest)" = "lxc" ] || return 1
    [ "$(run uci -q get firewall.lan2lxc.target)" = "ACCEPT" ] || return 1
    [ "$(run uci -q get firewall.lan2lxc.proto)" = "all" ] || return 1
}

# SNAT 段定位：按 name="lxc-snat" 找 nat 段，不赌段名。
# LuCI 删了重建会把段名变成 @nat[0] / cfg0a1b2c 之类，写死 lxcsnat 会在
# 「用户在界面上明明配了」的情况下误判缺失，然后每小时开机都报一遍待办。
_snat_sec() {
    for _s in $(run uci show firewall 2>/dev/null | grep -E '=nat$' | cut -d. -f2 | cut -d= -f1); do
        [ "$(run uci -q get "firewall.$_s.name" 2>/dev/null)" = "lxc-snat" ] \
            && { printf '%s\n' "$_s"; return 0; }
    done
    return 1
}

verify_snat_rule() {
    _sn=$(_snat_sec) || return 1
    [ "$(run uci -q get "firewall.$_sn.target" 2>/dev/null)" = "SNAT" ] || return 1
    [ "$(run uci -q get "firewall.$_sn.proto"  2>/dev/null)" = "all" ] || return 1
    [ "$(run uci -q get "firewall.$_sn.src"    2>/dev/null)" = "lan" ] || return 1
    [ "$(run uci -q get "firewall.$_sn.src_ip" 2>/dev/null)" = "$(_lxc_net)" ] || return 1
    [ "$(run uci -q get "firewall.$_sn.snat_ip" 2>/dev/null)" = "$(_lan_ip)" ] || return 1
    return 0
}

verify_ip_forward() {
    [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ] || return 1
}

# 容器 veth 掉线重接（首台真机 2026-10-22 现场新增）
#
# 现象：lxcbr0 有 IP 但 <NO-CARRIER>，容器 eth0 有 IP 且 LAPI 在 :::8080 LISTEN，
#       宿主 ping 容器 100% 丢包。两边都"正常"，中间那根线不在。
# 成因：/etc/init.d/network reload 让 netifd 按 uci 重建 lxcbr0（拆了重加），
#       而容器已经在跑 —— LXC 只在 lxc-start 时插 veth，之后没人负责接回端口。
# 判据：宿主侧 veth 的 iflink == 容器 eth0 的 ifindex（veth 对端的编号关系）。
# 兜底：找不到对端就什么都不做，绝不 ip link del 网桥（那会把容器网彻底打死）。
verify_bridge() {
    # 【v.108.24】uci 侧三项（proto/device/ipaddr）与内核侧地址一起比。
    # build 写的是 network.lxc = interface / proto=static / device=lxcbr0 /
    # ipaddr=BRIDGE_IP / netmask，原来只比 proto + 内核 IP：
    # device 被改成 eth0、ipaddr 被改成别的，只要内核地址还在就判「已就绪」，
    # 重启后 netifd 按 uci 重新拉起，lxcbr0 就没了。
    [ "$(run uci -q get network.lxc)" = "interface" ] || return 1
    [ "$(run uci -q get network.lxc.proto 2>/dev/null)" = "static" ] || return 1
    [ "$(run uci -q get network.lxc.device 2>/dev/null)" = "lxcbr0" ] || return 1
    [ "$(run uci -q get network.lxc.ipaddr 2>/dev/null)" = "$BRIDGE_IP" ] || return 1
    # 【v.108.37】netmask 也要验：build 写了它，verify 原来不看，
    # 掩码被改成 /16 之类时接口照起、地址照在，但整个 10.1.0.0/16 都会被算进直连，
    # 容器和 LAN 网段的转发判定跟着变 —— 属于「写了没验」的漏项。
    [ "$(run uci -q get network.lxc.netmask 2>/dev/null)" = "255.255.255.0" ] || return 1
    # 【v.108.34】设备必须自己声明过：没有 config device 时 netifd 把 lxcbr0 当外部设备，
    # 「有就拿来用、没有也不建」。于是重启后网桥不存在，全靠脚本开机时 ip link add 兜着；
    # 脚本在 bridge 之前任何一步失败，网桥就没了 —— 这正是「ip link show 里没有 lxcbr0」。
    [ "$(run uci -q get network.lxcbr0)" = "device" ] || return 1
    [ "$(run uci -q get network.lxcbr0.type 2>/dev/null)" = "bridge" ] || return 1
    [ "$(run uci -q get network.lxcbr0.name 2>/dev/null)" = "lxcbr0" ] || return 1
    # 空网桥没有 bridge_empty='1' 时 netifd 直接不建（端口要等容器 veth 接进来）
    [ "$(run uci -q get network.lxcbr0.bridge_empty 2>/dev/null)" = "1" ] || return 1
    # 【首台真机 2026-10-22】端口在位才算就绪。
    #   netifd reload 会把 lxcbr0 拆了重建，端口跟着掉光变成 NO-CARRIER，
    #   而上面这些判据（device/proto/ipaddr/netmask/bridge_empty/地址）**全都还成立** ——
    #   这正是「两边各自都正常、中间断链」能藏住的根本原因：判据里没有一条问「桥里有谁」。
    #   容器在跑就必须有 veth 挂在桥上；容器没跑时不要求（空桥是常态，bridge_empty=1 就是为此）。
    if ct_running; then
        ip -d link show master lxcbr0 2>/dev/null | grep -q 'veth' || return 1
    fi
    run ip link show lxcbr0 >/dev/null 2>&1 || return 1
    _vb=$(ip -4 addr show lxcbr0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n1)
    [ -n "$_vb" ] && [ "$_vb" = "$BRIDGE_IP" ]
}

# LAN zone 放行独立验证（定责 name=lan）：input/forward 必须 ACCEPT
verify_lan_input() {
    # 【2026-11-14 加】lan6 必须在 lan zone 的 network 列表里，否则 IPv6 被默认策略丢掉
    _vlz=$(_zone_sec lan) 2>/dev/null
    if [ -n "$_vlz" ]; then
        run uci -q show "firewall.$_vlz" 2>/dev/null | grep -q "lan6" || return 1
    fi
    _lz=$(_zone_sec lan) || { log "[FW] 未找到 lan zone，本轮不校验 input/forward"; return 0; }
    [ "$(run uci -q get firewall.$_lz.input 2>/dev/null)" = "ACCEPT" ] || return 1
    [ "$(run uci -q get firewall.$_lz.forward 2>/dev/null)" = "ACCEPT" ] || return 1
    return 0
}

# ---- 旁路由网络基线（v.78-bp 起自 99-custom.sh 同源搬迁，每次开机按需校准）----

# 桥接口验证：br-lan bridge 设备 + ports 与 /sys 实际枚举物理口集合一致 + 无残留 cfg030f15
# 枚举为空（开机早期网口驱动未就绪）→ 跳过不误建空桥（防外网断）
verify_br_lan_ports() {
    _vp=$(_phys_ports)
    # 枚举不到物理网口 → return 1（不通过），不是 return 0。
    # 原来这里 return 0：verify 判「通过」后 ensure 根本不会去 build，于是 br-lan 桥
    # 从没被建过，却一路标记完成、组置位、--net-only 分支 exit 0 —— 网络没配好却
    # 报成功，日志干干净净。build_br_lan_ports 那边同条件是 return 1
    # （「未枚举到物理网口（驱动未就绪？），不敢建空桥」），两处必须一致：
    # 「无法确认」就是「不通过」，交给 build 响亮地失败，别在这里假装验过了。
    [ -n "$_vp" ] || return 1
    # 段类型必须是 device：`config br_lan 'br_lan'` 这种非 device 段 netifd 不认，
    # 只查 .type='bridge' 会漏过去（运行时桥还在，重启才丢）。
    [ "$(run uci -q get network.br_lan 2>/dev/null)" = "device" ] || return 1
    [ "$(run uci -q get network.br_lan.type 2>/dev/null)" = "bridge" ] || return 1
    [ "$(run uci -q get network.br_lan.name 2>/dev/null)" = "br-lan" ] || return 1
    [ "$(run uci -q get network.lan.device 2>/dev/null)" = "br-lan" ] || return 1
    for _ds in $(run uci show network 2>/dev/null | grep -E '=device$' | cut -d. -f2 | cut -d= -f1); do
        [ "$_ds" = "br_lan" ] && continue
        if [ "$(run uci -q get "network.$_ds.name" 2>/dev/null)" = "br-lan" ]; then
            return 1
        fi
    done
    # v.99-bp.1 修正：原来两侧各自 `sort` 后直接比字符串，但
    #   左边 _phys_ports 是「多行」（eth0\neth1\neth2）
    #   右边 uci get 的 list 是「单行空格分隔」（eth0 eth1 eth2）
    # 一个多行、一个单行，sort 改变不了行数，**永不相等**。真机上表现为多网口设备
    # 每次开机都判「不符」→ 重建 br-lan + commit + network reload，开机瞬间 LAN 闪断；
    # 单网口时两边恰好都是单行，所以问题被掩盖。
    # 单测里没暴露，是因为 mock 的 uci 把 list 存成多条记录、get 时按行输出（多行），
    # 与 _phys_ports 同格式 —— 与真机 uci 行为不一致。归一化后两种格式都能正确比对。
    [ "$(_norm_list "$_vp")" = "$(_norm_list "$(run uci -q get network.br_lan.ports 2>/dev/null)")" ]
}

# LAN 静态地址验证：proto/device/ipaddr/netmask/gateway/dns 与 _lan_static_conf 推导值一致
verify_lan_static() {
    # 这里就是要让它按空白拆开、按位置取 $1..$4；加引号反而会变成一个整体。
    # shellcheck disable=SC2046
    set -- $(_lan_static_conf)
    [ "$(run uci -q get network.lan.proto 2>/dev/null)" = "static" ] || return 1
    [ "$(run uci -q get network.lan.device 2>/dev/null)" = "br-lan" ] || return 1
    [ "$(run uci -q get network.lan.ipaddr 2>/dev/null)" = "$1" ] || return 1
    [ "$(run uci -q get network.lan.netmask 2>/dev/null)" = "$2" ] || return 1
    [ "$(run uci -q get network.lan.gateway 2>/dev/null)" = "$3" ] || return 1
    [ "$(run uci -q get network.lan.dns 2>/dev/null)" = "$4" ] || return 1
    # 【2026-11-10.0355】配置对 ≠ 地址在。
    # 上面六条全是 uci get —— 读的是 /etc/config/network，不是网卡。
    # 真机现场（192.168.1.201，2026-11-10 03:50 重启）：配置文件里 201 一直在，
    # 于是这里判「验证通过，跳过」→ build_lan_static 不跑 → flush_uci 不 reload，
    # 而 netifd 启动那一下并没把地址配上去 → br-lan 没有 inet。
    # 结果脚本一路往下走 bridge 建 lxcbr0，表现就是「IP 没建好却开始走 lxcbr0」，
    # 最后整机失联、SSH 连不上（只能去接显示器）。
    # 这里补一条运行时判据：网卡上必须真能看到 $1/。看不到就返回 1，
    # 让 build_lan_static 重写配置并触发 network reload。
    run ip -4 addr show br-lan 2>/dev/null | grep -q "inet $1/" || return 1
    # 【2026-11-14 加】lan6 必须存在。
    # 补建逻辑挂在 build_lan_static 末尾，而 build 只在本函数返回 1 时才跑；
    # 原来不判 lan6，于是「IP 全对但 lan6 缺失」会判通过 → 补建永远不执行，
    # 表现为 --fix 跑完 lan6 还是没有（2026-11-14 在 192.168.1.201 实测踩到）。
    # 没有 lan6 的后果：br-lan 拿不到 DHCPv6 地址（如果上游只发 DHCPv6），
    # 且防火墙 lan zone 里那条 lan6 成了悬空项。
    run uci -q show network 2>/dev/null | grep -q '^network\.lan6=interface$' || return 1
    # 【2026-11-15 用户定】lan6 的七个 option 也锁死。
    # 原来只判「段存在」：段在、但 proto 被改成 static 或 peerdns 被改成 1 时，
    # verify 照样判通过 → build 不跑 → 配置一直是坏的却没人发现。
    # 改错的后果：proto 不对则 br-lan 拿不到 DHCPv6 地址；peerdns=1 则上游 DNS
    # 会写进 resolv.conf.auto，和本机 smartdns 抢解析。
    [ "$(run uci -q get network.lan6.proto 2>/dev/null)" = "dhcpv6" ] || return 1
    [ "$(run uci -q get network.lan6.device 2>/dev/null)" = "@lan" ] || return 1
    [ "$(run uci -q get network.lan6.reqaddress 2>/dev/null)" = "try" ] || return 1
    [ "$(run uci -q get network.lan6.reqprefix 2>/dev/null)" = "auto" ] || return 1
    [ "$(run uci -q get network.lan6.norelease 2>/dev/null)" = "1" ] || return 1
    [ "$(run uci -q get network.lan6.sendclientid 2>/dev/null)" = "auto" ] || return 1
    [ "$(run uci -q get network.lan6.peerdns 2>/dev/null)" = "0" ] || return 1
    # 【2026-11-14 加】IPv6 前缀分配（用户实测确认）。
    # 位置必须在 lan 上，不能放 lan6：lan6 是 PD 的提供方，给它设 ip6assign 等于
    # 从自己的池里再切一块给自己，netifd 会直接报
    #   Failed to assign requested subprefix of size 64 for lan6, trying other
    # 结果 local-address 为空、br-lan 拿不到前缀，odhcpd 只能退回去用上游 SLAAC
    # 那一段（光猫的 8c00），分配出与光猫同段的地址（真机 2026-11-14 踩到）。
    [ "$(run uci -q get network.lan.ip6assign 2>/dev/null)" = "64" ] || return 1
    # 【2026-11-15 加】ip6ifaceid 必须显式 eui64。
    # 不设时 netifd 给的接口地址是 ::1，实测反复变 deprecated；
    # 显式 eui64 后 ULA 地址 = 前缀 + MAC，valid_lft forever。
    # RDNSS 通告的就是这个地址，所以要一起锁。
    [ "$(run uci -q get network.lan.ip6ifaceid 2>/dev/null)" = "eui64" ] || return 1
    return 0
}

# DHCP 让权验证：IPv4 不发地址（dhcpv4=disabled，让给光猫）；IPv6 由本机发 RA
# 抢默认路由与 RDNSS（ra=server + pref=high + 30-60s），并显式通告本机 link-local。
# 不再置 ignore=1：那会让 odhcpd 整个跳过该接口，连 RA 都不发。
# 只认「不对外发地址」这个实质结果 + 上面那套 RA 参数是否到位。
verify_dhcp_ignore() {
    # 【v.180.94】dhcp.lan 段不存在 = LAN 上根本没有 DHCP 池，本身即「已关闭」。
    # 这里若判未就绪，build 会把段建回来（旧行为），等于替用户重开 DHCP。
    _vdi_has=0
    if run uci show dhcp 2>/dev/null | grep -q '^dhcp\.lan=dhcp$'; then
        _vdi_has=1
    fi
    # 【2026-11-14 改】段不存在 = 需要修复（build 会把段建起来）
    [ "$_vdi_has" = "1" ] || return 1
    # 【2026-11-14 改】旁路由改为「自己发 RA 抢默认路由/DNS」，不再是「关 RA」。
    # 验的是 build 写进去的那套值，任一项不符就判需修复。
    [ -z "$(run uci -q get dhcp.lan.ignore 2>/dev/null)" ] || return 1
    [ "$(run uci -q get dhcp.lan.dhcpv4 2>/dev/null)" = "disabled" ] || return 1
    [ "$(run uci -q get dhcp.lan.ra 2>/dev/null)" = "server" ] || return 1
    [ "$(run uci -q get dhcp.lan.ra_preference 2>/dev/null)" = "high" ] || return 1
    [ "$(run uci -q get dhcp.lan.dns_service 2>/dev/null)" = "1" ] || return 1
    # 【2026-11-15 加】RDNSS 必须指向本机 br-lan 当前的 link-local。
    # 判「等于现算值」而不是判非空：换硬件后 MAC 变、地址跟着变，
    # 只判非空的话旧地址会一直留着，客户端拿到的是死地址。
    # 【2026-11-15 定稿】RDNSS 只判一条 ULA 地址（EUI-64 形式）。
    # 判「等于现算值」而不是判非空：换网卡后 MAC 变、地址跟着变，
    # 只判非空的话旧地址会一直留着，客户端拿到的是死地址。
    _vdi_ula=$(run ip -6 addr show br-lan 2>/dev/null \
               | grep 'inet6 fd' | awk '{print $2}' | cut -d/ -f1 | head -n1)
    [ -n "$_vdi_ula" ] || return 1
    [ "$(run uci -q get dhcp.lan.dns 2>/dev/null)" = "$_vdi_ula" ] || return 1
    # 【2026-11-15 用户定】RA 间隔与 dhcp.lan 段的四项也锁死。
    # 原来 build 会写、verify 不判：被手改后照样判通过，坏值一直留着。
    #   · ra_min/maxinterval 被改大 → 抢不过光猫（它 200-600s），Windows 的 RDNSS 会被覆盖；
    #   · interface 被改错 → odhcpd 服务到别的接口，RA 发不出去；
    #   · start/limit/leasetime 是 DHCPv4 池，dhcpv4 关着时无实际作用，但写死了
    #     才能保证「段被重建」时不出现两套口径。
    [ "$(run uci -q get dhcp.lan.ra_mininterval 2>/dev/null)" = "30" ] || return 1
    [ "$(run uci -q get dhcp.lan.ra_maxinterval 2>/dev/null)" = "60" ] || return 1
    [ "$(run uci -q get dhcp.lan.interface 2>/dev/null)" = "lan" ] || return 1
    [ "$(run uci -q get dhcp.lan.start 2>/dev/null)" = "231" ] || return 1
    [ "$(run uci -q get dhcp.lan.limit 2>/dev/null)" = "20" ] || return 1
    [ "$(run uci -q get dhcp.lan.leasetime 2>/dev/null)" = "12h" ] || return 1
    for _dm in $(run uci show dhcp 2>/dev/null | grep -E '=dnsmasq$' | cut -d. -f2 | cut -d= -f1); do
        [ -z "$(run uci -q get "dhcp.$_dm.authoritative" 2>/dev/null)" ] || return 1
    done
    return 0
}

# ---- smartdns 接管 DNS（DNS 从 dnsmasq 手里拿过来）----
# 目标：smartdns 直接监听 53 当权威解析，dnsmasq 只留 DHCP/RA，不再做 DNS。
# v.180.85 起本节点只做「已装才配置」：smartdns 不在位就直接放行，装入与补配统一交给
# 末尾的 DEPS 节点（网络没通时在这里硬装只会失败并把整轮引导带走）。
# 上游：国内 9 个 UDP（近、快；阿里/腾讯/百度/360/CNNIC），境外 4 个 DoT（带 SNI，防污染）。
# 关于 server_group：smartdns 的 server 默认「既进默认组、又进指定组」，只有显式
# 加 -exclude-default-group 才会被踢出默认组。所以这里写 Cn/Out 分组不会造成
# 「分组没人引用 → 上游全不参与解析 → 整机没 DNS」这种坑，两组都会正常出结果。
SD_DNS_IP_CN="223.5.5.5 223.6.6.6 119.29.29.29 180.76.76.76 101.226.4.6 218.30.118.6 123.125.81.6 140.207.198.6 1.2.4.8"
SD_DNS_IP_OUT="8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1"
SD_DNS_IPS="$SD_DNS_IP_CN $SD_DNS_IP_OUT"

# ---- 必备组件（v.180.85）：lxc / smartdns ----
# 演进：v.180.84 把三者（lxc/smartdns/dockerd）塞进 NETBASE 里「缺就装、装不上判 hard」。
# 真机上这是错的 —— 装机那一刻网络常常还没通（上游没起、拨号没完成），在这个位置 apk/opkg
# 必然失败，一失败就 hard 终止，后面的容器流程一步都跑不到，连「等网络好了再装」都没机会。
# 【v.180.99】脚本不再联网装包：
#   · lxc / smartdns 由固件内置（构建期 PACKAGES 装进 /rom），装包这件事整个交给构建期；
#   · pkg_base 退化为「必备组件在位验证」；
#   · NETBASE.smartdns 照旧：已装就配对配置，缺包就放行（此时 pkg_base 已拦在前）。
# docker 不再必选：路由上跑不跑 docker 是用户的选择，缺 dockerd 时 docker_fw 自己豁免。
# 【v.180.103】整条链按五阶段归位（用户口径）：
#   Ⅰ 配置网桥 / 网络接口 / 防火墙   —— NETBASE 前置 10 节点（br_lan_ports…docker_fw）
#   Ⅱ 查 lxc + smartdns，缺则从 /rom 装回 —— pkg_base（+ lxc_auto 紧随其后）
#   Ⅲ smartdns 配置                   —— NETBASE.smartdns
#   Ⅳ crowdsec 配置与安装             —— INSTALL / PREP / CAPIBLOCK / BOOT / LOGCONF / LAPI / BOUNCERVERIFY
#   Ⅴ 网络连通检测（到达 crowdsec）+ enroll —— DEPS / SMARTCHK / ENROLL
#   联网只出现在 Ⅴ：Ⅴ 之前一律离线，包只在 /rom 与运行时文件系统之间搬。
# 【v.180.102 → v.180.157】pkg_base 现在只管 lxc 五件套。
#   · v.180.102 曾把阀门扩到「lxc + smartdns」，v.180.157 又把 smartdns 整坨
#     （包 / 规则文件 / uci / 界面）搬出本脚本，所以这里只剩 lxc 这一半；
#     smartdns 的去处在 pkg-restore-smartdns.sh 的文件头，判在探针的 _up_n（上游条数）；
#   · 判据是「命令/文件真能用」而不是包名：lxc 看五件套 + 一次 lxc-start --version 冒烟；
#   · 缺了先走 /rom 包级自愈（lxc→pkg-restore.sh --lxc），自愈后仍缺才 hard exit 1。
_LXC_MISSING=""
_PKG_MISSING=""

# ---- 只读基座（/rom）文件级自愈（v.180.101）----
# 前提：固件把 lxc / smartdns 编进 PACKAGES，于是 /rom 里有二进制，
#       还留着 /rom/usr/lib/opkg/info/*.list / *.control 这套元数据。
# 语义：opkg remove 并不会删掉 /rom 里的原件，只在 overlay 层写一个 whiteout 把上层遮住。
#       所以「恢复」= 按清单把 /rom 的原件拷回运行时路径，不联网、不装包。
# 边界：不修 opkg 数据库（opkg list-installed 依旧看不到它），也不覆盖 conffiles
#        （/etc/config/* 这类用户配置一律跳过；smartdns 的配置由
#         pkg-restore-smartdns.sh --config 重写，不在本脚本里）。
ROMDIR="${ROMDIR:-/rom}"
# PKGROOT 只给夹具用：生产环境为空串，写的仍是真实路径 /usr/...
PKGROOT="${PKGROOT:-}"

# ---- v.180.127：固件自带离线包源 /root/pkg-cache ----
# build 时把关键包和它们的依赖闭包收进固件，并生成 Packages 索引。
# 恢复时只走 opkg install / apk add，不从 /rom 拷文件（v.180.149 起彻底去掉）：
#   · opkg 记账正确 —— opkg list-installed 和 LuCI 软件包页面都看得见；
#   · conffiles 由包管理器恢复 —— 正是 v.180.124 那次 smartdns 事故的根因
#     （拷文件那套对 conffiles 一律 continue，缺了永远补不上）。
# 装不上就明确报错，不再拷文件兜底：拷回来的包记不上账，是能跑但半残。
# v.180.150 起 bootstrap 里已无任何文件恢复路径，连 bouncer 也走本地包安装。
# 【v.180.198】本仓库只编 25.12，包管理器就是 apk —— 写死，不再运行时判断。
# 24.10 那套 opkg（.ipk / Packages.gz / customfeeds.conf）完整地活在自己的仓库里，
# 两个仓库各管各的（用户 2026-10-31 定）。原来的 _PKG_MGR + case 分流在 25.12 上
# 恒走 apk，opkg 那一路永远不可达 —— 留着只让人多读一层，判断等于没判断。
_PKG_DEF_OV=/root/apk-cache
_PKG_DEF_RO=/rom/root/apk-cache
_PKG_IDX=packages.adb
_PKG_EXT=apk

PKG_CACHE="${PKG_CACHE:-$_PKG_DEF_OV}"
# 【v.180.128】只读基座副本，解析时优先于 overlay。
# 构建时 ipk 收在 files/root/pkg-cache/，铺进镜像后就在 squashfs 里，
# 刷机后是 /rom/root/pkg-cache。而 /root/pkg-cache 走的是 overlay 合并视图：
#   一次 `rm -rf /root/pkg-cache` 会在 overlay 写一个 whiteout，
#   从此该路径永久读不到 —— 可 squashfs 里那份一个字节都没少。
# 这正是「备份包明明在 /rom 里，却装不回来」的成因，所以顺序固定为 /rom 优先：
#   · 删不掉：whiteout 只遮 overlay 路径，遮不住 /rom 挂载点本身；
#   · 不占 overlay：2G 分区里这几百兆很贵，包里不该再存一份；
#   · 同版：不会出现「overlay 里是旧固件留下的旧 ipk」这种跨版本混装。
PKG_CACHE_RO="${PKG_CACHE_RO:-$_PKG_DEF_RO}"
_PKG_CACHE_ACT=""

# 解析实际可用的包库目录到 _PKG_CACHE_ACT；两处都不可用返回 1。
# 判定用 Packages.gz 而不是目录存在：空目录（被清过）照样不可用；
# 只有裸 Packages 也不行 —— opkg 的 file:// 源只认 .gz（24.10.6 真机实证：
# copy_file: ///rom/root/pkg-cache/Packages.gz: No such file or directory）。
_rom_restore_lxc() {
    # 【v.180.146】lxc 全家桶扫描搬到 pkg-restore.sh --lxc，这里只做委托。
    # 【v.180.159】删掉内置的第二份枚举：它和 pkg-restore.sh 的 _pr_lxc 是同一套逻辑
    #   两处实现（都在扫 /usr/lib/opkg/info/lxc-*.list），加一处漏一处；而且在 apk
    #   固件上那段扫描恒为空，等于一段永远不会生效的兜底。判据只留 pkg-restore.sh 一处
    #   （那边已改成 opkg 清单 + apk 包库双来源）。pkg-restore.sh 与本脚本同目录出厂，
    #   缺它就说明固件不完整，直接判失败。
    if [ -x "$SROOT/usr/sbin/pkg-restore.sh" ]; then
        "$SROOT/usr/sbin/pkg-restore.sh" --lxc && return 0
        return 1
    fi
    log "[PKG] 缺少 $SROOT/usr/sbin/pkg-restore.sh，无法恢复 lxc 全家桶"
    return 1
}


# 【v.180.153】引导开头的前置检查：应用在不在 → 容器文件正不正常。
# 为什么不放探针：探针每 60 秒一轮，做应用/文件检查太重；它已有 last_pull 这根权威判据 ——
# 容器拉不动自然会在这里暴露。本函数由每次引导开头付一次，判据全是 O(1)
# （command -v / 文件可执行 / grep），只有真缺了才走包级装回。
# 容器文件只判不建：建归 rootfs / ct_config 两个节点，这里抢着建会把 _recovering 提前置位，
# 让后面的恢复记账错位 —— 那也是 v.180.149 起「不拷文件、只装包」这套口径的边界。
verify_svc_bind() {
    _wn=$(_zone_lan_network) || { log "[服务] 无 name=lan 的 zone，本轮不校验管理服务绑定"; return 0; }
    # 【2026-11-14 修】dropbear 的 Interface 只接受**单个**接口名。
    # lan zone 纳入 lan6 之后，_zone_lan_network 返回的是「lan lan6」，
    # 整串塞进去 dropbear 会报：
    #   Option 'Interface' should specify SINGLE interface but instead it lists interfaces: lan lan6
    # 取第一个（lan）即可 —— dropbear 只需要绑 br-lan 这个 L3 设备，lan6 与它同设备。
    _wn1=$(printf '%s' "$_wn" | awk '{print $1}')
    [ "$(run uci -q get dropbear.@dropbear[0].Interface 2>/dev/null)" = "$_wn1" ] || return 1
    return 0
}

# docker 防火墙验证：zone（ACCEPT + 172.16.0.0/12）+ docker↔lan 双向 forwarding
# 【v.180.81】wan zone 已从固件 /etc/config/firewall 整段删除，docker2wan 随之移除：
#   规则 dest 指向不存在的 zone 会让 fw4 整表加载失败（firewall/network reload 卡死）
# 无 dockerd → 不涉及，跳过
verify_docker_fw() {
    # 【2026-10-31.0256】dockerd 默认必装，写死不探测（用户 2026-10-31 定）。
    # 【v.108.37】段类型也要验：build 里 `uci set firewall.docker=zone`，
    # verify 原来只查 name/input/output/forward/subnet。段类型被写坏（例如变成 rule 段）
    # 时这些 option 一样在，fw4 却根本不把它当 zone —— docker 网段的转发策略全失效。
    [ "$(run uci -q get firewall.docker 2>/dev/null)" = "zone" ] || return 1
    [ "$(run uci -q get firewall.docker.name 2>/dev/null)" = "docker" ] || return 1
    [ "$(run uci -q get firewall.docker.input 2>/dev/null)" = "ACCEPT" ] || return 1
    [ "$(run uci -q get firewall.docker.output 2>/dev/null)" = "ACCEPT" ] || return 1
    [ "$(run uci -q get firewall.docker.forward 2>/dev/null)" = "ACCEPT" ] || return 1
    run uci -q get firewall.docker.subnet 2>/dev/null | grep -qx '172.16.0.0/12' || return 1
    [ "$(run uci -q get firewall.docker2lan.src 2>/dev/null)" = "docker" ] || return 1
    [ "$(run uci -q get firewall.docker2lan.dest 2>/dev/null)" = "lan" ] || return 1
    [ "$(run uci -q get firewall.docker2lan.target 2>/dev/null)" = "ACCEPT" ] || return 1
    [ "$(run uci -q get firewall.docker2lan.proto 2>/dev/null)" = "all" ] || return 1
    [ "$(run uci -q get firewall.lan2docker.src 2>/dev/null)" = "lan" ] || return 1
    [ "$(run uci -q get firewall.lan2docker.dest 2>/dev/null)" = "docker" ] || return 1
    # 【v.108.48】target / proto 原来没验：build 会写 ACCEPT，但被改成 REJECT
    # 或者丢掉 proto 时 verify 仍判就绪，规则实际是坏的却不重建。
    [ "$(run uci -q get firewall.lan2docker.target 2>/dev/null)" = "ACCEPT" ] || return 1
    [ "$(run uci -q get firewall.lan2docker.proto 2>/dev/null)" = "all" ] || return 1
    # 【2026-11-15 加】docker2wan 必须不存在（v.180.81 因 wan zone 已删而移除）。
    # build 里有 delete，但 verify 没判：被 LuCI 或手工加回来时没人发现，
    # 而 dest 指向不存在的 zone 会让 fw4 整表加载失败（firewall/network reload 卡死）。
    [ -z "$(run uci -q get firewall.docker2wan 2>/dev/null)" ] || return 1
    return 0
}

# 管理服务绑定 builder（v.95）：把 dropbear 的监听面钉到 LAN 网络，
# 避免 SSH 无差别监听所有口（尤其不能暴露到 WAN）。无 lan zone 则无从推导，跳过。
# 【v.108.40】ttyd 不再处理（本机不用网页终端）。
build_svc_bind() {
    _wn=$(_zone_lan_network) || { log "[服务] 无 name=lan 的 zone，跳过管理服务绑定"; return 0; }
    # 【2026-11-14 修】只取第一个网络名。原因见 verify_svc_bind 的注释：
    # lan zone 纳入 lan6 后 _zone_lan_network 返回「lan lan6」，dropbear 不接受多接口。
    _wn1=$(printf '%s' "$_wn" | awk '{print $1}')
    run uci -q set dropbear.@dropbear[0].Interface="$_wn1"
    run uci -q commit dropbear 2>/dev/null
    run /etc/init.d/dropbear reload >/dev/null 2>&1 || true
    log "[服务] dropbear 绑定 $_wn1（lan zone 里有：$_wn，只绑第一个）"
    return 0
}

# docker 防火墙 builder（v.95）：没装 dockerd 就什么都不做；
# 装了则补 docker zone（ACCEPT + 172.16.0.0/12）与两条 forwarding（wan zone 已删）。
build_docker_fw() {
    # 【2026-10-31.0256】dockerd 默认必装，写死不探测（用户 2026-10-31 定）。
    if ! run uci -q get firewall.docker >/dev/null 2>&1; then
        run uci -q set firewall.docker=zone >/dev/null 2>&1
    fi
    run uci -q set firewall.docker.name=docker
    run uci -q set firewall.docker.input=ACCEPT
    run uci -q set firewall.docker.output=ACCEPT
    run uci -q set firewall.docker.forward=ACCEPT
    run uci -q delete firewall.docker.subnet 2>/dev/null
    run uci -q add_list firewall.docker.subnet=172.16.0.0/12
    _fw_rule_d() {
        _frd="$1"; _frs="$2"; _frdst="$3"
        run uci -q get "firewall.$_frd" >/dev/null 2>&1 || uci -q set "firewall.$_frd=rule"
        run uci -q set "firewall.$_frd.src=$_frs"
        run uci -q set "firewall.$_frd.dest=$_frdst"
        run uci -q set "firewall.$_frd.target=ACCEPT"
        # 【v.108.48】同 _fw_rule：不写 proto 就被 fw4 默认成 tcpudp，ICMP 漏掉。
        run uci -q set "firewall.$_frd.proto=all"
    }
    _fw_rule_d docker2lan docker lan
    _fw_rule_d lan2docker lan    docker
    # 【v.180.81】wan zone 已整段删除，docker2wan 不能再写：dest 指向不存在的 zone
    # 会让 fw4 整表加载失败（firewall/network reload 卡住）。残留的一并清掉。
    run uci -q delete firewall.docker2wan 2>/dev/null
    log "[docker] 已写入 docker zone 与 2 条 forwarding（docker2wan 已清除）"
    return 0
}

# ============================================================================
# v.95：PREP 网络/防火墙节点由「只验不写」改为「验证 + 修改」
#   改完 → uci commit → 按组 reload 才真正生效（commit 只落盘，reload 才生效）
#   分组 reload：network → /etc/init.d/network reload
#               dhcp    → /etc/init.d/dnsmasq restart
#               firewall→ /etc/init.d/firewall reload（fw4 重建 nft 表）
#   不设回滚：改完 verify 仍不过 → ensure 判 hard，引导终止（按既定策略）
#   但加一道「不自杀」保护：改 br-lan / lan 之前先确认改完自己还能连上，
#   确认不了就不改、直接 hard —— 旁路由上把网桥改错等于失联。
# ============================================================================

# 改前「不自杀」预检：本次要动的字段若涉及管理面（br-lan / lan 地址），
# 必须能证明改完仍可达。证明不了就放弃写入，交给 hard 终止而非断网。
_net_write_guard() {
    _nwg_what="$1"
    _nwg_remote="${SSH_CONNECTION%% *}"
    if [ -n "$_nwg_remote" ]; then
        _nwg_ip="$(_lan_ip)"
        case "$_nwg_remote" in
            "$(echo "$_nwg_ip" | awk -F. '{print $1"."$2"."$3}')."*)
                log "[保护] 检测到 SSH 来自 LAN 网段（$_nwg_remote），改写 $_nwg_what 后本会话可能失联"
                ;;
            *)
                log "[保护] SSH 来自非 LAN 网段（$_nwg_remote），改写 $_nwg_what 影响不到本会话"
                ;;
        esac
    fi
    return 0
}

# ---- 旁路由网络基线 builder（v.78-bp 同源；v.95 起真实写入）----

# 桥接口 builder：br-lan 桥设备 + lan 指向它 + ports = 当前枚举物理口；清掉残留 cfg030f15
build_br_lan_ports() {
    _vp=$(_phys_ports)
    [ -n "$_vp" ] || { log "[BR_LAN] 未枚举到物理网口（驱动未就绪？），不敢建空桥，放弃写入"; return 1; }
    _net_write_guard "br-lan 桥与端口"

    # 段类型必须先声明成 device。只写 .type/.name 而不声明段类型时，uci 会把一个
    # 不存在的段建成 `config br_lan 'br_lan'`；netifd 只认 config device / interface，
    # 遇到别的类型直接忽略该段。表现：运行中的桥还在（内核里没拆），一重启 br-lan
    # 就没了。network.lxc 那边写了 =interface，这里此前漏了这一行。
    run uci -q set network.br_lan='device'

    # 清掉除 br_lan 之外、name 也是 br-lan 的 device 段（默认 network 的匿名段、
    # LuCI 重建留下的 cfg0xxxxx），它们会和 br_lan 抢同一批物理口。
    # 按 name 找，不赌具体段名。
    for _ds in $(run uci show network 2>/dev/null | grep -E '=device$' | cut -d. -f2 | cut -d= -f1); do
        [ "$_ds" = "br_lan" ] && continue
        [ "$(run uci -q get "network.$_ds.name" 2>/dev/null)" = "br-lan" ] || continue
        run uci -q delete "network.$_ds" 2>/dev/null
        log "[BR_LAN] 已清除重复的 br-lan device 段：$_ds"
    done

    run uci -q set network.br_lan.type='bridge'
    run uci -q set network.br_lan.name='br-lan'
    run uci -q delete network.br_lan.ports 2>/dev/null
    for _p in $_vp; do
        run uci -q add_list network.br_lan.ports="$_p"
    done
    run uci -q set network.lan.device='br-lan'
    log "[BR_LAN] 已写入 br-lan 桥，ports=$_vp"
    return 0
}

# LAN 静态地址 builder：按 _lan_static_conf 推导值写 proto/device/ipaddr/netmask/gateway/dns
build_lan_static() {
    # 同上：拆成位置参数再用，这个 shell 里没有别的取法。
    # shellcheck disable=SC2046
    set -- $(_lan_static_conf)
    # 先验再写：这四个值不是用户当场敲的，是编译期文件里读出来的。
    # 文件被写坏（空行、多空格、粘了 Windows 换行、手抖写成 10.0.0.1000）
    if ! _lan_conf_valid "$1" "$2" "$3" "$4"; then
        log "[LAN] 期望值不合法：IP=[$1] 掩码=[$2] 网关=[$3] DNS=[$4]"
        log "[LAN] 请检查 /etc/config/custom_router_{ip,netmask,gateway,dns}.txt 首行"
        log "[LAN] 为避免把 LAN 写成非法地址导致失联，放弃写入，hard 终止"
        return 1
    fi
    _net_write_guard "lan 静态地址"
    # ===== lan（IPv4 static）与 lan6（IPv6 dhcpv6）一起写，一次 commit =====
    # OpenWrt 一个 interface 只能有一个 proto，所以 IPv4/IPv6 必须分成两个段；
    # 但它们是同一个物理口（lan6 用 device='@lan' 跟随），生命周期完全一致，
    # 因此配置动作放在同一处、提交一次，避免「lan 提交了、lan6 还在内存里」这种半截状态。
    #
    # ---- lan：IPv4 静态 ----
    run uci -q set network.lan.proto='static'
    run uci -q set network.lan.device='br-lan'
    run uci -q set network.lan.ipaddr="$1"
    run uci -q set network.lan.netmask="$2"
    run uci -q set network.lan.gateway="$3"
    run uci -q delete network.lan.dns 2>/dev/null
    run uci -q add_list network.lan.dns="$4"
    # ---- lan6：IPv6 客户端（跟随 lan 的 device）----
    # 幂等：已存在就整段覆盖成目标值（不用 if 判断），配置漂移也能一次纠正。
    run uci -q set network.lan6=interface
    run uci -q set network.lan6.proto='dhcpv6'
    run uci -q set network.lan6.device='@lan'
    run uci -q set network.lan6.reqaddress='try'
    run uci -q set network.lan6.reqprefix='auto'
    run uci -q set network.lan6.norelease='1'
    run uci -q set network.lan6.sendclientid='auto'
    run uci -q set network.lan6.peerdns='0'
    # ---- lan：IPv6 前缀分配（用户 2026-11-14 定：长度 64）----
    # ip6assign='64'：从 lan6 向光猫要到的 PD 池里切一段 /64 给 lan
    # 【2026-11-14 用户定】不写 ip6hint：让 netifd 自己挑空位。
    # 原因：hint 是「从多段里选第几段」用的，本机只有一段 /64 时它不参与决策；
    # 而一旦运营商改发 /56，hint=0 会指向 8c00::/64 —— 那正是光猫自己在用的段
    # （lan6 的 SLAAC 地址就落在 8c00），会撞段。不写则 netifd 自动避开已占用的。
    # 为什么必须写在 lan 而不是 lan6：见 verify_lan_static 里的注释——
    # 写在 lan6 上 netifd 会报 subprefix 分配失败，且 odhcpd 会拿错前缀。
    run uci -q set network.lan.ip6assign='64'
    # 【2026-11-15 加】显式 eui64：地址 = ULA 前缀 + MAC，永久有效，
    # 也是 RDNSS 要通告的那个地址（不设时 netifd 给 ::1，会反复 deprecated）。
    run uci -q set network.lan.ip6ifaceid='eui64'
    # 【2026-11-11 用户方案】写完当场 commit：让后面的 snat 节点读 network.lan.ipaddr
    # 时拿到的是落盘后的值，而不是只存在于 /tmp/.uci delta 里的内存态。
    # 真正的 reload 仍由 build_NETBASE 末尾的 flush_uci 统一做（那里还会重接容器 veth），
    # 这里只保证「配置已定稿」，不碰网络。
    if ! run uci -q commit network 2>/dev/null; then
        log "[LAN] commit network 失败（lan/lan6 只在内存里，重启即丢）"
        return 1
    fi
    log "[LAN] 已提交：lan 静态地址 $1/$2 网关 $3 DNS $4 + lan6（dhcpv6, peerdns=0）"
    return 0
}

# DHCP builder：删 ignore（不是置 1）；IPv4 关池（dhcpv4=disabled）；
# IPv6 自己发 RA（ra=server / pref=high / 30-60s / RDNSS=本机 link-local）；
# 所有 dnsmasq 段删 authoritative。
build_dhcp_ignore() {
    # 【v.180.94】缺 dhcp.lan 段时**不建**：旁路由的 LAN 本来就不跑 DHCP，
    # 缺段是「已关闭」，不是「待配置」。旧行为是 add 一个段再 rename 成 lan 并置
    # ignore=1 —— 段被搬回来了，虽然不发地址，但等于替用户重开了一个 DHCP 池。
    # 这里改用 uci show 判段是否存在（uci get 两段式路径在精简 uci 上会误判）。
    _bdi_has=0
    if run uci show dhcp 2>/dev/null | grep -q '^dhcp\.lan=dhcp$'; then
        _bdi_has=1
    fi
    # 【2026-11-14 改】段不存在就建，不再跳过。
    # 原逻辑（v.180.94）是「缺段 = 用户主动删了 = 已关闭，别替用户建回来」，
    # 那套只适用于「旁路由完全不管 DHCP」。现在要发 RA，而 RA 配置就存在
    # dhcp.lan 段里，缺段等于永远开不了 RA，所以改成先建再配。
    if [ "$_bdi_has" != "1" ]; then
        run uci set dhcp.lan=dhcp
        log "[DHCP] 无 dhcp.lan 段，已新建"
    fi
    # 【2026-11-15 用户定】段内四项改为无条件写死，不再只在新建时写。
    # 原来只在建段时 set：段已存在但被手改（例如 interface 改成 lan6）时 build 不修，
    # 而 verify 一旦判这几项就会「判不过 → build 不修 → 永远判不过」死循环。
    # 写成无条件后，check/fix 两侧口径一致。
    run uci -q set dhcp.lan.interface='lan'
    run uci -q set dhcp.lan.start='231'
    run uci -q set dhcp.lan.limit='20'
    run uci -q set dhcp.lan.leasetime='12h'
    # 【2026-11-14 改】旁路由不再「关 RA」，改成「自己发 RA 抢默认路由和 DNS」
    # 原设计是把 DHCP/RA 全部让给光猫（ignore=1 + 删 ra/dhcpv6/ndp/ra_management）。
    # 现在改成：IPv4 DHCP 仍然不发（dhcpv4=disabled），但 IPv6 RA 由本机发，
    # 让设备的 IPv6 默认路由和 DNS 都指向本机（smartdns），光猫只做兜底。
    # 为什么必须自己发 RA：
    #   1) ra_preference=high  → Windows 收到 metric 16，光猫 medium 是 256
    #   2) interval=30-60s     → 比光猫（200-600s）发得勤；Windows 只保留最后到的 RDNSS
    # 说明：ra_management / ra_flags 故意不写死，交给 odhcpd 默认值和 LuCI 控制。
    # 副作用是 odhcpd 默认 other-config 会让 O=1，设备会多发一次无用的
    # DHCPv6 Information-request（超时后回退到 RDNSS），不影响功能。
    run uci -q delete dhcp.lan.ignore
    run uci -q set dhcp.lan.dhcpv4='disabled'
    run uci -q set dhcp.lan.ra='server'
    # 【2026-11-14 用户定】不写 dhcpv6：地址由 SLAAC 下发，不需要有状态 DHCPv6。
    # 实测（192.168.1.201）：dhcpv6 关着，Windows 一样从 RA 拿到 8c01 段地址
    # （PrefixOrigin=RouterAdvertisement）。开着反而有风险——一旦 ra_flags 带
    # managed-config，它会真去分配地址，可能又抢到光猫的 8c00 段。
    # 固件 /rom/etc/uci-defaults/15_odhcpd 本来就写 disabled，保持默认即可。
    run uci -q set dhcp.lan.ra_preference='high'
    run uci -q set dhcp.lan.dns_service='1'
    # 【2026-11-15 定稿】RDNSS 只发一条：ULA 地址（EUI-64 形式）。
    # 为什么不用 link-local：实测 Windows 对 fe80:: 做 DNS 服务器时会超时
    #   （本机 nslookup 通、Windows 侧 DNS request timed out）。
    # 为什么用 ULA：LAB 地址由 ula_prefix + ip6assign + ip6ifaceid=eui64 产生，
    #   valid_lft forever（实测），不随运营商 PD 变，Windows/Linux 都能用。
    # 为什么是 EUI-64 不是 ::1：ip6ifaceid 不设时 netifd 给的是 ::1，实测反复
    #   变 deprecated；显式写 eui64 后地址固定、永久有效。
    # 动态取而不写死：换网卡 MAC 变，地址跟着变，脚本自己算得出来。
    _bdi_ula=$(run ip -6 addr show br-lan 2>/dev/null \
               | grep 'inet6 fd' | awk '{print $2}' | cut -d/ -f1 | head -n1)
    if [ -n "$_bdi_ula" ]; then
        run uci -q delete dhcp.lan.dns
        run uci -q add_list dhcp.lan.dns="$_bdi_ula"
    else
        log "[DHCP] 取不到 br-lan 的 ULA 地址，跳过 DNS 通告配置"
    fi
    run uci -q set dhcp.lan.ra_mininterval='30'
    run uci -q set dhcp.lan.ra_maxinterval='60'
    # 所有 dnsmasq 段删掉 authoritative：旁路由不是权威 DHCP，避免抢答
    for _dm in $(run uci show dhcp 2>/dev/null | grep -E '=dnsmasq$' | cut -d. -f2 | cut -d= -f1); do
        run uci -q delete "dhcp.$_dm.authoritative" 2>/dev/null
    done
    # 【v.180.97】53 不在这里让。曾经并到这一步试过，但 dhcp_ignore 排在 DEPS 之前：
    # 那一刻 smartdns 可能还没装，让出 53 等于本机立刻没有 DNS，_net_ready 第三层
    # 的 nslookup 必然失败，DEPS 就永远装不上 smartdns —— 首轮直接死锁。
    # 所以让位跟着 smartdns 的接管结果走（port=53 + auto_set_dnsmasq=1 时，
    # 由 smartdns 自己的 init 让 dnsmasq 退出 53，见 pkg-restore-smartdns.sh 文件头）：
    # 能接管了才放手，接管不了就继续让 dnsmasq 顶着。
    log "[DHCP] IPv6 RA 已接管：ra=server pref=high dns_service=1 interval=30-60s（IPv4 DHCP 仍关闭）"
    return 0
}







# ---- pkg_base：必备组件在位验证 = Ⅱ 阶段（v.180.103 起排在网络基线之后）----
# 位置口径：Ⅰ 配网桥/接口/防火墙 → Ⅱ 查 lxc（缺则从 /rom 恢复）→ Ⅲ crowdsec 构建 → Ⅳ enroll。
#   · 前面：网络配置一步都不需要 lxc，把它排在链首会让「先配网」这条前提不成立；
#   · 后面：lxc_auto 要 lxc-auto 的服务脚本，得等本节点恢复完。
# 包的来源只有一处：固件内置（构建期 PACKAGES 装进 /rom）。脚本不联网装包。
# 判据是「命令/文件真能用」而不是「包名在列表里」：liblxc 在、lxc 壳在、applet 缺一个，
# 一样跑不起来 —— 见 _lxc_missing_deps 的五件套。
# 【v.180.157】smartdns 整套（含 luci-app-smartdns 界面）已移出 bootstrap：
# 本节点只管 lxc。smartdns 的恢复 / 配置 / 状态验证归 pkg-restore-smartdns.sh + 探针。
# 只读不写：本节点不装包、不写 uci、不碰容器。
verify_pkg_base() {
    _pkg_missing_all
}

# 缺件才动，缺什么补什么：lxc 走全家桶通配。
# 【v.180.150】改成走本地包安装：/rom 是只读、不可修改的可信层，包库里的 ipk/apk
# 就是固件原样内容，opkg/apk 装出来的结果与拷文件等价，但记账同步、依赖可解。
# 不再有「包级装不上就拷文件」这层兜底 —— 兜底只会留下能跑但半残的状态。
build_pkg_base() {
    if _pkg_missing_all; then
        log "[PKG] 必备组件齐备：lxc 五件套（start/stop/ls/info/attach）"
        return 0
    fi
    log "[PKG] 必备组件缺失：$_PKG_MISSING —— 先试只读基座 $ROMDIR"
    # lxc：applet 是各自独立的包，必须扫 lxc-*.list 全量恢复，再补 liblxc 依赖树。
    # 【v.180.164】全量记账缺（_LXC_MISSING_PKGS 非空）也走这条链：
    #   _pr_lxc 对已装包逐个 _pr_pkg 跳过，幂等，不会因为多跑一次而重装东西。
    if ! _lxc_missing_deps || [ -n "$_LXC_MISSING_PKGS" ]; then
        _rom_restore_lxc \
            || log "[PKG] 只读基座里没有 lxc 的安装清单（$ROMDIR/lib/apk/packages 与 $ROMDIR/usr/lib/opkg/info 都没扫到 lxc）"
    fi
    hash -r 2>/dev/null || true
    if _pkg_missing_all; then
        log "[PKG] 已从只读基座恢复，必备组件齐全"
        return 0
    fi
    log "[PKG] 恢复后仍缺：$_PKG_MISSING"
    log "[PKG] 固件未内置：查 shell/custom-packages.sh（24.10）/ shell/apk-custom-packages.sh（25.12）里的 CUSTOM_PACKAGES —— lxc 全家桶必须随固件进 /rom"
    return 1
}



# ---- lxc_zone：只写 zone 段 ----
# 【v.180.115】拆开：原来 zone 与 4 条转发规则共用 build_lxc_zone_fwd，任一处不符就
# 整体重写一遍。行为等价（都幂等），但日志分不出是 zone 坏了还是规则坏了，出问题只能
# 整段排查。现在两个节点各自 build，各自打日志，失败也各自停在那一小步。
# 顺序由 DEP_fwd_rules="lxc_zone" 保证，不靠函数里"顺手先建 zone"。
build_lxc_zone() {
    if [ -z "$(_zone_sec lxc)" ]; then
        run uci -q add firewall zone >/dev/null 2>&1
        _lzs=$(run uci show firewall 2>/dev/null | grep -E '=zone$' | cut -d. -f2 | cut -d= -f1 | tail -n1)
        [ -n "$_lzs" ] || { log "[FW] 无法新建 lxc zone"; return 1; }
        run uci -q rename "firewall.$_lzs"='lxczone' >/dev/null 2>&1 || _lzs='lxczone'
    else
        _lzs=$(_zone_sec lxc)
    fi
    run uci -q set "firewall.$_lzs.name=lxc"
    run uci -q set "firewall.$_lzs.network=lxc"
    run uci -q set "firewall.$_lzs.input=ACCEPT"
    run uci -q set "firewall.$_lzs.output=ACCEPT"
    run uci -q set "firewall.$_lzs.forward=ACCEPT"
    log "[FW] 已写入 lxc zone"
    return 0
}

# ---- fwd_rules：只写四条转发规则（lxc2lan / lxc2docker / lxc2vpn / lan2lxc）----
build_fwd_rules() {
    _fw_rule() {
        _fr_sec="$1"; _fr_src="$2"; _fr_dst="$3"
        if ! run uci -q get "firewall.$_fr_sec" >/dev/null 2>&1; then
            run uci -q set "firewall.$_fr_sec=rule"
        fi
        run uci -q set "firewall.$_fr_sec.src=$_fr_src"
        run uci -q set "firewall.$_fr_sec.dest=$_fr_dst"
        run uci -q set "firewall.$_fr_sec.target=ACCEPT"
        # 【v.108.48】必须显式写 proto=all，否则 ICMP 被漏掉。
        # fw4 对 config rule 不写 proto 时默认按 tcpudp 处理，编译出来是：
        #     meta l4proto tcp ... jump accept_to_lan "!fw4: lxc2lan"
        #     meta l4proto udp ... jump accept_to_lan "!fw4: lxc2lan"
        # 于是 ping（ICMP）、ESP、GRE 全落在规则之外 —— 真机现象是「规则明明在、
        # uci show 一条不少、fw4 也 reload 了，但容器就是出不去」，
        # forward_lxc 链里那两条规则的 counter 恒为 0，极易被误判成「没写入」。
        # 对比：config forwarding 段没有 proto 概念，天然放行所有协议 ——
        # 这就是为什么用户在 LuCI 里手加两条 forwarding 之后网络立刻通了。
        run uci -q set "firewall.$_fr_sec.proto=all"
    }
    _fw_rule lxc2lan    lxc lan
    _fw_rule lxc2docker lxc docker
    _fw_rule lxc2vpn    lxc vpn
    _fw_rule lan2lxc    lan lxc
    log "[FW] 已写入 4 条转发规则"
    return 0
}

# SNAT builder：从容器网段到 LAN 地址的源地址改写（容器出网生命线）
build_snat() {
    _sn=$(_snat_sec)
    if [ -z "$_sn" ]; then
        run uci -q add firewall nat >/dev/null 2>&1 || { log "[SNAT] 无法新建 nat 段"; return 1; }
        _sn=$(run uci show firewall 2>/dev/null | grep -E '=nat$' | cut -d. -f2 | cut -d= -f1 | tail -n1)
        [ -n "$_sn" ] || return 1
        run uci -q rename "firewall.$_sn"='lxcsnat' >/dev/null 2>&1 || _sn='lxcsnat'
    fi
    run uci -q set "firewall.$_sn.name=lxc-snat"
    run uci -q set "firewall.$_sn.target=SNAT"
    run uci -q set "firewall.$_sn.proto=all"
    run uci -q set "firewall.$_sn.src=lan"
    run uci -q set "firewall.$_sn.src_ip=$(_lxc_net)"
    run uci -q set "firewall.$_sn.snat_ip=$(_lan_ip)"
    log "[SNAT] 已写入 $(_lxc_net) → $(_lan_ip) 源地址改写"
    return 0
}

# LAN zone 放行：input/forward 锁定 ACCEPT
build_lan_input() {
    _lz=$(_zone_sec lan) || { log "[FW] 无 lan zone，跳过"; return 0; }
    run uci -q set "firewall.$_lz.input=ACCEPT"
    run uci -q set "firewall.$_lz.forward=ACCEPT"
    # 【2026-11-14 加】确保 lan6 在这个 zone 的 network 列表里。
    # lan6 是独立 UCI 接口（不是 lan 的别名），fw4 按接口名匹配 zone；
    # 不在列表里 → IPv6 包不属于任何 zone → 按默认策略 DROP。
    if ! run uci -q show "firewall.$_lz" 2>/dev/null | grep -q "lan6"; then
        run uci -q add_list "firewall.$_lz.network=lan6"
        log "[FW] lan zone 已纳入 lan6"
    fi
    log "[FW] lan zone input/forward 已置 ACCEPT（含 lan6）"
    return 0
}
# 旁路由网络基线入口（v.78-bp）：五对象独立预检，哪项不符只重建哪项
# 必须在 setup_bridge/setup_lxc_firewall 之前跑：SNAT 的 snat_ip 取 _lan_ip()，
# 需先确保 network.lan.ipaddr 已校准就位（否则首启会读到固件默认地址）


# docker 防火墙入口（无条件，与模式无关）：装了 dockerd 就要保证容器网络与防火墙互通


# 防火墙修复入口：六分项独立预检，哪项不符只重建哪项
# 全对 -> 不 commit 不 reload 直接跳过；只有 ip_forward 被关 -> 只 echo 1；

# 【v.108.49】末尾的 enroll 是本次补上的：ENROLL 组一直在 GROUP_SEQ 里，但
# DAG_NODES 里从来没有 enroll 这个节点（NODE_GROUP_enroll 也不存在）。而
# ensure_group / rg_restart_verify 都是「遍历 _order，按 NODE_GROUP_<节点> 筛组内节点」，
# 于是这一组永远是 0 个小步骤 —— 日志里就是这三行连着出现：
#     [DAG] 组 ENROLL 就序（0 个小步骤）
#     ---- 组 ENROLL（Console Enroll）：0 个小步骤 ----
#     [ENROLL] Console Enroll 完成（0/0）
# re_enroll / console_enroll_ok / 注册码保管（v.108.52 起为 _park_enroll_key）一次都没被调用过（死代码）。
# 真机证据（24.10，2026-10-22）：/etc/config/crowdsec_enroll_key.txt 26 字节一直在，
# 全量日志 grep 不到「已删除注册码文件」，而 cscli console status 是 not registered。
# [v.180.157] smartdns 整套（配置 / 服务 / 验证）已移出 bootstrap：
#   归 pkg-restore-smartdns.sh（--config / --repair）+ 探针负责。
#   bootstrap 只保留六件事：网络配置（含防火墙）、网桥配置、容器网络配置、
#   lxc 与 bouncer 恢复、crowdsec 容器恢复、crowdsec 与 bouncer 的本地联动配置。
#   dag_order 的组内次序仍取本行里同组节点的相对出现顺序。
verify_lxc_auto() {
    # 受 /rom 保护：缺失就是异常，不是「不适用」
    [ -x "$LXC_AUTO_INIT" ] || return 1
    [ -f "$LXC_AUTO_CFG" ] || return 1
    [ "$(run uci -q get lxc-auto.@container[0].name 2>/dev/null)" = "$LXC_NAME" ] || return 1
    [ "$(uci -q get lxc-auto.@container[0].timeout 2>/dev/null)" = "300" ] || return 1
    # 段里出现 command = 开机以 root 执行它（镜像固化的段没有这一项），出现即判不符
    run uci -q get lxc-auto.@container[0].command >/dev/null 2>&1 && return 1
    "$LXC_AUTO_INIT" enabled >/dev/null 2>&1 || return 1
    return 0
}
build_lxc_auto() {
    # ① 服务脚本被删了？先从只读基准恢复。guard 也会做这件事，但它有周期，
    #    本脚本可能先跑完一轮 —— 不依赖别人的执行顺序。
    if [ ! -x "$LXC_AUTO_INIT" ]; then
        _la_src="$LXC_AUTO_ROM$LXC_AUTO_INIT"
        if [ -f "$_la_src" ]; then
            rm -f "$LXC_AUTO_INIT" 2>/dev/null
            if cp -f "$_la_src" "$LXC_AUTO_INIT" 2>/dev/null && chmod 755 "$LXC_AUTO_INIT" 2>/dev/null; then
                log "[lxc-auto] 服务脚本曾被删除，已从只读基准恢复（$LXC_AUTO_INIT）"
            else
                log "[lxc-auto] 从只读基准恢复服务脚本失败（overlay 不可写？）"
                return 1
            fi
        else
            log "[lxc-auto] 只读基准里也没有 $LXC_AUTO_INIT —— 这台固件不带 lxc-auto 服务"
            return 1
        fi
    fi
    # ② 文件整个不在了也要能从零建：uci 对不存在的 config 只会在内存里造段，
    #    commit 没有落点就会失败。先放一个空文件当落点，再交给 _ensure_lxc_auto。
    #    【v.108.31】这一步以前不检查返回值：/etc/config 被删、只读、或被换成目录时，
    #    `: >` 悄悄失败，后面的报错只会说「写 lxc-auto 失败」，看不出根因在这里。
    if [ ! -f "$LXC_AUTO_CFG" ]; then
        _la_dir=$(dirname "$LXC_AUTO_CFG")
        if ! mkdir -p "$_la_dir" 2>/dev/null; then
            log "[lxc-auto] 落点目录不可用：$_la_dir（不存在且建不出来）"
            return 1
        fi
        # 重定向失败在 ash 里是**致命**的：` : > 坏路径` 会直接把整个 bootstrap 杀掉，
        # 日志里只留一行 "can't create ..." —— 既不是 return 1，也没有上下文。
        # 拿子 shell 把它关起来：死了只死子 shell，父进程拿得到非 0。
        if ! ( : > "$LXC_AUTO_CFG" ) 2>/dev/null; then
            log "[lxc-auto] 无法创建 $LXC_AUTO_CFG（overlay 只读，或该路径被目录/符号链接占着）"
            return 1
        fi
        log "[lxc-auto] $LXC_AUTO_CFG 不存在（或被删），已建空落点，按镜像应有的样子重建"
    fi
    _ensure_lxc_auto || return 1
    # ③ ensure() 在 build 成功后不复核（v.108.15 的教训），这里自己收口
    verify_lxc_auto
}

# 清掉历史遗留的 lxcboot 兜底（v.108.14）
#
# 背景：v107-bp 那版固件的启动链是断的（/etc/config/lxc-auto 整份注释 + 服务 disabled），
# 现场只能手工建 /etc/init.d/lxcboot + /etc/rc.d/S99lxcboot 兜底。这份兜底不在
# GUARD_FILES 里，也没有任何步骤会回收它。于是「保留配置」刷到 v.108 固件后，
# S99lxc-auto 与 S99lxcboot 会同时去启同一个容器：
#   · 后跑的那次 lxc-start 必然 already running 失败（这个本身无害）
#   · 但 lxcboot 里若还带手工 `mount -t cgroup -o none,name=systemd`，会再叠一份
#     挂载 → /sys/fs/cgroup/systemd 重复挂载，cgroup 视图错乱（现场确实叠过两条）
#   · 两个启动器谁先谁后取决于 rc.d 字典序之外的实现细节，出问题极难归因
#
# ★ 只在 lxc-auto 链路**确实就位**之后才清（调用点就在 _ensure_lxc_auto 成功分支内），
#   否则删掉兜底等于把唯一能起容器的路也砍了。
# ★ 备份后删，且**任何一步失败都只告警、不返回 1**：删不掉不该阻断开机，
#   那比留着旧兜底更糟。这里故意不给 ensure() 用的失败语义。
build_bridge() {
    _nb_ip="$BRIDGE_IP"
    _nb_mask="$(run uci -q get network.lxc.netmask 2>/dev/null)"
    [ -n "$_nb_mask" ] || _nb_mask="255.255.255.0"

    _net_write_guard "lxcbr0 网桥与地址"

    # 【v.108.35】顺序是「先 device，再 interface」：
    #   interface 里的 device 只是一个「名字引用」，被引用的设备必须先存在。
    # 原来的顺序是先写 interface、再 ip link add，于是 netifd 读到的 interface
    # 指向一个还没声明的名字 → 按外部设备处理 → 有就用、没有不建 → 重启后网桥凭空消失。

    # ① uci：device 段。必须让 netifd 知道「lxcbr0 是我要的网桥」，
    #    它才会在 network reload 时把这个 bridge 建出来，重启后也自动存在。
    #    bridge_empty='1' 是必须的：netifd 对「一个端口都没有的 bridge」默认
    #    不认为它是 present（device_set_present false），于是根本不创建。
    #    lxcbr0 恰恰是空网桥 —— 端口要等容器启动时 veth 才接进来。
    if [ "$(run uci -q get network.lxcbr0 2>/dev/null)" != "device" ] \
       || [ "$(run uci -q get network.lxcbr0.type 2>/dev/null)" != "bridge" ] \
       || [ "$(run uci -q get network.lxcbr0.name 2>/dev/null)" != "lxcbr0" ] \
       || [ "$(run uci -q get network.lxcbr0.bridge_empty 2>/dev/null)" != "1" ]; then
        run uci -q set network.lxcbr0='device'
        run uci -q set network.lxcbr0.name='lxcbr0'
        run uci -q set network.lxcbr0.type='bridge'
        run uci -q set network.lxcbr0.bridge_empty='1'
        log "[网桥] 已声明 network.lxcbr0（device / type=bridge / bridge_empty=1），netifd 自己建，重启不再靠脚本"
    fi

    # ② 内核：设备不存在则补建（reload 之前就要能用，所以不干等 netifd）。
    #    补建失败必须说出来 —— 以前 `ip link add ... 2>/dev/null` 不看返回值，
    #    建不出来也记「已补建」，下一轮 verify 才发现，中间容器起不来。
    if ! run ip link show lxcbr0 >/dev/null 2>&1; then
        if run ip link add lxcbr0 type bridge 2>/dev/null; then
            log "[网桥] 内核中无 lxcbr0，已补建"
        elif run ip link show lxcbr0 >/dev/null 2>&1; then
            log "[网桥] lxcbr0 已由 netifd 建出（与本次补建并发，忽略）"
        else
            log "[网桥] 无法创建 lxcbr0（ip link add 失败），网桥不存在，容器网络无从谈起"
            return 1
        fi
    fi
    run ip link set lxcbr0 up 2>/dev/null || log "[网桥] lxcbr0 up 失败（设备在但没起来）"

    # ③ uci：interface 段。设备已经在，这里只负责引用 + 地址
    #    （该段缺失时 ping 判据也过不去）。
    if [ "$(run uci -q get network.lxc.proto 2>/dev/null)" != "static" ] \
       || [ "$(run uci -q get network.lxc.device 2>/dev/null)" != "lxcbr0" ] \
       || [ "$(run uci -q get network.lxc.ipaddr 2>/dev/null)" != "$_nb_ip" ]; then
        run uci -q set network.lxc='interface'
        run uci -q set network.lxc.proto='static'
        run uci -q set network.lxc.device='lxcbr0'
        run uci -q set network.lxc.ipaddr="$_nb_ip"
        run uci -q set network.lxc.netmask="$_nb_mask"
        log "[网桥] 已写入 network.lxc（$_nb_ip/$_nb_mask 设备 lxcbr0）"
    fi

    # ④ 内核：地址校正（已正确就不动，避免每轮重启都抖一下）
    #    注意 ip addr 要的是前缀长度，不是点分掩码，所以这里把 255.x.x.x 折成位数。
    _nb_pfx=$(printf '%s\n' "$_nb_mask" | awk -F. '{n=0; for(i=1;i<=4;i++){v=$i+0; while(v>0){n+=v%2; v=int(v/2)}}; print n}')
    [ -n "$_nb_pfx" ] || _nb_pfx=24
    _nb_cur=$(ip -4 addr show lxcbr0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n1)
    if [ "$_nb_cur" != "$_nb_ip" ]; then
        [ -n "$_nb_cur" ] && run ip addr del "$_nb_cur/$_nb_pfx" dev lxcbr0 2>/dev/null
        if ! run ip addr add "$_nb_ip/$_nb_pfx" dev lxcbr0 2>/dev/null; then
            # add 失败可能是「地址其实已经在」（并发/重复执行），复核一次再定论
            _nb_chk=$(ip -4 addr show lxcbr0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -n1)
            if [ "$_nb_chk" != "$_nb_ip" ]; then
                log "[网桥] lxcbr0 地址写入失败（当前 ${_nb_chk:-无地址}，期望 $_nb_ip）"
                return 1
            fi
        fi
        log "[网桥] lxcbr0 地址已校正为 $_nb_ip/$_nb_pfx"
    fi

    # ⑥ 端口在位（首台真机 2026-10-22）：网桥一旦被重建，端口全掉、容器与宿主断链，
    #    而 uci 与地址全都"看着正常"。这里补一次重接，与 verify_bridge 的端口判据对称：
    #    verify 判不就绪 → ensure 调本函数 → 本函数把线接回去 → 下一轮 verify 通过。
    _reattach_ct_veth || true

    # ⑤ 脏标记由 ensure() 统一定位（_bs_flag_set "_dirty_$o" B），builder 里不必重复写。
    return 0
}


# ip_forward 节点 build（原 setup_lxc_firewall 尾部行为）
# 【v.97 修正】原来写完就无条件 log「已置 1」——/proc 只读、容器化宿主、权限不足
# 时写入静默失败，日志却报成功，ensure 以为修好了，实际 SNAT/转发全废。
# 现在写完必须回读确认，读不回来就判失败（让 ensure 走 hard 终止，别假装成功）。
build_ip_forward() {
    echo 1 >/proc/sys/net/ipv4/ip_forward 2>/dev/null
    if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ]; then
        _ipfwd_touched=1     # 记下"本轮是本脚本改的"，退出时据此决定要不要还原
        _ipfwd_mark          # 落哨兵：让下次进程能认出"这个 1 是脚本置的"
        log "[防火墙] ip_forward 已置 1"
        return 0
    fi
    log "[防火墙] ip_forward 写入失败（/proc 只读或无权限），容器出网与内网互访会失效"
    return 1
}

# SNAT rule 节点 verify（v.79 纯判定）：只验 rule 本身，不夹带修复动作——
# rule 缺失/不符由 ensure 走 build_snat 重建（_dirty_snat 进 firewall 组，flush 各至多一次）；
verify_snat() {
    if verify_snat_rule; then
        log "[SNAT] 就位（src=$(_lxc_net) → $(_lan_ip)）"
        return 0
    fi
    log "[SNAT] rule 缺失/不符，待重建"
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
        log "[$MY_GROUP] 修复 $_fg_x"
        ensure "$_fg_x" || log "[$MY_GROUP] 修复 $_fg_x 未成功（留待复检）"
    done
    [ "$_fg_n" -gt 0 ] || log "[$MY_GROUP] 无需修复（本组节点全部达标）"
    # 【2026-11-11】fix.sh 路径必须在这里 commit + reload 一次。
    # build_* 大多只写 uci 内存态（uci set 落在 /tmp/.uci/ 的 delta 里），
    # commit/reload 原本只在 build_<组> 末尾的 flush_uci 里做 —— 而那条路径只有
    # main.sh --full 会走；fix.sh 逐组调 `sh <组>/step.sh --fix`，走的是本函数，
    # 修完不 commit 就等于「只在内存里修好了」：/etc/config 没动、fw4 的 nft 表没重建，
    # 重启即清空，下次开机 verify 又不过、又 build 一遍，永远修不进去。
    # 真机 2026-11-11 14:37 场景：snat 的 uci set 后 /tmp/.uci/firewall 有 delta，
    # 直到 14:39 才有别的路径把它 commit 掉，中间 LuCI 读到的还是旧值。
    # flush_uci 内部按 _dirty_<节点> 判断，没改动的组不会白 reload。
    flush_uci || log "[$MY_GROUP] flush_uci 未全部成功（改动可能只在内存里）"
    _check_group
}

# 被 source 时不执行入口（main.sh / bootstrap.sh 需要本文件的函数）
if [ "${0##*/}" = "step.sh" ] && [ "${_BS_SOURCED:-0}" != "1" ]; then
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
