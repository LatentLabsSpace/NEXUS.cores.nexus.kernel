#!/usr/bin/env bash
# pr-owner.sh — make sure only one author session runs pr-review-loop on a PR.
#
# The owner is recorded as a hidden marker in the PR body:
#   <!-- pr-review-loop:owner session=<CLAUDE_CODE_SESSION_ID> -->
# Several sessions can push as the same GitHub account, so GitHub itself can't
# tell them apart; this marker can.
#
# Usage:
#   bash pr-owner.sh <pr> [--take-over]
#
# Exit codes and stdout (one line):
#   0  "claimed <session>"           marker was absent; this session now owns the PR
#   0  "owned <session>"             this session already owns it
#   0  "unenforced: …"               no CLAUDE_CODE_SESSION_ID (headless/fleet run);
#                                    ownership can't be checked, carry on
#   0  "took-over <old> -> <new>"    --take-over replaced another session's marker
#   3  "owned-by <other session>"    another session owns it: stop, tell the user
#   2  usage or GitHub error
#
# A claim is verified by re-reading the body a few seconds after writing it,
# and the loop re-runs this at the start of every round, so two sessions racing
# to claim converge on one owner by the next round's re-check at the latest
# (last write wins; the loser sees exit 3).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="$SCRIPT_DIR/gh.sh"
MARK_RE='<!-- pr-review-loop:owner session=([A-Za-z0-9._-]+) -->'

PR_ARG="" TAKE=0
for a in "$@"; do
  case "$a" in
    --take-over) TAKE=1 ;;
    -*) echo "pr-owner.sh: unknown flag $a" >&2; exit 2 ;;
    *) PR_ARG="$a" ;;
  esac
done
[[ -n "$PR_ARG" ]] || { echo "usage: pr-owner.sh <pr> [--take-over]" >&2; exit 2; }

ME="${CLAUDE_CODE_SESSION_ID:-}"
if [[ -z "$ME" ]]; then
  echo "unenforced: no CLAUDE_CODE_SESSION_ID in this environment"
  exit 0
fi
# Only ids the marker regex can match: anything else would append a new marker
# on every run and break the take-over substitution. Real ids are UUIDs.
if [[ ! "$ME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "unenforced: CLAUDE_CODE_SESSION_ID has an unexpected format"
  exit 0
fi

pr_json="$(bash "$GH" pr view "$PR_ARG" --json number,url 2>/dev/null)" || { echo "pr-owner.sh: cannot read PR $PR_ARG" >&2; exit 2; }
PR="$(jq -r .number <<<"$pr_json")"
REPO="$(jq -r '.url | split("/") | .[3] + "/" + .[4]' <<<"$pr_json")"

body_of() { bash "$GH" api "repos/$REPO/pulls/$PR" --jq '.body // ""' 2>/dev/null; }
owner_in() { [[ "$1" =~ $MARK_RE ]] && printf '%s' "${BASH_REMATCH[1]}"; }

set_body() { # new body → PATCH via REST (gh pr edit fails on some hosts)
  local f; f="$(mktemp)"; printf '%s' "$1" > "$f"
  bash "$GH" api -X PATCH "repos/$REPO/pulls/$PR" -F "body=@$f" --jq .number >/dev/null 2>&1
  local rc=$?; rm -f "$f"; return $rc
}

body="$(body_of)" || { echo "pr-owner.sh: cannot read PR body" >&2; exit 2; }
cur="$(owner_in "$body")"

if [[ "$cur" == "$ME" ]]; then
  echo "owned $ME"; exit 0
fi
if [[ -n "$cur" && "$TAKE" -eq 0 ]]; then
  echo "owned-by $cur"; exit 3
fi

marker="<!-- pr-review-loop:owner session=$ME -->"
if [[ -n "$cur" ]]; then
  new_body="$(sed -E "s/<!-- pr-review-loop:owner session=[A-Za-z0-9._-]+ -->/$marker/" <<<"$body")"
else
  new_body="$body"$'\n\n'"$marker"
fi
set_body "$new_body" || { echo "pr-owner.sh: could not write the PR body" >&2; exit 2; }

# Let a concurrent claim land before verifying (GitHub has no compare-and-swap
# on a PR body). The loop also re-runs this at the start of every round, so a
# session that lost a race finds out before it pushes.
sleep "${PR_OWNER_SETTLE_SEC:-5}"
after="$(owner_in "$(body_of)")"
if [[ "$after" != "$ME" ]]; then
  echo "owned-by ${after:-unknown}"; exit 3
fi
if [[ -n "$cur" ]]; then echo "took-over $cur -> $ME"; else echo "claimed $ME"; fi
exit 0
