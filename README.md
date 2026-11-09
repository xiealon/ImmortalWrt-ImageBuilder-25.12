# ImmortalWrt-ImageBuilder-25.12

ImmortalWrt 25.12.2 x86-64 构建线：ImageBuilder 用官方 docker 镜像、内核是官方的，apk 以官方源为主；daed 那 3 个包官方源没有，走 kenzok8/openwrt-daede 的 Release（见下）。

固件本体是 ImmortalWrt 25.12.2 x86-64，带 CrowdSec LXC、`rootfs-skel`、网络校验脚本 —— 和另外三条线完全相同的应用层，差别只在**内核和 apk 来源**。

> **daed 默认装、可直接用**：`build25.sh` 从 kenzok8/openwrt-daede 的 Release 取 3 个 apk（`daed` 25,992,538 B / `luci-app-daede` 99,180 B / `vmlinux-btf` 1,676,424 B）塞进 `packages/`，当本地包装进固件，LuCI 里点开即用；`_ak_need_daed` 会在构建期断言这 3 个包都在库，缺一个直接 `exit 1`。
> `vmlinux-btf` 的版本必须等于目标内核（25.12 是 `6.12.103`）：构建期读 `include/kernel-version.mk` 比对，不一致直接 `exit 1` —— 装错版本 daed 的 CO-RE eBPF 校验过不去，起不来。

## 四条线的差异

| | 25.12 | 25.12-honk | 25.12-daed | 24.10 |
|---|---|---|---|---|
| 用途 | **主线，官方源 + daed** | **纯 honk** | **honk（+ 预留 daed）** | 老版本线，维护用 |
| workflow | 28,825 B / 500 行 | 37,645 B / 644 行 | 37,419 B / 641 行 | 27,853 B / 494 行 |
| `runs-on` | ubuntu-22.04 | **ubuntu-24.04** | **ubuntu-24.04** | ubuntu-22.04 |
| ImageBuilder | 官方 docker `x86-64-openwrt-25.12.0/1/2` | **自建 IB**，`v25.12.2-ib-x86-64-r2` | **自建 IB**，同左 | 官方 docker `24.10.0 ~ 24.10.6` |
| apk 来源 | 官方源 | **自建 pkg**，`v25.12.2-pkg-x86-64-r2` | **自建 pkg**，同左 | 官方源 |
| 版本下拉 | 3 档（25.12.0 / .1 / .2） | **1 档（25.12.2），不可切** | **1 档（25.12.2），不可切** | 7 档（24.10.0 ~ .6） |
| 主 config | `imm25.config` 303,823 B / 8,272 行 | 同左 | 同左 | `imm.config` 284,106 B / 7,705 行 |
| `=y` / `=m`（全部） | 999 / 1,227 | 999 / 1,227 | **1,002 / 1,224** | 952 / 1,005 |
| `=y` / `=m`（kmod） | 133 / 1,060 | 133 / 1,060 | **136 / 1,057** | — |
| 构建脚本 | `build25.sh` **71,078 B / 1,288 行** | `build25.sh` **67,702 B / 1,226 行** | `build25.sh` **70,544 B / 1,265 行** | `build24.sh` **54,538 B / 1,039 行** |
| 自定义包清单 | `apk-custom-packages.sh` **12,372 B** | 11,410 B | 11,287 B | `custom-packages.sh` 12,231 B |
| 内核 | **官方镜像自带** | **自建**，五项 + BTF 写死并断言，hash `26ed6bc1` | **自建**，同左 | **官方镜像自带** |
| honk 组 apk | 无 | **2 个**（`honk` + `luci-app-honk`，从 `honk-apk` Release 取） | **2 个，同左** | 无 |
| daed 组 apk | **3 个**（`daed` / `luci-app-daede` / `vmlinux-btf`，从 kenzok8 Release 取） | 无 | 无 | **3 个，同左** |
| `sha256/` 目录 | 有 | 有 | 有 | 无 |
| 恢复探针 | `_pa_repair` 缺包走 `--tree`、缺文件走 `--force` | 同左 | 同左 | **同左**（2026-11-09 对齐） |
| CrowdSec LXC / rootfs-skel / 网络校验 | 有 | 有 | 有 | 有 |

> **三条 25.12 线（主线 / honk / daed）现在都只有一套 eBPF 引擎**：主线与 24.10 线装 **daed 三件套**（kenzok8 新版，2026.11.09-r1），两条自建线装 **honk 两件套**。daed 线的 config 仍保留 3 个 `=y`（总 `=y` 1,002），但包清单里跑的是 honk —— 这条线的 daed 组是预留位，要用时把 `_PA_DAED` 那三件加回 `apk-custom-packages.sh` 即可。
>
> **主线和两条自建线的本质差别**：内核来源。自建线把 eBPF 依赖的 `CONFIG_DYNAMIC_FTRACE` 五项 + `CONFIG_DEBUG_INFO_BTF` 写死在自建内核里，构建期逐项断言，实测挂载成功（`eBPF loaded and attached`、6 个 cgroup 程序、`dae0` 建链）；主线用官方镜像自带内核、不编译内核，只能靠 `vmlinux-btf` 包补 BTF，`CONFIG_DYNAMIC_FTRACE` 那几项随官方镜像走、本仓不做断言。daed 与 honk 共用这套前提。


