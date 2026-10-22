#!/usr/bin/env bash
# pr-opened.sh — PostToolUse(Bash) hook: when the session has just opened a
# pull request in a repo that pr-reviewer roles cover, tell it to start the
# author-side pr-review-loop now, so the human never has to relay reviews.
#
# Covered repos come from PR_REVIEW_ROLES_BY_REPO ("owner/repo=role,role;…"),
# the same variable pr-status.sh reads. Unset, or a repo not listed → no-op.
# Never blocks: any parse problem exits 0 silently.
set -uo pipefail

[[ -n "${PR_REVIEW_ROLES_BY_REPO:-}" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
# Claude Code reports a PR the command created as tool_response.gitOperation.pr.
url="$(jq -r 'if .tool_response.gitOperation.pr.action == "created"
               then .tool_response.gitOperation.pr.url // empty else empty end' <<<"$input" 2>/dev/null)" || exit 0
if [[ -z "$url" ]]; then
  # Fallback for harnesses without gitOperation: gh pr create, directly or via
  # the kernel's gh.sh wrapper, and the PR URL it printed.
  cmd="$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null)" || exit 0
  grep -Eq '(^|[[:space:];&|(/])(gh|gh\.sh)[[:space:]]+(.*[[:space:]])?pr[[:space:]]+create([[:space:];&|)]|$)' <<<"$cmd" || exit 0
  out="$(jq -r '[.tool_response.stdout // "", .tool_response.stderr // ""] | join("\n")' <<<"$input" 2>/dev/null)" || exit 0
  # A failed create ("a pull request for branch … already exists: <url>")
  # opened nothing. Otherwise gh pr create prints the new URL first; later
  # URLs come from whatever the command ran after it.
  grep -qi 'already exists' <<<"$out" && exit 0
  url="$(grep -Eo 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' <<<"$out" | head -1)"
fi
# Whatever the source, only a plain PR URL reaches the injected context.
[[ "$url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$ ]] || exit 0

repo="$(awk -F/ '{print $4 "/" $5}' <<<"$url")"
want="$(tr '[:upper:]' '[:lower:]' <<<"$repo")"
roles=""
entries=()
IFS=';' read -ra entries <<<"$PR_REVIEW_ROLES_BY_REPO"
for entry in "${entries[@]}"; do
  entry="$(tr -d '[:space:]' <<<"$entry")"
  [[ "$entry" == *=* ]] || continue
  [[ "$(tr '[:upper:]' '[:lower:]' <<<"${entry%%=*}")" == "$want" ]] && roles="${entry#*=}" && break
done
[[ -n "$roles" ]] || exit 0

msg="You just opened ${url}. Reviewer roles (${roles}) cover ${repo}, so start the author-side loop now: invoke the nexus-kernel pr-review-loop skill on this PR, unless you are already running it for this PR. Its wait step runs in the background (run_in_background) and wakes you when the review lands, so you can keep working or go idle meanwhile. Escalate to the user only for the cases the skill lists."
jq -n --arg m "$msg" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
exit 0
