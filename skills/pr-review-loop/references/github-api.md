# GitHub API cheatsheet for the PR review loop

Hard-won specifics so you don't rediscover them mid-loop. All `gh` calls go
through `scripts/gh.sh` (token injected via the repo's /secrets skill when it
has one, never seen by the agent). `$S` below is this skill's `scripts/` dir.

## Where reviews come from

Reviews are posted by `pr-reviewer` agents, one per role, as **issue
comments** (not PR review objects, not inline threads). Each carries a hidden
marker and a verdict trailer:

```
<!-- review-verdict: blockers=N nits=M -->
<!-- pr-reviewer:review v=1 role=<role> head=<sha40> agent=<id> [inputs=<roles>] -->
```

and each role's verdict is mirrored as a **commit status** `review/<role>` on
the head it covers (`failure` = blockers, `success` = none, `pending` = in
progress). Don't parse these yourself — `reviewer.py reviews` does, and
`pr-status.sh` embeds its output:

```bash
python3 $S/../../pr-reviewer/scripts/reviewer.py reviews owner/repo#52
```

Identity is in the marker, not the comment author: reviewers and authors may
post from the same account, so never classify a comment by its login.

Read a review's body by its comment id (`reviews.roles.<role>.review_id`):

```bash
bash $S/gh.sh api "repos/{owner}/{repo}/issues/comments/<id>" --jq .body
```

Commit statuses on a head (the `review/*` ones are the reviewers'):

```bash
bash $S/gh.sh api "repos/{owner}/{repo}/commits/<sha>/status" \
  --jq '.statuses[] | {context, state, description}'
```

Which `review/<role>` checks the base branch requires (rulesets, then classic
protection — either can 404 for a token without admin read; that just means
"unknown"):

```bash
bash $S/gh.sh api "repos/{owner}/{repo}/rules/branches/<base>" \
  --jq '.[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context'
bash $S/gh.sh api "repos/{owner}/{repo}/branches/<base>/protection/required_status_checks" --jq .contexts
```

## Replying to a reviewer

A plain issue comment after a role's review puts that role in `reply` state;
it re-checks on its next sweep:

```bash
bash $S/gh.sh api -X POST "repos/{owner}/{repo}/issues/<pr>/comments" -f body="Re: <role> finding …"
```

The deferred-nits ledger carries `<!-- pr-review-loop:deferred-ledger -->`,
which reviewers read but don't treat as a reply. Update it in place:

```bash
bash $S/gh.sh api -X PATCH "repos/{owner}/{repo}/issues/comments/<id>" -f body="…"
```

## Inline review threads need GraphQL to resolve

Some bots (and humans) leave inline threads. There is no REST endpoint to
resolve a thread; use the mutation:

```graphql
mutation($tid:ID!){ resolveReviewThread(input:{threadId:$tid}){ thread{ isResolved } } }
```

Thread IDs look like `PRRT_kwDO...`; get them from `pr-status.sh`
(`bot_threads_unresolved[].id`). `pr-resolve.sh` only resolves threads whose
first comment author matches `REVIEW_BOT_RE` (anchored) — human threads are
never touched.

- Inline comments: `bash $S/gh.sh api "repos/{owner}/{repo}/pulls/<pr>/comments"`
- Reply in-thread: `bash $S/gh.sh api -X POST "repos/{owner}/{repo}/pulls/<pr>/comments/<comment_id>/replies" -f body="..."`

A review *comment* `id` (REST, integer) is different from a review *thread*
`id` (GraphQL, `PRRT_...`). Replies use the comment id; resolution uses the
thread id.

## CI check states

From `statusCheckRollup.contexts`, two node types:
- `CheckRun`: `status` ∈ {QUEUED, IN_PROGRESS, COMPLETED}; when COMPLETED,
  `conclusion` ∈ {SUCCESS, FAILURE, NEUTRAL, CANCELLED, TIMED_OUT,
  ACTION_REQUIRED, STARTUP_FAILURE, SKIPPED}.
- `StatusContext`: `state` ∈ {EXPECTED, PENDING, SUCCESS, ERROR, FAILURE}.

`pr-status.sh` drops `review/*` statuses from the CI view (they're reported
under `reviews`) and classifies FAILURE/TIMED_OUT/ACTION_REQUIRED/
STARTUP_FAILURE/CANCELLED (and ERROR/FAILURE for statuses) as **failing**;
anything not COMPLETED (or PENDING/EXPECTED) as **pending**.
`bash $S/gh.sh pr checks "<pr>"` is a quick human-readable view (note: it lists
the `review/*` statuses too); `bash $S/gh.sh run view "<run-id>" --log-failed`
pulls failing job logs.

A token without `checks:read` gets FORBIDDEN on `statusCheckRollup` nodes;
`pr-status.sh` warns and continues with partial data. Fall back to
`gh run list --branch <branch>` to see CI runs.

## Quick recipes

```bash
# One-shot status snapshot (JSON)
bash $S/pr-status.sh 52

# Require specific roles even before any has reviewed
bash $S/pr-status.sh 52 --roles general,security

# Block until CI settles and every expected role reviewed the head
bash $S/pr-status.sh 52 --wait --timeout 3600

# Resolve the specific bot threads you fixed
bash $S/pr-resolve.sh 52 PRRT_xxx PRRT_yyy
```
