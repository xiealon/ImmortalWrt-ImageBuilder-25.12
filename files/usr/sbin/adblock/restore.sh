#!/bin/sh
# adblock/restore.sh —— adblock 分类总调度
#
# 顺序：
#   01-pkg     包先到位（--tree 或 --force）
#   02-config  uci 三项结构值
#   03-rules   四个 conffiles 缺失才补
#   90-check   复判
#
# 用法：
#   ./restore.sh              全流程
#   ./restore.sh --list       列出步骤
#   ./restore.sh --step 02-config
#   ./restore.sh --rebuild    删了重装（最后一招，本组专属）
#   ./restore.sh --check      透传 90-check 的四态码
#
# 退出码：0 成功 / 1 失败 / 2 用法错误

_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/_lib.sh"

STEPS="01-pkg 02-config 03-rules"

case "${1:-}" in
--list)
    for _s in $STEPS; do
        _f="$_here/$_s.sh"
        [ -f "$_f" ] || { printf '%-14s (缺失)\n' "$_s"; continue; }
        printf '%-14s %4d 行  %s\n' "$_s" "$(wc -l < "$_f")" \
            "$(sed -n '2s/^# //p' "$_f")"
    done
    printf '%-14s %4d 行  %s\n' "05-rebuild" "$(wc -l < "$_here/05-rebuild.sh")" "删了重装（最后一招）"
    exit 0
    ;;
--step)
    _t="${2:-}"
    [ -n "$_t" ] || { echo "用法：$0 --step 01-pkg" >&2; exit 2; }
    [ -f "$_here/$_t.sh" ] || { echo "没有这一步：$_t" >&2; exit 2; }
    exec sh "$_here/$_t.sh"
    ;;
--rebuild)
    exec sh "$_here/05-rebuild.sh"
    ;;
--check)
    exec sh "$_here/90-check.sh"
    ;;
"")
    ;;
*)
    echo "用法：$0 [--list|--step <名字>|--rebuild|--check]" >&2
    exit 2
    ;;
esac

sh "$_here/01-pkg.sh"    || { log "装回未成功，继续补配置（配置不依赖包装成功）"; }
sh "$_here/02-config.sh" || { log "配置写入失败"; exit 1; }
sh "$_here/03-rules.sh"  || { log "规则文件补齐失败"; exit 1; }

_rc=0
sh "$_here/90-check.sh" || _rc=$?
case "$_rc" in
0) log "adblock 全好（三包在位、程序文件齐、配置对）"; exit 0 ;;
1) log "adblock 仍有包缺失"; exit 1 ;;
3) log "adblock 程序文件仍缺（包在册但文件不全）"; exit 1 ;;
4) log "adblock 配置仍不对"; exit 1 ;;
*) log "adblock 判定异常 rc=$_rc"; exit 1 ;;
esac
