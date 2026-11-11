#!/bin/bash
# 【2026.11.10】固件版本标记 —— 与 bootstrap/_lib.sh 的 SCRIPT_VER 同步，每次改脚本一起改
source shell/apk-custom-packages.sh
echo "第三方apk软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"

# 【v.180.194】分区大小写进 .config，不只靠命令行。
# imm25.config 里 CONFIG_TARGET_ROOTFS_PARTSIZE=2048，而下拉框默认是 4G：
# 只传 `make image ROOTFS_PARTSIZE=` 时，凡是走 .config 的路径（rootfs 上限、
# gen_image_generic 的偏移计算）仍旧拿到 2048，结果就是「选了 6G、出来还是 2G」。
# build24.sh 早就这么做了，这边一直缺一段 —— 现在补齐，两边行为一致。
# .config 是单文件 bind mount，sed -i 靠 rename 会撞 "Device or resource busy"，
# 所以先写临时文件再原地截断写回。
if [ -f .config ]; then
    case "$PROFILE" in
        ''|*[!0-9]*)
            echo "::warning::PROFILE=$PROFILE 不是数字，分区沿用 .config 里的值"
            ;;
        *)
            if sed "s|^CONFIG_TARGET_ROOTFS_PARTSIZE=.*|CONFIG_TARGET_ROOTFS_PARTSIZE=$PROFILE|" .config > /tmp/imm25.cfg 2>/dev/null; then
                cat /tmp/imm25.cfg > .config
                echo "==> rootfs 分区按 Profile 设为 ${PROFILE}MB"
            else
                echo "::warning::改写 .config 的 ROOTFS_PARTSIZE 失败，沿用原值"
            fi
            ;;
    esac
fi

# 【v.180.196】给 Image/pad-to 打补丁 —— 20G 分区构建失败的真因。
#
# 上游定义（include/image.mk）：
#     define Image/pad-to
#         dd if=$(1) of=$(1).new bs=$(2) conv=sync
#         mv $(1).new $(1)
#     endef
# 调用方把 $(2) 传成 "$(CONFIG_TARGET_ROOTFS_PARTSIZE)M"，于是 20G 档就是
# `dd bs=20480M` —— dd 会先按 bs 分配输入缓冲区，20480M = 20GiB。
# runner 只有 16GB 内存，直接 OOM：
#     dd: memory exhausted by input buffer of size 21474836480 bytes (20 GiB)
#     make[3]: *** [Makefile:160: ...squashfs-rootfs.img.gz] Error 1
#
# 这跟磁盘一点关系没有（实测日志：146G 盘、清理后 109G 可用）。
# 10G 能过是因为 bs=10240M = 10GiB，16GB 内存勉强能分配；12G 以上越来越险。
#
# 改法：bs 换成固定的 1M（缓冲区只要 1MiB），再用 truncate 把结果扩到目标大小。
# dd 负责把 squashfs 复制出来并补齐到 1M 边界，truncate 负责撑到 20G 的
# 逻辑大小 —— 中间是空洞，稀疏，不占实际磁盘。产物与原来完全一致。
#
# 只在模式真的存在时才动手，上游哪天改了就自动跳过，不留死补丁。
_IMK="include/image.mk"
if [ -f "$_IMK" ] && grep -q 'of=$(1).new bs=$(2) conv=sync' "$_IMK" 2>/dev/null; then
    # 一条 sed 完成：把整行换成「bs=1M」+ 新起一行 truncate。
    # 替换串里的 \n 换行、\t 制表符由 sed 解释 —— Makefile 的 recipe 行必须以
    # tab 开头，少了 tab 会报 "missing separator"，所以这里必须显式补 \t。
    #
    # truncate 必须存在：补丁靠它把 dd 的结果撑到分区大小。万一没有，
    # dd 只会产出 487MB 的 img，分区悄悄变成几百兆 —— 构建显示成功、
    # 固件却不对，比 OOM 更糟。所以先 command -v 拦一道。
    if ! command -v truncate >/dev/null 2>&1; then
        echo "::error::容器里没有 truncate，补丁无法保证分区大小，终止"
        exit 1
    fi
    sed -i 's|dd if=$(1) of=$(1).new bs=$(2) conv=sync|dd if=$(1) of=$(1).new bs=1M conv=sync\n\ttruncate -s $(2) $(1).new|' "$_IMK"
    if grep -q 'truncate -s $(2) $(1).new' "$_IMK" 2>/dev/null; then
        echo "==> [patch] Image/pad-to 已改：bs=1M + truncate -s \$(2)（避开 20GiB 缓冲）"
    else
        echo "::error::Image/pad-to 补丁没写进去，20G 档仍会 OOM，终止"
        exit 1
    fi
else
    echo "==> [patch] Image/pad-to 未命中（上游可能已改），跳过"
fi

# 【v.180.200】gen_image_generic.sh 里那条 dd if=/dev/zero —— 大档位爆盘的真因。
#
# combined.img.gz / combined-efi.img.gz 这两条不走 pad-to，而是走 Build/combined
# → scripts/gen_image_generic.sh，里面有这么一行：
#   [ -n "$PADDING" ] && dd if=/dev/zero of="$OUTPUT" bs=512 seek="$ROOTFSOFFSET" conv=notrunc count="$ROOTFSSIZE"
# 注意 ROOTFSSIZE 这里是**扇区数**：256G 档 = 469762048 扇区 = 224GiB，
# 而且没有 conv=sparse —— dd 会把这 224GiB 零实打实写进磁盘。
# runner 总共 146G，写到剩 109G 时 ENOSPC，表现就是「卡在 dd 那行不动」，
# 最后 No space left on device。
#
# 改法：整行换成 truncate，直接把文件长度撑到「kernel 区 + rootfs 区 + GPT 备份区」。
# truncate 只改 inode 长度、不写数据，中间全是空洞，磁盘占用仍是几百 MB；
# 而 gzip 读到的逻辑长度不变，分区大小照样是 224G。
_GIS="scripts/gen_image_generic.sh"
if [ -f "$_GIS" ] && grep -q 'dd if=/dev/zero of="\$OUTPUT" bs=512 seek="\$ROOTFSOFFSET"' "$_GIS" 2>/dev/null; then
    if ! command -v truncate >/dev/null 2>&1; then
        echo "::error::容器里没有 truncate，大分区档会写满磁盘，终止"
        exit 1
    fi
    # 不用 sed：这条正则里 [ ] & $ 全是元字符，转义错一个就静默改坏脚本。
    # 改成「按行号切三段、中间整行换掉」——纯文本匹配，行为可预期。
    _LN=$(grep -n 'dd if=/dev/zero of="\$OUTPUT" bs=512 seek="\$ROOTFSOFFSET"' "$_GIS" | head -n1 | cut -d: -f1)
    if [ -n "$_LN" ]; then
        {
            head -n $((_LN - 1)) "$_GIS"
            printf '%s\n' '[ -n "$PADDING" ] && truncate -s $(( (ROOTFSOFFSET + ROOTFSSIZE + ${sect:-0}) * 512 )) "$OUTPUT"'
            tail -n +$((_LN + 1)) "$_GIS"
        } > /tmp/gis.new
        # 用 cat 覆盖而不是 mv：这个脚本是直接被执行的，要保住原文件的权限位
        cat /tmp/gis.new > "$_GIS" && rm -f /tmp/gis.new
    fi
    if grep -q 'truncate -s \$(( (ROOTFSOFFSET + ROOTFSSIZE' "$_GIS" 2>/dev/null && \
       [ "$(grep -c 'dd if=/dev/zero of="\$OUTPUT" bs=512 seek="\$ROOTFSOFFSET"' "$_GIS")" = "0" ]; then
        echo "==> [patch] gen_image_generic.sh 已改：写零 dd 换成 truncate（大档位不再爆盘）"
    else
        echo "::error::gen_image_generic.sh 没改成功，128G/256G 档会写满磁盘后失败，终止"
        exit 1
    fi
else
    echo "==> [patch] gen_image_generic.sh 未命中（上游可能已改），跳过"
fi

mkdir -p /home/build/immortalwrt/files/etc/config

