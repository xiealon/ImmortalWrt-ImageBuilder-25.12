#!/bin/sh

BASE_DIR="extra-packages"
TEMP_DIR="$BASE_DIR/temp-unpack"
TARGET_DIR="packages"

# 【v.181】run 包固定取自己仓库 CloudRunFilesBuilder 的 extra 标签。
# 上游 workflow 每次构建完，会把该包以固定文件名覆盖到 extra：
#   https://github.com/xiealon/CloudRunFilesBuilder/releases/download/extra/clashoo_x86_64.run
# 不再走 releases/latest + 正则筛选：latest 会被别的 release 抢占（例如 lxc-latest），
# 且同一包存在新旧两份时 head -n1 可能拿到旧的。
# 必须先后旧 run：下面会把 $BASE_DIR/*.run 全解一遍，两份并存就是两个版本的 ipk
# 同时进 packages/，最后谁赢取决于文件名排序 —— 看着更新了、其实没更新。
RUN_BASE="https://github.com/xiealon/CloudRunFilesBuilder/releases/download/extra-ipk"
for _pkg in clashoo; do
    rm -f "$BASE_DIR"/${_pkg}_*.run
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

find "$TEMP_DIR" -type f -name "*.ipk" -exec cp -v {} "$TARGET_DIR"/ \;


find "$BASE_DIR" -mindepth 2 -maxdepth 2 -type f -name "*.ipk" ! -path "$TEMP_DIR/*" \
  -exec echo "📜 Found:" {} \; \
  -exec cp -v {} "$TARGET_DIR"/ \;

# 【v.187】官方 feed 也有的系统底层包，一律改用官方版本：run 包里若带同名库或内核
# 模块（实测出现过 libopenssl3、libmbedtls21），进 packages/ 后 opkg 会优先挑中它，
# 与官方 toolchain 编出的其它组件 ABI 不一致，表现为运行期缺符号或 opkg 依赖冲突。
# 只清系统层，第三方插件一律不动 —— clashoo / ssr-plus / xray-core 这些即使官方 feed
# 同名，也必须用 run 里的新版；按「官方有就删」的口径会把它们全部退回旧版。
SYS_PKG_RE='^(libc|libgcc|libopenssl[0-9]*|libmbedtls[0-9]*|libwolfssl[0-9]*|libustream-[a-z0-9]+|libjson-c[0-9]*|liblua[0-9.]*|zlib|musl[a-z0-9.+_-]*|kernel|kmod-[a-z0-9-]+|base-files)$'
for _f in "$TARGET_DIR"/*.ipk; do
  [ -e "$_f" ] || continue
  _pn=$(basename "$_f" .ipk)
  _pn=${_pn%%_*}
  if echo "$_pn" | grep -Eq "$SYS_PKG_RE"; then
    rm -f "$_f"
    echo "删除系统包（改用官方 feed 版本）: $(basename "$_f")"
  fi
done


echo "✅ 所有 .ipk 文件已整理至 $TARGET_DIR/"
