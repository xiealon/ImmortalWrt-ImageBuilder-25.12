#!/bin/sh
# bootstrap/main.sh —— 主入口
#
# 内容：main（八组串行 + 收尾复核）、_bs_on_exit / _bs_on_signal（退出即恢复）、
#       _pending_report、audit_wan_purged / _audit_all（--verify-only 用）。


# 本文件被 bootstrap.sh 以 --full 模式执行时会 source 全部依赖；
# 直接跑 `sh main.sh` 时自己补齐（保持与原单文件脚本一致的行为）。
if [ -z "${_BS_DEPS_LOADED:-}" ]; then
    _here=$(cd "$(dirname "$0")" && pwd)
    . "$_here/_lib.sh"
    . "$_here/_dag.sh"
    for _f in "$_here"/*/step.sh; do
        case "$_f" in
        *selfheal*) continue ;;
        esac
        . "$_f"
    done
    . "$_here/selfheal/step.sh"
    _BS_DEPS_LOADED=1
fi

_pkgcache_resolve() {
    for _pr_d in "$PKG_CACHE_RO" "$PKG_CACHE"; do
        [ -n "$_pr_d" ] || continue
        [ -f "$_pr_d/$_PKG_IDX" ] || continue
        _PKG_CACHE_ACT="$_pr_d"
        return 0
    done
    _PKG_CACHE_ACT=""
    return 1
}

_pkgcache_ready() {
    _pkgcache_resolve || return 1
    ls "$_PKG_CACHE_ACT"/*."$_PKG_EXT" >/dev/null 2>&1 || return 1
    return 0
}

# 把 pkg-cache 挂成 apk 源。幂等 + 自清理死源。
# 旧写法只做「没有就追加」，于是两个坑：
#   ① 路径变了（/root → /rom）就多一条，两条同名源指两个目录；
#   ② 目录被删后那行还在，`apk update` 遇到不存在的 file:// 源会报错，
#      连带把真正可用的远程源也更新不掉 —— 用户装任何包都先撞这个错。
# 现在每次都按前缀重写这一行：其余源一个字不碰，pkgcache 行永远只有一条、且指向
# 当前真正可用的目录。
_pkgcache_install_apk() {
    _pci_pkg="$1"
    _pkgcache_ready || return 1
    # 【2026-10-31.0256】apk 必在，写死不探测。
    # 已装就跳过：没坏的东西不该重装一遍
    # 【v.180.161】PCR_FORCE=1 时不跳：同上，记账在、文件缺。
    if [ "${PCR_FORCE:-0}" != "1" ] && apk info -e "$_pci_pkg" >/dev/null 2>&1; then
        return 0
    fi
    # 【v.180.184】apk add 对已装包是 no-op —— 「记账有、文件被删」只有 apk fix
    # 会按校验和重装（实测删掉 /usr/bin/dns2socks 后 fix 打出 Reinstalling 并补回）。
    _pci_repos="${TMPDIR:-/tmp}/bootstrap-pkg.repos"
    printf 'file://%s/%s\n' "$_PKG_CACHE_ACT" "$_PKG_IDX" > "$_pci_repos" 2>/dev/null || {
        log "[PKG] 写不出临时源文件：$_pci_repos"
        return 1
    }
    if [ "${PCR_FORCE:-0}" = "1" ] && apk info -e "$_pci_pkg" >/dev/null 2>&1; then
        if apk fix --allow-untrusted --repositories-file "$_pci_repos" "$_pci_pkg" >/dev/null 2>&1; then
            log "[PKG] 本地 apk 强制重装成功：$_pci_pkg"
            rm -f "$_pci_repos"
            return 0
        fi
        log "[PKG] 本地 apk 强制重装失败：$_pci_pkg（本地库没有它）"
        rm -f "$_pci_repos"
        return 1
    fi
    if apk add --allow-untrusted --repositories-file "$_pci_repos" "$_pci_pkg" >/dev/null 2>&1; then
        log "[PKG] 本地 apk 源装回成功：$_pci_pkg（/etc/apk/world 记账正确，LuCI 可见）"
        rm -f "$_pci_repos"
        return 0
    fi
    rm -f "$_pci_repos"
    log "[PKG] 本地 apk 装不回 $_pci_pkg（本地库缺它或缺依赖），放弃 —— 不再拷文件兜底"
    return 1
}

_pkgcache_install() {
    # 【v.180.133】优先交给独立脚本 pkg-cache-restore.sh：它自己会先按
    # resolve -> 挂源 -> 铺索引 的顺序把前置做好，再装 —— 顺序不再依赖调用方。
    # 下面这段内置实现保留为兜底：老固件里没有那个脚本，行为必须完全不变。
    if [ -x /usr/sbin/pkg-cache-restore.sh ]; then
        if /usr/sbin/pkg-cache-restore.sh "$1" >/dev/null 2>&1; then
            log "[PKG] 经 pkg-cache-restore.sh 装回：$1"
            return 0
        fi
        log "[PKG] pkg-cache-restore.sh 未成功：$1，回退内置实现"
    fi
    # 【v.180.198】原来的 `if [ "$_PKG_MGR" = "apk" ]` 之后跟着整套 opkg 装回逻辑
    # （list-installed 判据 → ipk 直装 → 本地源 + --no-check-signature）。
    # 25.12 上那段永远不可达，已整段删除；opkg 那套活在自己的 24.10 仓库里。
    _pkgcache_install_apk "$1"
    return $?
}

# 恢复单个包：只走本地包安装，不拷文件（v.180.149）
_rom_restore_pkg() {
    # 【v.180.149】改成只走包级。理由：
    #   ① 拷文件修不了 opkg/apk 记账 —— 装回来的包 LuCI 看不见、依赖解不开、
    #      下次升级会乱，属于「能跑但半残」；
    #   ② 文件清单随包版本漂，判据越写越复杂，迟早出错。
    # 老固件没有本地包库时也无法恢复 —— 装不上就报错，不再补一个半残状态。
    #
    # 【v.180.161】第二个参数为 1 = 强制重装（跳过「已装就跳过」判定）。
    # 只有「文件确已不在」的调用方才许传 1：opkg 记账清不掉手删的文件，
    # 而 pkg-cache-restore.sh 和下面的内置回退都以记账为准 —— 不强制的话，
    # 恢复链会在这里返回 0 却不做任何事，日志上看是「装好了」，实际二进制还缺。
    # PCR_FORCE 是 pkg-cache-lib.sh 的既定接口（那边 _pcr_install 已支持），
    # 这里只是把它透传下去；前缀赋值由子进程按环境变量继承。
    if [ "${2:-0}" = "1" ]; then
        PCR_FORCE=1 _pkgcache_install "$1"
    else
        _pkgcache_install "$1"
    fi
}

# 【v.180.150】bouncer 不再单独拷文件 —— 和 lxc 一样走本地包安装。
# /rom 是只读、不可修改的可信层，包库里的 ipk/apk 就是固件原样内容，
# opkg install 出来的结果与拷文件完全等价，而且记账同步（LuCI 可见、依赖可解）。
# 既然源头可信，就不需要「包级装不上再拷文件」这层兜底 —— 兜底只会制造
# 「能跑但半残」的状态：文件在、记账没有，下次升级或卸载时出问题。

# lxc 全家桶：/rom 里装了哪些 lxc-* 就恢复哪些（applet 是独立包，不会互相拉）
_preflight() {
    _pf_bad=""
    _lxc_missing_deps || _pf_bad="$_pf_bad$_LXC_MISSING"
    [ -x /usr/bin/cs-firewall-bouncer ] || _pf_bad="$_pf_bad cs-firewall-bouncer"
    [ -x /etc/init.d/crowdsec-firewall-bouncer ] || _pf_bad="$_pf_bad init.d/crowdsec-firewall-bouncer"
    [ -x /usr/sbin/nft ] || _pf_bad="$_pf_bad nft"
    # 【2026-11-10.0420】timeout 也纳进来：它不在时 _run_capped 会降级（功能不变），
    # 但 /etc/init.d/crowdsec-lxc-probe 的 `timeout 60 guard` 与 6 处 rc.local 调用点
    # 都要走降级路径，能装回来就不要留着降级。判据只认命令，不认包名。
    command -v timeout >/dev/null 2>&1 || _pf_bad="$_pf_bad timeout"
    if [ -z "$_pf_bad" ]; then
        log "[PRE] 应用在位：lxc 五件套 + crowdsec-firewall-bouncer + nft + timeout"
    else
        log "[PRE] 应用缺失：$_pf_bad —— 先从只读基座按包装回"
        case "$_pf_bad" in
        *lxc*) _rom_restore_lxc || log "[PRE] lxc 装回失败（固件未内置或包库不可用）" ;;
        esac
        case "$_pf_bad" in
        *cs-firewall-bouncer* | *init.d/*) _rom_restore_pkg crowdsec-firewall-bouncer 1 \
            || log "[PRE] bouncer 装回失败" ;;
        esac
        case "$_pf_bad" in
        *nft*) _rom_restore_pkg nftables-json 1 || log "[PRE] nftables-json 装回失败" ;;
        # 【2026-11-10.0420】包级装回，不拷文件：coreutils-timeout 在包库里，
        # apk/opkg 装出来文件与记账一起回来；传 1 = PCR_FORCE，跳过「已装就算」判定。
        *timeout*) _rom_restore_pkg coreutils-timeout 1 \
            || log "[PRE] coreutils-timeout 装回失败（包库不可用或固件未内置）" ;;
        esac
        hash -r 2>/dev/null || true
        # 装完复判，别把「试过了」当「好了」
        _pf_bad=""
        _lxc_missing_deps || _pf_bad="$_pf_bad$_LXC_MISSING"
        [ -x /usr/bin/cs-firewall-bouncer ] || _pf_bad="$_pf_bad cs-firewall-bouncer"
        [ -x /etc/init.d/crowdsec-firewall-bouncer ] || _pf_bad="$_pf_bad init.d/crowdsec-firewall-bouncer"
        [ -x /usr/sbin/nft ] || _pf_bad="$_pf_bad nft"
    # 【2026-11-10.0420】timeout 也纳进来：它不在时 _run_capped 会降级（功能不变），
    # 但 /etc/init.d/crowdsec-lxc-probe 的 `timeout 60 guard` 与 6 处 rc.local 调用点
    # 都要走降级路径，能装回来就不要留着降级。判据只认命令，不认包名。
    command -v timeout >/dev/null 2>&1 || _pf_bad="$_pf_bad timeout"
        [ -z "$_pf_bad" ] || log "[PRE] 装回后仍缺：$_pf_bad"
    fi
    if verify_ct_config; then
        log "[PRE] 容器 config 正常"
    else
        log "[PRE] 容器 config 不符 —— 交给 ct_config 节点重建"
    fi
    if verify_rootfs; then
        log "[PRE] 容器 rootfs 正常"
    else
        log "[PRE] 容器 rootfs 不符 —— 交给 rootfs 节点重建"
    fi
    return 0
}



# 必备组件缺哪些（lxc 五件套）：全在返回 0；否则返回 1，缺失清单留在 _LXC_MISSING。
# 【v.180.112 / v.180.157】只管 lxc，不管 smartdns —— 后者归 pkg-restore-smartdns.sh + 探针。
# 只读不写 —— verify / build 两侧都用它。
# 五个命令逐一查：lxc-ls / lxc-info / lxc-attach 都是独立 applet 包（各自一个 ipk/apk），
# 没有任何反向依赖会把它们拉进来；只查 lxc-start 会得出「装好了」的假阳性 —— v.180.99 修正。
# 【v.180.100】smartdns 不在这里判：它由 _pkg_missing_all 合并，本函数只守 lxc 五件套。
# 【v.180.105】「在」≠「能用」：opkg remove liblxc 之后五个二进制全都还在，
# command -v 照过，可动态链接已经断了 —— 一直要到 ct_boot 真跑 lxc-start 才报
# 「Error loading shared library liblxc.so.1」，那时离根因已经很远。
# 所以五件套齐全后再跑一次 lxc-start --version 冒烟（一次进程，约 10ms）。
# 判据取向：只有明确看到动态库加载错误才判缺。反过来的「误判成缺」会让 pkg_base
# 硬失败、把整轮引导带走，代价远大于漏报，所以其余任何异常输出一律放过。
# 【v.180.112】本函数旧名带 sd 字样，有歧义：函数体只查 lxc 五件套，
# 与 smartdns 毫无关系；v.180.112 之前本函数旧名带 sd 字样，容易被读成
# 「smartdns 也在这里查」。v.180.157 起 smartdns 已整坨移出本脚本：
# 恢复归 pkg-restore-smartdns.sh，判定归探针的 _up_n / _up_watch，
# 本脚本不再有、也不该有 smartdns 的检查入口。
_wan_sections() {
    for _ws in wan wan6; do
        if run uci -q show "network.$_ws" 2>/dev/null | grep -q "^network\.$_ws="; then
            printf '%s\n' "$_ws"
        fi
    done
}

# 内核里有没有名为 wan / wan6 的接口（v.108.32）。x86 的网口是 eth*，这一项恒为空；
# 一旦出现，说明 uci 之外还有东西在造 WAN 面（DSA 板子的 wan netdev、手工 ip link、
# 别的脚本插一脚）。段删干净了但接口还在，就是「配置看着是旁路由、实际还在当网关」。
_wan_ifaces() {
    for _wi in wan wan6; do
        [ -e "/sys/class/net/$_wi" ] && printf '%s\n' "$_wi"
    done
    return 0
}

# firewall 里引用了 wan / wan6 的段，输出「段:接口」，空格分隔（无尾空格）。
# 抽成一处，是因为 purge 与 audit 必须共用同一份解析：各写一份的后果是
# 「purge 认得出、audit 认不出」——清理完了体检还在报，或者反过来报绿。
# uci 的 list 在 `uci show` 里是一行带多个值：
#   firewall.@zone[1].network='wan' 'wan6'
# 所以后面按值逐个 del_list，不能整条覆盖 —— 一覆盖就把别的接口引用也抹了。
_wan_refs() {
    _wr_all=""
    for _wr_net in wan wan6; do
        for _wr_sec in $(run uci show firewall 2>/dev/null \
            | sed -n "s/^firewall\.\([^.]*\)\.network=.*'$_wr_net'.*/\1/p" | sort -u); do
            if [ -n "$_wr_all" ]; then
                _wr_all="$_wr_all $_wr_sec:$_wr_net"
            else
                _wr_all="$_wr_sec:$_wr_net"
            fi
        done
    done
    [ -n "$_wr_all" ] && printf '%s\n' "$_wr_all"
    return 0
}

