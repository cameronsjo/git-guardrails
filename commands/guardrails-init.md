---
name: guardrails-init
description: Configure git-guardrails with your GitHub identity. Self-destructs after setup so it reappears when the plugin updates.
---

Configure git-guardrails by detecting the user's GitHub identity and writing the required environment variables to `~/.claude/settings.json`.

## Steps

1. **Check current state** - Read `~/.claude/settings.json` and check if `GIT_GUARDRAILS_ALLOWED_OWNERS` already exists in the `env` block. If configured, show current values and ask if the user wants to reconfigure or exit.

2. **Detect GitHub identity** - Run `gh api user --jq .login` to get the authenticated GitHub username. If `gh` is not installed or not authenticated, ask the user to provide their GitHub username manually via AskUserQuestion.

3. **Ask for additional owners** - Use AskUserQuestion:
   - Pre-fill the detected username as the primary owner
   - Ask: "Any additional GitHub orgs or users to allow?" with options:
     - "Just my account (Recommended)" — use only the detected username
     - "Add orgs/users" — prompt for space-separated list to append
   - If the user chooses to add more, ask for the list as free text

4. **Ask for allowed repos** - Use AskUserQuestion:
   - "Any specific repos from other owners you need write access to?" with options:
     - "None (Recommended)" — leave `GIT_GUARDRAILS_ALLOWED_REPOS` empty
     - "Add repos" — prompt for space-separated `owner/repo` list
   - These are repos you don't own but have write access to (collaborator repos, org repos)

5. **Write to settings.json** - Read `~/.claude/settings.json`, add/update these keys in the `env` block:
   - `GIT_GUARDRAILS_ALLOWED_OWNERS` — space-separated list of GitHub users/orgs
   - `GIT_GUARDRAILS_ALLOWED_REPOS` — space-separated list of `owner/repo` pairs (only if the user provided any)
   - Preserve all existing env vars. Do not modify anything else in settings.json.

6. **Verify** - Read back the settings.json and confirm the values were written correctly. Show the user what was set.

7. **Self-destruct** - After successful configuration:
   - Find this plugin's cache directory: `~/.claude/plugins/cache/*/git-guardrails/commands/guardrails-init.md`
   - Delete ONLY this command file from the cached copy
   - Tell the user: "The /guardrails-init command has been removed from your local cache. It will reappear next time the git-guardrails plugin updates."

8. **Summary** - Show what was configured and remind the user:
   - Restart Claude Code for the env vars to take effect
   - The hooks will now guard `git push` and `gh` write operations against repos outside the allowed list
   - To reconfigure later: reinstall the plugin or manually edit `~/.claude/settings.json` env block

## Important

- The env vars go in `~/.claude/settings.json` under the `env` key, NOT as shell exports
- `GIT_GUARDRAILS_ALLOWED_OWNERS` is REQUIRED — hooks block all pushes/writes if unset
- `GIT_GUARDRAILS_ALLOWED_REPOS` is OPTIONAL — only needed for collaborator/org repos
- The self-destruct targets the CACHE copy, not the source repo
- If `gh` CLI is unavailable, fall back to manual input — don't fail
