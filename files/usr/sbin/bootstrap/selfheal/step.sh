#!/bin/sh

# 【2026-11-10】脚本根：默认直接从只读基座 /rom 调用。
# /rom 是 squashfs 只读分区，脚本本身改不了，天然免疫篡改与误删；
# 比「运行副本 + 事后比对恢复」更硬，也省掉每轮 73 次进程比对。
# 需要热修时把 CS_SCRIPT_ROOT 设成空串，退回 /usr/sbin 副本。
SROOT="${CS_SCRIPT_ROOT-/rom}"
# bootstrap/selfheal/step.sh —— 重装自愈阶梯
#
# 内容：tier-3（_escalate_reinstall / full_reinstall / _structurally_broken）、
#       L3 丢可写层（_l3_*）、凭据保险柜（_cred_*）、重置额度、断电续做计数。
# 注意：本组不是 DAG 节点，没有 check/fix 两态 —— 它只在某个节点的 build 失败
#       且判定为「资产残缺」时才被调用，属于故障处理链，不是常规步骤。

# 【2026-11-11】_overlay_umount 已挪到 _lib.sh（install/selfheal/boot 共用）

_cur_boot_id() {
    cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \t\r\n'
}

# 本次开机还有额度？（读不到 boot_id 一律当「没有」：宁可少重置，也不在无据可依时抹盘）
_reset_quota_ok() {
    _rq_bi=$(_cur_boot_id)
    [ -n "$_rq_bi" ] || return 1
    # 【2026-11-09 用户定】两条抹现场路径共用一份额度。
    #   full_reinstall 记在 $RESET_BOOT_FILE，_l3_reset_overlay 记在 $L3_STATE。
    #   原来各记各的，同一次开机可能连丢两次 upper —— 决策库、日志、machines 记录各丢一遍。
    if [ -s "$L3_STATE" ]; then
        _rq_l3bi=""; _rq_l3n=0
        read -r _rq_l3bi _rq_l3n _rq_ign <"$L3_STATE" 2>/dev/null || true
        case "$_rq_l3n" in ''|*[!0-9]*) _rq_l3n=0 ;; esac
        if [ "$_rq_l3bi" = "$_rq_bi" ] && [ "$_rq_l3n" -ge 1 ]; then
            log "[重装] 本次开机已丢过层（$L3_STATE 记 $_rq_l3n 次），不再给第二次额度"
            return 1
        fi
    fi
    [ "$(cat "$RESET_BOOT_FILE" 2>/dev/null | tr -d ' \t\r\n')" != "$_rq_bi" ]
}

# 真正动手抹盘时调用，把额度记到本次开机名下（此后本次开机不再给第二次）
_reset_consume() {
    _rc_bi=$(_cur_boot_id)
    [ -n "$_rc_bi" ] || { log "[重装] 读不到 boot_id，额度无法记账（本次仍只做这一遍）"; return 0; }
    printf '%s\n' "$_rc_bi" | atomic_write "$RESET_BOOT_FILE" "" 2>/dev/null \
        || log "[重装] 额度记账写入失败（$RESET_BOOT_FILE）"
    log "[重装] 本次开机（$_rc_bi）的重置额度已用：${1:-无说明}"
    return 0
}

# ---- rootfs 残留校验（v.108.20）----
# 「已抹盘但没收尾」（断电/崩溃）之后，rootfs 可能是三种样子：
#   ① 根本不存在          → 必须重建，拒绝重置就等于永远不开机
#   ② 存在但是空壳/残缺    → 同上，重建
#   ③ 已解压且可用        → 上次重装其实干完了，只是收尾没跑，按普通失败处理
_rootfs_usable() {
    [ -d "$ROOTFS" ] || return 1
    [ -f "$ROOTFS/etc/os-release" ] || [ -x "$ROOTFS/sbin/init" ]
}

_intr_count() {
    _ic=""
    [ -f "$INTR_FILE" ] && _ic="$(cat "$INTR_FILE" 2>/dev/null)"
    case "$_ic" in ''|*[!0-9]*) _ic=0 ;; esac
    echo "$_ic"
}

_intr_inc() {
    _n=$(( $(_intr_count) + 1 ))
    printf '%s\n' "$_n" | atomic_write "$INTR_FILE" "" 2>/dev/null || true
}

# 半截写/非数字容错当 0（与 bouncer_pulling 的同款防御）
_reinstall_fail_count() {
    _c=""
    [ -f "$REINSTALL_FAIL_FILE" ] && _c="$(cat "$REINSTALL_FAIL_FILE" 2>/dev/null)"
    case "$_c" in ''|*[!0-9]*) _c=0 ;; esac
    echo "$_c"
}

_fail_count_inc() {
    mkdir -p "$STATE_DIR" 2>/dev/null || return 1
    _n=$(( $(_reinstall_fail_count) + 1 ))
    atomic_write "$REINSTALL_FAIL_FILE" "" <<EOF || return 1
$_n
EOF
    log "[重装] 失败计数 → $_n（阈值 $REINSTALL_MAX，达到即停机转人工）"
    return 0
}

