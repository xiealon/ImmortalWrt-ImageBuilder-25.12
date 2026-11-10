#!/bin/sh
# bootstrap/bouncer/step.sh —— BOUNCERVERIFY 组（bouncer）
#
# 两步结构：
#   第一步 --check   只检测，一个字节都不写。逐节点跑 verify_<node>，
#                    全部达标返回 0；有不过的把它们打在 stderr 并返回 1。
#   第二步 --fix     只修「检测不过」的那些（内部走 ensure，先查后改），
#                    修完复检一次；仍不过返回 1。
#
# 本组节点（按 DAG 顺序）：bouncer_verify capi_release
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

MY_GROUP="BOUNCERVERIFY"
MY_NODES="bouncer_verify capi_release"

_bouncer_missing_deps() {
    _BOUNCER_MISSING=""
    [ -x /usr/bin/cs-firewall-bouncer ] || _BOUNCER_MISSING="$_BOUNCER_MISSING cs-firewall-bouncer"
    [ -x /etc/init.d/crowdsec-firewall-bouncer ] || _BOUNCER_MISSING="$_BOUNCER_MISSING init.d/crowdsec-firewall-bouncer"
    [ -x /usr/sbin/nft ] || _BOUNCER_MISSING="$_BOUNCER_MISSING nft"
    # 命令在 ≠ 能用：kmod-nft-core 被删时 nft 照样存在，执行才报错。
    # 只有「明确跑不起来」才判内核不可用，其余一律放过（与两处冒烟同一取向）。
    if [ -z "$_BOUNCER_MISSING" ]; then
        case "$(nft list ruleset 2>&1)" in
            *"No such file"*|*"not found"*|*"Operation not permitted"*|*"Protocol not supported"*)
                _BOUNCER_MISSING="$_BOUNCER_MISSING nft(内核)" ;;
        esac
    fi
    # 配置文件：init 脚本靠它生成 /var/etc 下的 yaml，缺了 bouncer 重启即起不来。
    # 【v.180.109】v.180.108 只查了三个可执行文件，漏了这一项 —— 结果配置被删时
    # 判「依赖齐全」，整个恢复块被跳过，_bouncer_heal 里那段特判永远跑不到。
    # 真机实测：rm /etc/config/crowdsec 后 _bouncer_rule_sane 静默无输出、文件不回来。
    # 它必须单独判，不能指望 _rom_restore_pkg：那个函数对 /etc/config/* 与 conffiles
    # 一律跳过（不覆盖用户改动），配置恢复只由 _bouncer_heal 的特判负责。
    # 【v.180.111】判据升级：从「文件存在」改为「字段正确」。
    # 真机实测出厂版是 enabled='0' / api_key='' / api_url=localhost / interface=eth1，
    # 文件在、bouncer 却不会启动 —— 只查存在性会把这种情况当健康态放过去。
    _bouncer_cfg_ok || _BOUNCER_MISSING="$_BOUNCER_MISSING crowdsec配置"
    [ -z "$_BOUNCER_MISSING" ]
}

