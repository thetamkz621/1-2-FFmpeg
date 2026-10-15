#!/bin/bash
# shellcheck shell=bash
#
# util/run_stage.sh — Run one dependency stage, natively.
#
# Adapted from upstream util/run_stage.sh (which ran inside a container).
# Differences:
#   * container paths (/<stage>, /cache.tar.xz) are parameterised;
#   * the "merge into prefix" step copies $FFBUILD_DESTPREFIX into
#     $FFBUILD_PREFIX instead of into the container root "/".
#
# Invocation (all provided by the driver):
#   FFBUILD_STAGE_ROOT  scratch dir for stage sources
#   STAGENAME           stage name (also the dir name under FFBUILD_STAGE_ROOT)
#   STAGE_CACHE         optional path to <stage>_<hash>.tar.xz
#   $1                  stage script path
#   $2                  optional function to call instead of ffbuild_dockerbuild
#
set -e

# The stage script path must be absolute: we cd into the stage work dir below.
STAGE_SCRIPT="$1"
if [[ "$STAGE_SCRIPT" != /* ]]; then
    STAGE_SCRIPT="$(cd "$(dirname "$STAGE_SCRIPT")" && printf '%s/%s' "$PWD" "$(basename "$STAGE_SCRIPT")")"
fi

export RAW_CFLAGS="$CFLAGS"
export RAW_CXXFLAGS="$CXXFLAGS"
export RAW_LDFLAGS="$LDFLAGS"
[[ -n "${STAGE_CFLAGS:-}"   ]] && export CFLAGS="$CFLAGS $STAGE_CFLAGS"
[[ -n "${STAGE_CXXFLAGS:-}" ]] && export CXXFLAGS="$CXXFLAGS $STAGE_CXXFLAGS"
[[ -n "${STAGE_LDFLAGS:-}"  ]] && export LDFLAGS="$LDFLAGS $STAGE_LDFLAGS"

if [[ -n "${STAGENAME:-}" && -n "${FFBUILD_STAGE_ROOT:-}" ]]; then
    STAGE_DIR="$FFBUILD_STAGE_ROOT/$STAGENAME"
    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR"
    if [[ -n "${STAGE_CACHE:-}" && -f "$STAGE_CACHE" ]]; then
        tar xaf "$STAGE_CACHE" -C "$STAGE_DIR"
    fi
    cd "$STAGE_DIR"
fi

git config --global --add safe.directory "$PWD" 2>/dev/null || true

# shellcheck disable=SC1090
source "$STAGE_SCRIPT"
if [[ -z "${2:-}" ]]; then
    ffbuild_dockerbuild
else
    "$2"
fi

if [[ -d "${FFBUILD_DESTDIR:-}" ]]; then
    # Remove legacy libtool .la files
    find "$FFBUILD_DESTDIR" -name "*.la" -delete

    # Strip all plain .a archives, but only if they actually shrink
    STRIP_BIN="${STRIP:-${FFBUILD_CROSS_PREFIX:-}strip}"
    RANLIB_BIN="${RANLIB:-${FFBUILD_CROSS_PREFIX:-}ranlib}"

    # llvm-strip --strip-unneeded removes COMDAT section symbols from COFF
    # objects, which makes lld silently skip relocations against them.
    STRIP_VERSION="$("$STRIP_BIN" --version 2>&1 || true)"

    STRIP_ARGS=()
    [[ "${STRIP_VERSION,,}" != *llvm* ]] && STRIP_ARGS+=( --strip-unneeded )
    [[ "${ADDINS_STR:-}" != *debug* ]] && STRIP_ARGS+=( --strip-debug )

    if (( ${#STRIP_ARGS[@]} )); then
        find "$FFBUILD_DESTDIR" -type f -name '*.a' ! -name '*.dll.a' -print0 | while IFS= read -r -d '' lib; do
            tmp="${lib}.strip"
            cp -p "$lib" "$tmp" || continue
            if "$STRIP_BIN" "${STRIP_ARGS[@]}" "$tmp" \
                && "$RANLIB_BIN" "$tmp" \
                && (( $(stat -c %s "$tmp") < $(stat -c %s "$lib") )); then
                mv -f "$tmp" "$lib"
            else
                rm -f "$tmp"
            fi
        done
    fi

    # Prune things that must not reach the packaged artifact, BEFORE merging.
    #
    # Upstream does the equivalent of this at the end of its in-container
    # run_stage (`rm -rf "$FFBUILD_DESTPREFIX"/bin`), and its Dockerfile copies
    # $FFBUILD_DESTPREFIX into $FFBUILD_PREFIX only in a *later* layer — so bin/
    # never reaches the prefix. We merge inside this very script, so the prune
    # has to happen first; otherwise every dependency's CLI tools leak into the
    # final tarball's bin/ (observed: xz, xzcat, ...).
    #
    # share/man is pruned for the same reason: third-party man pages (X11/XCB
    # man3, ...) are of no use in an FFmpeg artifact, and package_variant copies
    # $FFBUILD_PREFIX/share/man wholesale. FFmpeg's own man pages are installed
    # later by `make install`, so they are unaffected.
    # NOTE: share/man pruning is a deliberate deviation from upstream.
    rm -rf "$FFBUILD_DESTPREFIX"/bin "$FFBUILD_DESTPREFIX"/share/man

    # Merge this stage's install tree into the shared prefix.
    if [[ -d "$FFBUILD_DESTPREFIX" ]]; then
        cp -al "$FFBUILD_DESTPREFIX"/. "$FFBUILD_PREFIX"/ 2>/dev/null || \
            cp -a "$FFBUILD_DESTPREFIX"/. "$FFBUILD_PREFIX"/
    fi
fi

# Upstream's 47-vulkan/99-enable stage copies /opt/glslc into /usr/bin/glslc via
# a Docker layer. Natively we surface it on $PATH instead (see native/env.sh).
if [[ -s /opt/glslc ]]; then
    mkdir -p "$FFBUILD_ROOT/bin"
    ln -sf /opt/glslc "$FFBUILD_ROOT/bin/glslc"
fi

if [[ -n "${STAGENAME:-}" && -n "${FFBUILD_STAGE_ROOT:-}" ]]; then
    rm -rf "$FFBUILD_STAGE_ROOT/$STAGENAME"
fi
