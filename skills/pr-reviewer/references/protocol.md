# Coordination protocol

The whole protocol is PR comments plus a local cache, with each role's verdict
mirrored as a commit status. There are no labels, no bot, and no coordinator
process.

## Markers

All markers are HTML comments, which GitHub does not render. They are
versioned (`v=1`), so a future format can coexist with this one.

```
<!-- pr-reviewer:claim  v=1 role=<role> head=<sha40> agent=<id> ts=<epoch> ttl=<minutes> -->
<!-- pr-reviewer:review v=1 role=<role> head=<sha40> agent=<id> [refs=<repo#n,...>] [inputs=<role,...>] -->
<!-- pr-reviewer:note   v=1 role=<role> head=<sha40> agent=<id> -->
<!-- review-verdict: blockers=<N> nits=<M> -->
```

- **claim**: a visible one-line placeholder that the review replaces. `ts` is
  the heartbeat; `renew` rewrites it with PATCH.
- **review**: must also carry the `review-verdict` trailer. `reviewer.py
  reviews` turns the markers and trailers into per-role state for the
  author-side `pr-review-loop`, so both sides read one grammar. An `aggregate`
  review also records the roles it merged in `inputs=`.
- **note**: a reviewer follow-up that is not a verdict. It is excluded from
  "someone replied" detection.
- **Author bookkeeping**: a comment containing `<!-- pr-review-loop:` (the
  author side's deferred-nits ledger, edited in place each round) is shown to
  reviewers in the packet's `conversation` but is also excluded from "someone
  replied" detection, so updating it doesn't trigger re-reviews.
- **Bot comments** (author login ending in `[bot]`: labelers, CI summaries,
  dependency bots) are also excluded from "someone replied" detection.
- **Legacy reviews**: a comment with a `review-verdict` trailer but no
  `pr-surface` marker counts as a `general` review. Its head is taken from
  "head `abc1234`" in the heading. If the heading has no head, the review is
  stale when any PR commit is newer than the comment. This lets the surface
  start from reviews that were posted before this skill existed.

Identity comes from the markers, never from the comment's author login.
Authors and reviewers here often post from the same GitHub account
(for example, one bot account for all agents). So "a comment by our user" does not tell you whether
it is a review, a claim or an author reply; only the marker does.

## Commit statuses

Each role's state is mirrored as commit status `review/<role>` (prefix
`$PR_REVIEWER_STATUS_PREFIX`) on the head it concerns:

| event | state | description |
|---|---|---|
| claim won | `pending` | Review in progress (<agent>, claim until HH:MMZ) |
| review posted, `blockers>0` | `failure` | N blockers, M nits |
| review posted, no blockers | `success` | No blockers, M nits / Clean — no findings |
| claim released, head not reviewed | `pending` | Awaiting review (claim released) |

The claim's expiry is in the pending description because a dead agent's
status stays `pending` until another agent claims or posts.

Statuses are a projection of the comments, never the source of truth: `scan`
and `claim` decide from the comments, and the status links to the review that
set it. Setting one is best-effort. A failure is returned and warned about but
never loses the posted review, and `reviews` flags a covering review whose
status disagrees (`status_mismatch`). Review statuses are excluded from the CI
summary. `PR_REVIEWER_STATUSES=0` disables them.

## Replies

A plain comment after a role's latest review puts that role in `reply` only if
it addresses that role — by linking one of the role's reviews
(`…#issuecomment-<id>`) or naming it as `Re: <role>` / `@<role>` — or addresses
no role at all, in which case every role answers. So an author pushing back on
one security finding doesn't wake general, ops, spec and the aggregate.

For the author side (`reviews`), legacy reviews (trailer without a marker) do
not make a role expected: a retired CI reviewer's old comments shouldn't make
the author wait for a role nobody runs.

## Claim algorithm (per PR, per role)

1. Read the comments. If a review for this role covers the current head and
   nothing but notes came after it, the PR is **done**: exit 10. If a live claim
   for this role exists, it is **held**: exit 11. A live claim is one where
   `ts + ttl` is later than now. If the live claim is yours (same agent id),
   reuse it.
2. Post a claim comment.
3. Wait about 2 seconds and read the comments again. Among the live claims for
   this role, the one with the **lowest comment id** wins. Comment ids increase
   monotonically, so every agent agrees on the winner without a clock.
4. If you lost, delete your own claim and exit 11.
5. On `post`, delete your claim and any **expired** claims for the role. Expired
   claims are ignored everywhere; `post` only tidies them up.

For the `aggregate` role, step 1 also requires every input role to have a
review covering the head with no live claim; otherwise the PR is `waiting`
(exit 12).

Claims are per role, not per head. If the head moves while you hold a claim,
you keep it; `post` then forces you to cover the new head (exit 4 until you do).

**Failure modes, and why they are acceptable:**
- **A dead agent.** Its claim expires after the TTL (60 min by default, set
  with `init --ttl`). This avoids gascity's `status/reviewing` label, which has
  no reaper.
- **Clock skew between hosts.** It only shifts when a claim counts as expired.
  Winning a claim never uses clocks.
