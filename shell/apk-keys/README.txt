把第三方 apk 源的签名公钥（*.pub 或 *.rsa.pub）放这个目录。
build25.sh 会自动把它们拷到 imagebuilder 的 keys/ 目录。
没有对应公钥的话，apk 会以 UNTRUSTED signature 拒绝安装该源的包。
（本目录为空时构建不受任何影响）

【2026-11-03】25.12 线改回 daed 后，daed 五件套（daed / daed-geoip /
daed-geosite / luci-app-daed / luci-i18n-daed-zh-cn）全部来自 25.12.2
官方源，由官方仓库公钥签名，不走本目录。

【2026-11-05】daeuniverse.pub 是硬依赖，不许删：
xiealon/apk 的 run/x86 里那批 apk（partexp / rtp2httpd / clashoo / taskplan
等）是 daeuniverse 私钥签的名。build25.sh 第 275-279 行把它拷进 IB 的
keys/，apk index 和 make image 装包才不报 UNTRUSTED。
同一份公钥还会 overlay 进固件的 /etc/apk/keys/，刷机后 apk add 免 --allow-untrusted。
删了的后果：
  1) 构建时这批包验签失败，make image 报 ERROR: xxx: UNTRUSTED signature；
  2) 固件里没有公钥，手动装 run 包必须带 --allow-untrusted。
build25.sh 里有三处断言（shell/apk-keys/、keys/、files/etc/apk/keys/），
任一缺失直接 ::error:: 中止，不会再静默放过。
