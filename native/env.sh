#!/bin/bash
# shellcheck shell=bash
#
# native/env.sh — Environment contract for Docker-free linux64 builds.
#
# This file replaces the `ENV` block of images/base-linux64/Dockerfile.
# It is *sourced* by native/setup.sh, native/download.sh and build.sh.
#
# ---------------------------------------------------------------- contract ----
# Toolchain selection
#   FFBUILD_TOOLCHAIN_MODE host (default) | ctng
#   FFBUILD_CTNG_ROOT      ct-ng toolchain root    (ctng mode, default
#                          $FFBUILD_ROOT/ctng)
#   FFBUILD_TOOLCHAIN_TRIPLE
#                          GNU triple override   (default: derived for host,
#                          x86_64-ffbuild-linux-gnu for ctng)
#
#   NOTE: FFBUILD_TOOLCHAIN itself is *derived* and exported for compatibility
#   with ~45 upstream stage scripts that pass it as `--host=...`. Setting it to
#   "host"/"ctng" selects the mode; any other value is taken as an explicit
#   triple override.
#
# Compiler override (REPLACE semantics)
#   FFBUILD_CC / FFBUILD_CXX / FFBUILD_LD / FFBUILD_AR / FFBUILD_RANLIB /
#   FFBUILD_NM / FFBUILD_STRIP
#   ...or simply export CC=clang CXX=clang++ before invoking build.sh
#
# Flag override
#   FFBUILD_CFLAGS / FFBUILD_CXXFLAGS / FFBUILD_LDFLAGS / FFBUILD_LDEXEFLAGS
#       -> REPLACE the built-in defaults entirely (advanced)
#   FFBUILD_EXTRA_CFLAGS / _CXXFLAGS / _LDFLAGS / _LDEXEFLAGS
#       -> APPEND to whatever is in effect (default or replaced)
#   FFBUILD_EXTRA_STAGE_CFLAGS / _CXXFLAGS / _LDFLAGS
#       -> APPEND to the per-stage flags
#
# Layout / misc
#   FFBUILD_ROOT           build root, default <repo>/.ffbuild
#   FFBUILD_JOBS           parallel job count, default $(nproc)
#   FFBUILD_PROXY          proxy override. Unset: inherit http_proxy /
#                          https_proxy / all_proxy (and their uppercase forms)
#                          from the environment. Set: use this value for all
#                          schemes. Empty: no proxy at all.
#   FFBUILD_NO_PROXY       no_proxy override; empty (default) adds nothing
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# This file uses bash-only constructs (indirect expansion, ${BASH_SOURCE}, ...).
# Refuse to run under any other shell: sourcing it from e.g. zsh/dash silently
# computes wrong paths and can poison a subsequent build's environment.
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "native/env.sh: must be sourced from bash (current shell is not bash)" >&2
    # Hard exit: continuing would compute wrong paths and can poison a later
    # build through exported variables. This branch is unreachable under bash.
    exit 1
fi

# ---------------------------------------------------------------- repo root ---
FFBUILD_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "$FFBUILD_REPO_ROOT" || ! -d "$FFBUILD_REPO_ROOT/scripts.d" ]]; then
    echo "native/env.sh: could not determine the repository root" >&2
    exit 1
fi

# Snapshot caller-supplied values *before* we install defaults, so that a plain
# `CC=clang ./build.sh ...` is honoured as an override.
_FFBUILD_ENV_SNAP_CC="${CC-}"
_FFBUILD_ENV_SNAP_CXX="${CXX-}"
_FFBUILD_ENV_SNAP_LD="${LD-}"
_FFBUILD_ENV_SNAP_AR="${AR-}"
_FFBUILD_ENV_SNAP_RANLIB="${RANLIB-}"
_FFBUILD_ENV_SNAP_NM="${NM-}"
_FFBUILD_ENV_SNAP_STRIP="${STRIP-}"
_FFBUILD_ENV_SNAP_CFLAGS="${CFLAGS-}"
_FFBUILD_ENV_SNAP_CXXFLAGS="${CXXFLAGS-}"
_FFBUILD_ENV_SNAP_LDFLAGS="${LDFLAGS-}"
_FFBUILD_ENV_SNAP_LDEXEFLAGS="${LDEXEFLAGS-}"