# 旁路由锁死（v.108.27）：wan / wan6 段一律删除，不作为 DAG 节点、不参与任何判定。
# 为什么从节点降级成无条件动作：目标就是旁路由，WAN 口永远不该存在 ——
# 「检测有没有 wan 段」对这台机器恒等于「还没有，那就删」，多一个节点只是多一行日志。
# 为什么必须整段 delete 而不是 disabled=1：新 nft 后台不认 disabled 标志，段还在，
# fw4 生成规则时照样按 proto/device 起接口、挂 WAN zone，等于旁路由还在当路由器用。
# 为什么删完要 reload：commit 只落到 /etc/config/network，运行中的接口还在内核里；
# 不 reload 的话这一轮看起来删干净了，实际 WAN 面还通着。
purge_wan_sections() {
    # network 配置本身写坏时 uci show 会失败、输出为空 —— 那不是「没有 wan 段」，
    # 是「读不出来」。不区分的话，一台配置文件损坏的机器会被判成「WAN 已清空」。
    if ! run uci show network >/dev/null 2>&1; then
        log "[WAN] 无法解析 /etc/config/network，不能判断 wan 段状态"
        return 1
    fi
    _pw_left=$(_wan_sections)
    if [ -z "$_pw_left" ]; then
        # 【v.108.32】段删过不等于引用清过。上一版把清理写在下面「真删了段」的分支里，
        # 热更新的机器（不刷机、直接换脚本）段早就没了，永远走不到清理那一步 ——
        # firewall 里对 wan 的引用一直留着，fw4 每轮 reload 都对不存在的接口告警。
        # 清理本身幂等（没有引用就 return 0），挪到这里没有代价。
        log "[WAN] 旁路由锁定：wan/wan6 段已不存在，无需删段"
        if ! purge_wan_refs; then
            log "[WAN] firewall 引用清理失败"
            return 1
        fi
        return 0
    fi
    log "[WAN] 旁路由锁定：发现 $_pw_left，整段删除"
    for _pw_n in $_pw_left; do
        run uci -q delete "network.$_pw_n" 2>/dev/null
    done
    if ! run uci -q commit network 2>/dev/null; then
        log "[WAN] 删除后提交失败（改动只在内存里，重启即丢）"
        return 1
    fi
    _pw_after=$(_wan_sections)
    if [ -n "$_pw_after" ]; then
        log "[WAN] 删除后复核仍有残留：$_pw_after"
        return 1
    fi
    _net_reload
    # 【v.108.30】firewall 里可能还挂着 `list network 'wan' 'wan6'`。段没了之后
    # fw4 会一直对不存在的接口告警，这条引用本身也在描述一个不存在的世界。
    # 只删「引用」，不删 zone：zone 上还可能绑着 rules/forwardings，整段删会把
    # 别的东西一起带走；fw4 对没有 network 的 zone 是忽略的。
    if ! purge_wan_refs; then
        log "[WAN] firewall 引用清理失败"
        return 1
    fi
    # 【v.108.32】段删了、引用清了，最后一关是内核：netifd 没拆掉的接口会继续存在，
    # 这时「uci 里没有 wan」是真的，但网卡还挂着。reload 是异步的，这里只报不判死，
    # 判定交给开机后的 audit_wan_purged（那时该消失的早消失了）。
    _pw_if=$(_wan_ifaces)
    [ -n "$_pw_if" ] && log "[WAN] 段已删，但内核里仍有接口：$_pw_if（等 reload 收敛，体检会复核）"
    log "[WAN] 已删除 network.wan / network.wan6 并 reload，WAN 面彻底关闭"
    return 0
}