# custom/ 由 workflow 挂到 /home/build/immortalwrt/custom（v.108.9）。
# 旧写法直接把 custom 挂到 files/etc/config 上，Docker 的 bind mount 会整体遮蔽
# 该目录 —— 仓库里固化在 files/etc/config 下的文件（lxc-auto）永远进不了镜像，
# 镜像落回软件包自带的默认模板。改成挂到独立目录、由这里拷进来：注入的
# /etc/config/*.txt 照样进镜像，固化的文件也不再被吃掉。
for _cf in /home/build/immortalwrt/custom/*; do
    [ -f "$_cf" ] || continue
    # 固化配置优先：action 注入不该有本事把 lxc-auto 覆盖成别的容器名，
    # 那会让 lxc-auto 服务拉错容器（或一个都不拉），且现场毫无报错。
    case "$(basename "$_cf")" in
        lxc-auto)
            echo "::warning::custom/ 里出现了 lxc-auto，已忽略（容器配置由 files/etc/config 固化）"
            continue ;;
    esac
    cp -f "$_cf" /home/build/immortalwrt/files/etc/config/ \
        || { echo "::error::拷贝 $_cf 到 files/etc/config 失败"; exit 1; }
done

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://github.com/xiealon/apk.git /tmp/store-apk-repo

  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-apk-repo/run/x86/* /home/build/immortalwrt/extra-packages/

  echo "✅ Run files copied to extra-packages:"
  sh shell/apk-prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
fi


echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"

PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"


# Docker 包已固定写在 shell/apk-custom-packages.sh 里（v.99-bp.2：纯 X86，不再由开关控制）

if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p files/etc/openclash/core
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz"
    wget -qO- $META_URL | tar xOvz > files/etc/openclash/core/clash_meta
    chmod +x files/etc/openclash/core/clash_meta
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O files/etc/openclash/GeoIP.dat
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O files/etc/openclash/GeoSite.dat
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*apk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest apk: $URL"
    wget "$URL" -P /home/build/immortalwrt/packages/
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

# 【v.108.71】SSR Plus → Clashoo（与 build24.sh 同一个理由）。
# clashoo 的 apk 自带 mihomo（Provides: mihomo, clash-meta），不再单独下内核；
# 改成断言 xiealon/apk 的 run/x86/clashoo/ 里那三个 apk 真的进了 packages/。
if echo "$PACKAGES" | grep -q "clashoo"; then
    _cl_apk=$(ls packages/clashoo-*.apk 2>/dev/null | head -n1)
    _cl_luci=$(ls packages/luci-app-clashoo-*.apk 2>/dev/null | head -n1)
    if [ -z "$_cl_apk" ] || [ -z "$_cl_luci" ]; then
        echo "::error::PACKAGES 里选了 clashoo，但 packages/ 下缺包（clashoo=$_cl_apk luci=$_cl_luci）—— apk 仓库的 run 没解出 apk"
        ls -la packages/ 2>/dev/null || true
        echo "::error::预期来自 xiealon/apk 的 run/x86/clashoo/"
        exit 1
    fi
    echo "✅ clashoo 就位: $_cl_apk + $_cl_luci（自带 mihomo 内核，不再单独下载）"
else
    echo "⚪️ 未选择 clashoo"
fi

REPOS_CONF="/home/build/immortalwrt/repositories"
# 【2026-11-03】apk 时代这份文件叫 repositories（不带 .conf），本 IB 里就是它。
# 原来固定写 repositories.conf，而文件不存在 → 下面 [ -f ] 恒假，
# EXTRA_APK_REPOS 从上线到现在一次都没生效过。先试无后缀，再退回旧名兼容。
[ -f "$REPOS_CONF" ] || REPOS_CONF="/home/build/immortalwrt/repositories.conf"
# ---- 【2026-11-02】修正 GitHub Release 资产名：`~` 被规范化成 `.` ----
# run #18（head 7be1d3d）实测失败，三个包同时报：
#   ERROR: luci-app-honk-26.303.60580~1046d3c: package mentioned in index not found
#   ERROR: luci-lib-daeuniverse-26.303.64947~503cdb1: ...
#   ERROR: luci-i18n-daeuniverse-zh-cn-26.303.60580~1046d3c: ...
# 根因是两个名字不一致：
#   Release 资产名  luci-app-honk-26.303.60580.1046d3c.apk     （GitHub 把 ~ 换成 .）
#   包内 pkgver     26.303.60580~1046d3c                       （apk adbdump 读出）
# make image 装包时按 name-version.apk 拼文件名去仓库取，磁盘上却是 . 版本 → not found。
# 反证：honk-0.1.0_beta4-r3.apk 与 vmlinux-btf-builtin-1-r1.apk 版本里没有 ~，
# 同一次构建里装得好好的 —— 所以问题只在被改名的那些资产上。
# GitHub 只改资产名、不动包内容，下载后按包内 name/version 改回来即可。
_gh_apk=""
_gh_fixname() {
    _gf_f="$1"
    [ -s "$_gf_f" ] || { echo "::error::改名：文件不存在或为空 $_gf_f（下载没拿到内容）"; return 1; }
    if [ -z "$_gh_apk" ]; then
        for _gc in "$(pwd)/staging_dir/host/bin/apk" "$(pwd)/staging_dir/host/bin/apk.static"; do
            [ -x "$_gc" ] && _gh_apk="$_gc" && break
        done
        [ -n "$_gh_apk" ] || _gh_apk="$(command -v apk 2>/dev/null)"
    fi
    [ -n "$_gh_apk" ] || { echo "::error::改名：找不到 apk 工具，读不出包内 pkgver"; return 1; }
    _gf_nv=$("$_gh_apk" adbdump "$_gf_f" 2>/dev/null \
        | sed -n 's/^  name: //p; s/^  version: //p' | head -n2 | tr '\n' ' ')
    _gf_n=${_gf_nv%% *}
    _gf_v=${_gf_nv#* }
    _gf_v=${_gf_v% }
    if [ -z "$_gf_n" ] || [ -z "$_gf_v" ]; then
        echo "::error::改名：读不出包内 name/version（$_gf_f）"
        return 1
    fi
    _gf_want="$(dirname "$_gf_f")/${_gf_n}-${_gf_v}.apk"
    [ "$_gf_f" = "$_gf_want" ] && return 0
    if mv -f "$_gf_f" "$_gf_want" 2>/dev/null; then
        echo "    ↻ $(basename "$_gf_f") → $(basename "$_gf_want")"
        return 0
    fi
    echo "::error::改名失败：$_gf_f → $_gf_want"
    return 1
}

# daed：新版 daed 三件套，从 kenzok8/openwrt-daede 的 release 取。
#
# 【2026-11-10】用户定：官方 25.12 线去掉 honk、改用新版 daed。
# 三件（全部 x86_64，版本随 release tag 走，不写死）：
#   daed-<ver>-x86_64.apk                 主程序，内嵌 Web UI，约 24.8 MiB
#   luci-app-daede-<ver>-x86_64.apk       LuCI 界面（PKGARCH:=all），约 97 KiB
#   vmlinux-btf-6.12.<n>-r<r>-x86_64.apk  BTF 包，必须与目标内核同版
#
# 为什么用 kenzok8 这套而不是官方 feed：
#   25.12 官方源里没有 daed / luci-app-daed；旧做法靠 store 的 .run 包解 ipk，
#   那是 opkg 格式，25.12 的 apk 装不了。kenzok8 直接给 apk v3，且同时出
#   x86_64 的 vmlinux-btf，版本跟内核对齐。
#
# vmlinux-btf 为什么必须取：daed 的 Makefile 有
#   DEPENDS: ... +DAED_USE_VMLINUX_BTF:vmlinux-btf
# 缺包时 make image 直接报找不到 vmlinux-btf。25.12 内核虽自带 BTF，但包名依赖
# 是硬约束；版本对不上（如 6.12.79 配 6.12.103 内核）daed 的 eBPF 校验会失败，
# 所以下面既取最新 6.12.x，又拿 include/kernel-version.mk 校验一致才继续。
if echo "$PACKAGES" | grep -q "daed"; then
    _dd_api="https://api.github.com/repos/kenzok8/openwrt-daede/releases/latest"
    echo "==> daed: 读取 Release 资产清单"
    echo "    $_dd_api"
    _dd_json=$(wget -qO- --timeout=30 --tries=3 "$_dd_api" 2>/dev/null) || _dd_json=""
    if [ -z "$_dd_json" ]; then
        echo "::error::daed: 取不到 openwrt-daede Release 资产清单（网络不通或 Release 不存在）"
        exit 1
    fi
    _dd_n=0
    _DAED_BTF_VER=""

    # BTF 包单独取：只认 x86_64 的 6.12.x，版本号记进 _DAED_BTF_VER，
    # 供下面「来源 A 拷贝」那段白名单放行（否则会被 vmlinux-btf-[0-9]* 挡掉）。
    _dd_btf_url=$(printf '%s' "$_dd_json" \
        | grep -oE "\"https://[^\"]*/vmlinux-btf-6\.12\.[0-9]+-r[0-9]+-x86_64\.apk\"" \
        | tr -d '"' | sort -V | tail -n1)
    if [ -z "$_dd_btf_url" ]; then
        echo "::error::daed: Release 里没有 x86_64 的 vmlinux-btf-6.12.*-r*.apk"
        exit 1
    fi
    _DAED_BTF_VER=$(basename "$_dd_btf_url" | sed -n 's/^vmlinux-btf-\(6\.12\.[0-9]*\)-r[0-9]*-x86_64\.apk$/\1/p')
    if [ -z "$_DAED_BTF_VER" ]; then
        echo "::error::daed: 解析不出 BTF 版本号（$_dd_btf_url）"
        exit 1
    fi
    # 与目标内核版本对齐 —— 不一致就让构建停在这里，别等 daed 起不来才查
    _dd_kver=$(sed -n 's/^LINUX_VERSION-6\.12 = //p' \
        /home/build/immortalwrt/include/kernel-version.mk 2>/dev/null | head -n1)
    if [ -n "$_dd_kver" ] && [ "$_dd_kver" != "$_DAED_BTF_VER" ]; then
        echo "::error::daed: vmlinux-btf 版本 $_DAED_BTF_VER 与目标内核 $_dd_kver 不一致，daed 的 eBPF 校验会失败"
        exit 1
    fi
    echo "    BTF 版本 $_DAED_BTF_VER（目标内核 ${_dd_kver:-未知，跳过校验}）"
    echo "    ↓ $(basename "$_dd_btf_url")"
    # 【2026-11-11】下载前先清掉 packages/ 里所有旧 btf包。
    # ImageBuilder 镜像自带一份 vmlinux-btf-6.12.103-r1-x86_64.apk（正好就是目标内核
    # 版本，所以 _ak_skip_btf 排除不掉它）；下面 cp 进来的 6.12.87 与
    # _gh_fixname 改名后的 6.12.103-r1 也在同一目录。三份同名同版本的包同时存在，
    # apk mkndx 会全编进索引，但一个名字+版本只能对一条 datahash，其余在
    # make image 阶段报：ERROR: vmlinux-btf-6.12.103-r1: ADB integrity error
    # （真机 2026-11-11 run #22 就是这么挂的）。
    # 先清干净，只留下面下载的那一份（版本已和目标内核校过）。
    rm -f /home/build/immortalwrt/packages/vmlinux-btf-*.apk 2>/dev/null || true
    wget -q "$_dd_btf_url" -P /home/build/immortalwrt/packages/ \
        || { echo "::error::daed: 下载失败 $_dd_btf_url"; exit 1; }
    # 【2026-11-11】下载后必须改名：apk 3.x 取包时按
    # <name>-<version>.apk 拼路径，不读索引里的 filename。
    # 下载回来的叫 vmlinux-btf-6.12.103-r1-x86_64.apk，客户端拼的是
    # vmlinux-btf-6.12.103-r1.apk —— 不改名就报
    #   ERROR: vmlinux-btf-6.12.103-r1: package mentioned in index not found
    # （run #23 就是这么挂的）。
    _gh_fixname "/home/build/immortalwrt/packages/$(basename "$_dd_btf_url")" || exit 1
    _dd_n=$((_dd_n + 1))

    for _dd_pkg in daed luci-app-daede; do
        # 取版本号最大的，不取第一个匹配 —— Release 里同名包可能留着旧版资产，
        # head -n1 会挑到旧的，构建出来还是上一代固件（honk 线踩过这个坑）。
        _dd_url=$(printf '%s' "$_dd_json" \
            | grep -oE "\"https://[^\"]*/${_dd_pkg}-[0-9][^\"]*x86_64[^\"]*\.apk\"" \
            | tr -d '"' | sort -V | tail -n1)
        if [ -z "$_dd_url" ]; then
            echo "::error::daed: Release 里没有 ${_dd_pkg}-*x86_64*.apk"
            exit 1
        fi
        echo "    ↓ $(basename "$_dd_url")"
        wget -q "$_dd_url" -P /home/build/immortalwrt/packages/ \
            || { echo "::error::daed: 下载失败 $_dd_url"; exit 1; }
        # GitHub 可能把资产名里的 ~ 换成 .，包内 pkgver 仍是 ~ —— 必须改回来，
        # 否则 make image 的 package_install 找不到文件（25.12 honk 线 run #18 就这么挂的）
        _gh_fixname "/home/build/immortalwrt/packages/$(basename "$_dd_url")" || exit 1
        _dd_n=$((_dd_n + 1))
    done
    echo "✅ daed: $_dd_n 个 apk 已进 packages/（版本随 Release 走，BTF=$_DAED_BTF_VER）"
    ls -l /home/build/immortalwrt/packages/daed-*.apk \
          /home/build/immortalwrt/packages/luci-app-daede-*.apk \
          /home/build/immortalwrt/packages/vmlinux-btf-*.apk 2>/dev/null || true
