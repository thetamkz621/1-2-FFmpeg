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

# A cache produced by a stage that runs autoreconf during its download step
# carries absolute symlinks to the generating host's automake, libtool and
# autoconf (config.sub, ltmain.sh, m4/libtool.m4, ...). After the cache moves to
# another host or repository path those links dangle, and aclocal stops with
# "file 'm4/lt~obsolete.m4' does not exist" before autoreconf can reinstall
# them. Replace a link with the file it points at when that target exists here;
# otherwise drop it so the stage's own autoreconf installs a fresh copy.
ffbuild_materialise_absolute_links() {
    local root="$1" link target tmp
    while IFS= read -r -d '' link; do
        target="$(readlink "$link")"
        [[ "$target" == /* ]] || continue
        tmp="$link.ffbuild-tmp"
        rm -rf "$tmp"
        if cp -RL -- "$link" "$tmp" 2>/dev/null; then
            rm -f "$link"
            mv -f "$tmp" "$link"
        else
            rm -rf "$tmp"
            rm -f "$link"
        fi
    done < <(find "$root" -type l -print0)
}

if [[ -n "${STAGENAME:-}" && -n "${FFBUILD_STAGE_ROOT:-}" ]]; then
    STAGE_DIR="$FFBUILD_STAGE_ROOT/$STAGENAME"
    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR"
    if [[ -n "${STAGE_CACHE:-}" && -f "$STAGE_CACHE" ]]; then
        tar xaf "$STAGE_CACHE" -C "$STAGE_DIR"
        ffbuild_materialise_absolute_links "$STAGE_DIR"
    fi
    cd "$STAGE_DIR"
fi

# Git calls a repository "dubious" when its owner is not the current user, and a
# stage work dir can legitimately be owned by someone else (sources extracted
# from a cache tarball or carried over from another machine). Inject the
# exception into this process tree instead of the host config: safe.directory is
# read from protected configuration, which includes the command scope, so
# GIT_CONFIG_* covers every git call below. The previous
# `git config --global --add` appended a new entry to the host's ~/.gitconfig on
# every stage that ran, duplicates included.
_git_cfg_index="${GIT_CONFIG_COUNT:-0}"
export GIT_CONFIG_COUNT=$((_git_cfg_index + 1))
export "GIT_CONFIG_KEY_${_git_cfg_index}=safe.directory"
export "GIT_CONFIG_VALUE_${_git_cfg_index}=$PWD"
unset _git_cfg_index

# `git am` (used by 50-aom) needs a committer identity. Provide a throwaway one
# for this process tree only -- never write to ~/.gitconfig.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-FFmpeg Builds}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-builder@localhost}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-FFmpeg Builds}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-builder@localhost}"

# gnulib's pygnulib (run by libiconv's bootstrap) otherwise puts its bytecode
# cache in $TMPDIR/gnulib-python-cache-$USER. Keep it in the build root; it
# honours PYTHONPYCACHEPREFIX when set.
export PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-$FFBUILD_ROOT/.pycache}"

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

    # Merge this stage's install tree into the shared prefix, *everything*
    # included: in our single-filesystem model this merge is the only channel
    # through which a later stage can use an earlier stage's build-time tools.
    #
    # Upstream can afford to drop bin/ here (`rm -rf "$FFBUILD_DESTPREFIX"/bin`
    # at the end of its in-container run_stage) because a Docker sub-stage first
    # hardlink-copies its DESTDIR onto `/`, which makes e.g. glib's
    # `glib-mkenums` visible to its siblings (pango needs it) while still keeping
    # it out of the *merged* prefix. We have no such second channel, so pruning
    # here breaks the build: with it, `50-librsvg/30-pango` fails with
    # "Dependency 'glib-2.0' tool variable 'glib_mkenums' contains erroneous
    # value".
    #
    # Third-party tools and man pages are therefore pruned once, at packaging
    # time, in build.sh (see "prune dependency junk") — after every dependency
    # has been built and before FFmpeg is installed, so FFmpeg's own bin/ and
    # man1/ are unaffected.
    #
    # --remove-destination is load-bearing: later stages and sibling scripts of
    # the same directory stage install over files an earlier one already merged,
    # and plain `cp -l` refuses to replace an existing destination — it goes
    # straight to link() and fails with EEXIST, which leaves the *old* file in
    # place while the command exits non-zero. cp -a is the fallback for a
    # cross-device destination, where hard links are impossible.
    #
    # The sentinel marks the prefix as being modified. A copy interrupted here
    # leaves an unknown part of the stage behind, which re-running the stage
    # cannot repair; build.sh refuses to continue while the file exists.
    if [[ -d "$FFBUILD_DESTPREFIX" ]]; then
        if [[ -n "${STAGE_KEY:-${STAGENAME:-}}" && -n "${FFBUILD_STATE:-}" ]]; then
            : > "$FFBUILD_STATE/.merging.${STAGE_KEY:-${STAGENAME:-}}"
        fi
        cp -al --remove-destination "$FFBUILD_DESTPREFIX"/. "$FFBUILD_PREFIX"/ ||
            cp -a --remove-destination "$FFBUILD_DESTPREFIX"/. "$FFBUILD_PREFIX"/
        if [[ -n "${STAGE_KEY:-${STAGENAME:-}}" && -n "${FFBUILD_STATE:-}" ]]; then
            rm -f "$FFBUILD_STATE/.merging.${STAGE_KEY:-${STAGENAME:-}}"
        fi
    fi
fi

if [[ -n "${STAGENAME:-}" && -n "${FFBUILD_STAGE_ROOT:-}" ]]; then
    rm -rf "$FFBUILD_STAGE_ROOT/$STAGENAME"
fi
