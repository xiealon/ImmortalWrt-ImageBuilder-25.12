#!/bin/sh
# pkg-restore-apps.sh — 观测应用的主程序检查与装回
#
# 为什么有这支脚本（用户 2026-10-29 定，判据取向见 crowdsec-lxc-probe.sh L219-231）：
#   探针只做两件事 —— 探测 + 拉脚本，自己不动手装包。
#   honk / clashoo 这两个应用不像 smartdns 那样接管 53
#   （ssrp 已于 v.180.165 整组移除，理由见清单处的说明），
#   所以不判进程、不判端口，只判包在不在册；缺了由本脚本装回。
#   【v.180.164】判定粒度从「主程序一个包」扩到「主程序 + 依赖内核 + LuCI 界面」：
#   实测 opkg remove --force-depends clashoo 能一次删掉 44MB 内核而壳与 i18n 不动，
#   结果是库在、界面在、功能全死。只盯主程序包名覆盖不到这种半损坏态。
#   装包动作只写在这一处，探针里不出现任何 opkg/apk 调用 —— 两处实现迟早漂移。
#
# 用法：
#   pkg-restore-apps.sh --check     只判断（只读，一个字节都不写）
#                                   全部在位 0；有缺 1；判断不了 2
#                                   有缺时把包名打在一行（空格分隔），供探针写日志
#   pkg-restore-apps.sh --list      打印清单与逐项状态（排障用），始终 0
#   pkg-restore-apps.sh [--repair]  装回缺的那些，再复判一次
#                                   0 = 全部在位；1 = 仍有缺（或装不上）
#
# 【2026-11-10】adblock 整组移出本脚本，独立成 /usr/sbin/adblock/：
#   它的恢复 / 配置 / 规则文件 / 删除重建四项都由那边按步骤管，
#   本脚本只管代理内核（clashoo / daed / sing-box）与 geo 数据。
#   移除理由：adblock 是本机唯一允许「删了重装」的包，而那条链要整链删除
#   （单独 del 主包会被 luci-i18n 的反向依赖挡住），代码形态与本脚本的
#   逐包恢复不同，混在一处两套白名单会互相干扰。
#
# 判据主体是包管理器认不认。本版写死 apk（25.12 线只有 apk）：apk info -e。
# 【2026-11-02】原 daed-geoip / daed-geosite 的软链接例外随 daed 一并移除
# （25.12 线改用 honk）；honk 的规则集由 native_api 自己下载到 data_dir，
# 不依赖 /usr/share 下的软链接，包在册即视为数据齐备。
#   【v.180.192】补齐文件级判据（用户 2026-10-30 定）。原来这里写的是「不看文件清单」，
#   理由是清单随版本漂 / 文件缺失 ≠ 功能缺失 / 两判据混用会死循环。这三条在
#   「包完整在册、二进制被单独删掉」这种形态上都不成立：
#     · 清单随版本漂 —— 读的是 /rom 侧固件原始清单（apk 域：/rom/lib/apk/packages），
#       不随运行侧升级漂；
#     · 文件缺失 ≠ 功能缺失 —— 这里只筛「可执行 / init / 共享库」，缺了包一定跑不起来；
#       /usr/share 与 /etc/config 一律不看（用户改配置、删规则集不算坏）；
#     · 混用会死循环 —— 不会：包级先判「该不该有」，文件级只在「包在册」之后补一刀，
#       判定顺序单向；恢复动作仍只有一处（--tree → pkg-restore.sh 内有同源复检）。
#   真实动机：clashoo 包里装的是 /usr/bin/mihomo 与 /usr/bin/clash-meta，包名与二进制名
#   毫无关系。只判包名时这两个被删，--check 返回 0、探针 appbad 恒为 0 ——
#   功能已死，日志全绿。24.10 线 2026-10-30 真机复现（192.168.1.201）：
#   把包内二进制单独删掉后，--check 仍返回 0、探针 appbad 恒为 0。
#   覆盖范围（各包落在判据内的文件）：
#     clashoo           /usr/bin/mihomo /usr/bin/clash-meta /etc/init.d/clashoo
#     honk              /usr/bin/honk-core /etc/init.d/honk
#     sing-box          /usr/bin/sing-box /etc/init.d/sing-box
#   25.12 的清单格式相同（一行一个绝对路径），但未在 25.12 新机上逐包复测路径覆盖率。
#   LuCI 壳与 i18n（6 个包）的文件都在 /usr/share、/usr/lib/lua，判据内 0 行 → 恒放行，
#   仍只靠记账判。这是有意的：那类文件删了顶多界面缺项，不会像二进制那样静默失去功能。
#
# 【关键】「该不该有」的门槛：只恢复固件里本来就带的那个应用。
#   否则一台根本没装 honk 的机器，探针每轮都判「缺」、每轮装一次，装上了再被
#   用户卸掉，又装 —— 就不是修复是强加。判据取 /rom 侧留下的痕迹（apk 域）：
#     · /rom/lib/apk/db/installed —— 固件出厂的已安装库，P:<包名> 一行一个
#   不准拿 /rom/root/apk-cache/<包>-*.apk 当判据：那是兜底包库，收的包远多于
#   固件实际安装的，会把「有包但没装」判成「该有」（v.180.165 真机复现过）。
#   一处都没有 → 这台机器的固件没带这个应用 → 什么都不做，也不报错。
#
# 环境变量：
#   CS_PROBE_APPS  应用（包名）清单，空格分隔。默认见 _PA_LIST
#   ROMDIR         只读基座，默认 /rom
#   RESTORE_BIN    装包执行体，默认 /usr/sbin/pkg-restore.sh
#
# 退出码：0 / 1 / 2（2 用于「判断不了」：apk 不在，判不了 ≠ 包丢了）

