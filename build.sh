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
#   FFBUILD_FORCE=1         discard prefix/state and rebuild every stage
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

# Both options empty the prefix that FFMPEG_ONLY reuses, so the combination is
# contradictory rather than merely redundant.
if [[ -n "${FFBUILD_FFMPEG_ONLY:-}" && \
      -n "${FFBUILD_FORCE:-}${FFBUILD_CLEAN:-}" ]]; then
    echo "build.sh: FFBUILD_FFMPEG_ONLY cannot be combined with FFBUILD_FORCE or FFBUILD_CLEAN" >&2
    echo "          they empty the prefix that FFBUILD_FFMPEG_ONLY is asked to reuse" >&2
    exit 2
fi

if [[ -n "${FFBUILD_CLEAN:-}" ]]; then
    echo "== cleaning $FFBUILD_ROOT =="
    rm -rf "$FFBUILD_ROOT"
fi

mkdir -p "$FFBUILD_ROOT"/{prefix,destdir,work,log}
FFBUILD_STAGE_ROOT="$FFBUILD_ROOT/work/stages"
FFBUILD_STATE="$FFBUILD_ROOT/state"
export FFBUILD_STAGE_ROOT FFBUILD_STATE
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

# Write /cross.meson and /toolchain.cmake into this build root, now that the lock
# is held, the tree has been cleared if asked to, and the target/compiler stamp
# has been checked. They embed the prefix and the compiler, so one root cannot
# serve two builds; keeping them out of the repository is what stops another
# target's build (or setup.sh) from overwriting the copy a running stage reads.
ffbuild_write_toolchain_files

# Reuse is only sound when the prefix holds exactly the stages that precede the
# first stage still to build: every configure in this tree probes the prefix as a
# whole. Clearing it is therefore how a rebuild starts, rather than re-running
# stages on top of their own output (glib's libintl probe, freetype finding
# brotli) and silently changing the result.
ffbuild_discard_prefix() {
    local root="${FFBUILD_ROOT%/}" parent
    parent="${root#/}"
    if [[ -z "$root" || "$root" != /* || "$parent" != */* ]]; then
        echo "build.sh: refusing to clear FFBUILD_ROOT='$FFBUILD_ROOT'" >&2
        exit 1
    fi
    if [[ "$FFBUILD_PREFIX" != "$root/prefix" ||
          "$FFBUILD_STATE" != "$root/state" ||
          "$FFBUILD_DESTDIR" != "$root/destdir" ]]; then
        echo "build.sh: refusing to clear an unexpected layout under $root" >&2
        exit 1
    fi
    if [[ -L "$FFBUILD_PREFIX" ]]; then
        echo "build.sh: $FFBUILD_PREFIX is a symlink; remove it manually before rebuilding" >&2
        exit 1
    fi
    if [[ -d "$FFBUILD_PREFIX" ]]; then
        echo "   dropping $FFBUILD_PREFIX ($(du -sh "$FFBUILD_PREFIX" 2>/dev/null | cut -f1))"
    fi
    rm -rf "$FFBUILD_PREFIX" "$FFBUILD_STATE" "$FFBUILD_DESTDIR"
    mkdir -p "$FFBUILD_PREFIX" "$FFBUILD_STATE" "$FFBUILD_DESTDIR"
}

if [[ -n "${FFBUILD_FORCE:-}" ]]; then
    echo "== discarding the prefix and stage state =="
    ffbuild_discard_prefix
fi

# A .merging.<stage> sentinel is written just before a stage's files are copied
# into the prefix and removed afterwards. A leftover means that copy was
# interrupted, so the prefix holds an unknown part of the stage; re-running the
# stage cannot repair it.
for _merging in "$FFBUILD_STATE"/.merging.*; do
    [[ -e "$_merging" ]] || continue
    echo "build.sh: the previous run was interrupted while merging ${_merging##*/.merging.}" >&2
    echo "          the prefix may hold an incomplete stage; rebuild it with FFBUILD_FORCE=1" >&2
    exit 1
done
unset _merging

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
            STAGE_KEY="$(stage_key "$SCRIPT")" \
            bash util/run_stage.sh "$SCRIPT"; then
        echo "ERROR: stage $STAGENAME failed; not marking it done" >&2
        return 1
    fi

    # The marker records what the stage was built from, so the next run can tell
    # "already built from these inputs" from "built from others". Write it under
    # a temporary name first: a half-written marker must not look valid.
    stage_fingerprint "$SCRIPT" > "$FFBUILD_STATE/$(stage_key "$SCRIPT").done.tmp"
    mv -f "$FFBUILD_STATE/$(stage_key "$SCRIPT").done.tmp" \
        "$FFBUILD_STATE/$(stage_key "$SCRIPT").done"
    printf '%s\n' "$(stage_key "$SCRIPT")" >> "$FFBUILD_STATE/.built"
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

