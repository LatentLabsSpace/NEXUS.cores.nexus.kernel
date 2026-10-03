#!/usr/bin/env bash
# gh.sh — run any `gh` command without the GitHub token entering the agent's
# conversation context. Shared by the pr-reviewer and pr-review-loop skills.
#
# Identity = whatever token this resolves to. Reviewer profiles run under a
# reviewer bot account; the fixer runs under the PR author's identity. Confirm
# which one you are with:  bash gh.sh api user --jq .login
#
# Usage:
#   bash gh.sh pr view 52 --json number,state
#   bash gh.sh api repos/{owner}/{repo}/pulls/52/comments
#
# Token resolution (first match wins):
#   1. A /secrets skill in the CURRENT repo (<repo>/.claude/skills/secrets/
#      scripts/secrets.sh) injects GH_TOKEN into the gh subprocess only, from:
#        a. $GH_SECRETS_ENV_FILE            explicit env file (e.g. .env/<agent>.env)
#        b. .env/$AGENT_NAME.env            per-agent file, if AGENT_NAME is set
#        c. the secrets skill's default     (.env + process environment)
#   2. Otherwise plain `gh` — it uses GH_TOKEN/GITHUB_TOKEN from the
#      environment or its own stored login. Never echo the token yourself.
#
# The repo is located from the working directory, not from this script's path:
# when the skill ships inside a plugin, this file runs from a plugin cache
# directory that has no relationship to the repo being worked on.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
SECRETS=""
if [[ -n "$ROOT" && -f "$ROOT/.claude/skills/secrets/scripts/secrets.sh" ]]; then
  SECRETS="$ROOT/.claude/skills/secrets/scripts/secrets.sh"
fi

if [[ -z "$SECRETS" ]]; then
  exec gh "$@"
fi

env_file="${GH_SECRETS_ENV_FILE:-}"
if [[ -z "$env_file" && -n "${AGENT_NAME:-}" && -f "$ROOT/.env/${AGENT_NAME}.env" ]]; then
  env_file=".env/${AGENT_NAME}.env"
fi

cd "$ROOT"

run_secrets() {
  if [[ -n "$env_file" ]]; then
    SECRETS_ENV_FILE="$env_file" bash "$SECRETS" run --keys GH_TOKEN -- gh "$@"
  else
    bash "$SECRETS" run --keys GH_TOKEN -- gh "$@"
  fi
}

# secrets.sh appends "ok: command completed successfully" to stdout on success.
# When gh emits compact output with no trailing newline (e.g. `api graphql`),
# that marker is glued onto the last line, so a line-based filter misses it.
# Strip it from the very end of the output (with or without a separating
# newline) and preserve gh's real exit code.
rc=0
out="$(run_secrets "$@")" || rc=$?
marker='ok: command completed successfully'
out="${out%"$marker"}"
out="${out%$'\n'}"
if [[ -n "$out" ]]; then
  printf '%s\n' "$out"
fi
exit "$rc"
