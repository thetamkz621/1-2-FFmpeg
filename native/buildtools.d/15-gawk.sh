#!/bin/bash
# shellcheck shell=bash
#
# gawk —— 若干 configure 走 AC_PROG_AWK 时会优先挑它；发行版的 awk 是 mawk 时行为略有差异。
BT_VERSION="5.3.2"
BT_URLS=(
    "https://ftp.gnu.org/gnu/gawk/gawk-$BT_VERSION.tar.xz"
    "https://ftpmirror.gnu.org/gnu/gawk/gawk-$BT_VERSION.tar.xz"
)
BT_SHA256="f8c3486509de705192138b00ef2c00bbbdd0e84c30d5c07d23fc73a9dc4cc9cc"

# --disable-extensions：默认会装 include/gawkapi.h 与 lib/gawk/*.so（可 dlopen 的插件），
# 工具前缀不该出现头文件与共享对象；构建脚本用不到这些扩展。
bt_build() {
    ./configure --prefix="$BT_PREFIX" --disable-nls --disable-extensions
    make -j"$BT_JOBS"
    make install
    # 即使关了扩展，install 仍会带上 gawkapi.h；工具前缀不放头文件。
    rm -rf "$BT_PREFIX/include"
}