# --- stage input fingerprints ----------------------------------------------
# A .done marker says which inputs produced the files a stage installed. Reuse is
# allowed only while those inputs are unchanged: the prefix is the product of one
# (stage set, inputs) pair, and every configure in this tree probes the whole
# prefix. Markers written before fingerprints existed are empty and count as
# unusable rather than as "built from anything".
declare -A FFBUILD_STAGE_STATE=()
FFBUILD_ENV_FP=""

ffbuild_env_fp() {
    local cc_ver cxx_ver f canon
    cc_ver="$("${CC:-cc}" --version 2>/dev/null | head -n 1)"
    cxx_ver="$("${CXX:-c++}" --version 2>/dev/null | head -n 1)"
    canon="$(
        {
            printf 'label %s\n' "${FFBUILD_TARGET}:${FFBUILD_COMPILER_LABEL:-${FFBUILD_COMPILER:-unknown}}"
            printf 'cc %s\n' "$cc_ver"
            printf 'cxx %s\n' "$cxx_ver"
            printf 'cflags %s\n' "${CFLAGS-}"
            printf 'cxxflags %s\n' "${CXXFLAGS-}"
            printf 'ldflags %s\n' "${LDFLAGS-}"
            printf 'ldexeflags %s\n' "${LDEXEFLAGS-}"
            printf 'stage_cflags %s\n' "${STAGE_CFLAGS-}"
            printf 'stage_cxxflags %s\n' "${STAGE_CXXFLAGS-}"
            printf 'stage_ldflags %s\n' "${STAGE_LDFLAGS-}"
            printf 'addins %s\n' "${ADDINS_STR-}"
            printf 'ffver %s\n' "${FFVER-}"
            for f in "$FFBUILD_TARGET_CONF" util/run_stage.sh util/dl_functions.sh util/vars.sh; do
                printf 'file %s %s\n' "$f" "$(sha256sum "$f" | cut -d' ' -f1)"
            done
        }
    )"
    sha256sum <<<"$canon" | cut -d' ' -f1
}

# The download cache is keyed by a hash of the fetch recipe and its symlink is
# refreshed on every run, so the name is the source identity without fetching.
ffbuild_source_fp() {
    local name="$1" link="$FFBUILD_REPO_ROOT/.cache/downloads/${1}.tar.xz" target
    if [[ -L "$link" ]]; then
        target="$(readlink "$link")"
        target="${target#"${name}"_}"
        printf '%s' "${target%.tar.xz}"
    else
        printf '%s' '-'
    fi
}

ffbuild_patches_fp() {
    local src="$1"
    if [[ -z "$src" || ! -d "$src" ]]; then
        printf '%s' '-'
        return 0
    fi
    find "$src" -type f -print0 | sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1
}

stage_fingerprint() {
    local SCRIPT="$1" name
    name="$(basename "$SCRIPT" .sh)"
    printf 'script %s\n' "$(sha256sum "$SCRIPT" | cut -d' ' -f1)"
    printf 'source %s\n' "$(ffbuild_source_fp "$name")"
    printf 'patches %s\n' "$(ffbuild_patches_fp "$(stage_patch_src "$SCRIPT")")"
    if [[ -z "$FFBUILD_ENV_FP" ]]; then
        FFBUILD_ENV_FP="$(ffbuild_env_fp)"
    fi
    printf 'env %s\n' "$FFBUILD_ENV_FP"
}

# Markers and logs are keyed by the script path, not by its basename:
# 99-finalize.sh exists in both 45-x11 and 50-vaapi, and a shared key would make
# the second one look built and skip its finalize step.
stage_key() {
    local p="${1#scripts.d/}"
    p="${p%.sh}"
    printf '%s' "${p//\//__}"
}

# Echo one of: ok | missing | legacy | stale:<component>. Cached per script: the
# patch lookup sources the stage script, and the answer is used twice per run.
stage_state() {
    local SCRIPT="$1" marker key want got
    if [[ -n "${FFBUILD_STAGE_STATE[$SCRIPT]:-}" ]]; then
        STAGE_STATE="${FFBUILD_STAGE_STATE[$SCRIPT]}"
        return 0
    fi
    marker="$FFBUILD_STATE/$(stage_key "$SCRIPT").done"
    if [[ ! -f "$marker" ]]; then
        FFBUILD_STAGE_STATE[$SCRIPT]="missing"
    elif ! grep -q '^script ' "$marker"; then
        FFBUILD_STAGE_STATE[$SCRIPT]="legacy"
    else
        while read -r key want; do
            got="$(sed -n "s/^${key} //p" "$marker" | head -n 1)"
            if [[ "$got" != "$want" ]]; then
                FFBUILD_STAGE_STATE[$SCRIPT]="stale:${key}"
                break
            fi
        done < <(stage_fingerprint "$SCRIPT")
        FFBUILD_STAGE_STATE[$SCRIPT]="${FFBUILD_STAGE_STATE[$SCRIPT]:-ok}"
    fi
    STAGE_STATE="${FFBUILD_STAGE_STATE[$SCRIPT]}"
}

