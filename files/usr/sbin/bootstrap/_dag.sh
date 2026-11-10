#!/bin/sh
# bootstrap/_dag.sh —— DAG 定义 + 调度器
#
# 内容：
#   · DAG_NODES / DEP_* / GROUP_SEQ / GROUP_DEP_* / GROUP_TITLE_* / NODE_GROUP_*
#   · dag_order     拓扑排序（组间按 GROUP_SEQ，组内按 DEP 边）
#   · ensure        单节点：先查现场 → 过了记 V → 没过才 build → 记账 B
#   · ensure_group  组调度：前置组没置位整组跳过
#   · flush_uci     统一 commit + 分组 reload（只在主流程末尾调一次）
#   · verify_<组> / build_<组>  9 对组级入口

DAG_NODES="img_migrate rootfs ct_config br_lan_ports lan_static dhcp_ignore bridge ct_net lxc_zone fwd_rules lan_input snat ip_forward cgroup_mount ct_bootlink svc_bind docker_fw pkg_base lxc_auto ct_resolv capi_block ct_boot logconf lapi_fetch bouncer_fill bouncer_verify capi_release enroll"

# ---- 网络基线模式（--net-only）----
# 适用场景：镜像没进固件（v.107.7 起不再有 Include Crowdsec 开关，容器恒内置，
# 所以「没有镜像」一律是异常：生成失败 / 被删 / 刷的是老固件）。但 Router IP /
# 掩码 / 网关 / DNS 仍然写进了 /etc/config/custom_router_*.txt，其唯一消费者是
# PREP 里的 br_lan_ports / lan_static —— 与容器无关，没理由连网络一起放弃。
# 网络是生命线：镜像没了还能进后台查，网络没了只能扛机器去接显示器。
#
# 该模式只跑 PREP，并摘掉下面这些节点：它们全都与容器强相关，本机没容器时跑了
# 只会失败或被 firewall 拒绝（引用不存在的接口）：
#   bridge       建 lxcbr0
#   ct_net       写容器内 10-eth0.network
#   ct_bootlink  写容器内自启软链
#   ct_resolv    写容器内 resolv.conf
#   lxc_zone     firewall 里声明 lxcbr0 所在 zone
#   fwd_rules    lxcbr0 的 forward 规则
#   snat         10.1.0.0/24 → LAN IP 的源地址改写（只服务容器出网）
#
# cgroup_mount 不在此列：它挂的是 /sys/fs/cgroup/systemd（容器内 systemd 的硬前置），
# 不碰 rootfs，且 verify_cgroup_mount 在 cgroup2 统一层级下第二判据直接通过、
# 实际很少动手；万一真去挂，build_cgroup_mount 也恒 return 0，不会 hard 终止。
# 留在链上一分钱不花，还省得「镜像补上之后头一次起容器先去补挂」这一跳。
NET_ONLY=0
NET_ONLY_SKIP="bridge ct_net ct_bootlink lxc_auto ct_resolv lxc_zone fwd_rules snat"

# 小步骤依赖（DAG 边）：只声明真实的强先后关系，不做无意义的线性串联。
# 注意：PREP 组内的"防火墙小步骤依赖网络小步骤"，是因为防火墙规则要引用接口名；
# 不构成组间死锁（同组内排序由 dag_order 的段内拓扑排序解决）。
DEP_img_migrate=""
DEP_ct_config="img_migrate"
DEP_rootfs="img_migrate"
# ---- PREP：容器启动前的静态准备 ----
DEP_br_lan_ports=""
DEP_lan_static="br_lan_ports"
DEP_dhcp_ignore=""
DEP_bridge="lan_static"
# ct_net / ct_bootlink / ct_resolv 写的是容器 rootfs 里的文件（10-eth0.network、
# 自启软链、resolv.conf），显式依赖 rootfs。rootfs 属 INSTALL 组，而 INSTALL 排在
# GROUP_SEQ 第一位，跨组依赖天然满足。v.107.4 之前 INSTALL 排在 PREP 之后，
# 而 PREP 里这三个就要写 rootfs → 必失败 → hard 终止 → rootfs 永不解压。
DEP_ct_net="bridge rootfs"
DEP_cgroup_mount=""
DEP_ct_bootlink="cgroup_mount rootfs"
# lxc_auto 只碰路由器侧的 uci 配置与 rc 软链，跟 rootfs / 容器状态都无关：
# 正因为它不依赖任何东西，才能在「容器跑着、配置却空了」时被验出来并补回去。
DEP_lxc_auto=""
DEP_ct_resolv="ct_net rootfs"
DEP_svc_bind=""
# ---- 路由侧防火墙：每类接口一个独立小步骤 ----
DEP_lxc_zone="bridge"
DEP_fwd_rules="lxc_zone"
# v.108.27：wan / wan6 段在 main 一开始就被无条件删除（purge_wan_sections），
# 不再是 DAG 节点，也没有 wan zone input 这一步 —— 旁路由没有 WAN 面需要收紧。
# snat 只读 lan 地址与容器网段（由 BRIDGE_IP /
# CONTAINER_IP 推导，不依赖 ct_net 节点的执行结果）。两者都不写容器 rootfs，
# 不加 ct_net 依赖，避免与 PREP 内其他节点形成无谓的串行。
DEP_lan_input="br_lan_ports"
DEP_snat="lan_static"
DEP_ip_forward=""
DEP_docker_fw=""
# ---- 容器内静态配置：启动前一次写完，启动后不再碰文件 ----
DEP_capi_block="rootfs ct_bootlink"
# ---- 启动：启动前必须全部备妥 ----
DEP_ct_boot="ct_config rootfs lxc_zone snat cgroup_mount ct_bootlink ct_resolv capi_block"
# ---- 启动后的运行态 ----
# 【v.108.22】LOGCONF 由两个节点（acquis + log_forward）合成一个节点 logconf。
# 它们本来就是同一件事的两半：宿主把 syslog 推给容器、容器用 acquisitions 收并解析。
# 拆成两个节点只会让日志里多两行「构建执行」，出问题时还得自己拼回去看。
# 【v.108.23】listen_uri（容器内 LAPI 对外监听地址）也并进来：它和 acquis 一样，
# 都是「容器内 crowdsec 起来之前必须就位的静态配置」。放在三处之外单干的结果是
# 容易漏 —— 漏了的表现是 bouncer 永远拉不到，而日志里看不出少做了什么。
# 现在 logconf 一个节点承诺三件事，缺一不可：
#   ① 宿主把 syslog 推给容器（log_forward）
#   ② 容器用 acquisitions 收并解析（acquis）
#   ③ 容器内 LAPI 监听 0.0.0.0:PORT，路由器上的 bouncer 才连得上（listen_uri）
DEP_logconf="ct_boot ct_net"
DEP_lapi_fetch="ct_boot"
DEP_bouncer_fill="lapi_fetch logconf"
DEP_bouncer_verify="bouncer_fill"
DEP_capi_release="bouncer_verify"
# ---- ENROLL：console 注册（v.108.49 补的节点，之前这一组是空壳）----
# 依赖 capi_release：capi_block 在容器启动前把 online_client 注释掉，bouncer 验证通过
# 后由 capi_release 放回来；注册要连中央 API，必须等它放出来之后再做。
# 【v.180.157】DEP_enroll 不再挂 deps —— DEPS 组已随 smartdns 一起删除。
# 注册要连中央 API、网络必须通，这一点由 enroll 自己的失败体现：它是 SOFT 节点，
# 失败只记日志、不中止引导，下一轮自动重试。
DEP_enroll="capi_release"

