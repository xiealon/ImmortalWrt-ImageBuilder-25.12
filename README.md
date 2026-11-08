# ImmortalWrt-ImageBuilder-25.12

给 **honk** 用的固件构建线：自建内核（带 ftrace + BTF）+ 自建 apk 全集，只有这一条线能把 honk 跑起来。

本仓是**纯 honk** 版，不含 daed。带 daed 的版本见 [`ImmortalWrt-ImageBuilder-25.12-daed`](https://github.com/xiealon/ImmortalWrt-ImageBuilder-25.12-daed)。

固件本体仍是 ImmortalWrt 25.12.2 x86-64，和其它线一样的 CrowdSec LXC、一样的 rootfs-skel、一样的网络校验脚本。差别只在**内核和 apk 来源**。

## 三条线的差异

| | 25.12 | 24.10 | 25.12-daed |
|---|---|---|---|
| 用途 | **纯 honk** | 老版本线，维护用 | **honk + daed** |
| workflow | 37,645 B / 644 行 | 27,853 B / 494 行 | 37,419 B / 641 行 |
| `runs-on` | **ubuntu-24.04** | ubuntu-22.04 | **ubuntu-24.04** |
| ImageBuilder | **自建 IB 包**，`v25.12.2-ib-x86-64-r2` | 官方 docker，tag 跟下拉（24.10.0 ~ 24.10.6） | **自建 IB 包**，`v25.12.2-ib-x86-64-r2` |
| apk 来源 | **自建 pkg 包**，`v25.12.2-pkg-x86-64-r2` | 官方源 | **自建 pkg 包**，`v25.12.2-pkg-x86-64-r2` |
| 版本下拉 | **1 档（25.12.2），不可切** | 7 档（24.10.0 ~ 24.10.6） | **1 档（25.12.2），不可切** |
| 主 config | `imm25.config` 303,823 B / 8,272 行 | `imm.config` 284,106 B / 7,705 行 | `imm25.config` 303,823 B / 8,272 行 |
| `=y` / `=m`（全部） | **999 / 1,227** | 952 / 1,005 | **1,002 / 1,224** |
| `=y` / `=m`（kmod） | **133 / 1,060** | — | **136 / 1,057** |
| 构建脚本 | `build25.sh` 63,180 B / 1,146 行 | `build24.sh` 47,780 B / 906 行 | `build25.sh` 66,675 B / 1,192 行 |
| 自定义包清单 | `apk-custom-packages.sh` 11,356 B | `custom-packages.sh` 11,263 B | `apk-custom-packages.sh` 11,356 B |
| 内核 | **自建，ftrace 五项 + BTF，hash `26ed6bc1`** | 官方 | **同 25.12** |
| honk 组 apk | **5 个，从 `honk-apk` Release 取** | 无 | **5 个** |
| daed 组 apk | 无 | 无 | **6 个** |
| `sha256/` 目录 | **有** | 无 | **有** |
| CrowdSec LXC / rootfs-skel / 网络校验 | 有 | 有 | 有 |
| 文档 | README + CROWDSEC（533 行）+ CHANGELOG（2,259 行） | 同左 | 同左 |

> **25.12 已经是自建源**，不再是官方 docker + 官方源：内核是自建的（ftrace 五项 + BTF），IB 包和 1,688 个 apk 都来自 [immortalwrt-artifacts](https://github.com/xiealon/immortalwrt-artifacts)，与 25.12-daed 同源，只有 daed 组和 config 极性不同。
>
> **两条 25.12 线的 config 只差 3 行**：`kmod-sched-bpf`、`kmod-xdp-sockets-diag`、`kmod-zram` 在 daed 线是 `=y`、在 25.12 线是 `=m`。其余 kmod 极性完全一致，所以 `=y` / `=m` 只相差这 3 项。

**完整的 CrowdSec LXC 运行期逻辑、网络与防火墙校验、`rootfs-skel` 契约 → [CROWDSEC.md](https://github.com/xiealon/ImmortalWrt-ImageBuilder-25.12/blob/master/CROWDSEC.md)；v.103 起的改动记录 → [CHANGELOG.md](https://github.com/xiealon/ImmortalWrt-ImageBuilder-25.12/blob/master/CHANGELOG.md)**

---

## honk 是什么

honk 是 dae 系的一个 OpenWrt 集成，基于 eBPF 的透明代理。上游手册在 [daeuniverse.org](https://daeuniverse.org/)，当前上游版本 v2.1.1，本仓库装的 honk 是 **0.1.0_beta4-r3**。

它和普通代理软件的根本区别在这里：

- 不走 iptables/nftables 转发，而是**把程序挂到内核函数上**（fentry/fexit），在 syscall 层决定流量去向
- 因此内核必须开 **ftrace 五项 + BTF**，缺一个 honk 直接起不来
- 内核版本要求 **≥ 5.17**，本仓库是 **6.12.103**

官方 ImageBuilder 的内核不带这套配置，也没法在打好包的 IB 里补 —— 内核选项属于编译期，改一次 hash 就变一次。所以只能自建内核，再拿自建内核产出的 IB 包来打固件。这就是本仓库存在的全部理由。

---

## 构建输入

两压缩包 + 一套 apk，全部来自自建流水线，不放本仓库。

| 包 | 大小 | sha256 | 来源 |
|---|---|---|---|
| `immortalwrt-imagebuilder-25.12.2-x86-64.Linux-x86_64.tar.zst` | **63,177,329** | `73abe42d…b312e8` | [v25.12.2-ib-x86-64-r2](https://github.com/xiealon/immortalwrt-artifacts/releases/tag/v25.12.2-ib-x86-64-r2) |
| `packages-x86_64-25.12.2.tar.zst` | **331,366,482** | `7af7a3a9…78c1a4` | [v25.12.2-pkg-x86-64-r2](https://github.com/xiealon/immortalwrt-artifacts/releases/tag/v25.12.2-pkg-x86-64-r2) |

pkg 包里是 **1,688 个 apk**（其中 **1,204 个 kmod** + kernel 本尊 + 其余用户态包），与 IB 包**同一次编译**产出，内核 hash 天生一致。构建时解到 `$IB/packages/official/`，不触发「打进固件」的那条通配。

honk 那 5 个 apk 不在 pkg 包里，构建时由 `build25.sh` 从 [CloudRunFilesBuilder 的 `honk-apk`](https://github.com/xiealon/CloudRunFilesBuilder/releases/tag/honk-apk) 逐个下载：

| 文件 | 字节 |
|---|---|
| `honk-0.1.0_beta4-r3.apk` | 16,186,820 |
| `luci-lib-daeuniverse-26.303.64947.503cdb1.apk` | 10,646 |
| `luci-app-honk-26.303.60580.1046d3c.apk` | 2,734 |
| `luci-i18n-daeuniverse-zh-cn-26.303.60580.1046d3c.apk` | 2,319 |
| `vmlinux-btf-builtin-1-r1.apk` | 972 |

> `vmlinux-btf-builtin` 只有 972 B，是个**哨兵包**：它本身不提供 BTF，只检查 `/sys/kernel/btf/vmlinux` 存在。内核 `CONFIG_DEBUG_INFO_BTF=y` 时这个文件由内核自己导出，所以它一定会过。

---

## 内核要求

两组要求分别来自上游手册和本仓库的硬校验，**当前内核 21/21 全部满足**。

### dae 上游要求（[requirements](https://daeuniverse.org/dae/start/requirements)）

| 选项 | 要求 | 本内核 |
|---|---|---|
| `CONFIG_BPF` | y | **y** |
| `CONFIG_BPF_SYSCALL` | y | **y** |
| `CONFIG_BPF_JIT` | y | **y** |
| `CONFIG_CGROUPS` | y | **y** |
| `CONFIG_KPROBES` | y | **y** |
| `CONFIG_NET_INGRESS` | y | **y** |
| `CONFIG_NET_EGRESS` | y | **y** |
| `CONFIG_NET_SCH_INGRESS` | m | **m** |
| `CONFIG_NET_CLS_BPF` | m | **m** |
| `CONFIG_NET_CLS_ACT` | y | **y** |
| `CONFIG_BPF_STREAM_PARSER` | y | **y** |
| `CONFIG_DEBUG_INFO` | y | **y** |
| `CONFIG_DEBUG_INFO_REDUCED` | 不设 | **不设** |
| `CONFIG_DEBUG_INFO_BTF` | y | **y** |
| `CONFIG_KPROBE_EVENTS` | y | **y** |
| `CONFIG_BPF_EVENTS` | y | **y** |

### 本仓库 workflow 的硬校验

`build-x86-64-25.12.x.yml` 解压 IB 后会 grep 五项，缺一项就 `::error::` + `exit 1`，**不产出一份「能开机但 honk 起不来」的固件**：

| 选项 | 本内核 |
|---|---|
| `CONFIG_DYNAMIC_FTRACE` | **y** |
| `CONFIG_DYNAMIC_FTRACE_WITH_REGS` | **y** |
| `CONFIG_DYNAMIC_FTRACE_WITH_DIRECT_CALLS` | **y** |
| `CONFIG_FUNCTION_TRACER` | **y** |
| `CONFIG_DEBUG_INFO_BTF` | **y** |

> 这五项是 honk 的命门 —— 它靠 fentry/fexit 挂内核函数，没有动态 ftrace 就无从挂钩。

---

## 固件里固定的内核模块

`x86-64/imm25.config` 里 16 个模块写死为 `=y`（`CONFIG_PACKAGE_*=y` 表示**装进固件**，不是编进 vmlinux）：

| 模块 | 行号 |
|---|---|
| `kmod-br-netfilter` | L2781 |
| `kmod-dummy` | L2920 |
| `kmod-inet-diag` | L3055 |
| `kmod-veth` | L3148 |
| `kmod-tun` | L3144 |
| `kmod-nft-tproxy` | L2884 |
| `kmod-nft-socket` | L2883 |
| `kmod-ikconfig` | L3173 |
| `kmod-acpi-call` | L3159 |
| `kmod-hwmon-pwmfan` | L2581 |
| `kmod-gpio-pwm` | L3170 |
| `kmod-crypto-chacha20poly1305` | L2430 |
| `kmod-i2c-hid-acpi` | L2612 |
| `kmod-intel-lpss-acpi` | L3175 |
| `kmod-thermal` | L3227 |
| `kmod-acpi-video` | L3428 |

上表是**显式指定**的 16 个；两条 25.12 线 config 里 `=y` 的 kmod 分别是 **133 个**（25.12）和 **1,188 个**（25.12-daed）。

`shell/apk-custom-packages.sh` 里同时列出包名作为兜底，两处都有才不会漏。

---

## 怎么构建

1. 打开 Actions → **Build 25.12.x x86-64** → Run workflow
2. 填 `Router IP`（多网口才生效），其余留空即用默认
3. `Luci Version` 下拉框只有 25.12.2 一项，**这是故意的**：内核来自自建 IB 包，切换版本没有意义，留一个不可选项比删掉更不容易误解

产物在 run 的 artifact 与 Release 里，文件名带档位后缀。

---

## 改动这个仓库前要知道的三件事

1. **内核 hash 是硬约束**。IB 包内是 `kernel-6.12.103~26ed6bc1347f7e9e86ff98fe27513539-r1.apk`，改任何内核 Kconfig 选项 hash 立刻变，IB 包和 1,688 个 apk 同时作废。想加内核模块请走 `imm25.config`（包级），不要动内核 `.config`。
2. **改 `imm25.config` 不影响 hash**。它只是告诉 `make image` 装哪些包。
3. **honk 组 apk 版本随上游 Release 走**，不在本仓库固定。版本漂了要重新看 `build25.sh` 里那段下载逻辑。

---

## 许可

- 本仓库代码：**GPL-3.0**（见 [LICENSE](LICENSE)）
- 构建产出的固件：继承 ImmortalWrt 的 **GPL-2.0**

GPL-2.0 与 GPL-3.0 不兼容，两者边界必须分清：**脚本是 3.0，固件是 2.0**。

上游 ImageBuilder 工作流出自 [wukongdaily/AutoBuildImmortalWrt](https://github.com/wukongdaily/AutoBuildImmortalWrt)，其说明文字版权归原作者所有，本仓库不再复制原文。
