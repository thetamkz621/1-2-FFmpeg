#!/bin/bash
# shellcheck shell=bash
#
# yasm — 1.3.0 是 2019 年的最后一个发行版，它的 libyasm/bitvect.h 用了名为 false
# 的枚举常量，C23 下编不过（GCC 15 起默认 C23）。上游此后没有发版，所以固定到一个
# 已修好的 commit；commit 归档没有 configure，需要 autogen.sh 现场生成。
BT_VERSION="09d1bc90ed53d0ec3e9b074f111058cbf262ed56"
BT_URL="https://github.com/yasm/yasm/archive/$BT_VERSION.tar.gz"
BT_SHA256="5908256a2db37ca6f6b60025ee2a4a81a52ff8588e08776ce37c2551f00ab2e0"

bt_deps() { echo automake autoconf; }

bt_build() {
    ./autogen.sh --prefix="$BT_PREFIX"

    # 先把三个生成文件串行做完：modules/arch/x86/Makefile.inc 把
    # x86insn_nasm.gperf / x86insn_gas.gperf / x86insns.c 写成一个三输出的非模式规则，
    # GNU make 会当成三条独立规则并行执行同一个 gen_x86_insn.py，genperf 读到被
    # 截断的 .gperf 就报 "no keywords section found"，且是时序相关的偶发失败。
    make -j1 x86insn_nasm.gperf x86insn_gas.gperf x86insns.c
    make -j"$BT_JOBS"
    make install
}
