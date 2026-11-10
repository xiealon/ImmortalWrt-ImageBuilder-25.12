#!/bin/sh
# bootstrap/fix.sh —— 第二步：只修「检测不过」的那一步，修完只复检它自己
#
# 流程（与要求一致）：
#   第 1 轮检测 → 拿到失败的组列表
#   对每个失败的组：调它自己的 step.sh --fix → 再调它自己的 step.sh --check 复检
#   其他组一个字节都不碰（不重启服务、不 reload 网络、不写 uci）
#
# 为什么按组而不是按节点调：组内节点之间有 DEP 边（比如 ct_net 依赖 bridge + rootfs），
# 单独拎一个节点修会绕过依赖检查。组内由 ensure 逐节点判「依赖是否就绪」，
# 已经做到「只修不过的那个」（verify 过的一律跳过，不写任何字节）。
#
# 退出码：0 全部修好 / 1 仍有组不过 / 2 用法错误
#
# 用法：
#   ./fix.sh              先检测，再只修失败的组
#   ./fix.sh net prep     指定只处理这几个组（不先跑全量检测）

_here=$(cd "$(dirname "$0")" && pwd)

GROUPS="net install prep capiblock boot logconf lapi bouncer enroll"

case "${1:-}" in
-h|--help)
    echo "用法：$0 [组名...]" >&2
    echo "  不带参数 = 先全量检测，再只修失败的那些组" >&2
    echo "  带组名   = 只修指定组：$GROUPS" >&2
    exit 0
    ;;
esac

if [ $# -gt 0 ]; then
    _target="$*"
else
    # 先检测，找出失败的组
    _target=""
    for _g in $GROUPS; do
        sh "$_here/$_g/step.sh" --check >/dev/null 2>&1 || _target="$_target $_g"
    done
    if [ -z "$_target" ]; then
        echo "全部达标，无需修复"
        exit 0
    fi
    echo "检测到需要修复的组：${_target# }"
fi

# 【2026-11-10 拆分适配】跨组依赖传播。
# 原单进程版本靠 $ _failed 和 GSET_ 变量在组之间传递「前面挂了」这个事实；
# 拆成子进程后两个变量都归零，于是 net 没修好时 prep 照样开修 ——
# prep 的 build 会去改网桥上的容器接口，而网桥本身是坏的，白折腾还可能留下半截配置。
# 这里用一个纯 sh 的依赖表把语义补回来：前置组仍在 _blocked 里，本组就跳过。
# SOFT_GROUPS 与 bootstrap 的 SOFT_NODES 对齐：bouncer / enroll 失败不阻断下游。
_gdep() {
    case "$1" in
    net)       echo "" ;;
    install)   echo "" ;;
    prep)      echo "net install" ;;
    capiblock) echo "install prep" ;;
    boot)      echo "net prep install capiblock" ;;
    logconf)   echo "boot" ;;
    lapi)      echo "boot" ;;
    bouncer)   echo "logconf lapi" ;;
    enroll)    echo "bouncer" ;;
    esac
}
SOFT_GROUPS="${CS_BOOTSTRAP_SOFT_GROUPS:-bouncer enroll}"

_still=""
_blocked=""
for _g in $_target; do
    case " $GROUPS " in
    *" $_g "*) ;;
    *) echo "未知组：$_g（可选：$GROUPS）" >&2; exit 2 ;;
    esac

    _skip=""
    for _d in $(_gdep "$_g"); do
        case " $_blocked " in
        *" $_d "*) _skip="$_d" ;;
        esac
    done
    if [ -n "$_skip" ]; then
        echo "---- 跳过 $_g：前置组 $_skip 未修复 ----" >&2
        _still="$_still $_g"
        _blocked="$_blocked $_g"
        continue
    fi

    echo "---- 修复 $_g ----"
    sh "$_here/$_g/step.sh" --fix
    _rc=$?
    if [ "$_rc" -eq 0 ]; then
        echo "---- $_g 修复后复检通过 ----"
        continue
    fi
    # 修完必须单独复检这一组，不看 --fix 的返回码（build 可能成功但配置未生效）
    if sh "$_here/$_g/step.sh" --check >/dev/null 2>&1; then
        echo "---- $_g 复检通过 ----"
    else
        echo "---- $_g 仍未通过 ----" >&2
        _still="$_still $_g"
        case " $SOFT_GROUPS " in
        *" $_g "*) ;;
        *) _blocked="$_blocked $_g" ;;
        esac
    fi
done

if [ -z "$_still" ]; then
    exit 0
fi
echo "仍有问题的组：${_still# }" >&2
exit 1
