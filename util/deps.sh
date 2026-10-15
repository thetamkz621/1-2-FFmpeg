#!/bin/bash
# shellcheck shell=bash
#
# util/deps.sh — Stage dependency-graph resolution.
#
# Extracted from upstream generate.sh (which used it to emit a multi-stage
# Dockerfile). The logic is retained verbatim; only the Docker emission was
# dropped, plus a topological `get_build_order` for sequential native builds.
#
# Requires the stage defaults from util/vars.sh to be in scope, and the current
# working directory to be the repository root.

# Last scripts.d entry is the build entry point (zz-final.sh upstream).
ffbuild_entry_script() {
    ls -1d scripts.d/* | tail -n 1
}

resolvestage() {
    [[ -d "$1" ]] && local SCRIPTDIR=("$1") || local SCRIPTDIR=(scripts.d/??-"$1")
    if [[ -d "${SCRIPTDIR[0]}" ]]; then
        echo scripts.d/??-"${1}"
    else
        echo scripts.d/??-"${1}.sh"
    fi
}

resolvescript() {
    local STAGE
    STAGE="$(resolvestage "$1")"
    if [[ -d "$STAGE" ]]; then
        ls -1 "$STAGE"/*.sh | tail -n 1
    else
        echo "$STAGE"
    fi
}

# Scripts that make up a stage, in build order.
# A directory stage contributes its ??-*.sh children; a file stage itself.
ffbuild_stage_scripts() {
    local STAGE
    STAGE="$(resolvestage "$1")"
    if [[ -d "$STAGE" ]]; then
        ls -1 "$STAGE"/??-*.sh 2>/dev/null || ls -1 "$STAGE"/*.sh
    elif [[ -f "$STAGE" ]]; then
        echo "$STAGE"
    fi
}

get_stagedeps() {
    [[ -d "$1" ]] && local SCRIPTDIR=("$1") || local SCRIPTDIR=(scripts.d/??-"$1")
    if [[ -d "${SCRIPTDIR[0]}" ]]; then
        local RESDEPS=()
        local SUBSCRIPT
        for SUBSCRIPT in "${SCRIPTDIR[0]}"/*.sh; do
            RESDEPS+=( $(get_stagedeps "${SUBSCRIPT}") )
        done
        tr ' ' '\n' <<< "${RESDEPS[@]}" | sort -u
    else
        local SCRIPT
        [[ -f "$1" ]] && SCRIPT=("$1") || SCRIPT=(scripts.d/??-"${1}.sh")
        SCRIPT="${SCRIPT[0]}"
        (
            SELF="$SCRIPT"
            STAGENAME="$(basename "$SCRIPT" .sh)"
            source util/dl_functions.sh
            # shellcheck disable=SC1090
            source "$SCRIPT"

            ffbuild_enabled || exit 0
            ffbuild_depends
        )
    fi
}

get_stagedeps_recursive_internal() {
    local CDEPS
    CDEPS=($(get_stagedeps "$1"))
    local CDEP
    for CDEP in "${CDEPS[@]}"; do
        get_stagedeps_recursive_internal "$CDEP"
    done
    printf '%s\n' "${CDEPS[@]}"
}

get_stagedeps_recursive() {
    declare -A ALREADY_PRINTED
    local CDEP
    for CDEP in $(get_stagedeps_recursive_internal "$1"); do
        if ! [[ -v ALREADY_PRINTED["$CDEP"] ]]; then
            echo "$CDEP"
            ALREADY_PRINTED["$CDEP"]="1"
        fi
    done
}

get_filled_deps() {
    local CUR_DEPS
    CUR_DEPS=($(get_stagedeps "$1"))
    local UNFILLED_DEPS=()
    local DEP
    for DEP in "${CUR_DEPS[@]}"; do
        [[ -v FILLED_DEPS["$DEP"] ]] || UNFILLED_DEPS+=("$DEP")
    done
    if [[ "${#UNFILLED_DEPS[@]}" -eq 0 ]]; then
        echo "$1"
    else
        for DEP in "${UNFILLED_DEPS[@]}"; do
            get_filled_deps "$DEP" | sort -u
        done
    fi
}

get_output() {
    (
        SELF="$1"
        # shellcheck disable=SC1090
        source "$1"
        if ffbuild_enabled; then
            "ffbuild_$2" || exit 0
        else
            "ffbuild_un$2" || exit 0
        fi
    )
}

# Topological build order (dependencies before dependents), deduplicated.
# Expands directory stages into their individual scripts at the right position,
# and drops anything whose ffbuild_enabled() returns non-zero.
get_build_order() {
    local entry="$1"
    declare -A EMITTED=()
    local -a ORDER=()

    _ffbuild_visit() {
        local stage="$1" dep
        for dep in $(get_stagedeps "$stage"); do
            _ffbuild_visit "$dep"
        done
        [[ -n "${EMITTED[$stage]:-}" ]] && return 0
        EMITTED[$stage]=1
        ORDER+=("$stage")
    }

    _ffbuild_visit "$entry"
    printf '%s\n' "${ORDER[@]}"
}

# Expand a stage name into the concrete script paths to execute.
# Emits nothing when the stage is disabled for the current target.
ffbuild_stage_enabled() {
    local name="$1"
    (
        local SCRIPT
        SCRIPT="$(resolvescript "$name")"
        [[ -f "$SCRIPT" ]] || exit 1
        SELF="$SCRIPT"
        # shellcheck disable=SC1090
        source "$SCRIPT"
        ffbuild_enabled
    )
}
