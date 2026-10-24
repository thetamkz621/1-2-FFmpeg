#!/bin/bash
# shellcheck shell=bash
#
# indent —— 个别项目的 make dist 会用它整理源码；默认图不直接调用。
BT_VERSION="2.2.13"
BT_URLS=(
    "https://ftp.gnu.org/gnu/indent/indent-$BT_VERSION.tar.xz"
    "https://ftpmirror.gnu.org/gnu/indent/indent-$BT_VERSION.tar.xz"
)
BT_SHA256="1b81ba4e9a006ca8e6eb5cbbe4cf4f75dfc1fc9301b459aa0d40393e85590a0b"

# GNU indent 的 --version 走 usage 分支、退出码是 64，不能拿来判定"装好了"；
# 用一次真实调用验证：从 stdin 读一段代码，格式化后写 stdout。
bt_check() {
    printf 'int  x;\n' | "$BT_PREFIX/bin/indent" >/dev/null 2>&1
}

bt_build() {
    ./configure --prefix="$BT_PREFIX" --disable-nls
    make -j"$BT_JOBS"
    make install
}
