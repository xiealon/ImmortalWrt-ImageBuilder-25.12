#!/bin/bash
# 【v.180.198】固件版本标记 —— 与 crowdsec-lxc-bootstrap.sh 的 SCRIPT_VER 同步，每次改脚本一起改

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-partexp luci-i18n-partexp-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-rtp2httpd luci-i18n-rtp2httpd-zh-cn"
# 【2026-11-02】lucky 移除（用户定：只去纯重复的，一个功能留一个）。
# lucky 是全能型（DDNS + 反向代理 + 端口转发 + Web 服务 + SSL 证书），
# 它的每一项在固件里都已有专用工具且是从没配过的状态：
#   DDNS   → ddns-go（保留）
#   证书   → acme-acmesh + luci-app-acme（保留）
#   穿透   → tailscale + cloudflared + nps（留这三个，见下方 zerotier/xfrpc/eoip/ngrokc 各处说明）
# 当日 201 实测：/etc/lucky 目录 0 个文件、option enabled '0' —— 装了从未配置，
# 留着只是多一个从没验证过的黑盒。cp /etc/config/lucky 里 configdir 指向它。
# honk：25.12 上替代 daed 的 eBPF 代理引擎（硬要求内核 6.12+）。
# doona 管理界面内嵌在 honk-core 里，访问 http://<LAN IP>:9527/（必须用 IP，不认主机名）。
# luci-app-honk 只负责 Services → honk 的启停/升级，节点与路由仍在 doona 里配。
# 包来自 xiealon/CloudRunFilesBuilder 的 honk-apk Release，由 build25.sh 下到 packages/，
# 所以这里不带 @tag —— 走的是本地包，不是 apk 源。
# luci-lib-daeuniverse 是 luci-app-honk 的运行依赖；vmlinux-btf-builtin 是 BTF 哨兵，
# 显式列出是为了让「缺包」在构建期就暴露，而不是靠依赖解析碰运气。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES honk luci-app-honk luci-lib-daeuniverse luci-i18n-daeuniverse-zh-cn vmlinux-btf-builtin"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES geoview sing-box luci-compat kmod-tun kmod-inet-diag kmod-nft-tproxy kmod-nft-socket bash curl lua unzip"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES clashoo luci-app-clashoo luci-i18n-clashoo-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES yq kmod-dummy ca-bundle"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-taskplan luci-i18n-taskplan-zh-cn"
# 【2026-11-02】mosdns 移除（用户定：DNS 只留 smartdns + adblock 这条链）。
# 为什么不留：DNS 层已经有两层在跑 —— smartdns 占 53 做加速/分流/缓存，
# adblock 生成广告黑名单喂给 smartdns（/etc/config/adblock 里
#   option adb_enabled '1' + option adb_dns 'smartdns'，
# /etc/config/smartdns 里 list conf_files '/tmp/smartdns/adb_list.overall'）。
# 再加 mosdns 就是第三个 DNS 分流器，默认端口 5335 且 redirect '1' 会去抢
# 53 的活，和 smartdns 直接冲突。当日实测 mosdns 本来就是 enabled '0' 没在跑。
# 注意：_PA_MOSDNS 保护组保留不动 —— 新固件不再带 P:mosdns，_pa_should
# 自动判「固件未带」跳过，不会误报；留着方便以后要加回来。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-openvpn-zh-cn"
# 【2026-11-02】zerotier 移除（用户定：组网只留 tailscale，其余按场景归并）。
# 当日 201 实测这 7 个穿透/组网工具全部 init.d enabled=YES，却只有 tailscaled
# 一个进程在跑，且它 BackendState=NeedsLogin、公钥全 0、TailscaleIPs=null ——
# 等于装了从来没登录过。按能力重新归并成三类，每类只留必要的：
#   组网(tailscale/zerotier) 留 1 —— tailscale 打洞成功直连、失败走 DERP 兜底，
#     还带 exit node 与 subnet router；zerotier 唯一的独有能力是二层广播，
#     而 201 是旁路由（uci get network.wan.device 为空、只有 br-lan），用不上。
#   公网暴露(cloudflared/ngrokc/xfrpc/npc) 留 cloudflared + nps 备用。
#   二层(eoip) 全去 —— 要求两端能直连建 GRE，无 WAN 时无从谈起。
# 25 线这里原来只有 i18n 一条，删了就带不进整套（依次拉 luci-app-zerotier → zerotier），
# 不必动 imm25.config（CONFIG_PACKAGE_zerotier 本来就是 not set）。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-proto-wireguard"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-tailscale-community luci-i18n-tailscale-community-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ddns-go-zh-cn"
# 【2026-11-02】xfrpc 移除（用户定）。xfrpc 是 frp 客户端，必须自己有公网 VPS
# 才能用；与 nps/npc 属同类（都是「自建中转」），二选一留 nps。
# nps 带 Web 管理面板 + SOCKS5，服务端放 VPS、客户端 npc 放本机，功能比 frp 全。
# 25 线只有 i18n 一条，删了就带不进整套（依次拉 luci-app-xfrpc → xfrpc）。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-timewol-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-3ginfo-lite-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-acme-zh-cn"
# 【2026-11-02】adblock：先留着（用户当日改回）。
# 这条链是 i18n → luci-app-adblock → adblock，写一行三个全装，imm25.config 里
# CONFIG_PACKAGE_adblock / CONFIG_PACKAGE_luci-app-adblock 都是 not set，
# 所以固件里有没有这套，全看这一行在不在 —— 别处不用改。
# 加了它就要一起进 pkg-restore-apps.sh 的 _PA_ADBLOCK 保护组：
# 单独留在清单里、却不在保护表里，等于「装上了但被 apk del 掉没人管」。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-adblock-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-aria2-zh-cn"
# 【2026-11-02】banip 移除（用户定：用不到）。
# 当日 201 实测：三个包都在、init.d 是 ENABLED，但 option ban_enabled '0'、
# 主程序 /usr/bin/banip.sh 从未启动、无 pidfile、/tmp 与 /var 下没有任何
# ipset/cidr、nft list sets 里也没有 banip 的 set —— 一件活都没干。
# ps 里那个 `{banip} ... /etc/init.d/banip actual` 是 procd 的 rc.common 壳，
# 两次检查拿到的 PID 都不同，不是常驻主程序。
# 根本原因：这台机器没有 WAN（uci get network.wan.device 为空，只有 br-lan
# 192.168.1.201/24），不承担转发，banip 拦的是「经过本机的转发/入站流量」，
# 没有 WAN 就一条都用不上。
# 而且这件事 crowdsec 已经在做且更专业：nft 里有 table ip crowdsec 与
# crowdsec-blacklists / -CAPI / -lists-crowdsec_cve_2024_4577 三个 set 在生效，
# ban_logterm 那种防爆破也由 crowdsec 的 ssh 场景覆盖，去掉不丢功能。
# 25 线这里原来只有 i18n 一条，删了就带不进整套（依次拉 luci-app-banip → banip）。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-cifs-mount-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-cloudflared-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-email-zh-cn"
# 【2026-11-02】eoip 移除（用户定）。EoIP 是二层 GRE 隧道，要求两端都能直连
# 建立 GRE；201 没有 WAN（无公网 IP），这条路根本走不通。
# 25 线只有 i18n 一条，删了就带不进整套（依次拉 luci-app-eoip → eoip）。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-hd-idle-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ksmbd-zh-cn"
# 【2026-11-02】keepalived 移除（用户定：旁路由用不到）。
# keepalived 是 VRRP 主备漂移，要至少两台机器跑同一 VRRP 组、共享一个漂移 VIP。
# 当日 201 实测：4 个包都在（keepalived / keepalived-sync / luci-app-keepalived /
# luci-i18n-keepalived-zh-cn），init.d 是 ENABLED，但 UCI option enabled '0'、
# 进程未起、一个漂移 VIP 都没有；/etc/keepalived/keepalived.conf 3625 B 与 /rom
# 出厂逐字节一致（cmp 通过，Jul 2 09:40）—— 那个 vrrp_instance VI_1 是包自带示例，
# 不是配置。纯占空间。
# 25 线这里原来只有 i18n 一条，删了就带不进整套（依次拉 luci-app-keepalived →
# keepalived → keepalived-sync），不必动 imm25.config。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-nfs-zh-cn"
# 【2026-11-02】ngrokc 移除（用户定）。ngrok 反向隧道，与 cloudflared 属同一场景
# （把内网服务暴露到公网），但 cloudflared 走 Cloudflare 网络、不需要公网 IP、
# 自带证书、免费不限速；ngrokc 免费版是随机域名 + 限速，差一档。
# 当日实测 ngrokc 服务在跑但唯一隧道 option enabled '0'，纯空转。
# 25 线只有 i18n 一条，删了就带不进整套（依次拉 luci-app-ngrokc → ngrokc）。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-nps-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-p910nd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-sqm-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ttyd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-uhttpd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-upnp-zh-cn"
# 【2026-11-02】usb_printer 移除，USB 打印共享只留 p910nd。
# 两者是同一件事的两个界面：/etc/init.d/usb_printer 里唯一动作就是
# killall p910nd —— 底层还是 p910nd，它只是 LuCI 的新式管理页。
# 当日 201 实测：/etc/config/usb_printer 是 0 字节、9100 端口没监听、无进程
# （init.d running 报 YES 是脚本无 procd 实例造成的假阳性）；
# p910nd 配置有内容（device /dev/usb/lp0、port 0）。留 p910nd 这个标准实现。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-wechatpush-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES liblxc lxc lxc-common lxc-configs lxc-auto lxc-init "
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-create lxc-start lxc-stop lxc-destroy lxc-freeze lxc-unfreeze lxc-autostart"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-ls lxc-info lxc-monitor lxc-top lxc-snapshot lxc-checkconfig lxc-config"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-attach lxc-console lxc-execute lxc-device lxc-copy lxc-cgroup"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES lxc-unshare lxc-usernsexec lxc-wait"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-lxc rpcd-mod-lxc luci-i18n-lxc-zh-cn"

