#!/bin/bash
# shellcheck shell=bash
#
# bison — 依赖项目的语法分析器生成器（libtasn1 等）；flex 自己的 parse.y 也要它。
BT_VERSION="3.8.2"
BT_URLS=(
    "https://ftp.gnu.org/gnu/bison/bison-$BT_VERSION.tar.xz"
    "https://ftpmirror.gnu.org/gnu/bison/bison-$BT_VERSION.tar.xz"
)
BT_SHA256="9bba0214ccf7f1079c5d59210045227bcf619519840ebfa80cd3849cff5a5bf2"

bt_deps() { echo m4; }

bt_build() {
    ./configure --prefix="$BT_PREFIX" --disable-nls
    make -j"$BT_JOBS"
    make install
}
