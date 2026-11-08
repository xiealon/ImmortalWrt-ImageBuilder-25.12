# ImmortalWrt-ImageBuilder-25.12

**全官方源**的 ImmortalWrt 25.12.2 x86-64 构建线：ImageBuilder 用官方 docker 镜像，apk 全部走官方源，不掺任何自建产物。

固件本体是 ImmortalWrt 25.12.2 x86-64，带 CrowdSec LXC、`rootfs-skel`、网络校验脚本 —— 和另外三条线完全相同的应用层，差别只在**内核和 apk 来源**。

> **honk 在这条线上装得上、起不来。**
> **装得上**：`shell/apk-custom-packages.sh` 里那行注释放开就行 —— 构建会把 `honk-apk` Release 的 5 个 apk 塞进 `packages/`，当本地包正常装进固件，LuCI 里也能点开。
> **起不来**：官方镜像的内核没开 `CONFIG_DYNAMIC_FTRACE*`，而 honk 是 eBPF 代理，靠 fentry/fexit 挂内核函数。要能跑的 honk 请用 [`25.12-honk`](https://github.com/xiealon/ImmortalWrt-ImageBuilder-25.12-honk)。
> `daed` 不受影响，随包清单正常进固件。

## 四条线的差异

| | 25.12 | 25.12-honk | 25.12-daed | 24.10 |
|---|---|---|---|---|
| 用途 | **主线，全官方源** | **纯 honk** | **honk + daed** | 老版本线，维护用 |
| workflow | 28,506 B / 496 行 | 37,645 B / 644 行 | 37,419 B / 641 行 | 27,853 B / 494 行 |
| `runs-on` | ubuntu-22.04 | **ubuntu-24.04** | **ubuntu-24.04** | ubuntu-22.04 |
| ImageBuilder | 官方 docker `x86-64-openwrt-25.12.0/1/2` | **自建 IB**，`v25.12.2-ib-x86-64-r2` | **自建 IB**，同左 | 官方 docker `24.10.0 ~ 24.10.6` |
| apk 来源 | 官方源 | **自建 pkg**，`v25.12.2-pkg-x86-64-r2` | **自建 pkg**，同左 | 官方源 |
| 版本下拉 | 3 档（25.12.0 / .1 / .2） | **1 档（25.12.2），不可切** | **1 档（25.12.2），不可切** | 7 档（24.10.0 ~ .6） |
| 主 config | `imm25.config` 303,823 B / 8,272 行 | 同左 | 同左 | `imm.config` 284,106 B / 7,705 行 |
| `=y` / `=m`（全部） | 999 / 1,227 | 999 / 1,227 | **1,002 / 1,224** | 952 / 1,005 |
| `=y` / `=m`（kmod） | 133 / 1,060 | 133 / 1,060 | **136 / 1,057** | — |
| 构建脚本 | `build25.sh` **68,177 B / 1,234 行** | `build25.sh` **67,172 B / 1,218 行** | `build25.sh` **70,667 B / 1,264 行** | `build24.sh` **50,349 B / 950 行** |
| 自定义包清单 | `apk-custom-packages.sh` **12,089 B** | 11,356 B | 11,356 B | `custom-packages.sh` 11,263 B |
| 内核 | **官方**，无 `DYNAMIC_FTRACE` | **自建**，ftrace 五项 + BTF，hash `26ed6bc1` | **自建**，同左 | 官方 |
| honk 组 apk | **默认不装**（放开那行注释即装进固件：能装、能进 LuCI，起不来） | **5 个，从 `honk-apk` Release 取** | **5 个** | 无 |
| daed 组 apk | 随包清单进固件 | 无 | **6 个** | 无 |
| `sha256/` 目录 | 有 | 有 | 有 | 无 |
| CrowdSec LXC / rootfs-skel / 网络校验 | 有 | 有 | 有 | 有 |

> **两条 25.12 自建线（honk / daed）的差别**：daed 线多 `daed` / `daed-geoip` / `daed-geosite` / `luci-app-daed` / `luci-i18n-daed-zh-cn` / `kmod-xdp-sockets-diag` 六个包，config 里对应 3 个 `=y`（总 `=y` 从 999 到 1,002）。
>
> **主线（25.12）和两条自建线的本质差别**：内核。自建内核开了 `CONFIG_DYNAMIC_FTRACE` 五项 + `CONFIG_DEBUG_INFO_BTF`，honk 才能把 eBPF 程序挂到内核函数上；官方镜像的内核没开这些，honk 装得上、LuCI 里能点，就是起不来。


---

## 本线做了什么

官方 ImageBuilder 只负责「把包装进 rootfs 再出镜像」。本仓在它外面套了四层：

1. **CrowdSec LXC 容器** —— `files/etc/crowdsec/lxc-crowdsec.tar.gz` 取自 CloudRunFilesBuilder 的 `lxc-*` Release，用 prepare 脚本与 `rootfs-skel/` 的 sha256 逐字节比对，对不上直接 `exit 1`，不产出「能开机但容器起不来」的固件。
2. **`rootfs-skel/`** —— 容器网络（固定 `10.1.0.10` / `10.1.0.1`）与 guard 脚本的单一来源，`build25.sh` 把它拷进固件成为 `/rom` 只读基准，`crowdsec-guard` 每 60 秒逐字节比对。
3. **`pkg-restore.sh` / `pkg-restore-apps.sh`** —— 刷机后被 `apk del` 或误删的关键文件，从 `/rom` 补回来的恢复链；`_DEPS_PKGS` 里含 `kmod-zram`。
4. **`shell/apk-custom-packages.sh`** —— 应用包清单。默认**不含** honk，daed 组照常装。

## 内核

官方 `immortalwrt/imagebuilder:x86-64-openwrt-25.12.x` 的内核缺这几项：

| 选项 | 官方镜像 | 自建（honk / daed 线） |
|---|---|---|
| `CONFIG_DYNAMIC_FTRACE` | 不设 | **y** |
| `CONFIG_DYNAMIC_FTRACE_WITH_REGS` | 不设 | **y** |
| `CONFIG_DYNAMIC_FTRACE_WITH_DIRECT_CALLS` | 不设 | **y** |
| `CONFIG_FUNCTION_TRACER` | 不设 | **y** |
| `CONFIG_DEBUG_INFO_BTF` | 视版本 | **y** |

这五项是 honk 的命门。写进 `imm25.config` 也改不动 —— ImageBuilder 不编译内核，那几行只是配置回显。真正的内核选项在自建 IB 包里，见 [`25.12-honk`](https://github.com/xiealon/ImmortalWrt-ImageBuilder-25.12-honk)。

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
