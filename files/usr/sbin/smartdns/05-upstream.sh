#!/bin/sh
# smartdns/05-upstream.sh —— 步骤⑤：写上游 6 条（全清重建）
#
# 拆分自 pkg-restore-smartdns.sh 的 _sd_cfg_upstream()。表内容一字未改。
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
# 退出码：0 写入成功 / 1 失败

_here=$(cd "$(dirname "$0")" && pwd)
. "$_here/_lib.sh"

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
done <<'SD_UPSTREAM_EOF'
# 【2026-11-07】CN 组改 DoT：实测本链路 TCP 53 被干扰（阿里/腾讯连上即 RST、
# 百度 SYN 无回应），而 853 端口可达且解析正常（91 B，与 UDP 同长）。
# 只有这 3 条实测可用：阿里 2 条、腾讯 1 条（dot.pub → 120.53.53.53）。
# 百度 / 360 / CNNIC 的 853 不通或解析失败，全部淘汰。
alidns 223.5.5.5 tls CN dns.alidns.com
alidns 223.6.6.6 tls CN dns.alidns.com
dnspod 120.53.53.53 tls CN dot.pub
google 8.8.8.8 tls out dns.google
# out 组：honk 开着时才可达（8.8.8.8 的 853/443、dns.google 的 DoH、
# cloudflare 的 DoH 都能真解析出 91 B；cloudflare 的 853 与 1.1.1.1 的 DoT 均为 0 B）。
# DoH 必须写域名，用 IP 形式（https://8.8.8.8/dns-query）实测 0 B 失败。
google https://dns.google/dns-query https out dns.google
cloudflare https://cloudflare-dns.com/dns-query https out cloudflare-dns.com
SD_UPSTREAM_EOF

[ "$_sdc_n" -eq 6 ] || { log "上游按表处理条数异常（$_sdc_n ≠ 6），不接管 DNS"; exit 1; }

log "上游 6 条已写：CN 3 DoT（阿里×2 / 腾讯 dot.pub）+ out 1 DoT（google）+ 2 DoH（google / cloudflare）"
exit 0
