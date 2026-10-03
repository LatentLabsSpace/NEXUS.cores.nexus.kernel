#!/usr/bin/env bash
# pr-status.sh — summarize everything the fix loop needs to decide its next
# move, as a single JSON object on stdout.
#
# It answers three questions the loop asks every iteration:
#   1. Are CI checks green, failing, or still running? (The reviewers'
#      "review/<role>" statuses are reported under `reviews`, not as CI.)
#   2. Are there unresolved inline review threads — and were they left by a
#      review bot (triage: fix blockers, defer nits) or a human (escalate,
#      never auto-resolve)?
#   3. Has every expected reviewer role reviewed the CURRENT head, and what did
#      they find? Read from the pr-reviewer skill's review comments via
#      `reviewer.py reviews` (contract: ../pr-reviewer/references/protocol.md).
#
# This script never requests a review. Reviewer agents sweep the open PRs on
# their own schedule and pick up any head their role hasn't reviewed; after a
# push the fixer just waits for them here.
#
# Usage:
#   bash pr-status.sh [<pr>] [--roles a,b] [--wait] [--timeout <sec>] [--poll <sec>]
#
#   <pr>        PR number or URL. If omitted, detected from the current branch.
#   --roles     Roles that must review this PR even if none has yet (merged with
#               $PR_REVIEW_REQUIRED_ROLES, the base branch's required
#               review/<role> checks, every role that has already reviewed the
#               PR, and every role holding a live claim).
#   --wait      Block until CI has settled AND every expected role has reviewed
#               the current head with no review in progress (or --timeout
#               elapses). The loop runs in this script (sleep + API re-fetch):
#               it costs GitHub API calls, not model turns.
#   --timeout   Max seconds to wait (default 3600 — reviewers run on a schedule,
#               so allow at least one sweep interval).
#   --poll      Seconds between polls (default 30).
#
# Environment:
#   REVIEW_BOT_RE   Anchored regex of logins whose INLINE threads count as bot
#                   findings rather than human ones
#                   (default: ^(github-actions|claude)(\[bot\])?$).
#
# Output JSON shape:
#   {
#     "number", "head_sha", "head_committed_at", "mergeable", "merge_state",
#     "truncated": {"review_threads", "checks", "any"},
#     "checks": {"rollup", "failing": [{name,result,url}], "pending": [{name,url}], "total"},
#     "bot_threads_unresolved":   [{id,author,path,line,body}],
#     "human_threads_unresolved": [{id,author,path,line,body}],
#     "reviews": <reviewer.py reviews: expected/missing/in_progress roles,
#                 per-role verdicts + commit statuses, aggregate_current,
#                 read (review URLs to work from), verdict>,
#     "review_verdict": "none|incomplete|blockers|unread|nits|clean",
#     "review_unread": true|false,   // a covering review's counts were unreadable
#     "wait_elapsed_sec", "wait_timed_out",
#     "ready": true|false  // CI green, no unresolved threads, every expected
#                          // role reviewed the head, review_verdict=clean.
#                          // A nits-only finish legitimately leaves this false;
#                          // that judgment lives in the skill.
#   }
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="$SCRIPT_DIR/gh.sh"
REVIEWER="$SCRIPT_DIR/../../pr-reviewer/scripts/reviewer.py"
REVIEW_BOT_RE="${REVIEW_BOT_RE:-^(github-actions|claude)(\\[bot\\])?\$}"
PREFIX="${PR_REVIEWER_STATUS_PREFIX:-review/}"

PR_ARG=""
ROLES=""
WAIT=0
TIMEOUT=3600
POLL=30

die() {
  echo "pr-status.sh: $*" >&2
  exit 2
}

int_arg() { # flag value min
  [[ "${2:-}" =~ ^[0-9]+$ ]] || die "$1 requires an integer argument, got '${2:-}'"
  (( $2 >= $3 )) || die "$1 must be >= $3"
  printf '%s' "$2"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait) WAIT=1; shift ;;
    --roles) [[ $# -ge 2 ]] || die "--roles requires a comma-separated list"; ROLES="$2"; shift 2 ;;
    --timeout) TIMEOUT="$(int_arg --timeout "${2:-}" 0)"; shift 2 ;;
    --poll) POLL="$(int_arg --poll "${2:-}" 1)"; shift 2 ;;
    -*) die "unknown flag $1" ;;
    *) PR_ARG="$1"; shift ;;
  esac
done
[[ -f "$REVIEWER" ]] || die "pr-reviewer skill not found beside this one ($REVIEWER)"

# Resolve the PR and the repo that HOSTS it in one call. gh pr view's .url is
# the canonical PR URL on the base repo even when the argument pointed at a
# fork, so owner/name come from it rather than from the local checkout.
if [[ -z "$PR_ARG" ]]; then
  pr_json="$(bash "$GH" pr view --json number,url)"
