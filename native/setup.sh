#!/bin/bash
# shellcheck shell=bash
#
# native/setup.sh — Provision the host for Docker-free linux64 builds.
#
# This is the native equivalent of images/base/Dockerfile + base-linux64/Dockerfile:
# it installs build prerequisites and plants the few root-level helper files that
# upstream stage scripts reference by absolute path.
#
# Usage:
#   ./native/setup.sh                 # provision the host (packages printed unless --install)
#   ./native/setup.sh --all           # include the optional upstream packages in the list
#   ./native/setup.sh --with-ctng     # additionally build the crosstool-ng toolchain
#   ./native/setup.sh --with-ctng --force-ctng   # rebuild an existing toolchain
#   ./native/setup.sh --with-ctng --ctng-target win64   # toolchain for another target
#   ./native/setup.sh --with-ctng --keep-ctng-src  # keep the ct-ng build tree (several GB)
#   ./native/setup.sh --install       # install the packages (default: print the command)
#   ./native/setup.sh --no-install    # skip the package step entirely (managed externally)
#   ./native/setup.sh --buildtools-only  # only build the managed build tools, touch nothing else
#   ./native/setup.sh --with-tools=a,b   # build these build tools even if only some are missing
#   ./native/setup.sh --no-managed-tools # do not build tools; use whatever the host provides
#   ./native/setup.sh --check         # only verify what is present
#   ./native/setup.sh --print-packages     # print this distro's install command and exit
#   ./native/setup.sh --print-packages=all # ... including the --all extras
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# env.sh is sourced only after the distro packages are in place: it aborts when
# no C compiler can be resolved, and on a bare host that compiler is one of the
# packages this script installs. See the "package install" section below.

DO_CHECK=0
DO_ALL=0
WITH_CTNG=0
FORCE_CTNG=0
KEEP_CTNG_SRC=0
DO_INSTALL=0
NO_INSTALL=0
PRINT_PKGS=0
PRINT_PKGS_ALL=0
ONLY_BUILDTOOLS=0
NO_MANAGED_TOOLS=0
WITH_TOOLS=""
# Target whose ctng toolchain is built and checked. The per-target details
# (triple, config file, pruning style) come from native/targets/<target>.conf.
CTNG_TARGET="${FFBUILD_TARGET:-linux64}"

while [[ $# -gt 0 ]]; do
    case "$1" in
    --check)      DO_CHECK=1 ;;
    --all)        DO_ALL=1 ;;
    --with-ctng)  WITH_CTNG=1 ;;
    --force-ctng) FORCE_CTNG=1 ;;
    --keep-ctng-src) KEEP_CTNG_SRC=1 ;;
    --ctng-target) CTNG_TARGET="${2:?--ctng-target needs a value}"; shift ;;
    --install)    DO_INSTALL=1 ;;
    --no-install) NO_INSTALL=1 ;;
    --print-packages)     PRINT_PKGS=1 ;;
    --print-packages=all) PRINT_PKGS=1; PRINT_PKGS_ALL=1 ;;
    --buildtools-only) ONLY_BUILDTOOLS=1 ;;
    --no-managed-tools) NO_MANAGED_TOOLS=1 ;;
    --with-tools=*)      WITH_TOOLS="${1#*=}" ;;
    --with-tools)        WITH_TOOLS="${2:-}"; shift ;;
    -h|--help)    sed -n '/^# Usage:/,/^#$/p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "setup.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
    shift
done

# env.sh resolves the target from FFBUILD_TARGET. Export it before any package
# list is assembled: a Windows target needs wine, a Linux one does not.
export FFBUILD_TARGET="$CTNG_TARGET"

# ---------------------------------------------------------------- sudo --------
if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=()
    # 容器里 root 是常态，不拦；但 .buildtools/ 与 ffbuild/ 会归 root，之后普通用户
    # 再跑会撞权限错误（编译工具时表现为莫名其妙的 "C compiler" 失败）。
    if [[ "$DO_CHECK" -eq 0 && "$PRINT_PKGS" -eq 0 ]]; then
        echo "WARNING: running as root: .buildtools/ and ffbuild/ will be owned by root," >&2
        echo "         and a later run as a normal user will fail on permissions." >&2
        echo "         Run this script as your own user; sudo is only used to install packages." >&2
    fi
else
    SUDO=(sudo)
    if ! command -v sudo >/dev/null 2>&1; then
        echo "setup.sh: sudo is required (or run as root)" >&2; exit 1
    fi
fi

asroot() { "${SUDO[@]}" "$@"; }

# ------------------------------------------------------------- pkg manager ----
# 只在这一步决定"能不能代装"和"给用户哪条命令"。包名与发行版强相关，写死在代码里
# 必然腐坏（Fedora 44 没有 wget，EL8 的 nasm/ocaml 在 powertools，EL8 的 python
# 只有 3.6），所以映射表单独放在 pkgdeps.conf，这里只负责读取与探测。
PKG_MGR=""
for _pm in apt-get dnf pacman zypper; do
    if command -v "$_pm" >/dev/null 2>&1; then PKG_MGR="$_pm"; break; fi
done
unset _pm

PKGDEPS_CONF="$HERE/pkgdeps.conf"

# dnf 还要再分一层：RHEL 8 系的仓库布局与 Fedora 不同（powertools、openssl3-devel、
# python3.12）。按 ID/ID_LIKE 认，认不出的当 Fedora 处理。
pkg_flavor() {
    case "$PKG_MGR" in
        apt-get) echo apt ; return 0 ;;
        pacman)  echo pacman ; return 0 ;;
        zypper)  echo zypper ; return 0 ;;
        dnf)     ;;
        *)       echo none ; return 0 ;;
    esac
    local id="" like="" ver="" k v
    if [[ -r /etc/os-release ]]; then
        while IFS='=' read -r k v; do
            v="${v%\"}"; v="${v#\"}"
            case "$k" in
                ID)         id="$v" ;;
                ID_LIKE)    like="$v" ;;
                VERSION_ID) ver="$v" ;;
            esac
        done </etc/os-release
    fi
    unset k v
    case " $id $like " in
        *" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*|*" ol "*)
            case "$ver" in 8|8.*) echo dnf-el8; return 0 ;; esac ;;
    esac
    echo dnf
}
PKG_FLAVOR="$(pkg_flavor)"

# pkgdeps_row <capability> -> 映射表里对应的整行
pkgdeps_row() {
    local key="$1" line first
    [[ -r "$PKGDEPS_CONF" ]] || return 1
    while IFS= read -r line; do
        [[ "$line" == *"|"* ]] || continue
        first="${line%%|*}"
        first="${first#"${first%%[![:space:]]*}"}"
        first="${first%"${first##*[![:space:]]}"}"
        [[ "$first" == "$key" ]] || continue
        printf '%s\n' "$line"
        return 0
    done <"$PKGDEPS_CONF"
    return 1
}

# 提示里用的发行版称呼，别再重复一遍包管理器名字
pkg_flavor_name() {
    case "$PKG_FLAVOR" in
        apt)     echo "Debian/Ubuntu" ;;
        dnf)     echo "Fedora / EL9+" ;;
        dnf-el8) echo "RHEL 8 family" ;;
        pacman)  echo "Arch" ;;
        zypper)  echo "openSUSE" ;;
        *)       echo "unknown" ;;
    esac
}

pkgdeps_col() {
    case "$PKG_FLAVOR" in
        apt)    echo 2 ;;
        dnf)    echo 3 ;;
        dnf-el8) echo 4 ;;
        pacman) echo 5 ;;
        zypper) echo 6 ;;
        *)      echo 2 ;;
    esac
}

# pkg_deps <capability> -> 当前发行版该装的包名（空格分隔，可能为空）
pkg_deps() {
    local row col out
    if ! row="$(pkgdeps_row "$1")"; then
        echo "pkgdeps.conf: no row for capability '$1'" >&2
        return 0
    fi
    col="$(pkgdeps_col)"
    out="$(printf '%s\n' "$row" | awk -F'|' -v c="$col" '{print $c; exit}')"
    out="${out#"${out%%[![:space:]]*}"}"
    out="${out%"${out##*[![:space:]]}"}"
    [[ "$out" == "-" ]] && out=""
    printf '%s\n' "$out"
}

# RHEL 8 系把 ocaml / nasm / ninja-build 放在 powertools。--enablerepo 只对本次
# 事务生效，不改用户的仓库配置。
DNF_REPO_ARGS=()
if [[ "$PKG_FLAVOR" == dnf-el8 ]] &&
   dnf -q repolist --all 2>/dev/null | awk '{print $1}' | grep -qx powertools; then
    DNF_REPO_ARGS=(--enablerepo=powertools)
fi
# 核心清单不依赖 EPEL：cargo-c 在系统 OpenSSL 过旧时改用 vendored 构建。
# 只有 --all 的 p7zip、lcov 来自 EPEL，而新装 EL8 默认没有启用 EPEL，此时整条
# dnf 事务会因找不到这两个包而失败。探测只看本地已启用仓库，不联网；探测失败
# 按"未启用"处理——多执行一次 epel-release 安装是无害的 no-op。
NEED_EPEL=0
if [[ "$PKG_FLAVOR" == dnf-el8 ]] && (( PRINT_PKGS_ALL || DO_ALL )) &&
   ! dnf -q repolist --enabled 2>/dev/null | awk '{print $1}' | grep -qx epel; then
    NEED_EPEL=1
fi
# Fedora 默认安装弱依赖（Recommends）。ant 的 JDK 绑定会 Recommends 完整 JDK，完整
# JDK 又 Recommends gtk3，再经 gdk-pixbuf2 → glycin → libheif → libheif-ffmpeg 拉进
# ffmpeg-free 全家（实测 789 包 / 642 MiB，关掉后 481 包 / 473 MiB）。构建宿主只认
# 显式清单；apt 侧早就用 --no-install-recommends，这里对齐。
DNF_INSTALL_ARGS=()
if [[ "$PKG_MGR" == dnf ]]; then
    DNF_INSTALL_ARGS=("${DNF_REPO_ARGS[@]}" --setopt=install_weak_deps=False)
fi

# pkg_cmd <capability> -> 一行可直接粘贴的安装命令
pkg_cmd() {
    local pkgs
    pkgs="$(pkg_deps "$1")"
    if [[ -z "$pkgs" ]]; then
        echo "(nothing to install)"
        return 0
    fi
    # shellcheck disable=SC2086  # 包名列表就是空格分隔的
    pkg_cmd_for $pkgs
}

# tool_hint <tool> -> 单个缺失工具的安装命令
tool_hint() {
    case "$1" in
        gcc|g++|make|patch|libtoolize) pkg_cmd toolchain ;;
        ninja)      pkg_cmd ninja ;;
        pkg-config) echo "./native/setup.sh (managed) or $(pkg_cmd pkgconf)" ;;
        svn)        pkg_cmd subversion ;;
        nasm)       pkg_cmd nasm ;;
        zip)        pkg_cmd zip ;;
        tar)        pkg_cmd archivers ;;
        xz)         pkg_cmd archivers ;;
        git)        pkg_cmd git ;;
        yasm)       pkg_cmd yasm ;;
        cmake)      pkg_cmd cmake ;;
        python3)    pkg_cmd python ;;
        texinfo|makeinfo) pkg_cmd texinfo ;;
        unzip)      pkg_cmd unzip ;;
        ant)        pkg_cmd java_ant ;;
        openssl3-devel|openssl-devel|libssl-dev) pkg_cmd openssl_dev ;;
        ocaml)      pkg_cmd ocaml ;;
        clang)      pkg_cmd clang ;;
        libatomic)  pkg_cmd libatomic ;;
        xxd)        pkg_cmd xxd ;;
        curl)       pkg_cmd curl ;;
        wget)       pkg_cmd wget ;;
        wine)       pkg_cmd wine ;;
        qemu-*)     pkg_cmd qemu_user ;;
        file|bzip2|gzip) pkg_cmd ctng_host ;;
        *)          echo "install it with your package manager (README §2.1)" ;;
    esac
}

