#!/bin/bash
# shellcheck shell=bash
#
# cmake — 图里最高要求是 libaribcaption 的 3.28；这里装 3.31.x：
#   3.28 的 bootstrap 里 kwsys 探测程序没 include <unistd.h>，GCC 14 起不再隐式声明
#   environ，bootstrap 直接失败（3.29+ 已修）；也不上 4.x，它移除了对
#   cmake_minimum_required(<3.5) 的兼容，会踩到图里一堆老项目。
BT_VERSION="3.31.6"
BT_URL="https://github.com/Kitware/CMake/releases/download/v$BT_VERSION/cmake-$BT_VERSION.tar.gz"
BT_SHA256="653427f0f5014750aafff22727fb2aa60c6c732ca91808cfb78ce22ddd9e55f0"

bt_build() {
    # -- -DCMAKE_USE_OPENSSL=OFF：bootstrap 不该为了一份自带的 curl 去要系统的 OpenSSL
    ./bootstrap --prefix="$BT_PREFIX" --parallel="$BT_JOBS" -- -DCMAKE_USE_OPENSSL=OFF
    make -j"$BT_JOBS"
    make install
}
