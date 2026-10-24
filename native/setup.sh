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
#   ./native/setup.sh --all           # also install the optional upstream packages
#   ./native/setup.sh --with-ctng     # additionally build the crosstool-ng toolchain
#   ./native/setup.sh --no-apt        # skip package installation (host manages its own)
#   ./native/setup.sh --buildtools-only  # only build the managed build tools, touch nothing else
#   ./native/setup.sh --with-tools=a,b   # build these build tools even if only some are missing
#   ./native/setup.sh --no-managed-tools # do not build tools; use whatever the host provides
#   ./native/setup.sh --check         # only verify what is present
#   ./native/setup.sh --print-apt     # print the core apt package list and exit
#   ./native/setup.sh --print-apt=all # ... including the --all extras
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=native/env.sh
source "$HERE/env.sh"

DO_CHECK=0
DO_ALL=0
WITH_CTNG=0
NO_APT=0
PRINT_APT=0
PRINT_APT_ALL=0
ONLY_BUILDTOOLS=0
NO_MANAGED_TOOLS=0
WITH_TOOLS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
    --check)      DO_CHECK=1 ;;
    --all)        DO_ALL=1 ;;
    --with-ctng)  WITH_CTNG=1 ;;
    --no-apt)     NO_APT=1 ;;
    --print-apt)  PRINT_APT=1 ;;
    --print-apt=all) PRINT_APT=1; PRINT_APT_ALL=1 ;;
    --buildtools-only) ONLY_BUILDTOOLS=1 ;;
    --no-managed-tools) NO_MANAGED_TOOLS=1 ;;
    --with-tools=*)      WITH_TOOLS="${1#*=}" ;;
    --with-tools)        WITH_TOOLS="${2:-}"; shift ;;
    -h|--help)    sed -n '3,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "setup.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
    shift
done

if [[ -n "${FFBUILD_IGNORED_CARGO_HOME:-}${FFBUILD_IGNORED_RUSTUP_HOME:-}" ]]; then
    echo "note: ignoring CARGO_HOME/RUSTUP_HOME from the environment; build caches stay under $FFBUILD_BUILDTOOLS_PREFIX"
fi

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
        pkg-config) echo "./native/setup.sh（托管）或 $(install_hint pkg-config pkgconf-pkg-config pkgconf)" ;;
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
        clang)      install_hint clang clang clang ;;
        libatomic)  install_hint "libatomic1 gcc" libatomic gcc ;;
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
#
# Build-time Python (meson / jinja2 / jsonschema) is deliberately absent: it lives
# in the repo-local venv, which is prepended to PATH for every build (see the
# "python" section below). Only the interpreter and the venv tooling come from the
# distro, so a host never ends up with two half-populated Python environments.
#
# APT_CORE is what the default target graph actually needs; APT_EXTRA is everything
# else upstream's image carries, installed only with --all. Nothing is dropped just
# because today's linux64 gpl build happens not to use it — the other targets and
# variants have not been exercised yet, and upstream installing it is evidence
# enough to keep it one flag away.
APT_CORE=(
    # 自举根：没有这些就什么都编不了
    build-essential gcc g++ binutils make patch
    libc6-dev zlib1g-dev libssl-dev
    # 网络与归档（wget 是 setup 自己的下载兜底）
    git curl wget ca-certificates
    tar xz-utils
    # Python 运行时：构建期模块由 venv 提供，发行版只管解释器与建 venv
    python3 python3-dev python3-pip python3-venv python3-setuptools
    python-is-python3
    # --enable-cuda-llvm：configure 把 nvcc 默认成 clang
    clang llvm
    # 默认图要 OCaml（fftw3 的 genfft）与 Java + ant（libbluray 的 BD-J jar）
    ocaml ocaml-findlib ocamlbuild libnum-ocaml-dev
    default-jdk-headless ant
    # lame / xvid 两个 stage 走 svn checkout
    subversion
)
APT_EXTRA=(
    # 上游镜像有、当前默认图用不到；--all 时装上
    p7zip-full libarchive-tools xxd libxml2-utils mercurial
    lld
    gtk-doc-tools gobject-introspection itstool
)

