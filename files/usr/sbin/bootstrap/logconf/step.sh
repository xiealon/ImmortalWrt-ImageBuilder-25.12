#!/bin/sh
# bootstrap/logconf/step.sh —— LOGCONF 组（logconf）
#
# 两步结构：
#   第一步 --check   只检测，一个字节都不写。逐节点跑 verify_<node>，
#                    全部达标返回 0；有不过的把它们打在 stderr 并返回 1。
#   第二步 --fix     只修「检测不过」的那些（内部走 ensure，先查后改），
#                    修完复检一次；仍不过返回 1。
#
# 本组节点（按 DAG 顺序）：logconf
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

MY_GROUP="LOGCONF"
MY_NODES="logconf"

build_acquis() {
    setup_acquis
}

# ---- LOGCONF / logconf（v.108.22 合成；v.108.23 并入 listen_uri）----
# 一个节点承诺三件事，缺一不可：
#   ① 宿主把 syslog 推给容器（log_forward）
#   ② 容器用 acquisitions 收并解析（acquis）
#   ③ 容器内 LAPI 监听 0.0.0.0:PORT（listen_uri）—— 少了这条，前两条做得再好，
#      路由器上的 bouncer 也永远拉不到，而日志里完全看不出少了什么。
# 只判文件层、不判进程：此刻容器里 crowdsec 可能还端着旧配置，
# 「进程认没认」是 LAPI 组 _ensure_lapi_exposed（探活 + 必要时重启）的活。
verify_logconf() {
    verify_log_forward || { log "[日志] 宿主机推送配置不符"; return 1; }
    verify_acquis || { log "[日志] 容器内采集配置不符"; return 1; }
    verify_lapi_listen || { log "[日志] 容器内 LAPI 未监听 0.0.0.0:${LAPI_PORT}"; return 1; }
    return 0
}
build_logconf() {
    # 修完立刻复核：build 返回 0 不等于修好了，只有 verify 说了算。
    if ! verify_log_forward; then
        build_log_forward
        verify_log_forward || { log "[日志] 宿主机推送配置写入后仍不符"; return 1; }
    fi
    if ! verify_acquis; then
        build_acquis
        verify_acquis || { log "[日志] 容器内采集配置写入后仍不符"; return 1; }
    fi
    if ! verify_lapi_listen; then
        ensure_listen_uri
        verify_lapi_listen || { log "[LAPI] listen_uri 写入后仍不是 0.0.0.0:${LAPI_PORT}"; return 1; }
    fi
    return 0
}

# ---- LOGCONF / log_forward：宿主机把 syslog 推给容器，并做标记日志入库验证 ----
# 两层验证：
LOG_MARK_PREFIX="csprobe"
verify_log_forward() {
    [ -n "$CONTAINER_IP" ] || return 1
    _sys=$(_system_section) || return 1
    [ -n "$_sys" ] || return 1
    [ "$(run uci -q get "$_sys.log_ip" 2>/dev/null)" = "$CONTAINER_IP" ] || return 1
    [ "$(run uci -q get "$_sys.log_port" 2>/dev/null)" = "514" ] || return 1
    [ "$(run uci -q get "$_sys.log_proto" 2>/dev/null)" = "udp" ] || return 1
    [ "$(run uci -q get "$_sys.log_remote" 2>/dev/null)" = "1" ] || return 1
    return 0
}

# 取 /etc/config/system 中第一个 system 段的段名（v.93：verify 与 build 共用同一套
# 段定位逻辑，避免两处各写一遍 uci show 解析而出现「一个判就绪、一个又去写」的抖动）
_system_section() {
    run uci show system 2>/dev/null | grep -q '=system$' || return 1
    run uci show system 2>/dev/null | grep '=system$' | head -n1 | cut -d= -f1
}

# 标记日志入库验证：成功 0，失败 1。容器没跑 / cscli 不可用则返回 1（不可判）。
verify_log_pipeline() {
    ct_running || return 1
    _mark="${LOG_MARK_PREFIX}$(date +%s)_$$"
    # ① 往容器 syslog 打标记（走容器内 logger，确保进的是 acquisitions 监听的那个文件/套接字）
    _ct_env "logger -t ${LOG_MARK_PREFIX} '${_mark}'" >/dev/null 2>&1 || return 1
    # ② 给 rsyslog 与解析链路一点时间（最多 8 秒，200ms 一探）
    _i=0
    while [ "$_i" -lt 40 ]; do
        _out="$(_ct_env "$CSCLI alerts list -o raw" 2>/dev/null)"
        case "$_out" in
            *"$_mark"*) return 0 ;;
        esac
        # 没有命中规则时 alerts 里不会有；退一步查 decisions 与 metrics 源行数增长
        _out2="$(_ct_env "$CSCLI metrics show" 2>/dev/null)"
        case "$_out2" in
            *"$_mark"*) return 0 ;;
        esac
        _i=$((_i + 1))
        sleep 0.2 2>/dev/null || sleep 1
    done
    # ③ 兜底：直接看容器 syslog 是否收到了这条（验证到「收」这一层）
    _ct_env "grep -q '${_mark}' /var/log/syslog /var/log/messages 2>/dev/null" >/dev/null 2>&1
}