# 上次重装没跑完（exec 前后崩溃/断电，EXIT trap 没机会跑）——开机先记账，
# 与 trap 计数两路互斥不重复：没有这路，「每天抹一次」在断电场景会漏计
_pending_recover() {
    [ -f "$REINSTALL_PENDING_FILE" ] || return 0
    log "[重装] 检出未完成的重装标记（上次抹除 rootfs 后进程未正常收尾）"
    # 【v.108.20】抹盘后断电，rootfs 已经是空的——这时拒绝重置不是「防死循环」，
    # 是「让机器永远不开机」。先看残留：该续做的续做，该算失败的算失败。
    if _rootfs_usable; then
        log "[重装] rootfs 残留校验：可用（/etc/os-release 或 /sbin/init 在）→ 上次重装已解压完成，仅补记一次失败"
        _reset_consume "上次抹盘后进程未收尾，但 rootfs 已重建"
        _fail_count_inc
    else
        _ic=$(( $(_intr_count) + 1 ))
        if [ "$_ic" -gt "$INTR_MAX" ]; then
            log "[重装] rootfs 残留校验：连续 $_ic 次「抹盘后仍未收尾」超过上限 $INTR_MAX，停止自动重建，转人工"
            _reset_consume "连续 $_ic 次抹盘后未收尾，超限"
            _fail_count_inc
        else
            _intr_inc
            log "[重装] rootfs 残留校验：不存在/残缺（第 $_ic/$INTR_MAX 次）→ 重建是唯一恢复途径，保留本次重置额度继续做"
        fi
    fi
    rm -f "$REINSTALL_PENDING_FILE" 2>/dev/null
    return 0
}

# exec 接缝：dash 禁 exec 同名函数（实测 Bad function name），测试打桩本函数验证「带标记重跑」
# 【2026-11-10 拆分适配】必须重跑「顶层入口」，不能重跑 $0。
# 拆分前 $0 就是整个引导脚本，exec 它等于重跑全流程。
# 拆分后 $0 是 bootstrap/<组>/step.sh —— 抹掉 rootfs 之后只重跑一个组，
# install / prep 全都不跑，容器永远起不来，而日志看起来「重装已执行」。
# 所以这里显式找入口，并强制带 --full（走 main.sh 的单进程完整流程，
# 保留 _failed / GSET_ 那套跨组依赖传播）。
_bs_reexec() {
    _ent=""
    for _c in "$SROOT/usr/sbin/bootstrap/bootstrap.sh" \
              "$(dirname "$0")/../bootstrap.sh" \
              "$(dirname "$0")/../../bootstrap.sh"; do
        [ -f "$_c" ] && { _ent="$_c"; break; }
    done
    if [ -z "$_ent" ]; then
        log "[重装] 找不到引导入口（bootstrap.sh），放弃重跑 —— rootfs 已抹除，需人工重刷或手工 exec"
        return 1
    fi
    log "[重装] 以重装模式重跑全流程：/bin/sh $_ent --full"
    exec /bin/sh "$_ent" --full
}

# 抹前备份 console 凭证：注册码虽可重用不消耗，保留凭证可免网站端多一条机器记录、免一次 Accept
_cred_backup() {
    [ -s "$ROOTFS/$_CRED_REL" ] || { log "[重装] 无 online_api_credentials.yaml，无凭证可备份"; return 0; }
    mkdir -p "$CRED_BACKUP_DIR" 2>/dev/null || { log "[重装] 备份目录不可建（$CRED_BACKUP_DIR）"; return 1; }
    cp -a "$ROOTFS/$_CRED_REL" "$CRED_BACKUP_DIR/" 2>/dev/null || { log "[重装] 凭证备份失败"; return 1; }
    log "[重装] 凭证已备份到 $CRED_BACKUP_DIR"
    return 0
}

# 二遍 rootfs 解压完成后调用：凭证落回新 rootfs + best-effort 重启容器内 crowdsec
_cred_restore() {
    [ -d "$ROOTFS/etc/crowdsec" ] || return 0
    # 【v.108.51】现场已有凭据就不覆盖：开机复核时这份可能比备份更新
    # （本轮刚 register 过），用旧副本盖回去等于把刚注册的身份作废。
    if [ -s "$ROOTFS/$_CRED_REL" ]; then
        log "[凭据] 现场已有 CAPI 凭据，保持不动"
        return 0
    fi
    _cr_src=""
    if [ -s "$CRED_KEEP_FILE" ]; then
        _cr_src="$CRED_KEEP_FILE"
    elif [ -s "$CRED_BACKUP_DIR/online_api_credentials.yaml" ]; then
        _cr_src="$CRED_BACKUP_DIR/online_api_credentials.yaml"
        log "[凭据] 无持久副本，改用重装前备份"
    fi
    if [ -z "$_cr_src" ]; then
        log "[凭据] 无可用备份，enroll 步将用注册码重注册（仅需网站端 Accept）"
        return 0
    fi
    cp -f "$_cr_src" "$ROOTFS/$_CRED_REL" 2>/dev/null \
        || { log "[凭据] 恢复失败（来源 $_cr_src）"; return 1; }
    chmod 600 "$ROOTFS/$_CRED_REL" 2>/dev/null
    log "[凭据] 已恢复 CAPI 凭据（来源 $_cr_src），无需重新 register/enroll"
    ct_running && _ct_restart_crowdsec || true
    return 0
}