else
    echo "⚪️ 未选择 daed"
fi

# OpenClash 的 apk 也是直接从 GitHub Release 下的，资产名同样会被 GitHub 把 ~
# 换成 .（本次没选 openclash，未实测，但风险与 honk 同源）。
# _gh_fixname 定义在上面，这里补一刀；没选时通配符不匹配，循环空转。
for _oc_f in packages/luci-app-openclash-*.apk; do
    [ -f "$_oc_f" ] || continue
    _gh_fixname "$_oc_f" || exit 1
done

if [ -n "$EXTRA_APK_REPOS" ] && [ -f "$REPOS_CONF" ]; then
    echo "🔗 加挂第三方 apk 源:"
    echo "$EXTRA_APK_REPOS"
    printf '%s\n' "$EXTRA_APK_REPOS" >> "$REPOS_CONF"
    echo "--- 当前 repositories.conf ---"
    cat "$REPOS_CONF"
else
    echo "⚪️ 未加挂第三方 apk 源"
fi

if [ -d /home/build/immortalwrt/shell/apk-keys ]; then
    mkdir -p /home/build/immortalwrt/keys
    cp -v /home/build/immortalwrt/shell/apk-keys/*.pub /home/build/immortalwrt/keys/ 2>/dev/null
    cp -v /home/build/immortalwrt/shell/apk-keys/*.rsa.pub /home/build/immortalwrt/keys/ 2>/dev/null
fi
case " $PACKAGES " in
    *" luci-i18n-aria2"*)
        mkdir -p files/aria2
        chown 6800:6800 files/aria2
        chmod 775 files/aria2
        echo "✅ aria2 下载目录 /aria2 已建（编译期）"
        ;;
    *)
        echo "⚪️ 未选择 aria2，跳过 /aria2 目录创建"
        ;;
esac

# 【v.108.45 → v.108.56】guard 的静态基准。
# 现在基底已整份在 squashfs（$BASE_DIR），这 16 个文件本来就在里面，再拷一遍是为了
# 「与 rootfs-skel 单一来源对齐」——prebuilt 包若比仓库旧，以仓库版本为准。
# 仍然不放进来的：config.yaml / crowdsec-net.conf / resolv.conf。
# 它们由 bootstrap 的 capi / ct_net / ct_resolv 每轮重写，
# 固化进只读层就是「bootstrap 写 → guard 改回去」的死循环。
# 【v.108.60】acquis.yaml 反过来从「不进来」变成「必须进来」：它是日志入口，
# config.yaml 的 acquisition_path 指着它，而 v.108.46 之后 bootstrap 不再重写它
# （setup_acquis 只校验 router.yaml 那三份）。以前它被删只能靠 _structurally_broken
# 判整盘损坏 → 重装 288MB，现在由 guard 一次原子 cp 复原。
# 【v.108.56】容器固定文件进 squashfs：把 prebuilt 包展开成只读基底。
# 为什么不再「tarball 原样进固件、首启解压」：
#   ① tarball 是个压缩包，guard 没法用 cmp 比它；展开进 squashfs 后才有同路径散文件；
#   ② 首启省掉 288MB 解压（真机实测这是开机最重的一段）；
#   ③ 固定文件落在 lower，容器内改不动 —— 保护从「每 60 秒盖回去」变成「物理不可写」。
# 体积账：tarball 107MB 换成 squashfs 里的 base，压缩后大致相当，固件几乎不变大；
# 所以包解压完就删，不让同一份内容在固件里存两次。
BASE_DIR="files/srv/lxc/ubuntu/base"
TARBALL_IN="files/etc/crowdsec/lxc-crowdsec.tar.gz"
if [ -f "$TARBALL_IN" ]; then
    echo "==> 展开容器只读基底 → $BASE_DIR"
    rm -rf "$BASE_DIR"
    mkdir -p "$BASE_DIR"
    tar -xzpf "$TARBALL_IN" -C "$BASE_DIR" \
        || { echo "::error::展开容器基底失败（$TARBALL_IN）"; exit 1; }
    for _need in etc/os-release etc/inittab usr/bin/crowdsec etc/crowdsec/acquis.yaml; do
        [ -e "$BASE_DIR/$_need" ] \
            || { echo "::error::基底缺 $_need —— 包结构不对，不能进固件"; exit 1; }
    done
    # 指纹给运行期用：upper 记着自己照着哪版基底建的，不符就整层丢弃，
    # 否则换固件后旧 upper 会永久遮住新基底的同名文件 —— 看着升级了，其实没升。
    sha256sum "$TARBALL_IN" | awk '{print $1}' > "$BASE_DIR.fingerprint"
    echo "==> 基底就绪：$(du -sh "$BASE_DIR" | cut -f1)，指纹 $(cat "$BASE_DIR.fingerprint")"
    rm -f "$TARBALL_IN"
    echo "==> 已从固件移除 prebuilt 包（内容已在 $BASE_DIR）"
else
    # 【v.108.59】workflow 只剩 prebuilt 一条路：本地 Prepare 回退已删，Download 步骤
    # 取不到包就在自己那一步 ::error:: + exit 1。这里是最后一道兜底 —— 万一哪天有人
    # 把那句 exit 去掉，也不能让空基底混进固件。
    # 继续构建只会得到「网络正常、容器永不启动」的固件 —— 现场表现是 rc.local 静默走
    # --net-only，路由器好好的，容器永远不来，属于最难查的一类。宁可让构建失败。
    echo "::error::没有容器基底：files/etc/crowdsec/lxc-crowdsec.tar.gz 不存在，prebuilt 未产出，拒绝构建无容器的固件"
    exit 1
fi

[ -d rootfs-skel ] || {
    echo "::error::找不到 rootfs-skel/（当前目录 $(pwd)）—— workflow 的 docker run 必须把仓库根下的 rootfs-skel 挂进来：-v \"\$GITHUB_WORKSPACE/rootfs-skel:/home/build/immortalwrt/rootfs-skel\"。没有它，容器内那批受保护文件既进不了 tarball 也进不了固件。"
    exit 1
}
ROOTFS_GUARD_DIR="$BASE_DIR"
# 【v.108.56】目标从 rootfs/ 改为 base/：guard 运行期读的是挂载点合并视图，
# 但静态基准必须和基底在同一处，否则 squashfs 里会多一份 288MB 之外的副本。
if [ -d "$BASE_DIR" ]; then
for _rel in \
    etc/passwd \
    etc/group \
    etc/nsswitch.conf \
    etc/hosts \
    etc/resolv.conf \
    etc/crowdsec-net.conf \
    etc/crowdsec/acquis.yaml \
    etc/crowdsec/acquis.d/router.yaml \
    etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml \
    etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml \
    etc/inittab \
    etc/init.d/rcS \
    etc/init.d/crowdsec \
    etc/init.d/netconf \
    etc/init.d/syslogd \
    usr/sbin/crowdsec-supervise; do
    mkdir -p "$ROOTFS_GUARD_DIR/$(dirname "$_rel")"
    cp -f "rootfs-skel/$_rel" "$ROOTFS_GUARD_DIR/$_rel" \
        || { echo "::error::缺 rootfs-skel/$_rel（容器脚本单一来源，prepare 与 guard 都靠它）"; exit 1; }
done
chmod 0755 "$ROOTFS_GUARD_DIR"/etc/init.d/rcS "$ROOTFS_GUARD_DIR"/etc/init.d/crowdsec \
           "$ROOTFS_GUARD_DIR"/etc/init.d/netconf "$ROOTFS_GUARD_DIR"/etc/init.d/syslogd \
           "$ROOTFS_GUARD_DIR"/usr/sbin/crowdsec-supervise
chmod 0644 "$ROOTFS_GUARD_DIR/etc/passwd" "$ROOTFS_GUARD_DIR/etc/group" \
           "$ROOTFS_GUARD_DIR/etc/nsswitch.conf" "$ROOTFS_GUARD_DIR/etc/hosts" \
           "$ROOTFS_GUARD_DIR/etc/resolv.conf" "$ROOTFS_GUARD_DIR/etc/crowdsec-net.conf" \
           "$ROOTFS_GUARD_DIR/etc/inittab"
chmod 0644 "$ROOTFS_GUARD_DIR/etc/crowdsec/acquis.yaml" \
           "$ROOTFS_GUARD_DIR/etc/crowdsec/acquis.d/router.yaml" \
           "$ROOTFS_GUARD_DIR/etc/crowdsec/parsers/s01-parse/openwrt-dropbear.yaml" \
           "$ROOTFS_GUARD_DIR/etc/crowdsec/parsers/s02-enrich/openwrt-whitelist.yaml"
fi
echo "==> 容器内受保护文件已进固件（16 个，/rom 只读基准）"

# 出镜像前补齐执行位并逐项断言：路径改名或文件漏拷时让构建直接失败。
# 不再用 2>/dev/null 把 chmod 的错误吞掉——那样后面那句"已确保可执行"就是在撒谎。
# 99-custom.sh / 98-lxc-auto.sh 走 uci-defaults 的 `.` 载入，不依赖执行位，所以只在 chmod 里，不进断言表。
# 【v.180.143】改成扫目录，不再逐个枚举。
# 起因：v.180.133 新增的 pkg-cache-check/fix/restore/lib.sh 忘了加进原来的枚举列表，
# 四个脚本以 644 进固件，真机 /usr/sbin/pkg-cache-check.sh 直接
#   -ash: /usr/sbin/pkg-cache-check.sh: Permission denied   (rc=126)
# 而 bootstrap 里调 /usr/sbin/pkg-cache-restore.sh 的地方同样失效 —— 包级自愈一直是废的，
# 只是没在真机上跑过所以没暴露。枚举法必然还会漏，改成扫 files/usr/sbin/*.sh。
# 【v.180.165】pkg-cache-check.sh 已删除（源检查内联在探针 _pkgcache_probe 里，
# 那份脚本从上线起没被调用过）。上面这段保留作历史 —— 它解释的是「为什么扫目录
# 而不是逐个枚举」，与具体某个文件在不在无关。
# 【v.180.163】init.d 也改成扫目录：cgroup2-guard 没有 .sh 后缀，
# 「files/usr/sbin/*.sh」和「逐个点名的 init.d 两项」两条通道都漏了它 ——
# 它靠 git mode 恰好是 755 才没出事，一旦哪次提交丢了执行位，docker 会在
# 开机时静默失败（devices cgroup 没挂 → dockerd 退出 → docker0 不建）。
# 【2026-11-10】改成递归扫。原来 files/usr/sbin/*.sh 只匹配**一层**，
# 拆分后的 bootstrap/ smartdns/ adblock/ 三个子目录（33 个 .sh）全在匹配之外；
# 末尾的 2>/dev/null 又把 "No such file" 静默吞掉 —— 权限真丢了也看不出来。
# 校验循环同样改递归：只 chmod 不校验，等于加了个看不见的兜底。
chmod +x files/etc/rc.local 2>/dev/null || true
# uci-defaults / usr/sbin 下全是 .sh，按后缀筛即可
find files/etc/uci-defaults files/usr/sbin \
     -type f \( -name '*.sh' -o -name 'rc.local' \) \
     -exec chmod +x {} + 2>/dev/null || true
# init.d 下**全部**都给执行位：cgroup2-guard / lxc-auto / zram-guard 没有 .sh
# 后缀，原来靠 `chmod +x files/etc/init.d/*` 的通配覆盖全部；改成按后缀筛会漏掉
# 这三个，而它们恰好是「丢了执行位就静默不启动」的那类（devices cgroup 不挂 →
# dockerd 退出 → docker0 不建）。这个坑 v.180.163 已经踩过一次。
find files/etc/init.d -type f -exec chmod +x {} + 2>/dev/null || true
for _f in files/etc/rc.local \
          $(find files/etc/uci-defaults files/usr/sbin \
            -type f \( -name '*.sh' -o -name 'rc.local' \) 2>/dev/null) \
          $(find files/etc/init.d -type f 2>/dev/null); do
    [ -x "$_f" ] || { echo "::error::缺少执行位: $_f"; exit 1; }
done
_n_sh=$(find files/usr/sbin -type f -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
echo "==> 已确保引导/自愈脚本可执行（files/usr/sbin 全树 $_n_sh 个 .sh，含 bootstrap/smartdns/adblock）"

echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

# 【v.180.120】把仓库里的自检脚本铺进固件。
# 刷机后 /rom 里就有这批文件的只读基准，guard 的目录级保护才比得出、也才补得回。
# 放 /usr/share（只读数据位）而不是 /usr/sbin，免得和真正的可执行命令混在一起。
#
# 分两组：
#   crowdsec-tests/       只读断言类，跑起来不改现场
#   crowdsec-tests/danger 会写 uci 或注入损坏的那几个，动之前先看 README
mkdir -p files/usr/share/crowdsec-tests/danger
_t_n=0
_t_d=0
# tests/ 是仓库里的目录，靠 workflow 的 -v 挂进容器；没挂上就只是没自检脚本，
# 不影响固件功能（guard 对 /usr/share/crowdsec-tests 是「没有就跳过」），所以只警告不中断。
[ -d tests ] || echo "::warning::容器里没有 tests/ 目录，本次镜像不带自检脚本"
for _t in tests/*; do
    [ -f "$_t" ] || continue
    case "${_t##*/}" in
    probe_netsafe.sh|probe_v10832.sh|test_bp_*)
        cp -a "$_t" files/usr/share/crowdsec-tests/danger/ || exit 1
        _t_d=$((_t_d + 1))
        ;;
    *)
        cp -a "$_t" files/usr/share/crowdsec-tests/ || exit 1
        _t_n=$((_t_n + 1))
        ;;
    esac