# INSTALL 排第一：rootfs 解压是 ct_net / ct_bootlink / ct_resolv（写容器内文件）
# 以及 capi_block / ct_boot 的硬前置。放在 PREP 之后时，PREP 里那些节点拿不到
# rootfs → 失败 → hard 终止 → INSTALL 永不执行 → rootfs 永不解压（自锁）。
GROUP_SEQ="NETBASE INSTALL PREP CAPIBLOCK BOOT LOGCONF LAPI BOUNCERVERIFY ENROLL"
GROUP_TITLE_NETBASE="网络基线（br-lan / lxcbr0 双网桥 + 防火墙 zone 与转发规则），最优先执行，不依赖 rootfs"
GROUP_TITLE_INSTALL="安装容器（迁移校验镜像 / 解压 rootfs / 写 config）"
GROUP_TITLE_PREP="容器启动前的全部静态准备（路由器网桥 / 容器网络 / cgroup）"
GROUP_TITLE_CAPIBLOCK="屏蔽 CAPI（容器内 online_client 停用）"
GROUP_TITLE_BOOT="启动容器（唯一一次开机）"
GROUP_TITLE_LOGCONF="日志链路与对外监听（宿主推送 + 容器采集 + LAPI 监听地址）"
GROUP_TITLE_LAPI="获取 LAPI 并填入路由器 bouncer"
GROUP_TITLE_BOUNCERVERIFY="验证 bouncer 列表生效并解开 CAPI"
GROUP_TITLE_ENROLL="Console Enroll"
# 组间强依赖只有一条主线：容器启动前必须先备好网桥/容器网络/cgroup，
# 启动后才有运行态可言。其余组按功能细分，依赖如实声明（不强加线性）。
GROUP_DEP_INSTALL=""
GROUP_DEP_NETBASE=""
GROUP_DEP_PREP="NETBASE INSTALL"
GROUP_DEP_CAPIBLOCK="INSTALL PREP"
GROUP_DEP_BOOT="NETBASE PREP INSTALL CAPIBLOCK"
GROUP_DEP_LOGCONF="BOOT"
GROUP_DEP_LAPI="BOOT"
GROUP_DEP_BOUNCERVERIFY="LOGCONF LAPI"
# 【v.180.157】ENROLL 改为依赖 BOUNCERVERIFY：原先的 SMARTCHK → DEPS → ENROLL
# 两跳链随之消失（smartdns 已移出 bootstrap，这两个组不存在了）。
GROUP_DEP_ENROLL="BOUNCERVERIFY"
NODE_GROUP_img_migrate=INSTALL
NODE_GROUP_rootfs=INSTALL
NODE_GROUP_ct_config=INSTALL
NODE_GROUP_br_lan_ports=NETBASE
NODE_GROUP_lan_static=NETBASE
NODE_GROUP_dhcp_ignore=NETBASE
NODE_GROUP_bridge=NETBASE
NODE_GROUP_ct_net=PREP
NODE_GROUP_cgroup_mount=PREP
NODE_GROUP_ct_bootlink=PREP
NODE_GROUP_lxc_auto=NETBASE
NODE_GROUP_ct_resolv=PREP
NODE_GROUP_lxc_zone=NETBASE
NODE_GROUP_fwd_rules=NETBASE
NODE_GROUP_lan_input=NETBASE
NODE_GROUP_snat=NETBASE
NODE_GROUP_ip_forward=NETBASE
NODE_GROUP_svc_bind=NETBASE
NODE_GROUP_docker_fw=NETBASE
NODE_GROUP_capi_block=CAPIBLOCK
NODE_GROUP_ct_boot=BOOT
NODE_GROUP_logconf=LOGCONF
NODE_GROUP_lapi_fetch=LAPI
NODE_GROUP_bouncer_fill=LAPI
NODE_GROUP_bouncer_verify=BOUNCERVERIFY
NODE_GROUP_capi_release=BOUNCERVERIFY
NODE_GROUP_enroll=ENROLL
NODE_GROUP_pkg_base=NETBASE

