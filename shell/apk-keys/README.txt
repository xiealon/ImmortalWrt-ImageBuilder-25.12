把第三方 apk 源的签名公钥（*.pub 或 *.rsa.pub）放这个目录。
build25.sh 会自动把它们拷到 imagebuilder 的 keys/ 目录。
没有对应公钥的话，apk 会以 UNTRUSTED signature 拒绝安装该源的包。
（本目录为空时构建不受任何影响）

【2026-11-03】25.12 线改回 daed 后，本目录已无实际用途：
daed 五件套（daed / daed-geoip / daed-geosite / luci-app-daed /
luci-i18n-daed-zh-cn）全部来自 25.12.2 官方源，由官方仓库公钥签名，
不再需要第三方源公钥；honk 那条 CloudRunFilesBuilder Release 的路径已整条移除。
daeuniverse.pub 留着无害（拷进 keys/ 不参与任何包验签），也可以直接删掉。