done
chmod 755 files/usr/share/crowdsec-tests/*.sh files/usr/share/crowdsec-tests/danger/*.sh 2>/dev/null || true
chmod 644 files/usr/share/crowdsec-tests/*.py 2>/dev/null || true
# 空目录会被 make image 静默丢掉。这里只警告不 exit：自检脚本是附加能力，
# 缺了它固件照样该出，否则一次漏挂载就把整条构建线卡死。
if [ "$_t_n" -gt 0 ]; then
    echo "==> 自检脚本已铺进固件：只读 $_t_n 个，danger $_t_d 个"
else
    echo "::warning::自检脚本一个都没铺进去，本镜像不含 crowdsec-tests（不阻断出镜像）"
fi

# ---- 第 0.5 遍（条件）：只在拿不到 apk 二进制时才补编 ----
# 【v.180.136】原来这里无条件编一整遍，唯一的目的是拿到
# staging_dir/host/bin/apk 去给包库建索引。但那个 apk 是 ImageBuilder
# 压缩包自带的预编译工具，解压后就在 —— 于是这一整遍（实测 5-10 分钟）
# 多数时候纯属白跑。现在先探测：有就跳过，最后只编一次。
#
# 不能干脆删掉：万一某个 ImageBuilder 版本确实不带 apk，索引就建不出来，
# 包库退化成「只能按绝对路径装」。所以保留这个兜底分支，代价只是一次 test -x。
# 【v.180.138】判据从「文件存在」收紧成「版本是 apk-tools 3」。
# 上一轮就是只看 -x：文件在、可执行，但它是 2.x —— 只认 tar.gz 的老格式，
# 而 25.12 的包全是 ADB 二进制，于是 no index 一败到底（详见包库段）。
_AK_PRE=""
for _c in "$(pwd)/staging_dir/host/bin/apk" "$(pwd)/staging_dir/host/bin/apk.static"; do
    [ -x "$_c" ] || continue
    _ak_v=$("$_c" --version 2>&1 | head -n1)
    echo "==> [预构建] 探测到 $_c：${_ak_v:-（--version 无输出）}"
    case "$_ak_v" in
    *"apk-tools 3"*) _AK_PRE="$_c" ;;
    *) echo "==> [预构建] 版本不是 apk-tools 3.x，用它建索引会把 25.12 的包全部判成坏包" ;;
    esac
    break
done
if [ -n "$_AK_PRE" ]; then
    echo "==> [预构建] apk 二进制可用：$_AK_PRE"
    echo "==> [预构建] 跳过第一遍 make image，最后只编一次"
else
    echo "==> [预构建] 没有可用的 apk 二进制，先编一遍把它生成出来（这一步省不掉）"
    make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE
    if [ $? -ne 0 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed (pre-pass)!"
        exit 1
    fi
    _PRE_PASS=1
fi

# 【v.180.195】预构建那一遍的镜像本体，用完立刻删。
# 两遍 make image 各产一个 ${PROFILE}MB 的 img；不删的话第二遍开跑时，
# 第一遍的产物还躺在 bin/targets 里，磁盘峰值 = 两遍之和。
# 只删镜像产物：packages/ 与 profiles.json 是第二遍要用的，一个都不能碰。
# 第二遍 make image 每次都重新 install，删掉会照常重建，不影响产物完整性。
#
# 稀疏性得现场说清楚：gen_image_generic 用 dd seek 铺空文件，理论上一份
# 20G 的 img 实际只占几百 MB；但后续 cp 若没带 --sparse 会被实体化成 20G。
# 到底是哪种，只有数字能定性 —— 所以这里同时打两个数：
#   df  可用空间（真正被吃掉的盘）
#   du  目录实际占用
# du 远小于 img 逻辑大小 → 稀疏，这段清理省的是逻辑大小、不是真盘；
# du ≈ 逻辑大小 → 实体，这段清理才真救命。
if [ "${_PRE_PASS:-0}" = "1" ]; then
    echo "==> 清理预构建产物，把空间让给第二遍"
    df -h bin | tail -1
    du -sh bin/targets/x86/64 2>/dev/null
    rm -f bin/targets/x86/64/*.img \
          bin/targets/x86/64/*.img.gz \
          bin/targets/x86/64/*.rootfs.tar.gz
    echo "==> 清理后"
    df -h bin | tail -1
    du -sh bin/targets/x86/64 2>/dev/null
fi

# ---- v.180.130：收关键包 apk 到 files/root/apk-cache/ ----
# 目的：smartdns / lxc / daed / mosdns / ssr-plus / clashoo / crowdsec-bouncer 被人
# opkg→apk 卸掉后，能用固件自带的包装回来，且记账正确（/etc/apk/world）、LuCI 可见。
#
# files/ 在下面第二遍 make image 时合进 rootfs，所以这批 apk 最终躺在 squashfs 里，
# 刷机后是只读的 /rom/root/apk-cache（不是 overlay 的 /root/apk-cache）。
# 运行期脚本按 /rom 优先解析：只读层删不掉、不占 overlay、与固件同版。
_AK_DIR="files/root/apk-cache"
rm -rf "$_AK_DIR"
mkdir -p "$_AK_DIR"

# 【v.180.132】白名单按 25.12.2（本次实建 622 个包的 Installing 清单）逐条核对修正。
# 旧版是照 24.10 抄的，有 12 个包名在 25.12 里根本不存在，白等一整轮：
#   lxc-monitord                    → 25.12 叫 lxc-monitor（无尾 d）
#   lxc-unprivileged / lxc-user-nic → 25.12 无此拆包，删
#   luci-i18n-smartdns-zh-cn        → 25.12 无此 i18n 包，删
#   dae / dae-geoip / dae-geosite / luci-app-dae / luci-i18n-dae-zh-cn
#                                   → 25.12 全套改名 daed-*（多一个 d），旧名删
#   crowdsec                        → 本体跑在 LXC 容器里（由 crowdsec-lxc tarball 提供，
#                                     宿主机不需要），宿主机只装防火墙 bouncer，所以不收主包
# 修正后 51 条，实测在 25.12.2 官方 index.json 里 51/51 全部命中；
# 【v.180.167】删掉 xray-core / xray-plugin 后为 49 条。
# 【2026-11-02】收进 adblock 三包：实测 47 条（此前 44 条，中间另有增删，
#   上面 49 那个数字是 v.180.167 当时的快照，不要再拿它当现值）。
#
# 【2026-11-02】adblock 三包为什么必须收进包库：
# 用户当日定「先留着，也保护起来」，于是 pkg-restore-apps.sh 里有了 _PA_ADBLOCK。
# 但那次在 201 上实测：/rom/root/apk-cache 116 个 apk 里 adblock 相关【0 个】——
# 光加保护组是假的，_pr_pkg 走的是包库，包库没有就装不回来，
# 探针会每分钟报「缺失」然后修不动，永远卡在那。
# 收进包库之后三条路才都通：
#   包被 apk del   → apk add 从包库装回，记账与文件一起回来；
#   包在、文件被删 → PCR_FORCE 按包内清单覆盖；
#   两者都不需要联网。
#
# 【v.180.167】xray-core / xray-plugin 不再收（ssrp 专属，用户 2026-10-29 定不用 ssrp）。
# 收进包库的直接后果：25.12 真机探针按旧判据把这两个装了上去（624 vs 出厂 622）。
# v2ray-geoip / v2ray-geosite 保留：通用 geo 数据，随 geoview 的依赖进固件，同时收进包库。
# 【2026-11-02】探针双通道：包级（_PA_GEO，管包被 apk del）+ 文件级（--deps，管 .dat 被删）。
# 两条判据都只看「在不在」、不看版本 —— 用户换过新数据不会被按回出厂版，
# 真删了又能自己长回来（/usr/share/v2ray/{geoip,geosite}.dat，从 /rom 拷回）。
#
# 注意：下面是**双引号字符串**，注释只能写在起始引号之前。写在里面的 `#`
# 不是注释，会被当成包名的一部分（v.180.167 踩过这个坑）。
_AK_WANT="lxc lxc-attach lxc-auto lxc-autostart lxc-cgroup lxc-checkconfig lxc-common
lxc-config lxc-configs lxc-console lxc-copy lxc-create lxc-destroy lxc-device
lxc-execute lxc-freeze lxc-hooks lxc-info lxc-init lxc-ls lxc-monitor
lxc-snapshot lxc-start lxc-stop lxc-templates lxc-top lxc-unfreeze
lxc-unshare lxc-usernsexec lxc-wait liblxc rpcd-mod-lxc
luci-app-lxc luci-i18n-lxc-zh-cn
smartdns luci-app-smartdns
mosdns
crowdsec-firewall-bouncer luci-app-crowdsec-firewall-bouncer
luci-i18n-crowdsec-firewall-bouncer-zh-cn nftables-json
v2ray-geoip v2ray-geosite sing-box
adblock luci-app-adblock luci-i18n-adblock-zh-cn
geoview
daed luci-app-daede vmlinux-btf"

# 来源 A：packages/ 里 run 包解出的 apk（第三方包，官方源没有）
#
# 【v.180.131】vmlinux-btf 单独排除，理由是与内核强绑定且实测对不上：
#   · 25.12.0 内核 6.12.87 / 25.12.1 内核 6.12.94 / 25.12.2 内核 6.12.103
#   · daed 的 run 包里带的是 vmlinux-btf-6.12.79
#   三个候选版本没有一个是 6.12.79，装上去 daed 的 eBPF 校验过不去。
#   而且 25.12 官方源里【一个 btf 包都没有】，说明内核已自带 BTF
#   （/sys/kernel/btf/vmlinux 由内核提供），本就不该再放一份。
#   若将来 run 包的 btf 版本与目标内核一致，把下面的 case 去掉即可 ——
#   这个判断不写死版本号，只按包名排除，换版本时不需要改代码。
# 【v.180.134】合法 apk 的判定：只有两种文件头
#   1f 8b        gzip       -> apk v2（tar.gz 结构）
#   41 44 42 64  "ADBd"     -> apk v3（ADB 容器）
# 其它一律不是包。真机日志里 apk index 报 "file format not supported" 的
# 那 6 个（xray-core/xray-plugin/v2ray-geoip/v2ray-geosite），就是 run 包里
# 带的坏文件；而「按文件名判断已存在」让它们挡住了官方源的好版本，
# 于是一个坏包废掉整份索引。
_ak_is_apk() {
    _ai_h=$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')
    case "$_ai_h" in
    1f8b* | 41444264*) return 0 ;;
    esac
    return 1
}

_ak_a=0
_ak_skip_btf=""
_ak_skip_geo=""
_ak_bad_a=""
_ak_skip_stale=""
for _f in packages/*.apk; do
    [ -f "$_f" ] || continue
    case "${_f##*/}" in
    # 【2026-11-10】daed 线必须让 vmlinux-btf 进包库：
    #   ① daed 的 DEPENDS 有 +DAED_USE_VMLINUX_BTF:vmlinux-btf，缺包 make image 报错；
    #   ② 探针要从 /rom/root/apk-cache 把它装回来，不进库等于空头支票；
    #   ③ daed 启动要读内核 BTF，版本必须与目标内核一致，装错版本直接起不来。
    # 所以只放行 build25.sh daed 段下载的那份（版本记在 _DAED_BTF_VER），
    # run 包顺带带来的旧版（6.12.79 之类）照旧挡掉，不写死版本号。
    vmlinux-btf-[0-9]*)
        case "${_f##*/}" in
        "vmlinux-btf-${_DAED_BTF_VER}"-*) ;;
        *)
            _ak_skip_btf="$_ak_skip_btf ${_f##*/}"
            continue
            ;;
        esac
        ;;
    # 【v.180.136】geo 数据统一走官方源，run 包带来的两份不要。
    # 原因：同名包在库里会凑出 3 个版本 —— PassWall 的 202606182327.1 /
    # 2026.06.06-r1、daed 的 20260529193437-r1。apk 装依赖时只挑版本号最大的，
    # 而 14 位数字段 20260529193437 必然赢，于是真正装进固件的是 daed 那份；
    # geoip.dat 的格式与 xray-core 版本耦合，选错不报错、只静默分流错误。
    # 官方 25.12.2 有这两个包（geoip 202605120112-r1 / geosite 20260518025449-r1），
    # 格式合法、版本统一、与官方 core 同批构建，比各带一份可靠。
    v2ray-geoip-* | v2ray-geosite-*)
        _ak_skip_geo="$_ak_skip_geo ${_f##*/}"
        continue
        ;;
    # 【2026-11-10】luci-app-daede 不再是「旧名残留」—— 官方线改用 daed 后
    # 它就是正主（kenzok8 v2026.11.09 的 LuCI 界面，1.15-r13，PKGARCH:=all）。
    # 原来的排除规则已删掉，否则会把要装的界面挡在包库外。
    # luci-i18n-daede-zh-cn 是更早的旧 i18n 名，仍按残留挡掉。
    luci-i18n-daede-zh-cn-[0-9]*)
        _ak_skip_stale="$_ak_skip_stale ${_f##*/}"
        continue
        ;;
    # 【2026-11-09】以下包**不需要离线保护**：不是系统组件，反向依赖为空
    # （apk info 实测 rdeps=0 或仅被自己的语言包依赖），删了联网即可装回：
    #   argon 三包      默认主题是 bootstrap，该主题根本没启用
    #   partexp 两包    分区扩容工具
    #   taskplan 两包   计划任务界面
    #   rtp2httpd 三包  RTSP->HTTP 代理
    # 合计约 828 KB，没必要占 squashfs。argon 已同时从 PACKAGES 移除，
    # 这里再挡一道的原因是：run 包可能仍来自移除前的构建。
    luci-theme-argon-* | luci-app-argon-config-* | luci-i18n-argon-config-zh-cn-*)
        _ak_skip_stale="$_ak_skip_stale ${_f##*/}"
        continue
        ;;
    luci-app-partexp-* | luci-i18n-partexp-zh-cn-*)
        _ak_skip_stale="$_ak_skip_stale ${_f##*/}"
        continue
        ;;
    luci-app-taskplan-* | luci-i18n-taskplan-zh-cn-*)
        _ak_skip_stale="$_ak_skip_stale ${_f##*/}"
        continue
        ;;
    rtp2httpd-* | luci-app-rtp2httpd-* | luci-i18n-rtp2httpd-zh-cn-*)
        _ak_skip_stale="$_ak_skip_stale ${_f##*/}"
        continue
        ;;
    esac
    # 拷之前先验文件头：坏文件不进库，否则它会以「已存在」挡住官方源的好版本
    if ! _ak_is_apk "$_f"; then
        _ak_bad_a="$_ak_bad_a ${_f##*/}"
        continue
    fi
    cp -f "$_f" "$_AK_DIR"/ && _ak_a=$((_ak_a + 1))
