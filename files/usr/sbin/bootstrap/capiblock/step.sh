#!/bin/sh
# bootstrap/capiblock/step.sh —— CAPIBLOCK 组（capiblock）
#
# 两步结构：
#   第一步 --check   只检测，一个字节都不写。逐节点跑 verify_<node>，
#                    全部达标返回 0；有不过的把它们打在 stderr 并返回 1。
#   第二步 --fix     只修「检测不过」的那些（内部走 ensure，先查后改），
#                    修完复检一次；仍不过返回 1。
#
# 本组节点（按 DAG 顺序）：capi_block
#
# 用法：
#   ./step.sh --check          检测本组
#   ./step.sh --fix            修本组（只动不过的节点）
#   ./step.sh --node <名字>    只处理单个节点（--check-node / --fix-node 同理）

_here=$(cd "$(dirname "$0")" && pwd)
# 【2026-11-10 修】不能无条件用 "$_here/.." 找依赖。
# 直接执行时 $0 是 .../bootstrap/<组>/step.sh → _here 是组目录 → ".." 才对。
# 但被 main.sh 或驱动脚本 source 时，$0 指向调用者 → _here 已经等于 bootstrap 根，
# 再拼 ".." 就指到 /usr/sbin 去了，_lib.sh 找不到 → 非交互 shell 直接退出。
# 这就是 --full 模式一直跑不通的根因。用目录名判定，两种情形都覆盖。
case "${_here##*/}" in
net|install|prep|capiblock|boot|logconf|lapi|bouncer|enroll) _BS_HOME=$(cd "$_here/.." && pwd) ;;
*) _BS_HOME="$_here" ;;
esac
. "$_BS_HOME/_lib.sh"
. "$_BS_HOME/_dag.sh"
# ensure 在硬失败时会调 full_reinstall —— 它在 selfheal/step.sh 里。
# 不 source 的话，重装判定走了、动作却是 "full_reinstall: not found"，
# 现场什么都没抹、日志只说一句 hard 终止，等于重装机制整条消失。
. "$_BS_HOME/selfheal/step.sh"

MY_GROUP="CAPIBLOCK"
MY_NODES="capi_block"

_capi_block_needed() {
    ct_running && return 1
    if _stamp_present && [ -s "$ROOTFS/etc/crowdsec/online_api_credentials.yaml" ]; then
        return 1
    fi
    return 0
}
verify_capi_block() {
    _capi_block_needed || return 0
    verify_online_client_off
}
build_capi_block() {
    if ! _capi_block_needed; then
        log "[CAPI] 本轮无需启动前屏蔽（容器已在跑，或已装机且 CAPI 凭据非空），跳过注释"
        return 0
    fi
    # v.108.34：build 返回 0 只代表 sed 没报错，不代表文件真的变成了 off。
    # 因为 capi_block 已从收尾复核里豁免（见 _post_verify_skip 的理由），
    # 「真的没写成」必须在当场抓住 —— 否则它会被 capi_release 悄悄盖过去。
    ensure_online_client_off || return 1
    verify_online_client_off || {
        log "[CAPI] online_client 注释后立即校验仍不符（$CROWDSEC_CFG）"
        return 1
    }
    return 0
}

# ---- LOGCONF / acquis：容器内日志采集配置（acquis + 解析器 + 白名单）----

# ============ 第一步：检测（只读） ============
_check_group() {
    _cg_bad=""
    for _cg_n in $MY_NODES; do
        if "verify_$_cg_n" >/dev/null 2>&1; then
            continue
        fi
        _cg_bad="$_cg_bad $_cg_n"
    done
    [ -z "$_cg_bad" ] && return 0
    for _cg_n in $_cg_bad; do
        printf '%%s\n' "$_cg_n" >&2
    done
    return 1
}

# ============ 第二步：修复（只动不过的） ============
_fix_group() {
    _fg_n=0
    for _fg_x in $MY_NODES; do
        "verify_$_fg_x" >/dev/null 2>&1 && continue
        _fg_n=$((_fg_n + 1))
        log "[%%s] 修复 %%s" "$MY_GROUP" "$_fg_x"
        ensure "$_fg_x" || log "[%%s] 修复 %%s 未成功（留待复检）" "$MY_GROUP" "$_fg_x"
    done
    [ "$_fg_n" -gt 0 ] || log "[%%s] 无需修复（本组节点全部达标）" "$MY_GROUP"
    _check_group
}

# 被 source 时不执行入口（main.sh / bootstrap.sh 需要本文件的函数）
if [ "${0##*/}" = "step.sh" ]; then
case "${1:---check}" in
--check)      _check_group && exit 0 || exit 1 ;;
--fix)        _fix_group   && exit 0 || exit 1 ;;
--node)
    _nd="${2:-}"
    [ -n "$_nd" ] || { echo "用法：$0 --node <名字>" >&2; exit 2; }
    case " $MY_NODES " in *" $_nd "*) ;; *) echo "不在本组：$_nd" >&2; exit 2 ;; esac
    "verify_$_nd" >/dev/null 2>&1 && exit 0
    ensure "$_nd" && exit 0 || exit 1
    ;;
--check-node)
    _nd="${2:-}"
    "verify_$_nd" >/dev/null 2>&1 && exit 0 || exit 1
    ;;
--fix-node)
    _nd="${2:-}"
    ensure "$_nd" && exit 0 || exit 1
    ;;
*)
    echo "用法：$0 [--check|--fix|--node <名>|--check-node <名>|--fix-node <名>]" >&2
    exit 2
    ;;
esac
fi
