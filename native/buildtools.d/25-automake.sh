#!/bin/bash
# shellcheck shell=bash
#
# automake — 除了裸名，还要提供 automake-1.18 / aclocal-1.18 这两个版本名：
# libiconv 的 Makefile.devel 写死了它们（Arch 的 automake 1.19 就没有）。
BT_VERSION="1.18.1"
BT_URLS=(
    "https://ftp.gnu.org/gnu/automake/automake-$BT_VERSION.tar.xz"
    "https://ftpmirror.gnu.org/gnu/automake/automake-$BT_VERSION.tar.xz"
)
BT_SHA256="168aa363278351b89af56684448f525a5bce5079d0b6842bd910fdd3f1646887"

bt_deps() { echo autoconf; }

bt_build() {
    ./configure --prefix="$BT_PREFIX"
    make -j"$BT_JOBS"
    make install
}