done
echo "==> [apk-cache] 来源 A（run 包）：$_ak_a 个 apk"
if [ -n "$_ak_bad_a" ]; then
    echo "::warning::run 包里有不是合法 apk 的文件（已丢弃，改由官方源补）：$_ak_bad_a"
fi
if [ -n "$_ak_skip_btf" ]; then
    echo "::warning::已排除 $_ak_skip_btf（内核 BTF 与目标内核版本不一致；25.12 内核自带 BTF，无需此包）"
fi
if [ -n "$_ak_skip_geo" ]; then
    echo "==> [apk-cache] 已排除 run 包里的 geo 数据（统一走官方源，避免多版本被 apk 挑错）：$_ak_skip_geo"
fi
if [ -n "$_ak_skip_stale" ]; then
    echo "==> [apk-cache] 已排除改名前的旧包：$_ak_skip_stale"
fi

# ---- 【2026-11-02】保护组在库核对 ----
# pkg-restore-apps.sh 的 _PA_DAED / _PA_GEO 只负责「发现缺失」；真正装回来
# 靠的是 /rom/root/apk-cache 里这份本地包库。库里没有对应 apk 的话，
# 探针每轮报缺失、每轮修不好 —— 那不是保护，是每轮白报一次警。
# 所以在构建期当场核对，别把空头支票留到真机。
#
# 【2026-11-10】官方线改用 daed 后，断言改成 daed 三件套。
# 这里只查「来自 packages/ 的第三方包」：v2ray-geoip / v2ray-geosite / ca-bundle /
# kmod-sched-* / kmod-veth 这些是 daed 的 DEPENDS，由官方源在 make image 阶段落地，
# 不经过 packages/ —— 把它们写进断言只会在构建期误报（25.12-honk run #13 的教训）。
if echo "$PACKAGES" | grep -q "daed"; then
    _ak_need_daed="daed luci-app-daede vmlinux-btf"
    _ak_daed_miss=""
    for _ak_np in $_ak_need_daed; do
        ls "$_AK_DIR"/"$_ak_np"-[0-9]*.apk >/dev/null 2>&1 || _ak_daed_miss="$_ak_daed_miss $_ak_np"
    done
    if [ -n "$_ak_daed_miss" ]; then
        echo "::error::daed 保护组缺包，探针将无法装回：$_ak_daed_miss"
        echo "::error::来源 A 看 packages/*.apk（kenzok8/openwrt-daede 的 Release）"
        ls -la "$_AK_DIR" 2>/dev/null | grep -iE "daed|daede|vmlinux" || true
        exit 1
    fi
    echo "==> [apk-cache] daed 保护组齐备（3 包）：$_ak_need_daed"
fi

# geo 两包的核对放在来源 B 之后 —— 它们来自官方源，不是 packages/。

# apk 二进制定位：只给最后「生成 packages.adb 索引」用，来源 B 已不依赖 apk。
# 【v.180.131】apk 不一定在 PATH 里：ImageBuilder 容器是 Ubuntu 底子，
# 给 rootfs 装包用的是它自带那份（staging_dir/host/bin/apk，与 grub-bios-setup 同目录）。
# 上一轮日志已证实探测命中该路径，所以按「自带优先、PATH 兜底」探一遍固定到 _AK_BIN。
# 【v.180.138】这里原来只判断 -x。文件在、能执行，但版本不对时 apk 会对
# 25.12 的每一个包都报 file format not supported —— 上一轮 114 个包就是这样
# 被判成「坏包」全删的。所以从这一处开始就必须按版本挑工具。
_AK_BIN=""
for _c in "$(pwd)/staging_dir/host/bin/apk" "$(pwd)/staging_dir/host/bin/apk.static"; do
    [ -x "$_c" ] || continue
    case "$("$_c" --version 2>&1 | head -n1)" in
    *"apk-tools 3"*) _AK_BIN="$_c"; break ;;
    esac
    echo "==> [apk-cache] 跳过 $_c：$("$_c" --version 2>&1 | head -n1)（不是 apk-tools 3）"