# Managed-build failures are collected here so the run can end with a real status
# instead of "setup complete" while required tools are missing.
SETUP_FAILURES=()
note_failure() { SETUP_FAILURES+=("$1"); }

# Version probe that is safe under `set -e`: a tool this script is about to
# install is by definition absent on a fresh host, and a bare
# `$(missing --version)` would abort setup with status 127 before the code
# that installs it ever runs.
probe_version() {
    local out=""
    out="$("$@" 2>/dev/null | sed -n '1p')" || out=""
    printf '%s\n' "$out"
}

# Version comparison used by both --check and the install sections.
version_ge() {  # $1 >= $2 (version sort)
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | sed -n '1p')" == "$2" ]]
}

# target_conf_get <target> <variable> -> native/targets/<target>.conf 中的值
# Runs in a subshell so the caller's environment is untouched.
target_conf_get() {
    local t="$1" v="$2" f="$HERE/targets/$1.conf"
    [[ -r "$f" ]] || return 1
    (
        set +u
        # shellcheck source=/dev/null
        . "$f"
        eval "printf '%s' \"\${$v:-}\""
    )
}

# cargo-c is a host tool, so probe the system OpenSSL rather than the FFmpeg
# prefix. An empty result also covers a missing pkg-config or development files.
system_openssl_version() {
    local sys_pc="/usr/lib64/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
    local triple
    triple="$("${CC:-cc}" -dumpmachine 2>/dev/null || true)"
    [[ -n "$triple" ]] && sys_pc="/usr/lib/$triple/pkgconfig:$sys_pc"
    PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$sys_pc" \
        pkg-config --modversion openssl 2>/dev/null || true
}

# --------------------------------------------------------------- packages -----
# 装什么由 pkgdeps.conf 决定；这里只声明"默认图需要哪些能力"和"--all 额外给哪些"。
# 默认图 = linux64 gpl；其余 target/variant 尚未全部跑通，上游镜像带的东西保持
# 在 --all 一侧，别因为今天的默认图用不到就把它们删掉。
PKG_KEYS_CORE=(
    # 自举根：没有这些就什么都编不了
    toolchain zlib_dev openssl_dev pkgconf
    # 网络与归档
    git curl wget ca_certificates archivers
    # configure 脚本依赖：libvpx 用 which 找汇编器；gettext 的 iconv 探测需要
    # EUC-JP 转换器（部分发行版把 gconv 模块拆包）
    which iconv_modules
    # Python 运行时：构建期模块由 venv 提供，发行版只管解释器与建 venv 的部件
    python
    # --enable-cuda-llvm：configure 把 nvcc 默认成 clang
    clang
    # 默认图要 OCaml（fftw3 的 genfft）与 Java + ant（libbluray 的 BD-J）
    ocaml java_ant
    # lame / xvid 两个 stage 走 svn checkout
    subversion
    # 托管构建工具自建，但编它们要用 perl 核心模块
    perl_core
)

# Windows targets run target binaries during meson setup; wine is only needed
# there, so it must not join the default Linux package set.
if [[ "$(target_conf_get "$CTNG_TARGET" FFBUILD_TARGET_WINE)" == 1 ]]; then
    PKG_KEYS_CORE+=(wine)
fi
# Linux targets on another architecture are verified through qemu-user; the
# build itself does not execute target programs, so this is a runtime tool
# rather than a build dependency.
if [[ -n "$(target_conf_get "$CTNG_TARGET" FFBUILD_TARGET_EMULATOR)" ]]; then
    PKG_KEYS_CORE+=(qemu_user)
fi
# ct-ng's own configure requires file, bzip2 and gzip; they are only needed
# when the toolchain is built.
if (( WITH_CTNG )); then
    PKG_KEYS_CORE+=(ctng_host)
fi
PKG_KEYS_EXTRA=(
    # 上游镜像有、当前默认图用不到；--all 时装上
    p7zip bsdtar xxd libxml2_tools mercurial
    # 上游与 clang/llvm 同组：覆盖率、交叉产物试运行、32 位目标的多架构
    lcov lld qemu_user multilib
    # 自建 libtool 只装 libtool / libtoolize，ltdl 头文件仍由发行版提供
    libltdl
    # install-doc 的 HTML 通道；缺了 build.sh 只告警
    texi2html
    # 上游装 nodesource 的 nodejs 与 python3-apt；仓库内零引用，保持能力对齐
    python3_apt nodejs
    gtk_doc gobject_introspection itstool
)

# zypper 的 search --match-exact 只认包名：python3-pip、java-devel、ocamlbuild
# 这类只以 provides 存在的名字会被误判成缺包，所以改用 --provides；104 才是
# "确实没有"，其它错误（元数据没缓存、锁冲突）一律当"无法判断"，别把包丢掉。
_ZYP_HAS_META=""
zypper_metadata_ready() {
    if [[ -z "$_ZYP_HAS_META" ]]; then
        if zypper --quiet --no-refresh search -x --provides filesystem >/dev/null 2>&1; then
            _ZYP_HAS_META=1
        else
            _ZYP_HAS_META=0
        fi
    fi
    [[ "$_ZYP_HAS_META" == 1 ]]
}

# pkg_available <pkg> -> 0 可用 / 1 该发行版没有 / 2 无法判断（元数据未就绪）
#
# dnf 用 --whatprovides 而不是 list：Fedora 44 已经没有 zlib-devel 这个包，它由
# zlib-ng-compat-devel 提供；按包名查会误判成"没有"。--cacheonly 保证这一步不
# 触网；缓存不存在时返回 2，让调用方把包原样交给包管理器去判断。
pkg_available() {
    local pkg="$1" out
    case "$PKG_MGR" in
    apt-get)
        apt-cache show "$pkg" >/dev/null 2>&1
        ;;
    dnf)
        if rpm -q "$pkg" >/dev/null 2>&1; then return 0; fi
        out="$(dnf -q --cacheonly "${DNF_REPO_ARGS[@]}" repoquery --available --whatprovides "$pkg" 2>/dev/null)" || return 2
        [[ -n "$out" ]]
        ;;
    pacman)
        if pacman -Q "$pkg" >/dev/null 2>&1; then return 0; fi
        pacman -Si "$pkg" >/dev/null 2>&1
        ;;
    zypper)
        if rpm -q "$pkg" >/dev/null 2>&1; then return 0; fi
        zypper_metadata_ready || return 2
        local zrc=0
        zypper --quiet --no-refresh search -x --provides "$pkg" >/dev/null 2>&1 || zrc=$?
        case $zrc in
            0)   return 0 ;;
            104) return 1 ;;
            *)   return 2 ;;
        esac
        ;;
    *)
        return 2
        ;;
    esac
}

