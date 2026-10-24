#!/bin/bash
# shellcheck shell=bash
#
# zstd —— 只装命令行工具；Makefile 没有 install 之外的坑，也不需要 zlib 之类的外部库。
BT_VERSION="1.5.7"
BT_URL="https://github.com/facebook/zstd/releases/download/v$BT_VERSION/zstd-$BT_VERSION.tar.gz"
BT_SHA256="eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3"

bt_build() {
    make -j"$BT_JOBS" zstd
    install -d "$BT_PREFIX/bin"
    install -m755 programs/zstd "$BT_PREFIX/bin/zstd"
}
