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
#   FFBUILD_TOOLCHAIN_MODE host (default) | clang | gcc | ctng
#                          host: auto-detect (cc -> gcc -> clang)
#                          clang/gcc: host toolchain, default to that compiler
#                          ctng: cross gcc toolchain
#   FFBUILD_CTNG_ROOT      ct-ng toolchain root    (ctng mode, default
#                          $FFBUILD_ROOT/ctng)
#   FFBUILD_TOOLCHAIN_TRIPLE
#                          GNU triple override   (default: derived for host,
#                          x86_64-ffbuild-linux-gnu for ctng)
#   FFBUILD_BUILD_DATE     date used in the artifact name (default YYYYMMDD)
#
#   FFBUILD_COMPILER is *derived* (clang|gcc|other) from the resolved CC.
#
#   NOTE: FFBUILD_TOOLCHAIN itself is *derived* and exported for compatibility
#   with ~45 upstream stage scripts that pass it as `--host=...`. Setting it to
#   "host"/"ctng" selects the mode; any other value is taken as an explicit
#   triple override. `clang`/`gcc` there is rejected: use TOOLCHAIN_MODE.
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
#   FFBUILD_ROOT           build root, default <repo>/ffbuild
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
# 1) Decide the toolchain *mode*: host (auto), clang, gcc, or ctng.
#    clang/gcc are shorthands for "host toolchain, default to that compiler";
#    they only seed the defaults below, so an explicit FFBUILD_CC / CC still wins.
#    FFBUILD_TOOLCHAIN keeps its old meaning (host/ctng or an explicit triple).
FFBUILD_TOOLCHAIN_MODE="${FFBUILD_TOOLCHAIN_MODE:-}"
if [[ -z "$FFBUILD_TOOLCHAIN_MODE" ]]; then
    case "${FFBUILD_TOOLCHAIN:-}" in
        ""|host) FFBUILD_TOOLCHAIN_MODE=host ;;
        ctng)    FFBUILD_TOOLCHAIN_MODE=ctng ;;
        *)       FFBUILD_TOOLCHAIN_MODE=host ;;
    esac
fi
case "$FFBUILD_TOOLCHAIN_MODE" in
host|clang|gcc|ctng) ;;
*)
    echo "native/env.sh: unknown FFBUILD_TOOLCHAIN_MODE='$FFBUILD_TOOLCHAIN_MODE' (host|clang|gcc|ctng)" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

# 2) An explicit triple may be supplied via FFBUILD_TOOLCHAIN (legacy meaning).
#    clang/gcc there is now a likely mistake: that variable is the triple.
case "${FFBUILD_TOOLCHAIN:-}" in
clang|gcc)
    echo "native/env.sh: FFBUILD_TOOLCHAIN is the host triple; use FFBUILD_TOOLCHAIN_MODE=$FFBUILD_TOOLCHAIN to pick the compiler" >&2
    return 1 2>/dev/null || exit 1
    ;;
""|host|ctng) ;;
*) FFBUILD_TOOLCHAIN_TRIPLE="$FFBUILD_TOOLCHAIN" ;;
esac

_ffbuild_def_cc="gcc"
_ffbuild_def_cxx="g++"
_ffbuild_def_ld="ld"
_ffbuild_def_ar="ar"
_ffbuild_def_ranlib="ranlib"
_ffbuild_def_nm="nm"
_ffbuild_def_strip="strip"

# Report the compiler family from the driver itself; used for defaults, the
# -latomic decision and the env dump.
_ffbuild_cc_kind() {
    local macros version
    macros="$("$1" -E -dM - </dev/null 2>/dev/null || true)"
    case "$macros" in
        *__clang__*) echo clang; return 0 ;;
        *__GNUC__*)  echo gcc;   return 0 ;;
    esac
    # Fallback for drivers that cannot preprocess (or are wrappers).
    version="$("$1" --version 2>/dev/null || true)"
    case "$version" in
        *clang*|*Clang*) echo clang ;;
        *gcc*|*GCC*|*Free*Software*Foundation*) echo gcc ;;
        *) echo other ;;
    esac
}

