#!/bin/sh
# smartdns/restore.sh —— smartdns 分类总调度
#
# 【2026-11-10】改成「先检测、只修不过的步骤」。
#
#   原先是六步顺序全跑：哪怕文件都在、配置一条不差，也要 uci 重写一遍、
#   commit、再重启一次 smartdns —— 白断 DNS 约 15 秒。探针每 5 分钟来一趟，
#   这种白断不能忍，而且「什么都没坏却重启」本身就是在制造故障窗口。
#
#   现在每一步先问自己的 --check：
#     过   → 跳过，一个字节不写
#     不过 → 只跑这一步的修复，其他步骤不受影响
#   最后只在三种情况下 apply（commit + 重启 + 等 53）：
#     ① 04 / 05 动过 uci 暂存 —— 不 commit 不落地
#     ② 02 / 03 补过文件      —— smartdns 启动时把配置读进内存，改文件要重启才被看见
#     ③ 06 自己判服务没起
#   三样都不成立 → 直接退出，DNS 一秒都不动。
#
# 顺序（不能换）：
#   01-pkg       包先到位，否则后面 uci 全是空转
#   02-conf      规则文件先补齐 —— smartdns 起不来的头号原因是 conf-file 指向的文件没了
#   03-localrule custom.conf 补 localhost 行（adblock 探活用）
#   04-config    主段
#   05-upstream  上游 6 条
#   06-apply     commit + 重启 + 等 53
#
# 04 / 05 任何一步失败都 revert 暂存，不把半套配置带上线。
#
# 用法：
#   ./restore.sh            检测 + 只修不过的（等价原 --config / --repair）
#   ./restore.sh --check    只检测不修（四态同 90-check.sh）
#   ./restore.sh --list     列出步骤与各自行数
#   ./restore.sh --step 04  只跑某一步
#
# 退出码：0 成功 / 1 失败 / 2 用法错误

_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/_lib.sh"

STEPS="01-pkg 02-conf 03-localrule 04-config 05-upstream 06-apply"

case "${1:-}" in
--list)
    for _s in $STEPS; do
        _f="$_here/$_s.sh"
        [ -f "$_f" ] || { printf '%-14s (缺失)\n' "$_s"; continue; }
        printf '%-14s %4d 行  %s\n' "$_s" "$(wc -l < "$_f")" \
            "$(sed -n '2s/^# //p' "$_f")"
    done
    exit 0
    ;;
--check)
    exec sh "$_here/90-check.sh"
    ;;
--config|--repair)
    # 【2026-11-10】兼容旧调用：rc.local 用 --config（开机配一次）、
    # 探针用 --repair（兜底重试）。拆成本目录之后这两个参数没有语义差别，
    # 都是「先检测、只修不过的步骤」。留别名的意义只有一个：
    # 设备端换路径时不用记得连参数一起删，漏删不会 exit 2。
    ;;
--conf)
    # 【2026-11-10】软故障专用：探针判「只是规则文件缺、53 正常」时只传这个，
    # 语义必须严格保持 —— 只把文件补回 /etc/smartdns，不碰 uci、不 commit、
    # 不 restart smartdns，全程零中断。走默认流程会因 _need_reload 触发重启，
    # 等于「删了个 conf 文件」也要掉 15 秒 DNS，正是这个参数要避免的事。
    exec sh "$_here/02-conf.sh"
    ;;
--step)
    _t="${2:-}"
    [ -n "$_t" ] || { echo "用法：$0 --step 01-pkg" >&2; exit 2; }
    [ -f "$_here/$_t.sh" ] || { echo "没有这一步：$_t" >&2; exit 2; }
    exec sh "$_here/$_t.sh"
    ;;
"")
    ;;
*)
    echo "用法：$0 [--check|--list|--step <名字>]" >&2
    exit 2
    ;;
esac

# ---- 全流程：先检测，只修不过的 ----

_fixed=""
_need_apply=0
_need_reload=0

_sd_restore_step() {   # $1 = 步骤名
    if sh "$_here/$1.sh" --check >/dev/null 2>&1; then
        log "$1 已达标，跳过"
        return 0
    fi
    log "$1 未通过，执行修复"
    sh "$_here/$1.sh" || {
        log "$1 修复失败"
        return 1
    }
    _fixed="$_fixed $1"
    case "$1" in
    04-config|05-upstream) _need_apply=1 ;;
    02-conf|03-localrule)  _need_reload=1 ;;
    esac
    return 0
}

# 包必须在位：后面所有 uci 操作都建立在这包上
if ! _sd_pkg_ok; then
    log "smartdns 不在位，先从只读基座装回"
    sh "$_here/01-pkg.sh" || { log "装包失败（只读基座里没有 smartdns）"; exit 1; }
    _sd_pkg_ok || { log "装包后仍判不在位，放弃写配置"; exit 1; }
    _fixed="$_fixed 01-pkg"
else
    log "01-pkg 已达标，跳过"
fi

for _s in 02-conf 03-localrule 04-config 05-upstream; do
    _sd_restore_step "$_s" || { _sd_discard; exit 1; }
done

# 06：有配置改动，或服务本身没起，才 commit + 重启
if [ "$_need_apply" = 1 ] || [ "$_need_reload" = 1 ]; then
    sh "$_here/06-apply.sh" || exit 1
    _fixed="$_fixed 06-apply"
elif sh "$_here/06-apply.sh" --check >/dev/null 2>&1; then
    log "06-apply 已达标（53 归 smartdns），跳过重启"
else
    log "服务未就绪，执行 apply"
    sh "$_here/06-apply.sh" || exit 1
    _fixed="$_fixed 06-apply"
fi

if [ -z "$_fixed" ]; then
    log "全部步骤达标，未改动任何配置，DNS 未中断"
else
    log "本次修复：$_fixed"
    log "smartdns 已接管 DNS：6 条上游（国内 2 DoH + 2 DoT，境外 2 DoH），dnsmasq 由 init 让出 53"
    log "localhost 本地解析在位：adblock 的 nslookup localhost. 探活可通过"
fi
exit 0
