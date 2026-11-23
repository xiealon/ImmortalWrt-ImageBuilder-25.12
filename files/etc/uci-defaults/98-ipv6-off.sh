#!/bin/sh
# 【2026-11-23 用户定】不在 LAN 上折腾 IPv6：
#   这台是旁路由，上游没有 v6 出口，发 RA 只会让客户端拿到用不了的 ULA，
#   表现为「解析/连接卡住再回落」。这里把 RA / DHCPv6 / NDP 全关掉。
#
# 想恢复（或以后手动加 v6）：
#   uci set dhcp.lan.ra='server'; uci set dhcp.lan.dhcpv6='server'; uci commit dhcp
#   uci set network.lan6='interface'; uci set network.lan6.proto='dhcpv6'
#   uci set network.lan6.device='@lan'; uci set network.lan6.reqaddress='try'
#   uci set network.lan6.reqprefix='auto'; uci commit network
#   /etc/init.d/network restart; /etc/init.d/odhcpd restart
#
# 注意：这里**不写死** network.lan6，只关开关，接口以后随时手动建。
[ -f /etc/config/dhcp ] || exit 0
uci -q get dhcp.lan >/dev/null 2>&1 || exit 0

uci set dhcp.lan.ra='disabled'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ndp='disabled'
uci set dhcp.lan.ra_flags='none'
uci -q delete dhcp.lan.ra_management 2>/dev/null
uci commit dhcp || exit 1

/etc/init.d/odhcpd restart >/dev/null 2>&1 || true
logger -t ipv6-off "LAN RA/DHCPv6/NDP 已关闭（旁路由无 v6 上行）" 2>/dev/null
exit 0