---

## 本线做了什么

官方 ImageBuilder 只负责「把包装进 rootfs 再出镜像」。本仓在它外面套了四层：

1. **CrowdSec LXC 容器** —— `files/etc/crowdsec/lxc-crowdsec.tar.gz` 取自 CloudRunFilesBuilder 的 `lxc-*` Release，用 prepare 脚本与 `rootfs-skel/` 的 sha256 逐字节比对，对不上直接 `exit 1`，不产出「能开机但容器起不来」的固件。
2. **`rootfs-skel/`** —— 容器网络（固定 `10.1.0.10` / `10.1.0.1`）与 guard 脚本的单一来源，`build25.sh` 把它拷进固件成为 `/rom` 只读基准，`crowdsec-guard` 每 60 秒逐字节比对。
3. **`pkg-restore.sh` / `pkg-restore-apps.sh`** —— 刷机后被 `apk del` 或误删的关键文件，从 `/rom` 补回来的恢复链；`_DEPS_PKGS` 里含 `kmod-zram`。
4. **`shell/apk-custom-packages.sh`** —— 应用包清单。eBPF 代理只用一套：本线装 **daed 三件套**（`daed` / `luci-app-daede` / `vmlinux-btf`），honk 组已移除；要换回 honk 就改这一行 + `build25.sh` 的取包段（两条自建线里有现成写法）。

## 内核

honk / daed 都是 eBPF 代理，靠 fentry/fexit 挂内核函数，依赖这几项：

| 选项 | 主线（官方镜像自带） | 自建线（honk / daed） |
|---|---|---|
| `CONFIG_DYNAMIC_FTRACE` | 随官方镜像 | **y**，构建期断言 |
| `CONFIG_DYNAMIC_FTRACE_WITH_REGS` | 随官方镜像 | **y**，构建期断言 |
| `CONFIG_DYNAMIC_FTRACE_WITH_DIRECT_CALLS` | 随官方镜像 | **y**，构建期断言 |
| `CONFIG_FUNCTION_TRACER` | 随官方镜像 | **y**，构建期断言 |
| `CONFIG_DEBUG_INFO_BTF` | 随官方镜像 | **y**，构建期断言 |

自建线的价值是**确定**：五项写死在自建内核里，workflow 解开 IB 后逐项 grep，缺一项 `::error::` + `exit 1`。实测（25.12-daed #31，内核 `6.12.103`）：八项全 `y`，`available_filter_functions` 66,989 个，`/sys/kernel/btf/vmlinux` 5,147,981 B，honk-core 启动即 `eBPF loaded and attached`。

**主线不编译内核，只能补 BTF 包**：`vmlinux-btf-6.12.103-r1-x86_64.apk`（1,676,424 B）随 daed 一起进固件，提供的 BTF 与官方内核同版，daed 启动时读的就是它；`CONFIG_DYNAMIC_FTRACE` 那几项随官方镜像走，本仓**不做断言**。所以主线的 eBPF 挂载成功率取决于上游镜像，不像自建线那样有构建期保证 —— 这也是保留两条自建线的原因。

写进 `imm25.config` 改不动内核 —— ImageBuilder 不编译内核，那几行只是配置回显。内核选项在自建 IB 包里，见 [`25.12-honk`](https://github.com/xiealon/ImmortalWrt-ImageBuilder-25.12-honk)。

## 怎么构建

1. Actions → **Build 25.12.x x86-64 (official source)** → Run workflow
2. `Luci Version` 选 `25.12.2`（或 `.1` / `.0`，决定官方镜像 tag）
3. 填 `Router IP`（多网口才生效），其余留空用默认
4. 产物在 Release `Autobuild-x86-64` 里，文件名带档位后缀（`disk16G-rootfs10G` 这种）

## 产物

| 项 | 值 |
|---|---|
| 分区档位 | 8G / 16G / 32G / 64G / 128G / 256G 盘 |
| rootfs 对应 | 4G / 10G / 22G / 50G / 108G / 224G |
| 默认 | `16G盘→rootfs 10G` |
| 网络 | 编译期写入 `custom_router_*.txt`，开机由 `99-custom.sh` 落成 UCI |

## 许可

- 本仓库代码：**GPL-3.0**（见 [LICENSE](https://github.com/xiealon/ImmortalWrt-ImageBuilder-25.12/blob/master/LICENSE)）
- 构建产出的固件：继承 ImmortalWrt 的 **GPL-2.0**（`COPYING` 写的是 `GPL-2.0-only`）

GPL-2.0 与 GPL-3.0 不兼容，两者边界必须分清：**脚本是 3.0，固件是 2.0**。脚本以独立进程方式调用 ImageBuilder，不与内核链接，属于聚合而非衍生，边界清晰。

上游 ImageBuilder 工作流出自 [wukongdaily/AutoBuildImmortalWrt](https://github.com/wukongdaily/AutoBuildImmortalWrt)，其说明文字版权归原作者所有，本仓库不再复制原文。
