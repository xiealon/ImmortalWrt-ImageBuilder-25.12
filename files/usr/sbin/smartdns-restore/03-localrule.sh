#!/bin/sh
# smartdns/03-localrule.sh —— 步骤③：补 custom.conf 的 localhost 行
#
# 拆分自 pkg-restore-smartdns.sh 的 _sd_localrule_ok() / _sd_localrule()。
#
# 为什么需要它：不少脚本把 localhost 当 DNS 探活域名（`nslookup localhost.`，
# 硬编码写死在脚本里）。smartdns 若对 localhost 回 NXDOMAIN，nslookup 退出码 1，
# 会被判成「DNS 后端没起来」：30 次轮询 × 1 秒后打一条假失败，功能其实没坏，
# 只是白白等 30 秒。给 localhost 一条本地解析即可。
#
# 判据：整行精确匹配（grep -xF），不是子串 ——
# 否则 address /localhost/127.0.0.2 这种也会被判成已配好。
#
# 两步结构：--check 只判行在不在；无参数 = 补行
# 退出码：--check 0 在 / 1 不在；修复 0 已生效或写入成功 / 1 写入失败

_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/_lib.sh"

# 两步结构：--check 只判不写，无参数 = 修复
case "${1:-}" in
--check)
    _sd_localrule_ok && exit 0
    exit 1
    ;;
"")
    ;;
*)
    echo "用法：$0 [--check]" >&2
    exit 2
    ;;
esac

# 判定函数 _sd_localrule_ok 在 _lib.sh（90-check 与各步骤共用同一份）
_slr_f="$PKGROOT/etc/smartdns/custom.conf"
[ -d "$PKGROOT/etc/smartdns" ] || mkdir -p "$PKGROOT/etc/smartdns" 2>/dev/null
[ -f "$_slr_f" ] || : >"$_slr_f"
# 原文件末尾没有换行时先补一个，否则新行会粘到最后一行注释上变成废行。
if [ -s "$_slr_f" ] && [ -n "$(tail -c 1 "$_slr_f" 2>/dev/null)" ]; then
    printf '\n' >>"$_slr_f" || exit 1
fi
printf '%s\n' "$_SD_LOCALRULE" >>"$_slr_f" || exit 1
log "已追加 localhost 本地解析（/etc/smartdns/custom.conf）"
exit 0