# smartdns：crowdsec-lxc-bootstrap 的 DNS 前置（同上，必须随固件进 /rom）
CUSTOM_PACKAGES="$CUSTOM_PACKAGES smartdns"
# 界面：同上，随固件进 /rom 才能被 pkg_base 补回；不选 smartdns-ui（Rust 大包）。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-smartdns"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES dockerd luci-app-dockerman luci-i18n-dockerman-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES crowdsec-firewall-bouncer"
# nftables-json /usr/sbin/nft 归属这个包（2026-10-27 真机核实）：bouncer 的 deny_action=drop
# 走 nft JSON 接口，少了它 bouncer 起得来但一条拦截都下发不了 —— 全是「开着却不拦」。
# bootstrap 里有 _rom_restore_tree nftables-json，所以**构建期必须随固件进 /rom**，
# 否则那条恢复路径两边都空。
CUSTOM_PACKAGES="$CUSTOM_PACKAGES nftables-json"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-crowdsec-firewall-bouncer"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-crowdsec-firewall-bouncer-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES xz tar ip-full"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-veth kmod-ikconfig"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-br-netfilter"
# acpi_call: manual EC fan-step control for Panasonic CFSV7-3 (added 2026-11-05).
# apk already ships in packages tar (kmod-acpi-call-6.12.103.1.0-r1.apk); list it here only.
CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-acpi-call"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES kmod-hwmon-pwmfan kmod-gpio-pwm"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES glib2 crconf davici swanmon kmod-crypto-chacha20poly1305"