done
if [ -z "$_AK_BIN" ]; then
    _c=$(command -v apk 2>/dev/null)
    if [ -n "$_c" ]; then
        case "$("$_c" --version 2>&1 | head -n1)" in
        *"apk-tools 3"*) _AK_BIN="$_c" ;;
        *) echo "==> [apk-cache] PATH 里的 apk 也不是 3.x：$("$_c" --version 2>&1 | head -n1)" ;;
        esac
    fi
fi
_AK_IDX=""
if [ -n "$_AK_BIN" ]; then
    echo "==> [apk-cache] apk 用：$_AK_BIN（$("$_AK_BIN" --version 2>&1 | head -n1)）"
    # 【v.180.139】根因终于定位：apk 有两个建索引的 applet，作用完全不同 ——
    #   apk index  -> 生成 v2 的 APKINDEX.tar.gz，只吃 tar.gz 包
    #   apk mkndx  -> 生成 apkv3 的 packages.adb，这才是 25.12 要的东西
    # 之前一直用 index 去读 ADB 包，于是每个包都报
    #   "xxx.apk: file format not supported (in this applet)"
    # 那句 (in this applet) 的意思正是「当前 applet 不支持这种文件格式」。
    # v.180.134 把这句当成「包是坏的」，是整条误删链的起点。
    #
    # 早探针顺便就把 applet 定下来：拿 extra-packages 里现成的一个包逐个试，
    # 谁能建出非空索引就用谁。失败只报错不阻断 —— 阻断会卡死整条构建线，
    # 而「有包无索引」的镜像至少还能按绝对路径装。
    _ak_ep=$(find extra-packages -name '*.apk' 2>/dev/null | head -n1)
    if [ -n "$_ak_ep" ]; then
        for _ap in mkndx index; do
            if "$_AK_BIN" --allow-untrusted "$_ap" -o /tmp/ak-probe.adb "$_ak_ep" \
                    >/tmp/ak-probe.log 2>&1 && [ -s /tmp/ak-probe.adb ]; then
                _AK_IDX="$_ap"
                echo "==> [apk-cache] 索引命令确定为 apk $_ap（试索引 $(basename "$_ak_ep") 通过）"
                break
            fi
        done
        if [ -z "$_AK_IDX" ]; then
            echo "::error::apk mkndx 与 index 都建不出索引：$_AK_BIN 读不了 $(basename "$_ak_ep")"
            head -n 5 /tmp/ak-probe.log 2>/dev/null
        fi
        rm -f /tmp/ak-probe.adb
    else
        # 没有现成的包可试：押 mkndx（25.12 唯一的正解），失败再回退
        _AK_IDX="mkndx"
    fi
else
    echo "::error::没有可用的 apk-tools 3.x，本次建不出 packages.adb（包仍会收进镜像，真机可按绝对路径装）"
fi

# 【v.180.132】来源 B：官方源官方包，用 index.json + HTTP 直下。
# 三条实证决定了这个写法，前两版都是错的：
#   ① 上一版想"直接读本地 packages/"——错。ImageBuilder 的 packages/ 里只有 run 包
#      （日志里来源 A 恰好 75 个 = packages/*.apk 全量，排除 btf 后），官方 547 个包
#      是它联网流式装进 rootfs 的，装完不落地，本地根本没有；
#   ② 原版用 apk fetch —— 也错。apk-tools 3.0.5 的 FETCH_OPTIONS 里没有 --output-dir
#      也没有 --recursive（只有 -o/--output、--built-after、--pkgname-spec、-s/--stdout、
#      --url、--link），所以 rc=1；而且宿主机是 Ubuntu，没有 /etc/apk/repositories，
#      apk update 必然失败，apk 也就无从知道有哪些包可下；
#   ③ 官方每个 feed 目录都有 index.json，格式是 {"packages":{"包名":"完整版本"}}，
#      文件名就是 "包名-版本.apk"。实测 lxc-6.0.5-r1 / smartdns-48.4-r1 /
#      luci-app-daed-26.236.50544~cb5d434 等 HEAD 全部 200。
# 所以直接取 index.json 拼文件名下载，不碰 apk 的索引/签名/宿主配置，确定性最高。
# 版本取的就是 25.12.2 官方源当前版本，与本次 ImageBuilder 装机来源同源同日。
_AK_BASE="${AK_BASE_OVERRIDE:-https://downloads.immortalwrt.org/releases/25.12.2}"
_AK_FEEDS="${AK_FEEDS_OVERRIDE:-packages/x86_64/base packages/x86_64/luci packages/x86_64/packages packages/x86_64/routing packages/x86_64/telephony targets/x86/64/packages}"

_AK_DL="${AK_DL_OVERRIDE:-}"
if [ -z "$_AK_DL" ]; then
    if command -v curl >/dev/null 2>&1; then
        _AK_DL=curl
    elif command -v wget >/dev/null 2>&1; then
        _AK_DL=wget
    fi
fi
echo "==> [apk-cache] 下载器：${_AK_DL:-无}；源：$_AK_BASE"

# $1=url $2=输出文件
_ak_dl() {
    case "$_AK_DL" in
    curl) curl -fsSL --connect-timeout 20 --max-time 180 -o "$2" "$1" ;;
    wget) wget -q -T 30 -O "$2" "$1" ;;
    *) return 1 ;;
    esac
}

_ak_b=0
_ak_miss=""
if [ -n "$_AK_DL" ]; then
    # 【v.180.133】_AK_WANT 是多行字符串，原来只 tr ' ' '|' 换空格，换行还在。
    # 而 pattern 外面套的是 "(...)"：换行会把整个正则拆成 12 条残缺片段 ——
    # 第一段只有左括号、最后一段只有右括号，grep 直接报 Unmatched 退出，
    # stdout 空，退出码又被 2>/dev/null 吞掉。run #77 的真机表现就是
    # 「1.4 秒、来源 B 0 个 apk、连一条 missing 都没有」。
    # 先把所有空白压成单空格，再转 |，最后校验 pattern 里不能再有空白。
    _ak_pat=$(printf '%s' "$_AK_WANT" | tr '\n' ' ' | tr -s ' ' | sed 's/^ *//; s/ *$//' | tr ' ' '|')
    case "$_ak_pat" in
    "" | *[[:space:]]*)
        echo "::error::白名单正则里还有空白（或为空），index.json 匹配必然失败"
        exit 1
        ;;
    esac
    for _ak_fd in $_AK_FEEDS; do
        _ak_u="$_AK_BASE/$_ak_fd"
        _ak_jf="/tmp/akidx.json"
        if ! _ak_dl "$_ak_u/index.json" "$_ak_jf"; then
            echo "::warning::取不到 $_ak_u/index.json，跳过这个 feed"
            continue
        fi
        # 一次 grep 抽出白名单里所有 "<名>":"<版本>"，再逐个拼文件名
        # index.json 实际是 "包名": "版本"（冒号后有空格），grep 要容忍空白，再统一去掉
        for _ak_kv in $(grep -oE "\"($_ak_pat)\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$_ak_jf" 2>/dev/null | sed 's/[[:space:]]//g'); do
            _ak_nm=$(printf '%s' "$_ak_kv" | sed 's/^"//; s/":".*$//')
            _ak_ver=$(printf '%s' "$_ak_kv" | sed 's/^.*":"//; s/"$//')
            [ -n "$_ak_nm" ] && [ -n "$_ak_ver" ] || continue
            # run 包优先：packages/ 里已有【且合法】的同名包就不再下官方版。
            # 【v.180.134】原来只看文件名在不在，坏文件会一直挡住官方版；
            # 现在顺手把同名的坏文件删掉，让官方版能补进来。
            # 【2026-11-09】同名包改为比版本，不再「run 包一律优先」。
            # 原策略只看 packages/ 里有没有合法同名包，有就直接跳过官方源。
            # 201 上 /rom/root/apk-cache 的实测后果：
            #   luci-app-daed        库里 1.4-r1                 固件实装 26.298.29275~c84adb9
            #   luci-i18n-daed-zh-cn 库里 25.283.11553~bce4b5f   固件实装 26.298.29275~c84adb9
            # 固件里是官方 feed 装的新版，库里只有 run 包的旧版 —— pkg-restore.sh --force
            # 走 apk fix 按「已装版本」找包，必然报 APK unavailable，「包在册、文件被删」
            # 这条恢复路直接断掉（实测 luci-app-daed 删文件后修不回来）。
            # 现在官方源不低于 run 包就替换；只有 run 包确实更高才保留。
            _ak_keep=0
            for _ak_e in "$_AK_DIR/$_ak_nm"-*.apk; do
                [ -f "$_ak_e" ] || continue
                if ! _ak_is_apk "$_ak_e"; then
                    rm -f "$_ak_e"
                    echo "::warning::丢弃非法 apk（交回官方源）：${_ak_e##*/}"
                    continue
                fi
                _ak_ev="${_ak_e##*/}"
                _ak_ev="${_ak_ev#"$_ak_nm"-}"
                _ak_ev="${_ak_ev%.apk}"
                if [ -n "$_AK_BIN" ] && [ "$("$_AK_BIN" version -t "$_ak_ev" "$_ak_ver" 2>/dev/null)" = ">" ]; then
                    _ak_keep=1
                    echo "==> [apk-cache] 保留 run 包更高版：$_ak_nm $_ak_ev（官方 $_ak_ver）"
                else
                    rm -f "$_ak_e"
                    echo "==> [apk-cache] 官方版替换 run 包：$_ak_nm $_ak_ev -> $_ak_ver"
                fi
            done
            [ "$_ak_keep" = "1" ] && continue
            _ak_fn="$_ak_nm-$_ak_ver.apk"
            if _ak_dl "$_ak_u/$_ak_fn" "$_AK_DIR/$_ak_fn"; then
                _ak_b=$((_ak_b + 1))
            else
                _ak_miss="$_ak_miss $_ak_nm"
            fi
        done
    done
else
    echo "::warning::容器里既没有 curl 也没有 wget，官方源这部分收不到"
fi
echo "==> [apk-cache] 来源 B（官方源 index.json 直下）：$_ak_b 个 apk"
if [ -n "$_ak_miss" ]; then
    echo "::warning::以下包在官方源上没下到（可能已改名或不在 25.12.2 源里）：$_ak_miss"
fi

