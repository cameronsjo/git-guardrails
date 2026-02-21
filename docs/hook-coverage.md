# Hook Coverage Analysis

> Last reviewed: 2026-02-20
> Test suite: `tests/test-guards.sh` (154 tests)

## Design Philosophy

These hooks are **guardrails, not gates**. The bias is toward false positives (blocking
valid commands) over false negatives (allowing bad ones). Claude Code users can always
override a blocked command manually. The goal is to catch the obvious mistakes — pushing
to upstream, writing to repos you don't own — not to parse the full `gh` CLI grammar.

## guard-gh-write.sh

### Quick-exit Filter

The `\bgh\b` check is a cheap filter, not a precise one. It lets some non-gh commands
into deeper checks, but those checks handle it.

| Scenario | Likelihood | Impact | Status |
|----------|:----------:|:------:|:------:|
| No `gh` in command | Every non-gh call | None (exit 0) | Covered |
| `gh` in filenames (e.g. `guard-gh-write.sh`) | Medium | Low (only matters if deeper checks also false-positive) | Known, acceptable |
| `gh` in commit messages/body text | Low | Low (same) | Known, acceptable |

**Decision:** Leave as-is. Tightening to `\bgh\s+(pr\|issue\|repo\|...)` would be
more precise but brittle if gh adds subcommands.

### Loop Detection

Strips all quoted strings from the command before checking — loop keywords inside
`--body`, `--title`, commit messages, etc. are user data, not shell structure. Then
matches shell loop syntax on the remaining structure.

| Scenario | Likelihood | Impact | Status |
|----------|:----------:|:------:|:------:|
| `for x in ...; do gh ...; done` | Medium | Correctly blocked | Covered |
| `while read ...; do gh ...; done` | Low-Medium | Correctly blocked | Covered |
| Prose in `--title`/`--body`/`-m` (e.g. "for clarity in the suite") | High | None (stripped) | Fixed (2026-02-15) |
| Loop keywords in heredoc inside `$(...)` | Very low | Stripped if within outer quotes | Acceptable |
| `until ...; do` loops | Very low | Low | Not worth adding |

**Approach:** Strip `"..."` and `'...'` content, then match `\bfor\s+\w+\s+in\b`
and `\bwhile\b.*;\s*do\b` on the remaining shell structure.

### Write Detection

The `WRITE_ACTIONS` list covers: `create`, `merge`, `close`, `comment`, `edit`, `delete`,
`transfer`, `archive`, `rename`, `review`, `reopen`, `ready`, `lock`, `unlock`.

| Scenario | Likelihood | Impact | Status |
|----------|:----------:|:------:|:------:|
| Standard gh write commands (`pr create`, `issue close`, etc.) | High | Correctly detected | Covered |
| `gh api -X POST/PUT/PATCH/DELETE` | Medium | Correctly detected | Covered |
| `gh api` with `-f`/`-F` (implicit POST) | Medium | Correctly detected | Covered |
| `gh api` GET (read-only) | High | Correctly allowed | Covered |
| `gh pr view`, `gh issue list` (reads) | High | Correctly allowed | Covered |
| `gh api` with `--input` flag (file body) | Medium | Correctly detected | Fixed (2026-02-19) |
| `gh workflow run/enable/disable` | Low | Correctly detected | Fixed (2026-02-19) |
| `gh repo fork` | Low | Correctly detected | Fixed (2026-02-19) |
| `gh gist create/edit/delete` | Medium | Allowed through (user-scoped) | Fixed (2026-02-19) |
| Future gh subcommands not in list | Low | False negative (goes through) | Acceptable — gh CLI has its own auth |

**Decision:** Action list is comprehensive. No gaps worth closing.

### Repo Resolution

Priority chain: explicit `-R` flag > `gh repo create` positional arg > `gh api` path > git remotes.