# 【v.108.51】把现场凭据存成持久副本（/etc/config 下，靠 base-files-essential 活过刷机）。
# 幂等：内容没变也照抄一遍（162 字节，代价可忽略），但只在首次建文件时打日志。
# --verify-only（探针体检）承诺「一个字节都不写」，那条路径必须跳过。
_cred_keep_save() {
    [ "${_VERIFY_ONLY:-0}" = "1" ] && return 0
    [ -s "$ROOTFS/$_CRED_REL" ] || return 0
    _cks_new=0
    [ -s "$CRED_KEEP_FILE" ] || _cks_new=1
    mkdir -p "$(dirname "$CRED_KEEP_FILE")" 2>/dev/null
    cp -f "$ROOTFS/$_CRED_REL" "$CRED_KEEP_FILE" 2>/dev/null \
        || { log "[凭据] 持久副本写入失败（$CRED_KEEP_FILE），刷机后需重新注册"; return 1; }
    chmod 600 "$CRED_KEEP_FILE" 2>/dev/null
    [ "$_cks_new" = "1" ] && log "[凭据] 已建立持久副本（$CRED_KEEP_FILE），刷机后免重注册"
    return 0
}

# 【v.108.51】判「CAPI 明确拒绝现有凭据」：token 被吊销 / 实例被删 / 403。
# 只认这几句明确报错，不用 console status 的 not registered —— 刚 register、还没
# enroll 时它同样是 not registered，拿它判死会把好凭据删掉，反而退化成重注册。
_capi_cred_rejected() {
    # 【v.108.65】加 timeout（v.108.70 起 8s）：这条要问一次中央 API，网络坏但没断时 cscli 会一直等
    # TCP 超时（分钟级），而调用它的 re_enroll 全程持着引导锁 —— 探针的 tick 会被
    # lock-busy 挡到 PROBE_LOCK_STALE（1800s）才回收，等于保护链路停摆半小时。
    # 超时返回 124、输出为空 → 下面的 grep 不匹配 → return 1（不删凭据），方向是安全的。
    _ccr_out="$(_ct_env "timeout 8 $CSCLI capi status" 2>&1)" || true
    printf '%s' "$_ccr_out" \
        | grep -qiE 'invalid credential|unable to authenticate|unauthori[sz]ed|forbidden|wrong credential|(^|[^0-9])40[13]([^0-9]|$)' \
        && return 0
    return 1
}

# 抹前内容级复核（对应用户需求「查看每个组是否置位1」）：只读、只记日志
_reinstall_diag() {
    log "[重装] 抹除前内容级复核（每个组是否就位）"
    verify_img_migrate       >/dev/null 2>&1 && log "[重装]   img_migrate 就绪"       || log "[重装]   img_migrate 未就绪"
    verify_ct_config         >/dev/null 2>&1 && log "[重装]   ct_config 就绪"         || log "[重装]   ct_config 未就绪"
    verify_rootfs            >/dev/null 2>&1 && log "[重装]   rootfs 就绪"            || log "[重装]   rootfs 未就绪（内容级不符即视为损坏）"
    verify_ct_net      >/dev/null 2>&1 && log "[重装]   ct_net 就绪"      || log "[重装]   ct_net 未就绪"
    verify_acquis      >/dev/null 2>&1 && log "[重装]   acquis 就绪"      || log "[重装]   acquis 未就绪"
    verify_ct_resolv   >/dev/null 2>&1 && log "[重装]   ct_resolv 就绪"   || log "[重装]   ct_resolv 未就绪"
    bouncer_pulling
    case $? in
        0) log "[重装]   bouncer last_pull 判定为在拉" ;;
        1) log "[重装]   bouncer last_pull 失效" ;;
        *) log "[重装]   bouncer last_pull 判不了（cscli 失败/超时/解析失败）" ;;
    esac
    cs_active_on_host && log "[重装]   bouncer 服务活"         || log "[重装]   bouncer 服务未活"
    nft_table_ready   && log "[重装]   nft 表就绪"             || log "[重装]   nft 表缺失"
    return 0
}

# =====================================================================
# LAPI 起不来时怎么办（v.108.63：砍到一步）
#
# 触发位置：build_lapi_fetch 开头。第 0 档（校正 listen_uri + 重启容器内 crowdsec）
# 建在 _ensure_lapi_exposed 里，已经试过仍不通才进到这里。
#
# 为什么不再分档：原来「LAPI 起不来但文件和配置都正常」是死路 —— 各 verify 都通过
# （它们验的是「文件内容对不对」），build 也改不动什么，于是 hard 退出、探针 3 次后
# 停手，机器一直坏到有人重启。重启一次之所以有用，是因为给了「丢可写层」的机会。
# 这里做的事就是：把「重启才有的那次机会」提前到运行期，但必须带额度。
#
# 只留两步：
#   ① 再探一次（第 0 档刚重启过进程，可能刚好生效）—— 不破坏，零成本；
#   ② 丢可写层 → 回到只读基底。
# 「先诊断再决定」这条路走不通：诊断输出的可信度不足以支撑「不许丢层」这个结论，
# 判错一次就是「明明能修却放过」，而且判据本身要跟着 crowdsec 版本改。详见下面
# 「分档诊断已删除」那段。
#
# 一条贯穿的原则：enroll 完全不参与。它要联网、要人在网页点 Accept，不确定性太大；
# 它掉线不影响 LAPI 链路，也不该让自愈逻辑做任何破坏性动作。