# 清掉 firewall 里对 wan/wan6 的引用（这两个接口段已不存在）。
# 解析在 _wan_refs，这里只负责按值逐个 del_list 并提交。
purge_wan_refs() {
    _pr_hit=$(_wan_refs)
    [ -n "$_pr_hit" ] || return 0
    for _pr_one in $_pr_hit; do
        _pr_sec=${_pr_one%%:*}
        _pr_net=${_pr_one##*:}
        if ! run uci -q del_list "firewall.$_pr_sec.network=$_pr_net" 2>/dev/null; then
            log "[WAN] firewall.$_pr_sec 解除 $_pr_net 引用失败"
            return 1
        fi
        log "[WAN] firewall.$_pr_sec 不再引用 $_pr_net（该接口段已删除）"
    done
    if ! run uci -q commit firewall 2>/dev/null; then
        log "[WAN] firewall 引用改动提交失败（改动只在内存里）"
        return 1
    fi
    run_svc /etc/init.d/firewall reload >/dev/null 2>&1
    return 0
}

# reload 单独抽一层：直接写绝对路径的话，「删完到底有没有让内核重建接口」
# 就只剩一句注释可以相信了 —— 抽出来测试才能真的数到这次调用。
_net_reload() { run_svc /etc/init.d/network reload >/dev/null 2>&1; }

# 管理服务监听面验证（v.77 同源）：dropbear(SSH) 绑 LAN zone 对应接口
# ——取代原 99-custom 的「Interface 清空=无差别监听所有口」：那种写法会把 SSH 暴露到 WAN
# 无 name=lan 的 zone → 不涉及，跳过
# 【v.108.40】ttyd 不再参与：本机用不到网页终端，那两条判据（interface=all +
# netstat 查端口监听）连同 build 侧的 ttyd 写入一起删掉。原判据里 `netstat -lnt`
# 在 ImmortalWrt 默认固件里通常没有这个 applet，命令不存在 → 管道空 → grep 必失败，
# 于是配置写得完全正确也被判成「写了没生效」，收口复核直接 exit 1（见 v.108.40 说明）。
_bs_content_fp() {
    _cf_dir="${1:-.}"
    _cf_out=$(
        cd "$_cf_dir" 2>/dev/null || exit 3
        _cf_list=$(find . -type f 2>/dev/null | sort | sed 's|^\./||')
        [ -n "$_cf_list" ] || exit 4
        # 【v.180.192】sha1sum → sha256sum：25.12 的 busybox 只编了 md5sum 与
        # sha256sum（真机 `busybox --list` 实测），没有 sha1sum，coreutils 那份
        # 也是 not set。原来这里恒为空 → 指纹永远算不出来 → 「容器被动过」判不出来，
        # 只剩时间戳那条路（正是本函数刻意要避开的）。
        printf '%s\n' "$_cf_list" | while IFS= read -r _cf_f; do sha256sum "$_cf_f" 2>/dev/null; done | sha256sum 2>/dev/null | cut -c1-16
    ) || return 1
    [ -n "$_cf_out" ] || return 1
    printf '%s' "$_cf_out"
}

# ---- 静态配置 sha 基线（v.108.25）----
# 「文件在」「结构对」都只是形式；内容和上次写的那份是不是同一份，只有 sha 说得清。
# 覆盖范围刻意收窄到脚本自己写的那四份文件，不多算一个字节：
#   主配置 config.yaml / 采集源 acquis.d/router.yaml / 两个解析器
# 不比整目录指纹 —— 用户自己在 parsers/ 下加解析器是合理需求，不该判成不符。
CFG_SHA_LIST="etc/crowdsec/config.yaml
etc/crowdsec/acquis.d/router.yaml
etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml
etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml"

# 四个文件逐个算 sha256，输出「sha 相对路径」行；缺任何一个都算算不出来
#
# 【v.108.42】config.yaml 不能整文件算进基线。它里面有几行是「设计上每轮必变」的：
#   capi_block    启动前把 online_client 注释掉
#   capi_release  bouncer 验证后把它放回来
# 基线是在 _stamp_write 那一刻写的（那时按设计是「放开态」），而重启态的开机引导
# 一上来就先跑 capi_block 注释 → 文件变了 → LOGCONF 的 verify_acquis 立刻报
# 「解析器/配置 sha 与基线不符」→ build_acquis 怎么写都写不回去（它压根不管
# online_client 那两行）→ hard 退出。
# 首台真机实测（07:15 那一轮，重启后第一次引导）：
#   [日志] 解析器/配置 sha 与基线不符（内容被改动）
#   [日志] 容器内采集配置不符
#   [配置] 解析器 + 日志源 + 白名单已写入
#   [日志] 容器内采集配置写入后仍不符
#   [logconf] 构建执行失败，hard 失败，引导终止（退出码 1）
# 这不是配置被改坏，是判据把「设计内的状态切换」当成了漂移。
# 处理：把这四行剔掉再算 sha —— online_client 与它的 online_api credentials_path。
# （client 段的 local_api credentials_path 不受影响，正则限定了 online_api_credentials.yaml）
_cfg_sha_now() {
    for _r in $CFG_SHA_LIST; do
        [ -f "$ROOTFS/$_r" ] || return 1
        case "$_r" in
            etc/crowdsec/config.yaml)
                _h=$(sed -E \
                        -e '/^[[:space:]]*#?[[:space:]]*online_client:/d' \
                        -e '/credentials_path:[[:space:]]*\/etc\/crowdsec\/online_api_credentials\.yaml/d' \
                        "$ROOTFS/$_r" 2>/dev/null | sha256sum | awk '{print $1}')
                ;;
            *)
                _h=$(sha256sum "$ROOTFS/$_r" 2>/dev/null | awk '{print $1}')
                ;;
        esac
        [ -n "$_h" ] || return 1
        printf '%s  %s\n' "$_h" "$_r"
    done
}

# 一轮跑完（stamp 落盘那一刻）把当时的 sha 记成基线，首行钉住版本号：
# 换了脚本版本就说明产出可能变，旧基线不该拿来判新脚本。
_cfg_sha_write() {
    mkdir -p "$STATE_DIR" 2>/dev/null || return 1
    _cs_new=$(_cfg_sha_now) || return 1
    { printf 'ver=%s\n' "$SCRIPT_VER"; printf '%s\n' "$_cs_new"; } >"$CFG_SHA_FILE.tmp" 2>/dev/null || return 1
    [ -s "$CFG_SHA_FILE.tmp" ] || { rm -f "$CFG_SHA_FILE.tmp" 2>/dev/null; return 1; }
    mv -f "$CFG_SHA_FILE.tmp" "$CFG_SHA_FILE" 2>/dev/null
}

# 判据：当前 sha 与基线逐字节一致。
# 无基线（首次安装还没跑完）或版本已变（基线过期）→ 不拿它下结论，交给结构判据。
_stamp_field() {
    [ -s "$STAMP_FILE" ] || return 0
    sed -n "s/^$1=//p" "$STAMP_FILE" 2>/dev/null | head -n 1
}

# 「容器配置还是不是我上次认下来的那一套」——比内容，不比时间。
_stamp_cfg_changed() {
    _sc_reason=""
    _sc_old_cfg=$(_stamp_field cfg_fp)
    _sc_old_parsers=$(_stamp_field parsers_fp)
    # 老 stamp 没有这两个字段：不是「变了」，是「当初没记」。不能据此判变更 ——
    # 否则所有从旧版本升级上来的机器，第一次开机都要白跑一轮全量复核。
    if [ -z "$_sc_old_cfg" ] && [ -z "$_sc_old_parsers" ]; then
        return 0
    fi
    _sc_new_cfg=$(_bs_content_fp "$ROOTFS/etc/crowdsec") || _sc_new_cfg=""
    _sc_new_parsers=$(_bs_content_fp "$ROOTFS/etc/crowdsec/parsers") || _sc_new_parsers=""
    # 算不出新指纹（目录被删/权限不对）属于「这次没法比」，不在这里下结论，
    # 交给 verify_rootfs 那一层去判「缺东西」。
    [ -n "$_sc_new_cfg" ] || return 0
    if [ "$_sc_old_cfg" != "-" ] && [ "$_sc_old_cfg" != "$_sc_new_cfg" ]; then
        _sc_reason="$_sc_reason cfg($_sc_old_cfg→$_sc_new_cfg)"
    fi
    if [ -n "$_sc_new_parsers" ] && [ "$_sc_old_parsers" != "-" ] \
       && [ "$_sc_old_parsers" != "$_sc_new_parsers" ]; then
        _sc_reason="$_sc_reason parsers($_sc_old_parsers→$_sc_new_parsers)"
    fi
    [ -z "$_sc_reason" ] && return 0
    log "[变更] 容器 crowdsec 配置与上次跑通时的指纹不一致：$_sc_reason"
    return 1
}