set -u

# 【2026-11-10】脚本根：默认直接从只读基座 /rom 调用。
# 为什么：/rom 是 squashfs 只读分区，脚本本身改不了，天然免疫篡改与误删 ——
#   比「运行副本 + 事后比对恢复」更硬，也省掉每轮 73 次进程比对。
# 需要热修（改脚本立刻生效，不刷机）时，把 CS_SCRIPT_ROOT 设成空串即可退回 /usr/sbin。
SROOT="${CS_SCRIPT_ROOT-/rom}"
ROMDIR="${ROMDIR:-/rom}"
_RESTORE="${RESTORE_BIN:-$SROOT/usr/sbin/pkg-restore.sh}"

# 应用清单。写固件里真实的包名，不是对外叫法。
#
# 【v.180.164】用户 2026-10-29 定：不只保护主程序，依赖内核和 LuCI 界面一起保护。
# 起因是实测 opkg remove --force-depends clashoo 一次就把 44MB 的 mihomo 内核删干净，
# 而 luci 壳与 i18n 完好 —— 库存在、界面在、功能全死，这种形态只看主程序包名不够。
# 分组维护，每组三块：
#   ① 主程序（内核跑在这个包里，或它本身就是服务）
#   ② 依赖（内核 / geo 数据 / eBPF 运行时）—— 少一个都是「装了但起不来」
#   ③ LuCI 界面（luci-app-* / luci-i18n-*）—— 少了用户看不见入口，等同于坏了
#
#   clashoo 组：内核就在主包里（control: Provides: mihomo, clash-meta，Installed-Size 46.5MB）
#   honk 组：  eBPF 程序，vmlinux-btf 是运行时前提，缺了 honk-core 直接起不来
#   ssrp 组：已整组移除，见下方 v.180.165 说明
#
# 【v.180.165】ssrp 组整组删除（用户 2026-10-29 定）。理由两条：
#   ① honk 已经能替代它，没有必要再维护一套 ssr-plus；
#   ② ssr-plus 的依赖链太长 —— xray-core / xray-plugin / v2ray-plugin /
#      三套 shadowsocksr-libev / trojan-plus / tuic / shadow-tls / naiveproxy /
#      simple-obfs-client，每轮 _pa_missing 都要逐包问一次包管理器，
#      探针负担和它带来的价值完全不成正比。
# 两条构建线都不再装它：
#   · 24.10：shell/custom-packages.sh 里那一行已删；
#   · 25.12：本来就没装，但包库里有对应 apk（build25.sh 收的兜底包）。
# 所以即使包库还留着这些 apk，也不会再被判成「该有」—— 判据见 _pa_should。
#
# 门槛仍在 _pa_should：只有 /rom 侧留了痕迹（info/<包>.list 或包库里那份 ipk）
# 才判「该有」。所以这张表可以照全量写，固件没带的包会显示「固件未带」而不是
# 每轮触发一次装包 —— 不会把没选的应用强加给别的机器。
# 【v.180.171】清单按「真的装得回来」重划（用户 2026-10-29 定：
# 把需要保护的依赖查清楚，然后保护起来）。
# 2026-10-29 真机逐包实测了两件事：固件出厂的已安装库里有没有它
# （grep -qxF P:<包> /rom/lib/apk/db/installed），包库 /rom/root/apk-cache
# 里有没有对应的 apk。两个都 yes 才留在这张表里 —— 只有前者没有后者的包，
# 判出缺失也装不回来，每轮只是白报一次警。
#
# 留下的 14 个包全部 firmware=yes + pkg=yes：
#   clashoo / luci-app-clashoo / luci-i18n-clashoo-zh-cn
#   daed / luci-app-daede / vmlinux-btf
#   sing-box
#   v2ray-geoip / v2ray-geosite（2026-11-02 补入，只判包不判文件，见 _PA_GEO）
#   （adblock / luci-app-adblock / luci-i18n-adblock-zh-cn 三包 2026-11-10 移出本脚本，
#     归 /usr/sbin/adblock/ 独立管理；包库里它们的 apk 照旧收在 build25.sh 的 _AK_WANT，
#     移除只是换了管它的脚本，不是取消保护）
#
# vmlinux-btf 为什么也进 daed 组（2026-11-10）：
#   daed 的 Makefile 写着 +DAED_USE_VMLINUX_BTF:vmlinux-btf，包内 Depends
#   有它。删掉之后 daed 的依赖链就断，apk 任何一次操作都可能顺手把 daed 带走。
#   它同时是哨兵：装的是与内核同版的 BTF（6.12.103），启动校验读的就是它；
#   版本对不上时 daed 起不来，所以它在册 = 「BTF 与内核配套」这件事成立。
#   恢复走 _pr_tree 从 /rom 拷文件，不需要 apk 源，所以保护是真的生效。
#
# 内核模块全部移出本表，改由 pkg-restore.sh --deps 做文件级恢复。
# 原因是决定性的（2026-10-29 实测）：kmod-* 在固件出厂库里（P:kmod-tun 命中），
# 但包库 116 个 apk 里**一个 kmod 都没有**，apk add kmod-tun 无处可装 ——
# 留在这里只能报「缺」不能修。更要紧的是「包在册、模块文件被 whiteout」这种
# 形态，apk info -e 照样返回成功，包级判据根本看不见。
# 所以交给 --deps：清单不写死，直接读 /rom/lib/apk/packages/<包>.list，
# 从 /rom 逐文件拷回。9 个 kmod 包的 26 个 .ko 与 9 个 modules.d 配置、
# 以及 v2ray-geoip / v2ray-geosite 的 3 条路径都在里面（共 18 包 / 73 条，
# 2026-11-02 真机 --deps --list 实测；其中 /usr/share/xray/geosite.dat 是
# 指向 ../v2ray/geosite.dat 的软链接，补回时按链接重建，不做 cp 实体化）。
# geo 两个包同时也在本文件的 _PA_GEO 里（包级）—— 两条通道分工不同，见 _PA_GEO 说明。
# 范围只有应用要用的这些：不含内核本体（坏了重刷固件），也不含 /etc/config/
# （UCI 配置归 bootstrap 管，见 pkg-restore.sh v.180.181 说明）。
#
# 移出清单的无效条目及原因：
#   vmlinux-btf        固件出厂库无此包（25.12 内核自带 /sys/kernel/btf/vmlinux）
#   kmod-dummy / kmod-nft-socket / kmod-nft-tproxy / kmod-sched-bpf /
#   kmod-sched-core / kmod-veth / kmod-inet-diag / kmod-tun / kmod-netlink-diag
#                      固件库有、包库无 → 装不回，见上，改走 --deps
#   microsocks         固件库无、包库也无（ssrp 时代遗留，从未装过）
#   dns2socks / ipt2socks / chinadns-ng / tcping
#                      固件库无、包库有 → _pa_should 判「固件未带」，永远跳过
#   libopenssl3        固件库有、包库无 → 装不回；且它是全系统的 TLS 底座，
#                      不属于某一个应用的依赖
_PA_CLASHOO="clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn"
# 【2026-11-10】官方线改用 daed（用户定），保护组整体换过来，三件：
#   daed          主程序，/usr/bin/daed + /etc/init.d/daed，内嵌 Web UI
#   luci-app-daede LuCI 界面（kenzok8 的 1.15-r13，自带中文，没有单独 i18n 包）
#   vmlinux-btf   BTF 包，与内核同版（6.12.103），daed 的 Depends 里有它
# 三件都在包库 /rom/root/apk-cache 里 —— build25.sh 的 daed 段下载、
# 构建期断言 _ak_need_daed 也会在打包前核实一遍，所以探针判出缺失时
# 能从本地装回，不需要联网。
_PA_DAED="daed luci-app-daede vmlinux-btf"
# 【2026-11-02】geo 数据单独成组：包级判据（apk info -e），不判文件。
#
# 这一组负责的只是「包被人 apk del 掉」——装回时连文件带记账一起回来。
# 「包还在、.dat 被删」是另一种故障，归 pkg-restore.sh 的 --deps 文件级通道，
# 由探针 _kmods_watch 连续 N 轮缺失后自动从 /rom 拷回。两条合起来才叫
# 「删了还能自己长回来」，用户 2026-11-02 明确要求要有这一层保障。
#
# 为什么不在这里判文件：_pa_files_ok 的 case 只认 /usr/bin /usr/sbin
# /etc/init.d /lib/*.so*，而 geo 两包的文件全在 /usr/share/v2ray（实测
# v2ray-geoip.list 只有 1 行 /usr/share/v2ray/geoip.dat）。所以这一组
# 天然只判「包在册」，不会因为 .dat 新旧去动任何字节 —— 用户
# `apk add --upgrade v2ray-geoip` 换新数据后，这里永远判在位。
_PA_GEO="v2ray-geoip v2ray-geosite"
# sing-box 是通用代理内核，原挂在 ssrp 组里，现在单独一组。
# 它的 kmod 依赖（inet-diag / netlink-diag / tun）同样归 --deps 管。
_PA_COMMON="sing-box"
# 【2026-11-10】只判包级、不判文件的组（用户定）。
# clashoo / daed / honk 是三个互斥的代理内核（同时只能开一个），它们的状态
# 由用户导入订阅后生成在 /etc/clashoo、/etc/honk 等目录，**不在任何包的
# 文件清单里**。用文件级判据去判它们，只会把「用户还没配置」误报成「包坏了」，
# 进而触发重装 —— 而重装既补不回配置（配置不是包内容），又白折腾一次服务。
#
# 2026-11-10 真机证据：clashoo 装好但 /etc/clashoo/config.yaml 不存在，
# runtime_state 写的是 health_detail=preflight:config_missing，
# apk del + apk add 之后 config.yaml 依然不存在 —— 这证明配置与包正交。
#
# 结论：这三个组只走 _pa_installed（apk info -e），文件级一律放行。
# 二进制真被删了，重装包自然连文件一起回来；配置文件不被任何自动动作碰。
_PA_HONK="honk luci-app-honk luci-i18n-honk-zh-cn"
_PA_PKGONLY="$_PA_CLASHOO $_PA_DAED $_PA_HONK"

