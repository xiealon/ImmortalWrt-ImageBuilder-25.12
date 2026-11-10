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

# ---- 自举保护（放在最前，且不 source 任何库）----
#
# 为什么必须有这一段：
#   这些脚本不属于任何 opkg/apk 包（是 files/ 直接铺进固件的），
#   pkg-restore.sh --deps 是按包文件清单逐路径从 /rom 拉回，覆盖不到它们。
#   单体时代只有 crowdsec-lxc-bootstrap.sh 一个文件，探针的 _ensure_boot
#   用 cmp + cp 盯着它就够了；拆成 33 个之后，入口之外的 32 个没有任何
#   机制复原 —— 删一个就永久坏一个，而且是静默坏（调用时才报 not found）。
#
# 为什么不能 source _lib.sh 再调函数：
#   _lib.sh 自己也是这 33 个之一，它被删时函数根本不存在。
#   所以这里只用 busybox 基础命令（find / cmp / cp / chmod / mkdir）。
#
# 口径与探针 _ensure_boot 一致：**与只读基座不一致就覆盖**。
# 前提是「更新只通过刷机完成」——刷机后 /rom 即当前版，两边 cmp 相同，
# 每轮零动作；只有运行副本被删或被改，才从 /rom 复原。
# 只补不改多余文件：运行端多出来的（用户自己放的）一律不删。
_sg_fixed=0
for _sg_d in bootstrap smartdns adblock; do
    _sg_r="/rom/usr/sbin/$_sg_d"
    [ -d "$_sg_r" ] || continue
    for _sg_p in $(cd "$_sg_r" 2>/dev/null && find . -name '*.sh' 2>/dev/null); do
        _sg_rel=${_sg_p#./}
        _sg_t="/usr/sbin/$_sg_d/$_sg_rel"
        [ -f "$_sg_t" ] && cmp -s "$_sg_r/$_sg_rel" "$_sg_t" 2>/dev/null && continue
        mkdir -p "$(dirname "$_sg_t")" 2>/dev/null
        if cp -f "$_sg_r/$_sg_rel" "$_sg_t" 2>/dev/null; then
            chmod 755 "$_sg_t" 2>/dev/null
            _sg_fixed=$((_sg_fixed + 1))
        fi
    done
done
[ "$_sg_fixed" -gt 0 ] && echo "[selfguard] 已从只读基座复原 $_sg_fixed 个脚本"
unset _sg_fixed _sg_d _sg_r _sg_p _sg_rel _sg_t

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
