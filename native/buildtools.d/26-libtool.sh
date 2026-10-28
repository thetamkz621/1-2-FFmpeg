#!/bin/bash
# shellcheck shell=bash
#
# libtool — 提供 libtoolize / aclocal 宏 / ltdl。只建静态：依赖里没有需要共享
# libltdl 的场景，而前缀里多一份 .so 只会增加被误检出的机会。
BT_VERSION="2.5.4"
BT_URLS=(
    "https://ftp.gnu.org/gnu/libtool/libtool-$BT_VERSION.tar.xz"
    "https://ftpmirror.gnu.org/gnu/libtool/libtool-$BT_VERSION.tar.xz"
)
BT_SHA256="f81f5860666b0bc7d84baddefa60d1cb9fa6fceb2398cc3baca6afaa60266675"

bt_deps() { echo m4; }

bt_build() {
    ./configure --prefix="$BT_PREFIX" --enable-static --disable-shared
    make -j"$BT_JOBS"
    make install
}
