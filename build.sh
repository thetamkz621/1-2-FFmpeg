#!/bin/bash
# shellcheck shell=bash
#
# build.sh — Docker-free linux64 build driver for FFmpeg-Builds.
#
# Replaces upstream makeimage.sh + generate.sh + build.sh (the container run).
#
# Usage:
#   ./build.sh linux64 gpl [addin ...]
#   ./build.sh linux64 lgpl 8.1
#   ./build.sh linux64 gpl-shared debug
#
# Flags / environment:
#   FFBUILD_DEPS_ONLY=1     build dependencies only
#   FFBUILD_FFMPEG_ONLY=1   skip dependencies (reuse existing prefix)
#   FFBUILD_SKIP_DOWNLOAD=1 do not refresh the download cache
#   FFBUILD_CLEAN=1         wipe FFBUILD_ROOT before building
#   FFBUILD_FORCE=1         rebuild all stages (ignore resume state)
#   CC/CXX/LDFLAGS/...      compiler & flag overrides (see native/env.sh)
#
set -eo pipefail
shopt -s globstar
cd "$(dirname "$0")"

if [[ $# -lt 2 ]]; then
    echo "usage: $0 <target> <variant> [addin ...]" >&2
    echo "  e.g. $0 linux64 gpl" >&2
    exit 2
fi

TARGET="$1"
VARIANT="$2"
shift 2

# util/vars.sh defines the stage-function defaults and validates the variant.
# shellcheck source=util/vars.sh
source util/vars.sh "$TARGET" "$VARIANT" "$@"

# Stage scripts are executed in a *separate* process (bash util/run_stage.sh),
# so the target/variant contract must be exported for them to see it.
export TARGET VARIANT ADDINS_STR
export LICENSE_FILE
# Upstream's generate.sh exports this into the container; stage scripts read it
# directly (50-ffnvcodec selects the SDK branch with it).
export FFVER="$(ffbuild_ffver)"

# shellcheck source=native/env.sh
source native/env.sh
# shellcheck source=util/deps.sh
source util/deps.sh
# shellcheck source=util/source-prep.sh
source util/source-prep.sh

# Upstream bind-mounts patches/<name> at /patches for a few stages (aom,
# libaribb24).  Natively the driver repopulates this repo-local dir per stage and
# the scripts read it through $FFBUILD_PATCHES, so no
# root-owned /patches is involved.
export FFBUILD_PATCHES="$FFBUILD_REPO_ROOT/patches-current"

# --- native shim for upstream's Dockerfile emitter --------------------------
# Addins (e.g. addins/lto.sh) emit `ENV ...` lines via to_df(). Natively we
# apply those ENV lines directly to the environment instead of writing a
# Dockerfile. RUN/COPY/FROM lines are ignored.
to_df() {
    local line
    line="$(printf '%s' "$*")"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
        ENV\ *) eval "export ${line#ENV }" ;;
        *) : ;;
    esac
}

# shellcheck source=/dev/null
source "variants/${TARGET}-${VARIANT}.sh"
for addin in ${ADDINS[*]}; do
    # shellcheck source=/dev/null
    source "addins/${addin}.sh"
    type ffbuild_dockeraddin &>/dev/null && ffbuild_dockeraddin || true
done

# Refresh the generated /cross.meson + /toolchain.cmake targets so meson/cmake
# stages see the resolved compilers (including any override).
ffbuild_write_toolchain_files

case "$TARGET" in
linux64)
    ;;
linuxarm64)
    # Only the ctng toolchain can produce aarch64 binaries here; the host
    # compilers are Linux-only and target x86_64.
    if [[ "$FFBUILD_TOOLCHAIN_MODE" != ctng ]]; then
        echo "build.sh: target '$TARGET' requires FFBUILD_TOOLCHAIN_MODE=ctng" >&2
        exit 2
    fi
    ;;
win32|win64)
    # Only the ctng toolchain can produce Windows binaries here; the host
    # compilers are Linux-only.
    if [[ "$FFBUILD_TOOLCHAIN_MODE" != ctng ]]; then
        echo "build.sh: target '$TARGET' requires FFBUILD_TOOLCHAIN_MODE=ctng" >&2
        exit 2
    fi
    ;;
*)
    echo "build.sh: unsupported target '$TARGET' (supported: linux64, linuxarm64, win64, win32)" >&2
    exit 2
    ;;
esac

