#!/bin/sh
# bootstrap/lapi/step.sh —— LAPI 组（lapi）
#
# 两步结构：
#   第一步 --check   只检测，一个字节都不写。逐节点跑 verify_<node>，
#                    全部达标返回 0；有不过的把它们打在 stderr 并返回 1。
#   第二步 --fix     只修「检测不过」的那些（内部走 ensure，先查后改），
#                    修完复检一次；仍不过返回 1。
#
# 本组节点（按 DAG 顺序）：lapi_fetch bouncer_fill
#
# 用法：
#   ./step.sh --check          检测本组
#   ./step.sh --fix            修本组（只动不过的节点）
#   ./step.sh --node <名字>    只处理单个节点（--check-node / --fix-node 同理）

_here=$(cd "$(dirname "$0")" && pwd)
# 【2026-11-10 修】不能无条件用 "$_here/.." 找依赖。
# 直接执行时 $0 是 .../bootstrap/<组>/step.sh → _here 是组目录 → ".." 才对。
# 但被 main.sh 或驱动脚本 source 时，$0 指向调用者 → _here 已经等于 bootstrap 根，
# 再拼 ".." 就指到 /usr/sbin 去了，_lib.sh 找不到 → 非交互 shell 直接退出。
# 这就是 --full 模式一直跑不通的根因。用目录名判定，两种情形都覆盖。
case "${_here##*/}" in
net|install|prep|capiblock|boot|logconf|lapi|bouncer|enroll) _BS_HOME=$(cd "$_here/.." && pwd) ;;
*) _BS_HOME="$_here" ;;
esac
. "$_BS_HOME/_lib.sh"
. "$_BS_HOME/_dag.sh"
# ensure 在硬失败时会调 full_reinstall —— 它在 selfheal/step.sh 里。
# 不 source 的话，重装判定走了、动作却是 "full_reinstall: not found"，
# 现场什么都没抹、日志只说一句 hard 终止，等于重装机制整条消失。
. "$_BS_HOME/selfheal/step.sh"

MY_GROUP="LAPI"
MY_NODES="lapi_fetch bouncer_fill"

verify_lapi_fetch() {
    ct_running || return 1
    verify_lapi_ready || return 1
    # 【v.108.21】容器内自测通过还不够：bouncer 从路由器连，8080 必须对外开放。
    # 少了这一条，LAPI 只监听 127.0.0.1 时全程「验证通过」，bouncer 却一次都拉不到。
    verify_lapi_reachable || return 1
    # 能从容器里读出 local_api_credentials.yaml 的两个关键字段才算拿到
    _ct_env "grep -qE '^[[:space:]]*url:' /etc/crowdsec/local_api_credentials.yaml" >/dev/null 2>&1 || return 1
    _ct_env "grep -qE '^[[:space:]]*login:' /etc/crowdsec/local_api_credentials.yaml" >/dev/null 2>&1 || return 1
    return 0
}
build_lapi_fetch() {
    # 【v.108.21】先把 8080 真正打开（含老容器「文件改了但进程没重读」的兜底重启）
    # 打不开就进丢层流程：第 0 档已经在 _ensure_lapi_exposed 里试过
    # （校正 listen_uri + 重启进程 + 等待），仍不通说明不是「文件对不对」的问题，
    # 而是进程/资源/库层面的问题。丢层回基底，见 _lapi_ladder。
    if ! _ensure_lapi_exposed; then
        log "[LAPI] 8080 无法对路由器开放，LAPI 环节失败；进入丢层自愈（v.108.63）"
        if _lapi_ladder; then
            log "[LAPI] 自愈已使 8080 可达，继续读取凭证"
        else
            return 1
        fi
    fi
    # 等 LAPI 起（最多 MAX_WAIT 秒，SLEEP 步长），拿到 cscli 回显即认为就绪
    _w=0
    while [ "$_w" -lt "$MAX_WAIT" ]; do
        if verify_lapi_ready; then break; fi
        sleep "$SLEEP" 2>/dev/null || sleep 1
        _w=$((_w + SLEEP))
    done
    verify_lapi_ready || { log "[LAPI] 容器内 LAPI 未就绪（等待 ${MAX_WAIT}s）"; return 1; }

    # 缓存凭证到 STATE_DIR：既是「已获取」的证据，也供 bouncer_fill 使用
    mkdir -p "$STATE_DIR" 2>/dev/null
    _url="$(_ct_env "sed -n 's/^[[:space:]]*url:[[:space:]]*//p' /etc/crowdsec/local_api_credentials.yaml" 2>/dev/null | head -n1)"
    _key="$(_ct_env "sed -n 's/^[[:space:]]*login:[[:space:]]*//p' /etc/crowdsec/local_api_credentials.yaml" 2>/dev/null | head -n1)"
    [ -n "$_url" ] && [ -n "$_key" ] || { log "[LAPI] 读取容器内凭证失败"; return 1; }
    {
        printf 'LAPI_URL=%s\n' "$_url"
        printf 'LAPI_KEY=%s\n' "$_key"
        printf 'ts=%s\n' "$(date '+%F %T')"
    } > "$LAPI_CRED_CACHE" 2>/dev/null
    chmod 600 "$LAPI_CRED_CACHE" 2>/dev/null
    log "[LAPI] 已从容器取到 LAPI 地址与密钥（$_url）"
    return 0
}

