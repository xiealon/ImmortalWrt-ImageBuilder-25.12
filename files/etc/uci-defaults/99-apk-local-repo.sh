#!/bin/sh
# 【2026-11-23 用户定】把固件自带的本地 apk 库挂进 /etc/apk/repositories。
#
# 为什么：自建 honk 内核 6.12.103~26ed6bc1，官方 feed 的 kmod 是 71cc20e3 编的，
# 装上去 vermagic 不符、内核不认；全量预装进镜像又会和上游同名同版本 kmod 撞车
# （run #166:/#168 的 unable to select packages）。所以不预装，改成把本地库挂上：
# /rom/root/apk-cache 里有 1,683 个 apk（含全部 1,204 个 kmod + packages.adb 索引），
# 需要哪个模块直接 apk add，全程离线。
#
# 位置放第一行：同名同版本时本地（26ed）优先，不会被上游（71cc）抢走。
# 幂等：已经有了就不再插；库不存在（老固件）就什么都不做。
REPO="file:///rom/root/apk-cache/packages.adb"

[ -s /rom/root/apk-cache/packages.adb ] || exit 0

touch /etc/apk/repositories
if ! grep -qxF "$REPO" /etc/apk/repositories; then
    tmp="/tmp/.apk-repos.$$"
    { printf '%s\n' "$REPO"; cat /etc/apk/repositories; } > "$tmp" && cat "$tmp" > /etc/apk/repositories
    rm -f "$tmp"
fi

exit 0