if [[ -n "${FFBUILD_CLEAN:-}" ]]; then
    echo "== cleaning $FFBUILD_ROOT =="
    rm -rf "$FFBUILD_ROOT"
fi

mkdir -p "$FFBUILD_ROOT"/{prefix,destdir,work,log}
FFBUILD_STAGE_ROOT="$FFBUILD_ROOT/work/stages"
FFBUILD_STATE="$FFBUILD_ROOT/state"
export FFBUILD_STAGE_ROOT
mkdir -p "$FFBUILD_STATE"

# Guard against concurrent builds sharing the same FFBUILD_ROOT: two runs would
# clobber each other's stage work dirs and cause confusing spurious failures.
# mkdir is atomic, so it gives us a reliable lock without extra dependencies.
LOCKDIR="$FFBUILD_ROOT/.build.lock.d"
acquire_lock() {
    if mkdir "$LOCKDIR" 2>/dev/null; then
        echo $$ > "$LOCKDIR/pid"
        return 0
    fi
    local owner=""
    [[ -f "$LOCKDIR/pid" ]] && owner="$(cat "$LOCKDIR/pid" 2>/dev/null)"
    if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
        echo "build.sh: another build is already running (pid $owner) for $FFBUILD_ROOT" >&2
        exit 1
    fi
    echo "build.sh: removing stale lock ${owner:+from pid $owner }($LOCKDIR)" >&2
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" || { echo "build.sh: could not acquire lock $LOCKDIR" >&2; exit 1; }
    echo $$ > "$LOCKDIR/pid"
}
acquire_lock
trap 'rm -rf "$LOCKDIR" 2>/dev/null || true' EXIT

# A build root carries .done markers and static libraries built by one compiler;
# reusing it with the other silently mixes object files. Record the compiler on
# first use and refuse to continue on a mismatch (FFBUILD_CLEAN=1 wipes the root).
# The stamp carries the target as well as the compiler: linux64 and win64 share
# FFBUILD_ROOT by default, and their stage state is not interchangeable.
_build_label="${FFBUILD_TARGET}:${FFBUILD_COMPILER_LABEL:-${FFBUILD_COMPILER:-unknown}}"
if [[ -n "${FFBUILD_COMPILER:-}" ]]; then
    if [[ -f "$FFBUILD_ROOT/.compiler" ]]; then
        _prev_raw="$(cat "$FFBUILD_ROOT/.compiler" 2>/dev/null || true)"
        # Build roots written before targets existed hold a bare compiler label.
        case "$_prev_raw" in
            *:*) _prev_compiler="$_prev_raw" ;;
            ?*)  _prev_compiler="linux64:$_prev_raw" ;;
            *)   _prev_compiler="" ;;
        esac
        if [[ -n "$_prev_compiler" && "$_prev_compiler" != "$_build_label" ]]; then
            echo "build.sh: $FFBUILD_ROOT was built with $_prev_compiler, now using $_build_label" >&2
            echo "          use FFBUILD_ROOT=... for a separate tree, or FFBUILD_CLEAN=1 to start over" >&2
            exit 2
        fi
    else
        printf '%s\n' "$_build_label" > "$FFBUILD_ROOT/.compiler"
    fi
    unset _prev_compiler _prev_raw
fi

FFMPEG_REPO="${FFMPEG_REPO:-https://github.com/FFmpeg/FFmpeg.git}"
GIT_BRANCH="${GIT_BRANCH:-master}"
GIT_BRANCH="${GIT_BRANCH_OVERRIDE:-$GIT_BRANCH}"

RPATH_LDEXEFLAGS=''
if [[ $TARGET == linux* && $VARIANT == *shared* ]]; then
    # Upstream's literal; the escaping must survive configure and make so the
    # linker records $ORIGIN/../lib.
    RPATH_LDEXEFLAGS=' -Wl,-rpath,\\\$\$ORIGIN/../lib'
fi

# =============================================================== downloads ====
if [[ -z "${FFBUILD_SKIP_DOWNLOAD:-}" && -z "${FFBUILD_FFMPEG_ONLY:-}" ]]; then
    echo "== refreshing download cache =="
    ./native/download.sh --needed "$TARGET" "$VARIANT" ${ADDINS[@]+"${ADDINS[@]}"}
fi