# 【v.180.115】原名 _rom_restore_bouncer 已不符实：v.180.111 之后它除了从 /rom 补回
# 二进制，还会重建配置（_bouncer_uci_apply）、给空 api_key 重签（_bouncer_register_once）。
# 名字改成 _bouncer_heal —— 它做的是"把这层修到能用"，而不是"拷贝文件"。
# 装回 bouncer 依赖（v.180.150 起走本地包安装，与 lxc 同一套）。配置那一项例外：
# 包管理器恢复 conffiles 时只补「不存在」的，对「文件在但字段全错」它不修 ——
# 而出厂版本身就是坏的，所以配置由下面 _bouncer_uci_apply 从零重建。
# 所以这里特判：文件不存在才拷回，存在则一个字节不动（哪怕内容被改过）。
# 【v.180.111】配置判据不再是「文件在不在」，而是「字段对不对」。
# 与 verify_bouncer_fill 同口径（enabled / api_url / api_key 三项），但独立实现：
# bouncer_fill 属 LAPI 组，探针属 BOUNCERVERIFY 组，跨组调用会把两组的完成语义搅在一起。
# 真机依据：出厂版文件在、字段全错（enabled='0'），只查存在性等于放行。
_bouncer_cfg_ok() {
    [ -f /etc/config/crowdsec ] || return 1
    _bco_sec=$(run uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    [ -n "$_bco_sec" ] || return 1
    [ "$(run uci -q get "$_bco_sec.enabled" 2>/dev/null)" = "1" ] || return 1
    [ "$(run uci -q get "$_bco_sec.api_url" 2>/dev/null)" = "http://${CONTAINER_IP}:${LAPI_PORT}/" ] || return 1
    [ -n "$(run uci -q get "$_bco_sec.api_key" 2>/dev/null)" ] || return 1
    return 0
}
_bouncer_heal() {
    # 走本地包安装（与 lxc 同一套）。bouncer 的 Depends 里有 libnftables.so* 与
    # libnftnl11，opkg 走本地源时会自己解依赖，不需要在这里手写递归。
    # 【v.180.161】按「文件在不在」决定要不要强制：本函数也会因为「配置缺」被叫来，
    # 那种情况包是好的，强制重装只会白刷一次 flash 并重启 bouncer。
    _bh_f_b=0
    { [ -x /usr/bin/cs-firewall-bouncer ] \
      && [ -x /etc/init.d/crowdsec-firewall-bouncer ]; } || _bh_f_b=1
    _bh_f_n=0
    [ -x /usr/sbin/nft ] || _bh_f_n=1
    _rom_restore_pkg crowdsec-firewall-bouncer "$_bh_f_b"
    _rom_restore_pkg nftables-json "$_bh_f_n"
    # 【v.180.111】配置一律重建，不再从只读基座拷出厂版。
    # 真机实测（2026-10-27）出厂版本身不可用：
    #   enabled '0' / api_key '' / api_url http://localhost:8080/ / list interface 'eth1'
    # 照抄过来 init 根本不会拉起 bouncer —— 等于把「配置缺失」换成了「配置在但静默失能」，
    # 后者更隐蔽（缺失至少会报 not found）。而 _bouncer_uci_apply 本来就能从零建段，
    # api_key 由 LAPI 注册时签发 —— 这与「lxc 缺了就重装」是同一套思路：
    # 判据不对就重建，而不是拿一份旧副本凑合。
    _rbc_cfg=/etc/config/crowdsec
    if [ ! -e "$_rbc_cfg" ]; then
        # uci 对不存在的配置文件无法 add section，先落一个空文件占位
        mkdir -p "${_rbc_cfg%/*}" 2>/dev/null
        : > "$_rbc_cfg" 2>/dev/null
    fi
    if _bouncer_uci_apply; then
        chmod 644 "$_rbc_cfg" 2>/dev/null
        log "[bouncer] 配置已按标准字段重建（api_url=${CONTAINER_IP}:${LAPI_PORT} / enabled=1 / interface=br-lan）"
    else
        log "[bouncer] ** 配置重建失败：$_rbc_cfg（uci 不可用或写入受限）"
        return 0
    fi
    # api_key 只能由 LAPI 签发，读不回来。重建后为空属正常，就地补一次注册。
    _rbc_sec=$(run uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    if [ -n "$_rbc_sec" ]; then
        if [ -z "$(run uci -q get "$_rbc_sec.api_key" 2>/dev/null)" ]; then
            if _bouncer_register_once; then
                log "[bouncer] api_key 为空，已重新注册并写入（bouncer 需重启才生效）"
                _bouncer_service_restart >/dev/null 2>&1 || true
            else
                log "[bouncer] ** api_key 为空且注册失败（容器/LAPI 未就绪），下一轮会再试"
            fi
        fi
    fi
    return 0
}
_bouncer_rule_sane() {
    # verify 在组链各节点 / build 循环里会被反复调用，这里保证一轮只查一次
    [ "$_BC_SANE" = "1" ] && return 0
    _BC_SANE=1
    # 先保依赖：nft / bouncer / 配置缺任何一项，下面的结论都不可信
    if ! _bouncer_missing_deps; then
        log "[bouncer] ** 探针依赖不全：$_BOUNCER_MISSING —— 先试只读基座 $ROMDIR"
        _bouncer_heal
        hash -r 2>/dev/null || true
        if ! _bouncer_missing_deps; then
            log "[bouncer] ** 自愈后仍缺：$_BOUNCER_MISSING（固件未内置，查 shell/custom-packages.sh）"
            log "[bouncer] ** 探针跳过：依赖不全时「没有 drop 规则」的结论不可信"
            return 0
        fi
        log "[bouncer] 依赖已从只读基座恢复，继续探针"
    fi
    # ① 结构探针：表不存在说明 bouncer 压根没建起来，那是 bouncer_exists 的职责，
    #    这里不重复报，直接跳过，避免同一件事刷两条日志。
    if nft list table ip crowdsec >/dev/null 2>&1; then
        _brs_drop="$(nft list chain ip crowdsec crowdsec-chain-input 2>/dev/null | grep -c 'drop')"
        case "$_brs_drop" in
            ''|*[!0-9]*) _brs_drop=0 ;;
        esac
        if [ "$_brs_drop" -eq 0 ]; then
            # 【2026-11-09 用户定】drop 数单独没有意义：空载机器（0 条决策）本来就是 0 条 drop。
            # 本机实测：set crowdsec-blacklists 0 元素、两条 chain 各 0 条 drop、cscli 0 条决策 —— 健康。
            # 判据必须成对：只有「LAPI 有决策、防火墙却一条 drop 都没有」才是 bouncer 没下发。
            if _brs_raw="$(ct cscli decisions list -o raw 2>/dev/null)"; then
                _brs_dec="$(printf '%s\n' "$_brs_raw" | tail -n +2 | grep -c . || true)"
                case "$_brs_dec" in ''|*[!0-9]*) _brs_dec=0 ;; esac
                if [ "$_brs_dec" -eq 0 ]; then
                    log "[bouncer] 结构探针：LAPI 无决策、防火墙无 drop —— 空载正常"
                else
                    log "[bouncer] ** 结构探针：LAPI 有 $_brs_dec 条决策，防火墙 0 条 drop（bouncer 未下发）"
                    log "[bouncer] ** 修复：重启 crowdsec-firewall-bouncer"
                    if _bouncer_service_restart; then
                        sleep 3 2>/dev/null || sleep 1
                        _brs_drop2="$(nft list chain ip crowdsec crowdsec-chain-input 2>/dev/null | grep -c 'drop' || true)"
                        case "$_brs_drop2" in ''|*[!0-9]*) _brs_drop2=0 ;; esac
                        if [ "$_brs_drop2" -gt 0 ]; then
                            log "[bouncer] 重启后已下发 $_brs_drop2 条 drop 规则"
                        else
                            log "[bouncer] ** 重启后 3s 仍 0 条 drop（bouncer 拉取延迟或决策未进 set）"
                        fi
                    else
                        log "[bouncer] ** 重启失败，需人工介入"
                    fi
                fi
            else
                log "[bouncer] 结构探针：0 条 drop，决策数取不到（cscli 失败或超时），本条不判"
            fi
        fi
    fi
    # ② 错误探针：只读最后 200 行（约覆盖 2 天的 15 分钟心跳），轮转后读不到就放过
    if [ -f "$_BC_LOG" ] && [ -r "$_BC_LOG" ]; then
        _brs_err="$(tail -n 200 "$_BC_LOG" 2>/dev/null | grep -c 'netlink receive: no such file or directory')"
        case "$_brs_err" in
            ''|*[!0-9]*) _brs_err=0 ;;
        esac
        if [ "$_brs_err" -gt 0 ]; then
            log "[bouncer] ** 错误探针：$_BC_LOG 近 200 行出现 $_brs_err 次 netlink ENOENT（进程实例已坏）"
            log "[bouncer] ** 修复：/etc/init.d/crowdsec-firewall-bouncer restart（重启即恢复，配置无需改动）"
        fi
    fi
    return 0
}

