#!/bin/sh
# 【2026-11-23 用户定】旁路由没有 IPv6 上行，LAN 上不发 v6：
# 关掉 RA / DHCPv6 / NDP 三个开关。这是**一次性开机脚本**（uci-defaults 语义）：
# 每台设备首次开机执行一次，跑完自己删掉；之后你在 LuCI / uci 里改回 server 不会被覆盖。
#
# 想手动恢复（或以后要 v6）：
#   uci set dhcp.lan.ra='server'; uci set dhcp.lan.dhcpv6='server'
#   uci set dhcp.lan.ndp='server'; uci commit dhcp; /etc/init.d/odhcpd restart
#   # 并且自行建 lan6：uci set network.lan6='interface' ...
# 注：本脚本不写死 network.lan6，接口要自己加。
[ -f /etc/config/dhcp ] || exit 0
uci -q get dhcp.lan >/dev/null 2>&1 || exit 0

# 【2026-11-23 用户定】只此一次：把 LAN 的 RA/DHCPv6/NDP 关掉，之后脚本自删；
# step.sh 已经完全不碰这几项，所以本次设置不会被开机流程覆盖。
uci set dhcp.lan.ra='disabled'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ndp='disabled'
uci commit dhcp || exit 1

# 【2026-11-23 用户定】连 link-local 也不要：把 disable_ipv6 写进 /etc/sysctl.conf。
# 写 overlay 而不是固件里只读的 sysctl.d —— 以后想开 IPv6，把这三行删掉（或改成 0）
# 并重启即可，不需要换固件。
if ! grep -q 'net.ipv6.conf.all.disable_ipv6' /etc/sysctl.conf 2>/dev/null; then
    {
        echo ''
        echo '# ipv6 off (added by 98-ipv6-off.sh)'
        echo 'net.ipv6.conf.all.disable_ipv6 = 1'
        echo 'net.ipv6.conf.default.disable_ipv6 = 1'
        echo 'net.ipv6.conf.lo.disable_ipv6 = 1'
    } >> /etc/sysctl.conf
fi
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1
for _d in $(ls /proc/sys/net/ipv6/conf/ 2>/dev/null); do
    [ "$_d" = "all" ] && continue
    [ "$_d" = "default" ] && continue
    sysctl -w "net.ipv6.conf.$_d.disable_ipv6=1" >/dev/null 2>&1
done

/etc/init.d/odhcpd restart >/dev/null 2>&1 || true
logger -t ipv6-off "LAN RA/DHCPv6/NDP 已关闭（一次性开机脚本）" 2>/dev/null
exit 0
