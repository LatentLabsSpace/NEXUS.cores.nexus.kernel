#!/usr/bin/env bash
# session-start.sh — SessionStart hook: point git at the kernel's hook folder
# for this Claude Code session only, so every commit the session makes carries
# a `Claude-Session: <session id>` trailer (see git/prepare-commit-msg). The
# operator's own shell and other tools are untouched: the setting lives only in
# the session's environment, via CLAUDE_ENV_FILE, as git's GIT_CONFIG_* vars.
# Never blocks: anything missing exits 0.
set -uo pipefail

[[ -n "${CLAUDE_ENV_FILE:-}" ]] || exit 0
hooks_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/git" 2>/dev/null && pwd)" || exit 0
[[ -x "$hooks_dir/prepare-commit-msg" ]] || exit 0

# Append after any GIT_CONFIG_* entries the environment already carries.
n="${GIT_CONFIG_COUNT:-0}"
[[ "$n" =~ ^[0-9]+$ ]] || exit 0
{
  printf 'export GIT_CONFIG_KEY_%s=core.hooksPath\n' "$n"
  printf 'export GIT_CONFIG_VALUE_%s=%q\n' "$n" "$hooks_dir"
  printf 'export GIT_CONFIG_COUNT=%s\n' "$((n + 1))"
} >> "$CLAUDE_ENV_FILE"
exit 0
