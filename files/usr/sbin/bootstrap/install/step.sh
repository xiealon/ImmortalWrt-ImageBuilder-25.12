#!/bin/sh
# bootstrap/install/step.sh —— INSTALL 组（install）
#
# 两步结构：
#   第一步 --check   只检测，一个字节都不写。逐节点跑 verify_<node>，
#                    全部达标返回 0；有不过的把它们打在 stderr 并返回 1。
#   第二步 --fix     只修「检测不过」的那些（内部走 ensure，先查后改），
#                    修完复检一次；仍不过返回 1。
#
# 本组节点（按 DAG 顺序）：img_migrate rootfs ct_config
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

MY_GROUP="INSTALL"
MY_NODES="img_migrate rootfs ct_config"

verify_img_migrate() {
    # 【v.108.56】overlay 模式：容器来自 /rom 只读基底，不存在「要迁移镜像包」这回事。
    # 少了这一条，img_migrate 节点每轮都因「无 tarball」判失败，而它不在 SOFT_NODES，
    # 一轮就 hard exit —— 表现为「固件正常、容器永不启动」，且日志只说无镜像可迁移。
    [ -d "$ROM_BASE" ] && return 0
    [ -f "$TARBALL" ] || return 1
    # gzip -t 做全量 CRC 校验：包被截断或写坏这里直接不过，比只数目录名可靠
    gzip -t "$TARBALL" >/dev/null 2>&1 || return 1
    # 再确认这确实是 rootfs 包：前 200 条里出现任一顶层目录即可。
    # 原来要求 etc/ 与 usr/ 同时出现——tar 是深度优先打包（-C "$R" .），./usr 排在
    # ./etc 的上万条文件之后，前 200 条里永远看不到它，于是完好的包被判成半截，
    # verify 每轮都不过、build 又认定包完整直接 return 0，容器于是永远建不起来。
    run_tar tar -tzf "$TARBALL" 2>/dev/null | head -n 200 | grep -qE '^(\./)?(etc|usr|bin|lib)/'
}
build_img_migrate() {
    if [ -f "$TARBALL" ]; then
        gzip -t "$TARBALL" >/dev/null 2>&1 && return 0
        log "镜像文件损坏（gzip 完整性校验失败），删除后重新迁移"
        rm -f "$TARBALL"
    fi
    # 运行副本缺失/损坏：先从只读基准 /rom 恢复。squashfs 挂的是 ro，原件改不掉也
    # 删不掉，比任何放在可写层的备份都硬；副本被 rm 时 upper 只有 whiteout，cp 回去
    # 会直接把 whiteout 顶掉。非 squashfs 平台没有该路径，这段自动跳过。
    if [ -f "/rom$TARBALL" ]; then
        mkdir -p "$CS_HOME" 2>/dev/null
        cp -f "/rom$TARBALL" "$TARBALL" 2>/dev/null \
            && gzip -t "$TARBALL" >/dev/null 2>&1 \
            && { log "镜像已从 /rom 恢复：$TARBALL"; return 0; }
        rm -f "$TARBALL"
        log "从 /rom 恢复失败（写不进 overlay 或包本身有问题）"
    fi
    [ -f "$LEGACY_TARBALL" ] || { log "无镜像可迁移"; return 1; }
    mkdir -p "$CS_HOME" 2>/dev/null && mv -f "$LEGACY_TARBALL" "$TARBALL" 2>/dev/null \
        && log "镜像已从 $LEGACY_TARBALL 迁移到 $TARBALL"
}
# 容器 config 内容完整性（v.79：半截 config 会让启动链判据误判「在位」→ 开机即失败）
# v.108：不再硬查 lxc.utsname。apply_cfg 的裁剪循环会按 `lxc-info` 报错里
# `at line "..."` 的内容把该行整行 grep -v 掉（LXC 6.x 已改用 lxc.uts.name，
# 旧键会被判无效），而这里若同时硬要求 lxc.utsname 存在，就形成
# 「build 删键 → verify 不过 → 再 build 再删」的死循环，BOOT 组每轮 hard 失败、
# 容器永远起不来。判据改为「两份键在 + lxc 自己能把这份 config 解析出来」。
verify_ct_config() {
    [ -s "$CFG" ] || return 1
    grep -q "lxc.rootfs.path" "$CFG" 2>/dev/null || return 1
    grep -q "lxc.net.0.type" "$CFG" 2>/dev/null || return 1
    # 【2026-10-31.0256】lxc-info 必在，去掉 command -v 外壳（用户 2026-10-31 定）。
    _vcc=$(run lxc-info -P "$LXC_PATH" -n "$LXC_NAME" 2>&1)
    printf '%s\n' "$_vcc" | grep -q 'at line "' && return 1
    return 0
}
build_ct_config() {
    rm -f "$CFG"                       # 删旧建新：内容不一致时不用半截旧文件垫底
    write_cfg || { log "容器 config 写入失败"; return 1; }
    log "已写入容器 config"
    apply_cfg || { log "config 无法解析"; return 1; }
}
# rootfs 完整性（v.79：CROWDSEC_CFG 需含 crowdsec config 必备段，半截文件判不符）
verify_rootfs() {
    # overlay 模式：挂着 + stamp 对得上就算就绪。内容由只读 lower 保证，
    # 不必再逐文件验 —— os-release 恒在，拿它当判据在这里已经失去意义。
    if _overlay_mounted; then
        _upper_stamp_ok && return 0
    fi
    [ -d "$ROOTFS/etc" ] || return 1
    [ -d "$ROOTFS/usr" ] || return 1
    [ -s "$ROOTFS/etc/os-release" ] || return 1
    grep -q '^ID=' "$ROOTFS/etc/os-release" 2>/dev/null || return 1
    [ -s "$CROWDSEC_CFG" ] || return 1
    grep -q "api:" "$CROWDSEC_CFG" 2>/dev/null || return 1
    grep -q "common:" "$CROWDSEC_CFG" 2>/dev/null || return 1
}
build_rootfs() {
    log "rootfs 未就绪，开始重建"
    # 首选：/rom 只读基底 + overlay 可写层（零解压、固定文件不可改）
    if build_overlay_root; then
        _cred_restore || log "[凭据] 恢复未成功，enroll 步将走重注册"
        _recovering=true
        return 0
    fi
    # 回退：从 tarball 解压（老固件 / 内核不支持 overlay / /overlay 不可写）
    log "[overlay] 不可用，回退到镜像解压"
    rebuild_from_image || { log "镜像解压失败"; return 1; }
    _cred_restore || log "[凭据] 恢复未成功，enroll 步将走重注册"
    _recovering=true
}
# 容器内构建子步骤判定（v.93 起由 ct_net/ct_bootlink/ct_resolv/acquis 等节点各自闭环）：
# 每一步独立 verify 就绪探测，供所在节点的 verify/build 与整体快照判定共用，判定标准不变
write_cfg() {
    _dst="${1:-$CFG}"
    # 容器名键按 LXC 版本选：4.0 起是 lxc.uts.name，之前是 lxc.utsname。
    # 写旧键时 LXC 6.x 会判无效，apply_cfg 的裁剪循环把整行 grep -v 掉 ——
    # 表面「自愈成功」，实际让 config 永远少这一行（现场 cat 出来确实没有
    # lxc.utsname），随后 verify_ct_config 判「不完整」、BOOT 组 hard 失败。
    # 版本取不到就按新键写（4.0 以下早已没人用；真写错也只是名字退回目录名）。
    _wm_key="lxc.uts.name"
    _wm_ver=$(run lxc-info --version 2>/dev/null | sed -n 's/^\([0-9][0-9]*\)\..*/\1/p')
    if [ -n "$_wm_ver" ] && [ "$_wm_ver" -lt 4 ] 2>/dev/null; then
        _wm_key="lxc.utsname"
    fi
    atomic_write "$_dst" "lxc.rootfs.path" <<EOF || return 1
lxc.arch = amd64
${_wm_key} = $LXC_NAME
lxc.include = /usr/share/lxc/config/common.conf
lxc.rootfs.path = dir:$ROOTFS
lxc.init.cmd = /sbin/init
lxc.autodev = 1
lxc.net.0.type = veth
lxc.net.0.link = lxcbr0
lxc.net.0.flags = up
lxc.net.0.hwaddr = 10:66:6A:7C:05:9A
lxc.tty.max = 4
lxc.pty.max = 1024
EOF
}