case "$FFBUILD_TOOLCHAIN_MODE" in
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
    FFBUILD_CROSS_PREFIX=""
    # Only seed defaults when the caller did not pick a compiler. clang/gcc
    # modes are explicit; host mode mirrors meson/cmake: cc first, then gcc,
    # then clang. CXX follows the same family so the drivers are not mixed.
    if [[ -z "${FFBUILD_CC:-}" && -z "${_FFBUILD_ENV_SNAP_CC:-}" ]]; then
        case "$FFBUILD_TOOLCHAIN_MODE" in
        clang) _ffbuild_def_cc=clang; _ffbuild_def_cxx=clang++ ;;
        gcc)   _ffbuild_def_cc=gcc;   _ffbuild_def_cxx=g++ ;;
        *)
            for _cand in cc gcc clang; do
                command -v "$_cand" >/dev/null 2>&1 || continue
                _ffbuild_def_cc="$_cand"
                case "$(_ffbuild_cc_kind "$_cand")" in
                clang)
                    if command -v clang++ >/dev/null 2>&1; then _ffbuild_def_cxx=clang++
                    else _ffbuild_def_cxx=c++; fi
                    ;;
                gcc)
                    if command -v g++ >/dev/null 2>&1; then _ffbuild_def_cxx=g++
                    else _ffbuild_def_cxx=c++; fi
                    ;;
                *) _ffbuild_def_cxx=c++ ;;
                esac
                break
            done
            unset _cand
            ;;
        esac
    fi
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

# Fail early instead of letting every stage report "command not found".
# `setup.sh --check` is the exception: it exists to diagnose bare hosts, so with
# FFBUILD_ENV_CHECK_ONLY=1 a missing driver is only recorded here and reported by
# setup's own checklist. Everything below tolerates an absent driver (it only
# probes it with 2>/dev/null), so the contract stays valid in that mode.
_ffbuild_missing_drivers=()
for _t in CC CXX; do
    _v="${!_t}"
    if ! command -v "$_v" >/dev/null 2>&1; then
        if [[ "${FFBUILD_ENV_CHECK_ONLY:-0}" == 1 ]]; then
            _ffbuild_missing_drivers+=("$_t=$_v")
        else
            echo "native/env.sh: $_t='$_v' was not found in PATH" >&2
            echo "  install it, set $_t, or pick FFBUILD_TOOLCHAIN_MODE=host|clang|gcc" >&2
            return 1 2>/dev/null || exit 1
        fi
    fi
done
if ((${#_ffbuild_missing_drivers[@]})); then
    echo "note: no usable compiler (${_ffbuild_missing_drivers[*]}); continuing because --check only diagnoses" >&2
fi
unset _t _v _ffbuild_missing_drivers

FFBUILD_COMPILER="$(_ffbuild_cc_kind "$CC")"
export FFBUILD_COMPILER

# If the caller forced CC but not CXX, keep the two drivers in the same family
# instead of pairing clang with the mode's default g++ (or vice versa).
if [[ -z "${FFBUILD_CXX:-}" && -z "${_FFBUILD_ENV_SNAP_CXX:-}" ]]; then
    case "$FFBUILD_COMPILER:$CXX" in
    clang:clang++) ;;
    gcc:g++) ;;
    clang:*)
        if command -v clang++ >/dev/null 2>&1; then CXX=clang++; export CXX; fi ;;
    gcc:*)
        if command -v g++ >/dev/null 2>&1; then CXX=g++; export CXX; fi ;;
    esac
fi

# A mode that only seeded defaults must not claim a compiler the caller overrode.
case "$FFBUILD_TOOLCHAIN_MODE:$FFBUILD_COMPILER" in
clang:clang|gcc:gcc|ctng:gcc) ;;
clang:*|gcc:*)
    echo "note: FFBUILD_TOOLCHAIN_MODE=$FFBUILD_TOOLCHAIN_MODE was overridden by CC=$CC ($FFBUILD_COMPILER)" >&2
    ;;
esac

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
# Date put into the artifact filename (together with the compiler). Override for
# reproducible names; it is deliberately independent of --extra-version.
export FFBUILD_BUILD_DATE="${FFBUILD_BUILD_DATE:-$(date +%Y%m%d)}"
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
#   -latomic only for clang: librubberband's static archive references
#            __atomic_is_lock_free. GCC inlines that builtin for known sizes, so
#            its objects carry no reference; clang emits a real call and the
#            probe link fails with "undefined reference to
#            `__atomic_is_lock_free'". Passing -latomic unconditionally breaks
#            hosts whose compiler has no libatomic.so (EL8's gcc-toolset before
#            gcc-toolset-14-libatomic-devel), where gcc does not need it at all.
export FFBUILD_EXTRA_LIBS="${FFBUILD_EXTRA_LIBS--lm -lstdc++}"
if [[ "$FFBUILD_COMPILER" == clang ]]; then
    [[ "$FFBUILD_EXTRA_LIBS" == *-latomic* ]] ||
        FFBUILD_EXTRA_LIBS="$FFBUILD_EXTRA_LIBS -latomic"