# Ordered stage scripts this run would build, after the skip list and
# ffbuild_enabled. Sets PLAN; only the verbose form prints the skip reasons.
PLAN=()
resolve_plan() {
    local verbose="${1:-}" ENTRY ORDER STAGE SCRIPT
    ENTRY="$(ffbuild_entry_script)"
    ORDER="$(get_build_order "$ENTRY")"
    PLAN=()
    for STAGE in $ORDER; do
        # The graph entry is the aggregator zz-final.sh: it contributes
        # dependencies but builds nothing, and it is reached here as a *path*
        # (ffbuild_entry_script prints one), so stage resolution would fail and
        # report it as skipped. Leave it out instead of printing noise.
        [[ "$STAGE" == "$ENTRY" ]] && continue
        if ffbuild_stage_skipped "$STAGE"; then
            if [[ -n "$verbose" ]]; then
                echo "-- skip (FFBUILD_SKIP_STAGES): $STAGE"
            fi
            continue
        fi
        # A stage can be off for reasons other than the target: the license
        # variant (x264 under lgpl, fdk-aac outside nonfree), the FFmpeg version
        # it needs, or an addin. Naming the target alone would blame the wrong
        # thing, so state what it is not applicable *to* and leave the reason to
        # the stage itself.
        if ! ffbuild_stage_enabled "$STAGE"; then
            if [[ -n "$verbose" ]]; then
                echo "-- skip (not applicable to $TARGET/$VARIANT): $STAGE"
            fi
            continue
        fi
        while IFS= read -r SCRIPT; do
            [[ -n "$SCRIPT" ]] || continue
            if ! script_enabled "$SCRIPT"; then
                if [[ -n "$verbose" ]]; then
                    echo "-- skip (not applicable to $TARGET/$VARIANT): $SCRIPT"
                fi
                continue
            fi
            PLAN+=("$SCRIPT")
        done < <(ffbuild_stage_scripts "$STAGE")
    done
}

# Every built stage is also recorded in state/.built. The ledger is what makes a
# deleted marker visible: without it the last stage in the plan is indistinguish-
# able from one that was never built, and would be rebuilt on top of its own
# files, which is the situation this whole check exists to prevent.
check_stage_ledger() {
    local key
    if [[ ! -f "$FFBUILD_STATE/.built" ]]; then
        return 0
    fi
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        if [[ ! -f "$FFBUILD_STATE/${key}.done" ]]; then
            echo "build.sh: stage ${key//__//} was built but its state marker is missing" >&2
            echo "          the prefix still contains its files; rebuild it with FFBUILD_FORCE=1" >&2
            return 1
        fi
    done < "$FFBUILD_STATE/.built"
    return 0
}

