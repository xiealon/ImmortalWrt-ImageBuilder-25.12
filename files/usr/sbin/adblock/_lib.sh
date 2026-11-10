#!/bin/sh
# adblock/_lib.sh —— 本目录公共定义（被 01~90 各步骤 source）
#
# 拆分来源：pkg-restore-apps.sh 的 adblock 组（_PA_ADBLOCK 相关逻辑，2026-11-10 拆）
#
# 为什么 adblock 单独成组（原 _PA_ADBLOCK 注释留下的结论）：
#   ① 包被 apk del    → 从包库装回，记账与文件一起回；
#   ② 包在、文件被删  → 判 /etc/init.d/adblock 与 /usr/bin/adblock.sh。
#
# 刻意**不**整份 .list 逐路径从 /rom 拷回：那会把 /etc/adblock/adblock.allowlist、
# adblock.blocklist、adblock.custom.feeds 这些**用户自己加的规则**按出厂版覆盖掉。
# 这与 /etc/config/ 全目录排除是同一条理由 —— 保护动作不能制造它要防的故障。
# 用户规则被删，宁可让他知道缺了，也不要悄悄换成一份空白的出厂白名单。

set -u

# 【2026-11-10】脚本根：默认直接从只读基座 /rom 调用。
# 为什么：/rom 是 squashfs 只读分区，脚本本身改不了，天然免疫篡改与误删 ——
#   比「运行副本 + 事后比对恢复」更硬，也省掉每轮 73 次进程比对。
# 需要热修（改脚本立刻生效，不刷机）时，把 CS_SCRIPT_ROOT 设成空串即可退回 /usr/sbin。
SROOT="${CS_SCRIPT_ROOT-/rom}"
ROMDIR="${ROMDIR:-/rom}"
PKGROOT="${PKGROOT:-}"
_RESTORE="${RESTORE_BIN:-$SROOT/usr/sbin/pkg-restore.sh}"

log() { printf '[ADB] %s\n' "$*"; }

# 三包是一条依赖链：只写 i18n 也会把 adblock 本体拉进来，所以整链一起护。
# 删除时也必须整链给 apk —— 实测 `apk del adblock` 会被 luci-i18n-adblock-zh-cn
# 的反向依赖挡住，输出 "World updated, but the following packages are not removed
# due to: adblock: luci-i18n-adblock-zh-cn"，一个字节都没删。
_PA_ADBLOCK="adblock luci-app-adblock luci-i18n-adblock-zh-cn"

# 受 conffiles 保护的四个文件。包里改了这些，apk 不会覆盖；
# 但文件真没了的时候，那条保护会退化成「永远不修」，所以这里单独开口子补。
_ADB_CONF_FILES="/etc/config/adblock /etc/adblock/adblock.allowlist /etc/adblock/adblock.blocklist /etc/adblock/adblock.custom.feeds"

# 只判这几个程序文件（与 _pa_files_ok 的 case 同口径，不含 /usr/share）：
# 实测 adblock.list 11 行里只有这两个命中 case，/www/cgi-bin/adblock 与
# /etc/adblock/* 不在范围内 —— 删界面或规则文件这一层不报，报的是包，不是文件。
_ADB_PROG_FILES="/etc/init.d/adblock /usr/bin/adblock.sh"

_pa_installed() {
    apk info -e "$1" >/dev/null 2>&1
}

# 固件里本来就带这个应用吗 —— 判据取 /rom/lib/apk/db/installed（出厂已装库，P:<包> 一行一个）。
# 不准拿 /rom/root/apk-cache/<包>-*.apk 当判据：那是兜底包库，收的包远多于固件实际安装的，
# 会把「有包但没装」判成「该有」，等于把用户没选的应用强加给机器。
_pa_should() {
    grep -qxF "P:$1" "$ROMDIR/lib/apk/db/installed" 2>/dev/null
}

# 包在册、关键文件被删。判运行侧文件，不判 /rom（那边副本永远在，拿它当判据恒真）。
# 清单取 /rom 侧固件原始那份（/rom/lib/apk/packages/<包>.list，一行一路径）。
# 清单本身不在 → 放行（判不了，别乱报）。
_pa_files_ok() {
    _paf_l="$ROMDIR/lib/apk/packages/$1.list"
    [ -f "$_paf_l" ] || return 0
    while IFS= read -r _paf_f; do
        case "$_paf_f" in
        /usr/bin/*|/usr/sbin/*|/etc/init.d/*|/lib/*.so*|/usr/lib/*.so*) ;;
        *) continue ;;
        esac
        [ -e "$_paf_f" ] || return 1
    done < "$_paf_l"
    return 0
}

# 输出「该有却没有」的包名（一行，空格分隔）。没有则空行。
_adb_missing() {
    _adb_m=""
    for _adb_p in $_PA_ADBLOCK; do
        _pa_should "$_adb_p" || continue
        if _pa_installed "$_adb_p" && _pa_files_ok "$_adb_p"; then continue; fi
        _adb_m="$_adb_m $_adb_p"
    done
    printf '%s\n' "$_adb_m" | sed 's/^ *//'
}
