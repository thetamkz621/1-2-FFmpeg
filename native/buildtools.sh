#!/bin/bash
# shellcheck shell=bash
#
# native/buildtools.sh — 把 FFmpeg 依赖阶段需要的构建工具从源码编进
# .buildtools/prefix。每个工具一份配方：native/buildtools.d/NN-<name>.sh
#
# 配方约定（详见 native/buildtools.d/README.md）：
#   * 顶层只有变量赋值与函数定义 —— 本驱动会 source 它两次（取元数据、构建）
#   * 必填：BT_VERSION，以及 BT_URL（或 BT_URLS 数组）+ BT_SHA256；
#           git 源时改用 BT_COMMIT（BT_SHA256 留空）
#   * 必填：bt_build()，在解包目录内执行，自行带 --prefix="$BT_PREFIX"
#   * 可选：bt_deps()（打印依赖的工具名，仅用于顺序断言）、
#           bt_check()（自定义成功判定，默认跑 $BT_PREFIX/bin/<BT_BIN> --version）
#
# 用法：
#   native/buildtools.sh                  构建所有缺失项（按文件名顺序）
#   native/buildtools.sh --list           列出 name / version / checksum
#   native/buildtools.sh --tool NAME      只构建 NAME（逗号分隔或重复使用）
#   native/buildtools.sh --force NAME     强制重建 NAME
#   native/buildtools.sh --check          只报告缺口，不构建
#   --keep-going                          一个工具失败后继续构建其余的，最后统一报错
#   --jobs N                              并行度（默认 nproc）
#
# 安装前缀只放 bin/ 与 share/ 之类的纯工具内容：它绝不进入 PKG_CONFIG_LIBDIR，
# 一旦发现前缀里出现 *.pc，本脚本会直接报错（那意味着依赖构建会看到工具库）。
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECIPE_DIR="$REPO_ROOT/native/buildtools.d"
BT_PREFIX="${BT_PREFIX:-$REPO_ROOT/.buildtools/prefix}"
BT_STATE="${BT_STATE:-$REPO_ROOT/.buildtools/state}"
BT_LOG="${BT_LOG:-$REPO_ROOT/.buildtools/log}"
BT_SRC="${BT_SRC:-$REPO_ROOT/.buildtools/src}"
BT_CACHE="${BT_CACHE:-$REPO_ROOT/.cache/tools}"
BT_JOBS="${BT_JOBS:-$(nproc 2>/dev/null || echo 4)}"
BT_FAILED="$BT_STATE/failed-tools"
BT_CURRENT_NAME=""
export BT_PREFIX BT_JOBS BT_CACHE

DO_BUILD=1
DO_CHECK=0
DO_LIST=0
KEEP_GOING=0
WANT=()
FORCE=()

record_failure() {
    [[ -n "${BT_CURRENT_NAME:-}" ]] || return 0
    mkdir -p "$BT_STATE"
    printf '%s\n' "$BT_CURRENT_NAME" >> "$BT_FAILED"
}

die() {
    record_failure
    echo "buildtools.sh: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)   DO_LIST=1; DO_BUILD=0 ;;
        --check)  DO_CHECK=1; DO_BUILD=0 ;;
        --keep-going) KEEP_GOING=1 ;;
        --tool)   IFS=, read -r -a _t <<<"${2:-}"; WANT+=("${_t[@]}"); shift ;;
        --force)  FORCE+=("${2:-}"); shift ;;
        --jobs)   BT_JOBS="${2:-}"; export BT_JOBS; shift ;;
        -h|--help) sed -n '3,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

