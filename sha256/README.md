# 25.12.2 x86-64 产物校验

本目录只放校验文件，不含产物本体。产物在：
https://github.com/xiealon/immortalwrt-artifacts/releases

## 对应 release

| 用途 | tag | 产物文件名 |
|---|---|---|
| ImageBuilder | `v25.12.2-ib-x86-64-r2` | `immortalwrt-imagebuilder-25.12.2-x86-64.Linux-x86_64.tar.zst` |
| 包集合 | `v25.12.2-pkg-x86-64-r2` | `packages-x86_64-25.12.2.tar.zst` |
| 固件 | `v25.12.2-fw-x86-64-r2` | `*-generic-kernel.bin` / `*-squashfs-combined*.img.gz` |

## 文件说明

- `sha256sums` —— 构建产物的完整清单，1,336 行，含镜像、kernel.bin、ImageBuilder tar
- `packages-tar.sha256` —— `packages-x86_64-25.12.2.tar.zst` 的 hash。这一行**不在** `sha256sums` 里，因为 tar 是构建完成后另外打的

## 怎么核对

下载产物后：

```sh
sha256sum -c sha256sums --ignore-missing
```

只查某一个：

```sh
grep imagebuilder sha256sums | sha256sum -c -
```

查 packages tar：

```sh
sha256sum -c packages-tar.sha256
```

## workflow 硬编码的两个值

`ImmortalWrt-ImageBuilder-25.12-honk` 的 `build-x86-64-25.12.x.yml` 第 378、412 行写死了：

```
IB_SHA=73abe42d053fbc5a261235c08142704cdc253ff9e05ea7b9e0e2cb5e75b312e8
PKG_SHA=7af7a3a914ae3876e32890150c7bf001a80d160a0ee6769796fc25669478c1a4
```

这两个值必须与本体一致，换产物时要同步改，否则 CI 会在 sha256sum -c 那步红。

## 内核

kernel 6.12.103，kernel hash `26ed6bc1347f7e9e86ff98fe27513539`。

## 采集时间

2026-11-05 05:21（Asia/Shanghai）
