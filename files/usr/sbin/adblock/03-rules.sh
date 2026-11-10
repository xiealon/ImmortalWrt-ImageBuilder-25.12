#!/bin/sh
# adblock/03-rules.sh —— 步骤③：补 conffiles 保护的四个文件（缺失才补）
#
# 2026-11-10 新增。
#
# 这四个文件在 adblock 的 conffiles 里：
#   /etc/config/adblock
#   /etc/adblock/adblock.allowlist
#   /etc/adblock/adblock.blocklist
#   /etc/adblock/adblock.custom.feeds
# apk 的保护是「改过就不覆盖、没改才删」——文件真没了的时候，
# 那条保护会退化成「永远不修」，于是每轮启动都缺规则。
#
# 判据：**不存在才补**，存在一律不动（哪怕被清成 0 字节）。
# 这一条是硬约束 —— adblock.allowlist / blocklist / custom.feeds 是用户自己加的
# 规则，覆盖式恢复会把用户白名单换成一份出厂空白名单，等于保护动作制造故障。
#
# 退出码：0 补齐或本来就不缺 / 1 失败

_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/_lib.sh"

_n=0
for _f in $_ADB_CONF_FILES; do
    [ -e "$PKGROOT$_f" ] && continue
    [ -e "$ROMDIR$_f" ] || continue
    mkdir -p "$PKGROOT$(dirname "$_f")" 2>/dev/null
    cp -a "$ROMDIR$_f" "$PKGROOT$_f" 2>/dev/null && {
        _n=$((_n + 1))
        log "补回 $_f"
    }
done
[ "$_n" -gt 0 ] || log "无需补文件（四个 conffiles 都在位）"
exit 0