# 完整跑通的置位：同时清失败计数与未完成标记（任何一次健康开机都让计数自愈）
_stamp_write() {
    mkdir -p "$STATE_DIR" 2>/dev/null || { log "[stamp] STATE_DIR 不可写（$STATE_DIR），跳过置位"; return 1; }
    # 除了版本与时间，还记下「当时容器配置的指纹」：下次开机比对指纹就知道
    # 「容器里那套东西还是不是我上次认下来的那一套」，比时间可靠。
    _bs_fp_cfg=$(_bs_content_fp "$ROOTFS/etc/crowdsec") || _bs_fp_cfg="-"
    _bs_fp_parsers=$(_bs_content_fp "$ROOTFS/etc/crowdsec/parsers") || _bs_fp_parsers="-"
    atomic_write "$STAMP_FILE" "installed" <<EOF || { log "[stamp] 写入失败"; return 1; }
installed
ver=$SCRIPT_VER
ts=$(date '+%F %T')
cfg_fp=$_bs_fp_cfg
parsers_fp=$_bs_fp_parsers
EOF
    _bs_stamped=1
    # 【v.108.25】顺手把静态配置的 sha 记成基线：这一轮是验证通过的，
    # 它们现在长什么样，就是下一次 verify 要比对的样子。
    _cfg_sha_write || log "[stamp] 配置 sha 基线写入失败（不影响本轮，下次比对会跳过）"
    # 跑通即清账：失败计数、未完成标记、以及「抹盘后未收尾」的连续次数
    rm -f "$REINSTALL_FAIL_FILE" "$REINSTALL_PENDING_FILE" "$INTR_FILE" 2>/dev/null
    log "[stamp] installed 已置位（$STAMP_FILE）：本流程完整跑通过，重装自愈已启用"
    return 0
}

# ---- 重置额度（v.108.19）：每次开机一次 ----
# 语义：重启 = 人主动干预一次，换一次「可以抹盘重建」的权利。
# 同一次开机内无论跑几遍 bootstrap（探针触发、手动重跑），额度都只有一份。
_pending_report() {
    [ -f "${REINSTALL_PENDING_FILE:-}" ] || return 0
    log "[恢复] 重装未完成标记仍在（$REINSTALL_PENDING_FILE）：本次退出被判定为中途失败，下次开机将计一次失败。这是设计行为，不是漏清理"
    return 0
}

# EXIT trap 回调。做两件事，顺序要紧：
#   先做「重装失败计数」（要用到当前的 stamp/pending 状态），
#   再做「置位恢复」（把进程内变量归零、按需还原内核态）。
_bs_on_exit() {
    # ---- 第一部分：重装失败计数 ----
    if [ "${CS_BOOTSTRAP_REINSTALL:-0}" = 1 ] \
       && [ "${_bs_st:-0}" -ne 0 ] \
       && [ "${_bs_stamped:-0}" != 1 ]; then
        log "[重装] 重装后流程以退出码 $_bs_st 收场，计一次失败"
        _fail_count_inc
        rm -f "$REINSTALL_PENDING_FILE" 2>/dev/null
    fi

    # ---- 第二部分：置位恢复 ----
    # 只在「真有东西要恢复」时才打日志——正常跑完的路径上置位本来就该归零，
    # 每次都打两条「快照/已归零」只会把日志淹掉（跳过 DAG 的极简路径尤其明显）。
    if command -v _bs_flag_stats >/dev/null 2>&1; then
        _bx_snap=$(_bs_flag_stats)
        if [ "$_bx_snap" != "done=0 dirty=0 gset=0 built=0" ] \
           || [ "${_ipfwd_touched:-0}" = 1 ] \
           || [ -f "${REINSTALL_PENDING_FILE:-}" ]; then
            log "[恢复] 退出时置位快照：$_bx_snap（退出码 ${_bs_st:-?}）"
            # v.99：光有计数看不出「哪几个、什么时候置的」，真出问题时要翻半天。
            # 这里把每个已置位的名字连同 V/B/R 与时间戳打一行，日志本身就是现场。
            _bx_list=""
            for _bx_n in $DAG_NODES; do _bx_list="$_bx_list _done_$_bx_n _dirty_$_bx_n"; done
            for _bx_g in $GROUP_SEQ; do _bx_list="$_bx_list GSET_$_bx_g"; done
            _bx_dump=$(_bs_flag_dump $_bx_list)
            [ -n "$_bx_dump" ] && log "[恢复] 逐项：$_bx_dump"
            _ipfwd_restore
            _pending_report
            _bs_clear_flags
            log "[恢复] 置位已全部归零：$(_bs_flag_stats)"
        else
            # 干净退出：静默归零，不留噪音
            _ipfwd_restore
            _bs_clear_flags
        fi
    fi
    return 0
}

# 信号处理：INT/TERM/HUP 与 EXIT 走同一条恢复路径。
# 不装这几个的话，被 kill / SSH 断线时 EXIT trap 未必触发（dash 下 SIGTERM 默认
# 直接终止进程、不走 EXIT），置位与内核态就留在半截状态里。
_bs_on_signal() {
    _bs_sig="$1"
    # 三个信号 trap 全部摘掉：防止处理过程中再来一个信号把恢复逻辑打断、跑两遍。
    trap - INT TERM HUP
    log "[恢复] 收到信号 SIG$_bs_sig，按异常退出处理"
    _bs_st=143
    _bs_on_exit
    # 【必须连 EXIT trap 一起摘掉】否则下面的 exit 会再触发一次 EXIT trap，
    # 恢复逻辑跑第二遍：日志里会出现两条「置位快照/已归零」，
    # ip_forward 也可能被记成"还原过两次"。这个坑第一次就踩到了。
    trap - EXIT
    exit 143
}

verify_NETBASE() {
    for _n in $NETBASE_NODES; do
        "verify_$_n" 2>/dev/null || return 1
    done
    return 0
}
build_NETBASE() {
    for _n in $NETBASE_NODES; do
        ensure "$_n" || return 1
    done
    flush_uci
    return 0
}

# PREP：容器启动前必须在位的静态准备（容器网络 / cgroup），依赖 NETBASE 与 INSTALL
verify_PREP() {
    for _n in $PREP_NODES; do
        "verify_$_n" 2>/dev/null || return 1
    done
    return 0
}
build_PREP() {
    # 网络侧 11 项全部「验证 + 修改」（v.95/v.97 起，含 bridge；v.108.40 去掉 dns_domain）：
    # br_lan_ports / lan_static / dhcp_ignore / bridge / …
    for _n in $PREP_NODES; do
        ensure "$_n" || return 1
    done
    flush_uci
    return 0
}

# INSTALL：解压 rootfs / 迁移镜像 / 校验容器 config（全部磁盘态，可先于启动完成）
rg_step() {
    _rs_title="$1"; _rs_verify="$2"; _rs_build="$3"
    if "$_rs_verify" 2>/dev/null; then
        log "[$_rs_title] 内容一致，跳过"
        return 0
    fi
    log "[$_rs_title] 内容不符，执行构建一次"
    if ! "$_rs_build" 2>/dev/null; then
        log "[$_rs_title] 构建执行失败，hard 失败，引导终止"
        return 1
    fi
    log "[$_rs_title] 已构建"
    return 0
}

