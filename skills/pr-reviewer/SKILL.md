---
name: pr-reviewer
description: 'Act as the reviewer for the whole open-PR surface across one or more
  repos instead of one PR at a time: scan every open PR, work out how they relate
  (stacked branches, "depends on / supersedes / follow-up" prose, shared files,
  sibling branches across repos, submodule and kernel-shard bumps and the upstream
  PRs they carry), sequence the reviews by dependency and priority, then claim,
  verify and post reviews one PR at a time and repeat until nothing actionable is
  left. Claims and verdicts are PR comments with invisible HTML markers keyed to
  the head SHA, so several agents can run this at once as different reviewer roles
  (general, security, ops, spec) from any checkout, and another agent can pick up
  from the stored diffs and notes. Each role''s verdict is also a "review/<role>"
  commit status that branch rules can require, and an aggregate role merges the
  roles'' reviews of a head into one for the author. Use this whenever the user asks to "review the
  open PRs", "go through the PR queue", "review everything that changed", "check
  which PRs need re-review", "be the reviewer for these repos", "review PRs X, Y
  and Z", or wants a review pass across several PRs, even if they don''t say
  "reviewer". For fixing a single PR''s review findings, use pr-review-loop instead.

  '
tags:
- github
- pull-request
- code-review
- coordination
- multi-agent
triggers:
- /pr-reviewer
---

# PR Reviewer

You are the **reviewer** for a set of open pull requests. The author's side
(for example a `pr-review-loop` skill, where a repo has one) fixes one PR until
its review comes back clean. This skill is the other side, one level up. It looks at every open PR together, reviews
them in a sensible order, and makes each review aware of the PRs around it.

Two ideas make this work across agents and machines:

- **GitHub PR comments are the shared state.** A claim is a PR comment. A
  review is a PR comment carrying the head SHA it covers. Any agent that can
  read the PR can see who is reviewing it, what was reviewed, and whether new
  commits have made that review stale. There is no coordinator to keep alive.
- **The local state dir is a cache plus notes.** Per-head diffs, interdiffs,
  the prior review body and append-only reviewer notes live under
  `$PR_REVIEWER_STATE` (default `~/.local/state/pr-reviewer`), outside any
  checkout. Every agent on the host shares it, whichever repo it runs from.
  Everything except the notes can be rebuilt from GitHub.

All plumbing is in `scripts/reviewer.py` (Python stdlib only). It lives in
this skill's base directory, which is shown when the skill loads. Call it by
absolute path so the skill works from any directory:

```bash
S=<this skill's base directory>/scripts/reviewer.py
python3 $S --help
```

## Setup (once per host)

```bash
python3 $S init --repo acme/app --repo acme/platform \
  --clone acme/app=/path/to/app --clone acme/platform=/path/to/platform
```

