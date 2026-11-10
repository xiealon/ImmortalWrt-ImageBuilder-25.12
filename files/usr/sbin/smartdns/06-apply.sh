#!/bin/sh
# smartdns/06-apply.sh —— 步骤⑥：commit + 重启 + 等 53 落地
#
# 拆分自 pkg-restore-smartdns.sh 的 _sd_apply()。
#
# 不手动 restart dnsmasq：init 的 start_service 只要见到 port=53 且
# auto_set_dnsmasq=1，就会自己把 dnsmasq 的 port 置 0 并重启它，顺序由 init 保证。
# 前提（init 里的硬条件）：set_main_dns 开头 `[ -z "$hostip" ] && return`，
# hostip 取自 network.lan.ipaddr —— lan 没静态地址时 init 静默跳过、谁都不让位，
# 那时 53 仍被 dnsmasq 占着，由本脚本的失败分支报出来。
#
# 【v.180.198】不回滚（用户 2026-10-31 定）：smartdns 必须占 53。
# 旧行为是「init 让出 53 后若 smartdns 起不来，就把 53 还给 dnsmasq」，删掉的理由：
#   · 与固件的 DNS 取向冲突 —— 53 一旦被 dnsmasq 拿回去，分流与拦截全部失效，
#     且没有任何机制再把它拿回来（set_main_dns 只在 restart smartdns 时判断）；
#   · 回滚把「起不来」这件必须立刻知道的事，变成一条「已回滚」日志就算了结。
# 现在失败只报错并返回 1，由探针下一轮重试。
#
# 退出码：0 53 已归 smartdns / 1 15 秒内没监听或 commit 失败

_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/_lib.sh"

# 两步结构：--check 只判不写，无参数 = 修复
case "${1:-}" in
--check)
    _sd_serve && exit 0
    exit 1
    ;;
"")
    ;;
*)
    echo "用法：$0 [--check]" >&2
    exit 2
    ;;
esac

uci commit smartdns || { log "uci commit smartdns 失败"; _sd_discard; exit 1; }
[ -x /etc/init.d/smartdns ] || { log "没有 /etc/init.d/smartdns，无法重启"; exit 1; }

/etc/init.d/smartdns restart >/dev/null 2>&1
_sda_i=0
while [ "$_sda_i" -lt 15 ]; do
    _sd_serve && { log "smartdns 已接管 53"; exit 0; }
    sleep 1
    _sda_i=$((_sda_i + 1))
done

log "配置已写入，但 53 端口 15 秒内没有监听（端口被占、配置语法或动态库问题）"
exit 1
