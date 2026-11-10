#!/bin/sh
# smartdns/_lib.sh —— 本目录公共定义（被 01~90 各步骤 source）
#
# 拆分来源：pkg-restore-smartdns.sh（538 行 / 15 个函数，2026-11-10 拆）
# 原则：只搬不改。变量名、判据、退出码、注释口径全部照原样，
#       唯一新增的是 _sd_discard（原脚本已有，搬来这里供各步骤共用）。
#
# 调用方式（每个步骤脚本开头两行）：
#   _here=$(cd "$(dirname "$0")" && pwd)
#   . "$_here/_lib.sh"

set -u
ROMDIR="${ROMDIR:-/rom}"
PKGROOT="${PKGROOT:-}"

# 通用恢复脚本的查找顺序（原 v.180.147）：
#   ① 显式 RESTORE_BIN
#   ② /usr/sbin/pkg-restore.sh —— 固件里的正式位置
#   ③ 与本脚本同目录 —— 两个脚本一起被拷到 /tmp 单独验时的情况。
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
SD_CONF_FILES="address.conf blacklist-ip.conf custom.conf domain-block.list domain-forwarding.list"

# localhost 本地解析 —— adblock 探活的活路（原 L83-99 依据整段保留在原脚本，
# 这里只留判据用的整行文本）。落点是 custom.conf 而不是 uci：
# uci 的 domain-rule 段 init 不认，写了也白写；init 生成的 smartdns.conf 里
# 有 `conf-file /etc/smartdns/custom.conf`，往该文件追加整行才生效。
_SD_LOCALRULE="address /localhost/127.0.0.1"

# 包在不在：二进制 + init 可执行，再做一次冒烟抓动态库缺口。
# 判据取向不变：只有明确加载错误才判缺，其余异常一律放过。
_sd_pkg_ok() {
    [ -x "$PKGROOT/usr/sbin/smartdns" ] && [ -x "$PKGROOT/etc/init.d/smartdns" ] || return 1
    case "$("$PKGROOT/usr/sbin/smartdns" -v 2>&1)" in
        *"Error loading"*|*"No such file"*|*"not found"*|*"cannot open shared object"*)
            return 1 ;;
    esac
    return 0
}

# 服务生不生效：pidof + 「53 的 socket inode 反查属主」。
# 只读判定，不启动、不重启。重启只发生在 06-apply.sh。
# 为什么不能只用 netstat 判 :53 —— dnsmasq 占着 53 时旧判据照样通过（2026-11-10 实测）。
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

# 丢弃尚未 commit 的 smartdns 改动。/tmp/.uci 是 uci 的暂存目录，
# 本进程 exit 后脏数据仍在，下次任何人 commit smartdns 都会把它带进去。
# 只 revert smartdns —— dhcp 由 smartdns 的 init 改，碰它会误伤 LuCI 里未提交的改动。
_sd_discard() {
    uci -q revert smartdns 2>/dev/null
    return 0
}

# =====================================================================
# 【2026-11-10】两步结构支持：判定函数集中在这里
#
# 为什么放 _lib 而不是各步骤脚本里：
#   90-check.sh 的四态（0/1/3/4）是探针的接口，不能变；而 01~06 又要能各自
#   单独 --check。两处若各写一份判据，改一处忘另一处就会「检查说好、修复说坏」，
#   表现为每轮都重写一遍配置、永远不收敛。所以判定只此一份。
# =====================================================================

# 上游基准表（用户 2026-11-07 定，内容一字未改；注释行保留记录选型理由）。
# 05-upstream.sh 按它写入，_sd_upstream_ok 按它比对 —— 同一份表，不会漂移。
sd_upstream_table() {
    cat <<'SD_UPSTREAM_EOF'
# 【2026-11-07】CN 组改 DoT：实测本链路 TCP 53 被干扰（阿里/腾讯连上即 RST、
# 百度 SYN 无回应），而 853 端口可达且解析正常（91 B，与 UDP 同长）。
# 只有这 3 条实测可用：阿里 2 条、腾讯 1 条（dot.pub → 120.53.53.53）。
# 百度 / 360 / CNNIC 的 853 不通或解析失败，全部淘汰。
alidns 223.5.5.5 tls CN dns.alidns.com
alidns 223.6.6.6 tls CN dns.alidns.com
dnspod 120.53.53.53 tls CN dot.pub
google 8.8.8.8 tls out dns.google
# out 组：honk 开着时才可达（8.8.8.8 的 853/443、dns.google 的 DoH、
# cloudflare 的 DoH 都能真解析出 91 B；cloudflare 的 853 与 1.1.1.1 的 DoT 均为 0 B）。
# DoH 必须写域名，用 IP 形式（https://8.8.8.8/dns-query）实测 0 B 失败。
google https://dns.google/dns-query https out dns.google
cloudflare https://cloudflare-dns.com/dns-query https out cloudflare-dns.com
SD_UPSTREAM_EOF
}