# 层级拓扑排序（v.79）：先校验「每个小步骤都对应到某个组、组间依赖不倒置」，
# 再按 GROUP_SEQ 分段，段内 Kahn 变体迭代排序（无递归，天然检测环/缺失/跨组依赖倒置）
dag_order() {
    _order=""
    # 校验 1：每个小步骤都必须声明归属（NODE_GROUP_<node>），且归属的组在序列中
    for _n in $DAG_NODES; do
        _ng=$(eval "echo \$NODE_GROUP_$_n")
        if [ -z "$_ng" ]; then
            log "[DAG] 小步骤 $_n 未声明归属组（NODE_GROUP_$_n 缺失），终止"
            exit 1
        fi
        case " $GROUP_SEQ " in
            *" $_ng "*) ;;
            *) log "[DAG] 小步骤 $_n 归属的组 $_ng 不在 GROUP_SEQ 中，终止"; exit 1 ;;
        esac
    done
    # 校验 2：组间依赖不得倒置——GROUP_DEP 里的组必须排在本组之前（否则环/死等）
    _gseen=""
    for _g in $GROUP_SEQ; do
        for _gd in $(eval "echo \$GROUP_DEP_$_g"); do
            case " $_gseen " in
                *" $_gd "*) ;;
                *) log "[DAG] 组 $_g 绑定 $_gd，但 $_gd 未排在其之前（组依赖环/倒置），终止"; exit 1 ;;
            esac
        done
        _gseen="$_gseen $_g"
    done
    # 按组分段，段内拓扑排序；前置组的节点已在 _order 中，跨组依赖天然满足
    _gprev=""
    for _g in $GROUP_SEQ; do
        _gnodes=""
        for _n in $DAG_NODES; do
            [ "$(eval "echo \$NODE_GROUP_$_n")" = "$_g" ] && _gnodes="$_gnodes $_n"
        done
        _remaining="$_gnodes"
        while [ -n "$_remaining" ]; do
            _progress=0
            _next=""
            for _n in $_remaining; do
                _ready=1
                for _d in $(eval "echo \$DEP_$_n"); do
                    _dg=$(eval "echo \$NODE_GROUP_$_d")
                    if [ "$_dg" != "$_g" ]; then
                        case " $_gprev " in
                            *" $_dg "*) continue ;;
                            *) _ready=0; break ;;
                        esac
                    fi
                    case " $_order " in *" $_d "*) ;; *) _ready=0; break ;; esac
                done
                if [ "$_ready" = 1 ]; then
                    _order="$_order $_n"
                    _progress=1
                else
                    _next="$_next $_n"
                fi
            done
            _remaining="$_next"
            if [ "$_progress" = 0 ]; then
                log "[DAG] 组 $_g 内依赖环或跨组依赖未就绪（剩余：$_remaining），终止"
                exit 1
            fi
        done
        log "[DAG] 组 $_g 就序（$(echo $_gnodes | wc -w | tr -d ' ') 个小步骤）"
        _gprev="$_gprev $_g"
    done
    log "[DAG] 层级拓扑序已生成（$(echo $GROUP_SEQ | wc -w | tr -d ' ') 个组 / $(echo $_order | wc -w | tr -d ' ') 个小步骤）"
}

# 调度器（v.79 统一 ensure + hard，迭代式无递归）：
#   依赖未就绪 → 跳过本级并沿链传播（跳过即未完成，下游连带跳过）
#   verify 就绪 → 跳过；否则 build + 复核，至多两次
#   两次均未通过（build 失败或复核仍不符）→ hard 失败，立即终止引导
#   （半就绪状态继续引导比开机失败更危险：SNAT/防火墙缺项的容器会裸奔）
# 只验不写清单（v.95 起已清空）：
#   历史原因——网络/防火墙节点曾一律只验证、不修改，因为它们由 LuCI 生成，
#   改完不 reload 不生效，反而会把用户配好的东西覆盖成「看似正确却不工作」。
#   现改为「验证 + 修改 + commit + 分组 reload」，真正生效，因此不再需要这份清单。
#   保留变量与分支结构是为了：① 万一将来某项要退回只读，加回名字即可；
#   ② ensure() 的 else 分支仍可被测试覆盖。空清单 = 所有节点都会尝试修复。
RO_ONLY_NODES=""

