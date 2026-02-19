#!/usr/bin/env bash
# guard-git-init.sh — Remind to scaffold new projects after git init
#
# PostToolUse hook for Bash. Detects git init commands and nudges
# Claude to run /a-star-is-born for full project scaffolding.

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Quick exit: no git init, no nudge
echo "$COMMAND" | grep -qE '\bgit\s+init\b' || exit 0

echo "New repo detected. Run /a-star-is-born to scaffold project standards (.gitignore, README, CONTRIBUTING, CHANGELOG, LICENSE, Makefile, linting, CI/CD)."
exit 0
