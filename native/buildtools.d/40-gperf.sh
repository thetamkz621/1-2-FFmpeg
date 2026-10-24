#!/bin/bash
# shellcheck shell=bash
#
# gperf — 若干依赖的 configure 会优先用它生成完美哈希表（libunibreak 等）。
BT_VERSION="3.1"
BT_URLS=(
    "https://ftp.gnu.org/gnu/gperf/gperf-$BT_VERSION.tar.gz"
    "https://ftpmirror.gnu.org/gnu/gperf/gperf-$BT_VERSION.tar.gz"
)
BT_SHA256="588546b945bba4b70b6a3a616e80b4ab466e3f33024a352fc2198112cdbb3ae2"

bt_build() {
    ./configure --prefix="$BT_PREFIX"
    make -j"$BT_JOBS"
    make install
}