recipes() { ls -1 "$RECIPE_DIR"/*.sh 2>/dev/null | sort; }
tool_name() { local b; b="$(basename "$1" .sh)"; echo "${b#??-}"; }

load_meta() {   # $1 = recipe path；在当前 shell 里设置 BT_* 元数据
    BT_VERSION=""; BT_SHA256=""; BT_COMMIT=""; BT_URL=""; BT_URLS=(); BT_SOURCE=""
    BT_BIN=""; BT_STRIP_COMPONENTS=""
    # 配方定义的函数在同一个 shell 里会残留到下一个工具，先清掉
    unset -f bt_deps bt_build bt_check 2>/dev/null || true
    # shellcheck disable=SC1090
    . "$1"
    BT_SOURCE="${BT_SOURCE:-archive}"
    BT_STRIP_COMPONENTS="${BT_STRIP_COMPONENTS:-1}"
    BT_BIN="${BT_BIN:-$2}"
}

state_file() { echo "$BT_STATE/$1.done"; }
is_done() {     # $1 = name, $2 = expected stamp
    local f; f="$(state_file "$1")"
    [[ -f "$f" ]] && [[ "$(cat "$f" 2>/dev/null)" == "$2" ]]
}
stamp() { echo "$BT_VERSION ${BT_SHA256:-${BT_COMMIT:-}}"; }

download() {    # $1 = name, 其余为候选 URL
    local name="$1"; shift
    local out="$BT_CACHE/$name-$BT_VERSION.dl" url
    mkdir -p "$BT_CACHE"
    if [[ -f "$out" ]] && [[ -n "$BT_SHA256" ]] &&
       echo "$BT_SHA256  $out" | sha256sum -c - >/dev/null 2>&1; then
        echo "   cached: $out"; return 0
    fi
    for url in "$@"; do
        echo "   fetch: $url"
        if curl -fsSL --retry 3 --connect-timeout 20 -o "$out.part" "$url"; then
            mv -f "$out.part" "$out"
            break
        fi
        rm -f "$out.part"
    done
    [[ -f "$out" ]] || die "$name: download failed"
    if [[ -n "$BT_SHA256" ]]; then
        echo "$BT_SHA256  $out" | sha256sum -c - >/dev/null 2>&1 ||
            die "$name: sha256 mismatch for $out"
    fi
}

assert_clean_prefix() {
    local pcs
    pcs="$(find "$BT_PREFIX" -name '*.pc' -print -quit 2>/dev/null || true)"
    [[ -z "$pcs" ]] || die "工具前缀里出现了 pkg-config 文件（$pcs）；它绝不能提供库"
}

check_binary() {  # $1 = name
    # 有的工具 --version 返回非零（GNU indent 就是 64），配方可以用 bt_check 自己判定
    if declare -F bt_check >/dev/null 2>&1; then
        bt_check >/dev/null 2>&1 && return 0
        echo "   WARNING: bt_check failed for $1" >&2
        return 1
    fi
    local bin="$BT_PREFIX/bin/$BT_BIN"
    if [[ -x "$bin" ]]; then
        "$bin" --version >/dev/null 2>&1 && return 0
        echo "   WARNING: $bin exists but --version fails" >&2
        return 1
    fi
    local -a alt=("$BT_PREFIX"/bin/*"$BT_BIN"*)
    [[ -x "${alt[0]:-}" ]] && return 0
    return 1
}

build_one() {
    local recipe="$1" name; name="$(tool_name "$recipe")"
    BT_CURRENT_NAME="$name"
    load_meta "$recipe" "$name"

    local dep
    for dep in $(bt_deps 2>/dev/null || true); do
        is_done "$dep" "$(cat "$(state_file "$dep")" 2>/dev/null)" ||
            die "$name: dependency '$dep' is not built yet (run without --tool first)"
    done

    local src="$BT_SRC/$name" log="$BT_LOG/$name.log"
    mkdir -p "$BT_STATE" "$BT_LOG" "$BT_SRC" "$BT_PREFIX"

    echo "== $name $BT_VERSION"
    rm -rf "$src"; mkdir -p "$src"

    if [[ "$BT_SOURCE" == git ]]; then
        git clone --quiet --filter=blob:none "${BT_URL:-}" "$src" || die "$name: clone failed"
        git -C "$src" checkout --quiet "$BT_COMMIT" || die "$name: cannot checkout $BT_COMMIT"
    else
        download "$name" "${BT_URLS[@]:-${BT_URL:-}}"
        tar xf "$BT_CACHE/$name-$BT_VERSION.dl" -C "$src" \
            --strip-components="$BT_STRIP_COMPONENTS" || die "$name: unpack failed"
    fi

    (
        set -e
        cd "$src" || exit 1
        # 工具构建只看系统库：依赖前缀（ffbuild/prefix）与它的 .pc 都不该参与
        unset PKG_CONFIG_LIBDIR PKG_CONFIG_PATH CPPFLAGS CFLAGS CXXFLAGS LDFLAGS
        # 这些工具都是老 C 代码，gcc >= 15 默认的 gnu23 会把 `f()` 当成 `(void)`，
        # 直接编不过（texinfo 的 info、unzip 的 gmtime 原型）。统一按 C17 构建；
        # recipe 需要额外降级标志时自己往 CFLAGS 上追加。
        export CFLAGS="-O2 -std=gnu17"
        export PATH="$BT_PREFIX/bin:$PATH"
        # shellcheck disable=SC1090
        . "$recipe"
        bt_build
    ) >"$log" 2>&1 || { tail -n 20 "$log" >&2; die "$name: build failed (see $log)"; }

    assert_clean_prefix
    if ! check_binary "$name"; then
        die "$name: installed but not runnable (see $log)"
    fi

    stamp > "$(state_file "$name")"
    local _ver=""
    _ver="$("$BT_PREFIX/bin/$BT_BIN" --version 2>/dev/null | head -1)"
    echo "   ok: $BT_PREFIX/bin/$BT_BIN${_ver:+ ($_ver)}"
    BT_CURRENT_NAME=""
}

main() {
    local recipe name
    if (( DO_LIST )); then
        for recipe in $(recipes); do
            name="$(tool_name "$recipe")"
            load_meta "$recipe" "$name"
            printf '%-10s %-40s %s\n' "$name" "$BT_VERSION" "${BT_SHA256:-${BT_COMMIT:-}}"
        done
        return 0
    fi

    if (( ! DO_BUILD )) && (( DO_CHECK )); then
        local rc=0
        for recipe in $(recipes); do
            name="$(tool_name "$recipe")"
            load_meta "$recipe" "$name"
            if is_done "$name" "$(stamp)" && check_binary "$name"; then
                printf '  [ok]      %-10s %s\n' "$name" "$BT_VERSION"
            else
                printf '  [MISSING] %-10s %s\n' "$name" "$BT_VERSION"
                rc=1
            fi
        done
        return $rc
    fi

    mkdir -p "$BT_STATE"
    : > "$BT_FAILED"

    local -a list=()
    local -a failed=()
    if (( ${#WANT[@]} )); then
        list=("${WANT[@]}")
    else
        for recipe in $(recipes); do list+=("$(tool_name "$recipe")"); done
    fi

    for name in "${list[@]}"; do
        BT_CURRENT_NAME="$name"
        recipe="$(ls -1 "$RECIPE_DIR"/*-"$name".sh 2>/dev/null | head -1)"
        [[ -n "$recipe" ]] || die "no recipe for '$name'"
        load_meta "$recipe" "$name"

        if [[ " ${FORCE[*]} " == *" $name "* ]]; then
            rm -f "$(state_file "$name")"
        fi
        if is_done "$name" "$(stamp)"; then
            echo "== $name $BT_VERSION (already built)"
            BT_CURRENT_NAME=""
            continue
        fi
        if (( KEEP_GOING )); then
            # 子 shell 隔离：build_one 内部的 die 只结束这一项，后面的工具照建。
            if ! ( build_one "$recipe" ); then
                failed+=("$name")
                echo "note: $name failed; continuing (--keep-going)" >&2
            fi
        else
            build_one "$recipe"
        fi
    done

    if ((${#failed[@]})); then
        echo "buildtools.sh: ${#failed[@]} tool(s) failed: ${failed[*]}" >&2
        return 1
    fi
}

main
