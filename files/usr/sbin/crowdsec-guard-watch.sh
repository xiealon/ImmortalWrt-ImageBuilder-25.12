#!/bin/sh

# 【2026-11-10】脚本根：默认直接从只读基座 /rom 调用。
# /rom 是 squashfs 只读分区，脚本本身改不了，天然免疫篡改与误删；
# 比「运行副本 + 事后比对恢复」更硬，也省掉每轮 73 次进程比对。
# 需要热修时把 CS_SCRIPT_ROOT 设成空串，退回 /usr/sbin 副本。
SROOT="${CS_SCRIPT_ROOT-/rom}"
# crowdsec-guard-watch.sh —— guard 的单次触发入口（cron 每 2 分钟调用）
#
# 为什么需要它：
#   guard 原来只由探针调用。探针主循环 2026-11-09 改成 600 秒之后，
#   「/usr/sbin/{bootstrap,smartdns,adblock} 被删/被改」的最坏恢复时间也跟着
#   从 60 秒变成 10 分钟。而目录完整性检查不碰容器、不做 lxc-attach，
#   开销只有一次 find + md5，跟探测频率没有因果关系，没理由被它拖着。
#   所以拆成独立触发：guard 每 120 秒跑一次，探针仍保持 600 秒。
#
# 本脚本不自带任何判断逻辑 —— 全部交给 guard。它只做两件事：
#   ① 自举 guard 自己（guard 坏了 cron 也调不动它）
#   ② 调 guard（互斥由 guard 内部的 mkdir 锁保证，两个入口共用一把）
#
# 幂等：任何时候跑、跑多少次都安全。拿不到锁就安静退出，不写日志。

GUARD="${CS_GUARD:-$SROOT/usr/sbin/crowdsec-guard.sh}"
ROM="${CS_GUARD_ROM:-/rom}"
CAP="${CS_GUARD_WATCH_MAX:-60}"

# ① 自举：与只读基座不一致就盖回。
# 这段不能调 guard 的任何函数 —— guard 坏掉时函数根本不存在。
if [ -f "$ROM$GUARD" ] && ! cmp -s "$ROM$GUARD" "$GUARD" 2>/dev/null; then
    rm -f "$GUARD" 2>/dev/null
    cp -f "$ROM$GUARD" "$GUARD" 2>/dev/null
    chmod 755 "$GUARD" 2>/dev/null
fi

[ -x "$GUARD" ] || exit 0

# ② 调 guard。timeout 缺失时直接跑（guard 自己有 3 次 attach 的硬上限）。
if command -v timeout >/dev/null 2>&1; then
    timeout "$CAP" "$GUARD" quiet
else
    "$GUARD" quiet
fi
exit 0
