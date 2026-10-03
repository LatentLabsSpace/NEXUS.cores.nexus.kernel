# Reviewer roles

Every role posts its own verdict. That verdict covers only the role's own lens,
and each review opens with the role name so the author knows which lens it is.
A role that finds something outside its lens mentions it in one line under
"Outside my lens" and leaves the finding to that role. Don't just drop it.

When only one agent is reviewing, use `general`. `aggregate` is not a lens;
see its section below. It covers everything below at
normal depth. Add the specialist roles when the user asks for them, or when a
PR's risk profile calls for them: firewall, auth or secrets changes want
`security`; compose, deploy or migration changes want `ops`.

## general (default)

- **Correctness.** Does the code do what the PR says? Check edge cases, error
  paths, and fail-soft paths that report success when they failed.
- **Tests.** Run the suites in a worktree. Do the new tests fail without the
  fix? Tests that pass either way prove nothing.
- **Determinism.** Look for unsorted map iteration and time or order dependence.
- **Doc/code drift.** Stale comments, and a PR body that under-describes the
  diff.
- **Cross-PR interactions**, from the relations: overlaps, siblings and
  dependency order.

## security

- Secrets handling: nothing printed or logged, no `.env` reads, and the
  service-prefixed credential pattern.
- Egress and ingress: firewall allowlists should be least-privilege. Check what
  each service actually calls, compared with what it is allowed to call.
- Auth boundaries, token scopes, sudoers and capability grants (`cap_add`,
  `SETENV`, `env_keep`).
- Supply chain: pinned digests and versions, and kernel or submodule bumps
  carrying only reviewed upstream PRs. The packet's `submodule_bumps` gives the
  upstream PRs and their reviewed heads.
- Input handling at trust boundaries: injection, path traversal, SSRF.

## ops

- **Rollout plan.** Is there an order of operations? Is anything recreated that
  loses state, such as a watcher that doesn't survive a recreate, or backup
  timers? Is there a rollback path?
- **Compose and Docker.** Restart policies, memory caps, entrypoints,
  healthchecks and volumes.
- **Live-state compatibility.** Check the running system read-only (`docker
  inspect`, `docker exec … <read>`, SELECT queries) against what the PR
  assumes.
- **Migration ordering across repos.** A kernel shard must be published before
  the downstream bump; a schema must be applied before the code that needs it.

## aggregate

Reviews the reviews. It runs after the lens roles and merges their reviews of
one head into a single work list for the author. It has no lens of its own.

- **Dedupe.** One entry per underlying problem, crediting every role that
  raised it.
- **Resolve contradictions.** When roles disagree, check it in a worktree and
  say which advice holds and why.
- **Dispute, don't drop.** A role's blocker you think is wrong goes under
  "Disputed" with the evidence. The role's own status stays red until that
  role re-reviews; the aggregate never clears another role's gate.
- **Rank.** Blockers first, by blast radius, then nits. Keep "Outside my lens"
  notes the roles left for each other, routed to the right owner.
- **Add nothing new** beyond what verifying a disagreement turns up. A finding
  no role raised belongs in a lens review, so mention it as a gap instead.

## spec

For specs, ideas and docs PRs (`spec(…)`, `docs:`).

- Internal consistency, and consistency with the specs and code that exist.
  Cite paths.
- Frontmatter status is the single source of truth, and approval travels in
  the same PR. Don't open a PR just to change a status.
- Open questions are named, and decisions have owners.
- Cross-references resolve. Sibling-branch doc PRs in other repos must agree
  with each other.
