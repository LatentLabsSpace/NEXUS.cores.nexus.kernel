---
name: pr-review-loop
description: 'Drive an open pull request to green automatically from the author''s
  side: detect failing CI checks and the findings of the pr-reviewer roles that
  review it (general, security, ops, spec, and the aggregate that merges them),
  fix the blockers locally, commit and push, then wait for every expected role to
  re-review the new head — repeating until CI is green and the reviews raise no
  blockers, or something needs a human. Small, clear nits are fixed in rounds that
  push anyway; a round with only nits never pushes, and whatever is left goes into
  a ledger on the PR instead of being churned through the loop. Use
  this whenever the user asks to "resolve PR comments", "fix the review", "address
  review feedback", "get this PR green", "make CI pass", "handle the review on PR
  #N", "babysit my PR", or points you at a pull request that has review findings or
  red checks — even if they don''t say the word "loop". Trigger it for any request
  that amounts to iterating on an open PR until reviewers and CI are satisfied. For
  reviewing PRs (the other side), use pr-reviewer.

  '
tags:
- github
- pull-request
- ci
- code-review
- automation
triggers:
- /pr-review-loop
- /resolve-pr
---

# PR Review Loop

You are the **author's side** of a pull request. Each round you read the PR's
state, fix what's blocking, push, and wait for the reviewers to look at the new
head — stopping when the PR is genuinely done or when something needs human
judgment.

**The reviewers are not yours to run.** Reviews come from agents running the
`pr-reviewer` skill (shipped beside this one), usually on a schedule and under
their own bot identity, one agent per **role**:

- each role posts a review comment carrying a hidden marker with its role and
  the head SHA it covers, ending in `<!-- review-verdict: blockers=N nits=M -->`;
- each role's verdict is also a commit status `review/<role>` on that head
  (`failure` = blockers, `success` = none, `pending` = in progress). Branch
  rules may require some of them to merge;
- the optional `aggregate` role merges the roles' reviews of one head into a
  single consolidated review — your work list when it's current.

A push leaves the new head unreviewed; the reviewers' next sweep picks it up on
its own. **You never request a review** — you wait for one. The protocol is in
`../pr-reviewer/references/protocol.md`.

