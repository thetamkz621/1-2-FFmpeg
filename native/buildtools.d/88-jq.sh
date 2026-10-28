#!/bin/bash
# shellcheck shell=bash
#
# jq —— 排查构建时读 JSON（ffbuild_env_dump 之类的输出）用；oniguruma 用源码里自带的那份。
# make install 会往前缀里放 libjq.pc / 头文件 / libjq.a，而工具前缀不能提供库，
# 所以只装二进制与手册；--disable-shared 保证 jq 自己静态链上 libjq。
BT_VERSION="1.7.1"
BT_URL="https://github.com/jqlang/jq/releases/download/jq-$BT_VERSION/jq-$BT_VERSION.tar.gz"
BT_SHA256="478c9ca129fd2e3443fe27314b455e211e0d8c60bc8ff7df703873deeee580c2"

bt_build() {
    # 内置的 oniguruma 用老式函数指针，GCC 14 起 -Wincompatible-pointer-types 是
    # 默认错误（与语言标准无关），只能按需降级。
    CFLAGS="$CFLAGS -Wno-error=incompatible-pointer-types" \
        ./configure --prefix="$BT_PREFIX" --with-oniguruma=builtin --disable-shared --disable-docs
    make -j"$BT_JOBS"
    install -d "$BT_PREFIX/bin" "$BT_PREFIX/share/man/man1"
    install -m755 jq "$BT_PREFIX/bin/jq"
    install -m644 jq.1 "$BT_PREFIX/share/man/man1/jq.1"
}
