# ImmortalWrt-ImageBuilder-25.12

ImmortalWrt 25.12.2 x86-64 构建线：ImageBuilder 用官方 docker 镜像、内核是官方的，apk 以官方源为主；honk 那 5 个 apk 官方源没有，走本仓自己的 `honk-apk` Release（见下）。

固件本体是 ImmortalWrt 25.12.2 x86-64，带 CrowdSec LXC、`rootfs-skel`、网络校验脚本 —— 和另外三条线完全相同的应用层，差别只在**内核和 apk 来源**。

> **honk 默认装、可直接用**：`build25.sh` 从 CloudRunFilesBuilder 的 `honk-apk` Release 取 5 个 apk 塞进 `packages/`，当本地包装进固件，LuCI 里点开即用；`_ak_need_honk` 会在构建期断言这 5 个包都在库，缺一个直接 `exit 1`。
> `daed` 照常随包清单进固件。

## 四条线的差异

| | 25.12 | 25.12-honk | 25.12-daed | 24.10 |
|---|---|---|---|---|
| 用途 | **主线，官方源 + honk** | **纯 honk** | **honk + daed** | 老版本线，维护用 |
| workflow | 28,506 B / 496 行 | 37,645 B / 644 行 | 37,419 B / 641 行 | 27,853 B / 494 行 |
| `runs-on` | ubuntu-22.04 | **ubuntu-24.04** | **ubuntu-24.04** | ubuntu-22.04 |
| ImageBuilder | 官方 docker `x86-64-openwrt-25.12.0/1/2` | **自建 IB**，`v25.12.2-ib-x86-64-r2` | **自建 IB**，同左 | 官方 docker `24.10.0 ~ 24.10.6` |
| apk 来源 | 官方源 | **自建 pkg**，`v25.12.2-pkg-x86-64-r2` | **自建 pkg**，同左 | 官方源 |
| 版本下拉 | 3 档（25.12.0 / .1 / .2） | **1 档（25.12.2），不可切** | **1 档（25.12.2），不可切** | 7 档（24.10.0 ~ .6） |
| 主 config | `imm25.config` 303,823 B / 8,272 行 | 同左 | 同左 | `imm.config` 284,106 B / 7,705 行 |
| `=y` / `=m`（全部） | 999 / 1,227 | 999 / 1,227 | **1,002 / 1,224** | 952 / 1,005 |
| `=y` / `=m`（kmod） | 133 / 1,060 | 133 / 1,060 | **136 / 1,057** | — |
| 构建脚本 | `build25.sh` **68,177 B / 1,234 行** | `build25.sh` **67,172 B / 1,218 行** | `build25.sh` **70,667 B / 1,264 行** | `build24.sh` **50,349 B / 950 行** |
| 自定义包清单 | `apk-custom-packages.sh` **11,874 B** | 11,356 B | 11,356 B | `custom-packages.sh` 11,263 B |
| 内核 | **官方镜像自带** | **自建**，五项 + BTF 写死并断言，hash `26ed6bc1` | **自建**，同左 | **官方镜像自带** |
| honk 组 apk | **默认装**（5 个，从 `honk-apk` Release 取） | **5 个，从 `honk-apk` Release 取** | **5 个** | 无 |
| daed 组 apk | 随包清单进固件 | 无 | **6 个** | 无 |
| `sha256/` 目录 | 有 | 有 | 有 | 无 |
| CrowdSec LXC / rootfs-skel / 网络校验 | 有 | 有 | 有 | 有 |

> **两条 25.12 自建线（honk / daed）的差别**：daed 线多 `daed` / `daed-geoip` / `daed-geosite` / `luci-app-daed` / `luci-i18n-daed-zh-cn` / `kmod-xdp-sockets-diag` 六个包，config 里对应 3 个 `=y`（总 `=y` 从 999 到 1,002）。
>
> **主线（25.12）和两条自建线的本质差别**：内核来源。自建线把 honk 依赖的 `CONFIG_DYNAMIC_FTRACE` 五项 + `CONFIG_DEBUG_INFO_BTF` 写死在自建内核里，构建期逐项断言，实测 honk 挂载成功（`eBPF loaded and attached`、6 个 cgroup 程序、`dae0` 建链）；主线用官方镜像自带内核、未做改造，honk 照常装得进、用得了。


---

## 本线做了什么

官方 ImageBuilder 只负责「把包装进 rootfs 再出镜像」。本仓在它外面套了四层：

1. **CrowdSec LXC 容器** —— `files/etc/crowdsec/lxc-crowdsec.tar.gz` 取自 CloudRunFilesBuilder 的 `lxc-*` Release，用 prepare 脚本与 `rootfs-skel/` 的 sha256 逐字节比对，对不上直接 `exit 1`，不产出「能开机但容器起不来」的固件。
2. **`rootfs-skel/`** —— 容器网络（固定 `10.1.0.10` / `10.1.0.1`）与 guard 脚本的单一来源，`build25.sh` 把它拷进固件成为 `/rom` 只读基准，`crowdsec-guard` 每 60 秒逐字节比对。
3. **`pkg-restore.sh` / `pkg-restore-apps.sh`** —— 刷机后被 `apk del` 或误删的关键文件，从 `/rom` 补回来的恢复链；`_DEPS_PKGS` 里含 `kmod-zram`。
4. **`shell/apk-custom-packages.sh`** —— 应用包清单。honk 组（5 包）与 daed 组都装。

## 内核

honk 是 eBPF 代理，靠 fentry/fexit 挂内核函数，依赖这几项：

| 选项 | 主线（官方镜像自带） | 自建线（honk / daed） |
|---|---|---|
| `CONFIG_DYNAMIC_FTRACE` | 随官方镜像 | **y**，构建期断言 |
| `CONFIG_DYNAMIC_FTRACE_WITH_REGS` | 随官方镜像 | **y**，构建期断言 |
| `CONFIG_DYNAMIC_FTRACE_WITH_DIRECT_CALLS` | 随官方镜像 | **y**，构建期断言 |
| `CONFIG_FUNCTION_TRACER` | 随官方镜像 | **y**，构建期断言 |
| `CONFIG_DEBUG_INFO_BTF` | 随官方镜像 | **y**，构建期断言 |

自建线的价值是**确定**：五项写死在自建内核里，workflow 解开 IB 后逐项 grep，缺一项 `::error::` + `exit 1`。实测（25.12-daed #31，内核 `6.12.103`）：八项全 `y`，`available_filter_functions` 66,989 个，`/sys/kernel/btf/vmlinux` 5,147,981 B，honk-core 启动即 `eBPF loaded and attached`。

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
