#!/bin/sh
# bootstrap.sh —— 入口（保留原文件名，rc.local / 探针 / 99-custom.sh 不用改调用）
#
# 行为分四种，默认是第 1 种（先检测、只修失败的）：
#
#   bootstrap.sh                ① 检测全部 → 只修不过的组 → 复检。
#                                  不重启服务、不 reload 网络，除非某组真的不过。
#   bootstrap.sh --check-all    ② 只检测，一个字节都不写（rc=0 全好 / 1 有问题）
#   bootstrap.sh --fix-all      ③ 只修复：先检测，再只修失败的组
#   bootstrap.sh --full [...]   ④ 原完整引导（main），开机首跑用它
#   bootstrap.sh --verify-only  ⑤ 全量审计（原 --verify-only，只读不写）
#
# 分组顺序（与原脚本 GROUP_SEQ 一致，不能改）：
#   net      宿主网络与网桥（br-lan / lan 地址 / 防火墙 zone / SNAT）★ 最前
#   install  容器镜像迁移校验、rootfs 解压、容器 config
#   prep     容器启动前的静态准备（容器内网络 / cgroup / resolv）
#   capiblock 屏蔽 CAPI（容器内 online_client）
#   boot     启动容器（唯一一次开机）
#   logconf  日志链路（宿主推送 + 容器采集 + LAPI 监听地址）
#   lapi     获取 LAPI 并填入路由器 bouncer
#   bouncer  验证 bouncer 生效并解开 CAPI
#   enroll   网页注册（不参与检测：要在 app.crowdsec.net 点 Accept）

_here=$(cd "$(dirname "$0")" && pwd)

case "${1:-}" in
--check-all)
    # 【2026-11-10 实测】这里原来写 "${@:2}"，ash（设备上的 /bin/sh）不认这个
    # bash 扩展，展开成空串 —— 于是 `bootstrap.sh --check-all -v` 的 -v 被吃掉，
    # check.sh 收到零参数、静默跑完、只回一个 rc。改用 shift + "$@"。
    shift
    exec sh "$_here/check.sh" "$@"
    ;;
--fix-all)
    exec sh "$_here/fix.sh"
    ;;
--full)
    shift
    exec sh "$_here/main.sh" "$@"
    ;;
--verify-only|--only-funcs|--net-only)
    exec sh "$_here/main.sh" "$@"
    ;;
-h|--help)
    sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
"")
    # 默认：检测 → 只修失败的 → 复检
    echo "[step] 检测全部步骤"
    if sh "$_here/check.sh" -v; then
        echo "[step] 全部达标，未做任何修改"
        exit 0
    fi
    echo "[step] 进入修复：只动不过的组"
    sh "$_here/fix.sh"
    _rc=$?
    echo "[step] 最终复检"
    sh "$_here/check.sh" || exit 1
    exit $_rc
    ;;
*)
    echo "用法：$0 [--check-all|--fix-all|--full|--verify-only]" >&2
    exit 2
    ;;
esac
