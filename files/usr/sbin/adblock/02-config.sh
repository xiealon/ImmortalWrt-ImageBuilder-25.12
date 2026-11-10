#!/bin/sh
# adblock/02-config.sh —— 步骤②：写 uci 配置（结构项，不碰用户的 feed 选择）
#
# 2026-11-10 新增。拆自 pkg-restore-apps.sh 里「adblock 只判包、不管配置」的缺口。
#
# 口径（保守，与 smartdns 的「写死纠正」不同）：
#   只写三项结构性的，其余一律不动 —— adb_feed / adb_sources / 各类 adb_* 开关
#   是用户在 LuCI 里选出来的，脚本一写就每轮覆盖，等于把开关锁死。
#
# 为什么这三项要写死：
#   adb_enabled=1    adblock 是本固件的拦截层，关掉等于整套 crowdsec 之外的
#                    第二道拦截面失效。段存在但为 0 时改回 1。
#   adb_dns=smartdns 本固件的 DNS 后端就是 smartdns（53 归它），
#                    填 dnsmasq 会让列表生成了却没人加载。
#   adb_fetchcmd=curl 固件里带的是 curl；用 wget 时 busybox 版缺 TLS 会拉不到 feed。
#
# 段不存在时按出厂默认建段（feed 取 adguard 三条，与现场一致），
# 段已存在时**只纠正上面三项**，绝不重写 feed 列表。
#
# 退出码：0 写入成功 / 1 失败

_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/_lib.sh"

_seg=$(uci -q show adblock 2>/dev/null | sed -n 's/^adblock\.\([^.=]*\)=adblock$/\1/p' | head -n1)

if [ -z "$_seg" ]; then
    uci -q add adblock >/dev/null 2>&1
    _seg=$(uci -q show adblock 2>/dev/null | sed -n 's/^adblock\.\([^.=]*\)=adblock$/\1/p' | head -n1)
    [ -n "$_seg" ] || { log "无法创建 adblock 配置段"; exit 1; }
    # 新建段才给 feed 默认值；已存在的段不碰这一项
    uci -q set "adblock.$_seg.adb_feed=adguard" >/dev/null 2>&1
    uci -q add_list "adblock.$_seg.adb_feed=adguard_tracking" >/dev/null 2>&1
    uci -q add_list "adblock.$_seg.adb_feed=certpl" >/dev/null 2>&1
    log "新建 adblock 配置段：$_seg（feed 取出厂默认 adguard×3）"
fi

uci -q set "adblock.$_seg.adb_enabled=1"   || { log "写 adb_enabled 失败"; exit 1; }
uci -q set "adblock.$_seg.adb_dns=smartdns" || { log "写 adb_dns 失败"; exit 1; }
uci -q set "adblock.$_seg.adb_fetchcmd=curl" || { log "写 adb_fetchcmd 失败"; exit 1; }

uci commit adblock || { log "uci commit adblock 失败"; exit 1; }
log "adblock 配置已写：seg=$_seg enabled=1 dns=smartdns fetchcmd=curl（feed 未动）"
exit 0
