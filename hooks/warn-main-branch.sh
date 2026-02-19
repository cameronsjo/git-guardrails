#!/bin/bash
# Warn once per session when editing files directly on main/master

branch=$(git symbolic-ref --short HEAD 2>/dev/null) || exit 0
[[ "$branch" == "main" || "$branch" == "master" ]] || exit 0

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
hash=$(echo "$repo_root" | (md5 -q 2>/dev/null || md5sum | cut -d' ' -f1))
[[ -z "$hash" ]] && hash=$(echo "$repo_root" | cksum | cut -d' ' -f1)
[[ -z "$hash" ]] && exit 0  # Cannot compute hash, skip warning
marker="/tmp/.claude-main-branch-warned-${hash}-${PPID}"
[[ -f "$marker" ]] && exit 0

echo "You're editing files directly on '$branch'. Ask the user: should this work be on a feature branch instead?"
touch "$marker"
exit 0
