#!/bin/bash
# shellcheck shell=bash
#
# rsync —— popt 与 zlib 用源码树自带的；xxhash / zstd / lz4 三个可选压缩特性需要宿主的
# 开发库，而工具前缀不能提供库，所以显式关掉（基础 rsync 功能不受影响）。
BT_VERSION="3.4.1"
BT_URL="https://download.samba.org/pub/rsync/src/rsync-$BT_VERSION.tar.gz"
BT_SHA256="2924bcb3a1ed8b551fc101f740b9f0fe0a202b115027647cf69850d65fd88c52"

bt_build() {
    ./configure --prefix="$BT_PREFIX" \
        --with-included-popt --with-included-zlib \
        --disable-openssl --disable-xxhash --disable-zstd --disable-lz4
    make -j"$BT_JOBS"
    make install
}