| Scenario | Likelihood | Impact | Status |
|----------|:----------:|:------:|:------:|
| `-R owner/repo` or `--repo owner/repo` | High (fork workflow) | Correctly resolved | Covered |
| `gh repo create owner/repo` | High | Correctly resolved | Fixed (2026-02-15) |
| `gh repo create bare-name` (no slash) | Medium | Defaults to first allowed owner | Fixed (2026-02-15) |
| `gh repo create --flags-first name` | Very low | False positive (blocks) | Not worth the complexity |
| `gh api repos/owner/repo/...` | Medium | Correctly resolved | Covered |
| CWD is a fork (upstream remote) | High | Forces `-R` to disambiguate | Covered |
| CWD is own repo (origin only) | High | Resolved from origin | Covered |
| CWD has no git remotes | Low | False positive (blocks) | Acceptable — blocks with guidance |
| Non-GitHub origin URL (GitLab, Bitbucket, etc.) | Low | Allowed through (can't verify) | Fixed (2026-02-19) |
| Origin URL uses SSH vs HTTPS | Medium | `repo_from_url` handles both | Covered |

### Ownership Check

| Scenario | Likelihood | Impact | Status |
|----------|:----------:|:------:|:------:|
| Own user repos | High | Allowed | Covered |
| Allowed repos override (`ALLOWED_REPOS`) | Low | Allowed | Covered |
| Fork-parent repo (explicit `-R` from fork CWD) | High | Allowed | Covered |
| Unowned org repos | Medium | Blocked | Covered |
| Case mismatch in owner names | Very low (GitHub normalizes to lowercase) | False positive | Not worth fixing |
| Repo transferred to new owner | Very low | Stale remote (also needs `git remote` update) | Acceptable |

## guard-push-remote.sh

| Scenario | Likelihood | Impact | Status |
|----------|:----------:|:------:|:------:|
| Bare `git push` tracking upstream | High (fork default) | Correctly blocked | Covered |
| Bare `git push` tracking origin | High | Correctly allowed | Covered |
| Explicit `git push origin main` | High | Correctly allowed | Covered |
| Explicit `git push upstream main` | Medium | Correctly blocked | Covered |
| `git push -u origin main` | Medium | Correctly allowed | Covered |
| Multiple pushes in one command | Low | Blocked (complexity gate) | Covered |
| Loop with pushes | Low | Blocked (complexity gate) | Covered |
| Non-push git commands | Every other git call | Correctly allowed (exit 0) | Covered |
| `cd` mid-chain (`git add && cd /path && git push`) | Medium | Correctly resolved (last cd in chain) | Fixed (2026-02-19) |
| Non-GitHub remote URL (GitLab, etc.) | Low-Medium | Allowed through (can't verify) | Fixed (2026-02-19) |
| Push with `--force`, `--tags`, `--delete`, refspecs | Medium | Correctly handled | Covered |

## Accepted Gaps

These are known scenarios we intentionally do not cover:

1. **`gh` in filenames triggering quick-exit** — Benign due to defense-in-depth (write
   detection is the real gate).

2. **`gh repo create` with flags before positional arg** — Non-standard arg ordering.
   Very unlikely in practice. User overrides.

3. **No git remotes in CWD** — Unusual for Claude Code sessions. Blocks with guidance.

4. **`until` loops** — Claude almost never generates these. User overrides.

5. **Case-sensitive owner matching** — GitHub normalizes owners to lowercase. Not a
   real-world issue.

6. **`pushd`/`popd` not recognized as directory changes** — `cd` only.

7. **Variables in `cd` paths (`cd "$HOME/..."`) not expanded** — Static parsing only.

8. **`gh api` to non-repo endpoints (`user/repos`, `orgs/*/repos`)** — Write detected
   but repo resolves from CWD's origin. Allows through if origin is owned.

9. **`git push` in commit message + real push** — Multi-push count sees 2 matches,
   triggers complexity gate. Claude generates these as separate commands in practice.

10. **Invalid JSON input** — `jq` returns empty string, hooks exit 0. Claude Code
    always sends valid JSON from its protocol layer.

## warn-main-branch.sh

| Scenario | Likelihood | Impact | Status |
|----------|:----------:|:------:|:------:|
| On `main` or `master` branch | High | Correctly warns once per session | Covered |
| On feature branch | High | Silent (exit 0) | Covered |
| Detached HEAD | Medium | Silent (exit 0) | Covered |
| Not in git repo | Low | Silent (exit 0) | Covered |
| Stale marker from previous session | Medium | Prevented by PPID scoping | Fixed (2026-02-19) |
| Empty hash (no md5/md5sum) | Very low | cksum fallback | Fixed (2026-02-19) |

## check-idle-return.sh

| Scenario | Likelihood | Impact | Status |
|----------|:----------:|:------:|:------:|
| Gap < 5 minutes | High | No nudge | Covered |
| Gap 5min–8hr | Medium | Nudge fires | Covered |
| Gap > 8 hours (cross-session stale marker) | Medium | No nudge (treated as new session) | Fixed (2026-02-19) |
| Corrupted/empty marker file | Low | Gracefully ignored, marker reset | Fixed (2026-02-19) |
| First edit in session (no marker) | High | No nudge, marker created | Covered |
| Not in git repo | Low | Silent (exit 0) | Covered |
| Exactly 300s boundary | Low | Nudge fires (>= 300) | Fixed (2026-02-19) |
| Negative gap (future marker / clock skew) | Very low | No nudge (gap < 300) | Covered (2026-02-20) |
| Marker with surrounding whitespace | Low | Gracefully handled | Covered (2026-02-20) |
| Far-future timestamp (year 2100) | Very low | No crash, exceeds 8h cap | Covered (2026-02-20) |

## Input Resilience

| Scenario | Likelihood | Impact | Status |
|----------|:----------:|:------:|:------:|
| Empty input (no JSON) | Very low | Both hooks exit 0 | Fixed (2026-02-20) |
| Missing `command` field in JSON | Very low | Both hooks exit 0 | Covered (2026-02-20) |
| Invalid JSON (not parseable) | Very low | Both hooks exit 0 (jq `|| echo ""`) | Fixed (2026-02-20) |
| Multiple `ALLOWED_OWNERS` (space-separated) | High | All owners checked correctly | Covered (2026-02-20) |

## Additional WRITE_ACTIONS Coverage (2026-02-20)

| Action | Resource | Status |
|--------|----------|:------:|
| `enable` | `workflow` | Covered |
| `disable` | `workflow` | Covered |
| `delete` | `repo` | Covered |
| `transfer` | `repo` | Covered |
| `lock` | `pr` | Covered |
| `unlock` | `pr` | Covered |
| `reopen` | `issue` | Covered |
| `ready` | `pr` | Covered |
| `edit` | `pr`, `issue` | Covered |
| `delete` | `gist` | Covered (passthrough) |