apt_available() { apt-cache show "$1" >/dev/null 2>&1; }

filter_available() {
    local p out=()
    for p in "$@"; do apt_available "$p" && out+=("$p"); done
    printf '%s\n' "${out[@]}"
}

if [[ "$PRINT_APT" -eq 1 ]]; then
    printf '%s\n' "${APT_CORE[@]}" | sort -u
    if [[ "$PRINT_APT_ALL" -eq 1 ]]; then
        printf '%s\n' "${APT_EXTRA[@]}" | sort -u
    fi
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
OPTIONAL_TOOLS=(clang node 7z xxd)

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
    local py_bin py_ver
    py_bin=""
    py_ver=""
    for _c in python3.13 python3.12 python3.11 python3.10 python3; do
        command -v "$_c" >/dev/null 2>&1 || continue
        _v="$("$_c" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
        [[ -n "$_v" ]] || continue
        if version_ge "$_v" "$FFBUILD_BT_SYSTEM_python"; then py_bin="$_c"; py_ver="$_v"; break; fi
    done
    unset _v _c
    if [[ -n "$py_bin" ]]; then
        printf '  %-9s system=%-8s min=%-7s ok (%s)\n' python "$py_ver" "$FFBUILD_BT_SYSTEM_python" "$py_bin"
    else
        printf '  %-9s system=%-8s min=%-7s NEEDS INSTALL\n' python "${py_ver:-none}" "$FFBUILD_BT_SYSTEM_python"
    fi
    printf '  managed root: %s\n' "$FFBUILD_BUILDTOOLS_PREFIX"
    echo

    echo "== runtime prerequisites (not managed; install from your distro) =="
    rt_ok()      { printf '  [ok]      %s\n' "$1"; }
    # 第三个参数为 optional 时只提示、不影响退出码。
    rt_blocking=0
    rt_missing() {
        printf '  [MISSING] %s\n              %s\n' "$1" "$2"
        [[ "${3:-}" == optional ]] || rt_blocking=1
    }

    # 编译器由 FFBUILD_TOOLCHAIN_MODE 选择（host 自动探测）；这里只报告解析结果。
    if command -v "$CC" >/dev/null 2>&1 && command -v "$CXX" >/dev/null 2>&1; then
        rt_ok "compiler $FFBUILD_COMPILER ($CC / $CXX)"
    else
        rt_missing "compiler $FFBUILD_TOOLCHAIN_MODE" "$(tool_hint "${FFBUILD_COMPILER:-clang}")"
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
    [[ "$DO_ALL" -eq 1 ]] && PKGS+=("${APT_EXTRA[@]}")

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
    "$FFBUILD_REPO_ROOT/native/buildtools.sh" "${_bt_args[@]}" ||
        note_failure "build tools (native/buildtools.sh)"
    unset _bt_args
fi

# opam 是预编译二进制（不是源码包），所以留在 setup 里下载。
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
        "$FFBUILD_PYTHON_PREFIX/bin/pip" install --quiet --no-cache-dir --upgrade pip "${PY_MODULES[@]}"; then
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
            echo "           install openssl3-devel (dnf) first; cargo-c needs OpenSSL 3" >&2
        fi
    fi
    # cargo-c is the only piece that has no distro package; everything else
    # (cargo, rustc) is reused from the host when it works.
    cargo_c_install() {
        (
            unset PKG_CONFIG_LIBDIR PKG_CONFIG_PATH
            # 中间产物不放 TMPDIR（可能是 tmpfs）也不放 ~/.cargo：cargo-c 的构建很吃空间。
            mkdir -p "$FFBUILD_BUILDTOOLS_PREFIX/tmp" "$FFBUILD_BUILDTOOLS_PREFIX/cargo-target"
            TMPDIR="$FFBUILD_BUILDTOOLS_PREFIX/tmp" \
                cargo install --target-dir "$FFBUILD_BUILDTOOLS_PREFIX/cargo-target" cargo-c
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
            if ! curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal; then
                echo "  WARNING: rustup install failed" >&2
                note_failure "rust (rustup install)"
            fi
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

prepare_rust

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
