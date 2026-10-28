#!/bin/bash
# shellcheck shell=bash
#
# unzip —— 与 zip 同源的 Info-ZIP，也没有 configure；generic 目标会先跑 unix/configure
# 做能力探测，而它用隐式声明写测试程序（`int main(){ chdir(); }`），GCC 14 会判成错误，
# 探测全灭 → HAVE_DIRENT_H 缺失 → DIR 被当成 FILE。降级标志塞进 CC 即可。
# unix/unxcfg.h 还把 `gmtime()`/`localtime()` 声明成无原型函数，GCC 15 的 gnu23 会把它
# 当成 `(void)` 并和 time.h 冲突，所以 CC 里同时钉住 -std=gnu17（这份 Makefile 会覆盖
# 环境里的 CFLAGS，管不到它）。
#
# unzip 不认 --version（那是 zip 的用法），用 -v 判定。
BT_VERSION="6.0"
BT_URL="https://deb.debian.org/debian/pool/main/u/unzip/unzip_$BT_VERSION.orig.tar.gz"
BT_SHA256="036d96991646d0449ed0aa952e4fbe21b476ce994abc276e49d30e686708bd37"

bt_check() {
    "$BT_PREFIX/bin/unzip" -v >/dev/null 2>&1
}

bt_build() {
    make -f unix/Makefile generic CC="cc -std=gnu17 -Wno-error=implicit-function-declaration"
    install -d "$BT_PREFIX/bin" "$BT_PREFIX/share/man/man1"
    install -m755 unzip "$BT_PREFIX/bin/unzip"
    install -m644 man/unzip.1 "$BT_PREFIX/share/man/man1/unzip.1"
}