else
  pr_json="$(bash "$GH" pr view "$PR_ARG" --json number,url)"
fi
PR="$(jq -r '.number' <<<"$pr_json")"
pr_url="$(jq -r '.url' <<<"$pr_json")"
OWNER="$(awk -F/ '{print $4}' <<<"$pr_url")"
REPO="$(awk -F/ '{print $5}' <<<"$pr_url")"

read -r -d '' QUERY <<'GRAPHQL' || true
query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$pr){
      number
      headRefOid
      mergeable
      mergeStateStatus
      reviewThreads(first:100){
        pageInfo{ hasNextPage }
        nodes{
          id
          isResolved
          comments(first:1){ nodes{ author{login} path line body } }
        }
      }
      commits(last:1){ nodes{ commit{ committedDate statusCheckRollup{
        state
        contexts(first:100){ nodes{
          __typename
          ... on CheckRun{ name conclusion status detailsUrl }
          ... on StatusContext{ context state targetUrl }
        } pageInfo{ hasNextPage }}
      }}}}
    }
  }
}
GRAPHQL

fetch_graphql() {
  # gh exits non-zero when the response carries GraphQL "errors" entries (e.g.
  # FORBIDDEN on statusCheckRollup when the token lacks checks:read). The
  # secrets wrapper then appends "error: command failed (exit N)" directly onto
  # gh's single-line JSON; strip it so jq still gets the partial data.
  local out ec
  set +e
  out="$(bash "$GH" api graphql -f owner="$OWNER" -f repo="$REPO" -F pr="$PR" -f query="$QUERY" 2>/dev/null)"
  ec=$?
  set -e
  if [[ $ec -ne 0 ]]; then
    out="$(printf '%s' "$out" | sed 's/error: command failed (exit [0-9]*)//' | head -1)"
    echo "pr-status.sh: GraphQL had errors (exit $ec) — CI data may be partial; check token scope" >&2
  fi
  if [[ -n "$out" ]] && jq -e . >/dev/null 2>&1 <<<"$out"; then
    printf '%s' "$out"
  else
    echo "pr-status.sh: GraphQL fetch produced no usable output (exit $ec)" >&2
    printf '{"data":{"repository":{"pullRequest":null}},"errors":[{"message":"GraphQL fetch produced no output"}]}'
  fi
}

# Review state from the reviewers' comments. Any failure reads as "unread" —
# never as clean.
fetch_reviews() {
  local out args=(reviews "$OWNER/$REPO#$PR")
  [[ -n "$ROLES" ]] && args+=(--roles "$ROLES")
  if out="$(PR_REVIEWER_GH="bash $GH" python3 "$REVIEWER" "${args[@]}" 2>/dev/null)" \
     && jq -e 'type == "object" and has("verdict")' >/dev/null 2>&1 <<<"$out"; then
    printf '%s' "$out"
  else
    echo "pr-status.sh: reviewer.py reviews failed — treating review state as unread" >&2
    printf '{"verdict":"unread","all_reviewed":false,"expected":[],"missing":[],"in_progress":[],"read":[],"roles":{},"aggregate_current":false,"error":"reviewer.py reviews failed"}'
  fi
}

