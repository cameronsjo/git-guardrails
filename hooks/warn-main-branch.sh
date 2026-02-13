#!/bin/bash
# Warn once per session when editing files directly on main/master

branch=$(git symbolic-ref --short HEAD 2>/dev/null) || exit 0
[[ "$branch" == "main" || "$branch" == "master" ]] || exit 0

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
hash=$(echo "$repo_root" | (md5 -q 2>/dev/null || md5sum | cut -d' ' -f1))
marker="/tmp/.claude-main-branch-warned-${hash}"
[[ -f "$marker" ]] && exit 0

echo "You're editing files directly on '$branch'. Ask the user: should this work be on a feature branch instead?"
touch "$marker"
exit 0