# ---- 分档诊断已删除（v.108.63） ----
# v.108.61~62 在这里放过两档只读诊断：`crowdsec -t` 校验 + 按签名对症处置
# （离线时 hub update 无效、移 decisions.db），再加一道「坏的是谁的文件」的第四道门，
# 用来判断这次该不该丢层。整套东西的前提是「丢层代价高，所以先试着不丢」。
# 真机数据把这个前提推翻了（2026-10-22 实测只读基底）：
#   · hub 五个目录（collections/contexts/parsers/postoverflows/scenarios）齐全；
#   · var/lib/crowdsec/data/crowdsec.db 180224 B 在，凭据 yaml 158 B 在，
#     且与 rootfs 那份 md5 完全相同 → 丢层连机器身份都不改，也不会在 console 多记录；
#   · GeoLite2 两个 mmdb、detect.yaml 都在 → 情报库同样干净回退。
# 也就是说：丢层 = 回到构建时验证过的完整状态，不需要联网、不需要 hub update。
# 那诊断就只剩下坏处 —— 判错了会「明明丢层能修却放过」，而判据本身要维护两版代码。
# 现在配置与规则由 guard 逐字节守着（坏了 60 秒内复原）；守不住的（库、hub 更新、
# 进程状态、缓存）直接丢层回基底。一步到位，不用第二套判据。
# 唯一保留的「先试一次不破坏的」是调用方已经做过的：重启容器内 crowdsec。

# ---- 丢层的资源门 ----
# 磁盘满 / inode 耗尽时丢可写层不只无解，还更糟：重建要写更多数据。
# 读不到容量不拦（无据可依时不该替人做否定判断），但必须记一句。
_l3_res_gate() {
    _lr_avail="$(df -k "$OVL_UPPER" 2>/dev/null | awk 'NR==2{print $4}')"
    case "$_lr_avail" in
    ''|*[!0-9]*)
        log "[自愈] 丢层：读不到可写层可用空间，不拦（但这意味着无法排除磁盘满）"
        ;;
    *)
        if [ "$_lr_avail" -lt 32768 ]; then
            log "[自愈] 丢层被拒：可写层所在分区仅剩 ${_lr_avail}KB（<32MB），重建无从谈起"
            return 1
        fi
        ;;
    esac
    return 0
}

# ---- 丢层的两道门（v.108.63：从四道砍到两道） ----
# 签名门删了：没有 `crowdsec -t` 就没有可靠的「同一个根因」判据，
# 靠现象签名只会恒等（进到这里就一定是 LAPI 不通）—— 那等于把额度永久锁死，
# 比误丢一次更糟。留下的两道回答同一个问题：「凭什么现在可以再抹一次现场」。
#   ① 开机门：同一次开机只给一次。探针每 60 秒会重启 bootstrap，
#      没有这道门就是每 60 秒抹一次（CS_BOOTSTRAP_REINSTALL 只挡同一条进程链）。
#   ② 时间门：距上次不足 6 小时就拒 —— 防反复重启设备、每次白得一次额度。
# 恢复正常**不会**刷新额度：额度只跟开机和时钟走，不看 LAPI 通没通。
_l3_load() {
    L3_BI=""; L3_N=0; L3_TS=0
    [ -s "$L3_STATE" ] || return 0
    # 末位留给旧版本的四字段（曾带签名），读进来丢掉即可
    read -r L3_BI L3_N L3_TS _l3_old_sig <"$L3_STATE" 2>/dev/null || true
    case "$L3_N" in ''|*[!0-9]*) L3_N=0 ;; esac
    case "$L3_TS" in ''|*[!0-9]*) L3_TS=0 ;; esac
    return 0
}

_l3_gate() {
    _l3_load
    _lg_bi="$(_cur_boot_id)"
    if [ -z "$_lg_bi" ]; then
        log "[自愈] 丢层被拒：读不到 boot_id，无据可依时不做破坏性动作"
        return 1
    fi
    if [ "$L3_BI" != "$_lg_bi" ]; then
        [ -n "$L3_BI" ] && log "[自愈] 新的一次开机（boot_id 变了），丢层次数归零"
        L3_N=0
    fi
    if [ "$L3_N" -ge "$L3_MAX" ]; then
        log "[自愈] 丢层被拒：本次开机已用（$L3_N/$L3_MAX 次）。恢复不会刷新额度，只有重启设备才会"
        return 1
    fi
    _lg_now="$(date +%s 2>/dev/null)"
    case "$_lg_now" in ''|*[!0-9]*) _lg_now=0 ;; esac
    if [ "$L3_TS" -gt 0 ] && [ "$_lg_now" -gt 0 ]; then
        _lg_gap=$((_lg_now - L3_TS))
        if [ "$_lg_gap" -lt "$L3_GAP" ]; then
            log "[自愈] 丢层被拒：距上次丢可写层 ${_lg_gap}s，未满 ${L3_GAP}s（防重启循环反复抹盘）"
            return 1
        fi
    fi
    # 【2026-11-09 用户定】与 full_reinstall 共用额度：它记在 $RESET_BOOT_FILE，
    # 这里也要看一眼，否则同一次开机「结构重装抹一次 + LAPI 丢层再抹一次」。
    if [ "$(cat "$RESET_BOOT_FILE" 2>/dev/null | tr -d ' \t\r\n')" = "$_lg_bi" ]; then
        log "[自愈] 丢层被拒：本次开机已由结构重装抹过现场（$RESET_BOOT_FILE），不重复丢"
        return 1
    fi
    # 记账挪到 _l3_consume，由 _l3_reset_overlay 在强停成功后调用 —— 与 full_reinstall 同一时机。
    # 原来在这里先扣，ct_force_stop / rm -rf 失败时白扣一次，本次开机再没机会。
    log "[自愈] 丢层放行：本次开机将用第 $((L3_N + 1))/$L3_MAX 次额度（记账在强停成功后）"
    return 0
}

