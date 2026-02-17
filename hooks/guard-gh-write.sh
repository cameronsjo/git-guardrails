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
  echo "$1" | sed -nE 's|.*github\.com[:/]([0-9]+/)?([^/]+/[^/.]+)(\.git)?$|\2|p'
}

# --- Complexity gate ---

# Strip quoted strings before checking — loop keywords in prose (--body, --title,
# commit messages) are user data, not shell structure.
command_structure=$(echo "$COMMAND" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")
has_loop=$(echo "$command_structure" | grep -cE '\bfor\s+\w+\s+in\b|\bwhile\b.*;\s*do\b' || true)
if [ "$has_loop" -gt 0 ] && echo "$COMMAND" | grep -qE '\bgh\b'; then
  echo "🚫 git-guardrails: gh command in loop — cannot verify targets" >&2
  echo "   Run each gh command individually." >&2
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

# Fail-safe: block writes when unconfigured (but read-only gh commands above pass through,
# so /guardrails-init can run `gh api user` to detect identity).
if [ -z "$ALLOWED_OWNERS" ]; then
  echo "🚫 git-guardrails: Not configured — run /guardrails-init to set up" >&2
  echo "   GIT_GUARDRAILS_ALLOWED_OWNERS is not set." >&2
  exit 2
fi

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

# 2. gh repo create <name> — repo name is the positional arg, not -R
#    gh repo create doesn't support -R; the target is always the first
#    non-flag argument after 'create'.
if [ -z "$target_repo" ] && echo "$COMMAND" | grep -qE 'gh\s+repo\s+create\b'; then
  after_create=$(echo "$COMMAND" | sed -nE 's/.*gh[[:space:]]+repo[[:space:]]+create[[:space:]]+(.*)/\1/p')
  first_arg=$(echo "$after_create" | awk '{print $1}')
  if [ -n "$first_arg" ] && [[ "$first_arg" != -* ]]; then
    if echo "$first_arg" | grep -q '/'; then
      target_repo="$first_arg"
    else
      # Bare name (e.g. "llm-comic") — prefix with first allowed owner
      default_owner=$(echo "$ALLOWED_OWNERS" | awk '{print $1}')
      target_repo="${default_owner}/${first_arg}"
    fi
  fi
fi

# 4. gh api with repos/OWNER/REPO anywhere in the command
if [ -z "$target_repo" ] && echo "$COMMAND" | grep -qE 'gh\s+api\b.*/?repos/'; then
  target_repo=$(echo "$COMMAND" | grep -oE '/?repos/[^/]+/[^/ ]+' | head -1 | sed 's|^/\{0,1\}repos/||')
fi

# 5. Resolve from git remotes
if [ -z "$target_repo" ]; then
  # Fork detection: if upstream remote exists, gh CLI may resolve ANY write
  # operation to the parent repo (pr create targets parent, issue/release
  # resolution is ambiguous). Require -R in fork repos to eliminate ambiguity.
  upstream_url=$(git -C "$work_dir" remote get-url upstream 2>/dev/null || echo "")
  if [ -n "$upstream_url" ]; then
    upstream_repo=$(repo_from_url "$upstream_url")
    origin_url=$(git -C "$work_dir" remote get-url origin 2>/dev/null || echo "")
    origin_repo=$(repo_from_url "$origin_url")
    echo "🚫 git-guardrails: Write operation in a fork — specify target with -R" >&2
    echo "   Fork:     $origin_repo" >&2
    echo "   Upstream: $upstream_repo" >&2
    echo "" >&2
    echo "   Use -R $origin_repo to target your fork" >&2
    echo "   Use -R $upstream_repo to target upstream (if intended)" >&2
    exit 2
  fi

  # Non-fork: resolve from origin
  origin_url=$(git -C "$work_dir" remote get-url origin 2>/dev/null || echo "")
  if [ -n "$origin_url" ]; then
    target_repo=$(repo_from_url "$origin_url")
  fi
fi

if [ -z "$target_repo" ]; then
  echo "⚠️  git-guardrails: Cannot determine target repo for gh write operation" >&2
  echo "   Use -R owner/repo to specify target explicitly." >&2
  exit 2
fi

# --- Check ownership ---

if ! is_allowed "$target_repo"; then
  # Fork-parent: if the target matches the upstream remote, allow it.
  # This covers the common case of contributing back to the parent repo
  # (e.g. gh pr create -R upstream-owner/repo) without requiring manual
  # ALLOWED_REPOS entries.
  upstream_url=$(git -C "$work_dir" remote get-url upstream 2>/dev/null || echo "")
  if [ -n "$upstream_url" ]; then
    upstream_repo=$(repo_from_url "$upstream_url")
    if [ "$target_repo" = "$upstream_repo" ]; then
      exit 0
    fi
  fi

  echo "🚫 git-guardrails: gh write targets repo you don't own" >&2
  echo "   Target:  $target_repo" >&2
  echo "   Allowed: owners=[$ALLOWED_OWNERS] repos=[$ALLOWED_REPOS]" >&2
  echo "" >&2
  echo "   To override: add to GIT_GUARDRAILS_ALLOWED_REPOS" >&2
  echo "   Or specify:  -R owner/repo" >&2
  exit 2
fi

exit 0
