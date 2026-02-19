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
  "unconfigured: gh hook blocks when ALLOWED_OWNERS unset" \
  "$GH_HOOK" \
  "gh issue create --title test" \
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

# Test: cd mid-chain before git push
expect_allow \
  "push: 'git add && cd DIR && git push' (mid-chain cd)" \
  "$PUSH_HOOK" \
  "git add . && cd $OWN_REPO && git push" \
  "/tmp"

# Test: push with --force flag
expect_allow \
  "push: 'git push --force origin main' to own remote" \
  "$PUSH_HOOK" \
  "git push --force origin main" \
  "$OWN_REPO"

# Test: push with --tags flag
expect_allow \
  "push: 'git push --tags' to own remote" \
  "$PUSH_HOOK" \
  "git push --tags" \
  "$OWN_REPO"

# Test: push with --delete flag
expect_allow \
  "push: 'git push --delete origin feature' to own remote" \
  "$PUSH_HOOK" \
  "git push --delete origin feature" \
  "$OWN_REPO"

# Test: push with --force-with-lease
expect_allow \
  "push: 'git push --force-with-lease origin main'" \
  "$PUSH_HOOK" \
  "git push --force-with-lease origin main" \
  "$OWN_REPO"

# Test: push with refspec
expect_allow \
  "push: 'git push origin HEAD:refs/heads/feature'" \
  "$PUSH_HOOK" \
  "git push origin HEAD:refs/heads/feature" \
  "$OWN_REPO"

# Test: push with delete refspec
expect_allow \
  "push: 'git push origin :refs/heads/feature' (delete refspec)" \
  "$PUSH_HOOK" \
  "git push origin :refs/heads/feature" \
  "$OWN_REPO"

# Test: push with --set-upstream
expect_allow \
  "push: 'git push --set-upstream origin feature'" \
  "$PUSH_HOOK" \
  "git push --set-upstream origin feature" \
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

expect_allow \
  "gh: 'gh issue comment -R $UPSTREAM_REPO_NAME' (fork-parent allowed)" \
  "$GH_HOOK" \
  "gh issue comment 42 -R $UPSTREAM_REPO_NAME -b \"test\"" \
  "$FORK_REPO"

expect_allow \
  "gh: 'gh pr create -R $UPSTREAM_REPO_NAME' (fork-parent allowed)" \
  "$GH_HOOK" \
  "gh pr create -R $UPSTREAM_REPO_NAME --title \"test\"" \
  "$FORK_REPO"

expect_block \
  "gh: unrelated unowned repo still blocked from fork" \
  "$GH_HOOK" \
  "gh pr create -R someoneelse/other-repo --title \"test\"" \
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

# --- Gist commands: should pass through (user-scoped, not repo-scoped) ---

expect_allow \
  "gh: 'gh gist create' passes through (user-scoped)" \
  "$GH_HOOK" \
  "gh gist create foo.txt" \
  "$OWN_REPO"

expect_allow \
  "gh: 'gh gist create' passes through from fork CWD" \
  "$GH_HOOK" \
  "gh gist create --public foo.txt" \
  "$FORK_REPO"

expect_allow \
  "gh: 'gh gist edit' passes through (user-scoped)" \
  "$GH_HOOK" \
  "gh gist edit abc123" \
  "$OWN_REPO"

# --- gh api --input (implicit POST detection) ---

expect_block \
  "gh: 'gh api --input' to upstream (implicit POST)" \
  "$GH_HOOK" \
  "gh api repos/$UPSTREAM_REPO_NAME/issues --input body.json" \
  "$OWN_REPO"

expect_allow \
  "gh: 'gh api --input' to own repo (implicit POST)" \
  "$GH_HOOK" \
  "gh api repos/$FORK_REPO_NAME/issues --input body.json" \
  "$OWN_REPO"

# --- gh workflow run/enable/disable ---

expect_block \
  "gh: 'gh workflow run' in fork (no -R)" \
  "$GH_HOOK" \
  "gh workflow run ci.yml" \
  "$FORK_REPO"

expect_allow \
  "gh: 'gh workflow run -R own-repo'" \
  "$GH_HOOK" \
  "gh workflow run ci.yml -R $FORK_REPO_NAME" \
  "$FORK_REPO"

# --- gh repo fork ---

expect_block \
  "gh: 'gh repo fork' in fork CWD (no -R)" \
  "$GH_HOOK" \
  "gh repo fork $UPSTREAM_REPO_NAME" \
  "$FORK_REPO"

# --- gh pr merge (in WRITE_ACTIONS but untested) ---

