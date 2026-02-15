# Hook Coverage Analysis

> Last reviewed: 2026-02-15
> Test suite: `tests/test-guards.sh` (44 tests)

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
| CWD has no git remotes | Low | False positive (blocks) | Acceptable |
| Origin URL uses SSH vs HTTPS | Medium | `repo_from_url` handles both | Covered |

### Ownership Check

| Scenario | Likelihood | Impact | Status |
|----------|:----------:|:------:|:------:|
| Own user repos | High | Allowed | Covered |
| Allowed repos override (`ALLOWED_REPOS`) | Low | Allowed | Covered |
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

## Accepted Gaps

These are known scenarios we intentionally do not cover:

1. **`gh` in filenames triggering quick-exit** — Only matters when combined with another
   false positive. Fixing requires enumerating all gh subcommands, which is more brittle
   than the current approach.

2. **`gh repo create` with flags before positional arg** — Non-standard arg ordering.
   Very unlikely in practice. User overrides.

3. **No git remotes in CWD** — Unusual for Claude Code sessions. User overrides.

4. **`until` loops** — Claude almost never generates these. User overrides.

5. **Case-sensitive owner matching** — GitHub normalizes owners to lowercase. Not a
   real-world issue.
