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
#   ./native/setup.sh                 # install core build prerequisites
#   ./native/setup.sh --all           # + optional deps (rust, node, extra libs)
#   ./native/setup.sh --with-rust     # rustup + cargo-c (needed by rav1e/librsvg)
#   ./native/setup.sh --with-ctng     # additionally build the crosstool-ng toolchain
#   ./native/setup.sh --no-apt        # skip package installation (host manages its own)
#   ./native/setup.sh --buildtools-only  # only build the managed build tools, touch nothing else
#   ./native/setup.sh --check         # only verify what is present
#   ./native/setup.sh --print-apt     # print the apt package list and exit
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=native/env.sh
source "$HERE/env.sh"

DO_CHECK=0
DO_ALL=0
WITH_RUST=0
WITH_CTNG=0
WITH_NODE=0
NO_APT=0
PRINT_APT=0
ONLY_BUILDTOOLS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
    --check)      DO_CHECK=1 ;;
    --all)        DO_ALL=1; WITH_RUST=1; WITH_NODE=1 ;;
    --with-rust)  WITH_RUST=1 ;;
    --with-node)  WITH_NODE=1 ;;
    --with-ctng)  WITH_CTNG=1 ;;
    --no-apt)     NO_APT=1 ;;
    --print-apt)  PRINT_APT=1 ;;
    --buildtools-only) ONLY_BUILDTOOLS=1 ;;
    -h|--help)    sed -n '3,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "setup.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------- sudo --------
if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=()
else
    SUDO=(sudo)
    if ! command -v sudo >/dev/null 2>&1; then
        echo "setup.sh: sudo is required (or run as root)" >&2; exit 1
    fi
fi

asroot() { "${SUDO[@]}" "$@"; }

# Version probe that is safe under `set -e`: a tool this script is about to
# install is by definition absent on a fresh host, and a bare
# `$(missing --version)` would abort setup with status 127 before the code
# that installs it ever runs.
probe_version() {
    local out=""
    out="$("$@" 2>/dev/null | head -n1)" || out=""
    printf '%s\n' "$out"
}

# Version comparison used by both --check and the install sections.
version_ge() {  # $1 >= $2 (version sort)
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]
}

# --------------------------------------------------------------- packages -----
# Package names target Debian 13 (trixie) and Ubuntu 24.04 (noble); entries that
# the running distro does not have are filtered out, so one list serves both.
APT_CORE=(
    build-essential gcc g++ binutils make patch
    pkg-config pkgconf
    git curl wget ca-certificates
    unzip zip tar xz-utils zstd p7zip-full libarchive-tools
    nasm yasm xxd
    autoconf automake autopoint gettext libtool libltdl-dev libtool-bin
    cmake ninja-build meson
    python3 python3-dev python3-pip python3-venv python3-setuptools
    python3-jinja2 python3-jsonschema python-is-python3
    flex bison gperf gawk
    libxml2-utils texinfo help2man groff
    rsync jq subversion mercurial
    clang llvm lld
    libc6-dev zlib1g-dev libssl-dev
)
APT_EXTRA=(
    gtk-doc-tools gobject-introspection itstool ragel indent
    default-jdk-headless ant
    ocaml ocaml-findlib ocamlbuild libnum-ocaml-dev
    wget2
)

apt_available() { apt-cache show "$1" >/dev/null 2>&1; }

filter_available() {
    local p out=()
    for p in "$@"; do apt_available "$p" && out+=("$p"); done
    printf '%s\n' "${out[@]}"
}

if [[ "$PRINT_APT" -eq 1 ]]; then
    printf '%s\n' "${APT_CORE[@]}" "${APT_EXTRA[@]}" | sort -u
    exit 0
fi