# Sound reuse needs the prefix to hold exactly the stages that precede the first
# stage still to build: a stage inserted before an already built one would
# configure against libraries a from-scratch build would not have installed yet,
# and changed inputs leave the dependents built against the old copy.
check_prefix_reuse() {
    local i SCRIPT state name first_missing=-1 marker foreign=()
    local -A in_plan=()
    for SCRIPT in "${PLAN[@]}"; do
        in_plan["$(stage_key "$SCRIPT")"]=1
    done

    for i in "${!PLAN[@]}"; do
        SCRIPT="${PLAN[i]}"
        name="$(basename "$SCRIPT" .sh)"
        stage_state "$SCRIPT"
        state="$STAGE_STATE"
        case "$state" in
        ok) ;;
        missing)
            if [[ $first_missing -lt 0 ]]; then
                first_missing=$i
            fi
            continue
            ;;
        legacy)
            echo "build.sh: stage $name has no input fingerprint (built by an older build.sh)" >&2
            echo "          the prefix cannot be reused; rebuild it with FFBUILD_FORCE=1" >&2
            return 1
            ;;
        stale:*)
            echo "build.sh: stage $name was built with different inputs (${state#stale:} changed)" >&2
            echo "          the prefix cannot be reused; rebuild it with FFBUILD_FORCE=1" >&2
            return 1
            ;;
        esac
        if [[ $first_missing -ge 0 ]]; then
            echo "build.sh: stage $name is built, but stage $(basename "${PLAN[first_missing]}" .sh) before it is not" >&2
            echo "          rebuilding it inside a populated prefix changes what configure probes" >&2
            echo "          rebuild from an empty prefix with FFBUILD_FORCE=1, or use a separate FFBUILD_ROOT" >&2
            return 1
        fi
    done

    if [[ $first_missing -lt 0 ]]; then
        return 0
    fi

    for marker in "$FFBUILD_STATE"/*.done; do
        [[ -e "$marker" ]] || continue
        name="$(basename "$marker" .done)"
        if [[ -z "${in_plan[$name]:-}" ]]; then
            foreign+=("$name")
        fi
    done
    if (( ${#foreign[@]} )); then
        echo "build.sh: the prefix contains stages that this build does not use: ${foreign[*]}" >&2
        echo "          they belong to another variant; other stages still need building, so" >&2
        echo "          their configure would run against the extra files in the prefix" >&2
        echo "          rebuild from an empty prefix with FFBUILD_FORCE=1, or use a separate FFBUILD_ROOT" >&2
        return 1
    fi
    return 0
}

build_deps() {
    local i SCRIPT state
    echo "== resolving dependency graph =="
    FFBUILD_ENV_FP="${FFBUILD_ENV_FP:-$(ffbuild_env_fp)}"
    if ! check_stage_ledger; then
        exit 1
    fi
    resolve_plan verbose
    echo "   ${#PLAN[@]} stage scripts in dependency order"
    if ! check_prefix_reuse; then
        exit 1
    fi

    for i in "${!PLAN[@]}"; do
        SCRIPT="${PLAN[i]}"
        stage_state "$SCRIPT"
        state="$STAGE_STATE"
        if [[ "$state" == "ok" ]]; then
            echo "   (already built: $(basename "$SCRIPT" .sh))"
            continue
        fi
        echo "-- build: $SCRIPT"
        run_one_script "$SCRIPT" 2>&1 | tee "$FFBUILD_LOG/$(stage_key "$SCRIPT").log"
    done
}

# FFBUILD_FFMPEG_ONLY rebuilds nothing, so the prefix must already hold every
# stage this invocation needs, built from the current inputs.
check_prefix_complete() {
    local i SCRIPT state list missing=() unusable=()
    FFBUILD_ENV_FP="${FFBUILD_ENV_FP:-$(ffbuild_env_fp)}"
    if ! check_stage_ledger; then
        exit 1
    fi
    resolve_plan
    for i in "${!PLAN[@]}"; do
        SCRIPT="${PLAN[i]}"
        stage_state "$SCRIPT"
        state="$STAGE_STATE"
        case "$state" in
        ok) ;;
        missing) missing+=("$(basename "$SCRIPT" .sh)") ;;
        legacy)  unusable+=("$(basename "$SCRIPT" .sh) (no fingerprint)") ;;
        stale:*) unusable+=("$(basename "$SCRIPT" .sh) (${state#stale:} changed)") ;;
        esac
    done
    if (( ${#missing[@]} )); then
        list="$(printf '%s\n' "${missing[@]}" | head -n 10 | tr '\n' ' ')"
        echo "build.sh: the prefix is missing ${#missing[@]} enabled stages: $list" >&2
    fi
    if (( ${#unusable[@]} )); then
        echo "build.sh: the prefix holds stages built with different inputs: ${unusable[*]}" >&2
    fi
    if (( ${#missing[@]} || ${#unusable[@]} )); then
        echo "          FFBUILD_FFMPEG_ONLY only reuses a complete prefix" >&2
        echo "          rebuild the dependencies without it, using FFBUILD_FORCE=1" >&2
        exit 1
    fi
    if [[ ! -d "$FFBUILD_PREFIX" ]] || [[ -z "$(ls -A "$FFBUILD_PREFIX" 2>/dev/null)" ]]; then
        echo "build.sh: $FFBUILD_PREFIX is empty; nothing for FFBUILD_FFMPEG_ONLY to reuse" >&2
        exit 1
    fi
}


echo "== toolchain: ${FFBUILD_COMPILER_LABEL:-${FFBUILD_COMPILER:-unknown}} (CC=${CC:-?} CXX=${CXX:-?}, mode=${FFBUILD_TOOLCHAIN_MODE:-?}) =="

if [[ -n "${FFBUILD_FFMPEG_ONLY:-}" ]]; then
    check_prefix_complete
else
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
# Page types are configure-time decisions: man pages need pod2man, HTML needs
# makeinfo or texi2html. A disabled type is an empty target, so a failure here
# is a real generation error.
make install install-doc
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
