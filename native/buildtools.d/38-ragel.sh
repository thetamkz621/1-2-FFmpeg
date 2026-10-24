#!/bin/bash
# shellcheck shell=bash
#
# ragel —— 状态机代码生成器，被少数依赖的 configure 探测。
BT_VERSION="6.10"
BT_URL="https://www.colm.net/files/ragel/ragel-$BT_VERSION.tar.gz"
BT_SHA256="5f156edb65d20b856d638dd9ee2dfb43285914d9aa2b6ec779dac0270cd56c3f"

bt_build() {
    ./configure --prefix="$BT_PREFIX"
    make -j"$BT_JOBS"
    make install
}