build_log_forward() {
    setup_log_forward || return 1
    # 配置补齐后立刻跑一次链路验证（首次构建值得花这个时间）
    if verify_log_pipeline; then
        log "[日志] 标记日志已成功入库（推送→接收→解析→入库 全链通）"
        return 0
    fi
    log "[日志] 标记日志未在窗口内入库；配置已写，解析链路留待容器下一轮拉取后再验"
    # 不 hard：容器刚起时 acquis 可能还没热，配置层已保证正确即可继续
    return 0
}

# ---- LAPI / lapi_fetch：从容器 cscli 取 LAPI 地址与密钥 ----
# 语义：容器内 LAPI 就绪 + 能拿到 local API 凭证（供路由器 bouncer 用）。
LAPI_CRED_CACHE="$STATE_DIR/lapi.env"
setup_log_forward() {
    [ -n "$CONTAINER_IP" ] || { log "[日志] 无容器 IP，跳过转发配置"; return 1; }

    _sys=$(_system_section) || _sys=""
    if [ -z "$_sys" ]; then
        run uci add system system >/dev/null 2>&1
        _sys=$(_system_section) || _sys=""
    fi
    [ -n "$_sys" ] || { log "[日志] 无 system 段，无法配置远程日志"; return 1; }

    _want_ip="$CONTAINER_IP"
    _cur_ip=$(run uci -q get "$_sys.log_ip" 2>/dev/null)
    _cur_port=$(run uci -q get "$_sys.log_port" 2>/dev/null)
    _cur_proto=$(run uci -q get "$_sys.log_proto" 2>/dev/null)
    _cur_remote=$(run uci -q get "$_sys.log_remote" 2>/dev/null)

    if [ "$_cur_ip" = "$_want_ip" ] && [ "$_cur_port" = "514" ] \
       && [ "$_cur_proto" = "udp" ] && [ "$_cur_remote" = "1" ]; then
        log "[日志] 远程日志已指向容器 ${_want_ip}:514/udp，跳过"
        return 0
    fi

    run uci -q set "$_sys.log_ip=$_want_ip"
    run uci -q set "$_sys.log_port=514"
    run uci -q set "$_sys.log_proto=udp"
    run uci -q set "$_sys.log_remote=1"
    run uci commit system

    run /etc/init.d/log reload >/dev/null 2>&1 || run /etc/init.d/logd reload >/dev/null 2>&1 || true
    log "[日志] 宿主机系统日志已转发到容器 ${_want_ip}:514/udp"
    return 0
}


setup_acquis() {
    [ -d "$ROOTFS/etc/crowdsec" ] || { log "[配置] rootfs 内无 crowdsec"; return 1; }
    if _is_minimal_init; then
        # 【v.108.46】采集源 / 解析器 / 白名单全部静态化：内容在构建期就确定，
        # 由 rootfs-skel 进 tarball 与固件，guard 逐字节保护。
        # 以前这三个文件由本函数每轮重写，所以不能进 guard（写了就被盖回去）。
        for _sf in etc/crowdsec/acquis.d/router.yaml \
                   etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml \
                   etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml; do
            [ -s "$ROOTFS/$_sf" ] \
                || { log "[配置] 缺 /$_sf（静态文件被删？），等 guard 从 /rom 复原"; return 1; }
        done
        log "[配置] 解析器 + 日志源 + 白名单为静态文件（guard 保护）"
        return 0
    fi
    mkdir -p "$ROOTFS/etc/crowdsec/acquis.d" \
             "$ROOTFS/etc/crowdsec/parsers/s01-parse" \
             "$ROOTFS/etc/crowdsec/parsers/s02-enrich" 2>/dev/null

    _acq="$ROOTFS/etc/crowdsec/acquis.d/router.yaml"
    atomic_write "$_acq" "source: syslog" <<'EOF' || return 1
source: syslog
listen_addr: 0.0.0.0
listen_port: 514
protocol: udp
labels:
  type: syslog
EOF

    _par="$ROOTFS/etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml"
    atomic_write "$_par" "openwrt/dropbear-logs" <<'EOF' || return 1
name: openwrt/dropbear-logs
description: Parse OpenWrt non-PAM dropbear logs
filter: evt.Parsed.program == 'dropbear'
onsuccess: next_stage
nodes:
  - grok:
      pattern: "Bad password attempt for '?%{DATA:username}'? from %{IP:source_ip}:%{INT:source_port}"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_failed-auth
  - grok:
      pattern: "Login attempt for nonexistent user %{GREEDYDATA:username} from %{IP:source_ip}:%{INT:source_port}"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_failed-auth
  - grok:
      pattern: "Exit before auth from <%{IP:source_ip}:%{INT:source_port}>"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_failed-auth
  - grok:
      pattern: "Password auth succeeded for '?%{DATA:username}'? from %{IP:source_ip}:%{INT:source_port}"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_auth_success
  - grok:
      pattern: "Pubkey auth succeeded for '?%{DATA:username}'? with key %{DATA:key_type} from %{IP:source_ip}:%{INT:source_port}"
      apply_on: message
    statics:
      - meta: log_type
        value: ssh_auth_success
statics:
  - meta: service
    value: ssh
  - meta: source_ip
    expression: evt.Parsed.source_ip
  - meta: username
    expression: evt.Parsed.username
EOF

    _wl="$ROOTFS/etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml"
    atomic_write "$_wl" "whitelist:" <<'EOF' || return 1
name: openwrt/my-whitelist
description: 'No whitelist configured - placeholder only'
whitelist:
  reason: placeholder, nothing is whitelisted
  ip:
    - 127.0.0.1
  cidr:
    - 240.0.0.0/4
EOF
    log "[配置] 解析器 + 日志源 + 白名单已写入"
    return 0
}

