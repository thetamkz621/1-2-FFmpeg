#!/bin/bash
# shellcheck shell=bash
#
# util/source-prep.sh — resolve FFMPEG_REPO into $FFMPEG_DIR.
#
# FFMPEG_REPO accepts three forms:
#
#   remote git URL        clone $GIT_BRANCH (master unless overridden)
#   local git checkout    clone it and check out its current HEAD, or
#                         $GIT_BRANCH_OVERRIDE when that is set
#   local plain directory copy it; the directory must contain configure
#
# The source is never built in place. The caller removes and recreates
# $FFMPEG_DIR under the build root; this file only writes there.

ffmpeg_source_prepare() {
    local src="$FFMPEG_REPO" head=""

    if [[ -z "$src" ]]; then
        echo "build.sh: FFMPEG_REPO is empty" >&2
        return 1
    fi

    if [[ -d "$src" ]]; then
        src="$(cd "$src" && pwd)"

        if git -C "$src" rev-parse --git-dir >/dev/null 2>&1; then
            head="$(git -C "$src" rev-parse --verify HEAD 2>/dev/null)" || {
                echo "build.sh: $src is a git repository without commits" >&2
                return 1
            }
            git clone --quiet "$src" "$FFMPEG_DIR" || return 1

            # The clone only mirrors what the source repository had checked
            # out, so a detached HEAD has to be restored explicitly.
            local ref="${GIT_BRANCH_OVERRIDE:-$head}"
            if ! git -C "$FFMPEG_DIR" checkout --quiet --detach "$ref" 2>/dev/null; then
                git -C "$FFMPEG_DIR" checkout --quiet --detach "origin/$ref" || {
                    echo "build.sh: cannot check out '$ref' from $src" >&2
                    return 1
                }
            fi
        else
            if [[ -n "${GIT_BRANCH_OVERRIDE:-}" ]]; then
                echo "build.sh: GIT_BRANCH_OVERRIDE is ignored for a plain source directory" >&2
            fi
            if [[ ! -f "$src/configure" ]]; then
                echo "build.sh: $src is not an FFmpeg source directory (configure not found)" >&2
                return 1
            fi
            mkdir -p "$FFMPEG_DIR"
            cp -a "$src/." "$FFMPEG_DIR/" || return 1
        fi
    elif [[ "$src" == *://* || "$src" == *@*:* ]]; then
        # A dropped connection leaves a partial clone and a checkout that
        # cannot fetch its promisor objects. Retry the whole clone, cleaning
        # the destination first; the FFmpeg repository is large enough that
        # the default 120 s attempt timeout is too short.
        local retry="$FFBUILD_REPO_ROOT/util/bin/retry-tool"
        if [[ ! -x "$retry" ]]; then
            echo "build.sh: retry-tool not found at $retry" >&2
            return 1
        fi
        RETRY_TIMEOUT="${RETRY_TIMEOUT:-3600}" "$retry" bash -c '
            dest=$1; url=$2; branch=$3
            rm -rf "$dest"
            exec git clone --filter=blob:none --branch="$branch" "$url" "$dest"
        ' _ "$FFMPEG_DIR" "$src" "$GIT_BRANCH" || return 1
    else
        echo "build.sh: FFMPEG_REPO=$src does not exist" >&2
        return 1
    fi

    if [[ ! -f "$FFMPEG_DIR/configure" ]]; then
        echo "build.sh: $FFMPEG_DIR is not an FFmpeg source tree (configure not found)" >&2
        return 1
    fi

    ffmpeg_source_check_version
}

# A source tree carrying RELEASE comes from a release artifact; the stage set
# is selected by the version addin, so a mismatch would configure the wrong
# tree with the wrong flags. Git checkouts have no RELEASE and are left alone.
ffmpeg_source_check_version() {
    local rel="" want=""

    [[ -f "$FFMPEG_DIR/RELEASE" ]] || return 0

    rel="$(head -n 1 "$FFMPEG_DIR/RELEASE" | tr -d '[:space:]')"
    if [[ ! "$rel" =~ ^([0-9]+)\.([0-9]+) ]]; then
        echo "build.sh: cannot parse FFmpeg RELEASE '$rel'; skipping version check" >&2
        return 0
    fi
    want="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"

    case "-${ADDINS_STR:-}-" in
    *"-$want-"*) return 0 ;;
    esac

    echo "build.sh: source is FFmpeg $rel, but addins '${ADDINS_STR:-<none>}' do not select $want" >&2
    echo "          rerun with the $want addin, e.g. ./build.sh $TARGET $VARIANT $want" >&2
    return 1
}
