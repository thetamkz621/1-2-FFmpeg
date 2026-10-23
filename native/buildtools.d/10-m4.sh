#!/bin/bash
# shellcheck shell=bash
#
# m4 — autoconf 的运行时依赖，也是整个工具链的根。
BT_VERSION="1.4.21"
BT_URLS=(
    "https://ftp.gnu.org/gnu/m4/m4-$BT_VERSION.tar.xz"
    "https://ftpmirror.gnu.org/gnu/m4/m4-$BT_VERSION.tar.xz"
)
BT_SHA256="f25c6ab51548a73a75558742fb031e0625d6485fe5f9155949d6486a2408ab66"

bt_build() {
    ./configure --prefix="$BT_PREFIX"
    make -j"$BT_JOBS"
    make install
}