# 【2026-11-09】额度记账：强停成功后才写，两个状态文件同时写，让两条路径互相看得见。
_l3_consume() {
    _lc_bi="$(_cur_boot_id)"
    [ -n "$_lc_bi" ] || { log "[自愈] 读不到 boot_id，丢层额度无法记账（本次仍只做这一遍）"; return 0; }
    _lc_now="$(date +%s 2>/dev/null)"
    case "$_lc_now" in ''|*[!0-9]*) _lc_now=0 ;; esac
    printf '%s %s %s\n' "$_lc_bi" "$((L3_N + 1))" "$_lc_now" \
        | atomic_write "$L3_STATE" "" 2>/dev/null \
        || log "[自愈] 丢层记账写入失败（$L3_STATE），本次仍只做这一遍"
    printf '%s\n' "$_lc_bi" | atomic_write "$RESET_BOOT_FILE" "" 2>/dev/null \
        || log "[自愈] 重装额度同步写入失败（$RESET_BOOT_FILE）"
    log "[自愈] 丢层额度已记账：本次开机第 $((L3_N + 1))/$L3_MAX 次"
    return 0
}

# ---- 丢层前把「机器身份会不会变」说清楚 ----
# 2026-10-22 真机核对：基底里 local_api_credentials.yaml（158 B）与 crowdsec.db
# （180224 B）成对存在，而现场那份凭据与基底 md5 完全相同 → 这台机器从未重新注册，
# 丢层不改身份。但这是「现在如此」，不是一个可以写死的假设：哪天换过 key、重新
# register 过，丢层就会把凭据回退成基底那份，console 里多一条 offline 记录。
# 所以要现算现说，而不是在文档里断言「丢层无代价」。
_l3_cred_delta() {
    _cd_a="$ROOTFS/etc/crowdsec/local_api_credentials.yaml"
    _cd_b="$ROM_BASE/etc/crowdsec/local_api_credentials.yaml"
    if [ ! -s "$_cd_a" ]; then
        log "[自愈] 机器身份：现场无凭据文件，丢层后由基底带回一份"
        return 0
    fi
    if [ ! -s "$_cd_b" ]; then
        log "[自愈] 机器身份：基底无凭据，丢层后凭据为空，需 bouncer_fill 重新注册（要重新 Accept）"
        return 0
    fi
    _cd_ha="$(md5sum "$_cd_a" 2>/dev/null | cut -d' ' -f1)"
    _cd_hb="$(md5sum "$_cd_b" 2>/dev/null | cut -d' ' -f1)"
    if [ -n "$_cd_ha" ] && [ "$_cd_ha" = "$_cd_hb" ]; then
        log "[自愈] 机器身份：现场凭据与基底一致（运行期未重新注册），丢层不改变机器身份"
    else
        log "[自愈] 机器身份：现场凭据与基底不同（运行期重新注册过），丢层会回退成基底那份，console 里可能多一条 offline 记录"
    fi
    return 0
}

# ---- 丢层执行 ----
# 与 full_reinstall 的区别只在「谁有资格调它」：那条走结构性损坏 + 开机首跑，
# 这条走 LAPI 不通。破坏动作本身完全一致 —— 基底只读不动，
# 丢 upper/work 即回到构建时验证过的状态。
_l3_reset_overlay() {
    log "[自愈] 丢可写层，回到只读基底（回不来的东西：hub 更新、决策库历史、日志、machines 记录）"
    _l3_cred_delta
    _cred_backup || log "[自愈] 凭证备份失败，继续 —— bouncer_fill 会重新注册"
    ct_force_stop || { log "[自愈] 容器强停失败，放弃丢层（现场一个字节没动）"; return 1; }
    # 【2026-11-09】强停成功才开始记账，与 full_reinstall 的 _reset_consume 同一时机
    _l3_consume
    _overlay_umount || log "[自愈] overlay 卸载未成功，继续尝试抹除"
    rm -rf "$OVL_UPPER" "$OVL_WORK" 2>/dev/null \
        || { log "[自愈] 可写层抹除失败，放弃"; return 1; }
    : > "$REINSTALL_PENDING_FILE" 2>/dev/null || log "[自愈] 未完成标记写入失败（断电将漏计一次）"
    export CS_BOOTSTRAP_REINSTALL=1
    _bs_reexec
    return 1
}

# ---- 主入口 ----
# 返回 0 = 已修好（调用方继续走正常流程）；1 = 没修好（调用方按原逻辑记失败）
_lapi_ladder() {
    # 丢层后重跑时不再进：否则「丢层 → 重跑 → 又丢层」就是递归
    if [ "${CS_BOOTSTRAP_REINSTALL:-0}" = "1" ]; then
        log "[自愈] 本次已是丢层后流程，不再介入"
        return 1
    fi
    # 再探一次：调用方刚重启过容器内 crowdsec，可能刚好生效
    if verify_lapi_reachable; then
        log "[自愈] 重启进程后 8080 已通，不丢层"
        return 0
    fi
    if [ ! -d "$ROM_BASE" ]; then
        log "[自愈] 无只读基底（$ROM_BASE），丢层不可用（老固件只能走镜像解压）"
        return 1
    fi
    _l3_res_gate || return 1
    if ! _l3_gate; then
        log "[自愈] 丢层被拒 → 剩下的可能：基底本身有问题、宿主侧（overlay/磁盘/端口占用）。这三类抹现场都无效，转人工"
        return 1
    fi
    _l3_reset_overlay
    return 1
}

