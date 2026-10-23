#!/bin/bash
# shellcheck shell=bash
#
# help2man — 一个 perl 脚本，从 --help 输出生成 man 页；flex 等的文档要用它。
BT_VERSION="1.49.3"
BT_URLS=(
    "https://ftp.gnu.org/gnu/help2man/help2man-$BT_VERSION.tar.xz"
    "https://ftpmirror.gnu.org/gnu/help2man/help2man-$BT_VERSION.tar.xz"
)
BT_SHA256="4d7e4fdef2eca6afe07a2682151cea78781e0a4e8f9622142d9f70c083a2fd4f"
BT_BUILD_DEPS="perl"

bt_build() {
    ./configure --prefix="$BT_PREFIX"
    make -j"$BT_JOBS"
    make install
}
