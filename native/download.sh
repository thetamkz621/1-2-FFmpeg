#!/bin/bash
# shellcheck shell=bash
#
# native/download.sh — Native replacement for upstream download.sh.
#
# Upstream ran every stage's `ffbuild_dockerdl` inside a throwaway container
# purely to obtain a bash/git/tar environment. Here we simply run it on the host.
#
# Produces (identical layout to upstream):
#   .cache/downloads/<stage>_<hash>.tar.xz      (content-addressed cache)
#   .cache/downloads/<stage>.tar.xz -> <stage>_<hash>.tar.xz
#
# Usage:
#   ./native/download.sh                        # fetch everything
#   ./native/download.sh --needed linux64 gpl   # only what this target needs
#   ./native/download.sh hashonly               # print the cache key
#
# The `--needed` form resolves the dependency graph first and skips stages that
# are disabled for the target (e.g. mingw/schannel for linux64), which avoids
# downloading large Windows-only repositories.
#
# Slow-network knobs (see util/bin/retry-tool):
#   RETRY_TIMEOUT / RETRY_MAX / RETRY_TIMEOUT_INC / RETRY_SLEEP_MAX
#
set -eo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=native/env.sh
source "$HERE/env.sh"

cd "$FFBUILD_REPO_ROOT"

MODE=all
NEEDED_TARGET=""
NEEDED_VARIANT=""
NEEDED_ADDINS=()

case "${1:-}" in
hashonly)
    MODE=hashonly
    ;;
--needed)
    MODE=needed
    shift
    if [[ $# -lt 2 ]]; then
        echo "usage: $0 --needed <target> <variant> [addin ...]" >&2
        exit 2
    fi
    NEEDED_TARGET="$1"
    NEEDED_VARIANT="$2"
    shift 2
    NEEDED_ADDINS=("$@")
    ;;
""|all)
    MODE=all
    ;;
*)
    echo "usage: $0 [--needed <target> <variant> [addin ...]] | [hashonly]" >&2
    exit 2
    ;;
esac

DLDIR="$FFBUILD_REPO_ROOT/.cache/downloads"
mkdir -p "$DLDIR"

# Slow links are normal here (proxied GitHub); lengthen the default per-attempt
# timeout unless the caller already chose one.
export RETRY_TIMEOUT="${RETRY_TIMEOUT:-600}"
export RETRY_MAX="${RETRY_MAX:-8}"

# Clean up work dirs left behind by an interrupted previous run.
rm -rf "$FFBUILD_ROOT"/.dl.* 2>/dev/null || true

# Download steps may create temp dirs (librsvg's `cargo vendor` does). Keep them
# in the build root so they disappear with it instead of piling up in /tmp.
export TMPDIR="$FFBUILD_ROOT/.tmp"
mkdir -p "$TMPDIR"

process_stage() {
    local STAGE="$1"
    (
        set -eo pipefail
        source util/dl_functions.sh
        # shellcheck disable=SC1090
        source "$STAGE"

        local STG
        STG="$(ffbuild_dockerdl)"
        if [[ -z "$STG" ]]; then
            exit 0
        fi

        local HASH; HASH="$(sha256sum <<<"$STG" | cut -d' ' -f1)"
        local NAME; NAME="$(basename "$STAGE" .sh)"

        if [[ "$MODE" == "hashonly" ]]; then
            printf '%s\n' "$HASH"
            exit 0
        fi

        local TGT="$DLDIR/${NAME}_${HASH}.tar.xz"
        if [[ -f "$TGT" ]]; then
            rm -f "$DLDIR/${NAME}.tar.xz"
            ln -sf "${NAME}_${HASH}.tar.xz" "$DLDIR/${NAME}.tar.xz"
            echo "cache hit: $NAME"
            exit 0
        fi

        local WORKDIR; WORKDIR="$(mktemp -d "$FFBUILD_ROOT/.dl.XXXXXX")"
        # NB: single quotes + ${WORKDIR:-} because the trap fires after the
        # function scope has ended.
        trap 'rm -rf -- "${WORKDIR:-}"' EXIT
        cd "$WORKDIR"

        echo "fetching: $NAME"
        eval "set -e; $STG"

        tar -I "xz -T0" -cpf "$TGT.tmp" .
        mv "$TGT.tmp" "$TGT"
        rm -f "$DLDIR/${NAME}.tar.xz"
        ln -sf "${NAME}_${HASH}.tar.xz" "$DLDIR/${NAME}.tar.xz"
    )
}

# All stage scripts, in upstream's order.
all_scripts() {
    local s
    for s in scripts.d/*.sh scripts.d/*/*.sh; do
        [[ -e "$s" ]] && printf '%s\n' "$s"
    done
}

# Only the scripts required by one target/variant, honouring ffbuild_enabled().
needed_scripts() {
    # shellcheck source=util/vars.sh
    source util/vars.sh "$NEEDED_TARGET" "$NEEDED_VARIANT" "${NEEDED_ADDINS[@]+"${NEEDED_ADDINS[@]}"}"
    # shellcheck source=util/deps.sh
    source util/deps.sh

    local stage script
    for stage in $(get_build_order "$(ffbuild_entry_script)"); do
        ffbuild_stage_enabled "$stage" || continue
        while IFS= read -r script; do
            [[ -n "$script" ]] && printf '%s\n' "$script"
        done < <(ffbuild_stage_scripts "$stage")
    done
}

case "$MODE" in
hashonly)
    while IFS= read -r STAGE; do
        process_stage "$STAGE"
    done < <(all_scripts) | sha256sum | cut -d' ' -f1
    ;;
needed)
    echo "== downloading for ${NEEDED_TARGET} ${NEEDED_VARIANT} =="
    while IFS= read -r STAGE; do
        process_stage "$STAGE"
    done < <(needed_scripts)
    echo "download cache: $DLDIR"
    ;;
all)
    while IFS= read -r STAGE; do
        process_stage "$STAGE"
    done < <(all_scripts)
    echo "download cache: $DLDIR"
    ;;
esac
