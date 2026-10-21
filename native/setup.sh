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

# ------------------------------------------------------------- pkg manager ----
# 只在这一步决定“能不能代装”和“给用户哪条命令”。包名与仓库在不同发行版之间差异太大
# （EL8 的 nasm 在 CRB、有的发行版根本没有 OCaml 的 num 包），逐发行版硬编码不划算。
PKG_MGR=""
for _pm in apt-get dnf pacman zypper; do
    if command -v "$_pm" >/dev/null 2>&1; then PKG_MGR="$_pm"; break; fi
done
unset _pm

# install_hint <apt> <dnf> <pacman> [zypper] -> 一行可直接粘贴的命令
install_hint() {
    case "${PKG_MGR:-none}" in
        apt-get) echo "apt-get install $1" ;;
        dnf)     echo "dnf install $2" ;;
        pacman)  echo "pacman -S $3" ;;
        zypper)  echo "zypper install ${4:-$2}" ;;
        *)       echo "apt: $1 | dnf: $2 | pacman: $3" ;;
    esac
}

# tool_hint <tool> -> 单个缺失工具的安装命令
tool_hint() {
    case "$1" in
        gcc|g++|make|patch|libtoolize)
            install_hint "build-essential" "gcc gcc-c++ make patch libtool" "base-devel" ;;
        ninja)      install_hint ninja-build ninja-build ninja ;;
        pkg-config) install_hint pkg-config pkgconf-pkg-config pkgconf ;;
        svn)        install_hint subversion subversion subversion ;;
        nasm)       install_hint nasm nasm nasm ;;
        zip)        install_hint zip zip zip ;;
        tar)        install_hint tar tar tar ;;
        xz)         install_hint xz-utils xz xz ;;
        git)        install_hint git git git ;;
        yasm)       install_hint yasm yasm yasm ;;
        cmake)      install_hint cmake cmake cmake ;;
        python3)    install_hint "python3 python3-venv" "python3.12 python3.12-devel" python ;;
        texinfo|makeinfo) install_hint texinfo texinfo texinfo ;;
        unzip)      install_hint unzip unzip unzip ;;
        ant)        install_hint "ant default-jdk-headless" "ant java-17-openjdk-headless" "ant jdk-openjdk" ;;
        openssl3-devel|openssl-devel|libssl-dev)
            install_hint "libssl-dev" "openssl-devel (EL8: openssl3-devel)" openssl ;;
        ocaml)      install_hint "ocaml ocaml-findlib ocamlbuild libnum-ocaml-dev" \
                                 "ocaml ocaml-findlib ocaml-ocamlbuild" \
                                 "ocaml ocaml-findlib ocamlbuild" ;;
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
            printf '  [MISSING] %-14s %s\n' "$t" "$(tool_hint "$t")"
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
    # automake 有两条独立需求：裸名 >= 1.16.3（libxml2），以及 libiconv 写死的
    # automake-1.18。系统版本比 1.18 新也未必提供那个名字（Arch 1.19 只给 1.19），
    # 所以这条的判定看的是版本名在不在，而不是版本号大小。
    local am_major am_name am_verdict
    am_major="${FFBUILD_BT_INSTALL_automake%.*}"
    am_name="$(command -v "automake-$am_major" 2>/dev/null || true)"
    if [[ -z "$am_name" ]]; then
        am_verdict="NEEDS INSTALL (no automake-$am_major)"
    elif { [[ -n "$am_cur" ]] && version_ge "$am_cur" "$FFBUILD_BT_MIN_automake"; } ||
         { [[ -n "$am_man" ]] && version_ge "$am_man" "$FFBUILD_BT_MIN_automake"; }; then
        am_verdict="ok ($am_name)"
    else
        am_verdict="NEEDS INSTALL (bare automake < $FFBUILD_BT_MIN_automake)"
    fi
    printf '  %-9s system=%-8s min=%-7s managed=%-8s %s\n' \
        automake "${am_cur:-none}" "$FFBUILD_BT_MIN_automake" "${am_man:-none}" "$am_verdict"
    btv cmake    "$cm_cur" "$FFBUILD_BT_MIN_cmake"    "$cm_man"
    if [[ -z "$cm_man" ]] && { [[ -z "$cm_cur" ]] || ! version_ge "$cm_cur" "$FFBUILD_BT_MIN_cmake"; }; then
        printf '              -> %s  (or re-run ./native/setup.sh to build %s into .buildtools)\n' \
            "$(tool_hint cmake)" "$FFBUILD_BT_INSTALL_cmake"
    fi
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
    # 第三个参数为 optional 时只提示、不影响退出码（例如 cargo-c 的 OpenSSL 3 只在 --with-rust 时需要）。
    rt_blocking=0
    rt_missing() {
        printf '  [MISSING] %s\n              %s\n' "$1" "$2"
        [[ "${3:-}" == optional ]] || rt_blocking=1
    }

    if perl -MTime::Piece -e1 2>/dev/null; then
        rt_ok "perl(Time::Piece)      openssl"
    else
        rt_missing "perl(Time::Piece)      openssl" \
                   "dnf install 'perl(Time::Piece)'  |  apt-get install perl"
    fi

    if command -v makeinfo >/dev/null 2>&1; then
        rt_ok "makeinfo (texinfo)     gmp 等 autotools 文档"
    else
        rt_missing "makeinfo (texinfo)     autotools 文档" "$(tool_hint texinfo)"
    fi

    if command -v ant >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
        rt_ok "ant + JDK              libbluray (BD-J)"
    else
        rt_missing "ant + JDK              libbluray (BD-J)" "$(tool_hint ant)"
    fi

    ap_ver="$(probe_version autopoint --version | awk '{print $NF}')"
    if [[ -n "$ap_ver" ]] && version_ge "$ap_ver" "0.21"; then
        rt_ok "autopoint >= 0.21      zvbi (found $ap_ver)"
    else
        rt_missing "autopoint >= 0.21      zvbi" \
                   "dnf install gettext-devel  |  apt-get install autopoint"
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
    fi
    case "$ocaml_ok" in
    1) rt_ok "OCaml + findlib + num  fftw3 (system)" ;;
    2) rt_ok "OCaml + findlib + num  fftw3 (managed: $OPAMROOT)" ;;
    *) rt_missing "OCaml + findlib + num  fftw3" \
                   "apt install ocaml ocaml-findlib ocamlbuild libnum-ocaml-dev | dnf install ocaml ocaml-findlib ocaml-ocamlbuild (num has no rpm) | pacman -S ocaml ocaml-findlib ocamlbuild; setup.sh provisions it through opam when num is missing" ;;
    esac

    cc_major="$(c++ -dumpversion 2>/dev/null | awk -F. '{print $1}')"
    if [[ -n "$cc_major" ]] && (( cc_major >= 9 )); then
        rt_ok "system c++ >= 9        shaderc native_build (found $cc_major)"
    else
        rt_missing "system c++ >= 9        shaderc native_build" \
                   "dnf install gcc-toolset-14 and put its bin before /usr/bin"
    fi

    # cargo-c needs OpenSSL 3 *development* files, not the CLI: on EL8 the
    # system openssl stays at 1.1.1 while openssl3-devel provides a parallel
    # tree that setup points openssl-sys at.
    ossl_ver="$(openssl version 2>/dev/null | awk '{print $2}')"
    if [[ -n "$ossl_ver" ]] && version_ge "$ossl_ver" "3"; then
        rt_ok "OpenSSL >= 3           cargo-c (found $ossl_ver)"
    elif [[ -f /usr/include/openssl3/openssl/ssl.h ]]; then
        rt_ok "OpenSSL 3 dev tree     cargo-c (/usr/include/openssl3, system $ossl_ver)"
    else
        rt_missing "OpenSSL >= 3           cargo-c" "$(tool_hint openssl3-devel)" optional
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
    if ((${#missing[@]})) || (( rt_blocking )); then
        echo
        if ((${#missing[@]})); then
            echo "Missing required tools: ${missing[*]}"
        fi
        if (( rt_blocking )); then
            echo "Missing runtime prerequisites: see the [MISSING] lines above."
        fi
        echo "  distro packages: install them as shown above (README §2.1), then re-run this check."
        echo "  managed tools  : if cmake / nasm / yasm / OCaml are the gaps, './native/setup.sh'"
        echo "                   builds them — failures are explained inline, logs in"
        echo "                   $FFBUILD_BUILDTOOLS_PREFIX/log/."
        return 1
    fi
}

if [[ "$DO_CHECK" -eq 1 ]]; then
    do_check
    exit $?
fi

# ------------------------------------------------------- package install -----
# 只代装 apt 能装的东西。其他发行版不猜包名、也不去碰 sudo，直接把命令打给用户 ——
# 猜错的代价（装错包、改坏仓库、在无 tty 时抛 sudo 错误）比省下的几步大得多。
# --no-apt 供“包由外部管理”的宿主使用；其余步骤照常进行。
APT_OK=1
if [[ "$NO_APT" -eq 1 ]]; then
    APT_OK=0
    echo "note: --no-apt: skipping package installation (tools must already be present)"
elif [[ "$PKG_MGR" != "apt-get" ]]; then
    APT_OK=0
    echo "note: no apt here (detected: ${PKG_MGR:-none}) — install distro packages yourself, then re-run --check"
    echo "      $(install_hint \
        "build-essential pkg-config m4 perl python3 nasm yasm cmake ninja-build texinfo ant default-jdk-headless" \
        "powertools: nasm yasm ninja-build gperf help2man; gcc gcc-c++ make patch m4 perl python3.12 cmake texinfo ant java-17-openjdk-headless" \
        "base-devel pkgconf m4 perl python nasm yasm cmake ninja texinfo ant jdk-openjdk")"
else
    echo "== installing build prerequisites (apt) =="
    if ! asroot apt-get update; then
        APT_OK=0
        echo "WARNING: 'apt-get update' failed; skipping apt-based installation." >&2
        echo "         Run './native/setup.sh --check' to see what is already present." >&2
    fi
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

# 托管构建的输出不再丢进 /dev/null：失败时用户至少能看到最后一屏错误，
# 完整日志留在 .buildtools/log/ 里（重启后仍在，便于事后排查）。
bt_logfile() {  # <prefix> -> <prefix 的 basename>.log
    mkdir -p "$BT_PREFIX/log"
    printf '%s/log/%s.log' "$BT_PREFIX" "$(basename "$1")"
}

bt_build_failed() {  # <logfile> <src-dir>
    echo "  WARNING: build failed" >&2
    echo "    log:  $1" >&2
    tail -n 4 "$1" 2>/dev/null | sed 's/^/    | /' >&2
    echo "    src:  $2 (left for inspection)" >&2
}

bt_build_configure() {  # <url> <sha256> <prefix> [cflags]
    local tmp log
    tmp="$(bt_unpack "$1" "$2")" || return 1
    log="$(bt_logfile "$3")"
    if bt_clean_env bash -c 'cd "$1" && CFLAGS="$4" ./configure --prefix="$2" && make -j"$3" && make install' \
           _ "$tmp/src" "$3" "$BT_JOBS" "${4:-}" >"$log" 2>&1; then
        rm -rf "$tmp"
        echo "  ok: $(basename "$3")"
        return 0
    fi
    bt_build_failed "$log" "$tmp/src"
    return 1
}

bt_build_cmake() {  # <url> <sha256> <prefix> [extra C++ flags]
    local tmp log
    tmp="$(bt_unpack "$1" "$2")" || return 1
    log="$(bt_logfile "$3")"
    if bt_clean_env bash -c 'cd "$1" && CXXFLAGS="$4" ./bootstrap --prefix="$2" --parallel="$3" && make -j"$3" && make install' \
           _ "$tmp/src" "$3" "$BT_JOBS" "${4:-}" >"$log" 2>&1; then
        rm -rf "$tmp"
        echo "  ok: $(basename "$3")"
        return 0
    fi
    bt_build_failed "$log" "$tmp/src"
    return 1
}

# --------------------------------------------------------------- autoconf -----
ac_cur="$(probe_version autoconf --version | awk '{print $NF}')"
ac_man="$(probe_version "$FFBUILD_AUTOCONF_PREFIX/bin/autoconf" --version | awk '{print $NF}')"
if [[ -n "$ac_cur" ]] && version_ge "$ac_cur" "$FFBUILD_BT_MIN_autoconf"; then
    echo "note: autoconf $ac_cur >= $FFBUILD_BT_MIN_autoconf"
elif [[ -n "$ac_man" ]] && version_ge "$ac_man" "$FFBUILD_BT_MIN_autoconf"; then
    echo "note: managed autoconf $ac_man ready at $FFBUILD_AUTOCONF_PREFIX"
else
    echo "== building autoconf $FFBUILD_BT_INSTALL_autoconf into $FFBUILD_AUTOCONF_PREFIX =="
    bt_build_configure "$FFBUILD_BT_URL_autoconf" "$FFBUILD_BT_SHA256_autoconf" "$FFBUILD_AUTOCONF_PREFIX" ||
        note_failure autoconf
fi

# --------------------------------------------------------------- automake -----
# 两条独立需求：裸名 automake 的图内下限是 1.16.3（libxml2），而 libiconv 的
# Makefile.devel 写死 automake-1.18 / aclocal-1.18。系统版本比 1.18 新也不等于够用：
# Arch 的 automake 1.19 只装出 automake-1.19，版本名仍然缺。所以判据是“这个版本名
# 在 PATH 里存不存在”，不是版本号大小。
am_cur="$(probe_version automake --version | awk '{print $NF}')"
am_major="${FFBUILD_BT_INSTALL_automake%.*}"
am_man="$(probe_version "$FFBUILD_AUTOMAKE_PREFIX/bin/automake" --version | awk '{print $NF}')"
if [[ -n "$am_man" ]] && version_ge "$am_man" "$am_major"; then
    echo "note: managed automake $am_man ready at $FFBUILD_AUTOMAKE_PREFIX"
elif command -v "automake-$am_major" >/dev/null 2>&1; then
    echo "note: system automake $am_cur provides automake-$am_major"
else
    echo "== building automake $FFBUILD_BT_INSTALL_automake into $FFBUILD_AUTOMAKE_PREFIX =="
    echo "   (system automake is ${am_cur:-absent} and provides no automake-$am_major)"
    bt_build_configure "$FFBUILD_BT_URL_automake" "$FFBUILD_BT_SHA256_automake" "$FFBUILD_AUTOMAKE_PREFIX" ||
        note_failure automake
fi

# ------------------------------------------------------------------ cmake -----
cm_cur="$(probe_version cmake --version | awk '{print $3}')"
cm_man="$(probe_version "$FFBUILD_CMAKE_PREFIX/bin/cmake" --version | awk '{print $3}')"
if [[ -n "$cm_cur" ]] && version_ge "$cm_cur" "$FFBUILD_BT_MIN_cmake"; then
    echo "note: cmake $cm_cur >= $FFBUILD_BT_MIN_cmake"
elif [[ -n "$cm_man" ]] && version_ge "$cm_man" "$FFBUILD_BT_MIN_cmake"; then
    echo "note: managed cmake $cm_man ready at $FFBUILD_CMAKE_PREFIX"
else
    echo "== building cmake $FFBUILD_BT_INSTALL_cmake into $FFBUILD_CMAKE_PREFIX (takes a while) =="
    bt_build_cmake "$FFBUILD_BT_URL_cmake" "$FFBUILD_BT_SHA256_cmake" "$FFBUILD_CMAKE_PREFIX" ||
        note_failure cmake
fi

# ----------------------------------------------------------------- gettext -----
# zvbi 的 configure.ac 声明 AM_GNU_GETTEXT_VERSION([0.21])，autopoint 在版本
# 不足时会直接拒绝执行（EL8 只有 0.19.8）。
ap_cur="$(probe_version autopoint --version | awk '{print $NF}')"
ap_man="$(probe_version "$FFBUILD_GETTEXT_PREFIX/bin/autopoint" --version | awk '{print $NF}')"
if [[ -n "$ap_cur" ]] && version_ge "$ap_cur" "$FFBUILD_BT_MIN_gettext"; then
    echo "note: autopoint $ap_cur >= $FFBUILD_BT_MIN_gettext"
elif [[ -n "$ap_man" ]] && version_ge "$ap_man" "$FFBUILD_BT_MIN_gettext"; then
    echo "note: managed gettext $ap_man ready at $FFBUILD_GETTEXT_PREFIX"
else
    echo "== building gettext $FFBUILD_BT_INSTALL_gettext into $FFBUILD_GETTEXT_PREFIX =="
    bt_build_configure "$FFBUILD_BT_URL_gettext" "$FFBUILD_BT_SHA256_gettext" "$FFBUILD_GETTEXT_PREFIX" ||
        note_failure gettext
fi

# ------------------------------------------------------------------- nasm -----
# FFmpeg requires nasm >= 2.13 for x86 asm (x264 as well). EL8 ships nasm in CRB
# (powertools), not in base/EPEL, so an host that never enabled that repo simply
# has no assembler: FFmpeg then silently drops to portable C and x264 fails.
nasm_cur="$(probe_version nasm --version | awk '{print $3}')"
nasm_man="$(probe_version "$FFBUILD_NASM_PREFIX/bin/nasm" --version | awk '{print $3}')"
if [[ -n "$nasm_cur" ]] && version_ge "$nasm_cur" "$FFBUILD_BT_MIN_nasm"; then
    echo "note: nasm $nasm_cur >= $FFBUILD_BT_MIN_nasm (already in PATH)"
elif [[ -n "$nasm_man" ]] && version_ge "$nasm_man" "$FFBUILD_BT_MIN_nasm"; then
    echo "note: managed nasm $nasm_man ready at $FFBUILD_NASM_PREFIX"
else
    echo "== building nasm $FFBUILD_BT_INSTALL_nasm into $FFBUILD_NASM_PREFIX =="
    bt_build_configure "$FFBUILD_BT_URL_nasm" "$FFBUILD_BT_SHA256_nasm" "$FFBUILD_NASM_PREFIX" ||
        note_failure nasm
fi

# ------------------------------------------------------------------- yasm -----
# Kept alongside nasm: only linux64 + current FFmpeg were validated, and older
# FFmpeg/win* targets may still prefer yasm.
yasm_cur="$(probe_version yasm --version | awk '{print $2}')"
yasm_man="$(probe_version "$FFBUILD_YASM_PREFIX/bin/yasm" --version | awk '{print $2}')"
if [[ -n "$yasm_cur" ]] && version_ge "$yasm_cur" "$FFBUILD_BT_MIN_yasm"; then
    echo "note: yasm $yasm_cur >= $FFBUILD_BT_MIN_yasm (already in PATH)"
elif [[ -n "$yasm_man" ]] && version_ge "$yasm_man" "$FFBUILD_BT_MIN_yasm"; then
    echo "note: managed yasm $yasm_man ready at $FFBUILD_YASM_PREFIX"
else
    echo "== building yasm $FFBUILD_BT_INSTALL_yasm into $FFBUILD_YASM_PREFIX =="
    bt_build_configure "$FFBUILD_BT_URL_yasm" "$FFBUILD_BT_SHA256_yasm" "$FFBUILD_YASM_PREFIX" "-std=gnu11" ||
        note_failure yasm
fi

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
            if [[ ! -d "$OPAMROOT" ]] &&
               ! "$opam_bin" init --bare --disable-sandboxing -y >"$opam_log" 2>&1; then
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
    if git clone --filter=blob:none --depth=1 https://github.com/yugr/Implib.so "$implib_tmp/Implib.so"; then
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

if [[ "$ONLY_BUILDTOOLS" -eq 1 ]]; then
    echo "note: --buildtools-only set; skipping toolchain descriptors and build root"
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
    # env.sh points these at $FFBUILD_BUILDTOOLS_PREFIX/{cargo,rustup}: the
    # toolchain belongs to the build tree, not to the user's home directory.
    export CARGO_HOME="${CARGO_HOME:-$FFBUILD_BUILDTOOLS_PREFIX/cargo}"
    export RUSTUP_HOME="${RUSTUP_HOME:-$FFBUILD_BUILDTOOLS_PREFIX/rustup}"
    mkdir -p "$CARGO_HOME" "$RUSTUP_HOME"
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
            # 中间产物不放 TMPDIR（可能是 tmpfs）也不放 ~/.cargo：cargo-c 的构建很吃空间，
            # TMPDIR 若是 tmpfs 等于把内存当磁盘用。
            mkdir -p "$FFBUILD_BUILDTOOLS_PREFIX/tmp" "$FFBUILD_BUILDTOOLS_PREFIX/cargo-target"
            TMPDIR="$FFBUILD_BUILDTOOLS_PREFIX/tmp" \
                cargo install --target-dir "$FFBUILD_BUILDTOOLS_PREFIX/cargo-target" cargo-c
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
        # crosstool-ng installs the finished toolchain in CT_PREFIX_DIR, and it
        # rm -rf's that directory first (CT_RM_RF_PREFIX_DIR=y). Point it at the
        # root this driver expects instead of the container's /opt.
        sed -i "s|^CT_PREFIX_DIR=.*|CT_PREFIX_DIR=\"$FFBUILD_CTNG_ROOT\"|" .config
        ./ct-ng build
    )
    echo "ct-ng toolchain installed under $FFBUILD_CTNG_ROOT"
    echo "Enable it with: FFBUILD_TOOLCHAIN_MODE=ctng ./build.sh linux64 gpl"
fi

if ((${#SETUP_FAILURES[@]})); then
    echo
    echo "== setup finished with ${#SETUP_FAILURES[@]} problem(s) =="
    printf '%s\n' "${SETUP_FAILURES[@]}" | sort -u | sed 's/^/  - /'
    echo "  managed build logs : $BT_PREFIX/log/"
    echo "  distro packages    : ./native/setup.sh --check  (per-tool command) / README §2.1"
    ffbuild_env_dump
    echo
    echo "The build will not work until these are resolved."
    exit 1
fi

echo
echo "== setup complete =="
ffbuild_env_dump
echo
echo "Next: ./native/download.sh && ./build.sh linux64 gpl"