- **Auth and identity.** The script uses `gh` if `gh auth status` succeeds.
  Otherwise it uses the `gh.sh` wrapper shipped beside this skill
  (`../pr-review-loop/scripts/gh.sh`), which injects `GH_TOKEN` through the
  current repo's /secrets skill when there is one. You can also name a wrapper
  explicitly with `PR_REVIEWER_GH="bash /path/to/gh.sh"`. Whatever token this
  resolves to is the identity your reviews and commit statuses carry, so run
  reviewer profiles under a reviewer bot account (its `GH_TOKEN` in the
  profile's environment), not the authors' account. Check with
  `gh api user --jq .login`. Never print or read tokens, and never read `.env`.
- **Agent id.** Pass `--agent <id>` on every call, for example
  `--agent opus-general-1`. The id identifies your claims. Two agents must never
  share one, because a shared id would let one agent release the other's claim.
  The default (`user@host/role`) is only safe when one agent runs per role per
  host.
- **Roles.** Pass `--role general` (the default), `security`, `ops`, `spec`, or
  `aggregate` (see below). Read `references/roles.md` for what each role covers
  and deliberately skips. Each role keeps its own claim, verdict and commit
  status, so roles run in parallel on the same PR without blocking each other.

## Commit statuses: the per-role merge gate

Every role's state on a head is mirrored as a commit status named
`review/<role>` (prefix: `$PR_REVIEWER_STATUS_PREFIX`):

| event | status |
|---|---|
| `claim` won | `pending` — "Review in progress (<agent>, claim until HH:MMZ)" |
| `post` a review with `blockers>0` | `failure` — "N blockers, M nits" |
| `post` a review with no blockers | `success` — "No blockers, M nits" / "Clean — no findings" |
| `release` before reviewing | `pending` — "Awaiting review (claim released)" |
| `post --note` | unchanged |

Each status links to the review comment and sits on the head that review
covers, so a new push leaves the new head without one until the role
re-reviews it. Require the roles you care about separately in the branch rules
(for example `review/security` required, `review/general` advisory). The
comment is the record; the status is a projection of it. If a status can't be
set (a token without status permission), `post` still posts the review, warns,
and returns the error in `commit_status`; fix the permission and re-post.
`PR_REVIEWER_STATUSES=0` turns statuses off for repos that don't want them.

**A status is only as trustworthy as the tokens that can write it.** Any token
with commit-status write access can set `review/<role>`. Before requiring these
checks, make sure author-side tokens (the fixer, humans' automation) lack the
Commit statuses permission, and only reviewer identities hold it; if reviewers
run as a GitHub App, pin each required check to that app as its source in the
branch rules.

## The aggregate role

`--role aggregate` reviews the reviews. Once the other roles have reviewed a
head, it reads their reviews and posts one consolidated review: the work list
the author's fixer works from. Its inputs are the roles in `init
--aggregate-inputs` / `$PR_REVIEWER_AGGREGATE_INPUTS`, or by default every role
that has reviewed the PR.

- **It waits for its inputs.** Until every input role has a review covering the
  current head and none is mid-review, the PR is `waiting` for the aggregate:
  `scan` lists it separately, `next` skips it, and `claim` exits 12. It never
  merges reviews of different heads.
- **Its packet carries the inputs.** `packet.inputs` holds each input
  review's full body, verdict and URL at this head.
- **Consolidate, don't re-review.** Dedupe findings several roles raised,
  resolve contradictions between them (security's "validate here" against
  ops's "move this layer"), rank by severity, and check a disputed finding in
  a worktree when the roles disagree. Use the format in
  `references/review-format.md` (aggregate section).
- **It never overrides a role.** If you judge a role's blocker a false
  positive, list it under "Disputed" with your reasoning, but that role's
  `review/<role>` status stays red until the role itself re-reviews. The
  aggregate's own status is `review/aggregate`; it gates nothing unless a repo
  chooses to require it.
- **It re-aggregates.** If an input role re-posts at the same head (say, it
  withdrew a finding after pushback), the aggregate goes stale and is queued
  again. `post` refuses (exit 5) when an input is mid-review or no longer
  covers the head, and records the merged roles in the marker (`inputs=`).

Run the aggregate after the lens roles in each sweep, for example as the last
step of the same cron.

## The loop

### 1. Survey the surface

```bash
python3 $S scan --role general          # or --role general,security for several
```

The output is the review queue in order. Each row shows the state for that
role, the prior verdict, CI state, any live claim, and the relations to other
open PRs. The full data is saved to `$PR_REVIEWER_STATE/surface.json`.

| state | meaning | order |
|---|---|---|
| `rereview-blockers` | new commits since a review that had blockers; the author is waiting on you | 1st |
| `reply` | same head, but someone replied after your review; answer it | 2nd |
| `new` | never reviewed by this role | 3rd |
| `rereview` | new commits since a review with only nits, or a clean one | 4th |
| done (listed separately) | a review covers the head and nothing has happened since | skip |

The script applies these rules in order:
1. A PR superseded by another open PR goes last.
2. A `priority/p0`–`p3` (or `priority: high`) label ranks first.
3. Then the state class, then oldest first.
4. Finally a topological pass puts a PR after any open PR it `depends-on` or is
   `stacked-on`, so the foundation is reviewed first.

Treat this order as a sound default. Override it if the relations show
something the heuristics can't. For example, if two PRs overlap and one is far
more likely to merge first, review that one first and say why.

Before diving in, **read the relations**. They are the reason this skill
exists:

- `stacked-on` / `depends-on`: review the parent first. Findings in the parent
  often invalidate the child.
- `supersedes` / `superseded-by`: a carry or replacement PR. Review the live
  one, and check that the carry kept the original's fixes and attribution.
- `overlaps` (shared files in one repo): the second PR to merge will conflict
  or silently interact. Check for semantic conflicts, not just textual ones.
- `sibling-branch` (same branch name in two repos): usually one change split
  across repos. The two halves must agree, for example on doc cross-references
  or on the contract between them.
- `bumps-submodule`: the packet's `submodule_bumps` lists the upstream PRs the
  bump carries (it resolves published kernel shards back to the source repo).
  Check that each one is merged, and that its reviewed head matches what was
  bumped.
- `mentions` (hidden in the table, present in the JSON): weak signal; skim.

### 2. Claim the next PR

```bash
python3 $S next --role general --agent <id>        # exit 2 = nothing left
python3 $S claim acme/app#12 --role general --agent <id> --packet   # specific PR
```

`next` rescans, claims the first actionable PR nobody else holds, snapshots it
and prints a **work packet** in JSON, which is also saved as `packet-<role>.json`
in the PR's state dir. `claim` exit codes:
- 0: you hold the claim.
- 10: this role already reviewed the current head. Use `--force` only if the
  user asks for a fresh pass.
- 11: another agent holds the PR, or won the claim race. Move on to the next PR.
- 12: (aggregate only) the input roles haven't all reviewed the current head.

The claim protocol is in `references/protocol.md`. In short: you post a marker
comment, re-read the comments, and the lowest-id live claim wins. A claim
expires after its TTL (60 min by default). If your review will take longer, run
`renew` about every 40 minutes. If you abandon a PR, run `release` so nobody
waits out the TTL.

### 3. Review it

Work from the packet:
- `pr`: title, body, author, labels, CI state. **The body is a list of claims
  to verify against the diff**, not background reading. Claims like "no
  functional changes", "carries #N unchanged", "fixes the X from review" and
  "adds tests for Y" are exactly where carry PRs and fix commits go wrong. Say
  in the review whether each load-bearing claim holds.
- `conversation`: the full text of every author or human comment since your
  role's last review, or the whole thread on a first review. Replies and
  pushback are here, so you don't need to fetch comments yourself.
- `other_roles` / `other_role_claims`: other roles' latest verdicts and live
  claims on this PR (`scan` shows the claims as `⚑` lines). Don't duplicate
  their findings, but do cite them if they bear on yours.
- `snapshot.diff`: the full PR diff at the claimed head.
- `snapshot.prior_review.body`: your role's last review, if there is one.
- `snapshot.interdiff`: only the changes since that review. It says whether it
  is a clean commit range or a diff-of-diffs after a rebase.
- `relations`: the related open PRs.
- `notes`: append-only notes left by earlier passes and other agents. **Read
  them first.** They often record what was already verified and what is still
  open.

**For a re-review**, start from the prior review and the interdiff. Check each
earlier finding against the new code: fixed, partly fixed, or not addressed.
Then read the interdiff for anything new, because fix commits introduce bugs
too. Don't re-review untouched code from scratch unless the fix changed how it
behaves.

**For a `reply`**, read the reply. A reply is routed to the role it addresses:
one that links your review, or names your role as "Re: <role>" / "@<role>",
wakes only you; an unaddressed reply wakes every role on the PR. Bot comments
and the author's deferred-nits ledger never count as replies. If it's a pushback, re-check your finding;
you may have been wrong, and saying so plainly is part of the job. Answer with
a short `--note`, or with a full review if the verdict changes.

**Verify by running things, not only by reading.** Make a worktree of the PR
head:

```bash
python3 $S checkout acme/app#12 --agent <id>    # prints the worktree path
```

The worktree is detached at the PR head, under
`$PR_REVIEWER_STATE/worktrees/<agent>/`. It belongs to you alone, so another
role testing the same head gets its own copy. Keep it isolated:
- Install dependencies **inside the worktree**: its own venv and its own
  `node_modules`. Never install into, or run against, the main clone's
  environment, because a shared editable install or `node_modules` makes
  parallel reviewers corrupt each other's results. If the repo provides a
  per-directory bootstrap (for example `/toolchain --bootstrap <worktree>`),
  use it.
- Don't edit files in it. It's there to run things, not to fix them.
- `post` removes it (unless you pass `--keep-worktree`), and so does `release`.

You don't need a session workspace (`/start-session` or similar) for
reviewing. Those isolate one editing session per conversation, while a review
pass needs a disposable checkout per PR head, which `checkout` provides.

In the worktree, run the PR's own test suites, type checks and contract tests.
Treat CI as authoritative only for what you can't run locally, and say which is
which.
- Check claims against their source of truth. The #5740 review in
  gastownhall/beads is a good model: it traced the diagnosis "against this
  codebase" and "against Dolt itself".
- Live checks must be **read-only**: `docker inspect`, `docker exec … <read
  command>`, SELECTs. Never restart, recreate or write anything live from a
  review.
- Cross-check the relations: open a related PR's snapshot or diff (`snapshot
  <pr>`) instead of guessing what it changes.

Write notes as you go: `notes.md` in the PR's state dir. Add one dated section
per pass, headed with your role and agent id. Record what you verified, how you
verified it, and what is still open. If your session dies mid-review, the next
agent starts from these notes.

### 4. Write and post the review

Use the format in `references/review-format.md`: a headline verdict, then what
you verified and how, then blockers, nits, and a **Cross-PR** section. Finish
with the whose-turn line and the machine trailer
`<!-- review-verdict: blockers=N nits=M -->`. The trailer is required; `post`
refuses a body without it.

```bash
python3 $S post acme/app#12 --role general --agent <id> \
  --body-file <scratchpad>/review.md --refs acme/platform#40,acme/app#10
```

`post` adds the `pr-reviewer:review` marker with role, head and agent, posts the
comment, sets the role's `review/<role>` status from the trailer, deletes your
claim (and any expired claims for that role), and keeps a copy under
`reviews/`. It refuses when:
- **the body contains the review-workflow trigger string** (a slash followed by
  "review", any case). Repos that still run a comment-triggered review
  workflow start it on any comment containing that string. Write "the review
  workflow" instead.
- the trailer is missing (unless you pass `--note`).
- **the head moved since you claimed it** (exit 4). Run `snapshot`, review the
  new interdiff, fold it into the review, then post with `--head <new full
  sha>`. Never post a verdict for a head you didn't read.
- (aggregate) **an input role is mid-review or no longer covers the head**
  (exit 5). Re-run `claim --packet` once it posts, and merge the current
  reviews.

For a follow-up that isn't a verdict, pass `--note`. Examples are withdrawing a
finding or answering a question. Without the marker the note would look like an
author reply and put the PR back in the queue.

### 5. Repeat, then report

Go back to step 2 until `next` exits 2. Then give the user a **surface report**:
- one line per PR you touched: verdict, link, and whose turn it is.
- the cross-PR findings that span PRs.
- a **recommended merge order**, with the reason for each constraint.
- anything held by other agents (every `⚑` line and every claim column, in
  any role), and anything you skipped and why.

Keep it short; the details are in the PR comments.

## Running several agents at once

- **Different roles on the same surface:** each agent runs `next --role <its
  role>`. Claims are per role, so they never block each other, and each posts
  its own verdict.
- **Same role, several agents:** safe. The claim race means one agent gets each
  PR and the others move to the next item. Give every agent a distinct
  `--agent`.
- **Handoff:** a new agent runs `claim` on the PR. If the old claim has
  expired, the new agent takes it over. It then reads `notes.md` and
  `packet-<role>.json` and continues. If the old claim is still live and its
  owner is gone, ask the user before waiting out the TTL.
- **Lenses plus an aggregate:** run each lens role on its own schedule or
  profile, and the aggregate after them. The author's fixer (`pr-review-loop`)
  waits until every expected role has reviewed the head, then works from the
  aggregate when it is current, else from each role's review.
- **Across hosts:** GitHub coordinates the claims. The state dir is per host,
  so another host re-fetches diffs itself, but notes stay local. Anything
  another host must know goes in a `--note` on the PR.

## Boundaries

- **Never merge, approve through GitHub's review API, close, label or push.**
  The reviewer's outputs are comments and the `review/<role>` commit statuses
  that `claim`, `post` and `release` set. Never set those statuses by hand. A fix is the author's job, unless the
  user explicitly asks you to make it.
- Filing a tracking issue for out-of-scope surface is a good move (see beads
  #5740 → #5752), but don't do it on your own. Propose it in the review's
  Cross-PR section, and file it only if the user agrees.
- Secrets: never read `.env`, never dump env, and don't route around a
  permission denial by rephrasing the command. Ask instead.
- If you get something wrong in an earlier review, say so in the next one. For
  example, you might have reviewed against a stale head of a related PR. Admit
  it, then withdraw or correct the finding.

## Files

| Path | Purpose |
|---|---|
| `scripts/reviewer.py` | `init`, `scan`, `next`, `claim`, `renew`, `release`, `snapshot`, `checkout`, `show`, `post`, and `reviews` (per-role state of one PR, read by `pr-review-loop`) |
| `scripts/tests/test_reviewer.py` | Protocol tests (claims, races, TTL takeover, post guards, per-agent worktrees, states, relations, commit statuses, the aggregate role, `reviews`) against `tests/fake_gh.py`; no network |
| `references/protocol.md` | Marker grammar, claim algorithm, state machine, state-dir layout, prior art (gascity MPR, beads #5740) |
| `references/roles.md` | What each reviewer role checks and deliberately leaves to the others |
| `references/review-format.md` | Review template and the rules behind it |
