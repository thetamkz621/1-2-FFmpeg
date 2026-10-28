#!/bin/bash
# shellcheck shell=bash
#
# ninja — 几十个 cmake/meson 阶段用它当后端。这里只装二进制：release 归档没有
# install 目标，configure.py --bootstrap 产出的 ./ninja 直接放进前缀。
BT_VERSION="1.12.1"
BT_URL="https://github.com/ninja-build/ninja/archive/refs/tags/v$BT_VERSION.tar.gz"
BT_SHA256="821bdff48a3f683bc4bb3b6f0b5fe7b2d647cf65d52aeb63328c91a6c6df285a"
BT_BUILD_DEPS="python3"

bt_build() {
    python3 configure.py --bootstrap
    install -d "$BT_PREFIX/bin"
    install -m755 ninja "$BT_PREFIX/bin/ninja"
}