# 【v.108.23】文件层判据：只问「配置写对了没」，不问「进程认了没」。
# LOGCONF 组跑的时候容器里 crowdsec 还端着旧配置，这时候做进程探测必然假红。
# 「进程认了没」交给 LAPI 组的 _ensure_lapi_exposed（探活 + 必要时重启容器内 crowdsec）。
verify_lapi_listen() {
    [ -n "$LAPI_PORT" ] || return 1
    [ -f "$CROWDSEC_CFG" ] || { log "[LAPI] config.yaml 缺失"; return 1; }
    grep -qE "^[[:space:]]*listen_uri:[[:space:]]*['\"]?0\.0\.0\.0:${LAPI_PORT}" "$CROWDSEC_CFG" 2>/dev/null
}

ensure_listen_uri() {
    [ -f "$CROWDSEC_CFG" ] || { log "[配置] config.yaml 缺失"; return 1; }
    grep -qE "^[[:space:]]*listen_uri:[[:space:]]*['\"]?0\.0\.0\.0:${LAPI_PORT}" "$CROWDSEC_CFG" 2>/dev/null \
        && { log "[配置] listen_uri 已就绪 0.0.0.0:${LAPI_PORT}"; return 0; }
    sed -i -E "s|^([[:space:]]*listen_uri:)[[:space:]]*.*|\\1 0.0.0.0:${LAPI_PORT}|" "$CROWDSEC_CFG" 2>/dev/null
    grep -qE "^[[:space:]]*listen_uri:[[:space:]]*['\"]?0\.0\.0\.0:${LAPI_PORT}" "$CROWDSEC_CFG" 2>/dev/null \
        && { log "[配置] listen_uri 已改为 0.0.0.0:${LAPI_PORT}"; return 0; }
    log "[配置] listen_uri 覆盖失败"
    return 1
}

# 【v.108.21】宿主（路由器）侧探测 LAPI。
# 为什么必须从宿主探测：bouncer 跑在路由器上，它连的是 10.1.0.10:8080。
# 容器内 `cscli` / `curl 127.0.0.1` 永远是通的 —— 即使 LAPI 只监听回环。
# 只用容器内判据，就会出现「全部验证通过、bouncer 一次都拉不到」的假绿。

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
        log "[$MY_GROUP] 修复 $_fg_x"
        ensure "$_fg_x" || log "[$MY_GROUP] 修复 $_fg_x 未成功（留待复检）"
    done
    [ "$_fg_n" -gt 0 ] || log "[$MY_GROUP] 无需修复（本组节点全部达标）"
    # 【2026-11-11】fix.sh 路径必须在这里 commit + reload 一次。
    # build_* 大多只写 uci 内存态（uci set 落在 /tmp/.uci/ 的 delta 里），
    # commit/reload 原本只在 build_<组> 末尾的 flush_uci 里做 —— 而那条路径只有
    # main.sh --full 会走；fix.sh 逐组调 `sh <组>/step.sh --fix`，走的是本函数，
    # 修完不 commit 就等于「只在内存里修好了」：/etc/config 没动、fw4 的 nft 表没重建，
    # 重启即清空，下次开机 verify 又不过、又 build 一遍，永远修不进去。
    # 真机 2026-11-11 14:37 场景：snat 的 uci set 后 /tmp/.uci/firewall 有 delta，
    # 直到 14:39 才有别的路径把它 commit 掉，中间 LuCI 读到的还是旧值。
    # flush_uci 内部按 _dirty_<节点> 判断，没改动的组不会白 reload。
    flush_uci || log "[$MY_GROUP] flush_uci 未全部成功（改动可能只在内存里）"
    _check_group
}

# 被 source 时不执行入口（main.sh / bootstrap.sh 需要本文件的函数）
if [ "${0##*/}" = "step.sh" ] && [ "${_BS_SOURCED:-0}" != "1" ]; then
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
