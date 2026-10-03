#!/usr/bin/env bash
# pr-resolve.sh — resolve inline review threads left by a review bot after you
# have actually fixed them.
#
# Resolving a thread requires the GraphQL resolveReviewThread mutation — there
# is no REST equivalent. This script never requests reviews: pr-reviewer agents
# pick up the new head on their own sweep. (Their verdicts are PR comments, not
# threads; this script is for bots that leave inline threads.)
#
# Usage:
#   bash pr-resolve.sh <pr> <thread-id> [thread-id ...]   # resolve given threads
#   bash pr-resolve.sh <pr> --all                         # resolve ALL unresolved
#                                                         #   review-bot threads
#
# Pass explicit thread IDs (from pr-status.sh `bot_threads_unresolved[].id`).
# In the default blockers-only mode you resolve ONLY the blocker threads you
# fixed — nit threads stay unresolved and go in the deferred ledger. --all is
# for the rare round where you genuinely addressed every open bot thread.
#
# This script NEVER resolves human review threads. A thread counts as a bot's
# when its first comment's author matches REVIEW_BOT_RE (anchored; default
# ^(github-actions|claude)(\[bot\])?$).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="$SCRIPT_DIR/gh.sh"
# Login that authors the review workflow's inline comments (GraphQL
# author.login). Matched anchored, not as a substring, so a human reviewer
# whose username merely contains "claude" or "actions" is never mistaken for
# the bot (which would let us auto-resolve a human's thread — the one thing
# this script must never do).
REVIEW_BOT_RE="${REVIEW_BOT_RE:-^(github-actions|claude)(\\[bot\\])?\$}"

[[ $# -ge 2 ]] || { echo "usage: pr-resolve.sh <pr> <thread-id ...|--all>" >&2; exit 2; }
PR="$1"; shift

ALL=0
THREAD_IDS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) ALL=1; shift ;;
    -*) echo "pr-resolve.sh: unknown flag $1" >&2; exit 2 ;;
    *) THREAD_IDS+=("$1"); shift ;;
  esac
done

if [[ "$ALL" -eq 1 && ${#THREAD_IDS[@]} -gt 0 ]]; then
  echo "pr-resolve.sh: pass either --all or explicit thread ids, not both" >&2
  exit 2
fi

# Resolve the PR number AND the repo that HOSTS it in a single call. <pr> may be
# a number, URL, or branch. The returned .url is the canonical PR URL on the
# hosting (base) repo — https://github.com/<owner>/<repo>/pull/<n> — even when a
# PR URL points at a fork, so parsing owner/name from it (rather than
# `gh repo view`, which targets the local checkout) keeps the GraphQL $pr:Int!
# calls pointed at the right repository.
pr_json="$(bash "$GH" pr view "$PR" --json number,url)"
PR="$(jq -r '.number' <<<"$pr_json")"
pr_url="$(jq -r '.url' <<<"$pr_json")"
OWNER="$(awk -F/ '{print $4}' <<<"$pr_url")"
REPO="$(awk -F/ '{print $5}' <<<"$pr_url")"

validate_thread_is_review_bot() {
  local tid="$1"
  local author
  read -r -d '' VQ <<'GRAPHQL' || true
query($tid:ID!){
  node(id:$tid){
    __typename
    ... on PullRequestReviewThread {
      comments(first:1){ nodes{ author{login} } }
    }
  }
}
GRAPHQL
  author="$(bash "$GH" api graphql -f tid="$tid" -f query="$VQ" \
      -q '.data.node as $node
          | if ($node.__typename // "") != "PullRequestReviewThread" then
              ""
            else
              ($node.comments.nodes[0].author.login // "")
            end' || true)"
  [[ "$author" =~ $REVIEW_BOT_RE ]]
}

# With --all, discover every unresolved review-bot thread on the PR.
if [[ "$ALL" -eq 1 ]]; then
  read -r -d '' TQ <<'GRAPHQL' || true
query($owner:String!,$repo:String!,$pr:Int!){
  repository(owner:$owner,name:$repo){ pullRequest(number:$pr){
    reviewThreads(first:100){ pageInfo{ hasNextPage } nodes{ id isResolved
      comments(first:1){ nodes{ author{login} } } } } } }
}
GRAPHQL
  discovery_json="$(bash "$GH" api graphql -f owner="$OWNER" -f repo="$REPO" -F pr="$PR" -f query="$TQ")"
  if jq -e '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false' >/dev/null <<<"$discovery_json"; then
    echo "pr-resolve.sh: reviewThreads pagination exceeded first:100; refusing partial auto-resolution" >&2
    exit 2
  fi
  mapfile -t THREAD_IDS < <(
    jq -r --arg re "$REVIEW_BOT_RE" '.data.repository.pullRequest.reviewThreads.nodes[]
             | select(.isResolved|not)
             | select((.comments.nodes[0].author.login // "") | test($re;"i"))
             | .id' <<<"$discovery_json"
  )
fi

if [[ ${#THREAD_IDS[@]} -eq 0 ]]; then
  echo "resolve: no unresolved review-bot threads to resolve"
  exit 0
fi

for tid in "${THREAD_IDS[@]}"; do
  if ! validate_thread_is_review_bot "$tid"; then
    echo "resolve: refusing non-review-bot or unknown thread id $tid" >&2
    exit 2
  fi
  read -r -d '' MQ <<'GRAPHQL' || true
mutation($tid:ID!){ resolveReviewThread(input:{threadId:$tid}){ thread{ id isResolved } } }
GRAPHQL
  ok="$(bash "$GH" api graphql -f tid="$tid" -f query="$MQ" \
    -q '.data.resolveReviewThread.thread.isResolved' || echo "error")"
  echo "resolve $tid -> $ok"
done
