# CrowdSec LXC：流程与各项保护

编译期在 GitHub Actions 把固件编出来，运行期固件开机后自己把 CrowdSec 容器拉起来，两段之间唯一的交接物是 `img.gz`。

三条线（25.12 / 24.10 / 25.12-honk）的这部分逻辑完全相同，代码分别在各自的 `x86-64/build24.sh` / `x86-64/build25.sh` 与 `rootfs-skel/`、`shell/` 里。

v.103 起的改动记录见 [CHANGELOG.md](CHANGELOG.md)，仓库导航见 [README.md](README.md)。

---

# IP网关DNS为固定，请提前规划。

# 整体流程

这个仓库分两段：**编译期**在 GitHub Actions 上把固件编出来，**运行期**固件开机后自己把 CrowdSec 容器拉起来。两段之间唯一的交接物是 `img.gz`。

## 一、编译期（GitHub Actions）

全部手动触发，没有任何 `on: push`。本仓库只有一个构建入口 `build-x86-64-25.12.x.yml`。24.10 已是独立仓库 `ImmortalWrt-ImageBuilder-24.10`，两边代码同源，区别只在包管理器（opkg / apk）与 LuCI 版本。

**① 手动 Run workflow**
在 Actions 页面选一个入口点 Run，填 10 项输入。
Docker、LXC、CrowdSec 容器都已锁定为内置（纯 X86 平台，没有「要不要 docker」也没有「要不要 crowdsec」的开关）。关键几项：

| 输入 | 说明 |
|---|---|
| `Router IP` | 旁路由管理地址，默认 `10.0.0.201` |
| `Profile` | 软件包空间，选 2G/3G/4G/10G（1G 已在选项中移除：装不下容器 rootfs） |
| `Container IP` / `Bridge IP` | 容器固定 IP 与 lxcbr0 网桥 IP，必须同 /24 |

**② 参数校验**
`Validate Crowdsec Build Parameters` 这一步很关键，它把不合法的输入挡在编译之前：

- `Profile` 小于 2G → **直接构建失败**（v.107.7 起不再「自动跳过容器构建」。跳过等于变相的不内置，会造出一个「填了 Router IP 却不生效」的固件）
- 没填 `Crowdsec Enroll Key` → 只跳过控制台账号绑定，本地 bouncer/LAPI 照常工作
- 容器 IP / 网桥 IP 做四段合法性校验、同 /24 校验、不能相同校验，任一不过就回退默认 `10.1.0.10` / `10.1.0.1` 并打 error

