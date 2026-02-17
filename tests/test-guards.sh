#!/usr/bin/env bash
# test-guards.sh — Repeatable test suite for git-guardrails hooks
#
# Usage: ./tests/test-guards.sh
#
# Requires:
#   - jq
#   - A fork repo with both origin (youruser/*) and upstream (other/*) remotes
#   - A non-fork repo with only origin (youruser/*) remote
#
# The test uses real repo state but never actually pushes or creates anything.
# Owner detection is automatic from repo remotes — no hardcoded usernames.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/../hooks"
PUSH_HOOK="$HOOKS_DIR/guard-push-remote.sh"
GH_HOOK="$HOOKS_DIR/guard-gh-write.sh"

# Test repos — adjust if directory layout changes
FORK_REPO="${FORK_REPO:-$(cd "$SCRIPT_DIR/../../superpowers" 2>/dev/null && pwd)}"
OWN_REPO="${OWN_REPO:-$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)}"

passed=0
failed=0
total=0

# --- Detect owners from repo remotes ---

own_origin_url=$(git -C "$OWN_REPO" remote get-url origin 2>/dev/null)
OWN_OWNER=$(echo "$own_origin_url" | sed -nE 's|.*github\.com[:/]([^/]+)/.*|\1|p')

fork_origin_url=$(git -C "$FORK_REPO" remote get-url origin 2>/dev/null)
FORK_OWNER=$(echo "$fork_origin_url" | sed -nE 's|.*github\.com[:/]([^/]+)/.*|\1|p')
FORK_REPO_NAME=$(echo "$fork_origin_url" | sed -nE 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$|\1|p')

fork_upstream_url=$(git -C "$FORK_REPO" remote get-url upstream 2>/dev/null)
UPSTREAM_OWNER=$(echo "$fork_upstream_url" | sed -nE 's|.*github\.com[:/]([^/]+)/.*|\1|p')
UPSTREAM_REPO_NAME=$(echo "$fork_upstream_url" | sed -nE 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$|\1|p')

# Export for hooks — tests run as the repo owner
export GIT_GUARDRAILS_ALLOWED_OWNERS="$OWN_OWNER"

# --- Helpers ---

make_input() {
  local command="$1"
  echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(echo "$command" | jq -Rs .)}}"
}

expect_block() {
  local name="$1"
  local hook="$2"
  local command="$3"
  local work_dir="${4:-$OWN_REPO}"
  total=$((total + 1))

  set +e
  output=$(make_input "$command" | (cd "$work_dir" && bash "$hook" 2>&1))
  exit_code=$?
  set -e

  if [ "$exit_code" -ne 0 ]; then
    echo "  PASS  $name"
    passed=$((passed + 1))
  else
    echo "  FAIL  $name (expected block, got exit 0)"
    echo "        output: $output"
    failed=$((failed + 1))
  fi
}

expect_allow() {
  local name="$1"
  local hook="$2"
  local command="$3"
  local work_dir="${4:-$OWN_REPO}"
  total=$((total + 1))

  set +e
  output=$(make_input "$command" | (cd "$work_dir" && bash "$hook" 2>&1))
  exit_code=$?
  set -e

  if [ "$exit_code" -eq 0 ]; then
    echo "  PASS  $name"
    passed=$((passed + 1))
  else
    echo "  FAIL  $name (expected allow, got exit $exit_code)"
    echo "        output: $output"
    failed=$((failed + 1))
  fi
}

# --- Preflight ---

echo "=== git-guardrails test suite ==="
echo ""

if [ ! -d "$FORK_REPO/.git" ]; then
  echo "ERROR: Fork repo not found at $FORK_REPO"
  echo "Set FORK_REPO to a git repo with both origin and upstream remotes."
  exit 1
fi

if [ ! -d "$OWN_REPO/.git" ]; then
  echo "ERROR: Own repo not found at $OWN_REPO"
  echo "Set OWN_REPO to a git repo with only origin remote."
  exit 1
fi

if ! git -C "$FORK_REPO" remote get-url upstream &>/dev/null; then
  echo "ERROR: $FORK_REPO missing 'upstream' remote — not a fork setup."
  exit 1
fi

if [ "$OWN_OWNER" != "$FORK_OWNER" ]; then
  echo "ERROR: Own repo owner ($OWN_OWNER) != fork repo owner ($FORK_OWNER)"
  echo "Both repos should be owned by the same user."
  exit 1
fi

echo "Own repo:         $OWN_REPO"
echo "Fork repo:        $FORK_REPO"
echo "Your owner:       $OWN_OWNER"
echo "Upstream owner:   $UPSTREAM_OWNER"
echo "Allowed owners:   $GIT_GUARDRAILS_ALLOWED_OWNERS"
echo ""

