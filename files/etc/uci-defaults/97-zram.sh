#!/bin/sh
# 〔2026-11-09〕zram-swap 参数：固定 1024 MiB / lzo
#
# OpenWrt 24.10 / 25.12 的 zram.init 是同一份（PKG_RELEASE 32），
# 从 /etc/config/system 的 system 段读三个值，
# 不是 /etc/config/zram（那是 21.02 时代的老写法，改了不生效）：
#   zram_size_mb      默认 ram_size/2048 = 内存一半，本机 1.87G -> 956 MiB
#   zram_comp_algo    默认 lzo（内核只编了 lzo；LZ4/ZSTD 在 config 里都是 no）
#   zram_priority     默认 100
#
# 为什么是 1024 MiB：zram 的 disksize 只是上限、不预分配内存，
# 实际占 RAM 靠压缩后的量（lzo 约 2.5~3:1）。1.87G 内存下 1G 是常见的上限，
# 写满时压缩数据约占 350~400 MB，且它存的就是本来就在内存里的匿名页，
# 不会额外抬高总占用。
#
# 本脚本是 uci-defaults（S10boot 跑一次就自删），重点是确保
# /etc/rc.d/S14zram-guard 存在 —— 那个才是每次启动都校验的自愈守卫。
# 两个地方都写死 1024 / lzo，不做“已设过就不覆盖”的判断：
# 你要的就是不用手动、被改坏也能自己回来。

uci set system.@system[0].zram_size_mb='1024'
uci set system.@system[0].zram_comp_algo='lzo'
uci commit system

# guard 每次启动在 S14 跑（早于 S15zram），保证 zram 启动前值已经是对的。
# S10 建的链接本轮 rcS 的 glob 已扩开，要下次启动才生效；
# 但本轮配置已经写成 1024，S15zram 直接就对。
[ -e /etc/rc.d/S14zram-guard ] || ln -sf ../init.d/zram-guard /etc/rc.d/S14zram-guard
exit 0
