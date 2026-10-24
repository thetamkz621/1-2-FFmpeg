#!/bin/bash
# shellcheck shell=bash
#
# zip —— Info-ZIP，没有 configure：源码树里的 unix/Makefile 直接用。
#
# unix/Makefile 的 generic 目标会先跑 unix/configure，而它的能力探测写成
# `int main(){ rmdir(); }`（隐式声明）。GCC 14 把这种写法从警告升成错误，于是所有探测
# 都"失败"，configure 会加上 -DZMEM，与 glibc 的 memcpy/memcmp 声明冲突。把降级标志
# 塞进 CC 里（探测用的是 $CC，不是 $CFLAGS），探测就能恢复正常。
#
# 只装二进制与手册：make install 会按前缀生成一堆 man 链接，没必要。
BT_VERSION="3.0"
BT_URL="https://deb.debian.org/debian/pool/main/z/zip/zip_$BT_VERSION.orig.tar.gz"
BT_SHA256="f0e8bb1f9b7eb0b01285495a2699df3a4b766784c1765a8f1aeedf63c0806369"

bt_build() {
    make -f unix/Makefile generic CC="cc -Wno-error=implicit-function-declaration"
    install -d "$BT_PREFIX/bin" "$BT_PREFIX/share/man/man1"
    install -m755 zip "$BT_PREFIX/bin/zip"
    install -m644 man/zip.1 "$BT_PREFIX/share/man/man1/zip.1"
}
