#!/bin/bash
# shellcheck shell=bash
#
# pkgconf —— pkg-config 的实现，也是所有配方与依赖项目 configure 都要用的自举工具。
# 它默认会往前缀里装 libpkgconf.pc / include/pkgconf/*.h / libpkgconf.a，而工具前缀
# 绝不提供库（见同目录 README），所以这里只装二进制与 pkg-config 软链。
# 也不传 --with-pc-path：可见范围永远只由 env.sh 的 PKG_CONFIG_LIBDIR 决定。
BT_VERSION="2.5.1"
BT_URLS=(
    "https://distfiles.ariadne.space/pkgconf/pkgconf-$BT_VERSION.tar.xz"
)
BT_SHA256="cd05c9589b9f86ecf044c10a2269822bc9eb001eced2582cfffd658b0a50c243"
BT_BIN="pkgconf"

bt_build() {
    ./configure --prefix="$BT_PREFIX" --disable-shared --enable-static
    make -j"$BT_JOBS"
    install -d "$BT_PREFIX/bin" "$BT_PREFIX/share/aclocal"
    install -m755 pkgconf "$BT_PREFIX/bin/pkgconf"
    ln -sf pkgconf "$BT_PREFIX/bin/pkg-config"
    # pkg.m4 也是 pkg-config 的交付物（PKG_PROG_PKG_CONFIG 等宏）。没跑
    # make install 就得手动补：纯托管宿主上没有发行版 pkg-config，依赖项目的
    # autoreconf 只能从这里的 aclocal 目录拿到它（env.sh 已把该目录放进
    # ACLOCAL_PATH）。
    install -m644 pkg.m4 "$BT_PREFIX/share/aclocal/pkg.m4"
}