# 重启态：按 GROUP_SEQ 逐组验证；某组里有个节点修不好 → hard 退出（v.106 起不重装）
# 【2026-10-20 修掉的三个致命缺陷，每一个都能让这台机器每小时被抹一次盘】
#   ① 变量名大小写（v.104 更正 v.103 的错误修法）：GROUP_SEQ 里是全大写
#      （PREP INSTALL ...），置位走 ensure_group 的 _bs_flag_set "GSET_$_g"，
#      $_g 来自 GROUP_SEQ，所以写进 shell 的变量名就是 GSET_PREP。
#      v.103 为了「统一口径」把读取端 tr 成小写去读 GSET_prep —— 而 shell 变量名
#      大小写敏感，于是八个组一个都读不到，每次开机第 1 组就判「未置位」→
#      full_reinstall：复核链整体失效，last_pull 一旦失效就直接 rm -rf rootfs。
#      口径钉死：组键一律（大写）用 GROUP_SEQ 原值，置位与读取两侧都不做大小写转换。
#   ② 组级函数根本不存在：这里原本调 verify_$_g / build_$_g，也就是
#      verify_PREP / build_PREP …… 全脚本一个都没有（只有 verify_br_lan_ports
#      这类节点级函数）。`"verify_PREP" 2>/dev/null` 在 dash 下报
#      "not found" 并被 2>/dev/null 吞掉，返回非 0 ⇒ 每次都判「内容不符」⇒
#      调 build_PREP 同样不存在 ⇒ 「构建失败且无法修复」⇒ full_reinstall ⇒ 抹盘。
#      **每次开机都抹一次容器**，还完全静默。现在改成遍历该组内的节点，
#      调真正的 verify_<节点> / build_<节点>。
#   ③ 一个节点修不好就整机重装太重：节点级 verify 不过是很常见的事（比如某个
#      uci 值被人在 LuCI 里改了），build 一次基本都能修回来。v.106 起更进一步：
#      build 也失败时不再升级到重装，而是打一份只读诊断后 hard 退出 —— 修不好等于
#      脚本的修复能力对不上现场，重装是同一套脚本、同一份镜像再跑一遍，只会重蹈
#      覆辙并先把证据抹掉。自动重装的唯一入口收在 _structurally_broken() 里，
#      只认结构性损坏（rootfs 残缺 / 无 init / 容器目录不可写）。
#   ④ 【v.105，与①并列的第二个 v.103 遗留】重建后不落盘：build_* 只写 uci 内存态，
#      commit/reload 统一归 flush_uci；而 _dirty_ 脏标记只有 ensure() 会置。
#      本函数直接调 build_、组末又没 flush_uci ⇒ 「修好了」只活在内存里：
#      /etc/config 没动、fw4 的 nft 表没重建，uci delta 在 /tmp 下，重启即清空，
#      下次开机 verify 又不过、又修一遍，永远修不进去。现在：build 成功即补
#      _dirty_，并在每组末尾 flush_uci（放在 bad 判断之前，已修好的也要落盘）。
rg_restart_verify() {
    for _rg_g in $GROUP_SEQ; do
        _rgG=$(echo "$_rg_g" | tr 'a-z' 'A-Z')
        # 读 _rgG（大写）：置位点是 ensure_group 的 _bs_flag_set "GSET_$_g"，
        # $_g 来自 GROUP_SEQ（全大写），变量名就是 GSET_PREP。
        # v.103 这里 tr 成小写去读 GSET_prep —— shell 变量名大小写敏感，永远读不到。
        if ! _bs_flag_on "GSET_$_rgG"; then
            # 【v.106】组置位只表示「本进程的 ensure_group 跑成功过」，不是配置真相。
            # 重启态下这里为真，通常意味着阶段 1+2 该组中途失败（或上次是旧版本 /
            log "[重启态] 组 $_rgG 本轮未置位（阶段 1+2 未完成该组），改为逐节点复验判定"
        fi
        # 组内逐节点复验：通过就跳过，不过就修一次。
        # 节点清单从全局拓扑序 _order 里按 NODE_GROUP_<节点> 筛出来 ——
        # 与 ensure_group 同一个口径，不另建一份平行的组→节点表（那种并行表迟早会歪）。
        _rg_bad=""
        for _rg_n in $_order; do
            [ "$(eval "echo \$NODE_GROUP_$_rg_n")" = "$_rgG" ] || continue
            "verify_$_rg_n" 2>/dev/null && continue
            log "[重启态][$_rgG] $_rg_n 内容不符，执行构建一次"
            if "build_$_rg_n" 2>/dev/null; then
                # build_* 只写 uci 内存态（commit/reload 统一归 flush_uci 处理），
                # 脏标记也只在 ensure() 里置 —— 本函数直接调 build_ 绕过了 ensure，
                # 所以必须自己补 _dirty_，否则下面的 flush_uci 会判「无改动」跳过提交。
                _bs_flag_set "_dirty_$_rg_n" B
                log "[重启态][$_rgG] $_rg_n 已构建"
                continue
            fi
            log "[重启态][$_rgG] $_rg_n 构建也失败（不是配置错，是环境坏了）"
            case " $SOFT_NODES " in
            *" $_rg_n "*)
                log "[重启态][$_rgG] $_rg_n 属柔性节点（SOFT_NODES），只告警不中止；长期监视交给探针"
                continue
                ;;
            esac
            _rg_bad="$_rg_bad $_rg_n"
        done
        # 【v.105】组末落盘。build_* 只写 uci 内存态：不 flush 就等于「只在内存里修好了」
        # ——/etc/config 没动、fw4 的 nft 表没重建，而 uci 的 delta 在 /tmp 下，重启即清空，
        # 下次开机 verify 又不过、又 build 一遍，永远修不进去。日志却全程报「已构建」。
        flush_uci
        if [ -n "$_rg_bad" ]; then
            # 【v.106 用户口径】修不好＝脚本修复能力/资产失效，重装没有意义：同一套脚本、
            # 同一份镜像只会把同样的失败再走一遍，还要先把现场证据抹掉。唯一例外是
            # 结构性损坏（rootfs/init/容器定义被外部破坏），那由 _structurally_broken()
            # 判定，不在这里。这里先打一份只读诊断，再 hard 退出。
            log "[重启态][$_rgG] 这些节点修不好：$_rg_bad → 修复能力失效，hard 退出（不重装）"
            _reinstall_diag
            exit 1
        fi
        log "[重启态][$_rgG] 组内节点全部就绪"
    done
    log "[重启态] 全部 $(echo $GROUP_SEQ | wc -w | tr -d ' ') 个组验证通过"
}

main() {
    log "===== crowdsec-lxc-bootstrap v$SCRIPT_VER 开始（容器 $LXC_NAME）====="

    # 【--net-only】只校准路由器网络基线，不碰镜像 / rootfs / 容器。
    # 组链缩成 PREP 一组：INSTALL / CAPIBLOCK / BOOT 及之后的四组全部不参与，
    # 因为它们的每一步都要求容器 rootfs 存在。
    #
    # 注意不能只改 GROUP_SEQ：dag_order 会遍历整个 DAG_NODES，发现某个小步骤归属的
    # 组不在 GROUP_SEQ 里就直接终止（「归属的组 INSTALL 不在 GROUP_SEQ 中」）。
    # 所以必须同时把 DAG_NODES 裁成「PREP 组里与容器无关的节点」。
    if [ "$NET_ONLY" = "1" ]; then
        GROUP_SEQ="NETBASE"
        _no_dag=""
        for _no_n in $DAG_NODES; do
            [ "$(eval "echo \$NODE_GROUP_$_no_n")" = "NETBASE" ] || continue
            case " $NET_ONLY_SKIP " in
                *" $_no_n "*) continue ;;
            esac
            _no_dag="$_no_dag $_no_n"
        done
        DAG_NODES="$_no_dag"
        # 【v.108.29】组内真正执行的是 PREP_NODES，不是 DAG_NODES：
        # build_PREP / verify_PREP 都是 `for _n in $PREP_NODES`。只裁 DAG 的话，
        # PREP 组照样把 bridge / ct_net / ct_bootlink / ct_resolv / lxc_zone /
        # fwd_rules / snat 全跑一遍 ——「--net-only 不碰容器」就成了一句空话，
        # 没有 rootfs 时还会在 ct_net 上失败、把整个网络基线搭进去。
        _no_base=""
        for _no_n in $NETBASE_NODES; do
            case " $NET_ONLY_SKIP " in
                *" $_no_n "*) continue ;;
            esac
            _no_base="$_no_base $_no_n"
        done
        NETBASE_NODES="$_no_base"
        log "===== 网络基线模式（--net-only）：只校准路由器网络，不碰容器 ====="
        log "[网络基线] 跳过容器相关节点：$NET_ONLY_SKIP"
    fi

    # 【v.180.85】lxc 缺失不做硬失败：容器相关的每个节点都要 lxc-* 命令，硬跑只会
    # 第一个节点就 exit 1，把整轮引导带走。
    # 【v.180.104】缺 lxc 时这一轮跑「Ⅰ 网络 11 节点 + Ⅱ pkg_base」，两条出路：
    #   · pkg_base 从 /rom 补齐 → 末段看到 lxc-start 在，恢复完整组链接着跑；
    #   · /rom 里也没有   → 只留网络基线落盘，本轮到此刻收工，下次开机再试。
    # 判据仍是 verify-first：pkg_base 先 _pkg_missing_all，缺了才逐个文件拷，
    # 已就位时零写入、零扫描。
    # 裁剪方式与 --net-only 同源：只改 GROUP_SEQ 不够，dag_order 会遍历整个 DAG_NODES
    # 并校验归属组是否在 GROUP_SEQ 里，所以 DAG_NODES 必须同步收窄。
    # 【v.180.153】前置检查放在降级判定之前：先试从 /rom 包级装回，
    # 装得回来就不用走下面「裁 DAG 只跑网络」的降级路径 —— 那本来就是兜底，不该是首选。
    if [ "$NET_ONLY" != "1" ]; then
        _preflight
    fi
    _LXC_READY=1
    _FULL_DAG=""
    _FULL_SEQ=""
    _FULL_NETBASE=""
    if [ "$NET_ONLY" != "1" ] && ! command -v lxc-start >/dev/null 2>&1; then
        _LXC_READY=0
        # pkg_base 在本轮降为柔性：它只负责「尽力从 /rom 装回」，
        # 装不回来属于固件不合规，但网络基线已经配好，不该把整轮带走。
        SOFT_NODES="$SOFT_NODES pkg_base"
        # 完整组链留底：恢复成功后末段用它把容器流程接着跑完。
        _FULL_DAG="$DAG_NODES"
        _FULL_SEQ="$GROUP_SEQ"
        _FULL_NETBASE="$NETBASE_NODES"
        _lx_dag=""
        for _lx_n in $DAG_NODES; do
            case "$(eval "echo \$NODE_GROUP_$_lx_n")" in
                NETBASE)
                    # lxc_auto 必须摘掉：它要 lxc-auto 的服务脚本，Ⅱ 恢复成功之前跑
                    # 必然失败（成功后由末段重跑完整链补上）。
                    # pkg_base 必须保留 —— 它正是 Ⅱ「从 /rom 装回」的执行者，剔掉它 Ⅱ 永远没机会跑。
                    case "$_lx_n" in
                        lxc_auto) continue ;;
                    esac
                    _lx_dag="$_lx_dag $_lx_n"
                    ;;
            esac
        done
        # 组级 verify_NETBASE / build_NETBASE 遍历的是 NETBASE_NODES，不只是 DAG_NODES，
        # 这里同步收窄，避免两处口径不一致（--net-only 也踩过同一个坑）。
        _lx_base=""
        for _lx_n in $NETBASE_NODES; do
            case "$_lx_n" in
                lxc_auto) continue ;;
            esac
            _lx_base="$_lx_base $_lx_n"
        done
        NETBASE_NODES="$_lx_base"
        GROUP_SEQ="NETBASE"
        DAG_NODES="$_lx_dag"
        log "[PKG] 未检测到 lxc（缺 lxc-start）：本轮只跑网络基线，容器步骤整体跳过"
        log "[PKG] 固件应内置 lxc：请检查 custom-packages.sh / apk-custom-packages.sh 的 lxc 清单后重编"
    fi

    # 重装自愈持久状态：目录就位 + 退出记账 + 上次未完成重装先计数
    mkdir -p "$STATE_DIR" 2>/dev/null
    # 【v.108.18】判定「本次开机首跑」。boot_id 每次开机都变，所以拿它当开机身份：
    #   标记里的 id ≠ 当前 id  → 是新的一次开机，且是这次开机第一次跑 bootstrap → 首跑
    #   标记里的 id = 当前 id  → 本次开机已经跑过了（探针重跑 / 手动重跑）→ 非首跑
    # 拿不到 boot_id（极老内核）时按非首跑处理：宁可少重置，也不在运行期抹现场。
    _bi_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \t\r\n')
    if [ -n "$_bi_boot" ] && [ "$(cat "$BOOT_ID_FILE" 2>/dev/null | tr -d ' \t\r\n')" != "$_bi_boot" ]; then
        _BS_FIRST_RUN=1
        printf '%s\n' "$_bi_boot" | atomic_write "$BOOT_ID_FILE" "" 2>/dev/null \
            || log "[重装] 开机身份标记写入失败（$BOOT_ID_FILE），本次仍按首跑处理"
        # 【v.108.19】新的一次开机 → 失败计数归零，它从此只数「本次开机重置的结果」，
        # 不再是终身累计（否则一次偶发失败会把自愈能力永久关死）。
        # 必须赶在 _pending_recover 之前清：pending 补记的那一次要留在本次开机账上。
        if [ -f "$REINSTALL_FAIL_FILE" ]; then
            log "[重装] 新的一次开机：上次失败计数 $(_reinstall_fail_count) 归零，本次重新计"
            rm -f "$REINSTALL_FAIL_FILE" 2>/dev/null
        fi
    fi
    if [ "$_BS_FIRST_RUN" = 1 ]; then
        log "[重装] 本次开机的首跑：资产残缺且额度未用时可重置一次"
    else
        log "[重装] 本次开机已跑过引导（运行期重跑）：不重置，只走修复"
    fi
    # 三条退出路径统一走同一套恢复逻辑：
    #   EXIT  —— 正常返回 / exit N
    trap '_bs_st=$?; _bs_on_exit' EXIT
    trap '_bs_on_signal INT'  INT
    trap '_bs_on_signal TERM' TERM
    trap '_bs_on_signal HUP'  HUP
    _ipfwd_snapshot        # 记下 ip_forward 原值，退出时按需还原
    _bs_clear_flags        # 进场先归零，确保不会读到上一次（exec 前）的残留
    _pending_recover

    dag_order

    # 本机判定：无镜像且无 rootfs → 跳过（不进 DAG）。
    # net-only 不受此限：它的全部目的就是「没有镜像也把网络配了」。
