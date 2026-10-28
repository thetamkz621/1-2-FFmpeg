#!/bin/bash
# shellcheck shell=bash
#
# groff — 依赖的 Makefile 用 groff 排版 man 页（例如 openssl 的 provider 手册）。
# --without-x 去掉对 X 的依赖；文档用前一步装好的 makeinfo 生成。
BT_VERSION="1.23.0"
BT_URLS=(
    "https://ftp.gnu.org/gnu/groff/groff-$BT_VERSION.tar.gz"
    "https://ftpmirror.gnu.org/gnu/groff/groff-$BT_VERSION.tar.gz"
)
BT_SHA256="6b9757f592b7518b4902eb6af7e54570bdccba37a871fddb2d30ae3863511c13"

bt_deps() { echo texinfo; }

bt_build() {
    ./configure --prefix="$BT_PREFIX" --without-x
    make -j"$BT_JOBS"
    make install
}
