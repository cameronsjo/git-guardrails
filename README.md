# git-guardrails

Safety guardrails for Claude Code's git and GitHub CLI operations. Blocks pushes and `gh`
write commands targeting repos you don't own, warns when editing directly on main/master,
and nudges toward committing after idle periods. The design philosophy is guardrails, not
gates — biased toward blocking suspicious operations rather than letting them through.
Claude can always run a command manually if a block is incorrect; it cannot undo a push to
upstream.

## Hooks

### `guard-push-remote.sh`

**Guards:** `git push` to remotes you don't own.

**Fires:** `PreToolUse` on `Bash`.

**How it works:**

- Resolves the actual push target URL before the command executes. For bare `git push`,
  follows branch tracking config to find the remote. For explicit `git push <remote>`,
  resolves that remote's push URL.
- Checks the resolved URL against `GIT_GUARDRAILS_ALLOWED_OWNERS` using both HTTPS and
  SSH GitHub URL patterns.
- Blocks batch commands containing multiple `git push` calls or loop constructs — these
  cannot be safely resolved statically.
- Partially resolves `cd DIR && git push` by extracting the leading `cd` target.

**Config read:**

- `GIT_GUARDRAILS_ALLOWED_OWNERS` — REQUIRED. If unset, all pushes are blocked.

---

### `guard-gh-write.sh`

**Guards:** `gh` CLI write operations to repos you don't own.

**Fires:** `PreToolUse` on `Bash`.

**How it works:**

- Detects write operations across three patterns:
  - `gh <resource> <write-action>` where write actions include `create`, `merge`, `close`,
    `comment`, `edit`, `delete`, `transfer`, `archive`, `rename`, `review`, `reopen`,
    `ready`, `lock`, `unlock`
  - `gh api` with explicit `-X POST|PUT|PATCH|DELETE`
  - `gh api` with field flags (`-f`, `-F`, `--field`, `--raw-field`) indicating an
    implicit POST
- Resolves the target repo in priority order: explicit `-R`/`--repo` flag > `gh repo
  create` positional arg > `gh api` path > git remotes.
- Fork-aware: when the CWD has an `upstream` remote, resolution is ambiguous (is the
  target the fork or the parent?). Requires `-R` to disambiguate.
- Allows operations targeting the fork's parent repo when `-R` is explicitly provided.
- Strips quoted strings before loop detection to avoid false positives from prose in
  `--title`, `--body`, and commit messages.

**Config read:**

- `GIT_GUARDRAILS_ALLOWED_OWNERS` — REQUIRED. If unset, all `gh` writes are blocked.
- `GIT_GUARDRAILS_ALLOWED_REPOS` — Optional. Space-separated `owner/repo` pairs for
  repos you collaborate on but don't own.

---

### `warn-main-branch.sh`

**Guards:** Accidental edits directly on main/master.

**Fires:** `PreToolUse` on `Edit` and `Write`.

**How it works:**

- Checks the current git branch. If it is `main` or `master`, emits a one-time advisory
  asking whether the work should be on a feature branch instead.
- Uses a per-repo marker file in `/tmp` to fire at most once per session.
- Advisory only — exits 0, never blocks.

**Config read:** None.

---

### `check-idle-return.sh`

**Guards:** Uncommitted work after periods of inactivity.

**Fires:** `PreToolUse` on `Edit` and `Write`.

**How it works:**

- Tracks the timestamp of the last edit via a per-repo marker file in `/tmp`.
- On each edit, computes the gap since the previous one. If the gap exceeds 5 minutes,
  emits a nudge to check for uncommitted changes and consider saving learnings to auto
  memory.
- Advisory only — exits 0, never blocks.

**Config read:** None.

---

## guard-push-remote vs guard-gh-write

The two blocking hooks guard different surfaces and use different resolution models.

| | `guard-push-remote` | `guard-gh-write` |
|---|---|---|
| **Surface guarded** | `git push` | `gh` CLI write operations |
| **Command detection** | `git push` substring | `\bgh\b` + write action pattern |
| **Target resolution** | git remote URL via `git remote get-url` | `-R` flag, `gh api` path, or git remotes |
| **Fork handling** | Blocks push to upstream remote URL | Requires `-R` when upstream remote exists |
| **Allowed repos override** | Not applicable (URL owner match only) | `GIT_GUARDRAILS_ALLOWED_REPOS` |
| **Non-GitHub URLs** | Allowed through (can't verify) | Allowed through (can't verify) |

## Setup

Run `/guardrails-init` in any Claude Code session after installing the plugin. This
command:

1. Detects your GitHub identity via `gh api user`.
2. Prompts for any additional allowed owners or orgs.
3. Prompts for any collaborator repos that require explicit overrides.
4. Writes the env vars to `~/.claude/settings.json` under the `env` key.
5. Self-destructs from the plugin cache — it reappears on the next plugin update.

After running `/guardrails-init`, **restart Claude Code** for the env vars to take effect.

## Configuration

Both `guard-push-remote.sh` and `guard-gh-write.sh` read the following env vars from
`~/.claude/settings.json`:

```json
{
  "env": {
    "GIT_GUARDRAILS_ALLOWED_OWNERS": "myuser myorg",
    "GIT_GUARDRAILS_ALLOWED_REPOS": "someorg/shared-repo anotherorg/collab-repo"
  }
}
```

| Variable | Required | Format | Description |
|---|---|---|---|
| `GIT_GUARDRAILS_ALLOWED_OWNERS` | REQUIRED | Space-separated GitHub users/orgs | Pushes and writes to repos under these owners are allowed. If unset, all operations are blocked. |
| `GIT_GUARDRAILS_ALLOWED_REPOS` | Optional | Space-separated `owner/repo` pairs | Specific repos from non-owned orgs you have write access to (collaborator repos, org repos). Checked before owner-level matching. |

## Known Limitations

- **GitHub-only URL validation.** Only `github.com` URLs are ownership-checked. Non-GitHub
  remotes (GitLab, Bitbucket, self-hosted) pass through unvalidated — the hook cannot
  verify ownership on other hosts.
- **`cd` mid-chain partially resolved.** The hooks extract the last `cd` target from the
  command chain. Complex patterns (variables in paths, `pushd`/`popd`, nested subshells)
  are not resolved.
- **`gh gist` commands are unguarded.** Gists are user-scoped, not repo-scoped. The hook
  allows all `gh gist` operations through without ownership checks.
- **`gh workflow run/enable/disable` not detected as writes.** These subcommands are not
  in the write action list and pass through unguarded.
- **`gh repo create` with flags before positional arg** (e.g. `gh repo create --private
  my-repo`) is not resolved; the hook blocks as a false positive.
- **Non-GitHub `gh api` targets** (e.g. GitHub Enterprise with a custom hostname) are not
  resolved from the `repos/` path pattern.

See [`docs/hook-coverage.md`](docs/hook-coverage.md) for the full coverage analysis,
including accepted gaps and the rationale for each.

## Running Tests

```bash
./tests/test-guards.sh
```

The test suite requires:

- A fork repo with an `upstream` remote pointing to a repo you don't own.
- An owned repo with only an `origin` remote.

The suite covers 44 scenarios across both guard hooks.