# ===================================================================
# Unconfigured state (fail-safe)
# ===================================================================

echo "--- unconfigured (fail-safe) ---"
echo ""

# Temporarily unset the env var
_saved_owners="$GIT_GUARDRAILS_ALLOWED_OWNERS"
unset GIT_GUARDRAILS_ALLOWED_OWNERS

expect_block \
  "unconfigured: push hook blocks when ALLOWED_OWNERS unset" \
  "$PUSH_HOOK" \
  "git push" \
  "$OWN_REPO"

expect_block \
  "unconfigured: gh hook blocks writes when ALLOWED_OWNERS unset" \
  "$GH_HOOK" \
  "gh issue create --title test" \
  "$OWN_REPO"

# Read-only gh commands pass through even when unconfigured
# (needed for /guardrails-init to run `gh api user`)
expect_allow \
  "unconfigured: gh read-only command passes (gh api user)" \
  "$GH_HOOK" \
  "gh api user --jq .login" \
  "$OWN_REPO"

expect_allow \
  "unconfigured: gh pr list passes (read-only)" \
  "$GH_HOOK" \
  "gh pr list" \
  "$OWN_REPO"

# Non-push/non-gh commands still pass through
expect_allow \
  "unconfigured: non-push command still passes" \
  "$PUSH_HOOK" \
  "git status" \
  "$OWN_REPO"

expect_allow \
  "unconfigured: non-gh command still passes" \
  "$GH_HOOK" \
  "npm test" \
  "$OWN_REPO"

export GIT_GUARDRAILS_ALLOWED_OWNERS="$_saved_owners"

echo ""

# ===================================================================
# guard-push-remote.sh
# ===================================================================

echo "--- guard-push-remote.sh ---"
echo ""

# Save fork tracking state so we can simulate the broken case
original_tracking=$(git -C "$FORK_REPO" config branch.main.remote 2>/dev/null || echo "origin")

# Test: bare push when tracking upstream (the original incident)
git -C "$FORK_REPO" config branch.main.remote upstream
expect_block \
  "push: bare push tracking upstream" \
  "$PUSH_HOOK" \
  "git push" \
  "$FORK_REPO"
git -C "$FORK_REPO" config branch.main.remote "$original_tracking"

# Test: bare push when tracking origin
expect_allow \
  "push: bare push tracking origin" \
  "$PUSH_HOOK" \
  "git push" \
  "$FORK_REPO"

# Test: explicit push to origin
expect_allow \
  "push: explicit 'git push origin main'" \
  "$PUSH_HOOK" \
  "git push origin main" \
  "$FORK_REPO"

# Test: explicit push to upstream
expect_block \
  "push: explicit 'git push upstream main'" \
  "$PUSH_HOOK" \
  "git push upstream main" \
  "$FORK_REPO"

# Test: push with -u flag to origin
expect_allow \
  "push: 'git push -u origin main'" \
  "$PUSH_HOOK" \
  "git push -u origin main" \
  "$FORK_REPO"

# Test: push with -u flag to upstream
expect_block \
  "push: 'git push -u upstream main'" \
  "$PUSH_HOOK" \
  "git push upstream main" \
  "$FORK_REPO"

# Test: for loop with pushes (complexity gate)
expect_block \
  "push: for loop with git push" \
  "$PUSH_HOOK" \
  "for dir in a b; do cd /tmp/\$dir && git push; done" \
  "$FORK_REPO"

# Test: while loop with pushes
expect_block \
  "push: while loop with git push" \
  "$PUSH_HOOK" \
  "cat repos.txt | while read repo; do cd \$repo && git push; done" \
  "$FORK_REPO"

# Regression: prose in commit messages must not trigger loop detection
expect_allow \
  "push: 'for WORD in' in commit message is not a loop" \
  "$PUSH_HOOK" \
  "git commit -m \"Refactored for clarity in the test suite\" && git push" \
  "$OWN_REPO"

expect_allow \
  "push: 'while; do' in commit message is not a loop" \
  "$PUSH_HOOK" \
  "git commit -m \"poll while idle; do not restart services\" && git push" \
  "$OWN_REPO"

# Test: non-push command passthrough
expect_allow \
  "push: 'git status' passthrough" \
  "$PUSH_HOOK" \
  "git status" \
  "$FORK_REPO"

# Test: push in own (non-fork) repo
expect_allow \
  "push: bare push in own repo" \
  "$PUSH_HOOK" \
  "git push" \
  "$OWN_REPO"

