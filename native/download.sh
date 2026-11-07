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

        # git runs `maintenance run --auto` after fetch/clone/submodule update
        # by default, and gc.autoDetach lets that maintenance keep running
        # after the command returns. It rewrites .git/**/objects/pack while the
        # cache tarball is created, which makes GNU tar exit 1. The work dir is
        # temporary, so automatic maintenance has nothing to gain here; keep
        # the gc synchronous for older git versions that call `gc --auto`
        # directly. The tar retry below remains as a guard.
        local _gi="${GIT_CONFIG_COUNT:-0}"
        export GIT_CONFIG_COUNT=$((_gi + 2))
        export "GIT_CONFIG_KEY_${_gi}=maintenance.auto" "GIT_CONFIG_VALUE_${_gi}=false"
        export "GIT_CONFIG_KEY_$((_gi + 1))=gc.autoDetach" "GIT_CONFIG_VALUE_$((_gi + 1))=false"

        echo "fetching: $NAME"
        eval "set -e; $STG"

        # git can still be finishing a clone (or rewriting pack files from a
        # detached gc) when the archive is created. GNU tar then exits 1 with
        # "file changed as we read it" even though the work tree is complete.
        # Retry those races; any other failure is fatal.
        local attempt rc=0
        for attempt in 1 2 3; do
            rm -f "$TGT.tmp"
            if tar -I "xz -T0" -cpf "$TGT.tmp" .; then
                rc=0
                break
            else
                rc=$?
            fi
            if [[ $rc -ne 1 || $attempt -eq 3 ]]; then
                break
            fi
            echo "note: $NAME changed while archiving (tar exit 1); retrying" >&2
            sleep 2
        done
        if [[ $rc -ne 0 ]]; then
            rm -f "$TGT.tmp"
            echo "download.sh: failed to archive $NAME (tar exit $rc)" >&2
            exit "$rc"
        fi
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

# Per-script applicability. A directory stage can mix scripts that are enabled
# for different targets, so the stage-level check (which only evaluates the last
# script) is not precise enough for deciding what to download.
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

# Only the scripts required by one target/variant, honouring ffbuild_enabled().
needed_scripts() {
    # shellcheck source=util/vars.sh
    source util/vars.sh "$NEEDED_TARGET" "$NEEDED_VARIANT" "${NEEDED_ADDINS[@]+${NEEDED_ADDINS[@]}}"
    # shellcheck source=util/deps.sh
    source util/deps.sh

    local stage script
    for stage in $(get_build_order "$(ffbuild_entry_script)"); do
        while IFS= read -r script; do
            [[ -n "$script" ]] || continue
            script_enabled "$script" || continue
            printf '%s\n' "$script"
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