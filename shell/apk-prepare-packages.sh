#!/bin/sh

BASE_DIR="extra-packages"
TEMP_DIR="$BASE_DIR/temp-unpack"
TARGET_DIR="packages"

# 【v.181】run 包固定取自己仓库 CloudRunFilesBuilder 的 extra 标签（理由同 24.10 线的
# prepare-packages.sh）：上游 25.12 workflow 每次构建完会把 apk 包以固定文件名覆盖到 extra。
#   https://github.com/xiealon/CloudRunFilesBuilder/releases/download/extra/25-clashoo_x86_64.run
# 不再走 releases/latest + 正则筛选：latest 会被别的 release 抢占，
# 且同一包存在新旧两份时 head -n1 可能拿到旧的。
# 两个额外注意点：
#   ① 资产名带 25- 前缀，否则会取到 24.10 的 ipk 版；
#   ② apk 仓库里 clashoo 是 run/x86/clashoo/ 目录（三个 apk），不是 run 文件，
#      所以连目录一起删，否则旧 apk 会被下面的 find 收进 packages/。
RUN_BASE="https://github.com/xiealon/CloudRunFilesBuilder/releases/download/extra-apk"
for _pkg in clashoo; do
    rm -f "$BASE_DIR"/${_pkg}_*.run
    rm -rf "$BASE_DIR"/${_pkg}
    wget -q "$RUN_BASE/${_pkg}_x86_64.run" -P "$BASE_DIR"/ \
        || { echo "::error::下载 ${_pkg} 失败: $RUN_BASE/${_pkg}_x86_64.run"; exit 1; }
    echo "✅ ${_pkg} 已取: ${_pkg}_x86_64.run ($(stat -c%s "$BASE_DIR/${_pkg}_x86_64.run") bytes)"
done

rm -rf "$TEMP_DIR" "$TARGET_DIR"
mkdir -p "$TEMP_DIR" "$TARGET_DIR"

for run_file in "$BASE_DIR"/*.run; do
    [ -e "$run_file" ] || continue
    echo "🧁 解压 $run_file -> $TEMP_DIR"
    sh "$run_file" --target "$TEMP_DIR" --noexec
done

find "$TEMP_DIR" -type f -name "*.apk" -exec cp -v {} "$TARGET_DIR"/ \;


find "$BASE_DIR" -mindepth 2 -maxdepth 2 -type f -name "*.apk" ! -path "$TEMP_DIR/*" \
  -exec echo "📜 Found:" {} \; \
  -exec cp -v {} "$TARGET_DIR"/ \;

apk_fixname() {
  for f in "$1"/*.apk; do
    [ -e "$f" ] || continue
    cur=$(basename "$f")
    base="${cur%.apk}"
    pn=$(tar -xzOf "$f" .PKGINFO 2>/dev/null | sed -n 's/^pkgname[[:space:]]*=[[:space:]]*//p' | head -n1)
    pv=$(tar -xzOf "$f" .PKGINFO 2>/dev/null | sed -n 's/^pkgver[[:space:]]*=[[:space:]]*//p'  | head -n1)
    if [ -n "$pn" ] && [ -n "$pv" ]; then
      want="$pn-$pv.apk"
    else
      nb=$(printf '%s' "$base" \
        | sed -E 's/-(x86_64|aarch64_[a-z0-9_]+|arm_[a-z0-9_-]+|i386_pentium4|mips[a-z0-9_]*)$//' \
        | sed -E 's/([0-9]{4}\.[0-9]{2}\.[0-9]{2})\./\1~/')
      want="$nb.apk"
    fi
    if [ "$cur" != "$want" ]; then
      mv -f "$f" "$1/$want"
      echo "🔧 apk 名修正: $cur -> $want"
    fi
  done
}

# 【v.186】apk 文件名必须严格等于 <pkgname>-<pkgver>.apk，且 pkgver 与包内
# PKGINFO 完全一致 —— apk index 就是从 PKGINFO 生成的，imagebuilder 的
# package_install 按索引拼文件名去 packages/ 找，找不到就报
#   ERROR: xxx: package mentioned in index not found
# 上游各式各样的"美化"（把 ~ 换成 .、追加 -<arch>、甚至直接把 ~ 删掉，
# 例如 sbwml 的 luci-i18n-mosdns-zh-cn-26.255.53985~73981c0.apk）都没法用
# sed 猜回来，所以这里直接读 PKGINFO 定名。已规范的幂等，不会动。
apk_fixname "$TARGET_DIR"

echo "✅ 所有 .apk 文件已整理至 $TARGET_DIR/"