echo ""

# ===================================================================
# guard-gh-write.sh
# ===================================================================

echo "--- guard-gh-write.sh ---"
echo ""

# --- Fork repo: all writes without -R should block ---

expect_block \
  "gh: 'gh pr create' in fork (no -R)" \
  "$GH_HOOK" \
  "gh pr create --title \"test\" --body \"test\"" \
  "$FORK_REPO"

expect_block \
  "gh: 'gh issue create' in fork (no -R)" \
  "$GH_HOOK" \
  "gh issue create --title \"test\"" \
  "$FORK_REPO"

expect_block \
  "gh: 'gh release create' in fork (no -R)" \
  "$GH_HOOK" \
  "gh release create v1.0.0" \
  "$FORK_REPO"

expect_block \
  "gh: 'gh pr close' in fork (no -R)" \
  "$GH_HOOK" \
  "gh pr close 42" \
  "$FORK_REPO"

expect_block \
  "gh: 'gh issue comment' in fork (no -R)" \
  "$GH_HOOK" \
  "gh issue comment 42 -b \"test\"" \
  "$FORK_REPO"

# --- Fork repo: -R to own fork should allow ---

expect_allow \
  "gh: 'gh pr create -R $FORK_REPO_NAME'" \
  "$GH_HOOK" \
  "gh pr create -R $FORK_REPO_NAME --title \"test\"" \
  "$FORK_REPO"

expect_allow \
  "gh: 'gh issue create -R $FORK_REPO_NAME'" \
  "$GH_HOOK" \
  "gh issue create -R $FORK_REPO_NAME --title \"test\"" \
  "$FORK_REPO"

# --- Fork repo: --repo long form ---

expect_allow \
  "gh: 'gh pr create --repo $FORK_REPO_NAME' (long form)" \
  "$GH_HOOK" \
  "gh pr create --repo $FORK_REPO_NAME --title \"test\"" \
  "$FORK_REPO"

# --- Fork repo: -R to upstream should block ---

expect_block \
  "gh: 'gh issue comment -R $UPSTREAM_REPO_NAME'" \
  "$GH_HOOK" \
  "gh issue comment 42 -R $UPSTREAM_REPO_NAME -b \"test\"" \
  "$FORK_REPO"

expect_block \
  "gh: 'gh pr create -R $UPSTREAM_REPO_NAME'" \
  "$GH_HOOK" \
  "gh pr create -R $UPSTREAM_REPO_NAME --title \"test\"" \
  "$FORK_REPO"

# --- gh api ---

expect_block \
  "gh: 'gh api' POST via -f to upstream" \
  "$GH_HOOK" \
  "gh api repos/$UPSTREAM_REPO_NAME/issues -f title=test" \
  "$OWN_REPO"

expect_block \
  "gh: 'gh api -X DELETE' to upstream" \
  "$GH_HOOK" \
  "gh api -X DELETE repos/$UPSTREAM_REPO_NAME/issues/42" \
  "$OWN_REPO"

expect_allow \
  "gh: 'gh api' GET to upstream (read-only)" \
  "$GH_HOOK" \
  "gh api repos/$UPSTREAM_REPO_NAME/pulls" \
  "$OWN_REPO"

expect_allow \
  "gh: 'gh api' POST to own repo" \
  "$GH_HOOK" \
  "gh api repos/$FORK_REPO_NAME/issues -f title=test" \
  "$OWN_REPO"

expect_block \
  "gh: 'gh api --method POST' to upstream (long form)" \
  "$GH_HOOK" \
  "gh api --method POST repos/$UPSTREAM_REPO_NAME/issues -f title=test" \
  "$OWN_REPO"

expect_allow \
  "gh: 'gh api --method GET' to upstream (explicit read)" \
  "$GH_HOOK" \
  "gh api --method GET repos/$UPSTREAM_REPO_NAME/pulls" \
  "$OWN_REPO"

# --- gh repo create (positional arg resolution) ---

expect_allow \
  "gh: 'gh repo create owner/repo' for own owner" \
  "$GH_HOOK" \
  "gh repo create $OWN_OWNER/new-repo --private" \
  "$OWN_REPO"

expect_allow \
  "gh: 'gh repo create' with --source and --push (full pattern)" \
  "$GH_HOOK" \
  "gh repo create $OWN_OWNER/llm-comic --private --description \"test\" --source /tmp/llm-comic --push" \
  "$OWN_REPO"

expect_block \
  "gh: 'gh repo create' for unowned org" \
  "$GH_HOOK" \
  "gh repo create $UPSTREAM_OWNER/new-repo --private" \
  "$OWN_REPO"

