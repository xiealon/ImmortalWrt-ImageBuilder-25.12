#!/bin/sh
# 〔2026-11-09〕zram-swap 参数
#
# OpenWrt 24.10 / 25.12 的 zram.init 是同一份（PKG_RELEASE 32），
# 从 /etc/config/system 的 system 段读三个值，
# 不是 /etc/config/zram（那是 21.02 时代的老写法，改了不生效）：
#   zram_size_mb      默认 ram_size/2048 = 内存一半，本机 1.87G -> 956 MiB
#   zram_comp_algo    默认 lzo（内核只编了 lzo；LZ4/ZSTD 在 config 里都是 no）
#   zram_priority     默认 100
#
# 956 MiB 对软路由偏大：disksize 只是上限、不预分配内存，但真写满时 lzo 的
# 压缩/解压要抢 CPU，反而拖慢转发。512 MiB 在 lzo 下实际占用 RAM 不到 200 MB，
# 足够吸收 1.5G 的匿名页压力。
#
# 已经手动设过的不覆盖。

[ -n "$(uci -q get system.@system[0].zram_size_mb)" ] || \
    uci set system.@system[0].zram_size_mb='512'
[ -n "$(uci -q get system.@system[0].zram_comp_algo)" ] || \
    uci set system.@system[0].zram_comp_algo='lzo'
uci commit system
exit 0
