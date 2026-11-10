#!/bin/sh
# smartdns/04-config.sh —— 步骤④：写主配置段（config smartdns）
#
# 拆分自 pkg-restore-smartdns.sh 的 _sd_cfg_main() / _sd_main_seg()。
#
# 只写 uci 暂存（/tmp/.uci），不 commit —— 落地是 06-apply.sh 的事。
# 单独跑本步骤后若决定不落地，用 `uci revert smartdns` 丢弃。
#
# 两步结构：--check 逐项比对主配置段（判定在 _lib.sh 的 _sd_cfg_ok）
# 退出码：--check 0 达标 / 1 有项不符；修复 0 写入成功 / 1 失败

_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/_lib.sh"

# 两步结构：--check 只判不写，无参数 = 修复
case "${1:-}" in
--check)
    _sd_cfg_ok && exit 0
    exit 1
    ;;
"")
    ;;
*)
    echo "用法：$0 [--check]" >&2
    exit 2
    ;;
esac

# smartdns 主配置段的段名；没有则回空
_sd_main_seg() {
    uci -q show smartdns 2>/dev/null \
        | sed -n 's/^smartdns\.\([^.=]*\)=smartdns$/\1/p' | head -n1
}

_sdc_seg=$(_sd_main_seg)
if [ -z "$_sdc_seg" ]; then
    uci -q add smartdns >/dev/null 2>&1
    _sdc_seg=$(_sd_main_seg)
    [ -n "$_sdc_seg" ] || { log "无法创建 smartdns 主配置段"; exit 1; }
fi

uci -q set "smartdns.$_sdc_seg.enabled=1" || exit 1
uci -q set "smartdns.$_sdc_seg.port=53" || exit 1
# bind 不是 UCI 选项：init 只读 port / bind_device，历史残留的 bind 顺手清掉。
uci -q delete "smartdns.$_sdc_seg.bind" 2>/dev/null
# bind_device=0 → 只生成 bind [::]:53，br-lan / lxcbr0 / docker0 一律可达。
# 设成 1 时 init 只绑 br-lan + lo，容器拿 lxcbr0 地址来查会被丢掉。
uci -q set "smartdns.$_sdc_seg.bind_device=0" || exit 1
# auto_set_dnsmasq=1：port=53 时由 init 把 dhcp.@dnsmasq[0].port 置 0 并重启 dnsmasq。
# 显式写死，防止在 LuCI 里误关一次就永久失效。
uci -q set "smartdns.$_sdc_seg.auto_set_dnsmasq=1" || exit 1
# 组名 CN / out（用户 2026-11-07 定）：bind 行的 -group 来自这里，
# 上游段的 server_group 必须逐字一致，大小写不同就是两个组 —— 对不上则解析全空。
uci -q set "smartdns.$_sdc_seg.server_flags=-group CN" || exit 1
# 第二服务器 = 6553，只走 out 组、不缓存：给 honk 的 dae 在分流后使用。
# init 里 seconddns_enabled 默认 0，不写则重刷后 6553 根本不监听。
uci -q set "smartdns.$_sdc_seg.seconddns_enabled=1" || exit 1
uci -q set "smartdns.$_sdc_seg.seconddns_port=6553" || exit 1
uci -q set "smartdns.$_sdc_seg.seconddns_tcp_server=1" || exit 1
uci -q set "smartdns.$_sdc_seg.seconddns_server_group=out" || exit 1
# no_cache / no_speed_check / no_dualstack_selection / force_aaaa_soa 故意不写：
# 用户 2026-11-07 定，这四项交给 LuCI 自己点，脚本一写就每轮覆盖等于锁死开关。
uci -q set "smartdns.$_sdc_seg.cache_size=32768" || exit 1
uci -q set "smartdns.$_sdc_seg.serve_expired=1" || exit 1
uci -q set "smartdns.$_sdc_seg.prefetch_domain=1" || exit 1

log "主配置段已写：$_sdc_seg（enabled=1 port=53 bind_device=0 auto_set_dnsmasq=1 seconddns=6553）"
exit 0