# ---- LAPI / bouncer_fill：把 LAPI 与密钥填进路由器 bouncer ----
verify_bouncer_fill() {
    _sec=$(run uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    [ -n "$_sec" ] || return 1
    [ "$(run uci -q get "$_sec.api_url" 2>/dev/null)" = "http://${CONTAINER_IP}:${LAPI_PORT}/" ] || return 1
    [ "$(run uci -q get "$_sec.enabled" 2>/dev/null)" = "1" ] || return 1
    [ -n "$(run uci -q get "$_sec.api_key" 2>/dev/null)" ] || return 1
    return 0
}
build_bouncer_fill() {
    verify_lapi_fetch || { log "[bouncer] LAPI 未就绪，无法填充"; return 1; }
    _bouncer_uci_apply || return 1
    # 注册到容器 LAPI 并取回 key
    _key="$(_ct_env "$CSCLI bouncers add ${BOUNCER_NAME} -o raw" 2>/dev/null | tr -d ' \t\r\n')"
    if [ -z "$_key" ]; then
        # 已存在同名 bouncer：删除旧的重建（否则拿不到新 key）
        _ct_env "$CSCLI bouncers delete ${BOUNCER_NAME}" >/dev/null 2>&1
        _key="$(_ct_env "$CSCLI bouncers add ${BOUNCER_NAME} -o raw" 2>/dev/null | tr -d ' \t\r\n')"
    fi
    [ -n "$_key" ] || { log "[bouncer] 向 LAPI 注册 bouncer 失败"; return 1; }
    _sec=$(run uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    run uci set "$_sec.api_key=$_key"
    run uci commit crowdsec
    log "[bouncer] 已注册并写入 api_key（${BOUNCER_NAME}）"
    # 宿主机 bouncer 进程仍持着旧 key（或根本还没起来）：uci 写完必须重启一次才读到新值。
    # 不重启的话，紧接着的 BOUNCERVERIFY 会白等 60 秒再判 hard。
    _bouncer_service_restart
    # 首启补拉（首台真机 2026-10-22 现场确认的真 bug）：
    #   全新固件第一轮里 bouncer 服务还没被 enable（bouncer_fill 组只落 uci，不起服务），
    #   _bouncer_service_restart 见进程没跑就直接放行 → 紧接着的 BOUNCERVERIFY 必然
    #   60 秒后软失败 → 不置位 → ENROLL 跳过 → 无 installed 标记 → 下轮重跑整条 DAG，
    #   现场表现就是引导日志里「LOGCONF → LAPI → BOUNCERVERIFY → 重跑」转圈。
    #   这里在写完 key 的当下就把服务拉起来（幂等：已在跑且 nft 表就绪则立即返回），
    #   让 BOUNCERVERIFY 第一次就有东西可验。不改 DAG 结构，只改动作。
    if ! cs_active_on_host; then
        log "[bouncer] 服务未运行（首启常态），就地 enable+restart"
        _ensure_bouncer_service
        if cs_active_on_host; then
            log "[bouncer] 首启拉起成功"
        else
            log "[bouncer] 首启拉起失败（仍交给 BOUNCERVERIFY 判定 + 探针兜底）"
        fi
    fi
    return 0
}

# ---- BOUNCERVERIFY / bouncer_verify：验证 bouncer 列表里确实有这个 bouncer 且在拉取 ----
# ---- bouncer 规则落地探针（v.180.107）----
# 为什么需要这一层：2026-10-27 真机故障 —— bouncer 在 LAPI 注册正常、Valid ✔️、
# last_pull 按周期刷新，但 nftables 里一条 drop 规则都没有，23870 条 CAPI 决策
# 全部没下发；机器处于「看着健康、实际裸奔」状态长达 5.5 小时。
# bouncer 自己的日志每 15 分钟刷一次：
#   can't get set elements for crowdsec-blacklists-CAPI: Receive: netlink receive: no such file or directory
# 根因是 jail 重启时的时序竞争（旧进程 removing 'crowdsec' table 与新进程 nftables
# initiated 挨得太近），新进程的 netlink 句柄指向已删除的 handle，此后针对 set 的
# 所有操作永久 ENOENT —— 不重启 bouncer 不恢复。
# 既有判据 bouncer_exists / bouncer_pulling 在这一整轮里全程为绿，所以必须补这一层。
#
# 两条判据，都是软告警：只打日志、置标志，绝不 return 1，不阻断 BOUNCERVERIFY，
# 也不影响 enroll。理由：新机器首次启动时 CAPI 决策还没拉到，规则确实可能为空，
# 硬判会把它误判成故障，而「宁可漏报不误杀」是这套脚本一贯的取向。
#   ① 结构：crowdsec-chain-input 里有没有 drop 规则
#   ② 错误：bouncer 日志近期有没有上面那句 netlink ENOENT
# 文件读取一律先守卫：nft 不在 / 表不存在 / 日志不存在或不可读，全部静默跳过。
_BC_SANE=0
_BC_LOG="${BC_LOG:-/var/log/crowdsec-firewall-bouncer.log}"

# ---- 探针依赖自愈（v.180.108）----
# 为什么探针自己也需要保护：探针 A 写的是
#     nft list chain ip crowdsec crowdsec-chain-input 2>/dev/null | grep -c 'drop'
# `nft` 被 opkg remove 之后，这条命令 stderr 被吞、stdout 为空，grep -c 得 0 ——
# 探针会把「工具没了」误报成「规则没落地」。误诊比不报更糟，所以依赖必须先验在位。
# 归属已经真机核实（2026-10-27）：/usr/sbin/nft 属于 nftables-json 包，
# 不是名字更像的 nftables（该包在 /rom 的 opkg info 里根本不存在）。
# 内核模块 kmod-nft-* 只做「可用性检测」不做文件级恢复：把 .ko 拷回来还得 insmod，
# 而 insmod 失败会把内核状态搞乱，风险高于收益 —— 缺了就明确报出来交给人。
_BOUNCER_MISSING=""
_bouncer_uci_apply() {
    _sec=$(run uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    if [ -z "$_sec" ]; then
        run uci add crowdsec bouncer >/dev/null 2>&1
        _sec=$(run uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    fi
    [ -n "$_sec" ] || { log "/etc/config/crowdsec 无 bouncer 段，bouncer 包未装进固件"; return 1; }
    run uci -q set "$_sec.api_url=http://${CONTAINER_IP}:${LAPI_PORT}/"
    run uci -q set "$_sec.enabled=1"
    run uci -q set "$_sec.ipv4=1"
    run uci -q set "$_sec.ipv6=0"
    run uci -q set "$_sec.deny_action=drop"
    run uci -q set "$_sec.filter_input=1"
    run uci -q set "$_sec.filter_forward=1"
    run uci -q del "$_sec.interface"
    run uci add_list "$_sec.interface=br-lan"
    run uci commit crowdsec
    return 0
}

verify_lapi_ready() {
    ct_running || return 1
    _ct_env "$CSCLI bouncers list -o json" >/dev/null 2>&1
}




# 各组节点清单（由 NODE_GROUP_* 派生，供组级 verify/build 遍历；顺序即组内声明序）
NETBASE_NODES="br_lan_ports lan_static dhcp_ignore bridge lxc_zone fwd_rules lan_input snat ip_forward svc_bind docker_fw pkg_base lxc_auto"
PREP_NODES="ct_net cgroup_mount ct_bootlink ct_resolv"
INSTALL_NODES="img_migrate rootfs ct_config"
CAPIBLOCK_NODES="capi_block"
BOOT_NODES="ct_boot"
LOGCONF_NODES="logconf"
LAPI_NODES="lapi_fetch bouncer_fill"
BOUNCERVERIFY_NODES="bouncer_verify capi_release"
ENROLL_NODES="enroll"
# ---- 8 组组级 verify/build（v.93 按功能切分，组内小步骤各自 ensure）----
# 组级 verify = 组内节点全部内容一致；组级 build = 组内节点逐个 ensure（各自两次闭环）。
# 组与组之间只保留一条真实存在的硬顺序：静态准备/安装/屏蔽 CAPI → 启动容器 → 其余。

# NETBASE：路由器侧网络基线 —— 两块网桥（br-lan / lxcbr0）与防火墙 zone、转发规则。
# 全部只碰 uci 与内核网络栈，不读不写容器 rootfs，因此可以排在 INSTALL 解压之前，
# 保证「rootfs 还在解压时，LAN 已经能进 LuCI」。

# ============ 第一步：检测（只读） ============
_check_group() {
    _cg_bad=""
    for _cg_n in $MY_NODES; do
        if "verify_$_cg_n" >/dev/null 2>&1; then
            continue
        fi
        _cg_bad="$_cg_bad $_cg_n"
    done
    [ -z "$_cg_bad" ] && return 0
    for _cg_n in $_cg_bad; do
        printf '%s\n' "$_cg_n" >&2
    done
    return 1
}

# ============ 第二步：修复（只动不过的） ============
_fix_group() {
    _fg_n=0
    for _fg_x in $MY_NODES; do
        "verify_$_fg_x" >/dev/null 2>&1 && continue
        _fg_n=$((_fg_n + 1))
        log "[%%s] 修复 %%s" "$MY_GROUP" "$_fg_x"
        ensure "$_fg_x" || log "[%%s] 修复 %%s 未成功（留待复检）" "$MY_GROUP" "$_fg_x"
    done
    [ "$_fg_n" -gt 0 ] || log "[%%s] 无需修复（本组节点全部达标）" "$MY_GROUP"
    _check_group
}

# 被 source 时不执行入口（main.sh / bootstrap.sh 需要本文件的函数）
if [ "${0##*/}" = "step.sh" ]; then
case "${1:---check}" in
--check)      _check_group && exit 0 || exit 1 ;;
--fix)        _fix_group   && exit 0 || exit 1 ;;
--node)
    _nd="${2:-}"
    [ -n "$_nd" ] || { echo "用法：$0 --node <名字>" >&2; exit 2; }
    case " $MY_NODES " in *" $_nd "*) ;; *) echo "不在本组：$_nd" >&2; exit 2 ;; esac
    "verify_$_nd" >/dev/null 2>&1 && exit 0
    ensure "$_nd" && exit 0 || exit 1
    ;;
--check-node)
    _nd="${2:-}"
    "verify_$_nd" >/dev/null 2>&1 && exit 0 || exit 1
    ;;
--fix-node)
    _nd="${2:-}"
    ensure "$_nd" && exit 0 || exit 1
    ;;
*)
    echo "用法：$0 [--check|--fix|--node <名>|--check-node <名>|--fix-node <名>]" >&2
    exit 2
    ;;
esac
fi
