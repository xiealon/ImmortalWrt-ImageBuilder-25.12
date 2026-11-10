#!/bin/sh
# smartdns/90-check.sh —— 只判定，一个字节都不写
#
# 拆分自 pkg-restore-smartdns.sh 的 --check 分支。
#
# 四态退出码（探针按「坏在哪一层」选修法）：
#   0 = 服务在（53 归它）+ 五个规则文件齐 + localhost 行在位
#   1 = 服务没起来（53 未接管 / 二进制缺失）      —— 硬故障，只能走 01~06 全流程
#   3 = 服务正常、只有规则文件缺                   —— 软故障，02-conf.sh 补文件即可
#   4 = 服务正常、文件齐，只缺 custom.conf 的 localhost 行 —— 03-localrule.sh 补行
#
# 为什么分开：全流程要 commit + 重启 smartdns（约 15 秒 DNS 中断），
# 而「文件被删、进程还活着」这种软故障只要把文件拷回去就完事，重启纯属白掉线。
#
# 为什么 --check 必须同时判文件：_sd_serve 只判「进程在 + 53 归它」，两条都与
# /etc/smartdns/*.conf 在不在无关 —— smartdns 启动时把配置读进内存，
# 运行中删文件既不影响 pidof 也不影响 socket。2026-11-02 真机实测：
# 删 address.conf 后 --check 返 0，探针 100 秒无动作。
#
# 用法：
#   ./90-check.sh          四态判定（探针 / rc.local 门票用）
#   ./90-check.sh --pkg    只判包在不在（0 在 / 1 不在）

_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/_lib.sh"

# 规则文件「基座有、运行期没有」就算不完整。0=齐，1=缺。
# 只看「基座有、运行期没有」：基座本来就没有的（老固件没编这些规则）不算缺，
# 否则每轮都判坏、又永远补不回来，只会把通道锁死在 warn。
_sd_conf_ok() {
    _sc_miss=0
    for _sc_f in $SD_CONF_FILES; do
        [ -e "$ROMDIR/etc/smartdns/$_sc_f" ] || continue
        if [ ! -e "$PKGROOT/etc/smartdns/$_sc_f" ]; then
            printf '[PKG] 缺规则文件：/etc/smartdns/%s\n' "$_sc_f" >&2
            _sc_miss=1
        fi
    done
    [ "$_sc_miss" = 0 ]
}

_sd_localrule_ok() {
    if [ ! -f "$PKGROOT/etc/smartdns/custom.conf" ]; then
        printf '[PKG] 缺文件：/etc/smartdns/custom.conf\n' >&2
        return 1
    fi
    grep -qxF "$_SD_LOCALRULE" "$PKGROOT/etc/smartdns/custom.conf" 2>/dev/null && return 0
    printf '[PKG] 缺 localhost 本地解析：/etc/smartdns/custom.conf\n' >&2
    return 1
}

case "${1:-}" in
--pkg)
    _sd_pkg_ok && exit 0 || exit 1
    ;;
"")
    _sd_serve || exit 1
    _sd_conf_ok || exit 3
    _sd_localrule_ok || exit 4
    exit 0
    ;;
*)
    echo "用法：$0 [--pkg]" >&2
    exit 2
    ;;
esac