verify_bouncer_verify() {
    # 软告警探针：先看一眼规则有没有真落地，再走原有的三项硬判据
    _bouncer_rule_sane
    ct_running || return 1
    bouncer_exists
    _be=$?
    # 0 继续；1 = 确实没了（该重签）；2 = 判不了，原样上抛，交给窗口去等
    [ "$_be" = "0" ] || return "$_be"
    bouncer_pulling
}
build_bouncer_verify() {
    # 拉取有周期：最多等 60 秒看 last_pull 是否刷新（12 轮 × SLEEP=5）。
    # 这个 60s 与 _BP_DEFAULT_MAX_AGE 同量级是刻意的：窗口内要能真正观察到
    # 「阈值过期」，否则 verify 永远在新鲜区间里打转，等于没判定。
    _w=0
    _bp_unknown=0
    while [ "$_w" -lt 60 ]; do
        verify_bouncer_verify
        _bv=$?
        [ "$_bv" = "0" ] && return 0
        # 2 = 判不了（cscli 失败/超时）：继续等它自己恢复，但不计入「失效」
        [ "$_bv" = "2" ] && _bp_unknown=$((_bp_unknown + 1))
        sleep "$SLEEP" 2>/dev/null || sleep 1
        _w=$((_w + SLEEP))
    done
    # 整个窗口一次都没判成：证据不足。重签对「命令跑不成」没有意义，
    # 直接软失败退出，让探针下一轮带新证据再来。
    if [ "$_bp_unknown" -ge 12 ]; then
        log "[bouncer] 60s 内 12 次全部判不了（cscli 拿不到输出）—— 证据不足，不重签；先查容器/命令本身"
        return 1
    fi
    # 【v.108.58】等不到 ≠「还没到时候」。判据里 bouncer_pulling 依赖 last_pull 推进，
    # 而 last_pull 不推进的一个常见根因是本地 api_key 与 LAPI 的记录已经对不上
    # （见 _force_resign_bouncer 的注释）。这一档原来没有任何修复动作 —— 只是干等
    # 60 秒然后软失败，于是整台机器可以带着「封禁不下发」跑很久，日志里只有一句
    # 「bouncer 验证失败」，看不出根因。
    # 处置顺序：先确保服务在跑（进程没起来时重签毫无意义），再重签，再给同样的 60s。
    log "[bouncer] last_pull 60s 未刷新：先确保宿主机 bouncer 在跑，再按「key 可能已失配」重签后复验"
    _ensure_bouncer_service
    if _force_resign_bouncer; then
        _w=0
        while [ "$_w" -lt 60 ]; do
            if verify_bouncer_verify; then
                log "[bouncer] 重签 api_key 后 last_pull 已刷新（根因是 key 失配）"
                return 0
            fi
            sleep "$SLEEP" 2>/dev/null || sleep 1
            _w=$((_w + SLEEP))
        done
        log "[bouncer] 重签后 60s 内 last_pull 仍未刷新 —— 不是 key 失配（查 bouncer 进程 / 8080 连通 / 容器内 crowdsec）"
    fi
    return 1
}

