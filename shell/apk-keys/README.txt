把第三方 apk 源的签名公钥（*.pub 或 *.rsa.pub）放这个目录。
build25.sh 会自动把它们拷到 imagebuilder 的 keys/ 目录。
没有对应公钥的话，apk 会以 UNTRUSTED signature 拒绝安装该源的包。
（本目录为空时构建不受任何影响）

【2026-11-02】daeuniverse.pub 的用途变了，但文件要留着：
不再挂 openwrt.daeuniverse.org 源 —— honk 的 apk 改由 build25.sh 从
xiealon/CloudRunFilesBuilder 的 honk-apk Release 下到 packages/。
但那批 apk 仍然是 daeuniverse 私钥签名的，装进固件时 apk 会验签，
没有这个公钥就会被判 UNTRUSTED。