**How the loop starts.** Where reviewer roles cover a repo, the deployment says
so in `PR_REVIEW_ROLES_BY_REPO` (`owner/repo=role,role;…`, typically in the
project's `.claude/settings.json` `env`). The kernel plugin's `PostToolUse` hook
watches for `gh pr create` in a covered repo and tells the session to start this
loop on the new PR, so the author session — which knows why it made each change —
handles its own reviews without the human relaying them. If you're told to start
and you're already running the loop for that PR, don't start a second one.

The bundled scripts handle the GitHub plumbing so you can focus on the part
that needs intelligence: **understanding each finding and writing a correct
fix.** Don't paper over problems to make the loop terminate — a green PR full
of band-aids is worse than an honest escalation.

Scripts live in this skill's directory:

```bash
S=${CLAUDE_SKILL_DIR}/scripts
```

## Blockers vs nits — the default triage policy

What costs a round is a **push**: every new head sends every role back to
re-review it, which means a full reviewer pass and up to one sweep interval of
waiting. So the policy turns on whether this round pushes anyway, not on
whether a finding is small:

- **A round that pushes anyway** (it has blockers, or CI is red): fix the
  blockers, **and** every nit that is small, clearly right and inside this
  PR's scope, in the same push. The re-review is already paid for.
- **A round with only nits left:** don't push just for them. That would buy a
  whole extra review cycle for cosmetics. Ledger them and finish.
- **Never fix along:** a nit that is a judgment call, grows the PR's scope, or
  is a refactor that could introduce new findings. Ledger it with the reason.

The reviewers already sort findings: anything under a review's
"Medium (blocker)" section counts toward `blockers` in its trailer, everything
under "Low / nits" toward `nits`. Take their classification as the starting
point, then **read every nit and re-classify it yourself**:

- **Blocker** — fix it this round: correctness bugs, broken or missing error
  handling, security issues, data loss/corruption risks, race conditions,
  breaking API/contract changes, anything that makes CI fail. A "nit" that
  describes one of these is a blocker, whatever the reviewer called it — on
  NEXUS#156 a nit about expected roles was a real early-"ready" bug.
- **Nit** — style and naming, comment/docstring wording, optional refactors,
  micro-optimizations, test-coverage suggestions for working code.

When a finding is genuinely ambiguous, treat it as a blocker — over-deferring
real bugs is the worse failure mode.

**The ledger** is the record of every finding you didn't simply fix in the
code: one PR comment (format under Termination), one entry per finding (role,
path:line, one-line summary, review URL), each ending with its **status**.
Nits you fixed along stay in it, marked **fixed in `<sha>`**, so the merger
and the next re-review can see they were handled. Nothing deferred may live
only in the ledger: a ledger is a comment, and nobody reads it after the merge.
So every deferred finding becomes a work item (a bead) or an explicit
decision.
**Dedupe across rounds and roles**: each re-review may restate an unfixed
nit, and two roles may flag the same line. Record it once.

If the user asks for everything to be fixed ("fix the nits too", "address all
comments"), promote nits to blockers and skip the ledger.

## Authentication and identity (do this first, once)

Every `gh` call goes through `$S/gh.sh`, which injects `GH_TOKEN` via the
current repo's /secrets skill when there is one (else plain `gh`), so the token
never enters your context. **Never read a `.env` file directly and never print
a token.**

`gh.sh` finds the token automatically if `AGENT_NAME` is set (`.env/$AGENT_NAME.env`)
or if `GH_TOKEN` is already in the environment. Otherwise point it at the right
file once per session:

```bash
export GH_SECRETS_ENV_FILE=.env/<agent>.env
bash $S/gh.sh api user --jq .login     # who you are
bash $S/gh.sh pr view "<pr>" --json number,state
```

You act as the **PR author**. Reviewers run under a separate bot identity; if
`gh.sh api user` shows the reviewer bot, you are using the wrong token.

Commits you author must carry the human's name, not whatever happens to be in
the repo-local `.git/config`. Check once:

```bash
git config user.name && git config user.email
git log --format='%an <%ae>' -20 | sort | uniq -c | sort -rn   # the identity this repo's history uses
```

If the configured author doesn't match the PR owner, set it before committing.
Getting this wrong means a force-push to fix authorship later.

## The loop

Track the steps with a todo list so a long loop stays legible, and keep the
deferred-nits ledger updated every round.

### 0. Claim the PR (once, before anything else)

```bash
bash $S/pr-owner.sh "<pr>"
```

Several sessions can push as the same GitHub account, so one PR can look like
"yours" to two of them, for example after "run the loop on any PRs you have".
Two loops on one PR post duplicate ledgers and push competing fixes. The script
records this session (`CLAUDE_CODE_SESSION_ID`) in a hidden marker in the PR
body:

- `claimed` / `owned` → carry on.
- `unenforced` → no session id here (headless or fleet run). Carry on.
- **exit 3, `owned-by <session>`** → another session owns this PR. **Stop.**
  Tell the user which session owns it, and don't touch the PR. Only when the
  user explicitly says to take it over, run it again with `--take-over`.

Run it again at the start of **every** round, before you push. It's one API
call, and it's how a session that lost a simultaneous claim (or was taken over
by the user's word) finds out before it pushes a competing fix.

### 1. Assess

```bash
bash $S/pr-status.sh "<pr>"            # add --roles general,security to require roles explicitly
```

One JSON object: `checks.failing` / `checks.pending` (CI only — the
`review/<role>` statuses are reported under `reviews`), unresolved inline
threads split into `bot_threads_unresolved` / `human_threads_unresolved`,
`reviews`, `review_verdict`, `review_unread`, `mergeable`, and `ready`.

`reviews` (from `reviewer.py reviews`) is the part to read closely:

| field | meaning |
|---|---|
| `expected` | roles that must review this head: `--roles`, this repo's `$PR_REVIEW_ROLES_BY_REPO` entry, `$PR_REVIEW_REQUIRED_ROLES`, the base branch's required `review/<role>` checks, every role that has reviewed this PR before, and every role mid-review |
| `missing` | expected roles with no review covering the current head |
| `in_progress` | roles holding a live claim — a verdict is coming |
| `roles.<role>` | per role: `verdict` (blockers/nits/clean/unread), `counts`, `url`, `review_id`, `covers_head`, `commit_status`, `status_mismatch` |
| `aggregate_current` | an aggregate review covers the head and is newer than its inputs |
| `read` | the review(s) to work from this round: the aggregate when current, else each role review with findings |
| `stale_read` | reviews of an **earlier** head that had findings — known work you can start on while the roles re-review (e.g. after merging the base branch) |
| `legacy_read` | reviews posted without a pr-reviewer marker (hand-written, or the retired CI reviewer) that had findings — they make no role expected, so read them yourself |
| `verdict` | `none` · `incomplete` · `blockers` · `unread` · `nits` · `clean` (worst across expected roles) |

How to act on `review_verdict`:

- `blockers` → fix this round (step 2). Read every review in `reviews.read`:
  ```bash
  bash $S/gh.sh api "repos/{owner}/{repo}/issues/comments/<review_id>" --jq .body
  ```
  With a current aggregate, work from it — but note its **Disputed** section:
  a role's blocker the aggregate thinks is wrong still holds that role's
  `review/<role>` check red. Either fix it, or reply to that role (step 2).
- `nits` → read the reviews and re-classify each nit (a disguised blocker
  goes to step 2). If none is a blocker, this is a nits-only round: ledger
  them and don't push. If CI is green and no human threads remain, that's a
  default-mode finish (see Termination).
- `clean` → every expected role reviewed this head with no findings.
- `incomplete` → a role hasn't reviewed this head yet. Don't declare anything
  about this head's findings; wait (step 5). If `reviews.stale_read` lists
  reviews of an earlier head with findings, you may start fixing those while
  you wait — the re-review will say which still apply.
- `unread` → a covering review's verdict counts couldn't be read (or the review
  state couldn't be fetched). **Never treat it as clean.** Open the review(s)
  yourself and classify them.
- `none` → **no reviewer is expected on this PR at all.** That is not green —
  nobody has looked. If `reviews.legacy_read` lists reviews, someone *did* look
  without the marker: read and work those findings, and name them in the
  escalation. Escalate (ask which roles should review, or whether the
  user waives review), unless the user already told you the PR needs no review.
  **Except on a draft** (`draft: true`): reviewers skip drafts, so `none` is
  expected there. Don't wait and don't escalate. Finish with "draft, not
  reviewed: mark it ready for review when you want the reviewers", and never
  mark it ready yourself unless the user asks.

Also:

- `human_threads_unresolved` non-empty → a person left an inline comment.
  **Do not auto-resolve it.** Surface it and escalate, unless the user already
  told you how to handle human feedback. (The bucket is "any author not
  matching `REVIEW_BOT_RE`", so automated bots like CodeQL can land here too —
  those are findings to address, not human escalations.)
- `bot_threads_unresolved` → inline threads from a review bot; triage them like
  review findings.
- Failing checks → `bash $S/gh.sh pr checks "<pr>"` for the summary, then
  `bash $S/gh.sh run view "<run-id>" --log-failed` for the failure. If logs are
  unreachable, reproduce locally with the CI's pinned tool versions.
- `status_mismatch: true` on a role → its review comment and its check
  disagree (the reviewer couldn't set the status). The comment is
  authoritative; mention it in your report so the reviewer's token can be fixed.

### 2. Fix blockers locally

Make sure you're on the PR's branch (`bash $S/gh.sh pr checkout "<pr>"`) with a
clean tree. For each **blocker**, write a real fix:

- **Review finding** → change the code so the concern no longer applies.
- **A finding you believe is wrong** → don't silently skip it. Reply on the PR
  with a plain comment addressed to the role — start it with `Re: <role>` or
  link that role's review, so only that reviewer is woken — with the evidence:
  ```bash
  bash $S/gh.sh api -X POST "repos/{owner}/{repo}/issues/<pr>/comments" \
    -f body="Re: security review finding 2 (path:line) — not changing this because …"
  ```
  The reviewer sees a reply after its review and re-checks on its next sweep;
  it withdraws the finding or restates it. If it restates it, that's an
  escalation, not a second argument.
- **Failing test** → fix the code or the test, whichever is actually wrong.
- **Lint/format/type check** → apply the fix the tool wants.

Since this round pushes, fix along every nit that is small, clearly right and
in scope, in the same commit, and mark it **fixed in `<sha>`** in the ledger.
Ledger the rest with the reason (judgment call, scope, risky refactor).

Validate before pushing — run the relevant test/lint/build locally so you don't
burn a CI round on a typo. Keep each fix minimal and on-point; don't refactor
unrelated code or add scope the review didn't ask for.

### 3. Commit & push

```bash
git add "<files>" && git commit -m "fix(<scope>): address review — <summary>"
git push; echo "push rc=$?"
```

Use a normal push of new commits (cleaner review history than amend+force).
Only force-push to repair your own just-made mistake, and only with
`--force-with-lease`. Never `--no-verify`, never force-push shared/protected
branches.

**Never pipe a push (or commit) through an early-closing filter** (`| head`,
`| grep`, `| tail`). A closed pipe SIGPIPE-kills the push after its local
preview prints but before the bytes reach the remote — output that looks like
success while nothing landed. Run pushes unfiltered and check the exit code.

**Then verify the remote actually moved:**

```bash
LOCAL=$(git rev-parse @)                          # or: jj log -r @ -T commit_id --no-graph
REMOTE=$(bash $S/gh.sh api "repos/{owner}/{repo}/commits/<branch>" --jq '.sha')
[ "$LOCAL" = "$REMOTE" ] && echo "push verified" || echo "MISMATCH — push did NOT land"
```

If they differ, re-push unfiltered and re-verify before continuing. Waiting on
reviewers for a head the remote never received just stalls the loop.

If nothing needed fixing this round (no blockers, only nits) and CI is green,
skip the push and go straight to termination.

### 4. Resolve fixed inline threads

If a review bot left inline threads you fixed, resolve exactly those:

```bash
bash $S/pr-resolve.sh "<pr>" PRRT_xxx PRRT_yyy
```

`pr-resolve.sh` never touches human threads. Role reviews are PR comments, not
threads — there is nothing to resolve for them; the role's next review of the
new head records what was fixed under "Prior findings".

### 5. Wait for the re-review, then repeat

Start the wait as a **background** command (the Bash tool's
`run_in_background: true`), never in the foreground:

```bash
bash $S/pr-status.sh "<pr>" --wait          # timeout $PR_REVIEW_WAIT_TIMEOUT, else 3h; poll 30s
```

It blocks until CI has settled **and** every expected role has reviewed the
current head with none mid-review — then prints the settled status. The poll
loop lives inside the script (sleep + API re-fetch), so waiting costs GitHub
API calls, not model turns. Run in the background, the harness re-invokes you
when it exits: end your turn, keep working on something else, or go idle — the
review wakes you. (A foreground call hits the tool's 10-minute cap and is moved
to the background anyway, without you having planned for it.) Reviewers run on
a schedule, so the default timeout covers one sweep interval plus a review's own
run time; don't shorten it. Keep exactly one wait per PR running. Polls back
off on long waits (30s, then 60s after 5 minutes, then 120s after 15): every
waiting session polls as the same author account and shares its hourly API
budget.

The configured roles are a **floor**: a reviewer adds `spec`, `security`,
`ops` and `aggregate` on PRs that need them, and those count as expected only
once they claim. Roles land one after another, so a moment where every
expected role has posted can be a gap between two of them. `--wait` therefore
re-checks after `--settle` seconds (default 180, `PR_REVIEW_SETTLE_SEC`)
before returning, and keeps waiting if a role claimed in between.

When it wakes you, read its output, then go on below.

If `wait_timed_out: true`:
- `reviews.missing` non-empty and `reviews.in_progress` empty → no reviewer
  picked up the new head. Escalate: the reviewer sweep isn't running or isn't
  covering this repo/role. Don't trigger anything yourself.
- `reviews.in_progress` non-empty → a review is still running; start one more
  background wait, then escalate if that one times out too.
- `checks.pending` non-empty or `truncated.checks: true` → CI didn't settle or
  couldn't be proven settled. Escalate rather than calling it green.

Then go back to step 1.

**Reconcile before you terminate (mandatory gate).** Before declaring success,
you must have **read every review in `reviews.read` for the current head** and
folded its findings into the ledger. Machine precondition: `reviews.all_reviewed`
is true, `reviews.in_progress` is empty, and `review_verdict` ∈ {`clean`,
`nits`}. Two traps make the read non-optional:

- **Re-reviews are full passes over the new code.** A role can raise *new*
  findings, including on code your own fix introduced. Never assume "I read
  round N, so round N+1 says the same." Diff the latest review against your
  ledger.
- **A role can re-post after you read it** (answering your reply, or the
  aggregate re-merging after an input changed). Re-fetch `pr-status.sh` right
  before terminating and confirm each `reviews.roles.<role>.review_id` is the
  one you read.

**Termination:**
- ✅ **Success (clean)** — `ready: true`: CI green, no unresolved threads,
  every expected role reviewed the head, verdict `clean`, ledger reconciled.
- ✅ **Success (default mode)** — CI green, every expected role reviewed the
  head, nothing in progress, no human threads, `review_verdict == "nits"`, and
  the nits are in the ledger. `ready` reads `false` here purely because nits
  remain; that's expected.
- 🛑 **Unread** — `review_verdict == "unread"`: read and classify the reviews
  yourself, then re-evaluate. Never terminate from here.
- 🛑 **No reviewers** — `review_verdict == "none"`: escalate; nobody reviewed.
- 🛑 **Stalled** — the wait timed out (see step 5).
- 🛑 **Escalate** — see below.

**On every termination — success or escalation — persist the deferred-nits
ledger to the PR, then echo it in the conversation.** Conversation output is
lost when the session ends; the ledger must live where the merger sees it:

1. **Post or update the single canonical ledger comment with the script:**
   write the body to a file whose first line is the marker
   `<!-- pr-review-loop:deferred-ledger -->`, then
   `bash $S/pr-ledger.sh "<pr>" <body-file>`. It updates the existing ledger
   in place or posts one, and if two loops raced and more than one ledger
   exists, it keeps the oldest and deletes the rest. Don't hand-roll
   search-then-post: two loops doing that at the same moment both post.
2. **One aggregated block:** one bullet (`- `) per entry, `role · path:line —
   summary (review URL) — <status>`. Only bullets are entries: a deferred
   item written as prose or a numbered list is invisible to the validator and
   the harvester, so it is never filed. Every entry ends with exactly one
   status in bold, as the last thing on the line; `pr-ledger.sh` refuses a
   ledger with an entry that has none:

   | Status | When |
   |---|---|
   | `**fixed in <sha>**` | fixed in this PR |
   | `**done**` | handled without a code change (a PR-body edit, a retitle) |
   | `**decided …**` | the human ruled, e.g. `**decided by the TD: no**` |
   | `**skip: <reason>**` | deliberately not acted on, with the reason |
   | `**verified …**` | the finding was checked and needs no change |
   | `**bead <id>**` | deferred and filed as a work item |
   | `**follow-up**` | deferred, but you can't file it here; the merged-PR harvester files it |

   **File deferred findings now.** When `PR_REVIEW_BD` is set (the cell's way
   to reach `bd`; with `PR_REVIEW_FOLLOWUP_ROOT_BY_REPO` and optionally
   `PR_REVIEW_FOLLOWUP_ROOT_BY_PATH` naming the roadmap roots), run
   `python3 $S/pr-followup.py --pr <url> --entry "<entry line>"` for each one
   and tag it `**bead <id>**`. It files the bead under the root's "Review
   follow-ups" milestone, creating that once. Otherwise tag it `**follow-up**`.
   Either way the merger sees what's still open, and the harvester
   (`pr-ledger-harvest.py`, run on a schedule) files any `**follow-up**` left
   on a merged PR, so nothing deferred is lost. Keep the block deduped
   across rounds and roles. Mark items you fixed as fixed rather than
   deleting them. If the ledger is empty, say so explicitly.
3. Echo the same ledger in your final report.

Reviewers see the ledger in their next work packet, so they know what you
deliberately deferred. Its marker keeps it from counting as a reply, so
updating it doesn't send every role back to re-review. A real disagreement
still goes in a plain comment (step 2).

## When to escalate to a human (stop the loop)

The loop's job is convergence on clear-cut fixes. Stop and hand back to the
user the moment progress depends on judgment you shouldn't make unilaterally:

- **A human left a review comment.** Their feedback isn't yours to resolve.
- **A finding needs a real decision** — an architectural change, a
  product/behavior tradeoff, a `needs-human` verdict, or a "fix" that would
  alter intended behavior. Don't guess; present it.
- **A role restated a finding you replied to.** Two agents arguing in comments
  is a human's call.
- **A check fails for reasons you can't fix from the code** — missing secrets,
  flaky infra, an external outage, a required approval/permission.
- **No reviewer is reviewing** — `review_verdict == "none"`, or the wait timed
  out with roles missing and none in progress.
- **Merge conflicts or a non-`MERGEABLE` state** that needs a rebase decision.
- **The loop isn't converging** — the same blocker survives ~2–3 fix attempts.
  Repeating the same change means you've misunderstood the problem; escalate
  with what you tried.
- **A security-sensitive or destructive change** would be required (auth,
  secrets, deleting data/branches, force-pushing shared history).
- **The fix is outside this PR's scope** — it belongs in a separate change.

When you escalate, give the user a tight summary: what's still red, what you
tried, the specific finding/check text, your recommended next step — and the
nit ledger so far. Leave the PR in a clean, pushed state.

**Tell the human, don't make them find you.** The loop usually runs in a
session nobody is watching. On every termination — an escalation, or a
success that leaves the PR ready for the human's merge — send one push
notification if a notification tool is available (Claude Code:
`PushNotification`): `<owner/repo>#<n>: <ready to merge | needs you: one-line
reason>`. One per termination, never per round. The full summary stays in the
conversation and the ledger on the PR; the notification only says where to look.

## Safety rules

- **Secrets:** all `gh` access via `gh.sh`; never read `.env`; never print tokens.
- **Identity:** act as the PR author; commit as the PR owner.
- **Pushes:** normal pushes of new commits; `--force-with-lease` only to fix
  your own just-made mistake; never on shared/protected branches; never
  `--no-verify`. Run pushes unfiltered, check the exit code, and verify the
  remote head moved (step 3).
- **Reviews are the reviewers':** never post review markers, never set
  `review/<role>` statuses, never edit or delete a reviewer's comment. Disagree
  by replying.
- **Human threads:** never auto-resolve. `pr-resolve.sh` refuses to.
- **Scope:** fix what the reviews flagged; no unrelated refactors.
- **Don't fake green:** disabling a test, weakening an assertion, or `# noqa`-ing
  a real lint error to terminate the loop is an escalation, not a fix. Don't
  reclassify a blocker as a nit to avoid fixing it.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/gh.sh` | Run any `gh` command with `GH_TOKEN` injected via the repo's /secrets skill (else plain `gh`). Shared with pr-reviewer. |
| `scripts/pr-status.sh` | One-shot (or `--wait`) JSON snapshot: CI checks (excluding `review/*`), inline threads split bot/human, the per-role review state from `reviewer.py reviews`, mergeability, `ready`. |
| `scripts/pr-owner.sh` | Claim the PR for this session via a hidden PR-body marker (`CLAUDE_CODE_SESSION_ID`); exit 3 when another session owns it; `--take-over` only on the user's word. |
| `scripts/pr-ledger.sh` | Post or update the single deferred-nits ledger comment; refuses an entry without a status; dedupes if two loops raced (keeps the oldest). |
| `scripts/ledger_status.py` | The ledger grammar (entries, statuses, paths), shared by the scripts below. |
| `scripts/pr-followup.py` | File one deferred entry as a bead under the owning roadmap's "Review follow-ups" milestone; prints the id. |
| `scripts/pr-ledger-harvest.py` | Sweep merged PRs' ledgers since a date: report open entries, or with `--file` file them and tag the ledger in place. No model calls. |
| `scripts/tests/test_ledger.py` | Tests for the ledger scripts and `gh.sh`, no network: `python3 scripts/tests/test_ledger.py`. |
| `scripts/pr-resolve.sh` | Resolve review-bot inline threads (GraphQL) by explicit id, or `--all`. Never touches human threads, never requests reviews. |
| `../pr-reviewer/scripts/reviewer.py reviews <owner/repo#N>` | The per-role review state on its own (what `pr-status.sh` embeds as `reviews`). |

GitHub API specifics (thread-resolution mutation, check-state taxonomy, reading
review comments) are in `references/github-api.md`.
