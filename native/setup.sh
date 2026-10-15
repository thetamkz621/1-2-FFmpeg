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
PRINT_APT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
    --check)      DO_CHECK=1 ;;
    --all)        DO_ALL=1; WITH_RUST=1; WITH_NODE=1 ;;
    --with-rust)  WITH_RUST=1 ;;
    --with-node)  WITH_NODE=1 ;;
    --with-ctng)  WITH_CTNG=1 ;;
    --print-apt)  PRINT_APT=1 ;;
    -h|--help)    sed -n '3,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
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

# --------------------------------------------------------------- packages -----
# Package names target Debian 13 (trixie); unavailable entries are filtered out.
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
REQUIRED_TOOLS=(gcc g++ make cmake meson ninja pkg-config git patch tar xz zip nasm yasm autoconf automake libtoolize python3 gen-implib git-mini-clone retry-tool)
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
# apt may be unusable for reasons unrelated to this project (e.g. a malformed
# sources file). That must not be fatal: the tools may already be installed.
APT_OK=1
if ! asroot apt-get update; then
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

# --------------------------------------------------------------- autoconf -----
# A few projects (lame, libjxl, ...) require autoconf >= 2.73, which is newer
# than Debian 13 ships (2.72). Upstream's image installs Ubuntu's autoconf 2.73
# .deb for exactly this reason; autoconf is architecture independent.
ac_cur="$(autoconf --version 2>/dev/null | head -n1 | awk '{print $NF}')"
if [[ -z "$ac_cur" ]] || [[ "$(printf '%s\n2.73\n' "$ac_cur" | sort -V | head -n1)" != "2.73" ]]; then
    echo "== installing autoconf >= 2.73 (found: ${ac_cur:-none}) =="
    ac_tmp="$(mktemp -d)"
    if wget -q -O "$ac_tmp/autoconf.deb" \
        "https://archive.ubuntu.com/ubuntu/pool/main/a/autoconf/autoconf_2.73-2_all.deb"; then
        if ! asroot dpkg -i "$ac_tmp/autoconf.deb" 2>/dev/null; then
            asroot dpkg -i --force-depends "$ac_tmp/autoconf.deb" \
                || echo "  WARNING: autoconf 2.73 install failed" >&2
        fi
        echo "  autoconf now: $(autoconf --version 2>/dev/null | head -n1)"
    else
        echo "  WARNING: could not download the autoconf 2.73 .deb" >&2
    fi
    rm -rf "$ac_tmp"
else
    echo "note: autoconf $ac_cur already >= 2.73"
fi

# --------------------------------------------------------------- automake -----
# gnulib-based projects (libiconv) invoke the *versioned* names aclocal-1.18 /
# automake-1.18, which Debian 13 does not ship (it has 1.17). Install automake
# 1.18 into a side prefix and append it to PATH: the versioned names then
# resolve, while plain `automake` still resolves to the distro's 1.17 so other
# stages keep their known-good behaviour.
AM_PREFIX="${FFBUILD_AUTOMAKE_PREFIX:-/opt/automake-1.18}"
am_cur="$(automake --version 2>/dev/null | head -n1 | awk '{print $NF}')"
if [[ -z "$am_cur" ]] || [[ "$(printf '%s\n1.18\n' "$am_cur" | sort -V | head -n1)" != "1.18" ]]; then
    if command -v automake-1.18 >/dev/null 2>&1; then
        echo "note: automake-1.18 already available"
    else
        echo "== installing automake 1.18 into $AM_PREFIX =="
        am_tmp="$(mktemp -d)"
        am_url="https://ftp.gnu.org/gnu/automake/automake-1.18.1.tar.xz"
        if wget -q -O "$am_tmp/automake.tar.xz" "$am_url"; then
            tar -xJf "$am_tmp/automake.tar.xz" -C "$am_tmp"
            if (
                cd "$am_tmp/automake-1.18.1"
                ./configure --prefix="$AM_PREFIX" >/dev/null 2>&1
                make -j"$FFBUILD_JOBS" >/dev/null 2>&1
                asroot make install >/dev/null 2>&1
            ); then
                echo "  installed: $(ls "$AM_PREFIX/bin" 2>/dev/null | tr '\n' ' ')"
            else
                echo "  WARNING: automake 1.18 build/install failed" >&2
            fi
        else
            echo "  WARNING: could not download automake 1.18" >&2
        fi
        rm -rf "$am_tmp"
    fi
else
    echo "note: system automake $am_cur already >= 1.18"
fi

# ------------------------------------------------------------------ meson -----
# Distro meson can be older than projects require (fontconfig needs >= 1.11;
# Debian 13 ships 1.7.0). Upstream's image installs meson via pip for the same
# reason — do the same when the available one is too old.
MESON_MIN="${FFBUILD_MESON_MIN:-1.11.0}"
meson_cur="$(meson --version 2>/dev/null | head -n1)"
if [[ -z "$meson_cur" ]] || [[ "$(printf '%s\n%s\n' "$meson_cur" "$MESON_MIN" | sort -V | head -n1)" != "$MESON_MIN" ]]; then
    echo "== installing meson >= $MESON_MIN (found: ${meson_cur:-none}) =="
    if asroot python3 -m pip install --break-system-packages --upgrade meson; then
        hash -r 2>/dev/null || true
        echo "  meson now: $(meson --version 2>/dev/null)"
    else
        echo "  WARNING: could not install a newer meson via pip" >&2
    fi
else
    echo "note: meson $meson_cur already >= $MESON_MIN"
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
