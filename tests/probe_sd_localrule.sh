#!/bin/sh
# R35：smartdns 的 localhost 本地解析（adblock 探活的依赖）
#
# 背景（2026-11-07 真机 H3C C100 / ImmortalWrt 25.12.2 / smartdns 48.4）：
#   adblock 4.5.x 的 f_dnsup() 用 `nslookup localhost.` 判 DNS 后端起没起
#   （adblock.sh 第 80 行 adb_lookupdomain="localhost"，硬编码）。smartdns 对
#   localhost 回 NXDOMAIN，nslookup 退出码 1，adblock 判失败，每次 reload 白等
#   30 秒并打 "dns backend restart with adblock blocklist failed"。
#
# 落点为什么是 custom.conf 而不是 uci：
#   真机上写 config domain-rule + domain/address 之后，/var/etc/smartdns/
#   smartdns.conf 里一行都没有 —— init 不认这个段类型。而 init 生成的配置里有
#   `conf-file /etc/smartdns/custom.conf`，往里追加一行才生效。
#
# 本测试盯四件事：
#   A. 两个函数在、变量值正确、判据是整行精确匹配（不能被子串骗过）；
#   B. 接进了 --config / --check / --conf / --localrule 四个入口；
#   C. 幂等：跑两次只有一行，已有该行不再追加；
#   D. 原文件末尾没有换行时，新行不能粘到最后一行上。
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
FILES_DIR="${CS_FILES_DIR:-files}"
SD="$REPO/$FILES_DIR/usr/sbin/pkg-restore-smartdns.sh"

R=0
ck() {
    if [ "$2" = "$3" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1  got=[$2] want=[$3]"
        R=$((R + 1))
    fi
}
body() {
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\)[[:space:]]*\\{" { inside = 1 }
        inside { print }
        inside && /^}/ { exit }
    ' "$2"
}
code() { body "$1" "$SD" | grep -v '^[[:space:]]*#'; }

echo "== 35.1 函数与变量 =="
ck "R35.1a 有 _sd_localrule" "$(grep -c '^_sd_localrule()' "$SD")" "1"
ck "R35.1b 有 _sd_localrule_ok" "$(grep -c '^_sd_localrule_ok()' "$SD")" "1"
ck "R35.1c 变量值正确" \
   "$(sed -n 's/^_SD_LOCALRULE="\(.*\)"$/\1/p' "$SD")" "address /localhost/127.0.0.1"
ck "R35.1d custom.conf 在 SD_CONF_FILES 里" \
   "$(sed -n 's/^SD_CONF_FILES=".*\(custom\.conf\).*"$/\1/p' "$SD")" "custom.conf"
ck "R35.1e 判据用整行精确匹配（grep -qxF）" \
   "$(code _sd_localrule_ok | grep -c 'grep -qxF')" "1"
ck "R35.1f 判据没有用子串匹配（无 grep -qF 但不带 x）" \
   "$(code _sd_localrule_ok | grep -cE 'grep -qF|grep -q "')" "0"
ck "R35.1g 判定函数只写 stderr，不动文件" \
   "$(code _sd_localrule_ok | grep -vE '>&2' | grep -cE '^[[:space:]]*(uci |cp |mv |rm |mkdir |printf|echo )')" "0"
ck "R35.1h 文件缺失时给出 stderr 提示" \
   "$(code _sd_localrule_ok | grep -c '缺文件：')" "1"
ck "R35.1i 缺行时给出 stderr 提示" \
   "$(code _sd_localrule_ok | grep -c '缺 localhost 本地解析')" "1"

echo
echo "== 35.2 接入四个入口 =="
ck "R35.2a _sd_config 调了 _sd_localrule" \
   "$(code _sd_config | grep -c '_sd_localrule')" "1"
_ln_lr=$(grep -n '_sd_localrule ||' "$SD" | head -1 | cut -d: -f1)
_ln_main=$(grep -n '_sd_cfg_main ||' "$SD" | head -1 | cut -d: -f1)
ck "R35.2b 调用排在 _sd_cfg_main 之前（先补文件再写 uci）" \
   "$([ -n "$_ln_lr" ] && [ -n "$_ln_main" ] && [ "$_ln_lr" -lt "$_ln_main" ] && echo ok)" "ok"
ck "R35.2c --check 有 exit 4" \
   "$(awk '/^--check\)/,/^    ;;/' "$SD" | grep -c '_sd_localrule_ok || exit 4')" "1"
ck "R35.2d --check 里 localhost 判定排在规则文件之后" \
   "$(awk '/^--check\)/,/^    ;;/' "$SD" | grep -n '_sd_' | grep -c '_sd_localrule_ok')" "1"
ck "R35.2e --conf 也补这一行" \
   "$(awk '/^--conf\)/,/^    ;;/' "$SD" | grep -c '_sd_localrule')" "1"
ck "R35.2f 有 --localrule 入口" \
   "$(grep -c '^--localrule)' "$SD")" "1"
ck "R35.2g 用法提示带上 --localrule" \
   "$(grep -c 'localrule  只补' "$SD")" "1"

echo
echo "== 35.3 动态：幂等与边界 =="
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/lr.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMPD"' EXIT

LIB="$TMPD/lib.sh"
: > "$LIB"
body _sd_localrule_ok "$SD" >> "$LIB"
body _sd_localrule "$SD" >> "$LIB"
[ -s "$LIB" ] || { echo "FAIL: 抽不到函数"; exit 1; }

log() { printf '%s\n' "$*" >> "$TMPD/log.txt"; }
_SD_LOCALRULE="address /localhost/127.0.0.1"
PKGROOT="$TMPD/root"
mkdir -p "$PKGROOT/etc/smartdns"
CF="$PKGROOT/etc/smartdns/custom.conf"
. "$LIB"

ck "R35.3a 文件不存在时判缺" "$(_sd_localrule_ok; echo $?)" "1"
_sd_localrule
ck "R35.3b 首次追加后文件存在" "$([ -f "$CF" ] && echo yes)" "yes"
ck "R35.3c 首行内容正确" "$(cat "$CF")" "address /localhost/127.0.0.1"
ck "R35.3d 追加后判好" "$(_sd_localrule_ok; echo $?)" "0"

_sd_localrule
ck "R35.3e 跑第二次仍是 1 行（幂等）" "$(wc -l < "$CF" | tr -d ' ')" "1"

printf 'address /localhost/127.0.0.2\n' > "$CF"
ck "R35.3f 近似行不算已配好" "$(_sd_localrule_ok; echo $?)" "1"
_sd_localrule
ck "R35.3g 追加后正好 2 行" "$(wc -l < "$CF" | tr -d ' ')" "2"
ck "R35.3h 原近似行保持不变" "$(head -1 "$CF")" "address /localhost/127.0.0.2"

printf '# tail-no-newline' > "$CF"
_sd_localrule
ck "R35.3i 末尾无换行时先补换行" "$(head -1 "$CF")" "# tail-no-newline"
ck "R35.3j 新行独立成行" "$(sed -n '2p' "$CF")" "address /localhost/127.0.0.1"
ck "R35.3k 没有粘连成一行" "$(grep -c 'tail-no-newlineaddress' "$CF")" "0"

mkdir -p "$TMPD/root2"
PKGROOT="$TMPD/root2"
_sd_localrule
ck "R35.3l 目录不存在时自建 etc/smartdns" \
   "$([ -f "$TMPD/root2/etc/smartdns/custom.conf" ] && echo yes)" "yes"

echo
if [ "$R" -eq 0 ]; then
    echo "全部通过"
else
    echo "失败 $R 项"
fi
exit $((R > 0))