expect_block \
  "gh: 'gh pr merge' in fork (no -R)" \
  "$GH_HOOK" \
  "gh pr merge 42 --merge" \
  "$FORK_REPO"

expect_allow \
  "gh: 'gh pr merge -R own-fork'" \
  "$GH_HOOK" \
  "gh pr merge 42 --merge -R $FORK_REPO_NAME" \
  "$FORK_REPO"

# --- gh pr review (in WRITE_ACTIONS but untested) ---

expect_block \
  "gh: 'gh pr review' in fork (no -R)" \
  "$GH_HOOK" \
  "gh pr review 42 --approve" \
  "$FORK_REPO"

# --- gh repo archive/rename/delete (in WRITE_ACTIONS but untested) ---

expect_allow \
  "gh: 'gh repo archive' for own repo" \
  "$GH_HOOK" \
  "gh repo archive -R $FORK_REPO_NAME" \
  "$OWN_REPO"

expect_block \
  "gh: 'gh repo rename' for upstream (blocked)" \
  "$GH_HOOK" \
  "gh repo rename -R $UPSTREAM_REPO_NAME new-name" \
  "$OWN_REPO"

# --- cd mid-chain for gh hook ---

expect_allow \
  "gh: 'git add && cd DIR && gh issue create' (mid-chain cd)" \
  "$GH_HOOK" \
  "git add . && cd $OWN_REPO && gh issue create --title test" \
  "/tmp"

echo ""

# ===================================================================
# warn-main-branch.sh
# ===================================================================

echo "--- warn-main-branch.sh ---"
echo ""

WARN_HOOK="$HOOKS_DIR/warn-main-branch.sh"

# Create a temporary git repo for warn tests
warn_tmp=$(mktemp -d)
git -C "$warn_tmp" init -b main --quiet
git -C "$warn_tmp" commit --allow-empty -m "init" --quiet

# Compute the marker path using the same method as the hook:
# git rev-parse --show-toplevel (canonical path) + PPID of test shell
warn_repo_root=$(git -C "$warn_tmp" rev-parse --show-toplevel 2>/dev/null)
warn_hash=$(echo "$warn_repo_root" | (md5 -q 2>/dev/null || md5sum | cut -d' ' -f1))
[ -z "$warn_hash" ] && warn_hash=$(echo "$warn_repo_root" | cksum | cut -d' ' -f1)
warn_marker="/tmp/.claude-main-branch-warned-${warn_hash}-$$"
rm -f "$warn_marker"

# Test: warns on main branch
output=$(cd "$warn_tmp" && bash "$WARN_HOOK" 2>&1)
total=$((total + 1))
if echo "$output" | grep -q "editing files directly on"; then
  echo "  PASS  warn: emits warning on main branch"
  passed=$((passed + 1))
else
  echo "  FAIL  warn: emits warning on main branch"
  echo "        output: $output"
  failed=$((failed + 1))
fi

# Test: second call is suppressed (marker exists from previous call)
output=$(cd "$warn_tmp" && bash "$WARN_HOOK" 2>&1)
total=$((total + 1))
if [ -z "$output" ]; then
  echo "  PASS  warn: second call suppressed by marker"
  passed=$((passed + 1))
else
  echo "  FAIL  warn: second call suppressed by marker (got output)"
  echo "        output: $output"
  failed=$((failed + 1))
fi

# Test: warns again after marker removed
rm -f "$warn_marker"
output=$(cd "$warn_tmp" && bash "$WARN_HOOK" 2>&1)
total=$((total + 1))
if echo "$output" | grep -q "editing files directly on"; then
  echo "  PASS  warn: warns again after marker removed"
  passed=$((passed + 1))
else
  echo "  FAIL  warn: warns again after marker removed"
  echo "        output: $output"
  failed=$((failed + 1))
fi
rm -f "$warn_marker"

# Test: silent on feature branch
git -C "$warn_tmp" checkout -b feature/test --quiet
output=$(cd "$warn_tmp" && bash "$WARN_HOOK" 2>&1)
total=$((total + 1))
if [ -z "$output" ]; then
  echo "  PASS  warn: silent on feature branch"
  passed=$((passed + 1))
else
  echo "  FAIL  warn: silent on feature branch (got output)"
  echo "        output: $output"
  failed=$((failed + 1))
fi

# Test: warns on master branch
git -C "$warn_tmp" checkout -b master --quiet
rm -f "$warn_marker"
output=$(cd "$warn_tmp" && bash "$WARN_HOOK" 2>&1)
total=$((total + 1))
if echo "$output" | grep -q "editing files directly on"; then
  echo "  PASS  warn: warns on master branch"
  passed=$((passed + 1))
