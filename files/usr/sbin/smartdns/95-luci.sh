#!/bin/sh
# smartdns/95-luci.sh —— 单独补界面 luci-app-smartdns
#
# 拆分自 pkg-restore-smartdns.sh 的 _sd_luci_ok() / _sd_luci()。
#
# 界面是真·可选项，所以不并进 01~06 主流程：本体通了就用不着它。
#
# 三段判据，都不碰包管理器（apk / opkg 通用）：
#   ① 运行期在位                                → 0
#   ② 只读基座里有、运行期没有（该有却缺）       → 1，要恢复
#   ③ 基座里也没有（固件压根没编界面）          → 0，不报警
# ③ 是为老固件留的：它本来就没界面，每轮白恢复一次没有意义。
#
# 【v.180.159】② 原来判的是 /usr/lib/opkg/info/luci-app-smartdns.list，
# 25.12 换 apk 后该路径永远不存在 → 恒返 0（静默通过）→ 界面真丢了也漏报，
# 而且 _sd_luci 永远不跑。换成判基座里的两个界面文件，跨包管理器。
#
# 退出码：0 在位或本来不需要 / 1 恢复失败

_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/_lib.sh"

_sd_luci_ok() {
    if [ -f "$PKGROOT/usr/share/luci/menu.d/luci-app-smartdns.json" ] \
       && [ -f "$PKGROOT/usr/libexec/smartdns-call" ]; then
        return 0
    fi
    if [ -f "$ROMDIR/usr/share/luci/menu.d/luci-app-smartdns.json" ] \
       && [ -f "$ROMDIR/usr/libexec/smartdns-call" ]; then
        return 1
    fi
    return 0
}

case "${1:-}" in
--check)
    _sd_luci_ok && exit 0 || exit 1
    ;;
"")
    _sd_luci_ok && { log "界面在位"; exit 0; }
    [ -x "$RESTORE_BIN" ] || { log "找不到 $RESTORE_BIN"; exit 1; }
    # 只调单包恢复、不递归 —— 它的 Depends 里有 luci-base，
    # 递归会一路碰 rpcd / ubus / ucode 一大片基础系统，那是砸系统。
    "$RESTORE_BIN" luci-app-smartdns || { log "界面未恢复（只读基座里没有它的安装清单，只影响网页配置）"; exit 1; }
    log "界面已恢复"
    exit 0
    ;;
*)
    echo "用法：$0 [--check]" >&2
    exit 2
    ;;
esac