# ============================================================ dependencies ====
# Escape hatch: comma/space separated stage names to skip (e.g. rust-dependent
# stages when rust is unavailable). Skipped stages are also excluded from the
# aggregated FFmpeg flags.
FFBUILD_SKIP_STAGES="${FFBUILD_SKIP_STAGES:-}"
ffbuild_stage_skipped() {
    local s
    for s in ${FFBUILD_SKIP_STAGES//,/ }; do
        [[ "$s" == "$1" ]] && return 0
    done
    return 1
}

# Evaluate one script's ffbuild_enabled. Directory stages (50-vaapi, 45-fonts,
# 50-dvd, ...) aggregate several scripts, and the stage-level check only sees
# the last one, so each script has to be asked separately. Upstream's Dockerfile
# emitter does the same when it decides whether to emit a RUN step.
script_enabled() {
    local SCRIPT="$1"
    (
        SELF="$SCRIPT"
        # shellcheck disable=SC1090
        source "$SCRIPT" 2>/dev/null || exit 1
        declare -F ffbuild_enabled >/dev/null || exit 0
        ffbuild_enabled
    )
}

run_one_script() {
    local SCRIPT="$1"
    local STAGENAME
    STAGENAME="$(basename "$SCRIPT" .sh)"

    # Resumability: a full linux64/gpl dependency build takes a long time, and
    # re-running after a late failure must not redo everything. Stages that
    # already completed are skipped unless FFBUILD_FORCE is set.
    if [[ -z "${FFBUILD_FORCE:-}" && -f "$FFBUILD_STATE/${STAGENAME}.done" ]]; then
        echo "   (already built: $STAGENAME)"
        return 0
    fi

    if ! script_enabled "$SCRIPT"; then
        echo "-- skip (not applicable to $TARGET/$VARIANT): $SCRIPT"
        return 0
    fi

    local CACHE="$FFBUILD_REPO_ROOT/.cache/downloads/${STAGENAME}.tar.xz"
    [[ -f "$CACHE" ]] || CACHE=""

    # Probe the stage's own `--mount=src=...,dst=/patches` declaration and
    # repopulate the dir $FFBUILD_PATCHES points at.
    local PATCHSRC
    PATCHSRC="$(stage_patch_src "$SCRIPT")"
    rm -rf "$FFBUILD_REPO_ROOT/patches-current"
    mkdir -p "$FFBUILD_REPO_ROOT/patches-current"
    if [[ -n "$PATCHSRC" && -d "$PATCHSRC" ]]; then
        cp -a "$PATCHSRC"/. "$FFBUILD_REPO_ROOT/patches-current"/
        echo "   patches: $PATCHSRC"
    fi

    rm -rf "$FFBUILD_DESTDIR"
    mkdir -p "$FFBUILD_DESTDIR" "$FFBUILD_PREFIX"

    if ! SELF="$SCRIPT" STAGENAME="$STAGENAME" STAGE_CACHE="$CACHE" \
            bash util/run_stage.sh "$SCRIPT"; then
        echo "ERROR: stage $STAGENAME failed; not marking it done" >&2
        return 1
    fi

    touch "$FFBUILD_STATE/${STAGENAME}.done"
}

# Derive the src dir of a stage's `--mount=src=<x>,dst=/patches` declaration.
stage_patch_src() {
    local SCRIPT="$1" out
    out="$(
        to_df() { printf '%s\n' "$*"; }   # capture raw lines instead of applying
        SELF="$SCRIPT"
        STAGENAME="$(basename "$SCRIPT" .sh)"
        # shellcheck disable=SC1090
        source util/dl_functions.sh 2>/dev/null || true
        # shellcheck disable=SC1090
        source "$SCRIPT" 2>/dev/null || true
        if type ffbuild_dockerstage >/dev/null 2>&1; then
            ffbuild_dockerstage 2>/dev/null || true
        fi
    )" 2>/dev/null || true
    sed -n 's/.*--mount=src=\([^,]*\),dst=\/patches.*/\1/p' <<<"$out" | head -n1
}

