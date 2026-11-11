#!/bin/sh
# bootstrap/enroll/step.sh —— ENROLL 组（enroll）
#
# 两步结构：
#   第一步 --check   只检测，一个字节都不写。逐节点跑 verify_<node>，
#                    全部达标返回 0；有不过的把它们打在 stderr 并返回 1。
#   第二步 --fix     只修「检测不过」的那些（内部走 ensure，先查后改），
#                    修完复检一次；仍不过返回 1。
#
# 本组节点（按 DAG 顺序）：enroll
#
# 用法：
#   ./step.sh --check          检测本组
#   ./step.sh --fix            修本组（只动不过的节点）
#   ./step.sh --node <名字>    只处理单个节点（--check-node / --fix-node 同理）
#
# 【本组不参与检测】enroll 需要在 app.crowdsec.net 网页上点 Accept，
# 本地只能把注册码交上去，是否 authenticated 由用户点确认决定。
# 所以 --check 一律返回 0（跳过），--fix 也只做「提交一次」这一步，
# 绝不因为「网页上还没点」判定本组失败 —— 那会把外部人工流程变成脚本故障。

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

MY_GROUP="ENROLL"
MY_NODES="enroll"

console_enroll_ok() {
    # ① 首选 cscli console status：它直接回答「这台机器有没有绑到 console」。
    #    ⚠️【v.108.52 根因修正】真机输出（24.10，网页端关闭实例后，2026-10-22）：
    #      | Central API (CAPI) | ✅ authenticated |
    #      | Enrolled           | ❌ not enrolled  |
    #    CAPI 的 authenticated 与 console 的 Enrolled 是**两件事**：网页上把实例
    #    「关闭/删除」后，CAPI 凭据照样被接受（authenticated），只有 Enrolled 变成
    #    not enrolled。v.108.51 及之前只 grep 字符串 'not registered'，于是把
    #    「未注册」误判成「已注册」→ verify_enroll 直接 return 0 → 设备永远发现不了
    #    自己被摘掉，也就永不重注册。这就是「网页端不小心关闭后路由器不回来」的根因
    #    （比「注册成功即删 key」更前置：判据先瞎了，key 根本轮不到被用）。
    #    两个词都要认：老版 cscli 用 not registered，新版用 not enrolled。
    #    加 timeout 是因为这条会顺带问一次中央 API，网络不好时可能挂住。
    _out="$(_ct_env "timeout 8 $CSCLI console status" 2>&1)"
    if printf '%s' "$_out" | grep -qiE 'enrolled|central api'; then
        printf '%s' "$_out" | grep -qiE 'not[[:space:]]*-?[[:space:]]*(enrolled|registered)' && return 1
        return 0
    fi
    # ② 退回 capi status 的 enrolled 判据（console status 不可用时的兜底）
    _out="$(_ct_env "timeout 8 $CSCLI capi status" 2>&1)"
    [ -n "$_out" ] || return 1
    _line="$(printf '%s\n' "$_out" | grep -i 'enrolled' | head -n1)"
    [ -n "$_line" ] || return 1
    printf '%s\n' "$_line" | grep -qiE 'not enrolled|(^|[^[:alnum:]_])false' && return 1
    return 0
}

_park_enroll_key() {
    [ -f "$ENROLL_KEY_FILE" ] || return 0
    _pek_new="$(head -n1 "$ENROLL_KEY_FILE" 2>/dev/null | tr -d ' \t\r\n')"
    [ -n "$_pek_new" ] || { rm -f "$ENROLL_KEY_FILE" 2>/dev/null; return 0; }
    _pek_old=""
    [ -s "$ENROLL_KEY_KEEP" ] && _pek_old="$(head -n1 "$ENROLL_KEY_KEEP" 2>/dev/null | tr -d ' \t\r\n')"
    if [ -f "$ENROLL_KEY_KEEP" ] && [ "$_pek_old" = "$_pek_new" ]; then
        # 保险柜里已经是同一把码，主文件多余
        rm -f "$ENROLL_KEY_FILE" 2>/dev/null
        log "[enroll] 注册码已在保险柜（$ENROLL_KEY_KEEP），清掉主文件"
        return 0
    fi
    if mv -f "$ENROLL_KEY_FILE" "$ENROLL_KEY_KEEP" 2>/dev/null; then
        chmod 600 "$ENROLL_KEY_KEEP" 2>/dev/null
        log "[enroll] 注册码已移入保险柜（$ENROLL_KEY_KEEP，600）：网页端被摘后可自动重注册"
    else
        rm -f "$ENROLL_KEY_FILE" 2>/dev/null
        log "[enroll] 注册码移入保险柜失败，已删除主文件（下次被摘需手动 enroll）"
    fi
    return 0
}

# 读注册码：主文件 → 保险柜 两级回落。
# 结果放全局 $_ENROLL_KEY_V，不写 stdout —— log() 走 stdout，用 $(...) 取值会被日志污染。
_enroll_key_load() {
    _ENROLL_KEY_V=""
    if [ -s "$ENROLL_KEY_FILE" ]; then
        _ENROLL_KEY_V="$(head -n1 "$ENROLL_KEY_FILE" 2>/dev/null | tr -d ' \t\r\n')"
        [ -n "$_ENROLL_KEY_V" ] && return 0
    fi
    if [ -s "$ENROLL_KEY_KEEP" ]; then
        _ENROLL_KEY_V="$(head -n1 "$ENROLL_KEY_KEEP" 2>/dev/null | tr -d ' \t\r\n')"
        [ -n "$_ENROLL_KEY_V" ] \
            && log "[enroll] 主注册码缺失，改用保险柜里的注册码（$ENROLL_KEY_KEEP）"
    fi
    return 0
}

