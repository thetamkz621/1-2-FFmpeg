#!/bin/bash
# shellcheck shell=bash
#
# nasm — FFmpeg 的 x86 asm 要求 >= 2.13，x264 也要它；EL8 把 nasm 放在 CRB
# （powertools）而不是 base/EPEL，没开那个仓库的宿主干脆没有汇编器。
BT_VERSION="2.16.03"
BT_URLS=(
    "https://www.nasm.us/pub/nasm/releasebuilds/$BT_VERSION/nasm-$BT_VERSION.tar.xz"
)
BT_SHA256="1412a1c760bbd05db026b6c0d1657affd6631cd0a63cddb6f73cc6d4aa616148"

bt_build() {
    ./configure --prefix="$BT_PREFIX" --disable-shared --enable-static
    make -j"$BT_JOBS"
    make install
}