fi
# Both descriptors are generated into the repo (see ffbuild_write_toolchain_files
# below) so no root-owned copy under / is needed.  Stage scripts reach them
# through these variables.
export FFBUILD_CMAKE_TOOLCHAIN="${FFBUILD_CMAKE_TOOLCHAIN:-$FFBUILD_REPO_ROOT/toolchain/generated/toolchain.cmake}"
export FFBUILD_MESON_CROSS_FILE="${FFBUILD_MESON_CROSS_FILE:-$FFBUILD_REPO_ROOT/toolchain/generated/cross.meson}"

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
# 构建工具全部源码自建于 $FFBUILD_BUILDTOOLS_PREFIX/prefix（配方见
# native/buildtools.d/，驱动见 native/buildtools.sh）。该前缀只放 bin/ 与 share/，
# 不提供任何 .pc，也不进 PKG_CONFIG_LIBDIR —— 所以依赖构建看到的库永远只有
# $FFBUILD_PREFIX 那一套，这里也就不需要"系统版本够不够"的探测。
FFBUILD_BUILDTOOLS_PREFIX="${FFBUILD_BUILDTOOLS_PREFIX:-$FFBUILD_REPO_ROOT/.buildtools}"
export FFBUILD_BUILDTOOLS_PREFIX
FFBUILD_BUILDTOOLS_BIN="$FFBUILD_BUILDTOOLS_PREFIX/prefix/bin"
export FFBUILD_BUILDTOOLS_BIN

_ffbuild_path_prepend() {
    [[ -d "$1" ]] || return 0
    case ":$PATH:" in *":$1:"*) ;; *) PATH="$1:$PATH" ;; esac
}

# 自建工具永远排在发行版之前：用哪一套只由这里决定，不做版本比较。
_ffbuild_path_prepend "$FFBUILD_BUILDTOOLS_BIN"
if [[ -d "$FFBUILD_BUILDTOOLS_PREFIX/prefix/share/aclocal" ]]; then
    ACLOCAL_PATH="$FFBUILD_BUILDTOOLS_PREFIX/prefix/share/aclocal${ACLOCAL_PATH:+:$ACLOCAL_PATH}"
    export ACLOCAL_PATH
fi

# 构建期 Python 只有一个来源：venv（meson + jsonschema + jinja2）。它同时是
# python3，因此 venv/bin 必须在 PATH 最前。
FFBUILD_PYTHON_PREFIX="${FFBUILD_PYTHON_PREFIX:-$FFBUILD_BUILDTOOLS_PREFIX/venv}"
export FFBUILD_PYTHON_PREFIX
if [[ -x "$FFBUILD_PYTHON_PREFIX/bin/python3" ]]; then
    _ffbuild_path_prepend "$FFBUILD_PYTHON_PREFIX/bin"
fi
export PATH

# -------------------------------------------------------------- git env -------
# Download steps check out pinned commits, and git's detached-HEAD advice is
# pure noise here. GIT_CONFIG_* is a per-process override: nothing is written to
# ~/.gitconfig (util/run_stage.sh appends its safe.directory entry the same way).
if [[ -z "${FFBUILD_GIT_ENV_SET:-}" ]]; then
    _ffbuild_git_cfg="${GIT_CONFIG_COUNT:-0}"
    export GIT_CONFIG_COUNT=$((_ffbuild_git_cfg + 1))
    export "GIT_CONFIG_KEY_${_ffbuild_git_cfg}=advice.detachedHead"
    export "GIT_CONFIG_VALUE_${_ffbuild_git_cfg}=false"
    export FFBUILD_GIT_ENV_SET=1
    unset _ffbuild_git_cfg
fi