# 结构性损坏判定（v.106 起：自动重装的唯一理由）
# 为什么要有这个函数：修复动作就是脚本的全部能力。「脚本修了还是不行」只说明
# 修复能力对自己负责的那些配置项失效了，不说明容器需要重建 —— 重装跑的是同一套
# 脚本、同一份镜像，只会把同样的失败再走一遍，还要先 rm -rf 掉现场证据。
# 真正值得重建的只有一种情况：脚本再怎么修也够不着的东西被外部破坏了：
#   · rootfs 目录残缺（连 /etc 都没有）——磁盘满、半截解压、被误删
#   · rootfs 没有 init/systemd  ——任何 build_* 都只管配置，不补二进制
#   · 容器目录不可写            ——路径权限/磁盘只读，重装也是同一个地方
# 注意：只看「够不着」的东西。配置不符、last_pull 停滞、组未置位都不在此列，
# 那些都属于「脚本能修」，修不好就走 hard + 探针重试，绝不抹盘。
# 【2026-11-10 用户定】重装职责范围：
#   ① install 组三节点 —— rootfs 里该有的东西（os-release / crowdsec / busybox /
#      acquis / init）全部由 rootfs 节点解压产出，缺了只有重解压镜像能补。
#   ② boot 组的 ct_boot —— 用户 2026-11-10 明确要求：crowdsec 这个容器起不来就删盘重来。
#      它跑到的前提已经集齐：net（网桥/防火墙/SNAT）、install（rootfs/config）、
#      prep（cgroup/容器网络/resolv）全部验证通过 —— 物理前提都在，容器仍起不来，
#      剩下的可能就只有 rootfs 内容或容器内 init 坏了。
#   ★ 只动 $LXC_NAME 这一个容器。full_reinstall 里 ct_force_stop 用 -n "$LXC_NAME"、
#     抹的是 $LXC_PATH/$LXC_NAME 的 rootfs / overlay，同机其他容器一个字节都不碰。
#   别的组失败（日志推不动、LAPI 拉不到、enroll 没 Accept）与 rootfs 无关，绝不抹盘。
#   CS_BOOTSTRAP_REINSTALL_SCOPE=all 恢复「任何组都能触发」，=none 完全关闭。
_reinstall_scope() {
    case "${CS_BOOTSTRAP_REINSTALL_SCOPE:-install}" in
    all) return 0 ;;
    none) return 1 ;;
    esac
    case "$1" in
    img_migrate|rootfs|ct_config) return 0 ;;
    ct_boot) return 0 ;;
    esac
    return 1
}

# 该节点失败时，够不够格转重装（在 _reinstall_scope 放行之后才调用）。
# ct_boot 走「容器起不来」这一条：不看 _structurally_broken —— 容器起不来常常
# 不是因为那 6 个文件缺了，config 写坏、容器内 init 崩、rootfs 解压出半截都算，
# 而这些重解压一遍确实能救。所以这里放行，由 _escalate_reinstall 的四道门兜底。
# 其余（install 组）仍要求 _structurally_broken，避免「配置写不进去」也去抹盘。
_reinstall_should() {
    case "$1" in
    ct_boot) return 0 ;;
    esac
    _structurally_broken
}

_structurally_broken() {
    if [ ! -d "$ROOTFS/etc" ]; then
        log "[结构] rootfs 缺 /etc（目录残缺），判定结构性损坏"
        return 0
    fi
    # 【v.108.17】容器必备资产缺失也算结构性损坏，统一由 ensure 转 full_reinstall。
    # 判据是「资产还在不在」（-s 比 -f 严一档：空文件等于没装），不是「内容对不对」——
    # 内容对不对由各自的 verify_* 判，这里只回答「重解压镜像能不能救」。
    # 覆盖的是一整类：容器里该有的文件被删/被清空/根本没解压出来。
    # v.109-min：init 类型决定「哪些文件算必备」——systemd 版看 crowdsec.service，
    # 极简版看 inittab + init.d/crowdsec。两套都要求 usr/bin/crowdsec 与 os-release。
    if _is_minimal_init; then
        # 【v.108.45】不再列 etc/inittab 与 etc/init.d/crowdsec。
        # 原因：从这一版起，固件里也有这 6 个容器脚本的副本（供 crowdsec-guard 拿
        # /rom squashfs 当只读基准），于是 `-s $ROOTFS/etc/inittab` 在 rootfs
        # 根本没解压时**同样成立**（读的是 squashfs 下层）—— 判据恒真，等于没判。
        # 它们的「存在 + 内容」交给 guard：guard 每轮 cmp，改坏/删掉 60 秒内补回，
        # 代价几十 KB，比整盘重解压 288MB 合理得多。
        # 这里只留**固件里没有**的文件：没有 → 只可能来自 tarball 解压 → 缺了就是真缺。
        _sb_list="$ROOTFS/etc/os-release $ROOTFS/bin/busybox
                  $ROOTFS/usr/bin/crowdsec $ROOTFS/etc/crowdsec/acquis.yaml"
        # os-release 还有第二重身份：它是 verify_rootfs 的「rootfs 已解压」标志。
        # 缺它时其余判据都可能因固件副本而恒真，所以这里单独先判、直接定性。
        if [ ! -s "$ROOTFS/etc/os-release" ]; then
            log "[结构] rootfs 缺 /etc/os-release（未解压或已损坏），判定结构性损坏"
            return 0
        fi
    else
        _sb_list="$ROOTFS/lib/systemd/system/crowdsec.service"
    fi
    for _sb_f in \
        $_sb_list \
        "$ROOTFS/usr/bin/crowdsec" \
        "$ROOTFS/etc/os-release"; do
        if [ ! -s "$_sb_f" ]; then
            log "[结构] rootfs 缺 ${_sb_f#$ROOTFS}（容器资产残缺），判定结构性损坏"
            return 0
        fi
    done
    if [ ! -e "$ROOTFS/sbin/init" ] && [ ! -e "$ROOTFS/lib/systemd/systemd" ]; then
        log "[结构] rootfs 既无 /sbin/init 也无 systemd，判定结构性损坏"
        return 0
    fi
    if ! mkdir -p "$LXC_PATH/$LXC_NAME" 2>/dev/null; then
        log "[结构] 容器目录不可写（$LXC_PATH/$LXC_NAME），判定结构性损坏"
        return 0
    fi
    return 1
}

