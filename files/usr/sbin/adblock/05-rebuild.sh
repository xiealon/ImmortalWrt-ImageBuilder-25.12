#!/bin/sh
# adblock/05-rebuild.sh —— 删了重装（最后一招，只对本组开放）
#
# 拆自 pkg-restore-apps.sh 的 _pa_rebuild，2026-11-10 按用户决定加白名单：
# **只有 adblock 允许删了重装**，代理内核一律不重建。
#
# 为什么代理内核不许重建（写在这里，防止将来又扩大范围）：
#   clashoo / daed / honk 的配置是用户导入订阅生成的，不在任何包的文件清单里。
#   apk del 删掉后，apk add 装回来的只有出厂骨架，用户的 config.yaml / 节点 / 规则
#   全部不可恢复。它们只做包级 --force，绝不重建。
#
# 为什么 --force 不够、还要重建：
#   --force 走 PCR_FORCE=1 → apk fix，只按包内容重铺文件、**不动记账**。
#   记账本身坏掉时（包在册但实际不在 / 文件与记账分裂 / conffiles 状态错乱）
#   它会一直报「成功」，复判却依然缺 —— 探针就只能反复重试到 need-human。
#
# 删的时候必须整链一起给 apk：
#   实测 `apk del adblock` 会被 luci-i18n-adblock-zh-cn 的反向依赖挡住，
#   "World updated, but the following packages are not removed due to:
#    adblock: luci-i18n-adblock-zh-cn" —— 一个字节都没删，然后下面的装回
#   变成 apk fix，看起来成功实际空转。三个一起给才真删。
#
# 仍然不带 --rdepends：那会连带 gawk / coreutils-sort / rpcd-mod-rpcsys 一起走
# （实测 6 个包），共享库被拖走会连累别的应用。
#
# 退出码：0 复判全部在位 / 1 仍有缺

_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/_lib.sh"

_chain=""
for _c in $_PA_ADBLOCK; do
    _pa_installed "$_c" && _chain="$_chain $_c"
done

if [ -n "$_chain" ]; then
    log "整链删除：$_chain"
    apk del --no-network $_chain >/dev/null 2>&1 ||
        log "删除$_chain 失败（继续尝试重装，结果以复判为准）"
fi

# 装回走本地库：--no-network 不等镜像索引（没网时不会卡住），
# --allow-untrusted 跳过签名（本固件包库无签名），--force-overwrite 覆盖残留。
for _p in $_PA_ADBLOCK; do
    _pa_installed "$_p" && continue
    log "从本地库装回 $_p"
    apk add --no-network --allow-untrusted --force-overwrite "$_p" >/dev/null 2>&1
    _rc=$?
    [ "$_rc" -eq 0 ] || log "本地库装回 $_p 失败（rc=$_rc）"
done

_m=$(_adb_missing)
[ -z "$_m" ] && { log "重建完成，三包全部在位"; exit 0; }
log "重建后仍有缺：$_m"
exit 1