- **Two agents given the same `--agent` id.** They would share a claim; the
  race check still separates them by comment id, but `release` from one agent
  could delete the other's claim. That's why the SKILL requires distinct ids.

## Review states (per PR × role)

```
          ┌──── review posted at head H ────┐
 new ─────┤                                  ├─► done ──(non-note comment)──► reply ──(review/note)──► done
          └──────────────────────────────────┘      │
                                                     └──(new head)──► rereview | rereview-blockers ──► …
```

A PR is `rereview-blockers` when the last verdict had `blockers>0`. That means
the author has probably pushed fixes and is waiting, so it goes first.

The `aggregate` role adds a `waiting` state (inputs not all at the head, or one
mid-review). Its review is `done` only while it covers the head **and** is
newer than every input review; an input re-posting at the same head makes it
due again.

## Relations (computed by `scan`)

| kind | source | affects order? |
|---|---|---|
| `stacked-on` / `stack-parent-of` | the PR's base branch is another open PR's head branch | yes (parent first) |
| `depends-on` | prose before a reference: "depends on / blocked by / requires / stacked on / builds on / merge after / needs"; or prose after it: "#N, which must merge first" | yes |
| `supersedes` / `superseded-by` | "supersedes / replaces / carry of" and "superseded by / carry PR / carried in" | the superseded PR goes last |
| `follow-up-to` | "follow-up to / backport of / cherry-pick of / split from" | no |
| `conflicts-with` | "conflicts with / collides with / overlaps with" | no |
| `overlaps` | same repo, shared changed files | no, but review the pair together |
| `sibling-branch` | same head branch name in different repos | no, but check that both halves agree |
| `bumps-submodule` | a changed path is a `.gitmodules` submodule | no; `snapshot` resolves the carried upstream PRs |
| `mentions` | any other `#N`, `owner/repo#N` or PR URL | no |

The prose is taken from the PR body, from non-marker comments, and from earlier
reviews and notes. So a reviewer who writes "depends on acme/platform#40" in a review
sets up the ordering for every later scan. gascity authors follow the same
conventions in their PR bodies: "Depends on #N", "Supersedes #N", "**Stack:**
base `x` (#N, which must merge first)", "Carry PR: <url>".

**Shard resolution.** A submodule repo whose description reads `Published shard
of OWNER/REPO:path` has commits messages of the form `Sync from <path>@<source
sha>`. `snapshot` maps both ends of the bump back to the source repo. It then
lists the merged source PRs in that range that touched `path`, with each PR's
head, so you can check the bump against what was reviewed. For example, a
kernel-pin bump resolves to the kernel PRs merged in the bumped range.

## Local state dir

```
$PR_REVIEWER_STATE/                       (default ~/.local/state/pr-reviewer)
├── config.json                          repos, clones (repo → local path), ttl_minutes
├── surface.json                         last scan: ordered queue + done list, with relations
├── worktrees/<agent>/<repo>-<n>-<sha7>/ per-agent detached checkouts from `checkout` (removed by post/release)
└── <owner>__<repo>/pr-<n>/
    ├── heads/<sha>.diff, <sha>.meta.json   PR diff at each head seen (survives force-pushes)
    ├── interdiff-<old12>-<new12>.diff      commit-range diff, or diff-of-diffs after a rebase
    ├── last-review-<role>.md               body of the role's latest review
    ├── snapshot.json, packet-<role>.json   latest snapshot / work packet
    ├── claim-<role>.json                   this host's claim (id, head, agent)
    ├── worktrees-<agent>.json              checkouts to remove on post/release
    ├── notes.md                            APPEND-ONLY reviewer notes, the handoff channel
    ├── outbox-<role>.md                    last body sent by `post`
    └── reviews/<head12>-<role>-<id>.md     copies of posted reviews
```

The per-head diffs are kept because a force-push can make the reviewed head
unreachable through the API. The stored diff still lets you build a
diff-of-diffs.

## Prior art

- **gascity's maintainer-pr-review pack** (private; observed through its PR
  output).
  - Claims with a `status/reviewing` label: added when a review starts, removed
    about a second after the verdict posts.
  - Its verdict trailer `<!-- mpr-review head=<sha> verdict=fix-merge -->` is
    keyed to the head, the same idea as ours.
  - Three model reviewers plus a synthesizer that checks their claims against a
    checkout.
  - Label state machine: `status/needs-review`, `merge-ready`, and holds such
    as `blocked-on-deploy-gate`.
  - What we copy: the head-keyed verdict, incremental re-reviews ("Re-reviewed
    `09cbd4b`..`4870cbb` (1 new commit)"), and failing closed when state is
    ambiguous.
  - What we avoid: labels with no TTL.
- **gastownhall/beads #5740.** The maintainer's review:
  - states the verdict first ("MERGE-AFTER-FIXES");
  - traces the claim against the codebase and against upstream Dolt issues;
  - asks one load-bearing question (the server version);
  - files #5752 for the in-tx surface the PR left out;
  - cross-links the fork's parallel work "so nobody starts it independently";
  - ends with "Ball's in your court".

  Later a carry PR (#6040) superseded it with attribution preserved, and the
  original stayed open with the reason stated. Our review format and the
  `supersedes` relations come from this thread.
