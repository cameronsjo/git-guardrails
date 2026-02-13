#!/usr/bin/env bash
# guard-push-remote.sh — Block git push to remotes you don't own
#
# PreToolUse hook for Bash. Resolves the actual push target URL
# before the command executes and blocks if it's not yours.
#
# Config: GIT_GUARDRAILS_ALLOWED_OWNERS (space-separated, default: cameronsjo)

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Quick exit: no git push, no problem
echo "$COMMAND" | grep -qw 'git push' || exit 0

ALLOWED_OWNERS="${GIT_GUARDRAILS_ALLOWED_OWNERS:-}"

if [ -z "$ALLOWED_OWNERS" ]; then
  echo "🚫 git-guardrails: Not configured — run /guardrails-init to set up"
  echo "   GIT_GUARDRAILS_ALLOWED_OWNERS is not set."
  exit 2
fi

# --- Helpers ---

check_owner() {
  local url="$1"
  for owner in $ALLOWED_OWNERS; do
    # Match both HTTPS and SSH GitHub URLs
    if echo "$url" | grep -qiE "github\.com[:/]${owner}/"; then
      return 0
    fi
  done
  return 1
}

resolve_push_url() {
  local dir="$1"
  local remote="$2"

  if [ -n "$remote" ]; then
    git -C "$dir" remote get-url --push "$remote" 2>/dev/null
    return
  fi

  # No explicit remote — find where bare push would go
  local branch
  branch=$(git -C "$dir" branch --show-current 2>/dev/null) || return 1
  local tracking_remote
  tracking_remote=$(git -C "$dir" config "branch.${branch}.remote" 2>/dev/null || echo "origin")
  git -C "$dir" remote get-url --push "$tracking_remote" 2>/dev/null
}

# --- Complexity gate ---
# Can't statically resolve variable paths in loops. Block and require individual commands.

push_count=$(echo "$COMMAND" | grep -ow 'git push' | wc -l | tr -d ' ')
has_loop=$(echo "$COMMAND" | grep -cE '\bfor\b|\bwhile\b' || true)

if [ "$push_count" -gt 1 ] || [ "$has_loop" -gt 0 ]; then
  echo "🚫 git-guardrails: git push in batch/loop command — cannot verify targets"
  echo "   Run each push individually so remotes can be validated."
  exit 2
fi

# --- Parse working directory ---
work_dir="$(pwd)"

# Extract cd target from "cd DIR && ..." or "cd DIR ; ..."
if echo "$COMMAND" | grep -qE '^\s*cd\s+'; then
  cd_target=$(echo "$COMMAND" | sed -nE 's/^\s*cd\s+("([^"]*)"|([^ &;]+)).*/\2\3/p')
  if [ -n "$cd_target" ]; then
    if [[ "$cd_target" = /* ]]; then
      work_dir="$cd_target"
    elif [[ "$cd_target" = ~* ]]; then
      work_dir="${cd_target/#\~/$HOME}"
    else
      work_dir="$(pwd)/$cd_target"
    fi
  fi
fi

# Not a git repo — let git fail naturally
git -C "$work_dir" rev-parse --git-dir &>/dev/null || exit 0

# --- Extract explicit remote ---
push_segment=$(echo "$COMMAND" | grep -oE 'git push[^&;|]*' | head -1)

# Strip "git push", strip flags (--flag, -f), take first remaining word
push_args=$(echo "$push_segment" | sed 's/git push//; s/--[a-z][a-z-]*//g; s/ -[a-zA-Z]//g' | xargs)
explicit_remote=$(echo "$push_args" | awk '{print $1}')

# Verify it's actually a known remote name, not a refspec
if [ -n "$explicit_remote" ] && ! git -C "$work_dir" remote | grep -qx "$explicit_remote"; then
  explicit_remote=""
fi

# --- Resolve and validate ---
remote_url=$(resolve_push_url "$work_dir" "$explicit_remote" || echo "")

if [ -z "$remote_url" ]; then
  echo "⚠️  git-guardrails: Cannot resolve push target"
  echo "   Directory: $work_dir"
  echo "   Push explicitly: git push origin main"
  exit 2
fi

if ! check_owner "$remote_url"; then
  echo "🚫 git-guardrails: Push target is not yours"
  echo "   Would push to: $remote_url"
  echo "   Directory:     $work_dir"
  echo "   Allowed:       $ALLOWED_OWNERS"
  echo ""
  echo "   Fix tracking:  git branch -u origin/main"
  echo "   Push explicit: git push origin main"
  exit 2
fi

exit 0