# 五道门：全过返 0（调用方执行重装）；任一不过返 1（维持 hard 终止）
_escalate_reinstall() {
    _esc_node="${1:-}"
    # ①【v.106】唯一的重装理由：结构性损坏。
    #   原来这里是「last_pull 判定为在拉 → 不升级」，等价于把 last_pull 失效当成
    #   重装前提；现在 last_pull 的持续监视已整体移交运行期探针，修不好只报人工介入，
    #   所以这一门换成结构判定，语义反转过来：不是 last_pull 说了算，是资产完好度说了算。
    #   【2026-11-10 用户定】ct_boot 例外：容器起不来的时候，那 6 个文件往往一个不缺
    #   （坏的是容器 config、容器内 init、或 rootfs 解压出半截），_structurally_broken
    #   判不出来。用户要求「crowdsec 容器起不来就删盘重来」，所以这一门对它放行，
    #   由 ③额度 ④失败次数 ⑤防递归 三道门收口。
    if [ "$_esc_node" = "ct_boot" ]; then
        log "[重装] 触发源：ct_boot（容器 $LXC_NAME 经 4 轮修复仍未起来），跳过文件级结构判定"
    else
        _structurally_broken || {
            log "[重装] 非结构性损坏（rootfs / init / 容器目录均完好），不重装"
            return 1
        }
    fi
    _stamp_present || {
        log "[重装] 无 installed 标记（本流程未曾完整跑通/初次安装），不自动重装，防开机反复重置"
        return 1
    }
    # ②【v.108.18】重启之后才重置：只有「本次开机首跑」允许重置。
    #   运行期重跑（探针 60s 轮询触发、手动重跑）时 boot_id 没变 → 不是首跑 → 拒绝重置。
    #   运行期多半是容器被停掉/网络抖动这类可修问题，修一下就好；抹 rootfs 既中断现场又没必要。
    #   【2026-11-10 用户定】ct_boot 例外：build_ct_boot 已经试过 lxc-auto → 兜底 lxc-start
    #   → 重试 → _ct_revive 重写 config 重启，四轮全败。这时候「抖动」的解释已经不成立，
    #   容器是真的起不来。允许运行期重装，但仍受③额度（一次开机只抹一次）约束。
    #   想恢复严格模式：CS_BOOTSTRAP_REINSTALL_RUNTIME=0。
    if [ "${_BS_FIRST_RUN:-0}" != 1 ]; then
        if [ "$_esc_node" = "ct_boot" ] && [ "${CS_BOOTSTRAP_REINSTALL_RUNTIME:-1}" = 1 ]; then
            log "[重装] 运行期触发（ct_boot 四轮修复无效），按用户设定允许重装；额度仍限一次开机一次"
        else
            log "[重装] 本次开机已跑过引导（非重启后首跑），不重置；先走原地修复"
            return 1
        fi
    fi
    # ③【v.108.19】额度门：本次开机只能重置一次。
    #   ②说的是「这次跑得早不早」，③说的是「这次开机还欠不欠你一次」。两者都要：
    #   ②挡探针在运行期重跑，③挡同一次开机里「首跑失败 → 再重启脚本再抹一遍」。
    if ! _reset_quota_ok; then
        log "[重装] 本次开机（$(_cur_boot_id)）的重置额度已用完，不再重置；转人工介入"
        return 1
    fi
    # ④ 本次开机的失败次数。reinstall_fail 在每个新开机的首跑处清零（见 main），
    #   所以它数的是「这次开机重置过几次、成没成」，不再是终身累计。
    _c=$(_reinstall_fail_count)
    if [ "$_c" -ge "$REINSTALL_MAX" ]; then
        log "[重装] 本次开机已重置失败 $_c 次（阈值 $REINSTALL_MAX），停止自动重装，转人工介入"
        return 1
    fi
    if [ "${CS_BOOTSTRAP_REINSTALL:-0}" = 1 ]; then
        log "[重装] 本次已是重装后流程，禁止递归重装"
        return 1
    fi
    # overlay 模式下基底在 squashfs 里只读，不存在「镜像被打断」这回事
    [ -d "$ROM_BASE" ] || verify_img_migrate || {
        log "[重装] 镜像不可用（$TARBALL gzip -t 不过），没有好镜像宁可失败也不抹 rootfs"
        return 1
    }
    return 0
}