# 【2026-11-02】daed 在 25.12 线已被 honk 取代（用户定），原来的 geo 软链接判据一并删除：
#   honk 的规则集不走 /usr/share/daed/*.dat 软链接，而是按 native_api.geosite_download_url /
#   geoip_download_url 自己下到 data_dir（默认 /etc/honk/data），包在册即认定数据齐备。
#   honk 是官方 daeuniverse 源的包，预装进固件后 /rom/lib/apk/db/installed 有 P:honk，
#   _pa_should 照常命中；被 force-remove 时同样能判出来。

# 【2026-11-10】_PA_HONK 并入清单：_PA_PKGONLY 原本写了 honk 三包却不进 _PA_LIST，
# 等于「判据写了、范围没进去」，只有 honk 变体才该有这三个包，靠 _pa_should 按
# /rom/lib/apk/db/installed 的 P: 行过滤 —— 纯净 25.12 / daed 线上自动跳过，不误报。
_PA_LIST="${CS_PROBE_APPS:-$_PA_CLASHOO $_PA_GEO $_PA_DAED $_PA_COMMON $_PA_HONK}"

log() { printf '[APP] %s\n' "$*"; }

# 【2026-10-31.0256】_pa_pm 删除：apk 是 25.12 的系统包管理器，必然在位（用户 2026-10-31 定）。
# 原来那层 command -v 探测只会产出一个永不触发的 exit 2。