# ---- 【2026-11-09】同名多版本去重 ----
# run 包实测会带同一个包的两个版本（daed-2026.06.14-r1 与 -r7 并存，差 25MB；
# luci-app-daed 同时有 1.4-r1 和 26.298 时也是两份）。旧版白占 squashfs，
# 还会让 apk fix 在找「已装版本」时多绕。只留版本最高的那个。
#
# 包名取法：从左起，第一个「以数字开头」的 -段 之前的部分就是包名。
# 不能从右往左截：lxc-auto-6.0.5-r1 的包名自己带连字符，而版本一定是数字开头。
_ak_pn_of() {
    printf '%s' "$1" | awk -F'-' '{pn=""; for(i=1;i<=NF;i++){ if($i ~ /^[0-9]/) break; pn=(pn==""?$i:pn"-"$i) } if(pn!="") print pn}'
}
_ak_dupes=$(ls "$_AK_DIR"/*.apk 2>/dev/null | sed 's#.*/##; s#\.apk$##' | while read -r _ak_bn; do _ak_pn_of "$_ak_bn"; done | sort | uniq -d)
_ak_dedup_n=0
for _ak_dp in $_ak_dupes; do
    _ak_best=$(ls "$_AK_DIR/$_ak_dp"-[0-9]*.apk 2>/dev/null | sed 's#.*/##; s#\.apk$##' | sort -V | tail -1)
    [ -n "$_ak_best" ] || continue
    for _ak_f2 in "$_AK_DIR/$_ak_dp"-[0-9]*.apk; do
        [ -f "$_ak_f2" ] || continue
        _ak_bn2="${_ak_f2##*/}"
        [ "${_ak_bn2%.apk}" = "$_ak_best" ] && continue
        rm -f "$_ak_f2"
        _ak_dedup_n=$((_ak_dedup_n + 1))
        echo "==> [apk-cache] 同名去重：删 ${_ak_bn2}（保留 ${_ak_best}.apk）"
    done
done
echo "==> [apk-cache] 去重共删 $_ak_dedup_n 个旧版本"

_ak_n=$(ls "$_AK_DIR"/*.apk 2>/dev/null | wc -l)
_ak_sz=$(du -sh "$_AK_DIR" 2>/dev/null | cut -f1)
echo "==> [apk-cache] 合计 $_ak_n 个 apk，$_ak_sz，位于 /root/apk-cache/（刷机后为只读的 /rom/root/apk-cache）"

# ---- 【2026-11-02】geo 数据只按 apk 核对，不碰 .dat ----
# 用户定：geoip / geosite 验证 apk，不验证文件 —— 因为这两份数据需要更新，
# 按 .dat 文件判会把人的新数据按回出厂版（详见 pkg-restore-apps.sh 的 _PA_GEO）。
# 这两个包来自官方源（来源 B），所以核对点必须在这里，不能跟 honk 组一起放前面。
_ak_geo_miss=""
for _ak_ng in v2ray-geoip v2ray-geosite; do
    ls "$_AK_DIR"/"$_ak_ng"-[0-9]*.apk >/dev/null 2>&1 || _ak_geo_miss="$_ak_geo_miss $_ak_ng"
done
if [ -n "$_ak_geo_miss" ]; then
    echo "::warning::geo 数据包不在库（探针判缺失时装不回）：$_ak_geo_miss"
else
    echo "==> [apk-cache] geo 数据包齐备（只核 apk，不核 .dat 内容）"
fi

if [ "$_ak_n" -lt 100 ]; then
    echo "::error::apk-cache 只收到 $_ak_n 个包，远低于预期（run 包约 75 + 官方白名单约 49）"
    echo "::error::来源 A 看 packages/*.apk；来源 B 看上面的 missing 列表"
    exit 1
fi

# --- 生成 apk 索引 ---
# apk 的索引是 packages.adb（二进制 ADB 格式），手写不出来，必须用它自己的命令。
# opkg 那套「拼 Packages 纯文本」在这里完全不适用。
# 失败不中断构建：没有索引时仍能按绝对路径单文件装（依赖齐的常态够用）。
if [ -n "$_AK_BIN" ] && [ -n "$_AK_IDX" ]; then
    # 先把工具本身是什么打出来。v.180.136 的日志里缺的就是这一行，才把
    # 「工具不认所有包」误判成「包全是坏的」，一路把 114 个包连同官方源下载的
    # 一起删光，最后产出空包库 + 0 条 manifest。
    echo "==> [apk-cache] apk 版本：$("$_AK_BIN" --version 2>&1 | head -n1)，索引命令：$_AK_IDX"

    _ak_rc2=0
    ( cd "$_AK_DIR" && "$_AK_BIN" --allow-untrusted "$_AK_IDX" -o packages.adb ./*.apk ) \
        >/tmp/apk-index.log 2>&1 || _ak_rc2=1
    if [ "$_ak_rc2" != "0" ]; then
        ( cd "$_AK_DIR" && "$_AK_BIN" --allow-untrusted "$_AK_IDX" -o packages.adb --no-warnings ./*.apk ) >>/tmp/apk-index.log 2>&1 || _ak_rc2=2
    fi

    _ak_total=$(ls "$_AK_DIR"/*.apk 2>/dev/null | wc -l)
    # 一次最多剔 5%（下限 3）：能剔掉的就该是「个别畸形文件」。
    # 需要剔一大片的时候，坏的不是包，是工具 —— 这时候一个都不能删。
    _ak_cap=$((_ak_total / 20))
    [ "$_ak_cap" -lt 3 ] && _ak_cap=3
    [ "$_ak_cap" -gt "$_ak_total" ] && _ak_cap=$_ak_total

    # 单包独立验证：只有「单独建索引也失败」的包才算坏。
    # 批量日志里那句 file format not supported 分不清「这个包坏」和「工具不认所有包」——
    # 工具读不了格式时，会对每一个文件报同一句话。
    _ak_one_ok() {
        _o=$(mktemp 2>/dev/null) || _o="/tmp/ak-one.$$"
        _r=1
        if ( cd "$_AK_DIR" && "$_AK_BIN" --allow-untrusted "$_AK_IDX" -o "$_o" "./$1" ) >/dev/null 2>&1; then
            [ -s "$_o" ] && _r=0
        fi
        rm -f "$_o"
        return $_r
    }

    # 工具可用性探针：随便挑前 3 个包单独建索引，全失败就说明是工具的问题。
    _ak_probe=0
    for _ak_p in $(ls "$_AK_DIR"/*.apk 2>/dev/null | head -n3); do
        if _ak_one_ok "$(basename "$_ak_p")"; then
            _ak_probe=1
            break
        fi
    done
    if [ "$_ak_probe" = "0" ] && [ "$_ak_total" -gt 0 ]; then
        echo "::error::apk 工具连单个包都建不出索引 —— 这是工具/版本问题，不是包的问题，本次一个文件都不剔除"
        tail -3 /tmp/apk-index.log 2>/dev/null
    fi

    # 隔离目录放 /tmp，绝不能放 files/ 下 —— 那是要整体打进固件的。
    _AK_QUAR="${AK_QUAR_OVERRIDE:-/tmp/apk-quarantine}"
    _ak_quar_n=0
    _ak_round=0
    while :; do
        [ "$_ak_rc2" = "0" ] && [ -s "$_AK_DIR/packages.adb" ] && break
        [ "$_ak_round" -ge 5 ] && break
        [ "$_ak_probe" = "1" ] || break
        _ak_badlist=$(grep -oE '\./[^:]+: file format not supported' /tmp/apk-index.log \
            2>/dev/null | sed 's#^\./##; s/: file format not supported$//' | sort -u)
        [ -n "$_ak_badlist" ] || break
        _ak_cand=$(printf '%s\n' "$_ak_badlist" | grep -c .)
        if [ "$_ak_cand" -gt "$_ak_cap" ]; then
            echo "::error::一轮要剔 $_ak_cand 个，超过上限 $_ak_cap（总 $_ak_total）——判定为工具不认这批包，一个都不删"
            break
        fi
        _ak_round=$((_ak_round + 1))
        mkdir -p "$_AK_QUAR" 2>/dev/null
        for _ak_b in $_ak_badlist; do
            [ -f "$_AK_DIR/$_ak_b" ] || continue
            if _ak_one_ok "$_ak_b"; then
                echo "==> [apk-cache] 保留 $_ak_b：批量报错，但单包能建索引（工具问题，不是包坏）"
                continue
            fi
            _ak_h=$(od -An -tx1 -N4 "$_AK_DIR/$_ak_b" 2>/dev/null | tr -d ' \n')
            echo "::error::隔离 $_ak_b：头部=$_ak_h 大小=$(wc -c < "$_AK_DIR/$_ak_b") 字节（单包也建不出索引）"
            # 用 mv 不用 rm：判断可能错，判断错了还得能从隔离区捡回来
            mv -f "$_AK_DIR/$_ak_b" "$_AK_QUAR/$_ak_b" 2>/dev/null && _ak_quar_n=$((_ak_quar_n + 1))
        done
        echo "==> [apk-cache] 隔离 $_ak_quar_n 个后重建索引（第 $_ak_round 轮）"
        _ak_rc2=0
        ( cd "$_AK_DIR" && "$_AK_BIN" --allow-untrusted "$_AK_IDX" -o packages.adb ./*.apk ) \
            >/tmp/apk-index.log 2>&1 || _ak_rc2=1
    done
    # 【v.180.137】索引（packages.adb）就是这个包库的依赖查询表：
    # 没有它，apk 不知道谁依赖谁，`apk add xxx` 只能退化成「按绝对路径单文件装」，
    # LuCI 的软件包页也会显示空白。所以生成出来必须再验一遍，不能只看退出码。
    _ak_idx_ok=0
    if [ "$_ak_rc2" = "0" ] && [ -s "$_AK_DIR/packages.adb" ]; then
        _ak_sz=$(wc -c < "$_AK_DIR/packages.adb")
        _ak_magic=$(od -An -tx1 -N3 "$_AK_DIR/packages.adb" | tr -d ' \n')
        case "$_ak_magic" in
        414442 | 1f8b*) _ak_idx_ok=1 ;;
        *) echo "::error::packages.adb 头部异常（$_ak_magic），这份索引 apk 读不了" ;;
        esac
        # 【v.180.138】上一轮的空库索引是 88 字节的 gzip，头部 1f8b08 —— 魔数检查
        # 放它过去了，日志还打「索引已生成」，等于把空库包装成成功。
        # 包数上百的索引不可能低于 1KB，低于这个数就是空索引。
        if [ "$_ak_idx_ok" = "1" ] && [ "$_ak_sz" -lt 1024 ]; then
            echo "::error::packages.adb 只有 $_ak_sz 字节，是空索引（$(ls "$_AK_DIR"/*.apk 2>/dev/null | wc -l) 个包一个都没进去）"
            _ak_idx_ok=0
        fi
        if [ "$_ak_idx_ok" = "1" ]; then
            echo "==> [apk-cache] 索引已生成：$_ak_sz 字节，头部=$_ak_magic"
            if [ "$_ak_round" -gt 0 ]; then
                echo "==> [apk-cache] 重建 $_ak_round 轮后成功（被剔除的不是合法 apk，真机也装不上）"
            fi
        fi
    fi
    if [ "$_ak_idx_ok" != "1" ]; then
        # 用 error 而不是 warning：这份镜像刷上去以后，包库是「有包、查不了依赖」的
        # 半残状态，用户装 ssr-plus/daed 这类带一串依赖的包会直接失败。
        # 仍然不中断构建 —— 一次 40 分钟的构建不该因为几个 run 包里的畸形文件全废，
        # 但必须让日志红到没人能忽略。
        echo "::error::apk index 失败：本镜像没有可用的依赖查询表（packages.adb），包库只能按绝对路径单文件装"
        echo "==> [apk-cache] 诊断：$(ls "$_AK_DIR"/*.apk 2>/dev/null | wc -l) 个 apk 未被索引"
        tail -6 /tmp/apk-index.log 2>/dev/null
    fi
fi

# ---- 【2026-11-03】给 ImageBuilder 自己的 packages/ 建索引 ----
# 上面那份是 /root/apk-cache（要打进固件的包库），make image 根本不读它。
# make image 读的是 $(pwd)/packages/packages.adb，而这个索引从来没人建过 ——
# 上一轮失败日志里那句
#   WARNING: opening .../ib/packages/packages.adb: No such file or directory
# 就是它。后果不是少装一个包，是本地仓库整个失效：honk 五件套、clashoo、
# 全部 run 包一律 (no such package)。
#
# official/ 里是自建内核配套的 1,199 个 kmod（workflow 灌进来的）。必须一起进索引：
# downloads.immortalwrt.org 的 kmods 目录下只有一个官方 hash
# （6.12.103-1-0413601b1c3f0490e17f340fe09229ea），本 IB 内核是 71cc20e3，
# 在线一条都取不到，内核模块全指望这份本地库。
#
# 放子目录而不是平铺，是为了绕开上面「来源 A」的 packages/*.apk 通配 ——
# 那条会把匹配到的全拷进 /root/apk-cache 打进固件，1,683 个包会凭空多几百 MB。
_IB_PKGS="$(pwd)/packages"
if [ -n "$_AK_BIN" ] && [ -n "$_AK_IDX" ] && [ -d "$_IB_PKGS" ]; then
    _ib_n=$(ls "$_IB_PKGS"/*.apk 2>/dev/null | wc -l)
    _ib_o=$(ls "$_IB_PKGS"/official/*.apk 2>/dev/null | wc -l)
    _ib_k=$(ls "$_IB_PKGS"/official/kmod-*.apk 2>/dev/null | wc -l)
    echo "==> [ib-pkgs] 本地 $(pwd)/packages：run 包 $_ib_n 个，official/ $_ib_o 个（其中 kmod $_ib_k 个）"

    # 【2026-11-03 修】apk 3 不认「索引里的 filename 带子目录前缀」。
    #
    # 上一轮（run 41659002690）的实测证据，非常干净：
    #   根层 ./clashoo-*.apk、./honk-*.apk、./luci-app-*.apk 全部 Installing 成功，零报错；
    #   official/ 里的包则一律
    #     ERROR: kmod-pppoe-6.12.103-r1: package mentioned in index not found
    #   最后 232 errors（206 个 kmod + 9 个 lib + 17 个 target 包），package_install Error 99。
    #   而那些包就在 official/ 里躺着，索引也确实有 194,475 字节 —— 索引里能查到，
    #   取文件时却拼不出路径。
    #
    # 结论：filename 记成 ./official/x.apk 时 apk 取不到文件，它只认 repository
    # 根下的平铺文件名。
    #
    # 修法：给 official/ 里每个包在根层建一个同名符号链接，索引只收根层 ./*.apk。
    # filename 就是纯文件名，与 82 个 run 包完全同构 —— 那条路径已被本轮日志证明可用。
    # 用符号链接不用真拷：省 300MB 磁盘，也不占构建时间。
    #
    # 为什么必须放在这一步而不是更早：上面「来源 A」的 packages/*.apk 通配会把根层
    # apk 全部拷进 /root/apk-cache 打进固件。1,384 个包会凭空多几百 MB。
    # 这里来源 A 早已跑完，建链接它看不见。
    _ib_ln_n=0
    for _f in "$_IB_PKGS"/official/*.apk; do
        [ -f "$_f" ] || continue
        _n="${_f##*/}"
        # 不用 -f 强覆盖：根层若已有同名（run 包），必须保留 run 包那份
        [ -e "$_IB_PKGS/$_n" ] || { ln -s "official/$_n" "$_IB_PKGS/$_n" && _ib_ln_n=$((_ib_ln_n + 1)); }
    done
    echo "==> [ib-pkgs] official/ 已在根层建 $_ib_ln_n 个符号链接"

    _ib_list=""
    for _f in "$_IB_PKGS"/*.apk; do
        [ -e "$_f" ] && _ib_list="$_ib_list ./${_f##*/}"
    done

    rm -f "$_IB_PKGS/packages.adb"
    _ib_rc=0
    ( cd "$_IB_PKGS" && "$_AK_BIN" --allow-untrusted "$_AK_IDX" -o packages.adb $_ib_list ) \
        >/tmp/ib-index.log 2>&1 || _ib_rc=1

    if [ "$_ib_rc" != "0" ] || [ ! -s "$_IB_PKGS/packages.adb" ]; then
        echo "::error::IB 包索引建失败，make image 会找不到任何本地包"
        echo "::error::命令：$_AK_BIN $_AK_IDX -o packages.adb（$_ib_n + $_ib_o 个包）"
        tail -8 /tmp/ib-index.log 2>/dev/null
        exit 1
    fi

    _ib_sz=$(wc -c < "$_IB_PKGS/packages.adb")
    _ib_magic=$(od -An -tx1 -N3 "$_IB_PKGS/packages.adb" | tr -d ' \n')
    echo "==> [ib-pkgs] 索引已生成：$_ib_sz 字节，头部=$_ib_magic"
    if [ "$_ib_sz" -lt 1024 ]; then
        echo "::error::IB 索引只有 $_ib_sz 字节，是空索引（$((_ib_n + _ib_o)) 个包一个都没进去）"
        exit 1
    fi
    _ib_in=$(echo $_ib_list | wc -w)
    echo "==> [ib-pkgs] 索引收录 $_ib_in 个包（run $_ib_n + official $_ib_o）"

    # 【2026-11-09】kmod 完整性断言只对「带自建内核模块库」的线成立。
    # 25.12-honk / 25.12-daed 把自建 pkg 包的 1,204 个 kmod 灌进 official/，
    # 少于 1,100 就是内核模块库不完整，必须炸。
    # 本线（官方源）用官方 ImageBuilder，官方 kmod 在 IB 自带的 packages/ 里，
    # official/ 只是第三方 apk 的下载目录（clashoo / daed / passwall 这些），
    # kmod 数天然是 0 —— 拿 1199 去卡会无条件失败（run #1 就是这么挂的）。
    if [ "$_ib_k" -gt 0 ]; then
        if [ "$_ib_k" -lt 1100 ]; then
            echo "::error::official/ 里只有 $_ib_k 个 kmod（预期 1199），内核模块库不完整"
            exit 1
        fi
        if [ "$_ib_in" -lt 1300 ]; then
            echo "::error::索引只收了 $_ib_in 个包（预期 1380 左右），符号链接或索引生成有问题"
            exit 1
        fi
        echo "==> [ib-pkgs] kmod $_ib_k 个已入索引"
    else
        echo "==> [ib-pkgs] 本线无自建 kmod 库（官方 IB 自带），跳过 kmod 完整性断言"
    fi