# ------------------------------------------------------------- root layout ----
# NOTE: the build root must NOT contain a '.' anywhere in its path. A few
# upstream stages (45-x11/30-libxcb.sh, 45-x11/60-libglvnd.sh) derive paths with
# ${LIBNAME%%.*}, which truncates at the *first* dot — so a root like ".ffbuild"
# would silently yield "/home/user/" instead of "…/lib/libxcb.so.1". Hence the
# dot-free default below.
FFBUILD_ROOT="${FFBUILD_ROOT:-$FFBUILD_REPO_ROOT/ffbuild}"
case "$FFBUILD_ROOT" in
    /*) ;;
    *) FFBUILD_ROOT="$FFBUILD_REPO_ROOT/$FFBUILD_ROOT" ;;
esac

if [[ -z "${FFBUILD_ALLOW_DOTTED_ROOT:-}" && "$FFBUILD_ROOT" == *.* ]]; then
    echo "native/env.sh: FFBUILD_ROOT='$FFBUILD_ROOT' contains a '.'." >&2
    echo "  Upstream stages 45-x11/30-libxcb.sh and 45-x11/60-libglvnd.sh derive" >&2
    echo "  paths with \${VAR%%.*}, which truncates at the first dot and breaks" >&2
    echo "  the build. Use a dot-free path (default: <repo>/ffbuild), or set" >&2
    echo "  FFBUILD_ALLOW_DOTTED_ROOT=1 to proceed anyway." >&2
    exit 1
fi
if [[ "$FFBUILD_REPO_ROOT" == *.* ]]; then
    echo "native/env.sh: WARNING: the repository path contains a '.':" >&2
    echo "  $FFBUILD_REPO_ROOT" >&2
    echo "  This may break the same dot-sensitive stages." >&2
fi

# Absolute paths on purpose: reproduces upstream's `$DESTDIR$PREFIX` concat.
export FFBUILD_REPO_ROOT
export FFBUILD_ROOT
export FFBUILD_PREFIX="$FFBUILD_ROOT/prefix"
export FFBUILD_DESTDIR="$FFBUILD_ROOT/destdir"
export FFBUILD_DESTPREFIX="$FFBUILD_DESTDIR$FFBUILD_PREFIX"
export FFBUILD_WORK="$FFBUILD_ROOT/work"
export FFBUILD_LOG="$FFBUILD_ROOT/log"
export FFBUILD_CTNG_ROOT="${FFBUILD_CTNG_ROOT:-$FFBUILD_ROOT/ctng}"

# --------------------------------------------------------------- helpers -----
# pick <FFBUILD_VAR> <snapshot> <default>
_ffbuild_pick() {
    local _cur="${!1-}"
    if [[ -n "$_cur" ]]; then printf '%s' "$_cur"
    elif [[ -n "$2" ]];         then printf '%s' "$2"
    else                             printf '%s' "$3"
    fi
}

# resolve_flags <FFBUILD_OVERRIDE_VAR> <snapshot> <base> <extra_var>
_resolve_flags() {
    local _ov="${!1-}" _snap="$2" _base="$3" _extra="${!4-}"
    if [[ -n "$_ov" ]]; then
        printf '%s' "$_ov${_extra:+ $_extra}"
    else
        printf '%s' "$_base${_snap:+ $_snap}${_extra:+ $_extra}"
    fi
}

# ------------------------------------------------------------- toolchain ------
# 1) Decide the toolchain *mode*.
FFBUILD_TOOLCHAIN_MODE="${FFBUILD_TOOLCHAIN_MODE:-}"
if [[ -z "$FFBUILD_TOOLCHAIN_MODE" ]]; then
    case "${FFBUILD_TOOLCHAIN:-}" in
        ""|host) FFBUILD_TOOLCHAIN_MODE=host ;;
        ctng)    FFBUILD_TOOLCHAIN_MODE=ctng ;;
        *)       FFBUILD_TOOLCHAIN_MODE=host ;;
    esac
fi

# 2) An explicit triple may be supplied via FFBUILD_TOOLCHAIN (legacy meaning).
if [[ -n "${FFBUILD_TOOLCHAIN:-}" && "$FFBUILD_TOOLCHAIN" != host && "$FFBUILD_TOOLCHAIN" != ctng ]]; then
    FFBUILD_TOOLCHAIN_TRIPLE="$FFBUILD_TOOLCHAIN"
fi

_ffbuild_def_cc="gcc"
_ffbuild_def_cxx="g++"
_ffbuild_def_ld="ld"
_ffbuild_def_ar="ar"
_ffbuild_def_ranlib="ranlib"
_ffbuild_def_nm="nm"
_ffbuild_def_strip="strip"

case "$FFBUILD_TOOLCHAIN_MODE" in
host)
    # No tool-name prefix: user compiler overrides (CC=clang) must win.
    FFBUILD_CROSS_PREFIX=""
    ;;
ctng)
    FFBUILD_TOOLCHAIN_TRIPLE="${FFBUILD_TOOLCHAIN_TRIPLE:-x86_64-ffbuild-linux-gnu}"
    FFBUILD_CROSS_PREFIX="${FFBUILD_TOOLCHAIN_TRIPLE}-"
    export PATH="$FFBUILD_CTNG_ROOT/bin:$PATH"
    _ffbuild_def_cc="${FFBUILD_CROSS_PREFIX}gcc"
    _ffbuild_def_cxx="${FFBUILD_CROSS_PREFIX}g++"
    _ffbuild_def_ld="${FFBUILD_CROSS_PREFIX}ld"
    _ffbuild_def_ar="${FFBUILD_CROSS_PREFIX}gcc-ar"
    _ffbuild_def_ranlib="${FFBUILD_CROSS_PREFIX}gcc-ranlib"
    _ffbuild_def_nm="${FFBUILD_CROSS_PREFIX}gcc-nm"
    _ffbuild_def_strip="${FFBUILD_CROSS_PREFIX}strip"
    ;;
*)
    echo "native/env.sh: unknown FFBUILD_TOOLCHAIN_MODE='$FFBUILD_TOOLCHAIN_MODE' (host|ctng)" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

export FFBUILD_TOOLCHAIN_MODE
export FFBUILD_CROSS_PREFIX

# 3) Resolve the actual tools.
export CC="$(_ffbuild_pick FFBUILD_CC     "$_FFBUILD_ENV_SNAP_CC"     "$_ffbuild_def_cc")"
export CXX="$(_ffbuild_pick FFBUILD_CXX   "$_FFBUILD_ENV_SNAP_CXX"    "$_ffbuild_def_cxx")"
export LD="$(_ffbuild_pick FFBUILD_LD     "$_FFBUILD_ENV_SNAP_LD"     "$_ffbuild_def_ld")"
export AR="$(_ffbuild_pick FFBUILD_AR     "$_FFBUILD_ENV_SNAP_AR"     "$_ffbuild_def_ar")"
export RANLIB="$(_ffbuild_pick FFBUILD_RANLIB "$_FFBUILD_ENV_SNAP_RANLIB" "$_ffbuild_def_ranlib")"
export NM="$(_ffbuild_pick FFBUILD_NM     "$_FFBUILD_ENV_SNAP_NM"     "$_ffbuild_def_nm")"
export STRIP="$(_ffbuild_pick FFBUILD_STRIP "$_FFBUILD_ENV_SNAP_STRIP" "$_ffbuild_def_strip")"

# 4) Derive FFBUILD_TOOLCHAIN (the GNU triple used as `--host` by stage scripts).
if [[ -n "${FFBUILD_TOOLCHAIN_TRIPLE:-}" ]]; then
    FFBUILD_TOOLCHAIN="$FFBUILD_TOOLCHAIN_TRIPLE"
else
    FFBUILD_TOOLCHAIN="$("$CC" -dumpmachine 2>/dev/null || true)"
    [[ -n "$FFBUILD_TOOLCHAIN" ]] || FFBUILD_TOOLCHAIN="$(uname -m)-linux-gnu"
fi
export FFBUILD_TOOLCHAIN

# 5) Sysroot: only meaningful for the ct-ng toolchain.
if [[ "$FFBUILD_TOOLCHAIN_MODE" == ctng ]]; then
    export FFBUILD_CMAKE_SYSROOT="${FFBUILD_CMAKE_SYSROOT:-$FFBUILD_CTNG_ROOT/${FFBUILD_TOOLCHAIN_TRIPLE}/sysroot}"
else
    export FFBUILD_CMAKE_SYSROOT="${FFBUILD_CMAKE_SYSROOT:-}"
fi

# Host tools (equal to target tools for native builds).
export HOST_CC="${HOST_CC:-$CC}"
export HOST_CXX="${HOST_CXX:-$CXX}"
export HOST_CFLAGS="${HOST_CFLAGS:--O2 -pipe}"
export HOST_CXXFLAGS="${HOST_CXXFLAGS:--O2 -pipe}"

# ---------------------------------------------------------------- flags -------
_ffbuild_base_cflags="-I$FFBUILD_PREFIX/include -O2 -pipe -fPIC -DPIC -D_FORTIFY_SOURCE=2 -fstack-protector-strong -fstack-clash-protection -pthread"
_ffbuild_base_cxxflags="$_ffbuild_base_cflags"
_ffbuild_base_ldflags="-L$FFBUILD_PREFIX/lib -O2 -pipe -fstack-protector-strong -fstack-clash-protection -Wl,-z,relro,-z,now -pthread -lm"
_ffbuild_base_ldexeflags=""

# ct-ng toolchain keeps upstream's static libgcc/libstdc++ linkage.
if [[ "$FFBUILD_TOOLCHAIN_MODE" == ctng ]]; then
    _ffbuild_base_cflags="-static-libgcc -static-libstdc++ $_ffbuild_base_cflags"
    _ffbuild_base_cxxflags="-static-libgcc -static-libstdc++ $_ffbuild_base_cxxflags"
    _ffbuild_base_ldflags="-static-libgcc -static-libstdc++ $_ffbuild_base_ldflags"
fi

# C language standard. When set it is appended last, so it wins over a standard
# that a project's own configure may have detected.
#
# The default exists for one specific compiler defect: GCC 14 accepts
# -std=gnu23 but still reports __STDC_VERSION__ == 202000L (C23's final value is
# 202311L) *while already treating `bool` as a keyword*. Projects that branch on
# `__STDC_VERSION__ >= 202311L` then take the "pre-C23" path and fail on the
# now-reserved `bool` — xvid is a concrete case (its configure injects
# `-std=gnu23` into CC). GCC 15+ makes the two consistent, and clang never has
# the problem (its -std=gnu23 reports 202311L).
#
# So the default is applied only when the compiler is actually in that
# inconsistent state. That is probed rather than version-sniffed. Forcing the
# standard on a self-consistent compiler buys nothing — clang's default *is*
# gnu17 — and actively hurts: `-std=gnu17` is rejected outright for C++
# translation units, so any project that feeds CFLAGS to a C++ compile breaks
# (davs2 compiles its .cc sources with $(CC); gcc only warns about this, clang
# errors).
#
# Override with FFBUILD_CSTD=gnu23/... or set it empty for the compiler default.
if [[ -z "${FFBUILD_CSTD+set}" ]]; then
    if [[ "$("$CC" -std=gnu23 -dM -E - </dev/null 2>/dev/null |
             awk '/^#define __STDC_VERSION__/ { print $3; exit }')" == "202000L" ]]; then
        FFBUILD_CSTD="gnu17"
    else
        FFBUILD_CSTD=""
    fi
fi
if [[ -n "$FFBUILD_CSTD" ]]; then
    _ffbuild_base_cflags="$_ffbuild_base_cflags -std=$FFBUILD_CSTD"
fi
export FFBUILD_CSTD

export CFLAGS="$(_resolve_flags FFBUILD_CFLAGS     "$_FFBUILD_ENV_SNAP_CFLAGS"     "$_ffbuild_base_cflags"     FFBUILD_EXTRA_CFLAGS)"
export CXXFLAGS="$(_resolve_flags FFBUILD_CXXFLAGS "$_FFBUILD_ENV_SNAP_CXXFLAGS" "$_ffbuild_base_cxxflags" FFBUILD_EXTRA_CXXFLAGS)"
export LDFLAGS="$(_resolve_flags FFBUILD_LDFLAGS   "$_FFBUILD_ENV_SNAP_LDFLAGS"   "$_ffbuild_base_ldflags"   FFBUILD_EXTRA_LDFLAGS)"
export LDEXEFLAGS="$(_resolve_flags FFBUILD_LDEXEFLAGS "$_FFBUILD_ENV_SNAP_LDEXEFLAGS" "$_ffbuild_base_ldexeflags" FFBUILD_EXTRA_LDEXEFLAGS)"

export STAGE_CFLAGS="-fvisibility=hidden -fno-semantic-interposition${FFBUILD_EXTRA_STAGE_CFLAGS:+ $FFBUILD_EXTRA_STAGE_CFLAGS}"
export STAGE_CXXFLAGS="-fvisibility=hidden -fno-semantic-interposition${FFBUILD_EXTRA_STAGE_CXXFLAGS:+ $FFBUILD_EXTRA_STAGE_CXXFLAGS}"
export STAGE_LDFLAGS="${FFBUILD_EXTRA_STAGE_LDFLAGS:-}"

# --------------------------------------------------------- ffmpeg contract ----
FFBUILD_TARGET_FLAGS="--pkg-config=pkg-config --arch=x86_64 --target-os=linux"
[[ -n "$FFBUILD_CROSS_PREFIX" ]] && \
    FFBUILD_TARGET_FLAGS="--pkg-config=pkg-config --cross-prefix=$FFBUILD_CROSS_PREFIX --arch=x86_64 --target-os=linux"
export FFBUILD_TARGET_FLAGS
export FFBUILD_RUST_TARGET="${FFBUILD_RUST_TARGET:-x86_64-unknown-linux-gnu}"
# FFmpeg's --extra-version suffix. Unset or empty keeps upstream's default
# behaviour, i.e. the build date in YYYYMMDD form.
export FFBUILD_EXTRA_VERSION="${FFBUILD_EXTRA_VERSION:-$(date +%Y%m%d)}"
# Libraries appended *after* every library on FFmpeg's link line (--extra-libs).
# This position matters: a library that only satisfies references coming from the
# dependency archives has to appear after them, otherwise Debian's default
# `-Wl,--as-needed` discards it. Both entries exist for a concrete failure:
#   -lm      chromaprint/fftw3 do not propagate their libm dependency, so the
#            probe failed with "undefined reference to symbol 'round@@GLIBC_2.2.5'"
#            / "DSO missing from command line".
#   -lstdc++ some dependency archives are C++ while their .pc files declare no
#            C++ runtime (davs2). clang keeps a __clang_call_terminate thunk in
#            its objects which references __cxa_begin_catch/std::terminate;
#            gcc's objects happen not to reference them, which is why this only
#            shows up in a clang build ("davs2 >= 1.6.0 not found using
#            pkg-config"). Override with e.g. -lc++ for a libc++ toolchain, or
#            set it empty to add nothing.
#   -latomic librubberband's static archive calls __atomic_is_lock_free but its
#            .pc carries no Libs.private, so the probe link failed with
#            "undefined reference to `__atomic_is_lock_free'". Note this cannot
#            be made a static dependency from here: glib's own .pc files emit
#            -latomic ahead of this list, so the binary picks it up dynamically
#            regardless of how it is written here.
export FFBUILD_EXTRA_LIBS="${FFBUILD_EXTRA_LIBS--lm -lstdc++ -latomic}"
export FFBUILD_CMAKE_TOOLCHAIN="${FFBUILD_CMAKE_TOOLCHAIN:-/toolchain.cmake}"
export FFBUILD_MESON_CROSS_FILE="${FFBUILD_MESON_CROSS_FILE:-/cross.meson}"

export PKG_CONFIG="${PKG_CONFIG:-pkg-config}"
export PKG_CONFIG_LIBDIR="$FFBUILD_PREFIX/lib/pkgconfig:$FFBUILD_PREFIX/share/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"

# Upstream's Docker layers copy $FFBUILD_PREFIX/share/aclocal into
# /usr/share/aclocal (10-xorg-macros, 45-x11). Natively we simply advertise the
# prefix's aclocal dir instead of polluting the system one.
#
# The system acdir must be listed explicitly as well: aclocal searches its own
# $prefix/share/aclocal plus ACLOCAL_PATH, and a side-prefix automake's own
# prefix is *not* /usr. Without this, `aclocal` from .buildtools cannot find
# third-party macros such as pkg.m4 (libxml2 fails with "couldn't find pkg.m4").
_ffbuild_aclocal_path="$FFBUILD_PREFIX/share/aclocal"
for _d in /usr/share/aclocal /usr/local/share/aclocal; do
    [[ -d "$_d" ]] && _ffbuild_aclocal_path="$_ffbuild_aclocal_path:$_d"
done
export ACLOCAL_PATH="$_ffbuild_aclocal_path${ACLOCAL_PATH:+:$ACLOCAL_PATH}"
unset _ffbuild_aclocal_path _d

export FFBUILD_JOBS="${FFBUILD_JOBS:-$(nproc 2>/dev/null || echo 4)}"
# NB: do NOT export MAKEFLAGS globally. Some autotools bootstrap steps
# (e.g. libiconv's autogen.sh / gnulib Makefile.devel) are not parallel-safe and
# race on generated files. Stage scripts pass `-j` explicitly where it is safe,
# and build.sh uses -j$FFBUILD_JOBS for FFmpeg itself.

# --------------------------------------------------------- build-time git -----
# Dependency stages write git objects in their throwaway source trees:
# 50-aom and 50-libaribb24 apply patches with `git am` (creates commits), and
# 50-avisynth creates a version tag with `git tag -a`. Upstream ran those inside
# a container whose git config was known: an identity was set in
# images/base/Dockerfile and nothing was signed. On a real host all of it is the
# user's business, and any of it can break the stage:
#   * commit.gpgsign=true with a passphrase-protected key and no agent ->
#     "fatal: failed to write commit object";
#   * tag.gpgsign=true -> `git tag -a` invokes the signer; without a terminal it
#     fails loudly (and still writes an unsigned tag), with one it blocks on the
#     passphrase prompt;
#   * no user.email at all -> "unable to auto-detect email address".
# Pin all three for this process tree only. GIT_CONFIG_* outranks every config
# file (git >= 2.31), so the host config is neither read nor written; the author
# of those throwaway objects matches what the container produced.
export GIT_CONFIG_COUNT=4
export GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
export GIT_CONFIG_KEY_1=user.name      GIT_CONFIG_VALUE_1=Builder
export GIT_CONFIG_KEY_2=user.email     GIT_CONFIG_VALUE_2=builder@localhost
export GIT_CONFIG_KEY_3=tag.gpgsign    GIT_CONFIG_VALUE_3=false

# ---------------------------------------------------------------- proxy -------
# Effective proxy, resolved in this order:
#   1. FFBUILD_PROXY, when the caller sets it explicitly (an explicitly *empty*
#      value means "no proxy at all");
#   2. otherwise the ambient environment, per scheme:
#      http_proxy / HTTP_PROXY, then https_proxy / HTTPS_PROXY, then
#      all_proxy / ALL_PROXY — all_proxy also fills schemes left unset;
#   3. otherwise there is no proxy.
# No proxy address is hard-coded here.
if [[ -v FFBUILD_PROXY ]]; then
    _ffbuild_http_proxy="$FFBUILD_PROXY"
    _ffbuild_https_proxy="$FFBUILD_PROXY"
    _ffbuild_all_proxy="$FFBUILD_PROXY"
else
    _ffbuild_http_proxy="${http_proxy:-${HTTP_PROXY:-}}"
    _ffbuild_https_proxy="${https_proxy:-${HTTPS_PROXY:-}}"
    _ffbuild_all_proxy="${all_proxy:-${ALL_PROXY:-}}"
    [[ -n "$_ffbuild_http_proxy" ]] || _ffbuild_http_proxy="$_ffbuild_all_proxy"
    [[ -n "$_ffbuild_https_proxy" ]] || _ffbuild_https_proxy="$_ffbuild_all_proxy"
fi

if [[ -n "$_ffbuild_http_proxy$_ffbuild_https_proxy$_ffbuild_all_proxy" ]]; then
    export http_proxy="$_ffbuild_http_proxy"  https_proxy="$_ffbuild_https_proxy"  all_proxy="$_ffbuild_all_proxy"
    export HTTP_PROXY="$_ffbuild_http_proxy"  HTTPS_PROXY="$_ffbuild_https_proxy"  ALL_PROXY="$_ffbuild_all_proxy"
else
    unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
fi
# Single, resolved value — exported mainly for reporting (ffbuild_env_dump).
export FFBUILD_PROXY="${_ffbuild_https_proxy:-${_ffbuild_http_proxy:-$_ffbuild_all_proxy}}"
unset _ffbuild_http_proxy _ffbuild_https_proxy _ffbuild_all_proxy

# FFBUILD_NO_PROXY contributes nothing by default — in particular no
# machine-specific host names. Set it to override no_proxy/NO_PROXY; leaving it
# empty keeps whatever the ambient environment already specified.
FFBUILD_NO_PROXY="${FFBUILD_NO_PROXY:-}"
if [[ -n "$FFBUILD_NO_PROXY" ]]; then
    export no_proxy="$FFBUILD_NO_PROXY" NO_PROXY="$FFBUILD_NO_PROXY"
fi
export FFBUILD_NO_PROXY

# ---------------------------------------------------- build tools (managed) ---
# 构建器版本下限见 native/buildtools.lock；不满足下限的工具由 native/setup.sh
# 装进 $FFBUILD_BUILDTOOLS_PREFIX（默认 <repo>/.buildtools，仓库内、不入库）。
#
# 策略是“只补不足”，因此这里只做判定，不做版本替换：
#   * 系统版本 >= 下限 → 托管版本完全不进 PATH（automake 例外：仍追加，
#     只为提供 automake-1.18 / aclocal-1.18 这两个版本名）；
#   * 系统版本 <  下限 → 托管版本的 bin 前置；
#   * python           → 构建专用 venv 始终前置：它是构建唯一的解释器，
#     既提供 meson，也提供 jsonschema/jinja2 这些非标准库模块。
FFBUILD_BUILDTOOLS_PREFIX="${FFBUILD_BUILDTOOLS_PREFIX:-$FFBUILD_REPO_ROOT/.buildtools}"
export FFBUILD_BUILDTOOLS_PREFIX
# shellcheck source=native/buildtools.lock
if [[ -f "$FFBUILD_REPO_ROOT/native/buildtools.lock" ]]; then
    source "$FFBUILD_REPO_ROOT/native/buildtools.lock"
fi

_ffbuild_ver_ge() {  # $1 >= $2 (version sort)
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | sed -n '1p')" == "$2" ]]
}
_ffbuild_path_prepend() {
    [[ -d "$1" ]] || return 0
    case ":$PATH:" in *":$1:"*) ;; *) PATH="$1:$PATH" ;; esac
}
_ffbuild_path_append() {
    [[ -d "$1" ]] || return 0
    case ":$PATH:" in *":$1:"*) ;; *) PATH="$PATH:$1" ;; esac
}

# 托管目录（变量名沿用旧称，便于单独覆盖某个工具）
FFBUILD_AUTOCONF_PREFIX="${FFBUILD_AUTOCONF_PREFIX:-$FFBUILD_BUILDTOOLS_PREFIX/autoconf-${FFBUILD_BT_INSTALL_autoconf:-2.73}}"
FFBUILD_AUTOMAKE_PREFIX="${FFBUILD_AUTOMAKE_PREFIX:-$FFBUILD_BUILDTOOLS_PREFIX/automake-${FFBUILD_BT_INSTALL_automake:-1.18.1}}"
FFBUILD_CMAKE_PREFIX="${FFBUILD_CMAKE_PREFIX:-$FFBUILD_BUILDTOOLS_PREFIX/cmake-${FFBUILD_BT_INSTALL_cmake:-3.28.3}}"
FFBUILD_GETTEXT_PREFIX="${FFBUILD_GETTEXT_PREFIX:-$FFBUILD_BUILDTOOLS_PREFIX/gettext-${FFBUILD_BT_INSTALL_gettext:-0.22.5}}"
FFBUILD_PYTHON_PREFIX="${FFBUILD_PYTHON_PREFIX:-$FFBUILD_BUILDTOOLS_PREFIX/venv}"
export FFBUILD_AUTOCONF_PREFIX FFBUILD_AUTOMAKE_PREFIX FFBUILD_CMAKE_PREFIX \
       FFBUILD_GETTEXT_PREFIX FFBUILD_PYTHON_PREFIX

_ac_cur="$(autoconf --version 2>/dev/null | sed -n '1p' | awk '{print $NF}')" || true
if [[ -z "$_ac_cur" ]] || ! _ffbuild_ver_ge "$_ac_cur" "${FFBUILD_BT_MIN_autoconf:-2.73}"; then
    _ffbuild_path_prepend "$FFBUILD_AUTOCONF_PREFIX/bin"
fi

_cm_cur="$(cmake --version 2>/dev/null | sed -n '1p' | awk '{print $3}')" || true
if [[ -z "$_cm_cur" ]] || ! _ffbuild_ver_ge "$_cm_cur" "${FFBUILD_BT_MIN_cmake:-3.28}"; then
    _ffbuild_path_prepend "$FFBUILD_CMAKE_PREFIX/bin"
fi

# autopoint 提供 gettext 的构建基础设施；版本不足会让 zvbi 的 autoreconf 直接失败
_ap_cur="$(autopoint --version 2>/dev/null | sed -n '1p' | awk '{print $NF}')" || true
if [[ -z "$_ap_cur" ]] || ! _ffbuild_ver_ge "$_ap_cur" "${FFBUILD_BT_MIN_gettext:-0.21}"; then
    _ffbuild_path_prepend "$FFBUILD_GETTEXT_PREFIX/bin"
fi

# automake 双轨：裸名看下限，版本名（gnulib）永远要 1.18
_am_cur="$(automake --version 2>/dev/null | sed -n '1p' | awk '{print $NF}')" || true
if [[ -n "$_am_cur" ]] && _ffbuild_ver_ge "$_am_cur" "${FFBUILD_BT_MIN_automake:-1.16.3}"; then
    _ffbuild_path_append "$FFBUILD_AUTOMAKE_PREFIX/bin"
else
    _ffbuild_path_prepend "$FFBUILD_AUTOMAKE_PREFIX/bin"
fi

if [[ -x "$FFBUILD_PYTHON_PREFIX/bin/python3" ]]; then
    _ffbuild_path_prepend "$FFBUILD_PYTHON_PREFIX/bin"
fi
unset _ac_cur _cm_cur _am_cur _ap_cur
export PATH

# -------------------------------------------------------------- rust PATH -----
# rav1e and librsvg build with cargo; librsvg even runs `cargo vendor` during its
# download step. `native/setup.sh --with-rust` installs this toolchain.
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
if [[ -d "$CARGO_HOME/bin" ]]; then
    case ":$PATH:" in
        *":$CARGO_HOME/bin:"*) ;;
        *) export PATH="$CARGO_HOME/bin:$PATH" ;;
    esac
fi

# -------------------------------------------------------------- util PATH -----
# git-mini-clone / retry-tool live in util/bin (extension-less, like upstream's
# /usr/bin copies) and must be callable by name from stage download scripts.
# $FFBUILD_ROOT/bin collects binaries that upstream installed into /usr/bin
# (e.g. glslc — see util/run_stage.sh).
for _d in "$FFBUILD_ROOT/bin" "$FFBUILD_REPO_ROOT/util/bin" "$FFBUILD_REPO_ROOT/util"; do
    case ":$PATH:" in
        *":$_d:"*) ;;
        *) export PATH="$_d:$PATH" ;;
    esac
done
unset _d

# ------------------------------------------------- toolchain descriptor files --
# Upstream stage scripts reference /cross.meson (32 meson stages) and
# /toolchain.cmake (~10 cmake stages) by absolute path — those files were
# supplied by the Docker image. We generate equivalent files that reflect the
# *currently resolved* compilers, so compiler overrides are honoured in both
# meson and cmake stages.
#
# native/setup.sh plants /cross.meson and /toolchain.cmake as symlinks into
# toolchain/generated/, so this function (which needs no privileges) is enough
# to keep them in sync.
_ffbuild_meson_array() {
    # Emit a meson array literal from a (possibly multi-word) command.
    local out="[" first=1 w
    # shellcheck disable=SC2086
    for w in $1; do
        [[ -n "$w" ]] || continue
        (( first )) || out+=", "
        out+="'$w'"
        first=0
    done
    printf '%s]' "$out"
}

ffbuild_write_toolchain_files() {
    local dir="$FFBUILD_REPO_ROOT/toolchain/generated"
    mkdir -p "$dir"

    {
        echo "# Generated by native/env.sh — do not edit."
        echo "[binaries]"
        echo "c = $(_ffbuild_meson_array "$CC")"
        echo "cpp = $(_ffbuild_meson_array "$CXX")"
        echo "ar = $(_ffbuild_meson_array "$AR")"
        echo "ranlib = $(_ffbuild_meson_array "$RANLIB")"
        echo "strip = $(_ffbuild_meson_array "$STRIP")"
        echo "nm = $(_ffbuild_meson_array "$NM")"
        echo
        echo "[host_machine]"
        echo "system = 'linux'"
        echo "cpu_family = 'x86_64'"
        echo "cpu = 'x86_64'"
        echo "endian = 'little'"
        if [[ -n "$FFBUILD_CMAKE_SYSROOT" ]]; then
            echo
            echo "[properties]"
            echo "sys_root = '$FFBUILD_CMAKE_SYSROOT'"
        fi
    } > "$dir/cross.meson"

    {
        echo "# Generated by native/env.sh — do not edit."
        echo "set(CMAKE_SYSTEM_NAME Linux)"
        echo "set(CMAKE_SYSTEM_PROCESSOR x86_64)"
        echo "set(CMAKE_SYSTEM_VERSION 4.18.20)"
        echo
        echo "set(CMAKE_C_COMPILER \"$CC\")"
        echo "set(CMAKE_CXX_COMPILER \"$CXX\")"
        echo "set(CMAKE_AR \"$AR\")"
        echo "set(CMAKE_RANLIB \"$RANLIB\")"
        echo "set(CMAKE_NM \"$NM\")"
        echo "set(CMAKE_STRIP \"$STRIP\")"
        echo
        if [[ -n "$FFBUILD_CMAKE_SYSROOT" ]]; then
            echo "set(CMAKE_SYSROOT \"$FFBUILD_CMAKE_SYSROOT\")"
            echo "list(APPEND CMAKE_FIND_ROOT_PATH \"$FFBUILD_CMAKE_SYSROOT\" \"$FFBUILD_PREFIX\")"
            echo "set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)"
            echo "set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)"
            echo "set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)"
        else
            echo "list(APPEND CMAKE_PREFIX_PATH \"$FFBUILD_PREFIX\")"
        fi
    } > "$dir/toolchain.cmake"
}

# --------------------------------------------------------------- QA dump ------
# `source native/env.sh && ffbuild_env_dump` prints the resolved configuration.
ffbuild_env_dump() {
    cat <<EOF
== FFmpeg-Builds native environment ==========================================
repo root      : $FFBUILD_REPO_ROOT
build root     : $FFBUILD_ROOT
prefix         : $FFBUILD_PREFIX
destdir        : $FFBUILD_DESTDIR
destprefix     : $FFBUILD_DESTPREFIX
toolchain mode : $FFBUILD_TOOLCHAIN_MODE
--host triple  : $FFBUILD_TOOLCHAIN
cross prefix   : '${FFBUILD_CROSS_PREFIX}'
jobs           : $FFBUILD_JOBS
-- tools ----------------------------------------------------------------------
CC=$CC
CXX=$CXX
LD=$LD
AR=$AR
RANLIB=$RANLIB
NM=$NM
STRIP=$STRIP
-- flags ----------------------------------------------------------------------
CFLAGS      = $CFLAGS
CXXFLAGS    = $CXXFLAGS
LDFLAGS     = $LDFLAGS
LDEXEFLAGS  = $LDEXEFLAGS
C standard  = ${FFBUILD_CSTD:-<compiler default>}
STAGE_CFLAGS   = $STAGE_CFLAGS
STAGE_CXXFLAGS = $STAGE_CXXFLAGS
STAGE_LDFLAGS  = $STAGE_LDFLAGS
-- ffmpeg ---------------------------------------------------------------------
FFBUILD_TARGET_FLAGS   = $FFBUILD_TARGET_FLAGS
FFBUILD_RUST_TARGET    = $FFBUILD_RUST_TARGET
FFBUILD_CMAKE_TOOLCHAIN= $FFBUILD_CMAKE_TOOLCHAIN
PKG_CONFIG_LIBDIR      = $PKG_CONFIG_LIBDIR
-- network --------------------------------------------------------------------
proxy (http)  = ${http_proxy:-<none>}
proxy (https) = ${https_proxy:-<none>}
proxy (all)   = ${all_proxy:-<none>}
no_proxy      = ${no_proxy:-<none>}
extra version = $FFBUILD_EXTRA_VERSION
extra libs    = ${FFBUILD_EXTRA_LIBS:-<none>}
==============================================================================
EOF
}