else
  echo "  FAIL  warn: warns on master branch"
  echo "        output: $output"
  failed=$((failed + 1))
fi
rm -f "$warn_marker"

# Test: silent in detached HEAD
git -C "$warn_tmp" checkout --detach --quiet
output=$(cd "$warn_tmp" && bash "$WARN_HOOK" 2>&1)
total=$((total + 1))
if [ -z "$output" ]; then
  echo "  PASS  warn: silent in detached HEAD"
  passed=$((passed + 1))
else
  echo "  FAIL  warn: silent in detached HEAD (got output)"
  echo "        output: $output"
  failed=$((failed + 1))
fi

# Test: silent outside git repo
output=$(cd /tmp && bash "$WARN_HOOK" 2>&1)
total=$((total + 1))
if [ -z "$output" ]; then
  echo "  PASS  warn: silent outside git repo"
  passed=$((passed + 1))
else
  echo "  FAIL  warn: silent outside git repo (got output)"
  echo "        output: $output"
  failed=$((failed + 1))
fi

# Test: always exits 0 (advisory, never blocks)
rm -f "$warn_marker"
git -C "$warn_tmp" checkout main --quiet
(cd "$warn_tmp" && bash "$WARN_HOOK") >/dev/null 2>&1
exit_code=$?
total=$((total + 1))
if [ "$exit_code" -eq 0 ]; then
  echo "  PASS  warn: always exits 0"
  passed=$((passed + 1))
else
  echo "  FAIL  warn: always exits 0 (got exit $exit_code)"
  failed=$((failed + 1))
fi

# Cleanup temp repo and markers
rm -rf "$warn_tmp"
rm -f "$warn_marker"

echo ""

# ===================================================================
# check-idle-return.sh
# ===================================================================

echo "--- check-idle-return.sh ---"
echo ""

IDLE_HOOK="$HOOKS_DIR/check-idle-return.sh"

# Derive the marker path the same way the hook does:
# git rev-parse --show-toplevel from OWN_REPO (no path discrepancy on non-tmpfs dirs)
idle_repo_root=$(git -C "$OWN_REPO" rev-parse --show-toplevel 2>/dev/null)
idle_hash=$(echo "$idle_repo_root" | (md5 -q 2>/dev/null || md5sum | cut -d' ' -f1))
[ -z "$idle_hash" ] && idle_hash=$(echo "$idle_repo_root" | cksum | cut -d' ' -f1)
idle_marker="/tmp/.claude-last-edit-${idle_hash}"

# Test: first edit — no nudge, no marker previously
rm -f "$idle_marker"
output=$(cd "$OWN_REPO" && bash "$IDLE_HOOK" 2>&1)
total=$((total + 1))
if [ -z "$output" ]; then
  echo "  PASS  idle: first edit in session — no nudge"
  passed=$((passed + 1))
else
  echo "  FAIL  idle: first edit in session — no nudge (got output)"
  echo "        output: $output"
  failed=$((failed + 1))
fi

# Test: recent edit (1 minute ago) — no nudge
echo $(($(date +%s) - 60)) > "$idle_marker"
output=$(cd "$OWN_REPO" && bash "$IDLE_HOOK" 2>&1)
total=$((total + 1))
if [ -z "$output" ]; then
  echo "  PASS  idle: recent edit (60s ago) — no nudge"
  passed=$((passed + 1))
else
  echo "  FAIL  idle: recent edit (60s ago) — no nudge (got output)"
  echo "        output: $output"
  failed=$((failed + 1))
fi

# Test: stale edit (400s ago) — nudge fires
echo $(($(date +%s) - 400)) > "$idle_marker"
output=$(cd "$OWN_REPO" && bash "$IDLE_HOOK" 2>&1)
total=$((total + 1))
if echo "$output" | grep -q "since your last edit"; then
  echo "  PASS  idle: stale edit (400s ago) — nudge fires"
  passed=$((passed + 1))
else
  echo "  FAIL  idle: stale edit (400s ago) — nudge fires"
  echo "        output: $output"
  failed=$((failed + 1))
fi

# Test: exactly 300s — nudge fires (>= 300)
echo $(($(date +%s) - 300)) > "$idle_marker"
output=$(cd "$OWN_REPO" && bash "$IDLE_HOOK" 2>&1)
total=$((total + 1))
if echo "$output" | grep -q "since your last edit"; then
  echo "  PASS  idle: exactly 300s — nudge fires (>= boundary)"
  passed=$((passed + 1))
else
  echo "  FAIL  idle: exactly 300s — nudge fires (>= boundary)"
  echo "        output: $output"
  failed=$((failed + 1))
fi

