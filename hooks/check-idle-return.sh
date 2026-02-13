#!/bin/bash
# Nudge Claude to commit/save state after 5+ minutes of edit inactivity
# Uses "return from idle" pattern: checks gap since last edit, not actual idle time

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
hash=$(echo "$repo_root" | (md5 -q 2>/dev/null || md5sum | cut -d' ' -f1))
marker="/tmp/.claude-last-edit-${hash}"

if [[ -f "$marker" ]]; then
    last_ts=$(cat "$marker")
    now=$(date +%s)
    gap=$((now - last_ts))

    if [[ $gap -gt 300 ]]; then
        mins=$((gap / 60))
        echo "It's been ${mins}m since your last edit. Before continuing: check for uncommitted changes worth committing, and consider saving any learnings to auto memory."
    fi
fi

date +%s > "$marker"
exit 0