# =====================================================================
# 置位的值带「分类 + 时间」（v.99）
# =====================================================================
# 【为什么不再只写 1】置位原来一律是 `=1`，于是三个问题：
#   ① 看日志只知「置过了」，不知「什么时候、因为什么置的」；
#   ② 退出恢复时打印 done=29 dirty=12，全是数字，看不出是哪几个、分别什么时候置的；
#   ③ 光有 1 分不清「verify 本来就过」和「build 改回来的」——排障时这两者含义差很远。
# 现在置位的值是一个带分类前缀的时间戳：
#   V:<ts>  verified  进场 verify 直接通过，没有任何写入
#   B:<ts>  built     build 真的改了一处（时间戳 = 改动时刻）
#   R:<ts>  ro        RO_ONLY_NODES 里、脚本不代改，只登记待办
# 用法上等价于布尔：非空即真，空串（归零）即假。
# 时间戳与 stamp 文件同格式 `%F %T`，正则同构，grep 一遍就能按天/按时段筛日志。
# 取本地时区（不是 UTC）：这玩意儿是给人看日志用的，「几点置的」当然是按墙上时钟。
# 【必须用双引号】单引号同样被吞：本脚本前面已有函数定义，dash 会把
# `X='%F %T'` 解析成「赋值 X=空 + 命令 '%F %T'」，实跑报 `%T: not found`，
# 变量最终是空串——一个不会报错、只会让时间戳变成空白的隐蔽 bug。
# 不加引号也一样错，所以这里用双引号（无变量展开，等价于字面量）。
_FLAG_TS_FMT="%F %T"
_bs_flag_set() {   # _bs_flag_set <变量名> <分类:V|B|R>
    eval "_bs_ts=\$(date \"+\$_FLAG_TS_FMT\")"
    eval "$1='$2:'\"\$_bs_ts\""
}
_bs_flag_clear() { eval "$1=''"; }   # 空串 = 未置位（≡ 原来的 0）
# 是否已置位。用 printf | grep 而不是 case 模式：
# 时间戳里带冒号空格，case 要额外转义，容易写错；这里只判「非空」。
_bs_flag_on() {
    printf '%s' "$(eval "printf '%s' \"\${$1:-}\"")" | grep -q . 2>/dev/null
}
# 取分类字符：V / B / R，未置位时输出空
_bs_flag_tag() {
    _bt_v=$(eval "printf '%s' \"\${$1:-}\"")
    printf '%s' "$_bt_v" | cut -c1
}
# 按分类计数：_bs_flag_count <D|B|R> <变量名...>
#   D = 已置位（不分类别），B = built，R = ro
_bs_flag_count() {
    _bc_want=$1; shift
    _bc_n=0
    for _bc_v in "$@"; do
        _bs_flag_on "$_bc_v" || continue
        case "$_bc_want" in
            D) _bc_n=$((_bc_n+1)) ;;
            *) [ "$(_bs_flag_tag "$_bc_v")" = "$_bc_want" ] && _bc_n=$((_bc_n+1)) ;;
        esac
    done
    printf '%s' "$_bc_n"
}
# 列出已置位的名字与时间（带分类），供退出日志一行打全
_bs_flag_dump() {
    _bd_out=""
    for _bd_v in "$@"; do
        _bs_flag_on "$_bd_v" || continue
        _bd_out="$_bd_out ${_bd_v}=$(eval "printf '%s' \"\${$_bd_v}\"")"
    done
    printf '%s' "$_bd_out"
}

# 首次装机判定（v.108.33）：没有 installed 标记 = 这台机器还没完整跑通过一轮。
# 只读，不写文件、不动任何标记，也不改流程 —— 只回答一个窄问题：
# 「现在能不能等一个还不存在的东西」。重装（标记被清）也算首次装机，因为它确实要从头等。
_first_install() { ! _stamp_present; }

# 构建后复核的豁免名单（v.108.33，v.108.34 增补 capi_block）。默认全都复核：
# build 返回 0 只代表命令没报错。
#
# ① bouncer_verify：只在首次装机时豁免 —— 它等的是 bouncer 的首次心跳，
#    装机那一刻心跳必然还没有，这正是 v.108.21 把它列进 SOFT_NODES 的原因。
#    重启态不给豁免：那时 bouncer 早该在拉了，验不过就是真有问题。
#
# ② capi_block：**永远豁免**，因为它和 capi_release 是同一处配置的两个互斥状态：
#      capi_block   → 容器启动前把 config.yaml 的 online_client 注释掉（要求 off）
#      capi_release → bouncer 验证通过后把它放回来（要求 on）
#    收尾复核发生在 DAG 全部跑完之后，那一刻按设计就是「已放出」，拿 off 去判
#    必然不符。首台真机实测（v.108.34）：capi_block 是唯一不符节点 → exit 1 →
#    置位全部归零 → installed 不写 → 探针【补印】分支每 5 分钟重跑一次全量引导
#    → 每轮重建一次 lxcbr0 → veth 被反复甩掉。这就是「重跑副作用」的真身。
#    capi_block 的时序义务由 DEP_ct_boot 的硬前置保证（不 off 就不许启容器），
#    「真的没写成」由 build_capi_block 内部的立即复核当场抓，收尾不必再判一次。
_post_verify_skip() {
    case " $1 " in
        *" bouncer_verify "*)
            _first_install && return 0
            ;;
        *" capi_block "*)
            return 0
            ;;
    esac
    return 1
}

# 复核不是「验一次就判死」：uci 改完到生效有延迟（dropbear reload、网桥地址），
# 验一次不中不代表没写成。3 次、每次间隔 1 秒，仍不中才算没写成。
_post_verify_confirm() {
    _pv_n=0
    while [ "$_pv_n" -lt 3 ]; do
        "verify_$1" 2>/dev/null && return 0
        _pv_n=$((_pv_n + 1))
        [ "$_pv_n" -ge 3 ] && return 1
        sleep 1
    done
    return 1
}