# ---- BOUNCERVERIFY / capi_release：解开 CAPI（取消注释 online_client）----
# 前置：bouncer 已生效。此时才让 LAPI 去连中央 API，避免新装期连不上导致反复重启。
verify_capi_release() {
    verify_online_client_on
}
build_capi_release() {
    ensure_online_client_on || return 1
    # 运行中容器需要重载才生效：重启容器内 crowdsec 服务
    if ct_running; then
        _ct_restart_crowdsec || true
        log "[CAPI] online_client 已放出，容器内 crowdsec 已重载"
        # 【v.108.41】重启会把 8080 摘掉约 10 秒，而收尾复核紧接着就要探它
        # （verify_lapi_fetch → verify_lapi_reachable，重试窗口只有 3×1s）。
        # 首台真机实测（06:54 那一轮）：
        #   06:54:42 [LAPI] 重启后 8080 已对路由器开放      ← 上一步刚把它弄通
        #   06:54:45 这里重启 crowdsec                      ← 又摘掉
        #   06:54:47 [复核] 首轮不符： lapi_fetch
        #   06:54:50 [复核][lapi_fetch] 构建后始终不符      ← 3 秒窗口覆盖不住
        #   → 整轮 exit 1 → 探针补印又跑一轮。lapi_fetch 本身没问题，
        #     是这一步的重启把它的现场弄脏了。等 8080 回来再返回，
        #     收尾复核看到的就是稳定现场。
        _cw=0
        while [ "$_cw" -lt "$MAX_WAIT" ]; do
            verify_lapi_reachable && break
            sleep 1
            _cw=$((_cw + 1))
        done
        if verify_lapi_reachable; then
            log "[CAPI] 重启后 8080 已恢复（等待 ${_cw}s）"
        else
            log "[CAPI] 重启后 ${MAX_WAIT}s 内 8080 未恢复（收尾复核可能因此误判）"
        fi
    fi
    return 0
}

# 构建 crowdsec 全链：七步各自 ensure + hard（被各节点按需调用）：
# 网络文件 → 自启软链/机器身份 → resolv.conf → 日志源/解析器 → listen_uri
# → trusted_ips → 容器 config；enroll 不在此链。

