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

# 【2026-11-10】原来的自举段已删除。
# 入口脚本本身现在直接从 /rom 执行（SROOT 默认 /rom），它所在的 squashfs
# 是只读分区 —— 自己改不了、也不会被删，所以「先从 /rom 拷一份到自己旁边」
# 这一步没有意义。保留它反而会往 /usr/sbin 写出 33 份没人用的副本。
#

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
# 【2026-11-11 修】探针在调这两个参数，但这里从来没转发过 ——
# main.sh 里 965 行 / 977 行早就实现了 --probe-check 与 --bouncer-heal，
# 只是 bootstrap.sh 的 case 没列出来，落到最后的 *) 分支：
#   用法：/rom/usr/sbin/bootstrap/bootstrap.sh [--check-all|--fix-all|--full|--verify-only]
#   Command exited with non-zero status 2
# 结果探针每轮都报「【bouncer 下发】检查异常退出 2（124=超时）」
# 和「【停滞】last_pull 判不了」，把「参数没转发」误报成「超时」。
# 真机 2026-11-11 13:08 现场：手工 lxc-attach 0.13s、cscli 0.38s，
# 根本不存在超时；手工直接跑 bootstrap.sh --bouncer-heal 才是 exit 2。
--probe-check|--bouncer-heal)
    exec sh "$_here/main.sh" "$@"
    ;;
-h|--help)
    sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
"")
    # 【2026-11-11】enroll 必须单独补跑一次，不能靠 check.sh 把它带进来。
    # enroll 组的 --check 恒返回 0（它的完成要人去 app.crowdsec.net 点 Accept，
    # 本地无法判定，不能因为「网页还没点」就把开机判成失败）。
    # 但恒 0 的副作用是：check.sh 永远看不到它失败 → fix.sh 永远不修它
    # → build_enroll 不跑 → 刷机/重装后 capi register 与 console enroll 一次都不做。
    # 真机 2026-11-11 12:10 现场：九组全绿、installed 已写，但
    #   online_api_credentials.yaml 0 B、cscli capi status 报 not registered、
    #   console status 显示 not enrolled —— 用户只能手工敲两条 cscli 才能用。
    # enroll --fix 本身是幂等的：内部先 verify_enroll，已注册就直接返回
    # （顺手把主注册码挪进保险柜）；未注册且本次开机没提交过 → 才提交一次。
    if [ -f "$_here/enroll/step.sh" ]; then
        sh "$_here/enroll/step.sh" --fix >/dev/null 2>&1 || true
    fi
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
    echo "用法：$0 [--check-all|--fix-all|--full|--verify-only|--probe-check|--bouncer-heal]" >&2
    exit 2
    ;;
esac