# 收尾复核（v.108.33）：本轮 build 过的节点，在 flush 之后必须真的生效。
# 为什么放在收尾而不是 build 旁边：build 只写 uci 内存，commit/reload 在 flush_uci，
# 落地之前的 verify 结论不可信（查内核地址、端口监听的必然不符）。
# 为什么还要再 flush 一次：阶段 3（LOG_CONF/LAPI/ENROLL）的改动不一定走过 flush，
# 首轮不符可能只是没落地。先落地再验，仍不符才算「写了没生效」。
_post_verify_after_boot() {
    _pva_bad=""
    for _pva_n in $_built_nodes; do
        if _post_verify_skip "$_pva_n"; then
            # v.108.41：两种情况豁免理由不同，日志不能共用一句话（原来 capi_block
            # 会打成「等首次心跳」，看日志的人会去查一个根本不存在的 bouncer 心跳）。
            case " $_pva_n " in
                *" capi_block "*)
                    log "[复核][$_pva_n] 与 capi_release 互斥，收尾不再判（终态由 capi_release 决定）"
                    ;;
                *)
                    log "[复核][$_pva_n] 首次装机：跳过（等首次心跳的柔性节点）"
                    ;;
            esac
            continue
        fi
        _post_verify_confirm "$_pva_n" || _pva_bad="$_pva_bad $_pva_n"
    done
    if [ -z "$_pva_bad" ]; then
        log "[复核] 本轮构建的节点全部生效（$(_count_words "$_built_nodes") 个）"
        return 0
    fi
    log "[复核] 首轮不符：$_pva_bad，落地后再验一次"
    flush_uci >/dev/null 2>&1 || log "[复核] 复验前的 flush 有失败项，见上方 [flush] 行"
    _pva_bad2=""
    for _pva_n in $_pva_bad; do
        if _post_verify_confirm "$_pva_n"; then
            log "[复核][$_pva_n] 落地后生效"
        else
            _pva_bad2="$_pva_bad2 $_pva_n"
        fi
    done
    if [ -z "$_pva_bad2" ]; then
        log "[复核] 复验后全部生效"
        return 0
    fi
    for _pva_n in $_pva_bad2; do
        case " $SOFT_NODES " in
        *" $_pva_n "*)
            log "[复核][$_pva_n] 属柔性节点，记账后继续；长期监视交给探针"
            _failed="$_failed $_pva_n"
            continue
            ;;
        esac
        log "[复核][$_pva_n] 构建后始终不符（写了没生效）"
        _failed="$_failed $_pva_n"
        return 1
    done
    return 0
}

# 数词（只用来打日志）
_count_words() {
    set -- $1
    echo $#
}

ensure() {
    _o=$1
    _O=$(echo "$_o" | tr 'A-Z' 'a-z')
    # 【v.108.24】不再用 _done_ 短路。
    # 原来第一行是 `_bs_flag_on "_done_$_o" && return 0`：只要上一轮（或本轮早些时候）
    # 留下过完成标记，就直接认定没问题，连现场都不看。于是「上次跑过、这次配置被改回去了」
    # 这类情况永远发现不了 —— 标记说做了，现场说没做。
    # 现在不论第几次跑，一律先 verify 现场：达标就过（并补记 _done_），不达标就 build。
    # _done_ 退化为「本轮已就绪」的记账，只供退出汇总和组置位使用，不再决定是否验证。
    # 每条语句都必须是「配置一致性」判断，不能退化成「接口/文件在不在」：
    # 网桥要比 ports 集合、lan 要比 ipaddr/netmask/gateway/dns、删掉的项要确认真的没了。
    for _d in $(eval "echo \$DEP_$_o"); do
        case " $_failed " in
            *" $_d "*)
                log "[$_O] 依赖 $_d 未就绪，跳过本级"
                _failed="$_failed $_o"
                return 1
                ;;
        esac
    done
    if "verify_$_o" 2>/dev/null; then
        log "[$_O] 验证通过，跳过"
        _bs_flag_set "_done_$_o" V
        return 0
    fi
    case " $RO_ONLY_NODES " in
        *" $_o "*)
            log "[$_O] 验证未通过（该节点被列入 RO_ONLY_NODES，脚本不做写入）"
            log "[待办] $_o 需在 LuCI 侧补正，脚本不做任何写入"
            case " $_ro_missing " in *" $_o "*) : ;; *) _ro_missing="${_ro_missing:-} $_o" ;; esac
            _bs_flag_set "_done_$_o" R
            return 0
            ;;
    esac
    _build_ok=1
    if ! "build_$_o" 2>/dev/null; then
        log "[$_O] 构建执行失败"
        _build_ok=0
    fi
    # 【v.108.33】这里**不做**复核，是有原因的：build_* 大多只写 uci 内存态，
    # commit/reload 统一在 flush_uci 里。此刻就去 verify 内核地址、端口监听的节点，
    # 必然全部不符 —— 那会把正常机器判死。复核点放在 flush 之后（_post_verify_after_boot）。
    if [ "$_build_ok" = "0" ]; then
        # 【v.108.21】柔性节点：不中止引导。判据是「前置环节已硬性把关，这里只差时机」，
        # 不是「修不好也没关系」。bouncer_verify 就是这类：8080 已由 LAPI 组验证，
        # 它只等 bouncer 首次心跳；等不到不该让整轮引导死掉、连 installed 都不写。
        case " $SOFT_NODES " in
        *" $_o "*)
            log "[$_O] 属柔性节点（SOFT_NODES=$SOFT_NODES）：不中止引导，记账后继续；长期监视交给探针"
            _failed="$_failed $_o"
            return 1
            ;;
        esac
        # 【v.108.17 口径：不看日志，直接重置】
        # build 修不好时先分辨两种性质，别一律 hard：
        #   · 资产残缺（rootfs 缺 /etc、缺 crowdsec.service、无 init、容器目录不可写）
        #     —— 重装有意义，交给 full_reinstall。它自己还有四道门：installed 标记、
        #     连续失败计数（REINSTALL_MAX=2）、防递归、镜像 gzip 完好。
        #   · 脚本能力对不上现场（配置写不进去、判据不成立）—— 维持 hard：同一套脚本
        #     重跑只会把同样的失败再走一遍，还要先抹掉现场证据。
        # 这条判断只读不写（除了 _structurally_broken 里那次 mkdir -p，本来就幂等）。
        # 【2026-11-10 用户定】只有 ①install 组三节点 ②boot 组的 ct_boot 有资格触发重装。
        # rootfs 缺文件不会因为「网桥配置写不进去」而变好；但反过来，网桥/rootfs/
        # cgroup 全部验过之后容器仍起不来，那就只剩 rootfs 内容坏了 —— 这条由
        # ct_boot 直接放行（见 _reinstall_should），重解压一遍确实能救。
        # ★ 抹的只有 $LXC_NAME 一个容器，同机别的容器不受影响。
        if _reinstall_scope "$_o"; then
            if _stamp_present && _reinstall_should "$_o"; then
                log "[$_O] 判定可重装（容器 $LXC_NAME 起不来或 rootfs 资产残缺），转入彻底重装"
                full_reinstall "$_o" || log "[$_O] 重装未接管（条件不满足，原因见上方 [重装] 行），维持 hard 终止"
            fi
        else
            # 不在重装职责范围：只提示，绝不抹盘。留给 install / boot 组下一轮去发现。
            if _stamp_present && _structurally_broken; then
                log "[$_O] 检出结构性损坏，但本节点不属于重装职责范围（install 组 / ct_boot），不抹盘"
            fi
        fi
        log "[$_O] 构建执行失败，hard 失败，引导终止"
        _failed="$_failed $_o"
        exit 1
    fi
    log "[$_O] 已构建"
    _bs_flag_set "_dirty_$_o" B
    _bs_flag_set "_done_$_o" B
    return 0
}
# 强制重建某节点（enroll 段 SNAT 修复用）。
# 【v.108.24】ensure 已经不看 _done_、每次都先验现场，清标记再跑是同一件事，
# 这里直接等同 ensure —— 保留函数名只为调用点可读。
rebuild() {
    ensure "$1"
}
# 组调度（v.79 层级）：组间绑定——GROUP_DEP 绑定的前置组任一失败，
# 本组整组跳过（如 boot 绑 net：容器网络/路由器网桥没就绪就不启动容器）；
# 组内小步骤逐个 ensure，统计完成度并打组边界日志；组失败只标记+传播，是否终止由小步骤 FMODE 定
ensure_group() {
    _g=$1
    _G=$(echo "$_g" | tr 'a-z' 'A-Z')
    for _gd in $(eval "echo \$GROUP_DEP_$_g"); do
        _GD=$(echo "$_gd" | tr 'a-z' 'A-Z')
        if ! _bs_flag_on "GSET_$_gd"; then
            log "[$_G] 前置组 $_GD 未置位（GSET_$_gd 为空），本组不执行"
            _group_failed="$_group_failed $_g"
            return 1
        fi
    done
    _gt=$(eval "echo \$GROUP_TITLE_$_g")
    _gn=0
    for _n in $_order; do
        [ "$(eval "echo \$NODE_GROUP_$_n")" = "$_g" ] && _gn=$((_gn+1))
    done
    log "---- 组 $_G（$_gt）：$_gn 个小步骤 ----"
    _gok=0
    for _n in $_order; do
        [ "$(eval "echo \$NODE_GROUP_$_n")" = "$_g" ] || continue
        ensure "$_n" && _gok=$((_gok+1))
    done
    if [ "$_gok" = "$_gn" ]; then
        _bs_flag_set "GSET_$_g" V
        log "[$_G] $_gt 完成（$_gok/$_gn），置位 GSET_$_g=$(eval "printf '%s' \"\${GSET_$_g}\"")"
    else
        log "[$_G] $_gt 未完成（$_gok/$_gn），不置位，后续依赖组将跳过"
        # _ro_missing 由 ensure() 以「空格 + 节点名」拼接，全空时是空串而不是空格，
        # 所以这里 trim 后判空；原先写 "  "|" " 两个模式永远匹配不到（SC2195）。
        if [ -n "$(printf '%s' "$_ro_missing" | tr -d ' \t')" ]; then
            log "[$_G] 以下节点验证未通过且脚本不代改（请在 LuCI 核对）：$_ro_missing"
        fi
        _group_failed="$_group_failed $_g"
    fi
    return 0
}

