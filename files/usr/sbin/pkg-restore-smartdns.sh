#!/bin/sh
# pkg-restore-smartdns.sh — smartdns 专用恢复
#
# 为什么单独一份：通用恢复只管「包在不在」，smartdns 还多两块状态，通用路径修不了。
#
#   ① /etc/smartdns/ 下的规则文件
#      address.conf / blacklist-ip.conf / custom.conf / domain-block.list /
#      domain-forwarding.list —— 它们在 conffiles 里，通用恢复按「不覆盖用户配置」
#      一律跳过。可文件真没了的时候，那条保护就退化成「永远不修」：
#      真机 2026-10-28 就是这么挂的 —— smartdns: open config file
#      '/etc/smartdns/address.conf' failed -> procd 记 crash loop -> 53 端口全空 ->
#      探针判进程不在 -> 重跑 bootstrap -> 再挂，死循环。
#      这里单独开口子，判据是「不存在才补」：存在就一律不动，哪怕被清成 0 字节。
#
#   ② LuCI 界面 luci-app-smartdns（menu.d + smartdns-call）
#      纯前端包，无二进制、无 init。只调单包恢复、不递归 —— 它的 Depends 里有
#      luci-base，递归会一路碰 rpcd / ubus / ucode 一大片基础系统，那是砸系统。
#
#   ③ uci 配置（主段 + 6 条写死上游）
#      2026-10-29 起从 bootstrap 整段搬来。bootstrap 只保留六件事：网络配置（含防火墙）、
#      网桥配置、容器网络配置、lxc 与 bouncer 恢复、crowdsec 容器恢复、
#      crowdsec 与 bouncer 的本地联动配置。smartdns 归本脚本 + 探针。
#      dnsmasq 让出 53 不在这里做：port=53 且 auto_set_dnsmasq=1 时由 smartdns
#      的 init 自己完成（见下方「不再手动让位」那段的依据）。53 只归 smartdns，
#      失败也不回滚给 dnsmasq（v.180.198，用户 2026-10-31 定）。
#      判据是「验证包在位就写」，不逐项比对配置差异 —— 上游表写死，
#      覆盖式写入。副作用：在 LuCI 里手改的上游会被下一轮冲掉（与原
#      bootstrap 的 build_smartdns_upstream 行为一致）。
#      注意：--config 直接用系统的 uci，不吃 PKGROOT，只对真机生效。
#
# 用法：
#   pkg-restore-smartdns.sh              全量：本体 + 依赖 + /etc/smartdns + 界面
#   pkg-restore-smartdns.sh --check      只判服务生效（pidof + 53 端口），0=生效
#   pkg-restore-smartdns.sh --check-pkg  只判包在不在（二进制 + init），0=在
#   pkg-restore-smartdns.sh --pkg        只装本体（含依赖树）
#   pkg-restore-smartdns.sh --conf       只补 /etc/smartdns/ 规则文件
#   pkg-restore-smartdns.sh --luci       只补界面
#   pkg-restore-smartdns.sh --config     写 uci 配置（主段 + 7 条写死上游）并 commit/重启 smartdns
#                                        （dnsmasq 让位由 smartdns 的 init 自动完成，本脚本不碰 dhcp）
#   pkg-restore-smartdns.sh --repair     整体自愈：装包 + 规则文件 + 配置 + 重启（探针用）
#   pkg-restore-smartdns.sh --localrule  只补 /etc/smartdns/custom.conf 的 localhost 行
#
# 环境变量：ROMDIR（默认 /rom）、PKGROOT（默认空）、RESTORE_BIN（默认 pkg-restore.sh）
#
# 退出码：0 成功或本来就不缺 / 1 失败 / 2 用法错误
# --check 另有三档：0 全好 / 3 规则文件缺 / 4 缺 localhost 本地解析

set -u
ROMDIR="${ROMDIR:-/rom}"
PKGROOT="${PKGROOT:-}"

# 通用恢复脚本的查找顺序（v.180.147）：
#   ① 显式 RESTORE_BIN
#   ② /usr/sbin/pkg-restore.sh —— 固件里的正式位置
#   ③ 与本脚本同目录 —— 两个脚本一起被拷到 /tmp 单独验时的情况。
#      写死 ② 的后果在 2026-10-29 真机暴露过：从 /tmp 跑这个脚本，
#      _sd_pkg 直接报「找不到 /usr/sbin/pkg-restore.sh」并返回 1，
#      smartdns 本体一个都没装回来，只剩 --conf 补了规则文件 —— 半残。
RESTORE_BIN="${RESTORE_BIN:-}"
if [ -z "$RESTORE_BIN" ]; then
    if [ -x /usr/sbin/pkg-restore.sh ]; then
        RESTORE_BIN=/usr/sbin/pkg-restore.sh
    else
        RESTORE_BIN="$(dirname "$0")/pkg-restore.sh"
    fi