# pkg_expand -> 选中的能力展开成包名（去重，保持声明顺序）
pkg_expand() {
    local k p
    local -A seen=()
    local -a out=()
    for k in "${PKG_KEYS_CORE[@]}"; do
        # 包名列表就是空格分隔的，这里要的正是分词
        # shellcheck disable=SC2046
        for p in $(pkg_deps "$k"); do
            [[ -n "${seen[$p]:-}" ]] && continue
            seen[$p]=1; out+=("$p")
        done
    done
    if (( PRINT_PKGS_ALL || DO_ALL )); then
        for k in "${PKG_KEYS_EXTRA[@]}"; do
            # shellcheck disable=SC2046
            for p in $(pkg_deps "$k"); do
                [[ -n "${seen[$p]:-}" ]] && continue
                seen[$p]=1; out+=("$p")
            done
        done
    fi
    ((${#out[@]})) && printf '%s\n' "${out[@]}"
    return 0
}

# pkg_plan <pkg...> -> 可整段粘贴的安装计划：EPEL 前置（EL8 的 --all 且未启用时）
# 与主命令
pkg_plan() {
    (($#)) || return 0
    if (( NEED_EPEL )); then
        echo "# EL8 packages p7zip and lcov (--all extras) in EPEL, which is not enabled on this host:"
        echo "dnf install -y epel-release"
    fi
    pkg_cmd_for "$@"
}

# pkg_cmd_for <pkg...> -> 一行可直接粘贴的安装命令
pkg_cmd_for() {
    (($#)) || return 0
    case "${PKG_MGR:-none}" in
        apt-get) printf 'apt-get install -y --no-install-recommends %s\n' "$*" ;;
        dnf)     printf 'dnf install -y %s %s\n' "${DNF_INSTALL_ARGS[*]}" "$*" ;;
        pacman)  printf 'pacman -S --needed %s\n' "$*" ;;
        zypper)  printf 'zypper install --no-recommends %s\n' "$*" ;;
        *)       printf '%s\n' "$*" ;;
    esac
}

if [[ "$PRINT_PKGS" -eq 1 ]]; then
    mapfile -t _print_pkgs < <(pkg_expand)
    if ((${#_print_pkgs[@]} == 0)); then
        echo "# no packages needed for $PKG_FLAVOR (${PKG_MGR:-unknown})"
        exit 0
    fi
    pkg_plan "${_print_pkgs[@]}"
    exit 0
fi

# ------------------------------------------------------- managed tool pins -----
# 这些不是"能自建的工具"，而是版本/来源常量：
#   * python：只检查版本，不构建（venv 用它）
#   * meson ：pin 在 venv 里
#   * opam  ：预编译静态二进制，给缺 OCaml 的宿主兜底
FFBUILD_BT_SYSTEM_python="${FFBUILD_BT_SYSTEM_python:-3.10}"
FFBUILD_BT_MESON="${FFBUILD_BT_MESON:-1.12.1}"
FFBUILD_BT_INSTALL_opam="${FFBUILD_BT_INSTALL_opam:-2.6.1}"
FFBUILD_BT_URL_opam="${FFBUILD_BT_URL_opam:-https://github.com/ocaml/opam/releases/download/2.6.1/opam-2.6.1-x86_64-linux}"
FFBUILD_BT_SHA256_opam="${FFBUILD_BT_SHA256_opam:-b533d393a6967150d6ef41cb3d71e147e93ecbabeb59e921aa412c0ae79ebe3d}"
FFBUILD_BT_OCAML_COMPILER="${FFBUILD_BT_OCAML_COMPILER:-ocaml-base-compiler.4.14.3}"

# ------------------------------------------------------------- check mode -----
# autoconf / automake / cmake 不在此列：它们可能是 setup 自己构建的托管版本，
# 由下面的 "build tools" 表按版本下限判定；meson 由 venv 提供，也不在系统工具之列。
REQUIRED_TOOLS=(gcc g++ make git patch svn tar xz python3 gen-implib git-mini-clone retry-tool)
OPTIONAL_TOOLS=(node 7z xxd)

do_check() {
    local missing=() t
    for t in "${REQUIRED_TOOLS[@]}"; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    echo "== required tools =="
    for t in "${REQUIRED_TOOLS[@]}"; do
        if command -v "$t" >/dev/null 2>&1; then
            printf '  [ok]      %-14s %s\n' "$t" "$(command -v "$t")"
        else
            printf '  [MISSING] %-14s %s\n' "$t" "$(tool_hint "$t")"
        fi
    done
    echo "== build tools (source-built into $FFBUILD_BUILDTOOLS_PREFIX) =="
    bt_missing=0
    if (( NO_MANAGED_TOOLS )); then
        printf '  %-9s skipped (--no-managed-tools)\n' "(all)"
    elif ! "$FFBUILD_REPO_ROOT/native/buildtools.sh" --check; then
        bt_missing=1
        echo "              -> run ./native/setup.sh to build the missing ones"
    fi
    # 这一项要报告的是"宿主自带的解释器"，但 env.sh 把构建 venv 的 bin 放在了
    # PATH 最前：直接 command -v 会命中 venv 里的 python3，于是把 venv 当成系统
    # 解释器（宿主的 python3 缺失也看不出来）。先把该目录从 PATH 摘掉再找。
    local py_bin py_ver py_sys _p
    local -a _pp
    local _sys_path=""
    py_bin=""
    py_ver=""
    py_sys=""
    IFS=: read -r -a _pp <<<"$PATH"
    for _p in "${_pp[@]}"; do
        [[ "$_p" == "$FFBUILD_PYTHON_PREFIX/bin" ]] && continue
        _sys_path+="${_sys_path:+:}$_p"
    done
    for _c in python3.13 python3.12 python3.11 python3.10 python3; do
        py_bin="$(PATH="$_sys_path" command -v "$_c" 2>/dev/null || true)"
        [[ -n "$py_bin" ]] || continue
        _v="$("$py_bin" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
        [[ -n "$_v" ]] || continue
        if version_ge "$_v" "$FFBUILD_BT_SYSTEM_python"; then py_sys="$py_bin"; py_ver="$_v"; break; fi
        py_bin=""
    done
    unset _v _c _p _pp _sys_path
    if [[ -n "$py_sys" ]]; then
        printf '  %-9s system=%-8s min=%-7s ok (%s)\n' python "$py_ver" "$FFBUILD_BT_SYSTEM_python" "$py_sys"
    else
        printf '  %-9s system=%-8s min=%-7s NEEDS INSTALL\n' python "${py_ver:-none}" "$FFBUILD_BT_SYSTEM_python"
    fi
    printf '  managed root: %s\n' "$FFBUILD_BUILDTOOLS_PREFIX"
    echo

    echo "== runtime prerequisites (not managed; install from your distro) =="
    rt_ok()      { printf '  [ok]      %s\n' "$1"; }
    # [warn] 只提示：不阻断构建，也不影响退出码。用于"不满足也能构建，但产物或
    # 可选能力会受影响"的情况。
    rt_warn() {
        printf '  [warn]    %s\n              %s\n' "$1" "$2"
        return 0
    }
    rt_blocking=0
    rt_missing() {
        printf '  [MISSING] %s\n              %s\n' "$1" "$2"
        rt_blocking=1
    }

    # 编译器由 FFBUILD_TOOLCHAIN_MODE 选择（host 自动探测）；这里只报告解析结果。
    if command -v "$CC" >/dev/null 2>&1 && command -v "$CXX" >/dev/null 2>&1; then
        rt_ok "compiler $FFBUILD_COMPILER ($CC / $CXX)"
    else
        rt_missing "compiler $CC / $CXX (mode $FFBUILD_TOOLCHAIN_MODE)" \
                   "$(tool_hint "${FFBUILD_TOOLCHAIN_MODE/host/gcc}")"
    fi
    if [[ "$FFBUILD_TOOLCHAIN_MODE" == ctng ]]; then
        if [[ -x "$FFBUILD_CTNG_ROOT/bin/$CTNG_TRIPLE-gcc" ]]; then
            rt_ok "ctng toolchain        $FFBUILD_TARGET: $FFBUILD_CTNG_ROOT"
        elif [[ -x "$FFBUILD_BUILDTOOLS_PREFIX/ctng/bin/$CTNG_TRIPLE-gcc" ]]; then
            # Toolchain built before the per-target layout existed. setup.sh
            # moves it on the next --with-ctng run; a plain build would not.
            rt_missing "ctng toolchain        $FFBUILD_TARGET: found in the legacy layout" \
                       "run ./native/setup.sh --with-ctng --ctng-target $FFBUILD_TARGET to migrate it"
        else
            rt_missing "ctng toolchain        $FFBUILD_TARGET: $FFBUILD_CTNG_ROOT" \
                       "run ./native/setup.sh --with-ctng --ctng-target $FFBUILD_TARGET"
        fi
    fi
    # wine is meson's exe_wrapper for Windows targets; without it the first
    # meson stage fails while running a feature-probe binary.
    if [[ "$FFBUILD_TARGET_WINE" == 1 ]]; then
        if command -v wine >/dev/null 2>&1; then
            rt_ok "wine                  $(command -v wine)"
        else
            rt_missing "wine                  $FFBUILD_TARGET: meson exe_wrapper" \
                       "$(pkg_cmd wine)"
        fi
    fi
    # qemu-user is only needed to run the resulting binaries, not to build
    # them; report it without failing the check.
    if [[ -n "$FFBUILD_TARGET_EMULATOR" ]]; then
        if command -v "$FFBUILD_TARGET_EMULATOR" >/dev/null 2>&1; then
            rt_ok "qemu                  $FFBUILD_TARGET: $(command -v "$FFBUILD_TARGET_EMULATOR")"
        else
            rt_missing "qemu                  $FFBUILD_TARGET: run artifacts" \
                       "$(pkg_cmd qemu_user)" optional
        fi
    fi
    # 默认变体经 50-ffnvcodec 打开 --enable-cuda-llvm，configure 把 nvcc 默认成 clang，
    # 所以即使宿主编译器是 gcc，clang 也是硬依赖（上游镜像同样把它列为基础包）。
    if command -v clang >/dev/null 2>&1; then
        rt_ok "clang (cuda-llvm)      ffnvcodec"
    else
        rt_missing "clang (cuda-llvm)      ffnvcodec" "$(tool_hint clang)"
    fi

    if [[ "$FFBUILD_COMPILER" == clang ]]; then
        _libatomic="$("$CC" -print-file-name=libatomic.so 2>/dev/null || true)"
        if [[ "$_libatomic" == /* && -e "$_libatomic" ]]; then
            rt_ok "libatomic (clang)     $_libatomic"
        else
            rt_missing "libatomic (clang)     rubberband 需要 -latomic" "$(tool_hint libatomic)"
        fi
        unset _libatomic
    fi

    # 构建期 Python 只有一个来源：venv。分两层检查——系统解释器能否建出带 pip
    # 的 venv（Debian 的 python3-venv、EL 的 python3.x-pip 缺了就不行），以及已
    # 存在的 venv 是否完整。只看解释器版本会漏掉后两者。
    if [[ -z "$py_sys" ]]; then
        rt_missing "python >= $FFBUILD_BT_SYSTEM_python          build venv" "$(tool_hint python3)"
    elif "$py_sys" -c 'import venv, ensurepip' >/dev/null 2>&1; then
        rt_ok "python venv module      $py_sys"
    else
        rt_missing "python venv module      build venv ($py_sys)" \
                   "$(pkg_cmd python_venv)"
    fi

    # 用 pyvenv.cfg 判断"venv 是否存在"：只测 bin/python3 会把残缺的 venv
    # （例如 python3.x 软链断掉）当成没有创建，掩盖真正的问题。
    if [[ -e "$FFBUILD_PYTHON_PREFIX/pyvenv.cfg" ]]; then
        local venv_meson venv_ok=1
        venv_meson="$(probe_version "$FFBUILD_PYTHON_PREFIX/bin/meson" --version)"
        [[ -x "$FFBUILD_PYTHON_PREFIX/bin/pip" ]] || venv_ok=0
        for _m in mesonbuild jsonschema jinja2; do
            "$FFBUILD_PYTHON_PREFIX/bin/python3" -c "import $_m" 2>/dev/null || venv_ok=0
        done
        if [[ -n "$venv_meson" ]] && version_ge "$venv_meson" "$FFBUILD_BT_MESON"; then
            :
        else
            venv_ok=0
        fi
        if (( venv_ok )); then
            rt_ok "build venv             meson $venv_meson"
        else
            rt_missing "build venv             pip/meson incomplete" \
                       "rerun ./native/setup.sh (it recreates $FFBUILD_PYTHON_PREFIX when pip is missing)"
        fi
        unset _m
    else
        rt_ok "build venv             not created yet (setup creates it)"
    fi

    # 发行版会把 Perl 核心模块拆包（Fedora 的 perl 只装解释器）。autoconf 的
    # autom4te 需要的不止 Time::Piece，这里一次探测几个实际会用到的。
    if perl -MTime::Piece -MFile::Compare -MData::Dumper -MFile::Temp -MEncode -e1 2>/dev/null; then
        rt_ok "perl core modules      openssl / autoconf"
    else
        rt_missing "perl core modules      openssl / autoconf" \
                   "$(pkg_cmd perl_core)"
    fi

    # makeinfo / autopoint 由托管工具提供；没建之前不该让用户去装系统包。
    if command -v makeinfo >/dev/null 2>&1; then
        rt_ok "makeinfo (texinfo)     gmp 等 autotools 文档"
    elif (( ! NO_MANAGED_TOOLS )); then
        printf '  %-9s makeinfo (texinfo)     built by native/buildtools.d\n' "[managed]"
    else
        rt_missing "makeinfo (texinfo)     autotools 文档" "$(tool_hint texinfo)"
    fi

    # BD-J 的 jar 由 meson 直接调 javac 生成，只有 JRE 的宿主不够。
    if command -v ant >/dev/null 2>&1 && command -v javac >/dev/null 2>&1; then
        rt_ok "ant + JDK (javac)      libbluray (BD-J)"
    else
        rt_missing "ant + JDK (javac)      libbluray (BD-J)" "$(tool_hint ant)"
    fi

    ap_ver="$(probe_version autopoint --version | awk '{print $NF}')"
    if [[ -n "$ap_ver" ]] && version_ge "$ap_ver" "0.21"; then
        rt_ok "autopoint >= 0.21      zvbi (found $ap_ver)"
    elif (( ! NO_MANAGED_TOOLS )); then
        printf '  %-9s autopoint >= 0.21      built by native/buildtools.d (gettext)\n' "[managed]"
    else
        rt_missing "autopoint >= 0.21      zvbi" \
                   "$(pkg_cmd autopoint)"
    fi

    ocaml_ok=0
    if command -v ocaml >/dev/null 2>&1 && command -v ocamlbuild >/dev/null 2>&1 &&
       command -v ocamlfind >/dev/null 2>&1 &&
       ocamlfind list 2>/dev/null | grep -q '^num '; then
        # env.sh 会把 opam switch 前置到 PATH，所以"能查到一个 ocamlfind"不等于
        # 它来自发行版——按解析出来的路径判断来源，标签才不会说谎。
        case "$(command -v ocamlfind)" in
            "$OPAMROOT"/*) ocaml_ok=2 ;;
            *)             ocaml_ok=1 ;;
        esac
    elif [[ -f "$OPAMROOT/default/lib/num/META" ]]; then
        ocaml_ok=2
    elif command -v ocaml >/dev/null 2>&1 && command -v ocamlfind >/dev/null 2>&1 &&
         command -v ocamlbuild >/dev/null 2>&1; then
        # 工具链齐了但 num 缺席：EL8 的仓库里根本没有这个包，装包命令帮不上忙。
        ocaml_ok=3
    fi
    case "$ocaml_ok" in
    1) rt_ok "OCaml + findlib + num  fftw3 (system)" ;;
    2) rt_ok "OCaml + findlib + num  fftw3 (managed: $OPAMROOT)" ;;
    3) rt_missing "OCaml num package      fftw3" \
                   "this distribution has no num package; rerun ./native/setup.sh to provision it through opam in $OPAMROOT" ;;
    *) rt_missing "OCaml + findlib + num  fftw3" \
                   "$(pkg_cmd ocaml); setup installs num through opam when the repo has none" ;;
    esac

    # shaderc 的 native_build 先 unset CC/CXX，cmake 因而使用 PATH 上的 c++。
    # 这里探测的正是那个 c++，而不是 $CXX：glslang 需要 std::filesystem，GCC 9 之前
    # 的 libstdc++ 还要额外链接 -lstdc++fs，缺失时链接失败。
    local host_cxx host_cxx_ok=0 _cxx_dir
    host_cxx="$(command -v c++ 2>/dev/null || true)"
    if [[ -n "$host_cxx" ]]; then
        _cxx_dir="${TMPDIR:-/tmp}/ffbuild-hostcxx.$$"
        mkdir -p "$_cxx_dir"
        if printf '%s\n' '#include <filesystem>
int main(int argc, char **argv) {
    std::filesystem::path p(argv[0]);
    return std::filesystem::exists(p) ? 0 : 1;
}' | env -u CC -u CXX "$host_cxx" -std=gnu++17 -x c++ - -o "$_cxx_dir/probe" >/dev/null 2>&1; then
            host_cxx_ok=1
        fi
        rm -rf "$_cxx_dir"
    fi
    if (( host_cxx_ok )); then
        rt_ok "host c++ (shaderc)    $host_cxx"
    else
        rt_missing "host c++ (shaderc)    cannot link a C++17 std::filesystem program" \
                   "shaderc ignores CC/CXX and uses c++ from PATH; install a C++17-capable toolchain and put its bin/ first in PATH"
    fi
    # 依赖里已经有 C++23 的用法（openal-soft 用 string_view 的范围构造）。直接
    # 探测标准库能力，比按编译器版本号判断可靠：clang 也可能配着旧的 libstdc++。
    local cxx_probe
    cxx_probe='#include <algorithm>
#include <ranges>
#include <string_view>
int main(int argc, char **argv) {
    std::string_view sv = argv[0];
    char sep = static_cast<char>(44);
    std::ranges::for_each(sv | std::views::split(sep), [](auto&& r) {
        std::string_view e{r.begin(), r.end()};
        (void)e;
    });
    (void)argc;
}'
    if printf '%s\n' "$cxx_probe" | "$CXX" -std=gnu++20 -x c++ -fsyntax-only - >/dev/null 2>&1; then
        rt_ok "c++23 string_view      openal (CXX=$CXX)"
    else
        rt_missing "c++23 string_view      openal (CXX=$CXX)" \
                   "$(pkg_cmd cxx23); or point FFBUILD_CXX at an installed compiler that supports it"
    fi

    # Rust 产物（rav1e/librsvg）里带 LLVM bitcode，binutils 的 bfd 靠 LLVMgold
    # 插件提取其中的符号。LLVM 14 及更早读不了 opaque pointer 形式的 IR，ar 会
    # 漏掉符号索引，链接 Rust 静态库时报 hidden symbol isn't defined；LLVM 15
    # 起正常。binutils 本身 2.38 已够用，限制在插件一侧；没有插件时 bfd 直接读
    # 原生符号表，同样可行。
    local gold gold_ver gold_bad=0
    for gold in /usr/lib/bfd-plugins/LLVMgold*.so; do
        [[ -e "$gold" ]] || continue
        gold_ver="$(readlink -f "$gold" | sed -n 's|.*/llvm-\([0-9][0-9]*\)/.*|\1|p')"
        [[ -n "$gold_ver" ]] || continue
        (( gold_ver >= 15 )) || gold_bad=1
    done
    if (( gold_bad )); then
        rt_missing "llvm bfd plugin >= 15  rust 静态库" \
                   "$(pkg_cmd llvm_bfd); or remove /usr/lib/bfd-plugins/LLVMgold*.so so that bfd reads native symbol tables"
    else
        rt_ok "llvm bfd plugin       rust 静态库"
    fi

    # cargo-c 优先使用系统的 OpenSSL 3 开发文件；系统没有时由 vendored 特性自建。
    # 只有 cargo-c 实际可运行且不依赖系统 libssl 时才报 [ok]；否则报 [pending]，
    # 表示它尚未按 vendored 方式构建。
    ossl_ver="$(system_openssl_version)"
    if [[ -n "$ossl_ver" ]] && version_ge "$ossl_ver" "3.0.0"; then
        rt_ok "OpenSSL >= 3 (dev)     cargo-c (system $ossl_ver)"
    elif command -v cargo-cinstall >/dev/null 2>&1 && cargo-cinstall --version >/dev/null 2>&1 &&
         command -v ldd >/dev/null 2>&1 &&
         ! ldd "$(command -v cargo-cinstall)" 2>/dev/null | grep -q libssl; then
        rt_ok "OpenSSL                 cargo-c (vendored, static)"
    else
        printf '  %-10s %s\n' "[pending]" "OpenSSL                 cargo-c will build with vendored OpenSSL"
    fi
    unset -f rt_ok rt_missing
    echo

    echo "== optional tools (only needed by some variants) =="
    for t in "${OPTIONAL_TOOLS[@]}"; do
        if command -v "$t" >/dev/null 2>&1; then
            printf '  [ok]      %-14s %s\n' "$t" "$(command -v "$t")"
        else
            printf '  [absent]  %-14s\n' "$t"
        fi
    done
    echo
    echo "== repo-local build tools =="
    # setup provisions nothing outside the repo any more, so the only tree to
    # report on is the managed-tools one. (glslc is produced by the vulkan stage
    # into $FFBUILD_GLSLc, not installed by setup.)
    local implib_gen="${FFBUILD_IMPLIB_DIR:-$FFBUILD_BUILDTOOLS_PREFIX/implib}/implib-gen.py"
    if [[ -f "$implib_gen" ]]; then
        printf '  [ok]      %s\n' "$implib_gen"
    else
        printf '  [MISSING] %s\n' "$implib_gen"
    fi
    echo
    ffbuild_env_dump
    if ((${#missing[@]})) || (( rt_blocking )) || (( ${bt_missing:-0} )); then
        echo
        if ((${#missing[@]})); then
            echo "Missing required tools: ${missing[*]}"
        fi
        if (( rt_blocking )); then
            echo "Missing runtime prerequisites: see the [MISSING] lines above."
        fi
        echo "  distro packages: install them as shown above (README §2.1), then re-run this check."
        echo "  build tools    : './native/setup.sh' builds them from source into"
        echo "                   $FFBUILD_BUILDTOOLS_PREFIX/prefix (logs in .../log/)."
        return 1
    fi
}

# ------------------------------------------------------- package install -----
# 所有宿主默认只打印安装命令，--install 才动手。猜错包名的代价（装错包、改坏仓库、
# 无 tty 时抛 sudo 错误）比省下的几步大。
INSTALL_OK=1
if [[ "$DO_CHECK" -eq 1 ]]; then
    # --check 是只读诊断：任何情况下都不动系统。
    INSTALL_OK=0
elif [[ "$NO_INSTALL" -eq 1 ]]; then
    INSTALL_OK=0
    echo "note: --no-install: skipping package installation (tools must already be present)"
elif [[ "$DO_INSTALL" -ne 1 ]]; then
    INSTALL_OK=0
    echo "note: detected ${PKG_MGR:-unknown package manager} ($(pkg_flavor_name)); this script only prints the packages by default."
    echo "      install them yourself, or rerun with --install:"
    mapfile -t _hint_pkgs < <(pkg_expand)
    if ((${#_hint_pkgs[@]})); then
        pkg_plan "${_hint_pkgs[@]}" | sed 's/^/        /'
    else
        echo "        (no column for $PKG_FLAVOR in pkgdeps.conf)"
    fi
    echo "      verify afterwards with ./native/setup.sh --check"
    unset _hint_pkgs
fi

if [[ "$INSTALL_OK" -eq 1 ]]; then
    if [[ "$PKG_MGR" == apt-get ]]; then
        echo "== installing build prerequisites (apt) =="
        if ! asroot apt-get update; then
            INSTALL_OK=0
            echo "WARNING: 'apt-get update' failed; skipping apt-based installation." >&2
            echo "         Run './native/setup.sh --check' to see what is already present." >&2
        fi
    else
        echo "== installing build prerequisites ($PKG_FLAVOR) =="
    fi
fi

# --all 的 p7zip、lcov 来自 EPEL，必须在可用性过滤之前装好 epel-release；否则
# pkg_available 会把它们判成"发行版没有"直接丢掉。
if [[ "$INSTALL_OK" -eq 1 ]] && (( NEED_EPEL )); then
    echo "== enabling EPEL (EL8) =="
    if ! asroot dnf install -y epel-release; then
        echo "WARNING: epel-release could not be installed; p7zip and lcov will be missing." >&2
        echo "         RHEL 8 without EPEL in its own repositories:" >&2
        echo "         dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm" >&2
    fi
fi

if [[ "$INSTALL_OK" -eq 1 ]]; then
    mapfile -t _want < <(pkg_expand)
    _keep=() _drop=() _unknown=()
    for _p in "${_want[@]}"; do
        _rc=0
        pkg_available "$_p" || _rc=$?
        case "$_rc" in
            0) _keep+=("$_p") ;;
            1) _drop+=("$_p") ;;
            *) _unknown+=("$_p"); _keep+=("$_p") ;;
        esac
    done
    if ((${#_drop[@]})); then
        echo "note: not in the configured repositories, skipped: ${_drop[*]}"
        if (( NEED_EPEL )) && [[ " ${_drop[*]} " == *" p7zip "* || " ${_drop[*]} " == *" lcov "* ]]; then
            echo "      p7zip/lcov come from EPEL: install epel-release, then rerun"
        fi
    fi
    if ((${#_unknown[@]})); then
        echo "note: repository metadata is not cached; ${#_unknown[@]} package(s) go to the package manager unchecked"
    fi
    if ((${#_keep[@]})); then
        case "$PKG_MGR" in
            apt-get) asroot env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${_keep[@]}" ;;
            dnf)     asroot dnf install -y "${DNF_INSTALL_ARGS[@]}" "${_keep[@]}" ;;
            pacman)  asroot pacman -S --needed --noconfirm "${_keep[@]}" ;;
            zypper)  asroot zypper --non-interactive install --no-recommends "${_keep[@]}" ;;
        esac || {
            echo "WARNING: package installation failed; run './native/setup.sh --check' to see what is missing" >&2
        }
    fi
    unset _p _rc _want _keep _drop _unknown
fi

# ------------------------------------------------------------ env contract ---
# 到了这里，包已经装过（--install 或用户自己装），env.sh 的 CC/CXX 校验才有意义。
# --check 例外：它是给裸机做诊断的，缺编译器时只记录，由 do_check 报 [MISSING]。
if [[ "$DO_CHECK" -eq 1 ]]; then
    export FFBUILD_ENV_CHECK_ONLY=1
fi
# Building the toolchain always uses the host compiler. A caller-supplied ctng
# mode describes the later FFmpeg build and would make env.sh demand a
# toolchain that does not exist yet.
if [[ "$DO_CHECK" -eq 0 && "$WITH_CTNG" -eq 1 && "${FFBUILD_TOOLCHAIN_MODE:-}" == ctng ]]; then
    echo "note: building the toolchain in host mode; FFBUILD_TOOLCHAIN_MODE applies to the FFmpeg build"
    FFBUILD_TOOLCHAIN_MODE=host
    export FFBUILD_TOOLCHAIN_MODE
fi

# shellcheck source=native/env.sh
if ! source "$HERE/env.sh"; then
    echo "setup.sh: build environment is incomplete — install the packages listed above" >&2
    echo "          (or run ./native/setup.sh --check), then re-run this script" >&2
    exit 2
fi

# The toolchain triple always comes from the target file: setup also builds the
# toolchain in host mode, where env.sh leaves FFBUILD_TOOLCHAIN_TRIPLE unset.
CTNG_TRIPLE="$FFBUILD_TARGET_CTNG_TRIPLE"

if [[ -n "${FFBUILD_IGNORED_CARGO_HOME:-}${FFBUILD_IGNORED_RUSTUP_HOME:-}" ]]; then
    echo "note: ignoring CARGO_HOME/RUSTUP_HOME from the environment; build caches stay under $FFBUILD_BUILDTOOLS_PREFIX"
fi

if [[ "$DO_CHECK" -eq 1 ]]; then
    do_check
    exit $?
fi

# Every fetch below goes through retry-tool. The per-attempt timeout is raised
# to match download.sh: rustup and crosstool-ng fetch large trees over links
# where the 120 s default is too short.
RETRY_TOOL="$FFBUILD_REPO_ROOT/util/bin/retry-tool"
RETRY_TIMEOUT="${RETRY_TIMEOUT:-600}"
export RETRY_TIMEOUT
if [[ ! -x "$RETRY_TOOL" ]]; then
    echo "setup.sh: retry-tool not found at $RETRY_TOOL" >&2
    exit 1
fi

# Fetch only the pinned ct-ng commit. A full clone transfers far more than the
# build needs and is markedly more likely to hit TLS resets on slow links.
ctng_fetch_source() {  # <dest> <url> <commit>
    local dest="$1" url="$2" commit="$3"
    if [[ -z "$dest" || -z "$url" || -z "$commit" ]]; then
        echo "ctng_fetch_source: empty destination, URL, or commit" >&2
        return 1
    fi
    RETRY_MAX="${CTNG_FETCH_ATTEMPTS:-3}" "$RETRY_TOOL" bash -c '
        dest=$1; url=$2; commit=$3
        rm -rf "$dest"
        mkdir -p "$dest"
        git -C "$dest" init -q
        git -C "$dest" fetch --depth=1 "$url" "$commit"
        git -C "$dest" checkout -q --detach FETCH_HEAD
    ' _ "$dest" "$url" "$commit"
}

# Clean the destination before every attempt: an interrupted clone leaves a
# partial repository that the next attempt cannot reuse.
clone_retry() {  # <dest> <url> [git clone options...]
    local dest="$1" url="$2"; shift 2
    if [[ -z "$dest" || -z "$url" ]]; then
        echo "clone_retry: empty destination or URL" >&2
        return 1
    fi
    "$RETRY_TOOL" bash -c '
        dest=$1; url=$2; shift 2
        rm -rf "$dest"
        exec git clone "$@" "$url" "$dest"
    ' _ "$dest" "$url" "$@"
}

# Upstream prunes the toolchain's unversioned shared-library symlinks so that
# everything except the C library links statically; the libc archives are
# removed at the same time so glibc itself stays dynamic. Keep the LTO plugin
# and the core glibc components.
#
# This must run before dependencies are built: with libgomp.so removed,
# CMake's OpenMP probes fail and soxr/vidstab build serially, which is the
# upstream behaviour.  Reusing a build tree created before pruning leaves
# OpenMP objects behind and breaks shared-library links.
ctng_prune_toolchain() {
    [[ -d "$FFBUILD_CTNG_ROOT/$CTNG_TRIPLE/sysroot" ]] || return 1
    echo "== pruning $FFBUILD_TARGET toolchain ($FFBUILD_TARGET_PRUNE): $FFBUILD_CTNG_ROOT"
    case "$FFBUILD_TARGET_PRUNE" in
    mingw)
        # Upstream removes the MinGW runtime DLLs and their import libraries so
        # that everything but the C runtime links statically.
        find "$FFBUILD_CTNG_ROOT" \( -name '*.dll' -o -name '*.dll.a' \) -delete
        ;;
    *)
        find "$FFBUILD_CTNG_ROOT" \( -type l \
            -and -name '*.so' \
            -and -not -ipath '*plugin*' \
            -and -not -name 'libdl.*' \
            -and -not -name 'libc.*' \
            -and -not -name 'libm.*' \
            -and -not -name 'libmvec.*' \
            -and -not -name 'librt.*' \
            -and -not -name 'libpthread.*' \
            \) -delete
        find "$FFBUILD_CTNG_ROOT" \( \
            -name 'libdl.a' \
            -or -name 'libc.a' \
            -or -name 'libm.a' \
            -or -name 'libmvec.a' \
            -or -name 'librt.a' \
            -or -name 'libpthread.a' \
            \) -delete
        ;;
    esac
}

# Before per-target toolchains, the Linux toolchain lived in .buildtools/ctng
# itself. Move it under <base>/<target> once and rename its state file, so an
# existing toolchain is reused instead of rebuilt (40+ minutes).
ctng_migrate_layout() {
    local base="${FFBUILD_BUILDTOOLS_PREFIX}/ctng"
    local old_state="$FFBUILD_BUILDTOOLS_PREFIX/state/ctng.done"
    local new_state="$FFBUILD_BUILDTOOLS_PREFIX/state/ctng-$FFBUILD_TARGET.done"
    [[ "$FFBUILD_CTNG_ROOT" == "$base/$FFBUILD_TARGET" ]] || return 0
    if [[ -d "$base" && ! -L "$base" && -x "$base/bin/$CTNG_TRIPLE-gcc" ]]; then
        local tmp="$base.migrate.$$"
        echo "== migrating toolchain: $base -> $FFBUILD_CTNG_ROOT"
        mv "$base" "$tmp" && mkdir -p "$base" && mv "$tmp" "$FFBUILD_CTNG_ROOT"
    fi
    if [[ -f "$old_state" && ! -e "$new_state" ]]; then
        local key
        key="$(cat "$old_state" 2>/dev/null || true)"
        if [[ "${key##* }" == "$CTNG_TRIPLE" ]]; then
            mv "$old_state" "$new_state"
        fi
    fi
}

# ------------------------------------------------------------ build tools -----
# 构建工具全部源码自建：配方在 native/buildtools.d/，驱动在 native/buildtools.sh。
# 装进 $FFBUILD_BUILDTOOLS_PREFIX/prefix，只放 bin/ 与 share/，不进 PKG_CONFIG_LIBDIR，
# 因此这里既不需要版本探测，也不需要给每个工具分目录。
#
# 无法"从源码自建"的仍是常量：python（只检查版本，venv 需要它）、meson（pin，
# 装在 venv 里）、opam（预编译静态二进制，给缺 OCaml 的宿主兜底）。

if (( NO_MANAGED_TOOLS )); then
    echo "note: --no-managed-tools; 使用宿主自带的构建工具"
else
    _bt_args=()
    [[ -n "${WITH_TOOLS:-}" ]] && _bt_args=(--tool "$WITH_TOOLS")
    if ! "$FFBUILD_REPO_ROOT/native/buildtools.sh" "${_bt_args[@]}"; then
        _bt_failed="$FFBUILD_BUILDTOOLS_PREFIX/state/failed-tools"
        if [[ -s "$_bt_failed" ]]; then
            while IFS= read -r _bt_tool; do
                [[ -n "$_bt_tool" ]] || continue
                note_failure "build tools: $_bt_tool (log: $FFBUILD_BUILDTOOLS_PREFIX/log/$_bt_tool.log)"
            done < "$_bt_failed"
        else
            note_failure "build tools (native/buildtools.sh)"
        fi
        unset _bt_failed _bt_tool
    fi
    unset _bt_args
fi

# env.sh 是在装包之后、建工具之前 source 的，那时前缀 bin 还不存在，所以它没有
# 进 PATH；buildtools.sh 只在自己的子 shell 里前置。裸机跑完这一步之后才第一次
# 需要这些工具（prepare_rust 要 pkg-config），在这里补上。
_ffbuild_path_prepend "$FFBUILD_BUILDTOOLS_BIN"

# opam 是预编译二进制（不是源码包），所以留在 setup 里下载。
bt_fetch() {  # <url> <dest> <sha256>
    local url="$1" dest="$2" want="$3" got=""
    if ! "$RETRY_TOOL" bash -c '
        dest=$1; url=$2
        curl -fsSL --max-time 300 -o "$dest" "$url" 2>/dev/null ||
            wget -q -O "$dest" "$url" 2>/dev/null
    ' _ "$dest" "$url"; then
        rm -f "$dest"
        echo "  WARNING: could not download $url" >&2
        return 1
    fi
    got="$(sha256sum "$dest" | awk '{print $1}')"
    if [[ "$got" != "$want" ]]; then
        echo "  ERROR: checksum mismatch for $url" >&2
        echo "    expected $want" >&2
        echo "    got      $got" >&2
        rm -f "$dest"
        return 1
    fi
}

# ------------------------------------------------------------------ ocaml -----
# 25-fftw3 builds from git with --enable-maintainer-mode, so its codelets are
# generated by OCaml's genfft, which needs ocamlbuild + the findlib package
# "num". OCaml is documented as a prerequisite; this is only the fallback for
# hosts where it is missing or where num has no package (EL8 has none at all).
#
# opam is a static binary and everything it installs stays under OPAMROOT, i.e.
# inside .buildtools — no ~/.opam, no distro packages, no root.
ocaml_state="none"
if command -v ocaml >/dev/null 2>&1 && command -v ocamlfind >/dev/null 2>&1 &&
   command -v ocamlbuild >/dev/null 2>&1 && ocamlfind query num >/dev/null 2>&1; then
    ocaml_state="system"
elif [[ -x "$OPAMROOT/default/bin/ocamlfind" && -f "$OPAMROOT/default/lib/num/META" ]]; then
    ocaml_state="managed"
fi

if [[ "$ocaml_state" == "system" ]]; then
    echo "note: system OCaml + findlib num ready"
elif [[ "$ocaml_state" == "managed" ]]; then
    echo "note: managed OCaml ready at $OPAMROOT"
else
    echo "== provisioning OCaml through opam under $OPAMROOT =="
    mkdir -p "$FFBUILD_OPAM_ROOT/bin"
    opam_bin="$FFBUILD_OPAM_ROOT/bin/opam"
    if [[ ! -x "$opam_bin" ]]; then
        if bt_fetch "$FFBUILD_BT_URL_opam" "$opam_bin.part" "$FFBUILD_BT_SHA256_opam"; then
            chmod +x "$opam_bin.part" && mv "$opam_bin.part" "$opam_bin"
        else
            echo "  WARNING: could not fetch opam; OCaml stays unprovisioned" >&2
        fi
    fi
    opam_log="$FFBUILD_OPAM_ROOT/opam-install.log"
    if [[ -x "$opam_bin" ]]; then
        export OPAMROOT
        # opam 自己也要几样东西：unzip 解仓库索引，git（或 hg/darcs/rsync）与
        # curl/wget 至少各一个。缺了就直说缺什么——不要先让 init 失败一次，
        # 再让人去翻 opam-install.log。
        opam_missing=()
        command -v unzip >/dev/null 2>&1 || opam_missing+=(unzip)
        command -v git >/dev/null 2>&1 || opam_missing+=(git)
        if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
            opam_missing+=(curl)
        fi
        if ((${#opam_missing[@]})); then
            echo "  WARNING: opam needs ${opam_missing[*]}; skipping the OCaml fallback" >&2
            for _m in "${opam_missing[@]}"; do echo "           $(tool_hint "$_m")" >&2; done
            unset _m
            note_failure "ocaml (opam prerequisites missing: ${opam_missing[*]})"
        else
            # opam init would otherwise offer to edit the user's shell profile.
            # The switch was renamed over time (2.0: --no-setup, 2.1+:
            # --no-shell-setup), so use whichever this binary advertises.
            opam_init_flags=(--bare --disable-sandboxing -y)
            if "$opam_bin" init --help 2>&1 | grep -q -- "--no-shell-setup"; then
                opam_init_flags+=(--no-shell-setup)
            elif "$opam_bin" init --help 2>&1 | grep -q -- "--no-setup"; then
                opam_init_flags+=(--no-setup)
            else
                echo "  WARNING: this opam offers no way to skip shell setup; check ~/.profile afterwards" >&2
            fi
            if [[ ! -d "$OPAMROOT" ]] &&
               ! "$opam_bin" init "${opam_init_flags[@]}" >"$opam_log" 2>&1; then
                echo "  WARNING: opam init failed (see $opam_log)" >&2
                note_failure "ocaml (opam init failed)"
            fi
            if ! "$opam_bin" switch list --short 2>/dev/null | grep -qx default; then
                # Prefer the system compiler (fast); fall back to building one when
                # the distro has no OCaml at all or opam rejects its version.
                if ! "$opam_bin" switch create default ocaml-system -y >>"$opam_log" 2>&1; then
                    "$opam_bin" switch create default --packages="$FFBUILD_BT_OCAML_COMPILER" -y >>"$opam_log" 2>&1 || {
                        echo "  WARNING: could not create an opam switch (see $opam_log)" >&2
                        note_failure "ocaml (opam switch)"
                    }
                fi
            fi
            # ocamlbuild's build aborts when a distro copy is present ("Preinstalled
            # ocamlbuild detected at /usr/lib/ocaml/ocamlbuild"). The guard is a make
            # variable, so it can be disabled through the environment.
            if ! CHECK_IF_PREINSTALLED=false "$opam_bin" install -y --switch=default \
                    ocamlfind ocamlbuild num >>"$opam_log" 2>&1; then
                echo "  WARNING: opam could not install ocamlfind/ocamlbuild/num (see $opam_log)" >&2
                note_failure "ocaml (opam install)"
            fi
            if [[ -x "$OPAMROOT/default/bin/ocamlfind" && -f "$OPAMROOT/default/lib/num/META" ]]; then
                echo "  OCaml + ocamlfind + num ready under $OPAMROOT"
                echo "  (with a system compiler it takes about a minute; otherwise opam builds one)"
            else
                echo "  ERROR: OCaml is still unusable — $(tool_hint ocaml)" >&2
                note_failure "ocaml"
            fi
        fi
    fi
fi

# ----------------------------------------------------------------- python -----
# 构建只需要一个解释器：这个 venv。它同时提供 meson 与 jsonschema/jinja2。
# Python 本身不构建——版本不足时给出对应发行版的安装命令。
PY_MIN="$FFBUILD_BT_SYSTEM_python"
# 建 venv 必须用宿主解释器：env.sh 会在 venv 存在时把它的 bin 前置到 PATH，
# 用 venv 自己的 python 去重建 venv 会得到自我引用的 python3.x 软链（pyvenv.cfg
# 的 home 指向 venv 自身），pip 也就装不进去。先把该目录从 PATH 摘掉。
_sys_path=""
IFS=: read -r -a _pp <<<"$PATH"
for _p in "${_pp[@]}"; do
    [[ "$_p" == "$FFBUILD_PYTHON_PREFIX/bin" ]] && continue
    _sys_path+="${_sys_path:+:}$_p"
done
unset _p _pp
PYBIN=""
for _c in python3.13 python3.12 python3.11 python3.10 python3; do
    _cand="$(PATH="$_sys_path" command -v "$_c" 2>/dev/null || true)"
    [[ -n "$_cand" ]] || continue
    _v="$("$_cand" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
    [[ -n "$_v" ]] || continue
    if version_ge "$_v" "$PY_MIN"; then PYBIN="$_cand"; break; fi
done
unset _c _cand _v _sys_path
if [[ -z "$PYBIN" ]]; then
    echo "ERROR: no python >= $PY_MIN found; it is needed to host the build venv." >&2
    echo "  $(pkg_cmd python)" >&2
    exit 1
fi

PY_MODULES=("meson==$FFBUILD_BT_MESON" jsonschema jinja2)
PY_IMPORTS=(mesonbuild jsonschema jinja2)
py_ok=0
py_meson=""
if [[ -x "$FFBUILD_PYTHON_PREFIX/bin/python3" ]]; then
    py_ok=1
    for _m in "${PY_IMPORTS[@]}"; do
        "$FFBUILD_PYTHON_PREFIX/bin/python3" -c "import $_m" 2>/dev/null || py_ok=0
    done
    py_meson="$(probe_version "$FFBUILD_PYTHON_PREFIX/bin/meson" --version)"
    [[ -n "$py_meson" ]] && version_ge "$py_meson" "$FFBUILD_BT_MESON" || py_ok=0
fi

if [[ "$py_ok" -eq 1 ]]; then
    echo "note: build venv ready at $FFBUILD_PYTHON_PREFIX (meson $py_meson)"
else
    echo "== preparing build venv at $FFBUILD_PYTHON_PREFIX =="
    # 只有 pip 缺失时才重建：venv 已存在、只是模块没装好，重建没有意义。
    # ensurepip 不可用时 -m venv 只会打印一段不含出处的提示，先探测再决定。
    _venv_failed=0
    if [[ ! -x "$FFBUILD_PYTHON_PREFIX/bin/pip" ]]; then
        if ! "$PYBIN" -c 'import venv, ensurepip' >/dev/null 2>&1; then
            echo "  ERROR: $PYBIN cannot create a venv with pip (venv/ensurepip missing)" >&2
            echo "         $(tool_hint python3)" >&2
            note_failure "python venv ($PYBIN: venv/ensurepip unavailable)"
            _venv_failed=1
        elif ! "$PYBIN" -m venv --clear "$FFBUILD_PYTHON_PREFIX"; then
            echo "  ERROR: could not create venv at $FFBUILD_PYTHON_PREFIX" >&2
            note_failure "python venv (could not create $FFBUILD_PYTHON_PREFIX)"
            _venv_failed=1
        fi
    fi
    if [[ -x "$FFBUILD_PYTHON_PREFIX/bin/pip" ]]; then
        if "$FFBUILD_PYTHON_PREFIX/bin/pip" install --quiet --no-cache-dir --upgrade pip "${PY_MODULES[@]}"; then
            echo "  python: $("$FFBUILD_PYTHON_PREFIX/bin/python3" -V 2>&1)"
            echo "  meson:  $("$FFBUILD_PYTHON_PREFIX/bin/meson" --version 2>/dev/null)"
        else
            echo "  WARNING: could not install ${PY_MODULES[*]} into $FFBUILD_PYTHON_PREFIX" >&2
            note_failure "python venv (pip install failed)"
        fi
    elif (( ! _venv_failed )); then
        echo "  ERROR: $FFBUILD_PYTHON_PREFIX has no pip after creation" >&2
        note_failure "python venv (pip missing after creation)"
    fi
    unset _venv_failed
fi

# ------------------------------------------------------ build-time tools ------
# Nothing below touches the system. The Docker image relied on root-owned system
# locations for all three of these (the aclocal dir, shaderc's output, Implib.so);
# the native driver keeps every build-time tool inside the repo instead, so a
# build needs no root at all — only installing distro packages does.
echo "== installing build-time tools =="

# 45-x11 / 50-vaapi stages call gen-implib (util/bin/gen-implib), which needs
# yugr/Implib.so. It is a build tool like autoconf or cmake, so it lives in
# .buildtools — no root, nothing outside the repo.
IMPLIB_DIR="${FFBUILD_IMPLIB_DIR:-$FFBUILD_REPO_ROOT/.buildtools/implib}"
if [[ -f "$IMPLIB_DIR/implib-gen.py" ]]; then
    echo "  Implib.so           (already present at $IMPLIB_DIR)"
else
    echo "== installing Implib.so =="
    mkdir -p "$(dirname "$IMPLIB_DIR")"
    implib_tmp="$(mktemp -d)"
    if clone_retry "$implib_tmp/Implib.so" https://github.com/yugr/Implib.so --filter=blob:none --depth=1; then
        rm -rf "$IMPLIB_DIR"
        if mv "$implib_tmp/Implib.so" "$IMPLIB_DIR"; then
            echo "  Implib.so           (installed at $IMPLIB_DIR)"
        else
            echo "  WARNING: could not place Implib.so at $IMPLIB_DIR" >&2
        fi
    else
        echo "  WARNING: could not clone Implib.so (gen-implib will fail)" >&2
    fi
    rm -rf "$implib_tmp"
fi

setup_fail_summary() {
    echo
    echo "== setup finished with ${#SETUP_FAILURES[@]} problem(s) =="
    printf '%s\n' "${SETUP_FAILURES[@]}" | sort -u | sed 's/^/  - /'
    echo "  managed build logs : $FFBUILD_BUILDTOOLS_PREFIX/log/"
    echo "  distro packages    : ./native/setup.sh --check  (per-tool command) / README §2.1"
    ffbuild_env_dump
    echo
    echo "The build will not work until these are resolved."
}

if [[ "$ONLY_BUILDTOOLS" -eq 1 ]]; then
    echo "note: --buildtools-only set; skipping toolchain descriptors and build root"
    # 到这里已经跑过 venv 与 Implib.so：它们失败时也得让退出码说实话。
    if ((${#SETUP_FAILURES[@]})); then
        setup_fail_summary
        exit 1
    fi
    exit 0
fi

# --------------------------------------------------- toolchain descriptor -----
# The descriptors live inside the repo and are reached through
# $FFBUILD_MESON_CROSS_FILE / $FFBUILD_CMAKE_TOOLCHAIN, so this only has to
# create them — no symlink under /, no root.
echo "== writing toolchain descriptor files =="
mkdir -p "$FFBUILD_REPO_ROOT/toolchain/generated"
ffbuild_write_toolchain_files
echo "  $FFBUILD_REPO_ROOT/toolchain/generated/{cross.meson,toolchain.cmake}"

# ------------------------------------------------------------ build root ------
echo "== creating build root =="
mkdir -p "$FFBUILD_ROOT"/{prefix,destdir,work,log} "$FFBUILD_ROOT/prefix/lib/pkgconfig" "$FFBUILD_ROOT/prefix/include" "$FFBUILD_ROOT/prefix/bin"
echo "  $FFBUILD_ROOT"

# `git am` needs a committer identity, but setup must not write ~/.gitconfig:
# util/run_stage.sh exports a throwaway one for the stage process tree only.

# ---------------------------------------------------------------- rust --------
# CARGO_HOME / RUSTUP_HOME point into .buildtools (native/env.sh), and the
# cargo/rustc on PATH are rustup *proxies* that resolve the toolchain through
# RUSTUP_HOME.  A proxy that exists but cannot run is worse than no rust at all:
# it passes a "command -v" test and then fails inside the build.  Ask the tools
# to actually run instead of trusting PATH.  rav1e/librsvg are part of the
# default gpl graph, so rust is prepared unconditionally rather than on demand.
rust_works() { command -v cargo >/dev/null 2>&1 && cargo --version >/dev/null 2>&1; }
cargo_c_works() { command -v cargo-cinstall >/dev/null 2>&1 && cargo-cinstall --version >/dev/null 2>&1; }

prepare_rust() {
    echo "== preparing rust toolchain (rav1e / librsvg) =="
    # env.sh already pointed CARGO_HOME/RUSTUP_HOME into .buildtools. Keep them
    # there unless the host already has a usable toolchain (see below).
    mkdir -p "$CARGO_HOME" "$RUSTUP_HOME"
    # cargo-c's build must see *system* pkg-config files (e.g. openssl); the
    # prefix-only PKG_CONFIG_LIBDIR installed by native/env.sh would hide them.
    # cargo-c is the only piece that has no distro package; everything else
    # (cargo, rustc) is reused from the host when it works.
    cargo_c_install() {
        (
            # cargo-c 是宿主工具，应该看系统库。env.sh 的 PKG_CONFIG_LIBDIR 只指向
            # ffbuild 前缀，而托管 pkgconf 编译进去的默认 pc_path 落在 .buildtools
            # 里，两者都到不了 /usr 下的 .pc（libssl-dev 的 openssl.pc 就因此找不到）。
            # 这里显式改指系统的 pkgconfig 目录；多架构目录名从编译器推导，免得
            # 在 x86_64/aarch64 之间硬编码。
            _sys_pc="/usr/lib64/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
            _triple="$("${CC:-cc}" -dumpmachine 2>/dev/null || true)"
            [[ -n "$_triple" ]] && _sys_pc="/usr/lib/$_triple/pkgconfig:$_sys_pc"
            unset PKG_CONFIG_PATH
            export PKG_CONFIG_LIBDIR="$_sys_pc"
            unset _sys_pc _triple
            # 系统没有 OpenSSL 3 开发文件时，使用 cargo-c 官方的 vendored 特性。
            # 该特性让全部 Rust 原生依赖共用静态 OpenSSL，避免混用宿主并行版本。
            _cargo_c_features=()
            _ossl_ver="$(system_openssl_version)"
            if [[ -z "$_ossl_ver" ]] || ! version_ge "$_ossl_ver" "3.0.0"; then
                _cargo_c_features=(--features=vendored-openssl)
                echo "  note: no system OpenSSL 3 development files; cargo-c will use vendored OpenSSL"
            fi
            # 中间产物不放 TMPDIR（可能是 tmpfs）也不放 ~/.cargo：cargo-c 的构建很吃空间。
            mkdir -p "$FFBUILD_BUILDTOOLS_PREFIX/tmp" "$FFBUILD_BUILDTOOLS_PREFIX/cargo-target"
            TMPDIR="$FFBUILD_BUILDTOOLS_PREFIX/tmp" \
                cargo install --target-dir "$FFBUILD_BUILDTOOLS_PREFIX/cargo-target" cargo-c "${_cargo_c_features[@]}"
        )
    }

    # cargo-c alone is not enough: it is a standalone binary and runs fine even
    # when the toolchain behind the cargo proxy is gone, so both have to work.
    rust_ok=0
    if rust_works && cargo_c_works; then
        echo "note: cargo-c already present: $(command -v cargo-cinstall)"
        rust_ok=1
    elif rust_works; then
        echo "note: using the rust already on PATH: $(rustc --version 2>/dev/null | sed -n 1p)"
        if cargo_c_install; then rust_ok=1; fi
    fi

    if (( ! rust_ok )); then
        # Prefer rustup from PATH, but fall back to the host cargo home: a shell
        # that never sourced ~/.cargo/env has no rustup on PATH even though the
        # toolchain is right there.
        rustup_bin="$(command -v rustup || true)"
        if [[ -z "$rustup_bin" && -x "$FFBUILD_HOST_CARGO_HOME/bin/rustup" ]]; then
            rustup_bin="$FFBUILD_HOST_CARGO_HOME/bin/rustup"
        fi
        # The repo already carries its own CARGO_HOME/RUSTUP_HOME, so a toolchain
        # that lives in the user's ~/.rustup is invisible to the proxies until it
        # is linked in.  Linking costs nothing and keeps the build self-contained,
        # so prefer it over downloading a second toolchain.
        host_tc=""
        for _tc in "$FFBUILD_HOST_RUSTUP_HOME"/toolchains/*; do
            [[ -x "$_tc/bin/rustc" ]] && host_tc="$_tc" && break
        done
        unset _tc

        if [[ -n "$host_tc" && -n "$rustup_bin" ]]; then
            echo "note: linking host toolchain $(basename "$host_tc") into $FFBUILD_RUSTUP_HOME"
            RUSTUP_HOME="$FFBUILD_RUSTUP_HOME" "$rustup_bin" toolchain link ffbuild-host "$host_tc" || \
                note_failure "rust (toolchain link)"
            RUSTUP_HOME="$FFBUILD_RUSTUP_HOME" "$rustup_bin" default ffbuild-host >/dev/null 2>&1 || true
        elif [[ -z "$rustup_bin" ]]; then
            echo "== installing rustup into $FFBUILD_RUSTUP_HOME =="
            rustup_init="$(mktemp)"
            if ! "$RETRY_TOOL" curl -fsSL -o "$rustup_init" https://sh.rustup.rs; then
                echo "  WARNING: could not download rustup-init" >&2
                note_failure "rust (rustup install)"
            elif ! "$RETRY_TOOL" sh "$rustup_init" -y --no-modify-path --profile minimal; then
                echo "  WARNING: rustup install failed" >&2
                note_failure "rust (rustup install)"
            fi
            rm -f "$rustup_init"
            export PATH="$CARGO_HOME/bin:$PATH"
        else
            echo "== installing a rust toolchain into $FFBUILD_RUSTUP_HOME =="
            RUSTUP_HOME="$FFBUILD_RUSTUP_HOME" "$rustup_bin" toolchain install stable --profile minimal || \
                note_failure "rust (toolchain install)"
            RUSTUP_HOME="$FFBUILD_RUSTUP_HOME" "$rustup_bin" default stable >/dev/null 2>&1 || true
        fi
        # The host may already carry cargo-c; do not rebuild it just because the
        # toolchain had to be linked first.
        if rust_works && { cargo_c_works || cargo_c_install; }; then
            rust_ok=1
        fi
        if (( ! rust_ok )); then
            echo "  WARNING: no usable rust toolchain; rav1e/librsvg cannot build" >&2
            note_failure "rust (toolchain)"
        fi
    fi
}

# Cross-compiled Rust: the toolchain needs the target's prebuilt std, and
# crates that do not export CC_<target> need a linker in cargo's config.
prepare_rust_target() {
    local want="$FFBUILD_RUST_TARGET" host="" cfg=""
    [[ -n "$want" ]] || return 0
    host="$(rustc -vV 2>/dev/null | sed -n 's/^host: //p')"
    # Native builds already have their target; nothing to add.
    if [[ -z "$host" || "$want" == "$host" ]]; then
        return 0
    fi
    if ! command -v rustup >/dev/null 2>&1; then
        echo "  WARNING: rustup not found; cannot add rust target $want" >&2
        note_failure "rust (target $want)"
        return 0
    fi
    if ! rustup target list --installed 2>/dev/null | grep -qx "$want"; then
        echo "== adding rust target $want =="
        rustup target add "$want" || { note_failure "rust (target $want)"; return 0; }
    fi
    if [[ -n "$FFBUILD_CROSS_PREFIX" ]]; then
        cfg="$CARGO_HOME/config.toml"
        mkdir -p "$CARGO_HOME"
        if [[ -f "$cfg" ]]; then
            sed -i '/^# >>> ffbuild cross target/,/^# <<< ffbuild cross target/d' "$cfg"
        fi
        {
            echo "# >>> ffbuild cross target (generated by setup.sh)"
            echo "[target.$want]"
            echo "linker = \"${FFBUILD_CROSS_PREFIX}gcc\""
            echo "ar = \"${FFBUILD_CROSS_PREFIX}gcc-ar\""
            echo "# <<< ffbuild cross target"
        } >> "$cfg"
        echo "  cargo config: $cfg (target.$want)"
    fi
}

prepare_rust
prepare_rust_target

# ---------------------------------------------------------------- ct-ng -------
if [[ "$WITH_CTNG" -eq 1 ]]; then
    CTNG_REPO="https://github.com/crosstool-ng/crosstool-ng.git"
    # The per-target config was generated by this ct-ng revision. Cloning master
    # would break as soon as crosstool-ng changes a configuration symbol.
    CTNG_COMMIT="b1a94f65c5187d99037a4e2f57aefbdf995a9677"
    CTNG_CONFIG="$FFBUILD_REPO_ROOT/toolchain/ctng/$FFBUILD_TARGET_CTNG_CONFIG"
    CTNG_STATE="$FFBUILD_BUILDTOOLS_PREFIX/state/ctng-$FFBUILD_TARGET.done"
    CTNG_CC="$FFBUILD_CTNG_ROOT/bin/$CTNG_TRIPLE-gcc"
    # Component tarballs are target-independent; keeping them outside the
    # prefix also stops CT_RM_RF_PREFIX_DIR from deleting them on every rebuild.
    CTNG_SOURCES="$FFBUILD_BUILDTOOLS_PREFIX/ctng/sources"
    ctng_migrate_layout
    if [[ ! -f "$CTNG_CONFIG" ]]; then
        echo "setup.sh: missing toolchain config $CTNG_CONFIG" >&2
        exit 1
    fi
    # Bump CTNG_LOGIC_VERSION whenever the toolchain-building logic in this
    # file changes (pruning, sed rewrites, build invocation): otherwise an
    # existing toolchain would be considered current after a logic change.
    CTNG_LOGIC_VERSION=1
    CTNG_KEY="$(sha256sum "$CTNG_CONFIG" | cut -d' ' -f1) $CTNG_COMMIT $CTNG_TRIPLE $FFBUILD_TARGET_PRUNE $CTNG_LOGIC_VERSION"
    CTNG_STALE=0
    if [[ -f "$CTNG_STATE" && "$(cat "$CTNG_STATE")" != "$CTNG_KEY" ]]; then
        CTNG_STALE=1
    fi

    if [[ "$FORCE_CTNG" -eq 0 && -f "$CTNG_STATE" &&
          "$(cat "$CTNG_STATE")" == "$CTNG_KEY" && -x "$CTNG_CC" ]]; then
        ctng_prune_toolchain || {
            echo "setup.sh: $FFBUILD_CTNG_ROOT does not look like a ct-ng toolchain" >&2
            exit 1
        }
        echo "== crosstool-ng toolchain already built: $FFBUILD_CTNG_ROOT"
        echo "   use --force-ctng to rebuild it"
    else
        echo "== building crosstool-ng toolchain (this takes a long time) =="
        CTNG_SRC="$FFBUILD_ROOT/ctng-src"
        if [[ "$FORCE_CTNG" -eq 1 || "$CTNG_STALE" -eq 1 ]]; then
            # A changed config or build procedure can leave objects that no
            # longer match; start from a clean per-target tree.
            rm -rf "$CTNG_SRC/build/$CTNG_TRIPLE"
        fi
        mkdir -p "$FFBUILD_ROOT" "$FFBUILD_CTNG_ROOT" "$CTNG_SOURCES" "$(dirname "$CTNG_STATE")"
        if [[ ! -d "$CTNG_SRC/.git" ]] ||
           ! git -C "$CTNG_SRC" cat-file -e "${CTNG_COMMIT}^{commit}" 2>/dev/null; then
            if ! ctng_fetch_source "$CTNG_SRC" "$CTNG_REPO" "$CTNG_COMMIT"; then
                echo "setup.sh: shallow fetch of $CTNG_COMMIT failed; falling back to a full clone" >&2
                clone_retry "$CTNG_SRC" "$CTNG_REPO" --filter=blob:none || {
                    echo "setup.sh: cannot fetch crosstool-ng" >&2
                    exit 1
                }
            fi
        fi
        git -C "$CTNG_SRC" checkout --quiet --detach "$CTNG_COMMIT" || {
            echo "setup.sh: cannot check out crosstool-ng $CTNG_COMMIT" >&2
            exit 1
        }
        (
            cd "$CTNG_SRC"
            ./bootstrap
            ./configure --prefix="$FFBUILD_CTNG_ROOT" --enable-local
            make -j"$FFBUILD_JOBS"
            cp "$CTNG_CONFIG" .config
            # ct-ng defaults to /opt for the install prefix and $HOME/src for
            # component tarballs; keep both inside the repository instead, and
            # share the tarballs between targets.
            sed -i "s|^CT_PREFIX_DIR=.*|CT_PREFIX_DIR=\"$FFBUILD_CTNG_ROOT\"|" .config
            sed -i "s|^CT_LOCAL_TARBALLS_DIR=.*|CT_LOCAL_TARBALLS_DIR=\"$CTNG_SOURCES\"|" .config
            # Without CT_SAVE_TARBALLS ct-ng leaves downloads in build/tarballs
            # and consumes anything already in the local dir; enabling it keeps
            # one copy per component and lets every target reuse them.
            sed -i 's|^# CT_SAVE_TARBALLS is not set|CT_SAVE_TARBALLS=y|' .config
            # ct-ng aborts when CC/CXX/CFLAGS/LD_LIBRARY_PATH are set: they
            # belong to the final build, not to the toolchain build. Upstream
            # runs ct-ng in a base image without them; drop the same variables
            # for this step only.
            unset CC CXX LD AR AS RANLIB NM STRIP OBJDUMP CPP
            unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS LIBS
            unset LD_LIBRARY_PATH LIBRARY_PATH LPATH
            unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH
            unset PKG_CONFIG_LIBDIR PKG_CONFIG_PATH PKG_CONFIG
            # Prime the per-build tarball dir from the shared sources. The
            # package iterator does not reliably consult CT_LOCAL_TARBALLS_DIR,
            # but it always honours CT_TARBALLS_DIR, so symlinking here makes
            # reuse independent of the fetch path.
            mkdir -p "$CTNG_SRC/build/tarballs"
            for _ctng_src in "$CTNG_SOURCES"/*; do
                [[ -f "$_ctng_src" ]] || continue
                ln -sf "$_ctng_src" "$CTNG_SRC/build/tarballs/$(basename "$_ctng_src")"
            done
            unset _ctng_src
            ./ct-ng build
        )
        ctng_prune_toolchain || {
            echo "setup.sh: ct-ng finished but $FFBUILD_CTNG_ROOT/$CTNG_TRIPLE/sysroot is missing" >&2
            exit 1
        }
        if [[ ! -x "$CTNG_CC" ]]; then
            echo "setup.sh: ct-ng finished but $CTNG_CC is missing" >&2
            exit 1
        fi
        printf '%s\n' "$CTNG_KEY" > "$CTNG_STATE"
        # ct-ng writes its own log inside the source tree; keep a copy before
        # the per-target build directory is removed.
        mkdir -p "$FFBUILD_BUILDTOOLS_PREFIX/log"
        cp "$CTNG_SRC/build.log" "$FFBUILD_BUILDTOOLS_PREFIX/log/ctng-$FFBUILD_TARGET.log" 2>/dev/null || true
        if [[ "$KEEP_CTNG_SRC" -eq 0 ]]; then
            # The component tarballs live in build/tarballs (shared, and now
            # backed by the local sources dir); the per-target build tree is
            # only needed until the toolchain is installed.
            rm -rf "$CTNG_SRC/build/$CTNG_TRIPLE"
            echo "removed the ct-ng build tree for $FFBUILD_TARGET (use --keep-ctng-src to keep it)"
        fi
        echo "ct-ng toolchain installed under $FFBUILD_CTNG_ROOT"
        echo "Enable it with: FFBUILD_TOOLCHAIN_MODE=ctng ./build.sh $FFBUILD_TARGET gpl"
    fi
fi

if ((${#SETUP_FAILURES[@]})); then
    setup_fail_summary
    exit 1
fi

echo
echo "== setup complete =="
ffbuild_env_dump
echo
echo "Next: ./native/download.sh && ./build.sh $FFBUILD_TARGET gpl"
