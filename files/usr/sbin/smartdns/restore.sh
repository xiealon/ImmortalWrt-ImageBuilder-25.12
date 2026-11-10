#!/bin/sh
# smartdns/restore.sh —— smartdns 分类总调度
#
# 原 pkg-restore-smartdns.sh 的 --config / --repair 现在就是这里。
# 两个名字保留（rc.local 开机配一次用 --config，探针兜底用 --repair），走同一条路。
#
# 顺序（不能换）：
#   01-pkg       包先到位，否则后面 uci 全是空转
#   02-conf      规则文件先补齐 —— smartdns 起不来的头号原因是 conf-file 指向的文件没了
#   03-localrule custom.conf 补 localhost 行（adblock 探活用）
#   04-config    主段
#   05-upstream  上游 6 条
#   06-apply     commit + 重启 + 等 53
#
# 04/05 任何一步失败都 revert 暂存，不把半套配置带上线。
#
# 用法：
#   ./restore.sh            全流程（等价原 --config / --repair）
#   ./restore.sh --list     列出步骤与各自行数
#   ./restore.sh --step 04  只跑某一步
#
# 退出码：0 成功 / 1 失败 / 2 用法错误

_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/_lib.sh"

STEPS="01-pkg 02-conf 03-localrule 04-config 05-upstream 06-apply"

case "${1:-}" in
--list)
    for _s in $STEPS; do
        _f="$_here/$_s.sh"
        [ -f "$_f" ] || { printf '%-14s (缺失)\n' "$_s"; continue; }
        printf '%-14s %4d 行  %s\n' "$_s" "$(wc -l < "$_f")" \
            "$(sed -n '2s/^# //p' "$_f")"
    done
    exit 0
    ;;
--step)
    _t="${2:-}"
    [ -n "$_t" ] || { echo "用法：$0 --step 01-pkg" >&2; exit 2; }
    [ -f "$_here/$_t.sh" ] || { echo "没有这一步：$_t" >&2; exit 2; }
    exec sh "$_here/$_t.sh"
    ;;
"")
    ;;
*)
    echo "用法：$0 [--list|--step <名字>]" >&2
    exit 2
    ;;
esac

# ---- 全流程 ----

# 包不在位就先装：后面所有 uci 操作都建立在这包上
if ! _sd_pkg_ok; then
    log "smartdns 不在位，先从只读基座装回"
    sh "$_here/01-pkg.sh" || { log "装包失败（只读基座里没有 smartdns）"; exit 1; }
    _sd_pkg_ok || { log "装包后仍判不在位，放弃写配置"; exit 1; }
fi

sh "$_here/02-conf.sh" || { log "规则文件补齐失败"; exit 1; }
sh "$_here/03-localrule.sh" || { log "localhost 本地解析写入失败"; _sd_discard; exit 1; }
sh "$_here/04-config.sh"    || { log "主配置段写入失败"; _sd_discard; exit 1; }
sh "$_here/05-upstream.sh"  || { log "上游表写入失败，不接管 DNS"; _sd_discard; exit 1; }
sh "$_here/06-apply.sh"     || exit 1

log "smartdns 已接管 DNS：6 条上游（国内 3 DoT / 境外 2 DoH+1 DoT），dnsmasq 由 init 让出 53"
log "localhost 本地解析在位：adblock 的 nslookup localhost. 探活可通过"
exit 0