**③ 写入 custom/*.txt**
把路由 IP、掩码、网关、DNS、容器 IP、网桥 IP 逐个落成 `/workspace/custom/*.txt`。这些文件随后被挂载进镜像的 `/etc/config/`，固件里就有了可读的配置源。

**④ 准备 CrowdSec rootfs**
`prepare-crowdsec-rootfs.sh` 拉 Ubuntu 22.04 base rootfs，在 chroot 里 `apt-get install crowdsec`，清理 apt 缓存后打成 `files/etc/crowdsec/lxc-ubuntu.tar.gz`。这个 tar 就是固件里预置的容器镜像——**不需要联网拉镜像**。

**⑤ Docker 里跑 build.sh**
用 `immortalwrt/imagebuilder:x86-64-openwrt-<luci版本>` 官方镜像，把 `bin` / `files` / `custom` / `shell` / `.config` / `build25.sh` 全部挂载进去，跑 `build.sh`。脚本拉 feeds、装软件包、必要时下 clash/mihomo 内核，最后 `make image` 出 `*squashfs-combined-efi.img.gz`。

**⑥ 发布 Release**
产物传到 tag `Autobuild-x86-64` 的 Release，同时作为 artifact 留档。Release 说明里写后台地址/账号密码。

## 二、运行期（路由器开机）

固件刷进去开机后，`/etc/rc.local` 是唯一入口，它自己只做两件事：前置检查、抢锁。真正干活的是 `crowdsec-lxc-bootstrap.sh`。

**⑦ rc.local 前置检查**
脚本不在位、或者既没有镜像也没有 rootfs，直接跳过本轮引导——不在半残状态上瞎折腾。

**⑧ 抢引导锁**
`mkdir` 原子锁。残留锁（mtime 超 30 分钟，被 kill -9 或断电留下）会被强夺后继续，避免"一次异常永久不再引导"。锁在，说明上一次还在跑，本次跳过。

**⑨ bootstrap 九组链式置位**
按 `NETBASE → INSTALL → PREP → CAPIBLOCK → BOOT → LOGCONF → LAPI → BOUNCERVERIFY → ENROLL`（`GROUP_SEQ` 定序）执行，每组开跑前校验所有前置组已置位。组内每个节点都是**先验证现场、达标就零写入、不达标才构建**。构建失败分两种处置：结构性节点（`_structurally_broken`）失败直接整机重装，软节点（`bouncer_verify` / `enroll`）失败只记 failed 继续跑。复核统一放在 flush 之后与开机后，**不在 build 后即时复核**。

**⑩ NETBASE（13 节点）**
网络基线 11 项：`br_lan_ports` `lan_static` `dhcp_ignore` `bridge` `lxc_zone` `fwd_rules` `lan_input` `snat` `ip_forward` `svc_bind` `docker_fw`；`pkg_base` / `lxc_auto` 负责缺包时从 `/rom` 本地装回（不联网）—— `pkg_base` 另带 `luci-app-smartdns` 界面：只在这台固件编过它、运行时又缺时才补，补不上不影响引导。（v.180.157 起 smartdns 整块——配置 / 服务 / 验证——已移出本脚本，交给 `pkg-restore-smartdns.sh` 与探针。）

**⑪ INSTALL / PREP / CAPIBLOCK / BOOT**
`INSTALL` 三节点：迁移校验镜像、解压 rootfs、写容器 config；`PREP` 四节点：容器网络、cgroup 挂载、开机链、resolv.conf；`CAPIBLOCK` 在开机前停用 `online_client`（`config.yaml` 只在 crowdsec 启动时读一次，启动后再改等于没改）；`BOOT` 依赖 `snat`，没 SNAT 不启动，全程唯一一次开机。

**⑫ LOGCONF / LAPI / BOUNCERVERIFY / ENROLL**
宿主机日志推送 + 容器内采集解析（用标记日志验入库）、从容器内 `cscli` 取 LAPI 填入路由器 bouncer、验证 bouncer 真在拉（看 `last_pull` 新鲜度）才放开 CAPI、最后 `ENROLL` 做 Console 账号绑定 —— **全程唯一联网点**。

> **为什么 CAPIBLOCK 一定要在 BOOT 之前**：`config.yaml` / `acquis` / `resolv.conf` / 网络文件
> 都是 crowdsec 与 systemd 启动时读一次。启动后再改，不重启就不生效——流程里所有
> 「改静态配置」的步骤必须排在启动之前。

> **组间只保留真实存在的硬顺序**：`NETBASE → INSTALL → PREP → CAPIBLOCK → BOOT → LOGCONF/LAPI → BOUNCERVERIFY → ENROLL`。
> `LOGCONF` 与 `LAPI` 之间没有依赖，谁先谁后都行；把它们串成一条直线只是为了日志好读。

### 核心脚本防篡改（`crowdsec-guard.sh`）

产物是 `squashfs-combined-efi`，所以系统里有一个内核级只读的 `/rom`。核心脚本的开机原件
永远在 `/rom` 下——改不掉、删不掉；运行副本与它不一致（内容被改 / 被删 / 丢了执行位）就
从 `/rom` 拷回复原。保护范围：`crowdsec-lxc-bootstrap.sh`、`crowdsec-lxc-probe.sh`、
`crowdsec-guard.sh`、`rc.local`、`init.d/crowdsec-lxc-probe`。

三个调用点互为看门狗，任意一个还活着就能把另外几个补回来：

| 调用点 | 时机 | 为什么必须在这个位置 |
|---|---|---|
| `rc.local` | 开机、抢锁之前 | 要早于前置检查——bootstrap 被删时前置检查会直接 exit 0，那就再没机会复原 |
| `crowdsec-lxc-probe` | 每轮（60 秒） | 要早于 `probe_tick`——bootstrap 持锁时 tick 走 `lock-busy` 早退，完整性检查不能跟着停 |
| `init.d/crowdsec-lxc-probe` | 起服务前 | 服务被重启时兜一次 |

**为什么不用 `chattr +i`**：`/usr/sbin` 在 overlayfs 的合并视图里。还没 copy-up 时，chattr
的 ioctl 会打到下层 squashfs，直接 `Operation not supported`；先 copy-up 再设也能成功，
但 flag 只落在 upper 的 ext4 上，刷机重建 overlay 就丢，而且挡不住删 `/overlay/upper/...`
把上层实体整个拿掉。squashfs 的 `/rom` 反倒是内核级只读（`mount -o remount,rw` 直接失败），
拿它当基准才站得住。

**刻意不保护**：`/etc/config/*.txt`（action 注入的容器 IP / 网桥 IP / enroll key）和运行期
uci 配置。bootstrap 的 `_drop_enroll_key` 在绑定成功后会删 enroll key，纳进保护表只会被
反复"复原"回去。被改过的原文会在同目录留一份 `.user-<时间戳>` 备份，只留最近一份，不静默吞掉。

**占用有上限**：日志正常一条不写（只在复原时写一行），超过 64KB 只保留最后 200 行，
封顶后长期不再增长；`.user-*` 备份只留最近一份。所以被反复篡改也不会撑满 `/overlay`。

## 三、旁挂

**probe 守护**（`crowdsec-lxc-probe.sh`，独立 init.d 服务）
每 60 秒看容器 `last_pull`，连续 3 轮停滞就触发一次 bootstrap 修复，触发后冷却 600 秒。它和开机引导共用同一把锁，保证同一时刻只有一个 bootstrap 在跑。

**clean-workflow**
手动清 N 天前的 Actions 运行记录，防止积累太多。

---

## LAPI 组细部：取 LAPI → 填入 bouncer → 重启宿主机服务

填完 `api_key` 之后**必须重启宿主机 bouncer**（`service crowdsec-firewall-bouncer restart`），
否则进程仍持着旧 key，紧接着的 `BOUNCERVERIFY` 会白等 60 秒再判 hard。

同时**刻意不重启容器内 crowdsec**：它读的是容器里的 `config.yaml`，从不读宿主机的
`/etc/config/crowdsec`；重启它只会让 `last_pull` 断档，反而害得「60 秒新鲜度」判失败。
容器内 crowdsec 该重启的时机是改 `config.yaml` 之后 —— 那件事由 `capi_release` 自己负责。

## 旁路由版关键语义（本仓锁定，无模式开关）

- **所有物理网口**桥进 `br-lan`（无首口=WAN 划分）
- **`network.wan` / `network.wan6` 段整段删除**——不是 `disabled=1`
- `lan.ignore=1`：不跑 DHCP 服务，地址由上游分配
- 只删 WAN 段，不写 `wan.proto`、不设 `wan.device`、不碰 `lan` / `br_lan`

> **为什么必须删而不是 disable**：新版 fw4（nft）后台不认 `disabled` 标志。
> `network.wan` 段只要还在，fw4 生成规则时仍会按 `proto`/`device` 起接口、挂 WAN zone，
> 旁路由实际还是在当路由器用。判据必须是「段不存在」。
>
> 删掉后你随时可在 LuCI 重建 WAN 接口——脚本不阻止，只是下次引导会再删一次，
> 这叫旁路由语义闭环，不是跟你抢配置。

## 【验证 + 修改】：网络与防火墙配置由脚本自己校准

v.95 起，原先那 9 个「只验不写」的节点全部改为**验证 + 修改**；v.97 又补了两个漏网的
（`bridge` 表面在改、实际只建裸桥不写地址；`ip_forward` 写完不校验、读不回来也报成功）：

```
verify 通过  → 跳过（零写入、零 commit、零 reload）
verify 不符  → build 改回来 → uci commit → 按组 reload → 立即生效
build 失败   → hard 终止引导
改完复核仍不符 → hard 终止引导（不设回滚）
```

`RO_ONLY_NODES` 已清空，保留变量与分支结构只为「将来某项要退回只读时加个名字」。
覆盖的 12 个节点：`br_lan_ports` `lan_static` `dhcp_ignore` `wan_removed` `dns_domain`
`bridge` `lxc_zone` `fwd_rules` `wan_input` `lan_input` `snat` `ip_forward`；
另有 `docker_fw`（装了 dockerd 才生效）。

### 三个「假成功」是怎么被找出来的

这一类缺陷的共同特征是：**build 返回 0，但状态根本没改对**，而 `ensure` 不做
事后复核，于是没人发现，一路错到底。

| 节点 | 症状 | 后果 |
|---|---|---|
| `verify_ct_boot` | 整行被并进注释，函数在运行期不存在 | 每轮都重建容器，违背「全程只开机一次」 |
| `bridge` | 只 `ip link add` 建裸桥，不写 `network.lxc`、不配地址 | `ct_net` / 双向 ping 全链失败 |
| `ip_forward` | 写完无条件 log「已置 1」 | `/proc` 只读时 SNAT 与转发全废 |

检测手段是静态的：`tests/static_verify_first.py` 逐节点核查四条——
`verify_<node>` 存在、`build_<node>` 存在、`build_` 体内有判据（先判再写）、
`verify_` 体内没有写动作。这是唯一能廉价抓住「先写后验」的办法——
正常的「全就绪 → 零动作」流水测试永远走不到 build 分支。

### commit 与 reload 的区别，为什么必须成对

`uci commit` 只是把内存里的改动写进 `/etc/config/*`，**运行中的进程读不到**；
`reload` 才让进程重新加载配置。只 commit 不 reload 的结果就是「文件里是对的、
系统里还是不工作」——这正是旧版「只验不写」想规避的坑。v.95 直接把这个坑堵死：
写完必须 reload，并且 reload 后立刻再 verify 一遍。

| 配置面 | commit | 让它生效的动作 |
|---|---|---|
| `network` | `uci commit network` | `/etc/init.d/network reload`（含 lxcbr0 段与地址）|
| `dhcp` | `uci commit dhcp` | `/etc/init.d/dnsmasq restart`（reload 不够彻底） |
| `firewall` | `uci commit firewall` | `/etc/init.d/firewall reload`（fw4 重建整张 nft 表） |

三组各至多一次，且只在对应组被改动过时才触发；一次都没改就「零 commit、零 reload」。
reload 本身失败不判 hard（配置已落盘，下次重载仍生效），但**改完复核不过一定 hard**。

### 退出即恢复：不留半截置位

脚本有三种生命周期状态，任何一种残留在原地都会让下一次引导误判「已经做过了」：

| 类别 | 具体是什么 | 退出时怎么处理 |
|---|---|---|
| 进程内变量 | `GSET_<组>`、`_done_<节点>`、`_dirty_<节点>`、`_failed` | 全部清空，并打一条快照日志（干净退出时静默） |
| 内核态 | `/proc/sys/net/ipv4/ip_forward` | 本轮由脚本改过、且最终没写 `installed` → 还原成原值；引导成功则保留 `1` |
| 磁盘标记 | `reinstall_pending` | **刻意不清**。它就是靠"崩溃后残留"来计失败次数的，清了等于把自愈计数清零 |

#### 置位的值不是 1，是「分类 + 时间戳」（v.99）

以前所有置位都是 `=1`，于是三件事都做不到：看日志不知道「什么时候置的」、不知道
「是 verify 本来就过还是 build 改回来的」、退出时只知道个数不知道是谁。现在值是：

| 值 | 分类 | 含义 |
|---|---|---|
| `V:2026-10-20 12:07:38` | verified | 进场 verify 直接通过，**没有任何写入** |
| `B:2026-10-20 12:07:41` | built | build 真的改了一处（时间戳 = 改动时刻） |
| `R:2026-10-20 12:07:44` | ro | 在 `RO_ONLY_NODES` 里、脚本不代改，只登记待办 |

用法上等价于布尔：**非空即真，空串即假**。时间格式与 stamp 文件同构（`%F %T`，本地时区），
grep 一遍就能按天/按时段筛日志。退出时除了计数，还会打一行逐项明细：

```
[恢复] 退出时置位快照：done=29 dirty=12 gset=8 built=12（退出码 0）
[恢复] 逐项： _done_ct_boot=B:2026-10-20 12:07:41 _dirty_snat=B:2026-10-20 12:07:39 ...
[恢复] 置位已全部归零：done=0 dirty=0 gset=0 built=0
```

`built=N` 是这一版新加的判据：**「全都没动手」和「改了 12 处」是完全不同的结论**，
而两种情况下总数可能一样，光看个数分不出来。

改格式时踩到两个坑，都留在测试里了：

| 坑 | 症状 | 谁盯着 |
|---|---|---|
| `_FLAG_TS_FMT='%F %T'` 用单引号 | 脚本前面已有函数定义时，dash 把 `X='...'` 解析成「赋值 X=空 + 执行命令」→ `%T: not found`，变量是空串，时间戳静默变空白 | `probe_flag_format.sh` R8.8/R8.9（断言双引号 + source 无 stderr） |
| 某处仍用 `[ "$x" = 1 ]` 判置位 | 值变成 `V:<ts>` 后恒不相等，症状是某组莫名判「未置位」 | R8.3/R8.4 静态扫全脚本，一条都不许留 |

#### 为什么 `ip_forward` 需要一枚哨兵文件

`ip_forward` 是内核全局态：**重启会自然回 0，但不重启、只重跑脚本时它还是上次留下的 1**。
如果进场直接把读到的值当"原值"，就会把脚本自己上一次的写入误认成系统原本的状态，
于是"还原"变成"保持 1"，恢复逻辑形同虚设。

所以在 `$STATE_DIR/ip_forward.by-bootstrap` 落一枚空文件当哨兵，脚本置 1 时写下、还原成功后删掉：

| 进场读到 | 哨兵 | 判定 | 理由 |
|---|---|---|---|
| `1` | 在 | 原值按 `0` | 这个 1 是脚本上次置的、上次异常退出没还原 |
| `1` | 不在 | 原值 `1`，不动 | 是别的东西（手工 / 别的服务）设的，不归我们管 |
| `0` | 在 | 原值 `0`，顺手删哨兵 | 机器已经重启过、自己回 0 了，残留哨兵该清 |
| `0` | 不在 | 原值 `0` | 干净状态 |

引导成功（写了 `installed`）时哨兵**保留**——因为那个 1 是期望稳态，得留着让下次重跑
仍能认出"这个 1 是脚本的"。

这层逻辑由 `tests/probe_ipfwd_sentinel.sh` 单独盯着：它把整个脚本复制一份、只把
`/proc/.../ip_forward` 这一个字面量 sed 成临时文件路径，再用脚本自带的
`--only-funcs` 钩子只取函数定义去跑——**跑的是生产代码本体，一行逻辑都没抄**。
三个哨兵分支各做了一次变异验证（去掉判断 / 不落哨兵 / 还原后不删 / 快照不清残留），
每种变异都会让它报红。

> `--only-funcs` 是给测试用的出口：把脚本自身 `sed -n '1,/^main "\$@"$/p'` 截出来
> 打到 stdout 就 `exit 0`，不会落到 `main "$@"`。生产路径完全不受影响（只有显式传
> 这个参数才触发），但它让"拿本体做被测对象"这件事成为可能——否则只能把逻辑抄进测试，
> 那测的就不是生产代码了。

#### 顺带说清一件事：重跑时这些置位会不会自己回默认值

会，但**不是因为脚本归零**。`_bs_reexec` 走的是 `exec /bin/sh "$_self"`，整个进程映像
被替换，进程内变量自然全没了；真正"跨进程存活"的只有内核态 `ip_forward` 和磁盘标记
`reinstall_pending`。所以 `_bs_clear_flags` 的作用不是"防止跨启动污染"，而是：

1. 保证**同一进程内**不会有半截置位（信号中断、`rg_*` 子流程提前返回等情形）；
2. 让退出日志成为一张**收据**——打印「置位已全部归零」就真的能证明这次没留尾巴。

四个 trap 全装（`EXIT` / `INT` / `TERM` / `HUP`）。只装 `EXIT` 是不够的——dash 下
`SIGTERM` 默认直接终止进程、根本不走 `EXIT`，被 `kill` 或 SSH 断线时恢复逻辑不会执行。

信号处理里有个必须注意的细节：**调 `exit` 之前要把 `EXIT` trap 也摘掉**，否则
`exit` 会二次触发 `EXIT`，恢复逻辑跑两遍（日志里出现两条"置位快照/已归零"、`ip_forward`
被记成还原过两次）。这个坑第一版就踩到了，`tests/test_bp_reset.sh` 的 R2 专门盯着它。

顺序也有要求：**先做重装失败计数、再做恢复**。反过来的话计数会读到已被清空的
`_bs_stamped`/`_bs_st`，把一次真实失败记成成功。

#### 判「容器配置有没有被人动过」：比内容指纹，不比时间戳

`installed` 这个 stamp 文件里除了 `ver` / `ts`，还多记了两个指纹：

```
installed
ver=2026-10-20.102-bp
ts=2026-10-20 12:40:03
cfg_fp=a5f1c0dd3b7e2214          ← 容器 /etc/crowdsec 整个目录的内容指纹
parsers_fp=9c02be7741f0aa63      ← 容器 /etc/crowdsec/parsers 目录的内容指纹
```

**为什么不用「stamp 时间 vs 文件 mtime」判变更**——这个做法看起来合理，但两个方向都会错：

| 场景 | 时间判据会说 | 实际 | 后果 |
|---|---|---|---|
| `touch` 一下、重解压同版本 tar、备份还原 | 变了 | 没变 | 好机器被拖去**全量重装** |
| 同一秒内写两次、`cp -p` / `tar -p` 保留时间 | 没变 | 变了 | 改坏了**没人发现** |
| 时钟回跳、NTP 校正 | 不可信 | — | 时间单调性本身就不成立 |

时间只回答「什么时候动过」，回答不了「是不是同一个东西」。判「一不一样」只能比内容。

指纹的算法是「文件清单 + 每个文件的 sha1 再取一次摘要，取前 16 位十六进制」，
61 个文件实测 **9 ms**，开销可以忽略。三个实现细节都是踩出来的，每一个都对应一条测试：

| 坑 | 症状 | 修法 |
|---|---|---|
| 路径名参与摘要 | `find c` 出 `c/x.yaml`、`find .` 出 `./x.yaml`，同一个目录两个指纹 | 不接多路径参数：第一个参数当根 `cd` 进去，只算这一个目录 |
| `xargs` 无输入时抢 stdin | 空目录会把调用方管道吃掉 | `-r` + `</dev/null` |
| **`</dev/null` 挂整条管道末尾** | 管道每个元素都拿到这个重定向，`find` 的 stdout 被接 `/dev/null`，函数对**任何**目录都返回空集摘要 `da39a3ee5e6b4b0d` —— 不报错、不报警，永远说「没变」 | 只把重定向落在 `xargs` 上 |

最后一条是这一轮最值得记的：**它不报错，只是静默地永远给出同一个错误答案**。
所以 `_bs_content_fp` 额外规定：找不到文件、或路径不存在时**返回空串并置退出码 1**，
把「没法比」和「比出一致」区分开。空集摘要不是「没错」，是「看不出对错」。

读点是 `_stamp_cfg_changed`，接在重启态判定入口：

```sh
if _stamp_present; then
    log "[重启态] 检出 installed 标记：..."
    _stamp_cfg_changed || log "[变更] 上面这处差异说明容器配置被人/别的脚本改过；本次仍按组复核一遍"
    rg_restart_verify
```

**指纹只用来「说清楚现场」，不改变流程走向**。重启态本来就是逐组复核，配置改过与否，
要做的事完全一样（复核 → 不对就修一次 → 还不对重装）。但它必须出现在日志里——
否则同一台机器「今天开机很快、明天重装一遍」，事后没人说得清中间发生了什么。

判错的方向是刻意选过的：**宁可放过，不可冤枉**。所以这几种情况一律不判变更：

- 老 stamp 没有 `cfg_fp` / `parsers_fp` 字段（从旧版本升级上来的机器，当初就没记）；
- 字段值是 `-`（当时算不出指纹）；
- 现在也算不出指纹（容器目录被删、权限不对）——那是 `verify_rootfs` 该管的「缺东西」。

`tests/probe_stamp_fingerprint.sh` 的 R9（指纹本身 24 条）与 R10（读点 11 条）盯着这一整块，
其中 R9.7b/c 把「该场景下时间判据会说 changed、而内容判据说 same」做成可执行断言，
而不是注释里的一句话。

#### 重启态：哪个坏了修哪个，修不好才重装（v.101 修掉一个"每次开机都抹盘"的故障）

重启态的设计意图一直是「逐组复验、按需修补」，但 v.100 之前的实现是坏的，而且**完全静默**：

```sh
if "verify_$_g" 2>/dev/null; then ...     # 组名 PREP → verify_PREP
```

全脚本**没有** `verify_PREP` 这个函数（只有 `verify_br_lan_ports` 这类节点级函数）。
dash 报 `not found`，被 `2>/dev/null` 吞掉，返回非 0 ⇒ 判「内容不符」⇒ 调同样不存在的
`build_PREP` ⇒ 判「构建失败且无法修复」⇒ `full_reinstall` ⇒ **抹掉 rootfs**。

也就是说：**每次重启都会抹一次容器**，日志上看起来还挺"正常"——它老老实实打了
「构建失败且无法修复，彻底重装」。

修完之后是真正的「哪个坏了修哪个」：

```
按 GROUP_SEQ 逐组：
    这组置位了吗？没置位 → 重装（说明流程没走完，不是配置问题）
    组内逐节点（节点清单从全局 _order 按 NODE_GROUP_<节点> 筛，与 ensure_group 同口径）：
        verify_<节点> 过      → 跳过，一个字节都不写
        verify_<节点> 不过    → build_<节点> 修一次
            build 成功        → 继续下一个节点
            build 也失败      → 记下来（说明不是配置错，是环境坏了）
    本组有修不好的节点 → 重装
```

同一个提交里还修了两处同源问题：

| 问题 | 症状 |
|---|---|
| `main` 里残留 `eval "GSET_$_g=0"` | v.99 起置位值是 `V:<ts>`，`0` 是非空值 ⇒ 被判成"已置位"，后组的前置检查形同虚设 |
| 组键大小写不一致 | `GROUP_SEQ` 是大写、置位用小写，读错名字就永远读不到值（现在统一用 `_rg_key` 转小写） |

这三条都由 `tests/probe_restart_verify.sh`（R11，15 条）钉住，其中 R11.6 专门断言
「已经对的节点 `build` 一次都没被调用」——这才是"按需修补"和"无脑重写"的分界线。

#### `last_pull` 失效之后，脚本到底修什么（v.102）

`last_pull` 是 bouncer 向 LAPI 拉决策的时间戳，**只反映 bouncer↔LAPI 这条链**，与日志
转发无关。它失效后的处理在 `step_C`，四步：

```
① 等 LAPI 就绪（最多 90s）+ 直接查 last_pull      → 有效：链路就绪，收工
② LAPI 就绪但 last_pull 没刷新：再等一个纯窗口
   （12×5s=60s，只观察、不夹带任何写入/重启）      → 恢复：链路就绪，收工
③ 仍未恢复 → 复验 A/B 定位根因
④ A/B 有缺项 → 修一次 → 复验 → 再走一轮 ①+②
```

**真正会动手的只有两处**，其余都是等待和判定：

| 步骤 | 判据 | 修复动作 |
|---|---|---|
| A | 宿主机 syslog 是否转发到容器 `IP:514/udp`（`verify_log_forward` 四个 uci 值） | `setup_log_forward`：写 `log_ip/log_port/log_proto/log_remote` + `uci commit system` + reload logd |
| B | bouncer 服务活着 + nft 表就位 + （LAPI 可达时）bouncer 已注册 | `fix_B`：屏蔽 CAPI → `_bouncer_uci_apply`（api_url/enabled/deny_action/interface=br-lan）→ 等 LAPI → **`_bouncer_register_once`（删残留坏记录 → `cscli bouncers add` 拿新 key → 写进 uci）** → enable+restart 宿主机 bouncer → 等 nft 表 |

其中**最可能真正治好 `last_pull` 的是 `_bouncer_register_once`**：`last_pull` 停滞的头号
原因就是 bouncer 的 `api_key` 与 LAPI 里注册的对不上（换过容器、动过 uci、服务没重启），
重新注册换一把新 key 写回 uci，链路立刻通。A 步的日志转发其实治不了 `last_pull`，
它在这里的作用是"证明整条链路的其他部分都没塌"，用来把「容器整体坏了」和
「某个组件缺了」区分开。

修完之后的判定：

```
修好后 last_pull 恢复                        → 收工
A/B 修好了但 last_pull 仍不恢复               → 判定容器损坏 → 五道门 → 抹 rootfs 重装
A/B 修不好                                    → hard 终止（exit 1），不重装
```

> **为什么要 A/B 都正常才重装**：A/B 正常说明该配的都配了、服务都在跑，却还是拉不到
> 决策 —— 那就不是配置问题，是容器里的 crowdsec/数据库坏了，重装才对。反过来，A/B
> 有缺项时先修，因为缺项本身就可能就是原因（比如 bouncer 没注册 → 没 key → 拉不到）。

**这里有个 v.102 修掉的假绿**：`bouncer_pulling` 返回 0 有两种来路——「明确新鲜」和
「判不了」。原先判不了的三条路径（容器内 `date` 不可用、阈值非数字、阈值=0）全是裸
`return 0`，一个字不打。而 `_escalate_reinstall` 的第一句就是 `if bouncer_pulling; then … 不升级`，
于是判不了被读成「已恢复」，打出「last_pull 已恢复，重装无益」——**机器卡在坏状态，
日志一路报喜**。现在判不了仍然放过（误判失效会把好机器带去重装，破坏性更大），但
必须打一行「判不了……这不是『新鲜』」，并且 `_escalate_reinstall` 的措辞改成
「当前判定为在拉」并附一句「若上一行是判不了，这一行是放行不是确认恢复」。

顺带：阈值填成非数字时不再静默关闭检查（警告后回落默认 60s）；`_sc_wait_pull` 的
60 秒干等加了进度日志，并且同一句「停滞」不再每 5 秒刷一遍。

`tests/probe_last_pull_semantics.sh`（R12，19 条）钉住这些，其中 R12.6~R12.8 专门断言
「判不了时返回码仍是 0，但日志必须出现」——**放过可以，闭嘴不行**。

### LAN 四值以编译期文件为准

`network.lan` 的 IP / 掩码 / 网关 / DNS 四个字段，**期望值来自编译期写进固件的
四个文件**（GitHub Actions 输入框 → `/etc/config/custom_router_*.txt`），
由 `_lan_static_conf` 推导、`build_lan_static` 校准：

| 情况 | 结果 |
|---|---|
| 什么都没填 | `10.0.0.201 / 255.255.255.0 / 10.0.0.10 / 10.0.0.10` |
| 填了 IP 且掩码是 /24 | 网关与 DNS 自动取该 IP 的前三段 `.1` |
| 掩码非 /24 | **不推导**，网关仍取文件里的值（推不出来） |
| 显式填了网关 | 网关用该值；没单独填 DNS 时 DNS 跟随网关 |
| 显式填了 DNS | DNS 用该值（优先级最高） |

这意味着**在 LuCI 里改 LAN 地址会被下次开机改回去**。要改就从这四条路走：

1. 重新编译，在 Actions 里填新的 `Router IP` 等输入；
2. 或直接改 `/etc/config/custom_router_ip.txt` 等文件的首行，下次开机生效。

写入前有一道合法性闸门 `_lan_conf_valid`：IP / 网关 / DNS 必须是合法的点分四段
（每段 0–255、不允许多余前导零），且 IP 不能等于网关。**任何一项不合法就放弃写入并
hard 终止**——因为把 `network.lan` 写成非法地址，`network reload` 后接口起不来，
SSH 直接失联，而且是那种"重启也进不去"的失联。

### 需要自担的风险

把 `br-lan` 或 `lan` 地址改错，SSH 会当场失联，脚本也没法自己救回来。
因此 `build_br_lan_ports` / `build_lan_static` 前有一道 `_net_write_guard`：
它读 `SSH_CONNECTION` 判断你从哪个网段进来，如果来自 LAN 网段就明确打警告日志
（「改写后本会话可能失联」），非 LAN 网段则提示影响不到本会话。
这只是提醒，**不是拦截**——脚本仍会按你的期望值改下去。

### SNAT 是容器出网的生命线（`snat` 节点）

`snat` 归属 **PREP 组**（容器启动前），并且 **`ct_boot` 依赖它**——SNAT 没就位就不开机。
原因很直接：容器没有 SNAT 就出不了网，拉不到 LAPI，`last_pull` 一直停滞，
探针每小时判一次失败，最后走到反复重装。这不是配置洁癖，是防止自伤。

五个字段逐项核对，少一个都不放行；不符则由 `build_snat` 就地校准：

| 字段 | 期望值 |
|---|---|
| `target` | `SNAT` |
| `proto` | `all` |
| `src` | `lan` |
| `src_ip` | 由 `CONTAINER_IP` 推出的网段（如 `10.1.0.0/24`） |
| `snat_ip` | 路由器 LAN 地址（`network.lan.ipaddr`） |

**按 `name=lxc-snat` 定位段，不赌段名**：LuCI 删了重建会把段名变成 `cfg0a1b2c`
或 `@nat[0]`，写死 `firewall.lxcsnat` 会在「用户界面上明明配了」的情况下误判缺失。
这一点有专门的回归测试（S1.2 / S1.4）。重复 build 不会多造第二条 SNAT 段（S4.5）。

脚本还会写这些（按配置面）：

- `dropbear` / `ttyd` 的 `Interface`（把 SSH/Web 终端绑到 LAN 侧，各自局部 reload）
- `/etc/config/system` 的 `log_ip` / `log_port`（系统日志推给容器里的 crowdsec）
- `/etc/config/crowdsec` 的 `api_url` / `api_key`（bouncer 注册，写完重启宿主机 bouncer）

**防火墙不删整段**：全仓只允许 `uci -q delete firewall.<段>.<字段>` 这种单值删除
（如 `firewall.docker.subnet`），不允许删掉某个 zone/rule 段本身。
原来的 `build_docker_fw` 会 `uci delete firewall.docker` 并清掉所有含 docker 的
forwarding——那正是用户在 LuCI 里建的配置，现在改成「有则校准、无则补建」。

**WAN 段删除**：`build_wan_removed` 会 `uci -q delete network.wan` 与 `network.wan6`。
删完走 network 组统一 commit + reload。

**删段不波及桥接**：只删 `network.wan` / `network.wan6` 两个 section，
`br_lan`、`lan`、`ports`、`lan.device` 一概不动——这四项不动就是判据。

## 测试怎么跑

全在 `tests/` 下，纯 `sh`，无外部依赖（只有静态检查那一条要 `python3`）。

```sh
sh tests/test_bp_reset.sh            # 退出即恢复，内部转调下面 4 个探针
sh tests/probe_ipfwd_sentinel.sh     # ip_forward 哨兵（也可单独跑）
sh tests/probe_flag_format.sh        # 置位值格式「分类+时间戳」
sh tests/probe_stamp_fingerprint.sh  # 内容指纹：判「一个不一样」，不比时间
sh tests/probe_restart_verify.sh     # 重启态逐组复验：哪个坏了修哪个
python3 tests/static_verify_first.py # 逐节点核查「先验证后写入」
```

另有 19 个脚本可单独执行：`probe_v10830` ~ `probe_v10858` 一组按版本命名的回归探针
（对应各次修复）、`probe_audit` / `probe_guard` / `probe_netsafe` / `probe_lxc_auto` /
`probe_boot_heal` / `probe_boot_timeout` / `probe_dns_watch`、以及 `guard_pin` /
`guard_tests_dir` / `lapi_ladder` / `log_trim`。

每条脚本末尾自带通过数，以实际输出为准。

| 关注点 | 对应测试 |
|---|---|
| 退出路径：trap 有没有者、信号来了跑不跑、置位清没清 | `test_bp_reset.sh` |
| 判据本身错：拿 mtime 比时间当「变没变」，两个方向都会错 | `probe_stamp_fingerprint.sh` |
| 形状错：build 体内没有判据，等于无条件覆盖 | `static_verify_first.py` |
| 脚本自身被改坏 / `tests/` 目录没进镜像 | `guard_pin.sh` / `guard_tests_dir.sh` |

> v.180.162 起，`test_bp_dag.sh` / `test_bp_net.sh` / `test_bp_consistency.sh` /
> `probe_last_pull_semantics.sh` / `luci_restore.sh` 这 5 个失效测试已从 `tests/` 删除。
> 旧文档里 `sh tests/test_bp_*.sh` 那一排命令不要再照抄。

## 与双模式版（原 bk 仓）的差异

| | 本仓（旁路由版） | bk（双模式版） |
|---|---|---|
| 模式 | 仅旁路由 | gw / bypass 双模式，`custom_router_mode.txt` 切换 |
| 桥接 | 所有物理口 → br-lan | gw 模式首口=WAN，其余进桥 |
| WAN | wan/wan6 段整段删除 | gw 模式首口 dhcp 拨号 |
| DHCP | lan.ignore=1 | gw 模式 lan 正常发地址 |
| 网络/防火墙写入 | 验证 + 修改 + commit + 分组 reload | 自动补建 |