full_reinstall() {
    # 【2026-11-10】第一个参数 = 触发节点名（ct_boot 会在 _escalate_reinstall 里
    # 走「运行期也允许」的例外）。老调用点不传也一样跑，只是走严格门。
    _fr_node="${1:-}"
    log "[重装] 结构性损坏，进入彻底重装流程（v.106 起这是自动重装的唯一入口）"
    # 【2026-11-10 用户定】只重建 $LXC_NAME 这一个容器，同机其他容器一律不碰。
    # 这行日志把「谁会被动、谁不会被碰」写进现场，事后查日志不用再猜。
    _fr_others=$(run lxc-ls -P "$LXC_PATH" --running 2>/dev/null | grep -vx "$LXC_NAME" | tr '\n' ' ')
    log "[重装] 本次只重建容器 $LXC_NAME（$LXC_PATH/$LXC_NAME）；其他运行中的容器不动：${_fr_others:-无}"
    _escalate_reinstall "$_fr_node" || { log "[重装] 不满足重装条件，维持 hard 终止"; return 1; }
    _reinstall_diag
    _cred_backup || true
    ct_force_stop || { log "[重装] 容器 3 轮强停仍未停，放弃重装"; return 1; }
    # 【v.108.19】到这一步才开始破坏性动作，此时才把额度记掉。
    # 放在强停之后是有意的：强停失败时 rootfs 一个字节都没动，不该白丢一次机会。
    _reset_consume "结构性损坏，已强停容器并即将抹除 rootfs"
    _overlay_umount || log "[重装] overlay 卸载未成功，继续尝试抹除"
    if [ -d "$ROM_BASE" ]; then
        # 基底只读不动，丢可写层即可；ROOTFS 是挂载点，清它没有意义
        rm -rf "$OVL_UPPER" "$OVL_WORK" 2>/dev/null \
            || { log "[重装] 可写层抹除失败，放弃重装"; return 1; }
    else
        rm -rf "$ROOTFS" 2>/dev/null || { log "[重装] rootfs 抹除失败，放弃重装"; return 1; }
    fi
    : > "$REINSTALL_PENDING_FILE" 2>/dev/null || log "[重装] 未完成标记写入失败（断电将漏计一次）"
    export CS_BOOTSTRAP_REINSTALL=1
    _bs_reexec
    # exec 成功则不返回；exec 失败（理论上不发生）则由 EXIT trap 兜底计数
    return 1
}

# =====================================================================
# 置位恢复（三类，见各函数注释）

# ① 进程内变量归零。_bs_clear_flags 幂等：重复调用无副作用。
# v.99 起置位的值是 V:<ts>/B:<ts>/R:<ts>，所以「归零」= 清成空串（不是写成 0）。
_ipfwd_snapshot() {
    _cur=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
    [ -n "$_cur" ] || _cur=""
    _ipfwd_touched=0
    case "$_cur" in
        1)
            if [ -f "$IPFWD_SENTINEL" ]; then
                # 上次是脚本置的，且还没还原（上次异常退出）。真原值按 0 算。
                _ipfwd_orig=0
                log "[恢复] 检出上次遗留的 ip_forward 哨兵：当前 1 是本脚本置的，按原值 0 处理"
            else
                _ipfwd_orig=1     # 别人设的，不动
            fi
            ;;
        0|"")
            _ipfwd_orig=0
            # 系统已自己回 0（重启过了）：顺手把残留哨兵清掉，免得下次误判
            [ -f "$IPFWD_SENTINEL" ] && rm -f "$IPFWD_SENTINEL" 2>/dev/null
            ;;
        *)
            _ipfwd_orig="$_cur"
            ;;
    esac
    return 0
}
# 记号：置了 1，就落下哨兵（供下次进程判断"这个 1 是我置的"）
_ipfwd_mark() {
    mkdir -p "$STATE_DIR" 2>/dev/null
    : > "$IPFWD_SENTINEL" 2>/dev/null || return 0
    return 0
}
_ipfwd_restore() {
    # 本轮没动过它，或没拿到原值：无需恢复
    [ "${_ipfwd_touched:-0}" = 1 ] || return 0
    [ -n "${_ipfwd_orig:-}" ] || return 0
    # 引导成功（写了 installed）→ 保留 1，这是期望稳态，写回 0 反而把容器网搞断。
    # 此时哨兵留着，表示"这个 1 是脚本的"，下次重跑能正确判定原值。
    [ "${_bs_stamped:-0}" = 1 ] && return 0
    # --net-only 跑通同理：没有容器，但路由器自身的转发必须保持 1。
    # 这条路径永远写不到 installed 标记，不能靠 _bs_stamped 兜住。
    [ "${_NET_ONLY_OK:-0}" = 1 ] && return 0
    _ir_cur=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
    if [ "$_ir_cur" = "$_ipfwd_orig" ]; then
        rm -f "$IPFWD_SENTINEL" 2>/dev/null
        return 0
    fi
    if echo "$_ipfwd_orig" >/proc/sys/net/ipv4/ip_forward 2>/dev/null; then
        rm -f "$IPFWD_SENTINEL" 2>/dev/null   # 还原成功，哨兵使命结束
        log "[恢复] 引导未成功，ip_forward 已还原为 $_ipfwd_orig（原值）"
    else
        log "[恢复] 引导未成功，但 ip_forward 还原失败（/proc 只读），当前值 $_ir_cur"
        log "[恢复] 哨兵保留：下次重跑时仍能认出这个 1 是脚本置的"
    fi
    return 0
}

# ③ reinstall_pending 状态说明（只报告，不动文件）