# 24.10 线才需要 _PA_CACHE（opkg list-installed 是全表扫描，缓存后只跑一次）；
# 25.12 的 apk info -e 直接问包数据库，不需要缓存，本文件不保留这个变量。
_pa_installed() {
    apk info -e "$1" >/dev/null 2>&1
}

# 【2026-11-10】从本地仓库直装单个包，不主动补依赖树。
# 为什么不用 pkg-restore.sh --tree：那条会顺手把整棵依赖装回来，属于 --deps
# 的职责；apps 这层只回答「这个包该在而它不在」。依赖真缺时 apk 会拒装并说明
# 缺哪个，等 --deps 补齐后这里自然就过去了。
#
# 【必须注意】rc 只能这样取。2026-11-10 实测踩过坑：
#     apk add ... 2>&1 | tail -12
#     echo "RC=$?"        ← 拿到的是 tail 的 0，apk 明明失败却当成功
# 差点在设备上把 smartdns 删掉后装不回来。
_pa_add_local() {
    _pal_log=/tmp/.pa_add.$$.log
    apk add --no-network --allow-untrusted --force-overwrite "$1" >"$_pal_log" 2>&1
    _pal_rc=$?
    [ "$_pal_rc" -eq 0 ] && { rm -f "$_pal_log"; return 0; }
    # 本地索引还没加载时 apk 会报 no such package，刷一次（纯本地，0 秒）再试
    apk update >/dev/null 2>&1
    apk add --no-network --allow-untrusted --force-overwrite "$1" >"$_pal_log" 2>&1
    _pal_rc=$?
    rm -f "$_pal_log"
    return "$_pal_rc"
}

