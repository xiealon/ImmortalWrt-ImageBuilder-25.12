#!/bin/sh
LOGFILE="/etc/config/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >>$LOGFILE
# WAN/LAN zone input 改由 crowdsec-lxc-bootstrap 按 name 定责管理
#（单网口放行 WAN / 多网口收紧 WAN + LAN 放开），不再在此硬设 @zone[N] 索引
# v.78-bp 起网络基线（桥/地址/DHCP 让权/WAN 禁用/DNS/docker 防火墙/服务监听面）
# 全部由 bootstrap 每次开机按需校准；本文件只做非网络的一次性首启设置

  uci set luci.main.mediaurlbase="/luci-static/bootstrap"
  uci set luci.main.lang='auto'
  uci set luci.main.tablefilters='1'
  uci commit

# ===== IPv6 RA 配置（2026-11-14 定档）=====
# 目的：软路由的 RA 压过光猫的 RDNSS，让设备 IPv6 DNS 指向 smartdns（10.0.0.201）
# 关键三点：
#   1) ra_preference=high  → Windows 收到 metric 16，光猫 medium 是 256
#   2) ra_mininterval/maxinterval=30/60 → 比光猫（200-600s）发得勤，Windows 只保留最后到的 RDNSS
#   3) ra_management=0 + ra_flags=none → 显式写死 M=0 O=0
#      （odhcpd 默认 other-config 会让 O=1，设备会发无用的 DHCPv6 Information-request）
uci -q delete dhcp.lan.ignore
uci set dhcp.lan.dhcpv4='disabled'
uci set dhcp.lan.ra='server'
uci set dhcp.lan.ra_preference='high'
uci set dhcp.lan.dns_service='1'
uci set dhcp.lan.ra_mininterval='30'
uci set dhcp.lan.ra_maxinterval='60'
uci set dhcp.lan.ra_management='0'
uci set dhcp.lan.ra_flags='none'
uci commit dhcp
echo "IPv6 RA 已写死: dhcpv4=disabled ra=server pref=high dns_service=1 interval=30-60s flags=none" >>$LOGFILE

FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by DeepSeek"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"

CS_HOME='/etc/crowdsec'
if [ -d "$CS_HOME" ] || [ -f "$CS_HOME/lxc-crowdsec.tar.gz" ] || [ -f "$CS_HOME/lxc-ubuntu.tar.gz" ] || [ -d /srv/lxc/ubuntu/rootfs ]; then
    mkdir -p "$CS_HOME" 2>/dev/null
    # 保留清单要覆盖两种镜像名：极简版 lxc-crowdsec.tar.gz 与历史 systemd 版 lxc-ubuntu.tar.gz。
    # 少了它，sysupgrade 之后镜像被抹掉、rc.local 走 --net-only，容器再也起不来。
    for _keep in "$CS_HOME/lxc-crowdsec.tar.gz" "$CS_HOME/lxc-ubuntu.tar.gz"; do
        grep -q "^$_keep" /etc/sysupgrade.conf 2>/dev/null \
            || echo "$_keep" >> /etc/sysupgrade.conf 2>/dev/null
    done
fi

if [ -d /aria2 ] && [ -f /etc/config/aria2 ]; then
    uci set aria2.main.dir='/aria2'
    uci set aria2.main.seed_time='0'
    uci set aria2.main.max_overall_upload_limit='50k'
    uci set aria2.main.max_upload_limit='50k'
    uci set aria2.main.enabled='1'
    uci commit
    uci set aria2.main.enabled='0'
    uci commit
    echo "aria2 下载目录已设为 /aria2" >>$LOGFILE
else
    echo "跳过 aria2：未检测到 /aria2 目录或 aria2 未安装" >>$LOGFILE
fi

exit 0