# 容器是否在跑 —— BOOT 节点的唯一判据。
# 注意：这一行曾被误并进上面的注释里，导致 verify_ct_boot 在运行期根本不存在，
# ensure 调它必然失败，BOOT 组每轮都会去 build（重复开机）。已拆出来成真函数。
ensure_online_client_on() {
    [ -f "$CROWDSEC_CFG" ] || { log "[配置] config.yaml 缺失"; return 1; }

    sed -i -E \
        -e "s|^([[:space:]]*)# online_client:.*|\1online_client:|" \
        -e "s|^([[:space:]]*)# credentials_path: /etc/crowdsec/online_api_credentials.yaml.*|\1credentials_path: /etc/crowdsec/online_api_credentials.yaml|" \
        "$CROWDSEC_CFG" 2>/dev/null

    if grep -qE "^[[:space:]]*online_client:" "$CROWDSEC_CFG" 2>/dev/null; then
        log "[配置] online_client 已放出（取消注释），CAPI 可经 LAPI 后启用"
        return 0
    fi
    log "[配置] online_client 放出失败"
    return 1
}

_wait_lapi_ready() {
    _lw_max="${1:-90}"
    _lw_i=0
    while [ "$_lw_i" -lt "$_lw_max" ]; do
        _lw_i=$((_lw_i+1))
        ct_running || { log "容器已停止，LAPI 等待中止"; return 1; }
        _ct_env "$CSCLI bouncers list -o json" >/dev/null 2>&1 && return 0
        [ $((_lw_i % 15)) -eq 0 ] && log "等待容器内 crowdsec LAPI 就绪（已等 ${_lw_i}s）"
        sleep 1
    done
    return 1
}

_bouncer_register_once() {
    _ct_env "$CSCLI bouncers delete $BOUNCER_NAME" >/dev/null 2>&1 || true
    _junk="$(_ct_env "$CSCLI bouncers list -o json" 2>/dev/null \
             | grep -oE '"name":[[:space:]]*"[^"]*"' \
             | sed -E 's/.*"name":[[:space:]]*"([^"]*)"/\1/' \
             | grep -vx "$BOUNCER_NAME")"
    for _jn in $_junk; do
        _ct_env "$CSCLI bouncers delete \"$_jn\"" >/dev/null 2>&1 || true
        log "[bouncer] 已清理残留坏记录 name=$_jn"
    done

    _raw=$(_ct_env "$CSCLI bouncers add $BOUNCER_NAME -o raw" 2>&1)
    _key=$(printf '%s\n' "$_raw" | sed -e 's/\r$//' \
           | grep -Eo '^[A-Za-z0-9+/=_-]{16,}$' | tail -n1)
    [ -n "$_key" ] || return 1
    _sec=$(run uci show crowdsec 2>/dev/null | grep '=bouncer$' | head -n1 | cut -d= -f1)
    [ -n "$_sec" ] || return 1
    run uci set "$_sec.api_key=$_key"
    run uci commit crowdsec
    return 0
}

_force_resign_bouncer() {
    # LAPI 必须真的可用，否则「注册失败」会被误读成「key 修不好」。
    _wait_lapi_ready 60 || { log "[bouncer] 重签失败：容器内 LAPI 60s 内未就绪"; return 1; }
    _bouncer_register_once || { log "[bouncer] 重签失败：向 LAPI 注册 bouncer 失败（拿不到 key）"; return 1; }
    log "[bouncer] 已重签 api_key（${BOUNCER_NAME}），重启宿主机 bouncer 让进程读到新值"
    if cs_active_on_host; then
        _bouncer_service_restart
    else
        _ensure_bouncer_service
    fi
    return 0
}

_TS_RE='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]'