# 编译结果自检（v.108.50）：uci 里写了 proto=all ≠ nft 里真的没有协议限制。
# 真机踩过的坑（v.108.48 之前）：config rule 不写 option proto 时 fw4 默认按 tcpudp
# 编译，一条规则被拆成 tcp + udp 两条，ICMP/ESP/GRE 全落在规则外 ——
# uci show 一条不少、日志全绿，容器却出不去。
# 这里只报告、不参与判定：刚写完还没 reload 时看到的是旧表，拿来判死会误杀。
_nft_fw_report() {
    _nft_reported=1
    # 【2026-10-31.0256】nft 必在（fw4 依赖），写死不探测（用户 2026-10-31 定）。
    if ! run nft list chain inet fw4 forward_lxc >/dev/null 2>&1; then
        log "[FW] 未找到 nft 链 forward_lxc（zone 未绑 lxcbr0 或 firewall 未生成）"
        return 0
    fi
    _nr=$(run nft list chain inet fw4 forward_lxc 2>/dev/null | grep -c 'meta l4proto')
    _nr=${_nr:-0}
    if [ "$_nr" -gt 0 ]; then
        log "[FW] 警告：forward_lxc 里仍有 $_nr 条带 l4proto 的规则 → ICMP/ESP/GRE 会被漏掉，检查 proto=all 是否真的写进去"
    else
        log "[FW] forward_lxc 无协议限制（proto=all 已生效，ICMP 可通）"
    fi
    return 0
}