else
    echo "::warning::[ib-pkgs] 跳过：apk 工具不可用或 packages/ 不存在"
fi

# --- manifest.txt：pkg-cache-restore.sh --all 的比对基准 ---
# apk 文件名是 <包名>-<版本>.apk，版本一定以数字开头，所以从「-数字」处截断。
# 不能按最后一段截：lxc-auto-6.0.5-r1.apk 的包名自己带连字符。
# 不含容器内组件的原因同 24 版：crowdsec 跑在 LXC 容器里，宿主机没有这个包。
#
# 【v.180.193】两处口径修正，真机 r37978 实测暴露：
#
# ① 字符类必须含 `~`。OpenWrt 用 ~ 标预发布，apk 文件名会出现
#    clashoo-2026.05.27~38cb06d-r1.apk。原字符类 [0-9A-Za-z._-] 不含 ~，
#    截不断，整串文件名被当包名写进 manifest —— 实测 113 个文件里 19 条如此。
#    后果：apk info -e 恒返回不存在，--all 每轮报「缺失」再装失败，
#    真包名（clashoo）反而从未列入，永远补不回来。
#
# ② 必须与 PACKAGES 求交集，不能取包库全量（同 24 版 v.180.145）。
#    --all 的语义是「补齐缺失」，全量口径会把固件本来没选的包
#    （passwall / ssr-plus / bandix 等兜底包）一个个装上去 —— 那不叫恢复，叫扩容。
#    真机实测：全量 111 条里 38 条不该在里面，--all 真装 31 个包、world 多 17 行。
#    正确口径 = PACKAGES（含 CUSTOM_PACKAGES）∩ 包库里有文件的包，实测 73 条。
_ak_all=$(ls "$_AK_DIR"/*.apk 2>/dev/null \
    | sed -E 's#.*/##; s/\.apk$//; s/-[0-9][0-9A-Za-z._~-]*$//' \
    | grep -v '^$' | sort -u)
: > /tmp/ak-want-inst.txt
for _awi in $PACKAGES; do
    case "$_awi" in -*) continue ;; esac
    echo "$_awi"
done | sort -u > /tmp/ak-want-inst.txt
# busybox grep 的 -f 碰到空模式文件不是「一条都不匹配」，而是把整份输入全吐出来
# （24 版夹具实测：want 0 行 -> 全量通过）。那样 PACKAGES 为空时就悄悄退回
# 「包库全量」这个错行为。必须显式挡一道。
if [ -s /tmp/ak-want-inst.txt ]; then
    _ak_man=$(printf '%s\n' "$_ak_all" | grep -Fxf /tmp/ak-want-inst.txt 2>/dev/null)
else
    _ak_man=""
fi
printf '%s\n' "$_ak_man" > "$_AK_DIR/manifest.txt"
_ak_mn=$(printf '%s\n' "$_ak_man" | grep -c .)
_ak_alln=$(printf '%s\n' "$_ak_all" | grep -c .)
echo "==> [apk-cache] manifest.txt：$_ak_mn 个包名（库内 $_ak_alln 个，只列本固件该装的；供 restore --all 比对）"
if [ "$_ak_mn" -lt 1 ]; then
    echo "::error::manifest 为空：PACKAGES 与包库没有交集，restore --all 将无事可做"
    exit 1
fi

ls "$_AK_DIR" | head -n 20

# ---- 唯一一遍：此时 files/ 里的包库已完整，一次合进 rootfs ----
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed (2nd pass: apk-cache)!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."

echo "==> 离线恢复示例（固件刷好后，包被别人卸载时）："
echo "    单个包：apk add --allow-untrusted /rom/root/apk-cache/smartdns-*.apk"
echo "    走源装：apk add --allow-untrusted --no-network --repository file:///rom/root/apk-cache smartdns"
echo "    查库存：ls /rom/root/apk-cache/ | wc -l"
echo "    说明：apk 在 squashfs 只读层（/rom）里，删不掉；装完 /etc/apk/world 记账正确、LuCI 可见"