apply_cfg() {
    write_cfg "$CFG.tmp0" || return 1
    [ -s "$CFG.tmp0" ] || { rm -f "$CFG.tmp0"; return 1; }   # tmp 半截不落盘
    if [ -f "$CFG" ] && [ ! -f /usr/share/lxc/config/common.conf ]; then
        grep -v '^[[:space:]]*lxc.include' "$CFG.tmp0" > "$CFG" 2>/dev/null \
            && rm -f "$CFG.tmp0" || { rm -f "$CFG.tmp0"; return 1; }
    else
        mv -f "$CFG.tmp0" "$CFG" 2>/dev/null || return 1
    fi
    _trim=0
    while [ "$_trim" -lt 20 ]; do
        _err=$(run lxc-info -P "$LXC_PATH" -n "$LXC_NAME" 2>&1) && return 0
        _bad=$(printf '%s\n' "$_err" | sed -n 's/.*at line "\([^"]*\)".*/\1/p' | head -n1)
        [ -n "$_bad" ] || break
        grep -v -F "$_bad" "$CFG" > "$CFG.tmp1" 2>/dev/null && mv -f "$CFG.tmp1" "$CFG" || break
        _trim=$((_trim+1))
    done
    ct_exists
}

# 【v.108.55】容器包直接从 /rom 只读原件解压 —— 不拷贝、不比对。
# 为什么：/rom 是 squashfs，编译期写入、运行期不可写，它自己就是可信来源。
# 在可信来源外面再套一层「拷贝到 /etc 再 cmp」，只换来两个新的失败方式
# （overlay 写满、拷贝被截断），以及把 107 MB 复制进 overlay 白吃可写空间；
# 而 cmp 只能证明「刚拷的这份等于原件」，证明不了任何它本来就没法证明的事。
# 只有老固件里 /rom 压根没有这份包（当年只有 lxc-ubuntu.tar.gz）时，
# 才退回 /etc 的工作副本，并对它做 gzip 结构自检 —— 且日志如实写明来源不可证。
ROM_TARBALL="${CS_ROM_TARBALL:-/rom$CS_HOME/lxc-crowdsec.tar.gz}"
SRC_TARBALL=""

