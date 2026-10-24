#!/bin/bash
# shellcheck shell=bash
#
# autoconf — 图里大量依赖用 autotools；libmp3lame 的 AC_PREREQ 要求 2.73。
BT_VERSION="2.73"
BT_URLS=(
    "https://ftp.gnu.org/gnu/autoconf/autoconf-$BT_VERSION.tar.xz"
    "https://ftpmirror.gnu.org/gnu/autoconf/autoconf-$BT_VERSION.tar.xz"
)
BT_SHA256="9fd672b1c8425fac2fa67fa0477b990987268b90ff36d5f016dae57be0d6b52e"

bt_deps() { echo m4; }

bt_build() {
    ./configure --prefix="$BT_PREFIX"
    make -j"$BT_JOBS"
    make install
}