expect_allow \
  "gh: 'gh repo create bare-name' defaults to own owner" \
  "$GH_HOOK" \
  "gh repo create new-repo --private" \
  "$OWN_REPO"

expect_allow \
  "gh: 'gh repo create owner/repo' from fork CWD (bypasses fork detection)" \
  "$GH_HOOK" \
  "gh repo create $OWN_OWNER/new-repo --private" \
  "$FORK_REPO"

expect_block \
  "gh: 'gh repo create foreign/repo' from fork CWD" \
  "$GH_HOOK" \
  "gh repo create $UPSTREAM_OWNER/new-repo --private" \
  "$FORK_REPO"

# --- ALLOWED_REPOS override ---

_saved_repos="${GIT_GUARDRAILS_ALLOWED_REPOS:-}"
export GIT_GUARDRAILS_ALLOWED_REPOS="$UPSTREAM_REPO_NAME"

expect_allow \
  "gh: ALLOWED_REPOS override lets upstream write through" \
  "$GH_HOOK" \
  "gh issue create -R $UPSTREAM_REPO_NAME --title \"test\"" \
  "$OWN_REPO"

export GIT_GUARDRAILS_ALLOWED_REPOS="$_saved_repos"

# --- Non-fork own repo: writes should allow ---

expect_allow \
  "gh: 'gh issue create' in own (non-fork) repo" \
  "$GH_HOOK" \
  "gh issue create --title \"test\"" \
  "$OWN_REPO"

expect_allow \
  "gh: 'gh pr create' in own (non-fork) repo" \
  "$GH_HOOK" \
  "gh pr create --title \"test\"" \
  "$OWN_REPO"

expect_allow \
  "gh: 'gh release create' in own (non-fork) repo" \
  "$GH_HOOK" \
  "gh release create v1.0.0" \
  "$OWN_REPO"

expect_allow \
  "gh: 'gh label create' in own (non-fork) repo" \
  "$GH_HOOK" \
  "gh label create bug --color FF0000" \
  "$OWN_REPO"

# --- Read operations: always allow ---

expect_allow \
  "gh: 'gh pr view' (read-only)" \
  "$GH_HOOK" \
  "gh pr view 123" \
  "$FORK_REPO"

expect_allow \
  "gh: 'gh issue list' (read-only)" \
  "$GH_HOOK" \
  "gh issue list" \
  "$FORK_REPO"

expect_allow \
  "gh: 'gh pr list' (read-only)" \
  "$GH_HOOK" \
  "gh pr list" \
  "$FORK_REPO"

# --- Passthrough ---

expect_allow \
  "gh: non-gh command passthrough" \
  "$GH_HOOK" \
  "npm test" \
  "$OWN_REPO"

# --- Complexity gate ---

expect_block \
  "gh: for loop with gh commands" \
  "$GH_HOOK" \
  "for repo in a b; do cd /tmp/\$repo && gh issue create --title test; done" \
  "$FORK_REPO"

expect_block \
  "gh: while loop with gh commands" \
  "$GH_HOOK" \
  "cat repos.txt | while read repo; do gh issue create --title test -R \$repo; done" \
  "$OWN_REPO"

# Regression: prose in quoted args must not trigger loop detection
expect_allow \
  "gh: 'gh issue create' with 'for' in --title" \
  "$GH_HOOK" \
  "gh issue create --repo $OWN_OWNER/bosun --title \"feat: add endpoint for Homepage\"" \
  "$OWN_REPO"

expect_allow \
  "gh: 'gh issue create' with 'for' and 'while' in --body" \
  "$GH_HOOK" \
  "gh issue create --repo $OWN_OWNER/bosun --title \"test\" --body \"wait for results while polling\"" \
  "$OWN_REPO"

# Regression: 'for WORD in' pattern in --body (the exact false positive from the bug report)
expect_allow \
  "gh: 'gh pr create' with 'for clarity in' in --body" \
  "$GH_HOOK" \
  "gh pr create --title \"Fix tests\" --body \"Refactored the loop for clarity in the test suite\"" \
  "$OWN_REPO"

# Regression: 'while ...; do' pattern in --body
expect_allow \
  "gh: 'gh issue create' with 'while ...; do' in --body" \
  "$GH_HOOK" \
  "gh issue create --repo $OWN_OWNER/bosun --title \"test\" --body \"run the check while idle; do not restart\"" \
  "$OWN_REPO"

echo ""

# ===================================================================
# Summary
# ===================================================================

echo "=== Results: $passed/$total passed, $failed failed ==="

if [ "$failed" -gt 0 ]; then
  exit 1
fi