# ---- 提交记录（v.108.54：只记录，不再当闸门）----
# console enroll 成功 ≠ 本地已注册：必须有人去 app.crowdsec.net 点 Accept。
# 这段间隔里 console status 必然是 not enrolled，不能拿它判失败。
# 判定改由「本次开机是否已提交过」（进程变量 _ENROLL_TRIED）承担，这里只留个时间戳备查。
_enroll_submit_clear() {
    [ "${_VERIFY_ONLY:-0}" = "1" ] && return 0
    [ -f "$ENROLL_SUBMIT_FILE" ] && rm -f "$ENROLL_SUBMIT_FILE" 2>/dev/null
    return 0
}

verify_enroll() {
    _enroll_key_load
    # ① 已注册：清「等 Accept」标记，把主注册码搬进保险柜（不再删除）。
    #    --verify-only（探针体检）承诺「一个字节都不写」，那条路径只报不动。
    if console_enroll_ok; then
        if [ "${_VERIFY_ONLY:-0}" = "1" ]; then
            [ -f "$ENROLL_KEY_FILE" ] && log "[ENROLL] 已注册但主注册码仍在（体检模式：只报，不移动）"
        else
            _enroll_submit_clear
            _park_enroll_key
        fi
        return 0
    fi
    # ② 未注册且无码：无法自愈，把「已掉线」明明白白打出来，但不让开机失败。
    #    （旧写法 `[ -s key ] || return 0` 在这里静默通过，日志看着正常、设备其实早掉线。）
    if [ -z "$_ENROLL_KEY_V" ]; then
        log "[ENROLL] ** 未注册且无可用注册码（$ENROLL_KEY_FILE / $ENROLL_KEY_KEEP 都不在），无法自动重注册"
        log "[ENROLL] ** 补救：app.crowdsec.net 取注册码后执行 cscli console enroll <key>"
        return 0
    fi
    # ③ 本次开机已提交、等网页 Accept：这段间隔本地必然是 not enrolled，不能当失败。
    #    （v.108.52 就是把它当失败，每个复验轮次都重新提交一次，网页堆出一串 pending。）
    if [ "$_ENROLL_TRIED" = "1" ]; then
        if [ "$_ENROLL_WAIT_LOGGED" = "0" ]; then
            log "[ENROLL] 本次开机已提交注册，等待网页端 Accept（重启设备可再尝试一次）"
            log "[ENROLL]   → app.crowdsec.net → Instances 点 Accept enroll，之后本地自动变 enrolled"
            _ENROLL_WAIT_LOGGED=1
        fi
        return 0
    fi
    # ④ 本次开机还没试过：交给 build 提交一次
    log "[ENROLL] 检测到未注册（网页端可能被关闭/删除），发现可用注册码，交给 build 重注册"
    return 1
}
build_enroll() {
    _enroll_key_load
    if [ -z "$_ENROLL_KEY_V" ]; then
        log "[ENROLL] 未配置注册码（$ENROLL_KEY_FILE / $ENROLL_KEY_KEEP 都没有），跳过 console enroll"
        return 0
    fi
    # 本次开机只提交一次：阶段 1 / 阶段 3 / 重启态复验都走这个函数，共用同一个进程变量。
    # 想再试一次就重启设备（v.108.54：这是唯一的重置方式，不需要删文件）。
    if [ "$_ENROLL_TRIED" = "1" ]; then
        log "[ENROLL] 本次开机已提交过注册，跳过重复提交（想再试一次请重启设备）"
        return 0
    fi
    _ENROLL_TRIED=1
    re_enroll
}

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
        printf '%s\n' "$_cg_n" >&2
    done
    return 1
}

# ============ 第二步：修复（只动不过的） ============
_fix_group() {
    _fg_n=0
    for _fg_x in $MY_NODES; do
        "verify_$_fg_x" >/dev/null 2>&1 && continue
        _fg_n=$((_fg_n + 1))
        log "[%s] 修复 %s" "$MY_GROUP" "$_fg_x"
        ensure "$_fg_x" || log "[%s] 修复 %s 未成功（留待复检）" "$MY_GROUP" "$_fg_x"
    done
    [ "$_fg_n" -gt 0 ] || log "[%s] 无需修复（本组节点全部达标）" "$MY_GROUP"
    _check_group
}

# 被 source 时不执行入口（main.sh / bootstrap.sh 需要本文件的函数）
if [ "${0##*/}" = "step.sh" ]; then
case "${1:---check}" in
--check)
    # 【2026-11-11】原来只打一句「跳过检测」就 exit 0，信息量为零 ——
    # 九组全绿时完全看不出 CAPI 凭据是空的、注册码也从没提交过。
    # 这里保持 rc 恒 0（完成要人去 app.crowdsec.net 点 Accept，本地判不了，
    # 不能因为网页没点就把开机判成失败），但把真实状态报出来。
    # 注：console_enroll_ok 会进容器跑 cscli console status（timeout 8），
    # 容器没跑时它返回 1，会落到「未注册」分支，这与事实一致。
    _enroll_key_load
    if console_enroll_ok; then
        log "[ENROLL] 已注册（console 已接受）"
    elif [ -n "$_ENROLL_KEY_V" ]; then
        log "[ENROLL] 未注册，有注册码；--fix 会提交一次（本次开机仅一次）"
    else
        log "[ENROLL] 未注册且无注册码（$ENROLL_KEY_FILE / $ENROLL_KEY_KEEP 都不在）"
    fi
    exit 0
    ;;
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
