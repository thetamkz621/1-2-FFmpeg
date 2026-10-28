#!/bin/bash

# git_version_ge <min> — 主机 git 是否不低于 <min>（例如 2.36）。
# 阶段脚本在 ffbuild_dockerdl 里生成下载命令时用它做选项兼容判断。
git_version_ge() {
    local have
    have="$(git version 2>/dev/null | awk '{print $3}')"
    [[ -n "$have" ]] || return 1
    [[ "$(printf '%s\n%s\n' "$1" "$have" | sort -V | head -n1)" == "$1" ]]
}

default_dl() {
    echo "git-mini-clone \"$SCRIPT_REPO\" \"$SCRIPT_COMMIT\" \"$1\""
}

ffbuild_dockerdl() {
    default_dl .
}
