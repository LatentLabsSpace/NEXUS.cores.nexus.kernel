#!/usr/bin/env bash
# pr-ledger.sh — post or update the PR's single deferred-nits ledger comment.
#
# Usage:
#   bash pr-ledger.sh <pr> <body-file>
#
# The body file must start with the marker line
#   <!-- pr-review-loop:deferred-ledger -->
# Every entry (bullet line) must end with a status; see ledger_status.py.
# Only comments by the PR author count as ledgers (the loop posts as the
# author). Behaviour: update the existing ledger in place, or post one. Then re-list:
# if two loops raced and more than one ledger now exists, the oldest (lowest
# id) is kept and carries this body, and every newer ledger is deleted, so the
# PR always ends with exactly one. Prints the kept comment's URL.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="$SCRIPT_DIR/gh.sh"
MARKER='<!-- pr-review-loop:deferred-ledger -->'

[[ $# -eq 2 ]] || { echo "usage: pr-ledger.sh <pr> <body-file>" >&2; exit 2; }
PR_ARG="$1" BODY="$2"
[[ -s "$BODY" ]] || { echo "pr-ledger.sh: empty body file $BODY" >&2; exit 2; }
[[ "$(head -n1 "$BODY")" == "$MARKER" ]] || { echo "pr-ledger.sh: body must start with $MARKER" >&2; exit 2; }
# Every entry must state its status (ledger_status.py): fixed / done / decided /
# skip / verified / bead <id>, or follow-up for the harvester to file.
if ! python3 "$SCRIPT_DIR/ledger_status.py" check "$BODY"; then
  echo "pr-ledger.sh: every ledger entry needs a status: **fixed in <sha>**, **done**, **decided …**, **skip: <reason>**, **verified …**, **bead <id>** or **follow-up**" >&2
  exit 2
fi

pr_json="$(bash "$GH" pr view "$PR_ARG" --json number,url,author 2>/dev/null)" || { echo "pr-ledger.sh: cannot read PR $PR_ARG" >&2; exit 2; }
PR="$(jq -r .number <<<"$pr_json")"
REPO="$(jq -r '.url | split("/") | .[3] + "/" + .[4]' <<<"$pr_json")"
AUTHOR="$(jq -r .author.login <<<"$pr_json")"

ledger_ids() {
  bash "$GH" api --paginate "repos/$REPO/issues/$PR/comments?per_page=100" \
    --jq ".[] | select((.body | startswith(\"$MARKER\")) and .user.login == \"$AUTHOR\") | .id" 2>/dev/null | sort -n
}

ids="$(ledger_ids)"
if [[ -z "$ids" ]]; then
  bash "$GH" api -X POST "repos/$REPO/issues/$PR/comments" -F "body=@$BODY" --jq .id >/dev/null 2>&1 \
    || { echo "pr-ledger.sh: post failed" >&2; exit 2; }
  ids="$(ledger_ids)"
fi

keep="$(head -n1 <<<"$ids")"
[[ -n "$keep" ]] || { echo "pr-ledger.sh: ledger not found after posting" >&2; exit 2; }
bash "$GH" api -X PATCH "repos/$REPO/issues/comments/$keep" -F "body=@$BODY" --jq .id >/dev/null 2>&1 \
  || { echo "pr-ledger.sh: update of $keep failed" >&2; exit 2; }
for extra in $(tail -n +2 <<<"$ids"); do
  bash "$GH" api -X DELETE "repos/$REPO/issues/comments/$extra" >/dev/null 2>&1 \
    && echo "pr-ledger.sh: removed duplicate ledger $extra" >&2
done
echo "https://github.com/$REPO/pull/$PR#issuecomment-$keep"
