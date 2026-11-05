#!/bin/bash
# shellcheck shell=bash
#
# gettext — 主要为了 autopoint：zvbi 的 configure.ac 声明 AM_GNU_GETTEXT_VERSION([0.21])，
# 低于它 autopoint 直接拒绝运行（EL8 只有 0.19.8）。顺带提供 msgfmt/msgmerge。
BT_VERSION="0.22.5"
BT_URLS=(
    "https://ftp.gnu.org/gnu/gettext/gettext-$BT_VERSION.tar.xz"
    "https://ftpmirror.gnu.org/gnu/gettext/gettext-$BT_VERSION.tar.xz"
)
BT_SHA256="fe10c37353213d78a5b83d48af231e005c4da84db5ce88037d88355938259640"

bt_build() {
    # GCC 15 将 iconv 探测中的 incompatible-pointer-types 视为错误，configure 因此
    # 判定 HAVE_ICONV=0，并启用参数个数不匹配的 stub。仅对本配方降级该诊断。
    export CFLAGS="$CFLAGS -Wno-error=incompatible-pointer-types"
    ./configure --prefix="$BT_PREFIX" --disable-shared --disable-java --disable-csharp
    make -j"$BT_JOBS"
    make install
}