# -------------------------------------------------------------- rust PATH -----
# rav1e and librsvg build with cargo; librsvg even runs `cargo vendor` during its
# download step. `native/setup.sh` provisions this toolchain; it prefers the host's
# rustup toolchain and only downloads when there is none.
#
# Both homes belong to the build tree, not to the user's account: a build host
# should not get ~/.cargo or ~/.rustup behind its back, and "delete the repo"
# should delete the toolchain too. FFBUILD_CARGO_HOME / FFBUILD_RUSTUP_HOME are
# the knobs; CARGO_HOME / RUSTUP_HOME are always derived from them. Values the
# user exported are recorded so setup can say they were ignored.
FFBUILD_HOST_CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
FFBUILD_HOST_RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
FFBUILD_CARGO_HOME="${FFBUILD_CARGO_HOME:-$FFBUILD_BUILDTOOLS_PREFIX/cargo}"
FFBUILD_RUSTUP_HOME="${FFBUILD_RUSTUP_HOME:-$FFBUILD_BUILDTOOLS_PREFIX/rustup}"
export FFBUILD_HOST_CARGO_HOME FFBUILD_HOST_RUSTUP_HOME
export FFBUILD_CARGO_HOME FFBUILD_RUSTUP_HOME
unset FFBUILD_IGNORED_CARGO_HOME FFBUILD_IGNORED_RUSTUP_HOME
if [[ -n "${CARGO_HOME:-}" && "${CARGO_HOME}" != "$FFBUILD_CARGO_HOME" ]]; then
    export FFBUILD_IGNORED_CARGO_HOME="$CARGO_HOME"
fi
if [[ -n "${RUSTUP_HOME:-}" && "${RUSTUP_HOME}" != "$FFBUILD_RUSTUP_HOME" ]]; then
    export FFBUILD_IGNORED_RUSTUP_HOME="$RUSTUP_HOME"
fi
export CARGO_HOME="$FFBUILD_CARGO_HOME"
export RUSTUP_HOME="$FFBUILD_RUSTUP_HOME"
# cargo/rustc 是 rustup 的代理，装在哪里取决于 rustup 是怎么装的：setup 自己下载 rustup
# 时落在 $CARGO_HOME/bin，而"只把宿主工具链 link 进托管 RUSTUP_HOME"时，代理仍在宿主的
# ~/.cargo/bin。工具链本身始终来自 $RUSTUP_HOME，所以两处都找一遍。
for _ffbuild_rust_bin in "$CARGO_HOME/bin" "$FFBUILD_HOST_CARGO_HOME/bin"; do
    [[ -x "$_ffbuild_rust_bin/cargo" ]] || continue
    case ":$PATH:" in
        *":$_ffbuild_rust_bin:"*) ;;
        *) export PATH="$_ffbuild_rust_bin:$PATH" ;;
    esac
    break
done
unset _ffbuild_rust_bin

# -------------------------------------------------------------- ocaml --------
# OCaml is a documented prerequisite (fftw3 generates its codelets with OCaml's
# genfft, which needs ocamlbuild plus the findlib package "num"). When the host
# lacks either, native/setup.sh provisions OCaml through opam — and opam keeps
# everything under $FFBUILD_OPAM_ROOT, so no ~/.opam is created either.
#
# The switch's bin dir must win over a system OCaml: it carries the ocamlfind /
# ocamlbuild / num that match each other.
FFBUILD_OPAM_ROOT="${FFBUILD_OPAM_ROOT:-$FFBUILD_BUILDTOOLS_PREFIX/opam}"
export OPAMROOT="$FFBUILD_OPAM_ROOT/root"
if [[ -x "$OPAMROOT/default/bin/ocamlfind" ]]; then
    _ffbuild_path_prepend "$OPAMROOT/default/bin"
fi

# -------------------------------------------------------------- util PATH -----
# git-mini-clone / retry-tool live in util/bin (extension-less, like upstream's
# /usr/bin copies) and must be callable by name from stage download scripts.
# $FFBUILD_ROOT/bin is where upstream's image put helper binaries. Stages that
# would write one into a system directory (currently only glslc) use a full path
# from the environment instead; 50-shaderc requires FFBUILD_GLSLc and has no
# fallback, so it must stay exported here.
export FFBUILD_GLSLc="$FFBUILD_ROOT/bin/glslc"
for _d in "$FFBUILD_ROOT/bin" "$FFBUILD_REPO_ROOT/util/bin" "$FFBUILD_REPO_ROOT/util"; do
    case ":$PATH:" in
        *":$_d:"*) ;;
        *) export PATH="$_d:$PATH" ;;
    esac
done
unset _d

# ------------------------------------------------- toolchain descriptor files --
# Upstream supplied /cross.meson and /toolchain.cmake from the Docker image and
# referenced them by absolute path. We generate equivalent files inside the repo
# that reflect the *currently resolved* compilers, so compiler overrides are
# honoured in both meson and cmake stages.
#
# Stage scripts reach them via $FFBUILD_MESON_CROSS_FILE / $FFBUILD_CMAKE_TOOLCHAIN
# (the hard-coded meson paths were rewritten to use them), so this
# function needs no privileges and nothing has to be installed under /.
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
compiler       : $FFBUILD_COMPILER ($CC / $CXX)
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
