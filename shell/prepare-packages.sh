#!/bin/sh

BASE_DIR="extra-packages"
TEMP_DIR="$BASE_DIR/temp-unpack"
TARGET_DIR="packages"

# 【v.182】clashoo 不再在这里单独 wget。
#   x86-64/build24.sh / build25.sh 已从 CloudRunFilesBuilder release 全量下载固定名 .run
#   （extra-ipk / extra-apk 里都含 clashoo_x86_64.run），这里再下一次是同名覆盖，
#   白拉 17 MB；更糟的是第二次下载失败会 exit 1 掐断整条构建，而文件其实已经到手。
#   本脚本职责收窄为：解压 extra-packages/*.run + 归并到 packages/。

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

echo "✅ 所有 .ipk 文件已整理至 $TARGET_DIR/"
