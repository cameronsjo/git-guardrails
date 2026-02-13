#!/usr/bin/env bash
# guard-gh-write.sh — Block gh CLI write operations to non-owned repos
#
# PreToolUse hook for Bash. Detects gh write commands, resolves the
# target repo, and blocks if you don't own it.
#
# Config:
#   GIT_GUARDRAILS_ALLOWED_OWNERS  space-separated GitHub orgs/users (default: cameronsjo)
#   GIT_GUARDRAILS_ALLOWED_REPOS   space-separated owner/repo overrides (default: empty)

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Quick exit: no gh command
echo "$COMMAND" | grep -qE '\bgh\b' || exit 0

ALLOWED_OWNERS="${GIT_GUARDRAILS_ALLOWED_OWNERS:-}"
ALLOWED_REPOS="${GIT_GUARDRAILS_ALLOWED_REPOS:-}"

if [ -z "$ALLOWED_OWNERS" ]; then
  echo "🚫 git-guardrails: Not configured — run /guardrails-init to set up"
  echo "   GIT_GUARDRAILS_ALLOWED_OWNERS is not set."
  exit 2
fi

# --- Helpers ---

is_allowed() {
  local repo="$1"
  local owner="${repo%%/*}"

  # Specific repo overrides
  for allowed_repo in $ALLOWED_REPOS; do
    if [ "$repo" = "$allowed_repo" ]; then
      return 0
    fi
  done

  # Owner-level match
  for allowed_owner in $ALLOWED_OWNERS; do
    if [ "$owner" = "$allowed_owner" ]; then
      return 0
    fi
  done

  return 1
}

repo_from_url() {
  echo "$1" | sed -nE 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$|\1|p'
}

# --- Complexity gate ---

has_loop=$(echo "$COMMAND" | grep -cE '\bfor\b|\bwhile\b' || true)
if [ "$has_loop" -gt 0 ] && echo "$COMMAND" | grep -qE '\bgh\b'; then
  echo "🚫 git-guardrails: gh command in loop — cannot verify targets"
  echo "   Run each gh command individually."
  exit 2
fi

# --- Detect write operations ---

is_write=false

# gh <resource> <write-action>
WRITE_ACTIONS="create|merge|close|comment|edit|delete|transfer|archive|rename|review|reopen|ready|lock|unlock"
if echo "$COMMAND" | grep -qE "gh\s+(pr|issue|release|label|repo|gist)\s+(${WRITE_ACTIONS})"; then
  is_write=true
fi

# gh api with explicit write method
if echo "$COMMAND" | grep -qE 'gh\s+api.*(-X|--method)\s+(POST|PUT|PATCH|DELETE)'; then
  is_write=true
fi

# gh api with field flags (implicit POST)
if echo "$COMMAND" | grep -qE 'gh\s+api.*\s(-f\s|--field\s|-F\s|--raw-field\s)'; then
  is_write=true
fi

# Not a write — allow
$is_write || exit 0

# --- Parse working directory ---

work_dir="$(pwd)"

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

# --- Resolve target repo ---

target_repo=""

# 1. Explicit -R or --repo flag (highest priority)
if echo "$COMMAND" | grep -qE '(-R|--repo)\s+'; then
  target_repo=$(echo "$COMMAND" | grep -oE '(-R|--repo)\s+[^ ]+' | head -1 | awk '{print $2}')
fi

# 2. gh api with repos/OWNER/REPO anywhere in the command
if [ -z "$target_repo" ] && echo "$COMMAND" | grep -qE 'gh\s+api\b.*/?repos/'; then
  target_repo=$(echo "$COMMAND" | grep -oE '/?repos/[^/]+/[^/ ]+' | head -1 | sed 's|^/\{0,1\}repos/||')
fi

# 3. Resolve from git remotes
if [ -z "$target_repo" ]; then
  # Fork detection: if upstream remote exists, gh CLI may resolve ANY write
  # operation to the parent repo (pr create targets parent, issue/release
  # resolution is ambiguous). Require -R in fork repos to eliminate ambiguity.
  upstream_url=$(git -C "$work_dir" remote get-url upstream 2>/dev/null || echo "")
  if [ -n "$upstream_url" ]; then
    upstream_repo=$(repo_from_url "$upstream_url")
    origin_url=$(git -C "$work_dir" remote get-url origin 2>/dev/null || echo "")
    origin_repo=$(repo_from_url "$origin_url")
    echo "🚫 git-guardrails: Write operation in a fork — specify target with -R"
    echo "   Fork:     $origin_repo"
    echo "   Upstream: $upstream_repo"
    echo ""
    echo "   Use -R $origin_repo to target your fork"
    echo "   Use -R $upstream_repo to target upstream (if intended)"
    exit 2
  fi

  # Non-fork: resolve from origin
  origin_url=$(git -C "$work_dir" remote get-url origin 2>/dev/null || echo "")
  if [ -n "$origin_url" ]; then
    target_repo=$(repo_from_url "$origin_url")
  fi
fi

if [ -z "$target_repo" ]; then
  echo "⚠️  git-guardrails: Cannot determine target repo for gh write operation"
  echo "   Use -R owner/repo to specify target explicitly."
  exit 2
fi

# --- Check ownership ---

if ! is_allowed "$target_repo"; then
  echo "🚫 git-guardrails: gh write targets repo you don't own"
  echo "   Target:  $target_repo"
  echo "   Allowed: owners=[$ALLOWED_OWNERS] repos=[$ALLOWED_REPOS]"
  echo ""
  echo "   To override: add to GIT_GUARDRAILS_ALLOWED_REPOS"
  echo "   Or specify:  -R owner/repo"
  exit 2
fi

exit 0
