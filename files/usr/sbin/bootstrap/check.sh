#!/bin/sh
# bootstrap/check.sh —— 第一步：只检测，一个字节都不写
#
# 按原脚本的组顺序（GROUP_SEQ）逐个调各组 step.sh --check：
#   net → install → prep → capiblock → boot → logconf → lapi → bouncer → enroll
#
# 这个顺序就是原脚本的执行顺序，不能改：
#   网桥 / lan 地址 / 防火墙是容器能联网的前提，排最前（net）；
#   容器镜像与 rootfs 解压（install）；
#   容器启动前的静态准备（prep：容器内网络 / cgroup）；
#   屏蔽 CAPI（capiblock）；
#   启动容器（boot）；
#   日志链路（logconf）与 LAPI 对接（lapi）无先后，都要在 boot 之后；
#   验证 bouncer 生效并解开 CAPI（bouncer）；
#   最后是网页注册（enroll）—— 它不参与检测。
#
# 输出：全部达标 → 0；有不过的组 → 1，并把「组名 节点名」打在 stderr。
#
# 用法：
#   ./check.sh          检测全部
#   ./check.sh -v       带每组耗时（排障用）

_here=$(cd "$(dirname "$0")" && pwd)

GROUPS="net install prep capiblock boot logconf lapi bouncer enroll"

_bad=""
_gbad=""
for _g in $GROUPS; do
    [ -f "$_here/$_g/step.sh" ] || { echo "缺脚本：$_g/step.sh" >&2; exit 2; }
    _t0=$(date +%s)
    _out=$(sh "$_here/$_g/step.sh" --check 2>&1)
    _rc=$?
    _t1=$(date +%s)
    case "${1:-}" in
    -v) printf '  %-10s rc=%-2s %2ss %s\n' "$_g" "$_rc" "$((_t1 - _t0))" \
            "$(printf '%s' "$_out" | tr '\n' ' ')" ;;
    esac
    if [ "$_rc" -ne 0 ]; then
        _bad="$_bad $_g"
        for _n in $_out; do
            _gbad="$_gbad $_g:$_n"
        done
    fi
done

if [ -z "$_bad" ]; then
    [ "${1:-}" = "-v" ] && echo "  全部达标"
    exit 0
fi

echo "有问题的组：${_bad# }" >&2
for _x in $_gbad; do
    echo "  $_x" >&2
done
exit 1