_tarball_usable() {
    [ -f "$1" ] || return 1
    [ -s "$1" ] || return 1
    run_tar tar -tzf "$1" >/dev/null 2>&1 || return 1
    return 0
}

_pick_tarball() {
    # 首选固件里的只读原件：可信、零拷贝、不占 overlay。
    if [ -f "$ROM_TARBALL" ] && [ -s "$ROM_TARBALL" ]; then
        SRC_TARBALL="$ROM_TARBALL"
        return 0
    fi
    # 老固件的退路：/etc 那份可能被人换过，只能证明「是个能解的 gzip」，证明不了来源。
    if _tarball_usable "$TARBALL"; then
        SRC_TARBALL="$TARBALL"
        log "[包] 固件里没有 /rom 副本，改用工作副本 $TARBALL（仅 gzip 结构自检，来源无法证明）"
        return 0
    fi
    log "[包] 无可用容器包：$ROM_TARBALL 与 $TARBALL 都不可用"
    return 1
}

# 【2026-11-11】overlay 五函数已挪到 _lib.sh（跨组共用，见该文件末尾说明）

rebuild_from_image() {
    log "尝试从镜像解压 rootfs：$TARBALL"
    # 【v.108.55】选源失败就不再往下走：rm -rf "$ROOTFS" 是不可逆的。
    _pick_tarball || return 1
    log "[包] 解压源：$SRC_TARBALL"
    ct_force_stop || return 1
    # overlay 挂着时 rm -rf 会 busy 且删不干净：先卸载再抹
    _overlay_umount || { log "[overlay] $ROOTFS 卸载失败，放弃解压"; return 1; }
    rm -rf "$ROOTFS" 2>/dev/null
    mkdir -p "$ROOTFS" || return 1
    if ( set -C; : > "$ROOTFS/.extracting" ) 2>/dev/null; then
        if run_tar tar -xzf "$SRC_TARBALL" -C "$ROOTFS"; then
            rm -f "$ROOTFS/.extracting"
            log "解压完成（$(du -sh "$ROOTFS" 2>/dev/null | cut -f1)）"
            return 0
        fi
        rm -f "$ROOTFS/.extracting"
        log "解压失败"
        return 1
    fi
    log "另一实例正在解压，等待完成"
    _i=0
    while [ -f "$ROOTFS/.extracting" ]; do
        _i=$((_i+1)); [ "$_i" -ge $MAX_WAIT ] && break; sleep $SLEEP
    done
    [ -f "$CROWDSEC_CFG" ]
}



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