# CI is pending if any non-review check/status is unfinished. A truncated check
# list fails closed: unseen checks might still be running.
WARNED_TRUNCATED=false
ci_pending() {
  local r
  r="$(jq -c --arg p "$PREFIX" '
    (.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup // {}) as $rollup
    | {truncated: (($rollup.contexts.pageInfo.hasNextPage) // false),
       pending: any(($rollup.contexts.nodes // [])[];
         (.__typename == "CheckRun" and .status != "COMPLETED")
         or (.__typename == "StatusContext" and ((.context | startswith($p)) | not)
             and (.state == "PENDING" or .state == "EXPECTED")))}' <<<"$1" 2>/dev/null)" \
    || { echo "pr-status.sh: could not evaluate CI state; treating as pending" >&2; return 0; }
  if [[ "$(jq -r '.truncated' <<<"$r")" == "true" ]]; then
    if [[ "$WARNED_TRUNCATED" != true ]]; then
      echo "pr-status.sh: warning: check list truncated; --wait fails closed until --timeout" >&2
      WARNED_TRUNCATED=true
    fi
    return 0
  fi
  [[ "$(jq -r '.pending' <<<"$r")" == "true" ]]
}

# Reviews are still coming when an expected role hasn't covered the head or a
# role is mid-review. With no expected roles at all there is nothing to wait
# for — review_verdict "none" tells the skill nobody is reviewing.
reviews_pending() {
  jq -e '((.expected | length) > 0 and (.all_reviewed | not)) or ((.in_progress | length) > 0)' \
    >/dev/null 2>&1 <<<"$1"
}

raw="$(fetch_graphql)"
reviews="$(fetch_reviews)"
if jq -e '.errors | length > 0' <<<"$raw" >/dev/null 2>&1; then
  jq -r '.errors | map(.message) | unique | .[] | "pr-status.sh: GraphQL warning: " + .' <<<"$raw" >&2
fi

WAIT_ELAPSED=0
WAIT_TIMED_OUT=false
if [[ "$WAIT" -eq 1 ]]; then
  while { ci_pending "$raw" || reviews_pending "$reviews"; } && (( WAIT_ELAPSED < TIMEOUT )); do
    sleep "$POLL"
    WAIT_ELAPSED=$(( WAIT_ELAPSED + POLL ))
    raw="$(fetch_graphql)"
    reviews="$(fetch_reviews)"
  done
  if ci_pending "$raw" || reviews_pending "$reviews"; then
    WAIT_TIMED_OUT=true
  fi
fi

jq_filter="$(mktemp)"
trap 'rm -f "$jq_filter"' EXIT
cat > "$jq_filter" <<'JQ_FILTER'
  .data.repository.pullRequest as $pr
  | ($pr.commits.nodes[0].commit.statusCheckRollup // null) as $rollup
  | ($pr.reviewThreads.pageInfo.hasNextPage // false) as $threads_truncated
  | (($rollup.contexts.pageInfo.hasNextPage) // false) as $checks_truncated
  | ($threads_truncated or $checks_truncated) as $truncated
  | ([ ($rollup.contexts.nodes // [])[]
       | select(.__typename == "CheckRun" or ((.context | startswith($prefix)) | not)) ]) as $ctx
  | ($ctx | map(
      if .__typename == "CheckRun" then
        {name: .name, state: (.conclusion // .status), url: .detailsUrl,
         failing: ((.conclusion | IN("FAILURE","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE","CANCELLED")) // false),
         pending: (.status != "COMPLETED")}
      else
        {name: .context, state: .state, url: .targetUrl,
         failing: (.state | IN("ERROR","FAILURE")),
         pending: (.state | IN("PENDING","EXPECTED"))}
      end)) as $checks
  | ([ ($pr.reviewThreads.nodes // [])[]
       | select(.isResolved | not)
       | {id: .id,
          author: (.comments.nodes[0].author.login // "unknown"),
          path: .comments.nodes[0].path,
          line: .comments.nodes[0].line,
          body: .comments.nodes[0].body} ]) as $threads
  | ($threads | map(select(.author | test($bot_re; "i")))) as $bot
  | ($threads | map(select(.author | test($bot_re; "i") | not))) as $human
  | ($checks | map(select(.failing))) as $failing
  | ($checks | map(select(.pending and (.failing | not)))) as $pending
  | ($reviews.verdict // "unread") as $rv
  | {
      number: ($pr.number // null),
      head_sha: ($pr.headRefOid // null),
      head_committed_at: ($pr.commits.nodes[0].commit.committedDate // null),
      mergeable: ($pr.mergeable // null),
      merge_state: ($pr.mergeStateStatus // null),
      truncated: {review_threads: $threads_truncated, checks: $checks_truncated, any: $truncated},
      checks: {
        rollup: ($rollup.state // null),
        failing: ($failing | map({name, result: .state, url})),
        pending: ($pending | map({name, url})),
        total: ($checks | length)
      },
      bot_threads_unresolved: $bot,
      human_threads_unresolved: $human,
      reviews: $reviews,
      review_verdict: $rv,
      review_unread: ($rv == "unread"),
      wait_elapsed_sec: $wait_elapsed,
      wait_timed_out: $wait_timed_out,
      ready: (($truncated | not)
              and ($failing | length) == 0
              and ($pending | length) == 0
              and ($threads | length) == 0
              and ($reviews.all_reviewed // false)
              and (($reviews.in_progress // []) | length) == 0
              and $rv == "clean")
    }
JQ_FILTER

jq -f "$jq_filter" \
   --arg prefix "$PREFIX" \
   --arg bot_re "$REVIEW_BOT_RE" \
   --argjson reviews "$reviews" \
   --argjson wait_elapsed "$WAIT_ELAPSED" \
   --argjson wait_timed_out "$WAIT_TIMED_OUT" \
   <<<"$raw" \
   2>/dev/null || {
     echo "pr-status.sh: jq processing failed — outputting error snapshot" >&2
     jq -n --argjson pr "$PR" --argjson reviews "$reviews" \
       --argjson wait_elapsed "$WAIT_ELAPSED" --argjson wait_timed_out "$WAIT_TIMED_OUT" \
       '{number: $pr, error: "jq processing failed (likely GraphQL shape mismatch)",
         checks: {rollup: null, failing: [], pending: [], total: 0},
         bot_threads_unresolved: [], human_threads_unresolved: [],
         reviews: $reviews, review_verdict: "unread", review_unread: true,
         wait_elapsed_sec: $wait_elapsed, wait_timed_out: $wait_timed_out, ready: false}'
   }
