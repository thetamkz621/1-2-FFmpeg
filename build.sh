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

# shellcheck source=native/env.sh
source native/env.sh
# shellcheck source=util/deps.sh
source util/deps.sh

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

if [[ "$TARGET" != linux64 ]]; then
    echo "build.sh: this project supports the linux64 target only (got '$TARGET')." >&2
    exit 2
fi

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

FFMPEG_REPO="${FFMPEG_REPO:-https://github.com/FFmpeg/FFmpeg.git}"
FFMPEG_REPO="${FFMPEG_REPO_OVERRIDE:-$FFMPEG_REPO}"
GIT_BRANCH="${GIT_BRANCH:-master}"
GIT_BRANCH="${GIT_BRANCH_OVERRIDE:-$GIT_BRANCH}"

RPATH_LDEXEFLAGS=''
if [[ $TARGET == linux* && $VARIANT == *shared* ]]; then
    # Escaping is load-bearing; this is upstream's exact literal for a reason.
    # The value travels through three expansions before the linker sees it:
    #
    #   1. ./configure itself expands the option value once (shell semantics):
    #          \\  ->  \        \$  ->  $        \$  ->  $
    #      so  \ \ \ $ \ $ O R I G I N   becomes   \ $ $ O R I G I N
    #      and is written to ffbuild/config.mak as  -Wl,-rpath,\$$ORIGIN/../lib
    #   2. make rewrites `$$` -> `$`, leaving the backslash:  \$ORIGIN
    #   3. the shell running the link turns `\$` into a literal `$`
    #
    # Net result: the linker records `$ORIGIN/../lib`. Drop a backslash and step
    # 1 yields a bare `$ORIGIN`, which step 3 expands as an unset shell variable —
    # the binary then silently records `RUNPATH: [/../lib]` or `[../lib]`, and
    # only works if the process happens to be started from bin/.
    # `--disable-new-dtags` keeps DT_RPATH instead of DT_RUNPATH.
    # The shared libav* libraries carry no rpath of their own (verified: same as
    # upstream), so e.g. libavcodec's NEEDED libswresample/libavutil can only be
    # resolved through the *executable's* rpath — and only DT_RPATH is consulted
    # for transitive lookups; DT_RUNPATH is not. Upstream records DT_RPATH
    # (crosstool-ng's ld defaults to old dtags), while Debian's ld defaults to
    # new dtags, so we ask for old dtags explicitly to match.
    RPATH_LDEXEFLAGS=' -Wl,--disable-new-dtags -Wl,-rpath,\\\$\$ORIGIN/../lib'
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

    local CACHE="$FFBUILD_REPO_ROOT/.cache/downloads/${STAGENAME}.tar.xz"
    [[ -f "$CACHE" ]] || CACHE=""

    # Upstream bind-mounts patches/<name> at /patches for a few stages
    # (see their ffbuild_dockerstage). Probe that declaration and repopulate the
    # repo-local dir that /patches symlinks to (native/setup.sh creates it).
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

    SELF="$SCRIPT" STAGENAME="$STAGENAME" STAGE_CACHE="$CACHE" \
        bash util/run_stage.sh "$SCRIPT"

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
        if ffbuild_stage_skipped "$STAGE"; then
            echo "-- skip (FFBUILD_SKIP_STAGES): $STAGE"
            continue
        fi
        if ! ffbuild_stage_enabled "$STAGE"; then
            echo "-- skip (disabled for $TARGET): $STAGE"
            continue
        fi
        while IFS= read -r SCRIPT; do
            [[ -n "$SCRIPT" ]] || continue
            echo "-- build: $SCRIPT"
            run_one_script "$SCRIPT" 2>&1 | tee "$FFBUILD_LOG/$(basename "$SCRIPT" .sh).log"
        done < <(ffbuild_stage_scripts "$STAGE")
    done
}

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
git clone --filter=blob:none --branch="$GIT_BRANCH" "$FFMPEG_REPO" "$FFMPEG_DIR"
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

BUILD_NAME="ffmpeg-$("$FFMPEG_DIR/ffbuild/version.sh" "$FFMPEG_DIR")-${TARGET}-${VARIANT}${ADDINS_STR:+-}${ADDINS_STR}"
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
OUTPUT_FNAME="${BUILD_NAME}.tar.xz"
tar -I "xz -T0" -cf "$ARTIFACTS_PATH/${OUTPUT_FNAME}" "$BUILD_NAME"
cd "$FFBUILD_REPO_ROOT"

echo
echo "== done =="
echo "artifact: $ARTIFACTS_PATH/${OUTPUT_FNAME}"
