#!/bin/bash
# shellcheck shell=bash
#
# texinfo — 提供 makeinfo / texi2any，man 页与 info 文档的生成都要它。BT_BIN 用
# makeinfo：包名（texinfo）和最终可执行文件名不同。
BT_VERSION="7.1.1"
BT_URLS=(
    "https://ftp.gnu.org/gnu/texinfo/texinfo-$BT_VERSION.tar.xz"
    "https://ftpmirror.gnu.org/gnu/texinfo/texinfo-$BT_VERSION.tar.xz"
)
BT_SHA256="31ae37e46283529432b61bee1ce01ed0090d599e606fc6a29dca1f77c76a6c82"
BT_BIN="makeinfo"
BT_BUILD_DEPS="perl"

bt_build() {
    ./configure --prefix="$BT_PREFIX" --disable-nls
    make -j"$BT_JOBS"
    make install
}
