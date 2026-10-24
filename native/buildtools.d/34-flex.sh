#!/bin/bash
# shellcheck shell=bash
#
# flex — 词法分析器生成器（libtasn1、libpcap 系的 configure 会找它）。
BT_VERSION="2.6.4"
BT_URL="https://github.com/westes/flex/releases/download/v$BT_VERSION/flex-$BT_VERSION.tar.gz"
BT_SHA256="e87aae032bf07c26f85ac0ed3250998c37621d95f8bd748b31f15b33c45ee995"

bt_deps() { echo bison help2man; }

bt_build() {
    ./configure --prefix="$BT_PREFIX" --disable-shared
    make -j"$BT_JOBS"
    make install
}
