#!/bin/sh
# 【2026-11-21 用户定】adblock 只做**包级保护**：包要装，但默认不启用。
#
# 为什么需要它：adblock 包自带的 /etc/config/adblock 出厂就是 adb_enabled='1'，
# 而我们的策略是「不预置任何配置」——不预置的后果就是吃包的默认值，于是刷完
# 就自己开着。这里在首次开机把它关掉。
#
# uci-defaults 只跑一次（跑完自删），之后你在 LuCI / uci 里手动打开不会被覆盖；
# 下次刷机又会回到「默认关」。
[ -f /etc/config/adblock ] || exit 0
uci -q get adblock.global.adb_enabled >/dev/null 2>&1 || exit 0

rc=0
uci set adblock.global.adb_enabled='0' || rc=1
# 触发器/后端一起归零，避免「关着但还在跑后台更新」
for opt in adb_trigger adb_backend adb_dns; do
    uci -q get "adblock.global.$opt" >/dev/null 2>&1 && uci set "adblock.global.$opt"=''
done
uci commit adblock || rc=1

/etc/init.d/adblock stop >/dev/null 2>&1 || true
/etc/init.d/adblock disable >/dev/null 2>&1 || true
rm -f /tmp/adb_list.overall /tmp/smartdns/adb_list.overall 2>/dev/null || true

[ "$rc" = 0 ] && logger -t adblock-off "adblock 已按固件默认策略关闭（包级保护，不启用）" 2>/dev/null || true
exit "$rc"
