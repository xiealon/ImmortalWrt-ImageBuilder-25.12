#!/bin/sh
# smartdns/05-upstream.sh —— 步骤⑤：写上游 6 条（全清重建）
#
# 拆分自 pkg-restore-smartdns.sh 的 _sd_cfg_upstream()。
#
# 【2026-11-10】表内容移到 _lib.sh 的 sd_upstream_table()：本脚本按它写。
#
# --check 的判据**不用这张表**：只判「uci 里有没有上游」（> 0 就算好），
# 与探针 _up_watch 完全一致。原因见 _lib.sh 里 _sd_upstream_ok 的说明 ——
# 上游是设置项，用户可能自己换供应商、加自建 DNS，拿表逐条比对会把正常设置
# 判成故障，再用下面的全清重建去「修」它，等于保护动作制造出要防的故障。
# 表只在「一条都不剩、必须恢复默认」时使用。
#
# 口径（用户 2026-11-07 定）：先把所有 server 段删光，再按表逐条新建。
# 理由是「防止错误配置遗留」—— 按 IP 找段修正 + 淘汰黑名单那套自相矛盾：
# 覆盖式写入本来就会冲掉 LuCI 里手改的上游，黑名单那层「部分保留」没有意义；
# 而且黑名单是硬编码 10 个 IP，漏掉任何一个旧段它就继续生效。
#
# 事务性：删除只落在 uci 暂存目录（/tmp/.uci），后面任何一步失败都 revert，
# 不会真把表删成空的；只有 06-apply.sh commit 成功才算落地。
#
# 删除从后往前（@server[-1]）：每轮都指向当前最后一个，删它不动前面任何段的索引。
# 不能「预先展开列表再逐个删」—— 删掉 @server[0] 后其余整体前移一格，
# 8 段那样只会删掉 4 段、留下原 1/3/5/7，而末尾 -eq 6 只数表内行、照样通过。
#
# 用法：
#   ./05-upstream.sh --check   只判，一个字节不写（0 对 / 1 不对）
#   ./05-upstream.sh           清空重建
#
# 退出码：0 成功 / 1 失败 / 2 用法错误

_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/_lib.sh"

case "${1:-}" in
--check)
    _sd_upstream_ok
    exit $?
    ;;
"")
    ;;
*)
    echo "用法：$0 [--check]" >&2
    exit 2
    ;;
esac

# 守门①：uci 读不出来就什么都别做。否则「一条都没取到」会被当成
# 「本来就没有旧段」，接着 add 6 条 —— 6 条新的叠在 N 条旧的上，
# 而末尾 -eq 6 只数表内行、照样通过，脏配置被静默留下。
uci -q show smartdns >/dev/null 2>&1 || {
    log "uci show smartdns 失败，无法确认旧上游已清空，放弃写配置"
    exit 1
}

_sdc_g=0
while [ "$_sdc_g" -lt 50 ]; do
    _sdc_g=$((_sdc_g + 1))
    uci -q delete "smartdns.@server[-1]" 2>/dev/null || break
done

# 守门②：清完必须真的一条不剩。delete 失败或撞上 50 轮上限都会提前 break，
# 那时继续 add 就是「新的叠旧的」。复核一次，不干净就整条路径作废。
_sdc_left=$(uci -q show smartdns 2>/dev/null | grep -c '=server$')
case "$_sdc_left" in ''|*[!0-9]*) _sdc_left=-1 ;; esac
[ "$_sdc_left" = "0" ] || {
    log "旧上游未清干净（剩 $_sdc_left 条），不接管 DNS"
    exit 1
}

# 表先落临时文件再 while 读，不走管道：
# 管道会把 while 放进子 shell，_sdc_n 的计数出不来，末尾 -eq 6 永远判失败。
_sdc_tab="${TMPDIR:-/tmp}/.sd_upstream.$$"
sd_upstream_table > "$_sdc_tab" 2>/dev/null || {
    log "取上游表失败，不接管 DNS"
    rm -f "$_sdc_tab"
    exit 1
}

_sdc_n=0
while read -r _sdc_name _sdc_ip _sdc_tp _sdc_grp _sdc_host; do
    # 表里带 # 注释行，必须跳过 —— 否则注释会被当成一条上游写进 uci，
    # 条数校验直接炸（真机踩过：4 行注释让 7 条变 11 条）。
    case "$_sdc_name" in ''|'#'*) continue ;; esac
    [ -n "$_sdc_ip" ] || continue
    uci -q add smartdns server >/dev/null 2>&1
    _sdc_hit="@server[-1]"
    uci -q set "smartdns.$_sdc_hit.enabled=1"
    uci -q set "smartdns.$_sdc_hit.name=$_sdc_name"
    uci -q set "smartdns.$_sdc_hit.ip=$_sdc_ip"
    uci -q set "smartdns.$_sdc_hit.type=$_sdc_tp"
    uci -q set "smartdns.$_sdc_hit.server_group=$_sdc_grp"
    # DoT / DoH 都要带 SNI：DoT 只写 IP 不设 SNI 必然校验失败（8.8.8.8 的证书是 dns.google）；
    # DoH 的 URL 里虽含域名，显式设上更稳妥。
    if { [ "$_sdc_tp" = "tls" ] || [ "$_sdc_tp" = "https" ]; } && [ "$_sdc_host" != "-" ]; then
        uci -q set "smartdns.$_sdc_hit.host_name=$_sdc_host"
    else
        # UDP 段不该带 SNI：历史残留清掉，否则每轮都会判不符
        uci -q delete "smartdns.$_sdc_hit.host_name" 2>/dev/null
    fi
    _sdc_n=$((_sdc_n + 1))
done < "$_sdc_tab"
rm -f "$_sdc_tab"

[ "$_sdc_n" -eq 6 ] || { log "上游按表处理条数异常（$_sdc_n ≠ 6），不接管 DNS"; exit 1; }

log "上游 6 条已写：CN 3 DoT（阿里×2 / 腾讯 dot.pub）+ out 1 DoT（google）+ 2 DoH（google / cloudflare）"
exit 0