# 固件里本来就有这个应用吗 —— 见文件头「该不该有」的门槛。
# 本版只看 apk 的出厂已装库；opkg 的 .list 判据随版本拆分一并删除。
_pa_should() {
    # /rom/lib/apk/db/installed 是出厂已装库（P:<包名> 一行一个），记录的是
    # 「固件带了什么」，与之后 user 装了什么都不相干，正好是判据。
    # 【v.180.165】不准退回「包库里有没有 <包>-*.apk」：那是兜底包库，25.12 线
    # 114 个 apk 远多于固件实际安装的 622 个包，包库里每一个「有包但没装」的包
    # 都会被判成「该有」。2026-10-29 真机复现：ssrp 组 5 个包被判缺失，第 3 轮
    # --repair 把 xray-core / xray-plugin 装了上去（运行时 624 vs 出厂 622）——
    # 这不是修复，是把用户没选的应用强加给机器。
    grep -qxF "P:$1" "$ROMDIR/lib/apk/db/installed" 2>/dev/null
}

# 已装包的「运行数据还在吗」补充判据（v.180.167）。
# 原来只对 daed 的两个 geo 包生效（软链接断链要算缺失）。
# 【2026-11-02】daed 在 25.12 线被 honk 取代，本线已无「包在、数据另存」的包，
# case 里不再有任何具体分支；函数保留是为了调用点不用改，也方便日后加新判据。
_pa_data_ok() {
    case "$1" in
    *)            return 0 ;;
    esac
}