# ------------------------------------------------------------- check mode -----
# autoconf / automake / cmake / meson 不在此列：它们可能是 setup 自己构建的托管版本，
# 由下面的 "build tools" 表按版本下限判定。
REQUIRED_TOOLS=(gcc g++ make ninja pkg-config git patch svn tar xz zip nasm yasm libtoolize python3 gen-implib git-mini-clone retry-tool)
OPTIONAL_TOOLS=(clang cargo rustc node 7z xxd gperf bison flex ragel itstool help2man)

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
            printf '  [MISSING] %-14s\n' "$t"
        fi
    done
    echo "== build tools (policy: install only when the system is older) =="
    local ac_cur am_cur cm_cur ac_man am_man cm_man
    ac_cur="$(probe_version autoconf --version | awk '{print $NF}')"
    am_cur="$(probe_version automake --version | awk '{print $NF}')"
    cm_cur="$(probe_version cmake --version | awk '{print $3}')"
    ac_man="$(probe_version "$FFBUILD_AUTOCONF_PREFIX/bin/autoconf" --version | awk '{print $NF}')"
    am_man="$(probe_version "$FFBUILD_AUTOMAKE_PREFIX/bin/automake" --version | awk '{print $NF}')"
    cm_man="$(probe_version "$FFBUILD_CMAKE_PREFIX/bin/cmake" --version | awk '{print $3}')"
    btv() {  # <name> <system> <min> <managed>
        local verdict
        if [[ -n "$2" ]] && version_ge "$2" "$3"; then
            verdict="system ok"
        elif [[ -n "$4" ]] && version_ge "$4" "$3"; then
            verdict="managed ok"
        else
            verdict="NEEDS INSTALL"
        fi
        printf '  %-9s system=%-8s min=%-7s managed=%-8s %s\n' \
            "$1" "${2:-none}" "$3" "${4:-none}" "$verdict"
    }
    btv autoconf "$ac_cur" "$FFBUILD_BT_MIN_autoconf" "$ac_man"
    btv automake "$am_cur" "$FFBUILD_BT_MIN_automake" "$am_man"
    # 裸名达标不等于够用：libiconv 的 Makefile.devel 写死 automake-1.18。
    local am_major
    am_major="${FFBUILD_BT_INSTALL_automake%.*}"
    if command -v "automake-$am_major" >/dev/null 2>&1; then
        printf '  %-9s automake-%s: %s\n' "" "$am_major" "$(command -v "automake-$am_major")"
    else
        printf '  %-9s [MISSING] automake-%s (libiconv calls it by name)\n' "" "$am_major"
    fi
    btv cmake    "$cm_cur" "$FFBUILD_BT_MIN_cmake"    "$cm_man"
    local py_bin py_ver
    py_bin=""
    for _c in python3.13 python3.12 python3.11 python3.10 python3; do
        command -v "$_c" >/dev/null 2>&1 || continue
        _v="$("$_c" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
        [[ -n "$_v" ]] || continue
        if version_ge "$_v" "$FFBUILD_BT_SYSTEM_python"; then py_bin="$_c"; py_ver="$_v"; break; fi
    done
    if [[ -n "$py_bin" ]]; then
        printf '  %-9s system=%-8s min=%-7s ok (%s)\n' python "$py_ver" "$FFBUILD_BT_SYSTEM_python" "$py_bin"
    else
        printf '  %-9s system=%-8s min=%-7s NEEDS INSTALL\n' python "${py_ver:-none}" "$FFBUILD_BT_SYSTEM_python"
    fi
    printf '  managed root: %s\n' "$FFBUILD_BUILDTOOLS_PREFIX"
    echo

    echo "== runtime prerequisites (not managed; install from your distro) =="
    rt_ok()      { printf '  [ok]      %s\n' "$1"; }
    rt_missing() { printf '  [MISSING] %s\n              %s\n' "$1" "$2"; }

    if perl -MTime::Piece -e1 2>/dev/null; then
        rt_ok "perl(Time::Piece)      openssl"
    else
        rt_missing "perl(Time::Piece)      openssl" \
                   "dnf install 'perl(Time::Piece)'  |  apt-get install perl"
    fi

    ap_ver="$(probe_version autopoint --version | awk '{print $NF}')"
    if [[ -n "$ap_ver" ]] && version_ge "$ap_ver" "0.21"; then
        rt_ok "autopoint >= 0.21      zvbi (found $ap_ver)"
    else
        rt_missing "autopoint >= 0.21      zvbi" \
                   "dnf install gettext-devel  |  apt-get install autopoint"
    fi

    if command -v ocaml >/dev/null 2>&1 && command -v ocamlbuild >/dev/null 2>&1 &&
       command -v ocamlfind >/dev/null 2>&1 &&
       ocamlfind list 2>/dev/null | grep -q '^num '; then
        rt_ok "OCaml + findlib + num  fftw3"
    else
        rt_missing "OCaml + findlib + num  fftw3" \
                   "dnf install ocaml ocaml-findlib ocaml-ocamlbuild; num from source or opam"
    fi

    cc_major="$(c++ -dumpversion 2>/dev/null | awk -F. '{print $1}')"
    if [[ -n "$cc_major" ]] && (( cc_major >= 9 )); then
        rt_ok "system c++ >= 9        shaderc native_build (found $cc_major)"
    else
        rt_missing "system c++ >= 9        shaderc native_build" \
                   "dnf install gcc-toolset-14 and put its bin before /usr/bin"
    fi

    ossl_ver="$(openssl version 2>/dev/null | awk '{print $2}')"
    if [[ -n "$ossl_ver" ]] && version_ge "$ossl_ver" "3"; then
        rt_ok "OpenSSL >= 3           cargo-c (found $ossl_ver)"
    else
        rt_missing "OpenSSL >= 3           cargo-c" \
                   "dnf install openssl3-devel; then OPENSSL_INCLUDE_DIR=/usr/include/openssl3 OPENSSL_LIB_DIR=/usr/lib64/openssl3"
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
    echo "== system paths provisioned by setup =="
    for f in /cross.meson /toolchain.cmake /patches /opt/glslc /usr/share/aclocal /opt/implib/implib-gen.py; do
        if [[ -e "$f" ]]; then
            printf '  [ok]      %s\n' "$f"
        else
            printf '  [MISSING] %s\n' "$f"
        fi
    done
    echo
    ffbuild_env_dump
    if ((${#missing[@]})); then
        echo
        echo "Missing required tools: ${missing[*]}"
        echo "Run: ./native/setup.sh"
        return 1
    fi
}

if [[ "$DO_CHECK" -eq 1 ]]; then
    do_check
    exit $?
fi

# ----------------------------------------------------------- apt install -----
echo "== installing build prerequisites (apt) =="
# --no-apt is for hosts whose packages are managed outside this script (shared
# machines, non-Debian distros); the rest of setup still runs.
# apt may be unusable for reasons unrelated to this project (e.g. a malformed
# sources file). That must not be fatal: the tools may already be installed.
APT_OK=1
if [[ "$NO_APT" -eq 1 ]]; then
    APT_OK=0
    echo "note: --no-apt: skipping package installation (tools must already be present)"
elif ! asroot apt-get update; then
    APT_OK=0
    echo "WARNING: 'apt-get update' failed; skipping apt-based installation." >&2
    echo "         Run './native/setup.sh --check' to see what is already present." >&2
fi

if [[ "$APT_OK" -eq 1 ]]; then
    PKGS=("${APT_CORE[@]}")
    [[ "$DO_ALL" -eq 1 || "$WITH_RUST" -eq 1 ]] && PKGS+=("${APT_EXTRA[@]}")

    MAPFILE_PKGS=()
    while IFS= read -r p; do [[ -n "$p" ]] && MAPFILE_PKGS+=("$p"); done < <(filter_available "${PKGS[@]}")

    SKIPPED=()
    for p in "${PKGS[@]}"; do
        apt_available "$p" || SKIPPED+=("$p")
    done

    if ((${#MAPFILE_PKGS[@]})); then
        asroot env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${MAPFILE_PKGS[@]}" \
            || echo "WARNING: 'apt-get install' failed; run './native/setup.sh --check' to see what is missing" >&2
    fi
    if ((${#SKIPPED[@]})); then
        echo "note: not available in this distro, skipped: ${SKIPPED[*]}"
    fi
else
    echo "note: apt not usable on this host — skipping package installation"
fi

# ------------------------------------------------------------ build tools -----
# 版本下限与来源见 native/buildtools.lock。策略是"只补不足"：系统版本够用就
# 不装；不够才把对应版本构建进 $FFBUILD_BUILDTOOLS_PREFIX（默认 <repo>/.buildtools）。
# 该目录属当前用户、位于仓库内、不入库，安装过程不需要 root，也不影响同机其他项目。
BT_PREFIX="$FFBUILD_BUILDTOOLS_PREFIX"
BT_JOBS="${FFBUILD_JOBS:-$(nproc 2>/dev/null || echo 4)}"
mkdir -p "$BT_PREFIX"

bt_fetch() {  # <url> <dest> <sha256>
    local url="$1" dest="$2" want="$3" got=""
    if ! curl -fsSL --max-time 300 -o "$dest" "$url" 2>/dev/null &&
       ! wget -q -O "$dest" "$url" 2>/dev/null; then
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

bt_unpack() {  # <url> <sha256> -> prints a temp dir containing ./src
    local tmp
    tmp="$(mktemp -d)"
    bt_fetch "$1" "$tmp/src.tar" "$2" || { rm -rf "$tmp"; return 1; }
    mkdir -p "$tmp/src"
    tar -xf "$tmp/src.tar" -C "$tmp/src" --strip-components=1 || { rm -rf "$tmp"; return 1; }
    printf '%s\n' "$tmp"
}

# Build tools must not inherit the *FFmpeg build* environment: env.sh exports
# CFLAGS/CXXFLAGS/LDFLAGS pointing at $FFBUILD_PREFIX, whose headers and libs are
# for the target dependency tree. Feeding them to cmake's bootstrap produced
# "undefined reference to inflate" (prefix zlib.h, no -lz on the link line).
bt_clean_env() {  # runs a command without the build's compiler/flag overrides
    (
        unset CC CXX LD AR RANLIB NM STRIP
        unset CFLAGS CXXFLAGS LDFLAGS LDEXEFLAGS CPPFLAGS
        unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR ACLOCAL_PATH
        "$@"
    )
}

bt_build_configure() {  # <url> <sha256> <prefix>
    local tmp
    tmp="$(bt_unpack "$1" "$2")" || return 1
    if bt_clean_env bash -c 'cd "$1" && ./configure --prefix="$2" && make -j"$3" && make install' \
           _ "$tmp/src" "$3" "$BT_JOBS" >/dev/null 2>&1; then
        rm -rf "$tmp"
        return 0
    fi
    echo "  WARNING: build failed; source tree left at $tmp/src" >&2
    return 1
}

bt_build_cmake() {  # <url> <sha256> <prefix>
    local tmp
    tmp="$(bt_unpack "$1" "$2")" || return 1
    if bt_clean_env bash -c 'cd "$1" && ./bootstrap --prefix="$2" --parallel="$3" && make -j"$3" && make install' \
           _ "$tmp/src" "$3" "$BT_JOBS" >/dev/null 2>&1; then
        rm -rf "$tmp"
        return 0
    fi
    echo "  WARNING: build failed; source tree left at $tmp/src" >&2
    return 1
}

# --------------------------------------------------------------- autoconf -----
ac_cur="$(probe_version autoconf --version | awk '{print $NF}')"
ac_man="$(probe_version "$FFBUILD_AUTOCONF_PREFIX/bin/autoconf" --version | awk '{print $NF}')"
if [[ -n "$ac_cur" ]] && version_ge "$ac_cur" "$FFBUILD_BT_MIN_autoconf"; then
    echo "note: system autoconf $ac_cur >= $FFBUILD_BT_MIN_autoconf"
elif [[ -n "$ac_man" ]] && version_ge "$ac_man" "$FFBUILD_BT_MIN_autoconf"; then
    echo "note: managed autoconf $ac_man ready at $FFBUILD_AUTOCONF_PREFIX"
else
    echo "== building autoconf $FFBUILD_BT_INSTALL_autoconf into $FFBUILD_AUTOCONF_PREFIX =="
    bt_build_configure "$FFBUILD_BT_URL_autoconf" "$FFBUILD_BT_SHA256_autoconf" "$FFBUILD_AUTOCONF_PREFIX" ||
        echo "  WARNING: autoconf build failed" >&2
fi

# --------------------------------------------------------------- automake -----
# 裸名 automake 的图内下限是 1.16.3（libxml2），而 libiconv 的 Makefile.devel
# 写死 automake-1.18 / aclocal-1.18。只要系统不是 >= 1.18，就要装一份 1.18，
# 才能同时满足这两条。
am_cur="$(probe_version automake --version | awk '{print $NF}')"
am_major="${FFBUILD_BT_INSTALL_automake%.*}"
am_man="$(probe_version "$FFBUILD_AUTOMAKE_PREFIX/bin/automake" --version | awk '{print $NF}')"
if [[ -n "$am_cur" ]] && version_ge "$am_cur" "$am_major"; then
    echo "note: system automake $am_cur provides automake-$am_major"
elif [[ -n "$am_man" ]] && version_ge "$am_man" "$am_major"; then
    echo "note: managed automake $am_man ready at $FFBUILD_AUTOMAKE_PREFIX"
else
    echo "== building automake $FFBUILD_BT_INSTALL_automake into $FFBUILD_AUTOMAKE_PREFIX =="
    bt_build_configure "$FFBUILD_BT_URL_automake" "$FFBUILD_BT_SHA256_automake" "$FFBUILD_AUTOMAKE_PREFIX" ||
        echo "  WARNING: automake build failed" >&2
fi

# ------------------------------------------------------------------ cmake -----
cm_cur="$(probe_version cmake --version | awk '{print $3}')"
cm_man="$(probe_version "$FFBUILD_CMAKE_PREFIX/bin/cmake" --version | awk '{print $3}')"
if [[ -n "$cm_cur" ]] && version_ge "$cm_cur" "$FFBUILD_BT_MIN_cmake"; then
    echo "note: system cmake $cm_cur >= $FFBUILD_BT_MIN_cmake"
elif [[ -n "$cm_man" ]] && version_ge "$cm_man" "$FFBUILD_BT_MIN_cmake"; then
    echo "note: managed cmake $cm_man ready at $FFBUILD_CMAKE_PREFIX"
else
    echo "== building cmake $FFBUILD_BT_INSTALL_cmake into $FFBUILD_CMAKE_PREFIX (takes a while) =="
    bt_build_cmake "$FFBUILD_BT_URL_cmake" "$FFBUILD_BT_SHA256_cmake" "$FFBUILD_CMAKE_PREFIX" ||
        echo "  WARNING: cmake build failed" >&2
fi

# ----------------------------------------------------------------- gettext -----
# zvbi 的 configure.ac 声明 AM_GNU_GETTEXT_VERSION([0.21])，autopoint 在版本
# 不足时会直接拒绝执行（EL8 只有 0.19.8）。
ap_cur="$(probe_version autopoint --version | awk '{print $NF}')"
ap_man="$(probe_version "$FFBUILD_GETTEXT_PREFIX/bin/autopoint" --version | awk '{print $NF}')"
if [[ -n "$ap_cur" ]] && version_ge "$ap_cur" "$FFBUILD_BT_MIN_gettext"; then
    echo "note: system autopoint $ap_cur >= $FFBUILD_BT_MIN_gettext"
elif [[ -n "$ap_man" ]] && version_ge "$ap_man" "$FFBUILD_BT_MIN_gettext"; then
    echo "note: managed gettext $ap_man ready at $FFBUILD_GETTEXT_PREFIX"
else
    echo "== building gettext $FFBUILD_BT_INSTALL_gettext into $FFBUILD_GETTEXT_PREFIX =="
    bt_build_configure "$FFBUILD_BT_URL_gettext" "$FFBUILD_BT_SHA256_gettext" "$FFBUILD_GETTEXT_PREFIX" ||
        echo "  WARNING: gettext build failed" >&2
fi

# ----------------------------------------------------------------- python -----
# 构建只需要一个解释器：这个 venv。它同时提供 meson 与 jsonschema/jinja2。
# Python 本身不构建——版本不足时给出对应发行版的安装命令。
PY_MIN="$FFBUILD_BT_SYSTEM_python"
PYBIN=""
for _c in python3.13 python3.12 python3.11 python3.10 python3; do
    command -v "$_c" >/dev/null 2>&1 || continue
    _v="$("$_c" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
    [[ -n "$_v" ]] || continue
    if version_ge "$_v" "$PY_MIN"; then PYBIN="$(command -v "$_c")"; break; fi
done
if [[ -z "$PYBIN" ]]; then
    echo "ERROR: no python >= $PY_MIN found; it is needed to host the build venv." >&2
    echo "  Rocky/RHEL 8:  sudo dnf install python3.12" >&2
    echo "  Debian/Ubuntu: sudo apt-get install python3" >&2
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
    if [[ ! -x "$FFBUILD_PYTHON_PREFIX/bin/python3" ]]; then
        "$PYBIN" -m venv "$FFBUILD_PYTHON_PREFIX" ||
            { echo "  WARNING: could not create venv with $PYBIN" >&2; }
    fi
    if [[ -x "$FFBUILD_PYTHON_PREFIX/bin/pip" ]] &&
        "$FFBUILD_PYTHON_PREFIX/bin/pip" install --quiet --upgrade pip "${PY_MODULES[@]}"; then
        echo "  python: $("$FFBUILD_PYTHON_PREFIX/bin/python3" -V 2>&1)"
        echo "  meson:  $("$FFBUILD_PYTHON_PREFIX/bin/meson" --version 2>/dev/null)"
    else
        echo "  WARNING: could not install ${PY_MODULES[*]} into $FFBUILD_PYTHON_PREFIX" >&2
    fi
fi

if [[ "$ONLY_BUILDTOOLS" -eq 1 ]]; then
    echo "note: --buildtools-only set; skipping system paths and build root"
    exit 0
fi

# --------------------------------------------------- toolchain descriptor -----
# Upstream stage scripts reference these by absolute path:
#   32 meson stages: --cross-file=/cross.meson
#   ~10 cmake stages: -DCMAKE_TOOLCHAIN_FILE=/toolchain.cmake
# We can't remove those absolute references without patching stage scripts, so
# instead we symlink them to generated files inside the repo. build.sh then
# refreshes those files (no root needed) so they always reflect the resolved
# compilers and toolchain mode.
echo "== installing toolchain descriptor files =="
mkdir -p "$FFBUILD_REPO_ROOT/toolchain/generated"
ffbuild_write_toolchain_files

for name in cross.meson toolchain.cmake; do
    target="/$name"
    src="$FFBUILD_REPO_ROOT/toolchain/generated/$name"
    if asroot ln -sfn "$src" "$target" 2>/dev/null; then
        echo "  linked $target -> $src"
    elif [[ -e "$target" ]]; then
        echo "  note: $target already exists but is not a symlink; refreshing it instead"
        asroot rm -f "$target" && asroot ln -sfn "$src" "$target" || \
            echo "  WARNING: could not link $target (need root)" >&2
    else
        echo "  WARNING: could not create $target (need root)" >&2
    fi
done

# ------------------------------------------------------------ build root ------
echo "== creating build root =="
mkdir -p "$FFBUILD_ROOT"/{prefix,destdir,work,log} "$FFBUILD_ROOT/prefix/lib/pkgconfig" "$FFBUILD_ROOT/prefix/include" "$FFBUILD_ROOT/prefix/bin"
echo "  $FFBUILD_ROOT"

# --------------------------------------------- writable system paths ----------
# The Docker image ran as root, so a handful of stage scripts write to system
# locations directly. We cannot hand the build user root, so we pre-create
# exactly those paths owned by the build user. Each one also has an in-repo
# alternative that keeps scripts.d unmodified.
echo "== provisioning writable system paths =="
build_uid="$(id -u)"; build_gid="$(id -g)"

# 45-x11/10-xtrans.sh copies xorg macros there; also covered by $ACLOCAL_PATH.
if asroot mkdir -p /usr/share/aclocal && asroot chown "$build_uid:$build_gid" /usr/share/aclocal; then
    echo "  /usr/share/aclocal  (writable)"
else
    echo "  WARNING: /usr/share/aclocal not writable (45-x11/10-xtrans may fail)" >&2
fi

# 47-vulkan/50-shaderc.sh copies the glslc binary there.
if asroot touch /opt/glslc && asroot chown "$build_uid:$build_gid" /opt/glslc; then
    echo "  /opt/glslc          (writable)"
else
    echo "  WARNING: /opt/glslc not writable (47-vulkan/50-shaderc may fail)" >&2
fi

# Upstream bind-mounts patches/<name> at /patches per stage (aom, aribb24).
# Point /patches at a repo-local dir the driver can repopulate without root.
mkdir -p "$FFBUILD_REPO_ROOT/patches-current"
if asroot ln -sfn "$FFBUILD_REPO_ROOT/patches-current" /patches; then
    echo "  /patches -> $FFBUILD_REPO_ROOT/patches-current"
else
    echo "  WARNING: could not create /patches symlink (aom/aribb24 patches unavailable)" >&2
fi

# 45-x11 / 50-vaapi stages call gen-implib (util/bin/gen-implib), which needs
# yugr/Implib.so — the Docker image installed it at /opt/implib.
# Clone as the current user (so the proxy environment is available) and only
# use root for the final placement.
IMPLIB_DIR="${FFBUILD_IMPLIB_DIR:-/opt/implib}"
if [[ -f "$IMPLIB_DIR/implib-gen.py" ]]; then
    echo "  Implib.so           (already present at $IMPLIB_DIR)"
else
    echo "== installing Implib.so =="
    implib_tmp="$(mktemp -d)"
    if git clone --filter=blob:none --depth=1 https://github.com/yugr/Implib.so "$implib_tmp/Implib.so"; then
        asroot rm -rf "$IMPLIB_DIR"
        if asroot mv "$implib_tmp/Implib.so" "$IMPLIB_DIR"; then
            echo "  Implib.so           (installed at $IMPLIB_DIR)"
        else
            echo "  WARNING: could not place Implib.so at $IMPLIB_DIR" >&2
        fi
    else
        echo "  WARNING: could not clone Implib.so (gen-implib will fail)" >&2
    fi
    rm -rf "$implib_tmp"
fi

# The upstream base image sets a git identity; `git am` in the aom/aribb24
# stages needs one.
if ! git config --global user.email >/dev/null 2>&1; then
    git config --global user.email "builder@localhost"
    git config --global user.name "Builder"
    echo "  git identity configured (builder@localhost)"
fi
git config --global advice.detachedHead false 2>/dev/null || true

# ---------------------------------------------------------------- rust --------
if [[ "$WITH_RUST" -eq 1 ]]; then
    echo "== installing rust toolchain (rustup + cargo-c) =="
    export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
    export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
    if ! command -v rustup >/dev/null 2>&1; then
        curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path
    fi
    # shellcheck disable=SC1091
    source "$CARGO_HOME/env" 2>/dev/null || true
    # cargo-c's build must see *system* pkg-config files (e.g. openssl); the
    # prefix-only PKG_CONFIG_LIBDIR installed by native/env.sh would hide them.
    #
    # Its curl-sys dependency bundles a curl that requires OpenSSL >= 3.  EL8
    # ships 1.1.1; EPEL's openssl3-devel installs a parallel tree, so point
    # openssl-sys at it instead of failing with "OpenSSL 3.0.0 or greater".
    if [[ "$(openssl version 2>/dev/null | awk '{print $2}' | cut -d. -f1)" -lt 3 ]]; then
        if [[ -f /usr/include/openssl3/openssl/ssl.h ]]; then
            export OPENSSL_INCLUDE_DIR=/usr/include/openssl3
            export OPENSSL_LIB_DIR=/usr/lib64/openssl3
            echo "  note: cargo-c will build against OpenSSL 3 (/usr/include/openssl3)"
        else
            echo "  WARNING: OpenSSL < 3 and openssl3-devel is missing; cargo-c may fail" >&2
            echo "           install it (dnf install openssl3-devel) or skip --with-rust" >&2
        fi
    fi
    if ! command -v cargo-cinstall >/dev/null 2>&1; then
        (
            unset PKG_CONFIG_LIBDIR PKG_CONFIG_PATH
            cargo install cargo-c
        )
    fi
else
    command -v cargo >/dev/null 2>&1 || echo "note: rust/cargo absent — rav1e & librsvg(rust) will be skipped. Use --with-rust."
fi

# ---------------------------------------------------------------- node --------
if [[ "$WITH_NODE" -eq 1 ]]; then
    echo "== installing nodejs =="
    if ! command -v node >/dev/null 2>&1; then
        asroot env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs npm
    fi
fi

# ---------------------------------------------------------------- ct-ng -------
if [[ "$WITH_CTNG" -eq 1 ]]; then
    echo "== building crosstool-ng toolchain (this takes a long time) =="
    CTNG_SRC="$FFBUILD_ROOT/ctng-src"
    mkdir -p "$FFBUILD_ROOT"
    if [[ ! -d "$CTNG_SRC/.git" ]]; then
        git clone --filter=blob:none https://github.com/crosstool-ng/crosstool-ng.git "$CTNG_SRC"
    fi
    (
        cd "$CTNG_SRC"
        ./bootstrap
        ./configure --prefix="$FFBUILD_CTNG_ROOT" --enable-local
        make -j"$FFBUILD_JOBS"
        cp "$FFBUILD_REPO_ROOT/toolchain/ctng/ct-ng-config" .config
        ./ct-ng build
    )
    echo "ct-ng toolchain installed under $FFBUILD_CTNG_ROOT"
    echo "Enable it with: FFBUILD_TOOLCHAIN_MODE=ctng ./build.sh linux64 gpl"
fi

echo
echo "== setup complete =="
ffbuild_env_dump
echo
echo "Next: ./native/download.sh && ./build.sh linux64 gpl"