# ---- last_pull 新鲜度阈值的唯一来源（v.108）----
# 为什么收成常量：原来「600」在 bouncer_pulling 里出现三次（默认值 / 日志文本 /
#   非数字回落值），改一处漏两处就会出现「日志说 600、实际按 180 判」——正是本脚本
#   一直在防的那类「不报错、只给错误答案」。现在三个位置都引用同一个常量，语法层面
#   无法再不一致。
# 为什么是 6 个周期而不是 60 个：bouncer 的心跳是 10s 一次（crowdsec-firewall-bouncer
#   默认 update_frequency），连续丢 6 个周期（60s）已经是强信号。还要注意这 60s 只是
#   「第一轮判失效」的门槛，防抖由探针的 CS_PROBE_STALL_ROUNDS（连续 3 轮才动手）
#   负责，两者叠加后真实的误报容忍约 3 分钟，一次网络抖动不会触发修复。
# 改这里之前先看 build_bouncer_verify 的等待窗口：那边固定 60s（12 轮 × SLEEP=5），
#   与这里的默认值同量级。若把本值调到远小于 60s，安装期会在窗口内频繁判失效；
#   若调到远大于 60s，窗口内根本观察不到「过期」，安装期判定就形同虚设。两个数要同进退。
_BP_PULL_INTERVAL=10
_BP_PULL_MISS=6
_BP_DEFAULT_MAX_AGE=$((_BP_PULL_INTERVAL * _BP_PULL_MISS))

# 同一句日志不重复刷屏：探针与等待窗口都会反复调 bouncer_pulling，
# 让它把「last_pull 停滞」在窗口里原样打十几遍，会埋掉真正有用的信息。
bouncer_exists() {
    _be_raw="$(_ct_env "$CSCLI bouncers list" 2>/dev/null)"
    _be_rc=$?
    [ "$_be_rc" = "0" ] || return 2
    printf '%s\n' "$_be_raw" | grep -qE "^[[:space:]]*${BOUNCER_NAME}[[:space:]]"
}


# 一组路径的「内容指纹」：文件清单 + 每个文件的 sha1 再取一次摘要。
# 用什么不用时间：时间只说明「什么时候动过」，说明不了「是不是同一个东西」——
# 时间戳变了内容没变（touch/重解压同版本）会被误判成变更；内容变了而时间戳
# 恰好相同（同一秒内两次写、cp -p 保留时间）会被漏判。判「一不一样」只能比内容。
# 细节全是从测试里踩出来的，每一处都对应一条实测：
#   ① 必须先 cd 进去再 find，只传相对清单：否则传绝对路径和传相对路径算出来的
#      指纹不同，同一个树在两种调用方式下会「看起来变了」。
#   ② 路径名会参与摘要：sha1sum 的输出里带文件名，`find c` 打印的是 `c/x.yaml`，
#      `find .` 打印的是 `./x.yaml`，同一个目录换个写法就是两个指纹。所以这里不接
#      多个路径参数，而是「第一个参数当根 cd 进去、只算这一个目录」，再统一削掉
#      `./` 前缀——同一个树怎么调都只有一个值。
#   ③ xargs 一个文件都不给时会自己去读 stdin，把外层管道吃掉 —— 加 -r 兜住，
#      并把 stdin 明确接到 /dev/null。
#   ④ 【最坑的一条】把 `</dev/null` 直接挂在整条管道末尾（`... | sha1sum </dev/null`）
#      是错的：管道里每个元素都会拿到这个重定向，上游 `find` 的 stdout 因此被接到
#      /dev/null，一个路径都流不出来，函数对任何目录都稳定返回「空集」的摘要
#      da39a3ee5e6b4b0d —— 不报错、不报警，永远说「没变」。重定向只能落在子 shell 上。
#   ⑤ 【v.104】不能用 xargs 喂文件名：它按空白拆词，名字带空格的文件会被拆成两个
#      不存在的路径，错误又被 2>/dev/null 吞掉，结果是「新增了一个文件，指纹却没变」。
#      实测：目录里加 `a b.yaml` 前后指纹完全相同（都是 9ac6a0d0acfed167）。
#      改成 while read 逐行读、一个路径一次 sha1sum，空格只是文件名的一部分。
# 空集摘要不是「没错」而是「看不出对错」，所以这里额外要求：路径给了但一个文件都没
# 找到时，返回空串而不是那个固定值——调用方据此知道「这次没法比」，而不是「一样」。
verify_online_client_on() {
    [ -f "$CROWDSEC_CFG" ] || return 1
    grep -qE "^[[:space:]]*online_client:" "$CROWDSEC_CFG" 2>/dev/null
}

# LAPI 可达性判定（容器在运行 + cscli bouncers list 有回显）：
# bouncer_verify 的注册态分支与「等 LAPI 就绪」的判据共用——注意它只判「LAPI 活着」，
# 不判 last_pull（那是 bouncer_verify 与探针的职责），也不夹带任何修复动作

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
        printf '%%s\n' "$_cg_n" >&2
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
