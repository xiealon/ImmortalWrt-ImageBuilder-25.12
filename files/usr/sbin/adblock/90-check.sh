#!/bin/sh
# adblock/90-check.sh —— 只判定，一个字节都不写
#
# 四态退出码（与 smartdns/90-check.sh 同口径，调用方按「坏在哪一层」选修法）：
#   0 = 包齐、程序文件齐、配置对
#   1 = 包不在册                      —— 走 01-pkg.sh（连依赖装）
#   3 = 包在册、程序文件缺            —— 走 01-pkg.sh（内部转 --force）
#   4 = 包与文件都齐，配置不对        —— 走 02-config.sh（只改三项结构值）
#
# 用法：
#   ./90-check.sh     四态判定
#   ./90-check.sh -v  带逐项明细（排障用，始终 0）

_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/_lib.sh"

_pkg_missing() {
    for _p in $_PA_ADBLOCK; do
        _pa_should "$_p" || continue
        _pa_installed "$_p" || { printf '%s\n' "$_p"; return 0; }
    done
    return 0
}

_file_missing() {
    for _p in $_PA_ADBLOCK; do
        _pa_should "$_p" || continue
        _pa_installed "$_p" || continue
        _pa_files_ok "$_p" || { printf '%s\n' "$_p"; return 0; }
    done
    return 0
}

_cfg_ok() {
    _seg=$(uci -q show adblock 2>/dev/null | sed -n 's/^adblock\.\([^.=]*\)=adblock$/\1/p' | head -n1)
    [ -n "$_seg" ] || return 1
    [ "$(uci -q get "adblock.$_seg.adb_enabled")" = "1" ] || return 1
    [ "$(uci -q get "adblock.$_seg.adb_dns")" = "smartdns" ] || return 1
    return 0
}

case "${1:-}" in
-v|--list)
    for _p in $_PA_ADBLOCK; do
        _s="固件未带"
        if _pa_should "$_p"; then
            if ! _pa_installed "$_p"; then
                _s="缺失"
            elif ! _pa_files_ok "$_p"; then
                _s="文件缺失"
            else
                _s="在位"
            fi
        fi
        printf '%-34s %s\n' "$_p" "$_s"
    done
    if _cfg_ok; then
        printf '%-34s %s\n' "uci 配置" "对"
    else
        printf '%-34s %s\n' "uci 配置" "不对（enabled/dns）"
    fi
    exit 0
    ;;
"")
    [ -z "$(_pkg_missing)" ] || exit 1
    [ -z "$(_file_missing)" ] || exit 3
    _cfg_ok || exit 4
    exit 0
    ;;
*)
    echo "用法：$0 [-v]" >&2
    exit 2
    ;;
esac
