#!/bin/sh
# adblock/01-pkg.sh —— 步骤①：把缺的包装回
#
# 拆分自 pkg-restore-apps.sh 的 _pa_repair（adblock 部分）。
#
# 按形态分两条路（原 v.2026-11-09 结论）：
#   ① 包不在册      → --tree，连依赖一起装；
#   ② 包在册、判据没过 → --force，直连 PCR_FORCE=1 → apk fix，按包内容重装，
#                      文件与软链接都会重建。
# 原来一律走 --tree 看似通用，实际对「包在册、只有文件缺失」是空转：
#   --tree → _pr_pkg → 先判 _pr_installed（包在册=真）→ 再判 _pr_files_ok，
#   判据看不见的路径一律当「文件齐」→ 打「已安装，跳过」→ 返回 0，一个字节没写。
#
# 退出码：0 全部在位 / 1 仍有缺

_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/_lib.sh"

case "${1:-}" in
--check)
    _m=$(_adb_missing)
    [ -n "$_m" ] && printf '%s\n' "$_m" >&2
    [ -z "$_m" ] && exit 0 || exit 1
    ;;
esac

_n=0
for _p in $(_adb_missing); do
    _n=$((_n + 1))
    if _pa_installed "$_p"; then
        log "强制重装 $_p（包在册，文件缺失）"
        "$_RESTORE" --force "$_p" || log "强制重装 $_p 没成功"
    else
        log "装回 $_p（包不在册，连依赖一起装）"
        "$_RESTORE" --tree "$_p" || log "装回 $_p 失败（本地包库可能没有它）"
    fi
done
[ "$_n" -gt 0 ] || log "无需装回（三包都在位）"

# 不看装上命令的退出码，只认复判
_m=$(_adb_missing)
[ -z "$_m" ] && exit 0
log "仍有缺：$_m"
exit 1