fi

log() { printf '[PKG] %s\n' "$*"; }

# /etc/smartdns/ 下必须存在的规则文件（与构建期固化进固件的那批一致）
# 已淘汰的旧上游（2026-11-07 起 CN 组转 DoT）。这几个 IP 在真机上实测 TCP 853
# 不通或解析失败，留着只会拖慢并发查询（超时后才用上其他节点）。
#
# 【2026-11-07.2326】这个黑名单变量已删除。用户定「改成全清，防止错误配置遗留」：
# 上游写入改为「删光所有 server 段再按表重建」，黑名单不再是执行路径的一部分。
# 保留这份 IP 清单只为留档 —— 它们是被真机实测否掉的，将来想复活某条要先测通。
#   国内 UDP：180.76.76.76 123.125.81.6（百度）、101.226.4.6 218.30.118.6（DNS派）、
#             140.207.198.6（联通）、1.2.4.8（CNNIC）、119.29.29.29（DNSPod）
#   境外：8.8.4.4、1.1.1.1、1.0.0.1（855/443 实测 0 B，与 8.8.8.8 的 91 B 对照）

SD_CONF_FILES="address.conf blacklist-ip.conf custom.conf domain-block.list domain-forwarding.list"

# 【2026-11-07】localhost 本地解析 —— adblock 探活的活路
#
# adblock 4.5.x 的 f_dnsup() 用 nslookup localhost. 判 DNS 后端是否起来
# （adblock.sh 第 80 行 adb_lookupdomain="localhost"，硬编码）。smartdns 对
# localhost 回 NXDOMAIN，nslookup 退出码 1，adblock 判失败：30 次轮询 × 1 秒
# 后打 "dns backend restart with adblock blocklist failed"。列表其实照样生成
# 并已被 conf-file 引入（blocked_domains 不为 0），功能没坏，只是每次 reload
# 白等 30 秒 + 刷一条假错误。
#
# 落点为什么是 custom.conf 而不是 uci：
#   2026-11-07 真机（H3C C100 / ImmortalWrt 25.12.2 / smartdns 48.4）实测，
#   uci 里写 config domain-rule + domain/address 三段，/var/etc/smartdns/
#   smartdns.conf 里一行都不会出现 —— 那是 init 不认的段类型，写了也白写。
#   而 init 生成的 smartdns.conf 里有 `conf-file /etc/smartdns/custom.conf`，
#   往该文件追加一行 address /localhost/127.0.0.1 后 nslookup rc=0。
# 所以判据是 custom.conf 里的整行文本，不碰 uci 的 domain-rule 段。
_SD_LOCALRULE="address /localhost/127.0.0.1"

# 【v.180.148】两个判据分开，绝不混用：
#
#   --check-pkg   包在不在：二进制 + init 可执行，再做一次冒烟。
#                 回答的是「要不要装包」。装完就结束，不管服务起没起。
#
#   --check       服务生不生效：pidof + 53 端口。
#                 回答的是「功能通不通」。不生效就重启/报错，绝不再装包 ——
#                 否则配置写错会变成「判缺 -> 装包 -> 还是不通 -> 再判缺 -> 再装」的死循环。
#
# 服务判据与 bootstrap 的 verify_sd_serve 同口径（那边 v.180.106 已改用 pidof，
# 注释记了弃用 pgrep -x 的原因：busybox 拿 argv[0] 整串比对，"smartdns" 恒不相等）。
# 冒烟只为抓动态库缺口：opkg remove libopenssl3 之后两个 -x 判断依然为真，
# 只有真跑才看得见。取向仍是「只有明确加载错误才判缺」，其余异常一律放过。
_sd_pkg_ok() {
    [ -x "$PKGROOT/usr/sbin/smartdns" ] && [ -x "$PKGROOT/etc/init.d/smartdns" ] || return 1
    case "$("$PKGROOT/usr/sbin/smartdns" -v 2>&1)" in
        *"Error loading"*|*"No such file"*|*"not found"*|*"cannot open shared object"*)
            return 1 ;;
    esac
    return 0
}