# 【v.180.192】包在册、关键文件被删 —— 判运行侧文件，不判 /rom：
# 要问的是「现在能不能跑」，/rom 里的副本永远在，拿它当判据恒真。
# 清单取 /rom 侧固件原始那份（apk 域 /rom/lib/apk/packages/<包>.list，一行一路径）：
# 运行侧的 apk 记录是二进制的 installed.adb，取不出一行一路径的清单，正好只用 /rom 那份。
# 清单本身不在 → 放行（判不了，别乱报）。
# 与 pkg-restore.sh 的 _pr_files_ok 同源。两脚本各自独立部署（探针直接 exec 本脚本），
# 没有共享库；重复的只是 6 行 case，比引入一层 source 稳。
#
# case 只认程序文件（/usr/bin /usr/sbin /etc/init.d /lib/*.so*），
# **不含 /usr/share** —— 这正是 _PA_GEO 想要的：geo 数据在 /usr/share/v2ray/*.dat，
# 包里任何一个程序文件在册就判在位，数据新旧、在不在都不影响判断。
_pa_files_ok() {
    # 【2026-11-10】代理内核只判包级，见 _PA_PKGONLY 说明。
    case " $_PA_PKGONLY " in
    *" $1 "*) return 0 ;;
    esac
    _paf_l="$ROMDIR/lib/apk/packages/$1.list"
    [ -f "$_paf_l" ] || return 0
    while IFS= read -r _paf_f; do
        case "$_paf_f" in
        /usr/bin/*|/usr/sbin/*|/etc/init.d/*|/lib/*.so*|/usr/lib/*.so*) ;;
        *) continue ;;
        esac
        [ -e "$_paf_f" ] || return 1
    done < "$_paf_l"
    return 0
}

# 输出「该有却没有」的包名（一行，空格分隔）。没有则输出空行。
# 「没有」含三种形态：包不在册；包在册但运行数据断了（见 _pa_data_ok）；
# 包在册但关键文件被删（见 _pa_files_ok，v.180.192）。
_pa_missing() {
    _pa_m=""
    for _pa_p in $_PA_LIST; do
        _pa_should "$_pa_p" || continue
        if _pa_installed "$_pa_p" && _pa_data_ok "$_pa_p" && _pa_files_ok "$_pa_p"; then continue; fi
        _pa_m="$_pa_m $_pa_p"
    done
    printf '%s\n' "$_pa_m" | sed 's/^ *//'
}

_pa_check() {
    _pa_cm=$(_pa_missing)
    [ -n "$_pa_cm" ] && printf '%s\n' "$_pa_cm"
    [ -z "$_pa_cm" ]
}

_pa_list() {
    for _pa_p in $_PA_LIST; do
        _pa_s="固件未带"
        if _pa_should "$_pa_p"; then
            if ! _pa_installed "$_pa_p"; then
                _pa_s="缺失"
            elif ! _pa_files_ok "$_pa_p"; then
                _pa_s="文件缺失"   # 包在册但二进制/init 被删（v.180.192）
            elif _pa_data_ok "$_pa_p"; then
                _pa_s="在位"
            else
                _pa_s="数据断链"   # 包在册但软链接目标读不到（v.180.167）
            fi
        fi
        printf '%-34s %s\n' "$_pa_p" "$_pa_s"
    done
    return 0
}

_pa_repair() {
    _pa_n=0
    for _pa_p in $(_pa_missing); do
        _pa_n=$((_pa_n + 1))
        log "装回 $_pa_p"
        # 【2026-11-09】按形态分两条路。原来一律走 --tree，看似通用，实际对
        # 「包在册、只有文件缺失」这种形态是空转：
        #   --tree -> pkg-restore.sh 的 _pr_pkg -> 先判 _pr_installed（包在册=真）
        #   -> 再判 _pr_files_ok，而它的 case 只认 /usr/bin /usr/sbin /etc/init.d
        #   /lib/*.so* /usr/lib/*.so*，判据看不见的路径一律当「文件齐」
        #   -> 打「已安装，跳过」-> 返回 0，一个字节没写。
        # 所以：
        #   ① 包不在册 -> --tree，连依赖一起装；
        #   ② 包在册、判据没过 -> --force，直连 PCR_FORCE=1 -> apk fix，
        #      按包内容重装，文件与软链接都会重建。
        if _pa_installed "$_pa_p"; then
            if "$_RESTORE" --force "$_pa_p"; then
                log "装回完成 $_pa_p（强制重装：包在册，文件缺失）"
            else
                log "装回失败 $_pa_p（强制重装没成功，本地包库可能没有它）"
            fi
        elif _pa_add_local "$_pa_p"; then
            log "装回完成 $_pa_p"
        else
            log "装回失败 $_pa_p（本地包库没有它，或依赖缺失待 --deps 补齐）"
        fi
    done
    [ "$_pa_n" -gt 0 ] || log "无需装回（没有「该有却缺失」的应用）"
    # 装完必须重判。apk 没有缓存，直接重算即可。
    [ -z "$(_pa_missing)" ]
}

case "${1:---repair}" in
--check)
    _pa_check && exit 0 || exit 1
    ;;
--list)
    _pa_list
    exit 0
    ;;
--repair)
    _pa_repair && exit 0 || exit 1
    ;;
-*)
    echo "用法：$0 --check | --list | --repair" >&2
    exit 2
    ;;
*)
    echo "用法：$0 --check | --list | --repair" >&2
    exit 2
    ;;
esac