# 分组 flush（v.95：验证 + 修改语义）：按 DAG 收集的 _dirty_* 决定 commit / reload，
# 每组至多一次。commit 只把内存改动落到 /etc/config/*，reload 才让运行中的进程读到新值，
# 两者必须成对：
flush_uci() {
    _n=0; _d=0; _f=0
    _fu_bad=""
    # 判「脏」即「非空」：值现在是 B:<时间戳>，不再是 1
    for _o in br_lan_ports lan_static bridge; do
        _bs_flag_on "_dirty_$_o" && _n=1
    done
    for _o in dhcp_ignore; do
        _bs_flag_on "_dirty_$_o" && _d=1
    done
    for _o in lxc_zone fwd_rules lan_input snat docker_fw; do
        _bs_flag_on "_dirty_$_o" && _f=1
    done

    # ---- network：桥/地址/端口，reload 才让 netifd 重建接口 ----
    if [ "$_n" = 1 ]; then
        if run uci -q commit network; then
            log "[flush] network 已提交，执行 reload"
        else
            _fu_bad="$_fu_bad network-commit"
            log "[flush] network 提交失败：改动只在内存里，重启即丢"
        fi
        if run_svc /etc/init.d/network reload >/dev/null 2>&1; then
            log "[flush] network 已重载"
            # 【首台真机 2026-10-22 现场】netifd reload 会按 uci 重建 lxcbr0：
            # 网桥被拆了重加，而容器已经在跑 —— LXC 只在 lxc-start 时插 veth，
            # 没有任何东西会把端口接回去。结果就是现场那副样子：
            #     lxcbr0: <NO-CARRIER,UP> inet 10.1.0.1/24 state DOWN
            #     容器侧 eth0 有 IP、LAPI 在 :::8080 上 LISTEN
            #     宿主 ping 10.1.0.10 100% 丢包、curl 等 2.6 秒才 Failed to connect
            # 后面所有「LAPI 探测不通」的日志都是这一条的下游症状，别被它带偏。
            _reattach_ct_veth
        else
            _fu_bad="$_fu_bad network-reload"
            log "[flush] network 重载失败（配置已落盘，下次网络重载/重启仍生效）"
        fi
    fi

    # ---- dhcp：dnsmasq 需 restart 才读取新配置（reload 不够彻底）----
    if [ "$_d" = 1 ]; then
        if run uci -q commit dhcp; then
            log "[flush] dhcp 已提交，重启 dnsmasq"
        else
            _fu_bad="$_fu_bad dhcp-commit"
            log "[flush] dhcp 提交失败：改动只在内存里，重启即丢"
        fi
        if run_svc /etc/init.d/dnsmasq restart >/dev/null 2>&1; then
            log "[flush] dnsmasq 已重启"
        else
            _fu_bad="$_fu_bad dnsmasq-restart"
            log "[flush] dnsmasq 重启失败（配置已落盘，下次重启仍生效）"
        fi
    fi

    # ---- firewall：reload 会重建整张 nft 表，上一组改动在此刻真正生效 ----
    if [ "$_f" = 1 ]; then
        if run uci -q commit firewall; then
            log "[flush] firewall 已提交，执行 reload"
        else
            _fu_bad="$_fu_bad firewall-commit"
            log "[flush] firewall 提交失败：改动只在内存里，重启即丢"
        fi
        if run_svc /etc/init.d/firewall reload >/dev/null 2>&1; then
            log "[flush] firewall 已重载（nft 表已重建）"
            _nft_fw_report
        else
            _fu_bad="$_fu_bad firewall-reload"
            log "[flush] firewall 重载失败（配置已落盘，下次重载/重启仍生效）"
        fi
    fi

    # 清脏标记：把 DAG 里所有网络/服务侧节点全扫一遍，比手写清单更抗漏。
    # （原先手写清单漏过 bridge / svc_bind，残留脏标记会让下一轮多 reload 一次。）
    for _o in $DAG_NODES; do
        # 【v.108.33】清之前先记一笔：这一轮到底 build 过谁。收尾复核按这份名单走，
        # 不能按 _done_ 走（_done_ 里还有本轮本来就没问题的节点，复核它们纯属浪费）。
        if _bs_flag_on "_dirty_$_o"; then
            # 【v.108.52】去重：flush_uci 一轮里会被调用不止一次（收尾复核前还要再 flush），
            # 真机日志出现过 `[复核] 首轮不符： ct_net ct_net`，重复项让「不符 N 个」虚高，
            # 也让同一个节点被复验两次、白等一轮。
            case " $_built_nodes " in
                *" $_o "*) ;;
                *) _built_nodes="$_built_nodes $_o" ;;
            esac
        fi
        _bs_flag_clear "_dirty_$_o"   # v.99：置位值是 B:<ts>，归零 = 清空（写 0 会被判成脏）
    done
    [ "$_n$_d$_f$_s" = "0000" ] && log "[flush] 无配置改动，零 commit、零 reload"
    # 提交/重载失败必须能被上层看见：--net-only 据此 exit 1，不再「日志写了失败、
    # 退出码却是 0」。commit 失败尤其严重——改动只在内存里，重启就没了。
    if [ -n "$_fu_bad" ]; then
        log "[flush] 以下动作失败：$_fu_bad"
        return 1
    fi
    return 0
}

# ---- install 类节点 verify/build ----
# 镜像完整性（v.79：不只验文件名——半截 tarball 会漏判为「已就绪」，解压才炸）
_bs_clear_flags() {
    for _cf_n in $DAG_NODES; do
        _bs_flag_clear "_done_$_cf_n"
        _bs_flag_clear "_dirty_$_cf_n"
    done
    for _cf_g in $GROUP_SEQ; do
        _bs_flag_clear "GSET_$_cf_g"
    done
    _failed=""; _group_failed=""; _ro_missing=""
    return 0
}