# 只读判定，不启动、不重启。重启只发生在 --config / --repair 走到末尾 _sd_apply 时。
# 【v.180.186】判据补上「53 是谁在听」：
#   pidof 有进程 + netstat 里有 :53 这两条是独立的，合起来并不能说明
#   「smartdns 真的绑上了 53」—— dnsmasq 占着 53 时旧判据照样通过。
#   现在按 socket inode 反查：/proc/net/udp{,6} 里 local port=0035 且 st=07
#   的 inode，再在 /proc/<smartdns pid>/fd/* 里找 socket:[<inode>]。
# 【v.180.198】探针已不再判 53（它只数 uci 上游段），这条判据现在只服务本脚本
#   自己：_sd_apply 写完配置后用它确认「53 真的到了 smartdns 手上」，失败就
#   log + return 1，不再把 53 还给 dnsmasq。
_sd_serve() {
    _ss_pid=$(pidof smartdns 2>/dev/null | awk '{print $1}')
    [ -n "$_ss_pid" ] || return 1
    _ss_ino=$(awk 'NR>1 && $4=="07" { n=split($2,a,":"); if (a[n]=="0035") print $10 }' \
        /proc/net/udp /proc/net/udp6 2>/dev/null)
    [ -n "$_ss_ino" ] || return 1
    for _ss_i in $_ss_ino; do
        for _ss_f in /proc/"$_ss_pid"/fd/*; do
            [ "$(readlink "$_ss_f" 2>/dev/null)" = "socket:[$_ss_i]" ] && return 0
        done
    done
    return 1
}

# 本体：走通用恢复的依赖树，两个依赖都是普通包，递归即可
_sd_pkg() {
    [ -x "$RESTORE_BIN" ] || { log "找不到 $RESTORE_BIN"; return 1; }
    "$RESTORE_BIN" --tree smartdns
}

# 规则文件：不存在才补，存在一律不动
_sd_conf() {
    _n=0
    for _f in $SD_CONF_FILES; do
        [ -e "$PKGROOT/etc/smartdns/$_f" ] && continue
        [ -e "$ROMDIR/etc/smartdns/$_f" ] || continue
        mkdir -p "$PKGROOT/etc/smartdns" 2>/dev/null
        cp -a "$ROMDIR/etc/smartdns/$_f" "$PKGROOT/etc/smartdns/$_f" 2>/dev/null \
            && _n=$((_n + 1))
    done
    [ "$_n" -gt 0 ] && log "从只读基座恢复 smartdns 规则文件：$_n 个（/etc/smartdns/）"
    return 0
}

# 关键文件检测：五个规则文件「基座有、运行期没有」就算不完整。0=齐, 1=缺。
#
# 为什么必须单独判：_sd_serve() 只判「进程在 + 53 归它」，两条都与
# /etc/smartdns/*.conf 在不在无关 —— smartdns 启动时把配置读进内存，
# 运行中删文件既不影响 pidof 也不影响 socket，--check 照样返 0。
# 而探针的 _up_svc 直接转调 --check、rc.local 也拿它当门票，于是
# 「文件没了」两个自动入口都看不见，_sd_conf() 永远等不到调用。
# 2026-11-02 真机实测（192.168.1.201，删 /etc/smartdns/address.conf）：
#   --check  → rc=0（看不见）
#   --repair → 补回 1 个文件、824 B（能力是有的，就是没人触发）
#   rc.local / 探针在 100 秒内均无动作。
# 判据与 _sd_conf() 共用同一份 SD_CONF_FILES —— 判定与恢复各写一份清单的话，
# 加文件时漏一处就会出现「判得出、补不回」或反过来的静默失效。
# 只看「基座有、运行期没有」：基座本来就没有的（老固件/精简固件没编这些规则）
# 不算缺，否则每轮都判坏、又永远补不回来，只会把通道锁死在 warn。
_sd_conf_ok() {
    _sc_miss=0
    for _sc_f in $SD_CONF_FILES; do
        [ -e "$ROMDIR/etc/smartdns/$_sc_f" ] || continue
        if [ ! -e "$PKGROOT/etc/smartdns/$_sc_f" ]; then
            printf '[PKG] 缺规则文件：/etc/smartdns/%s\n' "$_sc_f" >&2
            _sc_miss=1
        fi
    done
    [ "$_sc_miss" = 0 ]
}

# localhost 行是否已经在位。整行精确匹配（-x），不是子串 ——
# 否则 address /localhost/127.0.0.2 这种也会被判成已配好。
_sd_localrule_ok() {
    if [ ! -f "$PKGROOT/etc/smartdns/custom.conf" ]; then
        printf '[PKG] 缺文件：/etc/smartdns/custom.conf\n' >&2
        return 1
    fi
    grep -qxF "$_SD_LOCALRULE" "$PKGROOT/etc/smartdns/custom.conf" 2>/dev/null && return 0
    # 失败要说清缺什么：探针的 _up_svc 会把 --check 的输出转 syslog，
    # 静默 return 1 的话日志里只剩一句笼统的「未就绪」。
    printf '[PKG] 缺 localhost 本地解析：/etc/smartdns/custom.conf\n' >&2
    return 1
}

# 追加该行。幂等：已在位直接返回 0，不重复追加。
# 原文件末尾没有换行时先补一个，否则新行会粘到最后一行注释上变成废行。
_sd_localrule() {
    _slr_f="$PKGROOT/etc/smartdns/custom.conf"
    _sd_localrule_ok && return 0
    [ -d "$PKGROOT/etc/smartdns" ] || mkdir -p "$PKGROOT/etc/smartdns" 2>/dev/null
    [ -f "$_slr_f" ] || : >"$_slr_f"
    if [ -s "$_slr_f" ] && [ -n "$(tail -c 1 "$_slr_f" 2>/dev/null)" ]; then
        printf '\n' >>"$_slr_f" || return 1
    fi
    printf '%s\n' "$_SD_LOCALRULE" >>"$_slr_f" || return 1
    log "已追加 localhost 本地解析（/etc/smartdns/custom.conf）"
    return 0
}

# 界面是否可用。三段判据，都不碰包管理器（apk / opkg 通用）：
#   ① 运行期在位                                   → 0
#   ② 只读基座里有、运行期没有（该有却没有）        → 1，要恢复
#   ③ 基座里也没有（固件压根没编界面）             → 0，不报警
# ③ 是为老固件留的：它本来就没界面，每轮白恢复一次没有意义。
#
# 【v.180.159】② 原来判的是 /usr/lib/opkg/info/luci-app-smartdns.list，
# 那是 opkg 的安装清单。25.12 换 apk 后该路径永远不存在，于是那一行
# `|| return 0` 恒触发 → 本函数恒返 0（静默通过）→ 界面真丢了也漏报，
# 而且 _sd_luci 永远不跑。这不是误报，是漏报 + 永不恢复。
# 换成判基座里的两个界面文件，跨包管理器，且与 _sd_luci 的恢复来源同一份东西。
_sd_luci_ok() {
    if [ -f "$PKGROOT/usr/share/luci/menu.d/luci-app-smartdns.json" ] \
       && [ -f "$PKGROOT/usr/libexec/smartdns-call" ]; then
        return 0
    fi
    if [ -f "$ROMDIR/usr/share/luci/menu.d/luci-app-smartdns.json" ] \
       && [ -f "$ROMDIR/usr/libexec/smartdns-call" ]; then
        return 1
    fi
    return 0
}

_sd_luci() {
    _sd_luci_ok && return 0
    [ -x "$RESTORE_BIN" ] || return 1
    "$RESTORE_BIN" luci-app-smartdns || return 1
    return 0
}

# ====================================================================
# 【v.180.155】配置写入与整体修复：smartdns 从 bootstrap 全面接管
#
# 架构口径（用户 2026-10-29 定）：bootstrap 只负责「网络 / 网桥 / 容器网络 /
# lxc 与 bouncer 恢复 / crowdsec 容器恢复 / crowdsec 与 bouncer 联动配置」六件事。
# smartdns 的包、配置、服务全部由本脚本 + 探针负责，bootstrap 不再参与。
#
# 配置口径：验证 smartdns 存在之后**即写入**，不做逐项比对 —— 上游表写死 6 条
# （国内 3 DoT / 境外 3，用户明确说「完全够用」）。覆盖式写入的副作用是
# 在 LuCI 里手改的上游会被下一轮冲掉；这与原 bootstrap 的
# build_smartdns_upstream 行为完全一致，不是退步。
#
# 与 bootstrap 的关键差别：本脚本是独立进程，没人替它 commit / 重启，
# 所以 _sd_apply 自己 commit + 重启 + 等端口。
# ====================================================================

# smartdns 主配置段（config smartdns）的段名；没有则回空
_sd_main_seg() {
    uci -q show smartdns 2>/dev/null \
        | sed -n 's/^smartdns\.\([^.=]*\)=smartdns$/\1/p' | head -n1
}

# 【v.180.156】不再手动把 dnsmasq 的 53 让出来 —— smartdns 的 init 自己会做。
#
# 依据（pymumu/smartdns，Release46.1 与 Release48.4 的 package/openwrt/files/
# etc/init.d/smartdns 逐字相同，ImmortalWrt 24.10 用 48.4）：
#   L733  config_get auto_set_dnsmasq "$section" "auto_set_dnsmasq" "1"   ← 默认开
#   L891  [ "$auto_set_dnsmasq" = "1" ] && set_main_dns                    ← port=53 时
#   L78   [ "$dnsmasq_port" = "53" ] && set dhcp.@dnsmasq[0].port=0        ← 就是这里让的位
# 随后它还会补 dhcp.lan.dhcp_option="6,$hostip"、把 dns_redirect 关掉、
# uci commit dhcp 并 restart dnsmasq；且幂等（uci_batch 为空直接 return，不重启）。
# LuCI 那句「端口设为 53 时自动配置为主 DNS」说的就是这段。
#
# 所以本脚本只要保证 port=53 且 auto_set_dnsmasq=1，restart smartdns 时由 init
# 完成让位。原来的 _sd_release_53 是重复劳动（还会让 dnsmasq 多重启一次），已删。
#
# 前提（init 里的硬条件）：set_main_dns 开头 `[ -z "$hostip" ] && return`，
# hostip 取自 network.lan.ipaddr。lan 没静态地址时 init 静默跳过、谁都不让位，
# 那时 53 仍被 dnsmasq 占着 —— 这种情形由 _sd_apply 的失败分支报出来。
#
# 【v.180.198】删除回滚：smartdns 必须占 53（用户 2026-10-31 定）。
#
# 旧行为是「init 让出 53 后若 smartdns 起不来，就把 53 还给 dnsmasq」。删掉的理由：
#   · 与本固件的 DNS 取向冲突 —— 这台机器就是拿 smartdns 当主 DNS 用，
#     53 一旦被 dnsmasq 拿回去，分流与拦截全部失效，而没有任何机制再把它拿回来：
#     init 的 set_main_dns 只在 restart smartdns 时判断，dnsmasq 占着 53 就不会再让位。
#   · 回滚把「起不来」这件必须立刻知道的事，变成一条「已回滚」日志就算了结 ——
#     表面上有 DNS，实际 smartdns 的规则一条都没生效。
# 现在失败只报错并返回 1，由探针下一轮重试（--config 会重写 uci 并重启）。
# 对应地，探针不再检查 53，只检查上游条数（见 crowdsec-lxc-probe.sh 的 _up_watch）。

# 主配置段：不存在就建，逐项写死
_sd_cfg_main() {
    _sdc_seg=$(_sd_main_seg)
    if [ -z "$_sdc_seg" ]; then
        uci -q add smartdns >/dev/null 2>&1
        _sdc_seg=$(_sd_main_seg)
        [ -n "$_sdc_seg" ] || { log "无法创建 smartdns 主配置段"; return 1; }
    fi
    uci -q set "smartdns.$_sdc_seg.enabled=1" || return 1
    uci -q set "smartdns.$_sdc_seg.port=53" || return 1
    # bind 不是 UCI 选项：init 脚本只读 port / bind_device，历史残留的 bind 顺手清掉，
    # 否则会让人误以为在控制监听地址。
    uci -q delete "smartdns.$_sdc_seg.bind" 2>/dev/null
    # bind_device=0 → 只生成 `bind [::]:53`，br-lan / lxcbr0 / docker0 一律可达。
    # 设成 1 时 init 只绑 br-lan + lo，容器拿 lxcbr0 地址来查会被丢掉。
    uci -q set "smartdns.$_sdc_seg.bind_device=0" || return 1
    # auto_set_dnsmasq=1（init 的默认值，这里显式写死）：port=53 时由 init 负责
    # 把 dhcp.@dnsmasq[0].port 置 0 并重启 dnsmasq。显式写是为了防止在 LuCI 里
    # 误关一次就永久失效 —— 与本脚本其它字段「写死纠正」的口径一致。
    uci -q set "smartdns.$_sdc_seg.auto_set_dnsmasq=1" || return 1
    # 组名 CN / out（用户 2026-11-07 定，全大写国内、全小写境外）。
    # bind 行的 -group 来自这个字段，上游段的 server_group 必须与它逐字一致，
    # 大小写不同就是两个组 —— 组名对不上时 53 端口绑的组没有上游，解析全空。
    uci -q set "smartdns.$_sdc_seg.server_flags=-group CN" || return 1
    # 第二服务器 = 6553，只走 out 组、不缓存：给 honk 的 dae 在分流后使用。
    # 只写四项骨头：开、端口、TCP、绑 out 组。init 里 seconddns_enabled 默认是 0
    # （第 564 行直接 return），不写 enabled，重刷后 6553 根本不监听，honk 的 out
    # 上游会整组失效；port / tcp_server / server_group 是这套转发的形状。
    uci -q set "smartdns.$_sdc_seg.seconddns_enabled=1" || return 1
    uci -q set "smartdns.$_sdc_seg.seconddns_port=6553" || return 1
    uci -q set "smartdns.$_sdc_seg.seconddns_tcp_server=1" || return 1
    uci -q set "smartdns.$_sdc_seg.seconddns_server_group=out" || return 1
    # no_cache / no_speed_check / no_dualstack_selection / force_aaaa_soa 故意不写：
    # 用户 2026-11-07 定，这四项交给 LuCI 自己点，以备不时之需。脚本一旦写了就会
    # 每轮覆盖，等于把开关锁死。注意重刷固件后它们回到默认 0，需要手动再点一次。
    uci -q set "smartdns.$_sdc_seg.cache_size=32768" || return 1
    uci -q set "smartdns.$_sdc_seg.serve_expired=1" || return 1
    uci -q set "smartdns.$_sdc_seg.prefetch_domain=1" || return 1
    return 0
}

# 上游 6 条写死（CN 3 条 DoT + out 1 DoT + 2 DoH）。**全清重建**：先把所有 server
# 段删光，再按下面 6 行表逐条新建（用户 2026-11-07 定，理由是「防止错误配置遗留」）。
#
# 为什么不再做「按 ip 找段修正 + 淘汰黑名单」：
#   · 覆盖式写入本来就会冲掉 LuCI 里手改的上游，黑名单那层「部分保留」语义自相矛盾；
#   · 黑名单是硬编码的 10 个 IP，漏掉任何一个旧段它都会继续生效 —— 53 的 CN 组还有
#     UDP 上游、out 组把实测 0 B 的死节点当可用，等于 DoT 改造白做；
#   · 刷机后新固件的 uci 里本来就没有那些段，黑名单永远匹配不到，是死代码。
# 代价（已知并接受）：LuCI 里手加的表外上游活不过一次 --config；要长期保留只能进表。
#
# 事务性：删除只落在 uci 暂存目录（/tmp/.uci），后面任何一步失败都会 _sd_discard
# revert，不会真的把表删成空的；只有 commit 成功才算落地。
#
# 删除从后往前：@server[-1] 每轮都指向当前最后一个，删它不动前面任何段的索引，
# 删到没有该类型段就自然失败退出（8 段 = 8 次 delete，不起 show/sed/head）。
# 不能「预先展开列表再逐个删」—— 删掉 @server[0] 之后其余整体前移一格，8 段
# 那样只会删掉 4 段、留下原 1/3/5/7，而末尾 -eq 6 只数表内行、照样通过。
# 50 轮上限兜底，delete 失败立刻退出，不死循环。
_sd_cfg_upstream() {
    # 守门①：uci 读不出来就什么都别做。否则下面「一条都没取到」会被当成
    # 「本来就没有旧段」，接着 add 6 条 —— 结果是 6 条新的叠在 N 条旧的上，
    # 而末尾 -eq 6 只数表内行、照样通过，脏配置被静默留下。
    uci -q show smartdns >/dev/null 2>&1 || {
        log "uci show smartdns 失败，无法确认旧上游已清空，放弃写配置"
        return 1
    }
    _sdc_g=0
    while [ "$_sdc_g" -lt 50 ]; do
        _sdc_g=$((_sdc_g + 1))
        uci -q delete "smartdns.@server[-1]" 2>/dev/null || break
    done
    # 守门②：清完必须真的一条不剩。delete 失败或撞上 50 轮上限都会提前 break，
    # 那时继续 add 就是「新的叠旧的」。这里复核一次，不干净就整条路径作废。
    _sdc_left=$(uci -q show smartdns 2>/dev/null | grep -c '=server$')
    case "$_sdc_left" in ''|*[!0-9]*) _sdc_left=-1 ;; esac
    [ "$_sdc_left" = "0" ] || {
        log "旧上游未清干净（剩 $_sdc_left 条），不接管 DNS"
        return 1
    }
    _sdc_n=0
    while read -r _sdc_name _sdc_ip _sdc_tp _sdc_grp _sdc_host; do
        # 表里带 # 注释行，必须跳过 —— 否则注释会被当成一条上游写进 uci，
        # 条数校验直接炸（真机踩过：4 行注释让 7 条变 11 条）。
        case "$_sdc_name" in ''|'#'*) continue ;; esac
        [ -n "$_sdc_ip" ] || continue
        uci -q add smartdns server >/dev/null 2>&1
        _sdc_hit="@server[-1]"
        uci -q set "smartdns.$_sdc_hit.enabled=1"
        uci -q set "smartdns.$_sdc_hit.name=$_sdc_name"
        uci -q set "smartdns.$_sdc_hit.ip=$_sdc_ip"
        uci -q set "smartdns.$_sdc_hit.type=$_sdc_tp"
        uci -q set "smartdns.$_sdc_hit.server_group=$_sdc_grp"
        # DoT / DoH 都要带 SNI：DoT 只写 IP，不设 SNI 必然校验失败（8.8.8.8 的证书是
        # dns.google）；DoH 的 URL 里虽然含域名，显式设上更稳妥 —— 不设虽然也能通，
        # 但那是靠实现去猜，不该依赖。
        if { [ "$_sdc_tp" = "tls" ] || [ "$_sdc_tp" = "https" ]; } && [ "$_sdc_host" != "-" ]; then
            uci -q set "smartdns.$_sdc_hit.host_name=$_sdc_host"
        else
            # UDP 段不该带 SNI：历史残留清掉，否则每轮都会判不符
            uci -q delete "smartdns.$_sdc_hit.host_name" 2>/dev/null
        fi
        _sdc_n=$((_sdc_n + 1))
    done <<'SD_UPSTREAM_EOF'
# 【2026-11-07】CN 组改 DoT：实测本链路 TCP 53 被干扰（阿里/腾讯连上即 RST、
# 百度 SYN 无回应），而 853 端口可达且解析正常（91 B，与 UDP 同长）。
# 只有这 3 条实测可用：阿里 2 条、腾讯 1 条（dot.pub → 120.53.53.53）。
# 百度 / 360 / CNNIC 的 853 不通或解析失败，全部淘汰（清单见文件头留档）。
alidns 223.5.5.5 tls CN dns.alidns.com
alidns 223.6.6.6 tls CN dns.alidns.com
dnspod 120.53.53.53 tls CN dot.pub
google 8.8.8.8 tls out dns.google
# out 组：honk 开着时才可达（实测 8.8.8.8 的 853/443、dns.google 的 DoH、
# cloudflare 的 DoH 都能真解析出 91 B；cloudflare 的 853 与 1.1.1.1 的 DoT 均为 0 B）。
# DoH 必须写域名，用 IP 形式（https://8.8.8.8/dns-query）实测 0 B 失败。
google https://dns.google/dns-query https out dns.google
cloudflare https://cloudflare-dns.com/dns-query https out cloudflare-dns.com
SD_UPSTREAM_EOF
    [ "$_sdc_n" -eq 6 ] || { log "上游按表处理条数异常（$_sdc_n ≠ 6），不接管 DNS"; return 1; }
    return 0
}

# commit + 重启 + 等端口。
# 不再手动 restart dnsmasq：init 的 start_service 只要见到 port=53 且
# auto_set_dnsmasq=1，就会自己把 dnsmasq 的 port 置 0 并重启它，顺序由 init 保证。
# 我们只 restart smartdns，然后等 53 真的在听。
_sd_apply() {
    uci commit smartdns || { log "uci commit smartdns 失败"; _sd_discard; return 1; }
    [ -x /etc/init.d/smartdns ] || { log "没有 /etc/init.d/smartdns，无法重启"; return 1; }
    /etc/init.d/smartdns restart >/dev/null 2>&1
    _sda_i=0
    while [ "$_sda_i" -lt 15 ]; do
        _sd_serve && return 0
        sleep 1
        _sda_i=$((_sda_i + 1))
    done
    log "配置已写入，但 53 端口 15 秒内没有监听（端口被占、配置语法或动态库问题）"
    # 【v.180.198】不回滚：smartdns 必须占 53（用户 2026-10-31 定）。
    # 此时 dnsmasq 的 53 已被 smartdns 的 init 让出，机器确实没有可用 DNS ——
    # 这条错误必须被看见，而不是用「把 53 还给 dnsmasq」把它掩盖成一条「已回滚」。
    # 重试由探针的 _up_watch 承担（它只判上游条数，不看 53）。
    return 1
}

# 丢弃尚未 commit 的 smartdns 改动。/tmp/.uci 是 uci 的暂存目录，本进程 exit 后
# 脏数据仍在，下次任何人 commit smartdns 都会把它带进去 —— 半套配置上线的后果比不写更糟。
# 只 revert smartdns：dhcp 由 smartdns 的 init 改，本脚本不再碰它，
# 贸然 revert dhcp 会把别人（LuCI 编辑中）尚未提交的改动一起丢掉。
# 只用在「还没 commit 就失败」的路径；已经 commit 的失败由 _sd_apply 报错返回，
# 不回滚（53 必须归 smartdns，v.180.198）。
_sd_discard() {
    uci -q revert smartdns 2>/dev/null
    return 0
}

# --config 主流程：验证存在 → 补规则文件 → 写主段 → 写上游 → commit/重启
_sd_config() {
    # 【2026-10-31.0256】uci 是 25.12 自带的系统组件，写死不探测（用户 2026-10-31 定）。
    if ! _sd_pkg_ok; then
        log "smartdns 不在位，先从只读基座装回"
        _sd_pkg || { log "装包失败（只读基座里没有 smartdns）"; return 1; }
        _sd_pkg_ok || { log "装包后仍判不在位，放弃写配置"; return 1; }
    fi
    _sd_conf
    _sd_localrule || { log "localhost 本地解析写入失败"; _sd_discard; return 1; }
    _sd_cfg_main || { log "主配置段写入失败"; _sd_discard; return 1; }
    _sd_cfg_upstream || { log "上游表写入失败，不接管 DNS"; _sd_discard; return 1; }
    _sd_apply || return 1
    log "smartdns 已接管 DNS：6 条上游（国内 3 DoT / 境外 2 DoH+1 DoT），dnsmasq 由 init 让出 53"
    log "localhost 本地解析在位：adblock 的 nslookup localhost. 探活可通过"
    return 0
}

case "${1:-}" in
"")
    _rc=0
    _sd_pkg || _rc=1
    _sd_conf
    if _sd_luci_ok; then
        :
    else
        log "界面 luci-app-smartdns 缺失 —— 单独补，不影响本体"
        _sd_luci || log "界面未恢复（只读基座里没有它的安装清单，只影响网页配置）"
    fi
    exit $_rc
    ;;
# --config 与 --repair 现在等价：_sd_config 内部已经按「缺包先装包」的顺序走完，
# 保留两个名字是为了调用点语义清楚（rc.local 开机配一次用 --config，
# probe 在「DNS 不正常」（53 未接管 或 上游 0 条）时兜底用 --repair。
# bootstrap 自 v.180.157 起不再调用本脚本）。
--config|--repair)
    _sd_config && exit 0 || exit 1
    ;;
--check)
    # 两段都必须过：服务在跑（53 归 smartdns）+ 五个规则文件在位。
    # 只判前者时，「文件被删、进程还活着」会一直判好（配置在内存里，pidof 和
    # socket 都不受影响），两个自动入口（探针 _up_svc / rc.local 门票）就都瞎，
    # _sd_conf() 永远等不到调用 —— 2026-11-02 真机实测：删 address.conf 后
    # --check 返 0，探针 100 秒无动作。判定清单与 _sd_conf() 共用 SD_CONF_FILES。
    #
    # 【2026-11-02】退出码分三态，让探针按「坏在哪一层」选修法：
    #   0 = 服务在（53 归它）+ 五个规则文件齐 + localhost 行在位
    #   1 = 服务没起来（53 未接管 / 二进制缺失）—— 硬故障，只能 --config
    #   3 = 服务正常、只有规则文件缺 —— 软故障，--conf 补文件即可
    #   4 = 服务正常、文件齐，只缺 /etc/smartdns/custom.conf 的 localhost 行
    #       —— 2026-11-07 新增。缺它 adblock 每次 reload 白等 30 秒并打假失败；
    #       修法同样走 --config（改 custom.conf 必须重启 smartdns 才载入）
    # 为什么要分开：--config 会 commit + 重启 smartdns（约 15 秒 DNS 中断），
    # 而「文件被删、进程还活着」这种软故障只要把文件拷回去就完事，重启纯属白掉线。
    # 只判 0/非 0 的调用点（rc.local 开机门票、其它 sh -c 判断）语义不变：
    # 非 0 照旧走 --config，兜底方向没变。
    _sd_serve || exit 1
    _sd_conf_ok || exit 3
    _sd_localrule_ok || exit 4
    exit 0
    ;;
--check-pkg)
    _sd_pkg_ok && exit 0 || exit 1
    ;;
--pkg)
    _sd_pkg && exit 0 || exit 1
    ;;
--conf)
    _sd_conf && _sd_localrule && exit 0 || exit 1
    ;;
--localrule)
    _sd_localrule && exit 0 || exit 1
    ;;
--luci)
    _sd_luci && exit 0 || exit 1
    ;;
*)
    echo "用法：$0 [--check|--pkg|--conf|--luci|--localrule]" >&2
    exit 2
    ;;
esac