build_deps() {
    local ENTRY ORDER STAGE SCRIPT
    ENTRY="$(ffbuild_entry_script)"

    echo "== resolving dependency graph =="
    ORDER="$(get_build_order "$ENTRY")"
    echo "   $(wc -l <<<"$ORDER") stages in dependency order"

    for STAGE in $ORDER; do
        # The graph entry is the aggregator zz-final.sh: it contributes
        # dependencies but builds nothing, and it is reached here as a *path*
        # (ffbuild_entry_script prints one), so stage resolution would fail and
        # report it as skipped. Leave it out instead of printing noise.
        [[ "$STAGE" == "$ENTRY" ]] && continue
        if ffbuild_stage_skipped "$STAGE"; then
            echo "-- skip (FFBUILD_SKIP_STAGES): $STAGE"
            continue
        fi
        # A stage can be off for reasons other than the target: the license
        # variant (x264 under lgpl, fdk-aac outside nonfree), the FFmpeg version
        # it needs, or an addin. Naming the target alone would blame the wrong
        # thing, so state what it is not applicable *to* and leave the reason to
        # the stage itself.
        if ! ffbuild_stage_enabled "$STAGE"; then
            echo "-- skip (not applicable to $TARGET/$VARIANT): $STAGE"
            continue
        fi
        while IFS= read -r SCRIPT; do
            [[ -n "$SCRIPT" ]] || continue
            echo "-- build: $SCRIPT"
            run_one_script "$SCRIPT" 2>&1 | tee "$FFBUILD_LOG/$(basename "$SCRIPT" .sh).log"
        done < <(ffbuild_stage_scripts "$STAGE")
    done
}

echo "== toolchain: ${FFBUILD_COMPILER_LABEL:-${FFBUILD_COMPILER:-unknown}} (CC=${CC:-?} CXX=${CXX:-?}, mode=${FFBUILD_TOOLCHAIN_MODE:-?}) =="

if [[ -z "${FFBUILD_FFMPEG_ONLY:-}" ]]; then
    build_deps
    echo "== dependencies done =="
    if [[ -n "${FFBUILD_DEPS_ONLY:-}" ]]; then
        echo "FFBUILD_DEPS_ONLY set; stopping before FFmpeg. Prefix: $FFBUILD_PREFIX"
        exit 0
    fi
fi

# ======================================================== aggregate flags ====
echo "== aggregating stage flags =="
ENTRY="$(ffbuild_entry_script)"
for SUBDEP in $(get_stagedeps_recursive "$ENTRY"); do
    ffbuild_stage_skipped "$SUBDEP" && continue
    STAGE="$(resolvestage "$SUBDEP")"
    if [[ -d "$STAGE" ]]; then
        SCRIPTS=("$STAGE"/??-*.sh)
    else
        SCRIPTS=("$STAGE")
    fi
    for SCRIPT in "${SCRIPTS[@]}"; do
        [[ -f "$SCRIPT" ]] || continue
        FF_CONFIGURE+=" $(get_output "$SCRIPT" configure)"
        FF_CFLAGS+=" $(get_output "$SCRIPT" cflags)"
        FF_CXXFLAGS+=" $(get_output "$SCRIPT" cxxflags)"
        FF_LDFLAGS+=" $(get_output "$SCRIPT" ldflags)"
        FF_LDEXEFLAGS+=" $(get_output "$SCRIPT" ldexeflags)"
        FF_LIBS+=" $(get_output "$SCRIPT" libs)"
    done
done

FF_CONFIGURE="$(xargs <<< "${FF_CONFIGURE:-}")"
FF_CFLAGS="$(xargs <<< "${FF_CFLAGS:-}")"
FF_CXXFLAGS="$(xargs <<< "${FF_CXXFLAGS:-}")"
FF_LDFLAGS="$(xargs <<< "${FF_LDFLAGS:-}")"
FF_LDEXEFLAGS="$(xargs <<< "${FF_LDEXEFLAGS:-}")"
FF_LIBS="$(xargs <<< "${FF_LIBS:-}")"

# Runtime libraries that must come *after* the libraries, e.g. libm (chromaprint)
# and libstdc++ (davs2). See FFBUILD_EXTRA_LIBS in native/env.sh for why this
# position is load-bearing: --extra-libs is placed after the library list
# (configure: `... $libs $extralibs`), whereas the same flag in LDFLAGS lands
# before it and is dropped by Debian's default -Wl,--as-needed.
FF_LIBS="$(xargs <<< "${FF_LIBS:-} ${FFBUILD_EXTRA_LIBS:-}")"