# Test: 299s — no nudge (below threshold)
echo $(($(date +%s) - 299)) > "$idle_marker"
output=$(cd "$OWN_REPO" && bash "$IDLE_HOOK" 2>&1)
total=$((total + 1))
if [ -z "$output" ]; then
  echo "  PASS  idle: 299s — no nudge (below threshold)"
  passed=$((passed + 1))
else
  echo "  FAIL  idle: 299s — no nudge (below threshold)"
  echo "        output: $output"
  failed=$((failed + 1))
fi

# Test: cross-session stale marker (24h ago) — no nudge (capped at 8h)
echo $(($(date +%s) - 86400)) > "$idle_marker"
output=$(cd "$OWN_REPO" && bash "$IDLE_HOOK" 2>&1)
total=$((total + 1))
if [ -z "$output" ]; then
  echo "  PASS  idle: cross-session marker (24h ago) — no nudge (8h cap)"
  passed=$((passed + 1))
else
  echo "  FAIL  idle: cross-session marker (24h ago) — no nudge (8h cap)"
  echo "        output: $output"
  failed=$((failed + 1))
fi

# Test: 28799s (just under 8h cap) — nudge fires
echo $(($(date +%s) - 28799)) > "$idle_marker"
output=$(cd "$OWN_REPO" && bash "$IDLE_HOOK" 2>&1)
total=$((total + 1))
if echo "$output" | grep -q "since your last edit"; then
  echo "  PASS  idle: 28799s (just under 8h cap) — nudge fires"
  passed=$((passed + 1))
else
  echo "  FAIL  idle: 28799s (just under 8h cap) — nudge fires"
  echo "        output: $output"
  failed=$((failed + 1))
fi

# Test: corrupted marker (non-numeric) — no crash, no nudge
echo "garbage" > "$idle_marker"
output=$(cd "$OWN_REPO" && bash "$IDLE_HOOK" 2>&1)
exit_code=$?
total=$((total + 1))
if [ "$exit_code" -eq 0 ] && [ -z "$output" ]; then
  echo "  PASS  idle: corrupted marker (non-numeric) — no crash"
  passed=$((passed + 1))
else
  echo "  FAIL  idle: corrupted marker (non-numeric) — got exit $exit_code"
  echo "        output: $output"
  failed=$((failed + 1))
fi

# Test: empty marker file — no crash, no nudge
> "$idle_marker"
output=$(cd "$OWN_REPO" && bash "$IDLE_HOOK" 2>&1)
exit_code=$?
total=$((total + 1))
if [ "$exit_code" -eq 0 ] && [ -z "$output" ]; then
  echo "  PASS  idle: empty marker file — no crash"
  passed=$((passed + 1))
else
  echo "  FAIL  idle: empty marker file — got exit $exit_code"
  echo "        output: $output"
  failed=$((failed + 1))
fi

# Test: marker updated after run
echo $(($(date +%s) - 60)) > "$idle_marker"
(cd "$OWN_REPO" && bash "$IDLE_HOOK") >/dev/null 2>&1
new_ts=$(cat "$idle_marker")
now=$(date +%s)
diff=$((now - new_ts))
total=$((total + 1))
if [ "$diff" -le 2 ]; then
  echo "  PASS  idle: marker updated with current timestamp after run"
  passed=$((passed + 1))
else
  echo "  FAIL  idle: marker not updated (diff=${diff}s)"
  failed=$((failed + 1))
fi

# Test: not in git repo — no output
rm -f "$idle_marker"
output=$(cd /tmp && bash "$IDLE_HOOK" 2>&1)
total=$((total + 1))
if [ -z "$output" ]; then
  echo "  PASS  idle: silent outside git repo"
  passed=$((passed + 1))
else
  echo "  FAIL  idle: silent outside git repo (got output)"
  echo "        output: $output"
  failed=$((failed + 1))
fi

# Test: always exits 0 (advisory, never blocks)
echo "garbage" > "$idle_marker"
(cd "$OWN_REPO" && bash "$IDLE_HOOK") >/dev/null 2>&1
exit_code=$?
total=$((total + 1))
if [ "$exit_code" -eq 0 ]; then
  echo "  PASS  idle: always exits 0 (even with corrupted marker)"
  passed=$((passed + 1))
else
  echo "  FAIL  idle: always exits 0 (got exit $exit_code)"
  failed=$((failed + 1))
fi

# Cleanup
rm -f "$idle_marker"

echo ""

# ===================================================================
# Summary
# ===================================================================

echo "=== Results: $passed/$total passed, $failed failed ==="

if [ "$failed" -gt 0 ]; then
  exit 1
fi
