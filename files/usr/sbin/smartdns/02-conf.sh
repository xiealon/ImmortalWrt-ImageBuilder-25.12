#!/bin/sh
# smartdns/02-conf.sh —— 步骤②：补 /etc/smartdns/ 规则文件
#
# 拆分自 pkg-restore-smartdns.sh 的 _sd_conf()。
#
# 判据：不存在才补，存在一律不动（哪怕被清成 0 字节）。
# 为什么单独开口子：这 5 个文件在 conffiles 里，通用恢复按「不覆盖用户配置」
# 一律跳过 —— 文件真没了时那条保护就退化成「永远不修」。
# 真机 2026-10-28 的死循环就是这么来的：
#   smartdns: open config file 'address.conf' failed → procd 记 crash loop
#   → 53 全空 → 探针判进程不在 → 重跑 bootstrap → 再挂。
#
# 两步结构：--check 只判缺哪个文件（判定在 _lib.sh 的 _sd_conf_ok）
# 退出码：--check 0 齐 / 1 缺；修复 0 补齐或本来就不缺 / 1 失败

_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/_lib.sh"

# 两步结构：--check 只判不写，无参数 = 修复
case "${1:-}" in
--check)
    _sd_conf_ok && exit 0
    exit 1
    ;;
"")
    ;;
*)
    echo "用法：$0 [--check]" >&2
    exit 2
    ;;
esac

_n=0
for _f in $SD_CONF_FILES; do
    [ -e "$PKGROOT/etc/smartdns/$_f" ] && continue
    [ -e "$ROMDIR/etc/smartdns/$_f" ] || continue
    mkdir -p "$PKGROOT/etc/smartdns" 2>/dev/null
    cp -a "$ROMDIR/etc/smartdns/$_f" "$PKGROOT/etc/smartdns/$_f" 2>/dev/null \
        && _n=$((_n + 1))
done
[ "$_n" -gt 0 ] && log "从只读基座恢复 smartdns 规则文件：$_n 个（/etc/smartdns/）"
exit 0