if [ "$NET_ONLY" != "1" ] && [ ! -f "$TARBALL" ] && [ ! -f "$LEGACY_TARBALL" ] \
   && [ ! -d "$ROM_BASE" ] && [ ! -f "$CROWDSEC_CFG" ]; then
        log "无镜像且无 rootfs，本机不带 CrowdSec，跳过"
        exit 0
    fi

    _recovering=false
    mkdir -p "$LXC_PATH/$LXC_NAME" 2>/dev/null

    # 【v.108.27】旁路由锁死：wan / wan6 段在这里无条件删除，不属于任何组、不参与判定。
    # 放在组循环之前：网络组的每一项（网桥 / lan 地址 / 防火墙）都建立在「这台机器
    # 只当旁路由」这个前提上，WAN 段还留着的话前提就是假的。
    # 删不掉就终止 —— WAN 面开着却继续往下配，等于配了一台会自己拨号的路由器。
    if ! purge_wan_sections; then
        log "[WAN] 无法删除 wan/wan6 段，引导终止（WAN 面必须关闭）"
        exit 1
    fi

    # ---- 阶段 1+2：组链式调度（每组置位 GSET_<组>，后组执行前校验前置全部置位）----
    # 抽成函数是因为 v.180.89 起这条链可能跑两遍：lxc 原先缺失时，DEPS 现场补装成功后
    # 立刻回头把容器流程（含 enroll / last pull）走完，而不是留到下次开机。
    _run_chain() {
        _group_failed=""
        # 清零要走 _bs_flag_clear：v.99 起置位值是 V:<ts>，写 0 是非空值、会被判成"已置位"
        for _g in $GROUP_SEQ; do _bs_flag_clear "GSET_$_g"; done
        for _g in $GROUP_SEQ; do
            ensure_group "$_g"
        done
        flush_uci || _flush_rc=1
    }
    _flush_rc=0
    _run_chain

    # ---- net-only 到此收工：PREP 跑完网络基线就结束，不进容器服务链 ----
    # 这一步必须放在 flush_uci 之后：commit / reload 在 flush_uci 里做，提前退出
    # 会让改好的 network 停在内存里、重启即丢。
    # _NET_ONLY_OK 是给退出钩子看的：网络基线跑通了，说明 ip_forward=1 是期望稳态，
    # 不许在 _ipfwd_restore 里被还原成 0（那会把路由器的转发关掉，整机不能上网）。
    if [ "$NET_ONLY" = "1" ]; then
        if [ "$_flush_rc" != "0" ]; then
            log "网络基线未完成（--net-only）：配置提交/重载失败，详见上方 [flush] 行"
            exit 1
        fi
        if _bs_flag_on "GSET_PREP"; then
            _NET_ONLY_OK=1
            log "网络基线完成（--net-only）：路由器网络已按 /etc/config/custom_router_*.txt 校准"
            exit 0
        fi
        log "网络基线未完成（--net-only）：详见上方各节点日志，未做任何容器操作"
        exit 1
    fi

    # 【v.180.85】lxc 原先缺失的这一轮到此收工：容器流程整体没跑，不能拿「前置组未置位」
    # 去判失败（那会把「组件已补装成功」的机器记成失败，探针还会反复重跑）。
    # 网络基线与组件安装都已落盘（上面 flush 过），下次引导从 INSTALL 组正常接管。
    if [ "$_LXC_READY" = 0 ]; then
        if command -v lxc-start >/dev/null 2>&1; then
            # 流程图 Ⅲ①：网络正常 → 不存在 lxc → 安装 lxc → 进行配置（含 enroll）→ last pull。
            # 这里恢复完整组链当场再跑一遍：NETBASE 各节点 verify 直接通过（无写入），
            # 真正干活的是 INSTALL → PREP → CAPIBLOCK → BOOT → … → ENROLL。
            GROUP_SEQ="$_FULL_SEQ"
            DAG_NODES="$_FULL_DAG"
            NETBASE_NODES="$_FULL_NETBASE"
            # 【v.180.157】原来这里还要抹 deps 的失败/置位（enroll 曾依赖 deps）。
            # DEPS 组已随 smartdns 移出 bootstrap，enroll 现在只依赖 BOUNCERVERIFY，
            # 这两行成了对不存在节点的空操作，删除。
            _failed=""
            _LXC_READY=1
            dag_order
            log "[PKG] lxc 已就位：恢复完整组链，继续容器安装配置与 enroll"
            _run_chain
        else
            # 网络异常/装不上：按流程图「跳过结束」。网络基线跑通了，ip_forward=1 是
            # 期望稳态，不能因为「这轮没装完容器」被退出钩子还原成 0。
            _bs_flag_on "GSET_NETBASE" && _NET_ONLY_OK=1
            log "[PKG] 本轮容器流程已跳过（lxc 仍不在位）：网络基线与本地装包已完成，下次引导继续"
            exit 0
        fi
    fi

    # 前置组（INSTALL / PREP / CAPIBLOCK / BOOT）任一未置位 → 容器内服务链无从谈起
    for _g in INSTALL PREP CAPIBLOCK BOOT; do
        _bs_flag_on "GSET_$_g" && continue
        # 【v.106】自动重装的唯一判定点就在这里。
        # 前置组做不下去时先问一句：是资产被外部破坏（rootfs 残缺 / 没有 init /
        # 容器目录不可写），还是脚本自己修不动？前者重建有意义，后者重建只是把
        # 同一套脚本再跑一遍、顺带抹掉现场 —— 所以只有前者才允许 full_reinstall。
        # 【v.106.1】首次安装做不下去 ≠ 资产被破坏。
        # 没有 installed 标记 = 这台机器从没装成过，rootfs 本来就不存在，
        # _structurally_broken 的「缺 /etc」判据会恒真 —— 若不加这一道，
        # 首次失败会被读成「结构性损坏」→ 白跑一次全量重装，日志还会把现场带偏。
        if ! _stamp_present; then
            log "[$_g] 未置位：首次安装未完成（无 installed 标记），引导终止（不重装）"
            exit 1
        fi
        if _structurally_broken; then
            log "[$_g] 未置位且存在结构性损坏，转入彻底重装"
            full_reinstall || { log "[$_g] 重装条件不满足（原因见上方 [重装] 行），异常退出"; exit 1; }
            log "[$_g] 重装流程未接管（exec 失败），异常退出"
            exit 1
        fi
        log "[$_g] 未置位：前置组未完成，且无结构性损坏，引导终止（不重装）"
        exit 1
    done

    # ---- 阶段 3：LOGCONF / LAPI / BOUNCERVERIFY / ENROLL 四组（后四组）----
    log "===== 阶段 3：服务链开始 ====="

    if [ "${CS_BOOTSTRAP_REINSTALL:-0}" = 1 ]; then
        _cred_restore || log "[重装] 凭证恢复未成功，enroll 步将走重注册"
    fi

    if [ "$_recovering" = true ]; then
        rg_step "CAPI 屏蔽（新装恢复中先断中央 API）" verify_online_client_off ensure_online_client_off
    fi

    if _stamp_present; then
        log "[重启态] 检出 installed 标记：按组逐步验证，失败修复一次，仍失败即 hard 退出（不重装）"
        # 指纹只用来「说清楚现场」，不用来改变流程走向：重启态本来就是逐组复核，
        # 配置被改过与没被改过，要做的事完全一样（复核 → 不对就修一次 → 还不对重装）。
        _stamp_cfg_changed || log "[变更] 上面这处差异说明容器配置被人/别的脚本改过；本次仍按组复核一遍"
        rg_restart_verify
    else
        log "[安装态] 无 installed 标记：完整执行 LOGCONF → LAPI → BOUNCERVERIFY → ENROLL"
        ensure_group LOGCONF
        ensure_group LAPI
        ensure_group BOUNCERVERIFY
        ensure_group ENROLL
    fi

    # 【v.108.11】总 flush 的失败以前只记录不处置：_flush_rc 算完就丢，
    # 下面照样 _stamp_write + exit 0。后果是 commit/reload 失败（网络、防火墙没落盘）
    # 也被当成「引导成功」，rc.local 拿到 0，下次开机重来一遍还是同样的失败。
    # 用户口径：失败必须返回 1，不许假成功。
    if [ "$_flush_rc" != "0" ]; then
        log "配置提交/重载失败（详见上方 [flush] 行），引导按失败退出"
        exit 1
    fi

    # 【v.108.32】WAN 面收口：开头删过，不代表结尾还是删着的。
    # 中间任何一步都可能把它造回来 —— 手工 uci、后装的包自己生成 wan 段、
    # 网络组重建 interface。这里是本轮最后一道：不符合就地再清一次，清完还不符合
    # 就按失败退出。绝不允许「8 组全过、WAN 面却开着」的引导返回 0。
    # 判据分两级：段与 firewall 引用是硬的（uci 说没了就是没了，做不到就是没做到）；
    # 内核接口是软的 —— reload 异步，刚删完的接口可能还挂着，这里只报不判死，
    # 交给开机后的 --verify-only（那时早该收敛，不收敛就是真问题）。
    _wan_hard_ok=true
    [ -z "$(_wan_sections)" ] || _wan_hard_ok=false
    [ -z "$(_wan_refs)" ] || _wan_hard_ok=false
    if [ "$_wan_hard_ok" = false ]; then
        log "[WAN] 收口复核不符（段或 firewall 引用），自动再清一次"
        if ! purge_wan_sections; then
            log "[WAN] 收口清理失败，引导按失败退出（WAN 面必须是关的）"
            exit 1
        fi
        if [ -n "$(_wan_sections)" ] || [ -n "$(_wan_refs)" ]; then
            log "[WAN] 清理后仍不符，引导按失败退出（WAN 面必须是关的）"
            exit 1
        fi
        log "[WAN] 收口复核已恢复"
    fi

    # 【v.108.50】防火墙「编译结果」报告：本轮没有 reload 过防火墙时也要看一眼。
    # flush 路径里已经报过就不重复（_nft_reported=1）。这一行的意义是把
    # 「uci 写了 proto=all」和「nft 里真的没有 l4proto 限制」分开说清楚 ——
    # 出问题时不至于再靠人去猜是没写还是没生效。只报告，不参与判定。
    [ "${_nft_reported:-0}" = 1 ] || _nft_fw_report

    # 【v.108.33】落地复核：本轮 build 过的节点必须在 flush 之后真的生效。
    # 这一关专门抓「build 返回 0、配置却没写成」——以前只有 30 轮后的体检能发现。
    if ! _post_verify_after_boot; then
        log "[复核] 有节点构建后始终不生效，引导按失败退出"
        exit 1
    fi

    # 【v.108.51】凭据持久副本：放在 _stamp_write 之前。刷机后 /srv 全丢，
    # 只有 /etc/config 能活下来；这一步把「本轮已验证可用」的 CAPI 凭据存到那里，
    # 下一次刷机的 build_rootfs → _cred_restore 才有的可恢复。
    # 排在 stamp 之前是因为：stamp 写入失败会 exit 1，那时凭据仍应被保住。
    _cred_keep_save || log "[凭据] 持久副本未建立，刷机后需重新 register/enroll"

    # 链路全通：置位 installed（enroll 是网站人工面，不计入安装成功判据）
    # 【v.108.30】installed 是探针与「重装自愈」的共同前提：写不进去，探针会一直等
    # （v.108.30 起改成补印重跑，但那是兜底），下次开机又会当没装过整趟重来。
    # 以前这里 `|| true` 把它咽了，退出码 0 报成功 —— 失败必须返回 1。
    # 【v.108.32】顺序上排在 WAN 收口之后：收口不通过说明这轮没达到「旁路由」这个前提，
    # 先写 installed 等于给一台还没锁住 WAN 的机器盖章。
    if ! _stamp_write; then
        log "[stamp] installed 落位失败（$STAMP_FILE），引导按失败退出"
        exit 1
    fi

    # 【v.108.44】成功路径才清账：失败退出时残留的 dirty 是现场证据，不能抹。
    # 清掉的是「最后一次 flush 之后才置位、且不归 uci 管」的那些（实测是 capi_release）。
    _settle_dirty

    if [ -x /etc/init.d/crowdsec-lxc-probe ]; then
        run /etc/init.d/crowdsec-lxc-probe enable >/dev/null 2>&1 || true
        run /etc/init.d/crowdsec-lxc-probe start  >/dev/null 2>&1 || true
        log "[探针] 运行期 last_pull 探针已启用（crowdsec-lxc-probe）"
    fi

    log "引导结束"
    exit 0
}