# 规则文件「基座有、运行期没有」就算不完整。0=齐，1=缺。
# 只看「基座有、运行期没有」：基座本来就没有的不算缺，否则每轮判坏又补不回来。
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

# custom.conf 里必须有一模一样的 localhost 行（整行精确匹配，不是子串）
_sd_localrule_ok() {
    if [ ! -f "$PKGROOT/etc/smartdns/custom.conf" ]; then
        printf '[PKG] 缺文件：/etc/smartdns/custom.conf\n' >&2
        return 1
    fi
    grep -qxF "$_SD_LOCALRULE" "$PKGROOT/etc/smartdns/custom.conf" 2>/dev/null && return 0
    printf '[PKG] 缺 localhost 本地解析：/etc/smartdns/custom.conf\n' >&2
    return 1
}

# 主配置段：逐项比对 04-config.sh 会写的那 12 项（以及必须不存在的 bind）。
# 这 12 项都是「不写就跑不对」的，其余四项（no_cache / no_speed_check /
# no_dualstack_selection / force_aaaa_soa）故意交给 LuCI，这里也不判。
_sd_cfg_ok() {
    _scg_seg=$(uci -q show smartdns 2>/dev/null | sed -n 's/^smartdns\.\([^.=]*\)=smartdns$/\1/p' | head -n1)
    if [ -z "$_scg_seg" ]; then
        printf '[SD] 缺 smartdns 主配置段\n' >&2
        return 1
    fi
    _scg_bad=0
    for _scg_kv in \
        enabled=1 \
        port=53 \
        bind_device=0 \
        auto_set_dnsmasq=1 \
        server_flags=-group\ CN \
        seconddns_enabled=1 \
        seconddns_port=6553 \
        seconddns_tcp_server=1 \
        seconddns_server_group=out \
        cache_size=32768 \
        serve_expired=1 \
        prefetch_domain=1; do
        _scg_k=${_scg_kv%%=*}
        _scg_v=${_scg_kv#*=}
        _scg_cur=$(uci -q get "smartdns.$_scg_seg.$_scg_k" 2>/dev/null)
        if [ "$_scg_cur" != "$_scg_v" ]; then
            printf '[SD] 主配置 %s=%s（应为 %s）\n' "$_scg_k" "${_scg_cur:-空}" "$_scg_v" >&2
            _scg_bad=1
        fi
    done
    if uci -q get "smartdns.$_scg_seg.bind" >/dev/null 2>&1; then
        printf '[SD] 主配置残留 bind（不是 UCI 选项，应为空）\n' >&2
        _scg_bad=1
    fi
    [ "$_scg_bad" = 0 ]
}

# 上游：只判「有没有」，不判「是不是我写的那 6 条」。
#
# 【2026-11-10 用户定】上游属于**设置项**：用户完全可能自己换供应商、加自建 DNS、
# 按分流需要调整分组。按表逐条比对会把这些正常设置判成故障，然后拿全清重建
# 去「修」它 —— 那是保护动作制造出它本来要防的故障。
# 所以这里与探针 _up_watch 的判据保持完全一致：> 0 就算好，一条都不留才判坏。
# 真被删光了（> 0 判据失败），05-upstream.sh 会按表全清重建，恢复默认那 6 条。
# sd_upstream_table() 保留，但只用于写入，不再充当判据。
_sd_upstream_ok() {
    _suo_cnt=$(uci -q show smartdns 2>/dev/null | grep -c '=server$')
    case "$_suo_cnt" in ''|*[!0-9]*) _suo_cnt=0 ;; esac
    if [ "$_suo_cnt" -le 0 ]; then
        printf '[SD] 上游 0 条（至少 1 条才能解析）\n' >&2
        return 1
    fi
    return 0
}