# ============================================================ build ffmpeg ==
FFMPEG_DIR="$FFBUILD_ROOT/ffmpeg"
# FFmpeg installs into its *own* tree, next to (not inside) the dependency
# prefix. Upstream gets this split for free from the container layout: stages
# install to /opt/ffbuild, that tree is merged into the container's /, and
# FFmpeg is configured with --prefix=/ffbuild/prefix, which is what
# package_variant reads. With a single shared prefix, packaging copied every
# dependency's headers, .pc file and stray .so (libglvnd installs
# libGLdispatch.so*) into the artifact -- visible only for *-shared, since the
# static variant packages bin/doc/man/presets only.
FFMPEG_PREFIX="$FFBUILD_ROOT/ffmpeg-prefix"
rm -rf "$FFMPEG_PREFIX"
rm -rf "$FFMPEG_DIR"
ffmpeg_source_prepare
cd "$FFMPEG_DIR"

echo "== configuring ffmpeg =="
./configure --prefix="$FFMPEG_PREFIX" --pkg-config-flags="--static" \
    $FFBUILD_TARGET_FLAGS $FF_CONFIGURE \
    --extra-cflags="$FF_CFLAGS" --extra-cxxflags="$FF_CXXFLAGS" --extra-libs="$FF_LIBS" \
    --extra-ldflags="$FF_LDFLAGS" --extra-ldexeflags="$FF_LDEXEFLAGS$RPATH_LDEXEFLAGS" \
    --cc="$CC" --cxx="$CXX" --ar="$AR" --ranlib="$RANLIB" --nm="$NM" \
    --extra-version="$FFBUILD_EXTRA_VERSION" || { cat ffbuild/config.log; exit 1; }

echo "== building ffmpeg =="
make -j"$FFBUILD_JOBS" V=1
make install
# Docs are best-effort: texi2html may be unavailable on some distros.
make install-doc || echo "WARNING: 'make install-doc' failed; documentation may be incomplete" >&2
cd "$FFBUILD_REPO_ROOT"

# =============================================================== packaging ===
ARTIFACTS_PATH="$FFBUILD_REPO_ROOT/artifacts"
mkdir -p "$ARTIFACTS_PATH"

BUILD_NAME="ffmpeg-$("$FFMPEG_DIR/ffbuild/version.sh" "$FFMPEG_DIR")-${TARGET}-${VARIANT}${ADDINS_STR:+-}${ADDINS_STR}-${FFBUILD_COMPILER_LABEL:-${FFBUILD_COMPILER:-unknown}}-${FFBUILD_BUILD_DATE:-unknown}"
PKGROOT="$FFBUILD_ROOT/pkgroot/$BUILD_NAME"
rm -rf "$FFBUILD_ROOT/pkgroot"
mkdir -p "$PKGROOT"

package_variant "$FFMPEG_PREFIX" "$PKGROOT"

# The variant's sed rewrites the *container* literal /ffbuild/prefix; a native
# build tree lives at an arbitrary host path, so libdir/includedir would keep it
# and the .pc files would not be relocatable. Rewrite whatever prefix we
# actually packaged from, leaving only ${prefix} behind.
if [[ -d "$PKGROOT/lib/pkgconfig" ]]; then
    # /^prefix=/! : package_variant already turned that line into
    # ${pcfiledir}/../..; rewriting it again would make it self-referential.
    find "$PKGROOT/lib/pkgconfig" -name '*.pc' -print0 |
        xargs -0 -r sed -i "/^prefix=/!s|$FFMPEG_PREFIX|\${prefix}|g"
fi
[[ -n "${LICENSE_FILE:-}" && -f "$FFMPEG_DIR/$LICENSE_FILE" ]] && \
    cp "$FFMPEG_DIR/$LICENSE_FILE" "$PKGROOT/LICENSE.txt"

cd "$FFBUILD_ROOT/pkgroot"
# Upstream ships Windows builds as zip and every other target as tar.xz;
# keep the extension users and release tooling expect.
if [[ "$TARGET" == win* ]]; then
    OUTPUT_FNAME="${BUILD_NAME}.zip"
    zip -9 -r -q "$ARTIFACTS_PATH/${OUTPUT_FNAME}" "$BUILD_NAME"
else
    OUTPUT_FNAME="${BUILD_NAME}.tar.xz"
    tar -I "xz -T0" -cf "$ARTIFACTS_PATH/${OUTPUT_FNAME}" "$BUILD_NAME"
fi
cd "$FFBUILD_REPO_ROOT"

echo
echo "== done =="
echo "artifact: $ARTIFACTS_PATH/${OUTPUT_FNAME}"