# ---- 网络基线模式（v.107.6）：只校准路由器网络，不碰容器 ----
# rc.local 在「无镜像且无 rootfs」时改走这里（见 rc.local 的 BOOT_MODE）。
# v.107.7 起容器恒内置、没有开关，所以走到这条分支 = 镜像没进固件（异常）。
# 即便如此也先把网络配好：网络是唯一的远程入口，丢了就只剩接显示器。
if [ "${1:-}" = "--net-only" ]; then
    NET_ONLY=1
    shift
fi

# ---- 运行期探针入口（v.82）：供 crowdsec-lxc-probe.sh 复用 last_pull 判定逻辑 ----
# 单一事实源：探针只验证 last_pull，判定标准（bouncer_pulling 的新鲜度阈值，
# 默认 60s = 6 个 10s 心跳周期，见 _BP_DEFAULT_MAX_AGE）与引导
if [ "${1:-}" = "--probe-check" ]; then
    bouncer_pulling
    exit $?
fi

# ---- 下发面健康检查（探针每 10 分钟一次，v.180.198）----
# 为什么不能塞进 --probe-check：那条路径 60 秒一轮且只读，而这里要重启服务。
# 为什么不能用 last_pull 判：netlink 脱节时 **拉取是成功的**，last_pull 照常刷新。
# 判据改成直接数 bouncer 日志里的 netlink 错误 —— 它是最接近症状的信号：
#   真机 2026-10-30 实测 cscli decisions list 报「No active decisions」，
#   而 cscli metrics 同时报 60315 条、内核 nft 有 69232 个元素 —— 列表视图不可信。
# 退出码：0=无需动作，1=动过手，其余=检查本身异常。
if [ "${1:-}" = "--bouncer-heal" ]; then
    # 【2026-11-09 用户定】与引导共用同一把锁（路径与 probe 的 $LOCK 一致）：
    # 原来不拿锁，体检组正在重启容器时这里同时重启 bouncer —— 日志交错，
    # 而且重启后很可能拉不到还没起来的 LAPI，白重启一次。
    # 拿不到锁就退出：下发面检查不差这 10 分钟。
    _bh_lock="/tmp/.crowdsec-lxc-bootstrap.lock"
    if ! mkdir "$_bh_lock" 2>/dev/null; then
        log "[bouncer] 引导进行中（持锁），本轮跳过下发面检查"
        exit 0
    fi
    printf '%s\n' "$$" > "$_bh_lock/pid" 2>/dev/null
    date +%s > "$_bh_lock/ts" 2>/dev/null
    trap "rm -rf '$_bh_lock' 2>/dev/null" EXIT INT TERM HUP
    if ! cs_active_on_host; then
        log "[bouncer] 进程未运行（不是下发问题），交由 _ensure_bouncer_service"
        _ensure_bouncer_service
        exit 0
    fi
    # 【2026-10-30.180.198】判据改为数全部 netlink 错误。
    # 为什么弃用 cscli decisions list：真机 2026-10-30 实测该命令返回
    # 「No active decisions」，而同一时刻 cscli metrics 报 Local API Decisions
    # 60315 条、内核 nft 有 69232 个元素 —— cscli 的列表视图与 bouncer 实际
    # 拉到的数据不是一回事。拿它当判据会让这层兜底永久失效（_bh_dec 恒为 0）。
    # 现在直接数 bouncer 日志里的 netlink 错误，不再限定子类：bouncer 换版本时
    # 错误文案可能改（ENOENT -> 别的），限定子类会静默失效，只认大前缀才不会漏。
    # 代价：不可自愈的错误也会触发重启，靠下面的存活时间冷却（默认 1 小时）限流。
    # awk 里的 n=0 是幂等关键：重启后日志末尾会追加新的 Starting，计数自然
    # 归零，既不依赖状态文件，也不会重启完下一轮又把同一批旧错误数一遍反复重启。
    _bh_err="$(tail -n 500 "$_BC_LOG" 2>/dev/null | awk '/Starting crowdsec-firewall-bouncer/{n=0; next} /netlink receive: /{n++} END{print n+0}')"
    case "$_bh_err" in ''|*[!0-9]*) _bh_err=0 ;; esac
    # 【2026-11-09 用户定】阈值 2 -> 1：单次 netlink 错误即重启 bouncer。