# 【v.108.44】收尾清账：清掉「本来就不归 uci flush 管」的脏标记。
# 为什么会有残留：_dirty_<节点> 由 ensure() 统一置位（语义是「这个节点动过东西」，
#   不等于「这个节点动过 uci」）；而 flush_uci 每次把 DAG 里**所有** dirty 清空，
#   所以只要某节点是在最后一次 flush 之后才置位的，它就会一直留到进程退出。
#   首台真机实测 #37：done=26 dirty=1 gset=8 built=13，逐项是 _dirty_capi_release=B。
#   capi_release 改的是容器内 online_api_credentials.yaml / config.yaml（非 uci），
#   永远不会被 flush_uci 的 commit/reload 认领，于是那条标记永远清不掉。
# 为什么必须清：留着它只有一个后果 —— 每次退出都打一行 dirty=1。而这个数字的用途
#   正是「有没有改动没落盘」。常年是 1，真出现落盘失败时也没人会注意到那个 1。
#   也就是说这条残留不是「多打一行日志」，是让一个安全信号失效。
# 只清、不提交：该提交的在 flush_uci 里早提交过了，这里清的是「本来就不归它管」的那几笔。
_settle_dirty() {
    _sd_list=""
    for _sd_n in $DAG_NODES; do
        _bs_flag_on "_dirty_$_sd_n" && _sd_list="$_sd_list $_sd_n"
    done
    for _sd_n in $DAG_NODES; do _bs_flag_clear "_dirty_$_sd_n"; done
    [ -n "$_sd_list" ] && log "[收尾] 脏标记清账：$_sd_list（非 uci 改动，不归 flush 管，清掉以免 dirty 计数失真）"
    return 0
}

# 统计当前还残留多少置位（用于退出日志：正常应为 0）
# 除了总数，还给出「多少是 build 改的、多少是 verify 本来就过的」——
_bs_flag_stats() {
    # 名字列表先用变量攒好再展开：$(for ...) 直接写在调用处，加引号会变成单个参数，
    # 不加引号 shellcheck 报 SC2046（虽然这里正是想要分词）。
    # 拆成「先赋值、再不加引号展开」两头都干净，也不用灌 disable 指令。
    _fs_dl=""; _fs_bl=""; _fs_gl=""
    for _x in $DAG_NODES; do _fs_dl="$_fs_dl _done_$_x"; _fs_bl="$_fs_bl _dirty_$_x"; done
    for _x in $GROUP_SEQ; do _fs_gl="$_fs_gl GSET_$_x"; done
    _fs_done=$( _bs_flag_count D $_fs_dl )
    _fs_dirty=$( _bs_flag_count D $_fs_bl )
    _fs_gset=$( _bs_flag_count D $_fs_gl )
    _fs_built=$( _bs_flag_count B $_fs_dl )
    printf 'done=%s dirty=%s gset=%s built=%s\n' "$_fs_done" "$_fs_dirty" "$_fs_gset" "$_fs_built"
}

# ② ip_forward 恢复。启动时快照原值，退出时按「是否成功引导」决定要不要写回。
IPFWD_SENTINEL="$STATE_DIR/ip_forward.by-bootstrap"

verify_INSTALL() {
    for _n in $INSTALL_NODES; do
        "verify_$_n" 2>/dev/null || return 1
    done
    return 0
}
build_INSTALL() {
    for _n in $INSTALL_NODES; do
        ensure "$_n" || return 1
    done
    return 0
}

# CAPIBLOCK：容器启动前把 online_client 停用（config.yaml 只在 crowdsec 启动时读一次，
# 启动后再改等于没改——所以必须先屏蔽、后开机）
verify_CAPIBLOCK() {
    for _n in $CAPIBLOCK_NODES; do
        "verify_$_n" 2>/dev/null || return 1
    done
    return 0
}
build_CAPIBLOCK() {
    for _n in $CAPIBLOCK_NODES; do
        ensure "$_n" || return 1
    done
    return 0
}

# BOOT：唯一一次开机
verify_BOOT() {
    for _n in $BOOT_NODES; do
        "verify_$_n" 2>/dev/null || return 1
    done
    return 0
}
build_BOOT() {
    for _n in $BOOT_NODES; do
        ensure "$_n" || return 1
    done
    return 0
}

# LOGCONF：宿主机推送 + 容器内采集解析（开机后才有容器可写入，故在 BOOT 之后）
verify_LOGCONF() {
    for _n in $LOGCONF_NODES; do
        "verify_$_n" 2>/dev/null || return 1
    done
    return 0
}
build_LOGCONF() {
    for _n in $LOGCONF_NODES; do
        ensure "$_n" || return 1
    done
    return 0
}

# LAPI：容器内 cscli 取 LAPI 地址/凭据 → 写入路由器 bouncer
verify_LAPI() {
    for _n in $LAPI_NODES; do
        "verify_$_n" 2>/dev/null || return 1
    done
    return 0
}
build_LAPI() {
    for _n in $LAPI_NODES; do
        ensure "$_n" || return 1
    done
    return 0
}

# BOUNCERVERIFY：bouncer 列表真生效 → 才放开 CAPI
verify_BOUNCERVERIFY() {
    for _n in $BOUNCERVERIFY_NODES; do
        "verify_$_n" 2>/dev/null || return 1
    done
    return 0
}
build_BOUNCERVERIFY() {
    for _n in $BOUNCERVERIFY_NODES; do
        ensure "$_n" || return 1
    done
    return 0
}

# ENROLL 节点（v.108.49）：console 注册。无注册码视为就绪，不阻断引导。
# 【为什么改写成节点级函数】v.79 把调度器换成「组 → 遍历 _order 按 NODE_GROUP_ 筛节点」
# 之后，组级函数（verify_PREP / verify_ENROLL 这一套）就再没被任何路径调用过；
# 而 enroll 又恰好没进 DAG_NODES，于是这一组连节点都没有，两条死路叠在一起：
# 「组在、组日志照打、注册码永不消费」。现在 enroll 是真节点，走 ensure() 的
# verify → build 两段，组级函数保留为薄封装（万一别处还有引用，不至于调空）。
# 幂等性：验的是「注册码还在、console 还没 Enrolled」这一对条件，成功一次即删码，
# 下一轮 verify 直接过，不会反复注册。
verify_ENROLL() { verify_enroll; }
build_ENROLL() { build_enroll; }

# 单步：verify 内容一致 → 置位跳过；否则 build 一次（不再复核）
