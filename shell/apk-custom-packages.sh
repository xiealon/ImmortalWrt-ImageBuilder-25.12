#!/bin/bash
# 【v.180.198】固件版本标记 —— 与 crowdsec-lxc-bootstrap.sh 的 SCRIPT_VER 同步，每次改脚本一起改

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-partexp luci-i18n-partexp-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-rtp2httpd luci-i18n-rtp2httpd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-lucky lucky luci-i18n-lucky-zh-cn"
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
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-mosdns luci-i18n-mosdns-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-openvpn-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-zerotier-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-proto-wireguard"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-app-tailscale-community luci-i18n-tailscale-community-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ddns-go-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-xfrpc-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-timewol-zh-cn"

CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-3ginfo-lite-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-acme-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-adblock-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-aria2-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-banip-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-cifs-mount-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-cloudflared-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-email-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-eoip-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-hd-idle-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ksmbd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-keepalived-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-nfs-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ngrokc-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-nps-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-p910nd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-sqm-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-ttyd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-uhttpd-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-upnp-zh-cn"
CUSTOM_PACKAGES="$CUSTOM_PACKAGES luci-i18n-usb-printer-zh-cn"
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

CUSTOM_PACKAGES="$CUSTOM_PACKAGES glib2 crconf davici swanmon kmod-crypto-chacha20poly1305"