# 用户实测：>=2 要等约 30 分钟，>=1 约 20 分钟即可触发。
# 兜底仍在下方：进程存活不足 CS_BOUNCER_HEAL_COOLDOWN（默认 3600s）直接跳过，
# 所以最坏情况是每小时最多重启一次，不会被单次抖动打穿。
if [ "$_bh_err" -ge 1 ]; then
        # 【v.180.198】重启冷却：进程存活不足 _bh_cool 秒就不动手（默认 3600）。
        # 目的：把「修不好的错误 -> 每 10 分钟重启一次」压到「最坏 1 小时 1 次」，
        # 而检查频率不变（判据仍每 10 分钟跑，健康时开销为零）。
        # 取存活时间用 /proc/<pid>/stat 的 starttime 与 /proc/uptime 相减，
        # 不依赖 ps -o etimes（busybox 不一定编了 -o）。
        _bh_cool="${CS_BOUNCER_HEAL_COOLDOWN:-3600}"
        _bh_pid="$(run pgrep -f "crowdsec-firewall-bouncer" 2>/dev/null | head -n1)"
        if [ -n "$_bh_pid" ] && [ -r "/proc/$_bh_pid/stat" ]; then
            _bh_start="$(awk -F') ' '{split($2,f," "); print f[20]}' "/proc/$_bh_pid/stat" 2>/dev/null)"
            _bh_up="$(awk '{print int($1)}' /proc/uptime 2>/dev/null)"
            if [ -n "$_bh_start" ] && [ -n "$_bh_up" ]; then
                case "${_bh_start}${_bh_up}" in
                *[!0-9]*) : ;;
                *)
                    _bh_age=$(( _bh_up - _bh_start / 100 ))
                    # 只有「系统已运行超过 _bh_cool」才把进程短寿当成 heal 重启的结果：
                    # 开机早期进程本来就活不到 1 小时，那种情况必须照常修
                    # （2026-10-27 那次故障就发生在 bouncer 启动后 2 分钟）。
                    if [ "$_bh_age" -lt "$_bh_cool" ] && [ "$_bh_up" -ge "$_bh_cool" ]; then
                        log "[bouncer] 进程仅存活 ${_bh_age}s（系统已运行 ${_bh_up}s，刚被重启过）-> 本轮跳过重启"
                        exit 0
                    fi
                    ;;
                esac
            fi
        fi
        _bh_kind="$(tail -n 500 "$_BC_LOG" 2>/dev/null | grep -o 'netlink receive: [a-zA-Z ]*' | tail -1 | sed 's/^netlink receive: //')"
        log "[bouncer] ** 本轮进程已 ${_bh_err} 次 netlink 错误（最近：${_bh_kind:-未知}）-> 重启 bouncer"
        _bouncer_service_restart >/dev/null 2>&1 || true
        sleep 2
        if cs_active_on_host; then
            log "[bouncer] 重启后进程在跑；netlink 错误是否消失看下一轮（10 分钟后）"
        else
            log "[bouncer] 重启后进程未起来（交给探针与下一轮）"
        fi
        exit 1
    fi
    exit 0
fi

# ---- 全量验证模式（v.108.25）----
# 既然每个节点都已经是「先验现场、有就过」，那整个脚本其实随时可以退化成一次体检：
# 从 img_migrate 到 capi_release 全跑一遍 verify_*，不写任何一个字节。
# 用途：探针定期跑一次就知道「这台机器有没有漂移」；人也随时能问同样的问题。
# 有项不符时返回 1，修复仍然交给正常引导（它自己会按需补那几项）。
# 【v.108.29】WAN 段已经不在 DAG 里了（主流程无条件删），但「它确实清空了」这件事
# 仍然必须能被体检发现。否则 --verify-only 会在 WAN 面开着的时候报告「全达标」——
# 又一处假绿，而且是最不该有的那种：这台机器会不会自己拨号，体检说了算。
# 只读：不删不写，跟其他 audit 项一个口径。
# 【v.108.32】原来只验网络段。段删干净、firewall 里还挂着 `list network 'wan' 'wan6'`，
# 体检照样报绿 —— 而那条引用正是「这台机器还在按有 WAN 的世界生成规则」的证据。
# 现在三项一起验：段、引用、内核接口。
audit_wan_purged() {
    run uci show network >/dev/null 2>&1 || return 1
    # ① network 里不许有 wan / wan6 段（v.108.27 定死了整段不存在，不是 disabled）
    [ -z "$(_wan_sections)" ] || return 1
    # ② firewall 里不许再有指向这两个接口的 list network 引用（v.108.32）
    [ -z "$(_wan_refs)" ] || return 1
    # ③ 内核里不许冒出 wan / wan6 接口（v.108.32）
    [ -z "$(_wan_ifaces)" ] || return 1
    return 0
}

_audit_all() {
    _ab=0
    _an=0
    _askip=0
    for _n in $DAG_NODES; do
        # 【v.108.61】enroll 不纳入体检：它要联网、要人在 app.crowdsec.net 点 Accept，
        # 不确定性太大。而且 --verify-only 是独立进程，_ENROLL_TRIED 恒为 0 →
        # 只要「有注册码且尚未注册」就恒返回 1，体检于是**永远**报不符，
        # 探针每 30 轮（≈30 分钟）白跑一次完整引导，日志里还看不出原因。
        # 必须打「跳过」而不是「OK」：把没验的报成达标，就是「不报错、只给错误答案」。
        case "$_n" in
        enroll)
            printf '[审计] %-16s 跳过（需联网，不入体检；注册状态见引导日志）\n' "$_n"
            _askip=$((_askip + 1))
            continue
            ;;
        esac
        _an=$((_an + 1))
        if "verify_$_n" >/dev/null 2>&1; then
            printf '[审计] %-16s OK\n' "$_n"
        else
            printf '[审计] %-16s 不符\n' "$_n"
            _ab=$((_ab + 1))
        fi
    done
    _an=$((_an + 1))
    if audit_wan_purged; then
        printf '[审计] %-16s OK\n' "wan_purged"
    else
        printf '[审计] %-16s 不符\n' "wan_purged"
        _ab=$((_ab + 1))
    fi
    printf '[审计] 共 %s 项，不符 %s 项' "$_an" "$_ab"
    [ "$_askip" -gt 0 ] && printf '（另有 %s 项跳过：enroll 需联网）' "$_askip"
    printf '\n'
    [ "$_ab" -eq 0 ]
}

if [ "${1:-}" = "--verify-only" ]; then
    # 体检模式：调用方（探针 / 人）信的是「一个字节都不写」，verify_enroll 里
    # 「已注册就清明文注册码」这一步必须在这里关掉。
    _VERIFY_ONLY=1
    _audit_all
    exit $?
fi

# ---- 测试钩子：只要函数定义，不执行 main ----
# v.98 起 tests/ 里有几套用例要「跑生产函数的真实逻辑，但不碰真系统」。
if [ "${1:-}" = "--only-funcs" ]; then
    sed -n '1,/^main "\$@"$/p' "$0" | sed '$d'
    exit 0
fi

# ---- 日志封顶：真引导才截，--verify-only / --probe-check 早就 exit 了 ----
_boot_log_trim

main "$@"
