# Review format

```markdown
## Review ({role}) — {repo}#{n} at `{head7}`{", re-review of `{old7}`..`{head7}`" if re-review}

**Verdict: {ship | fix-then-ship | changes-needed | needs-human}** — {one sentence: why}

{2–5 sentences: what this PR changes and what you checked most carefully, and why those were the risks.}

**Verified**
- {claim} — {how: command run / file:line read / live read-only check / compared against upstream X}
- …
- CI covers: {what you relied on CI for, and didn't rerun}

### Prior findings        (re-reviews only)
1. {finding} — fixed in `{sha}` ✓ | partly: {what remains} | not addressed

### Medium (blocker)
1. **{title}** — `path:line`. {What breaks, for whom, and under which concrete input or state.} {Suggested fix.}

### Low / nits
1. {…}

### Cross-PR
- {related PR}: {how it interacts — merge order, conflict, shared contract, carried upstream PR}. {What to do.}
- Suggested follow-up (not filed): {out-of-scope surface worth tracking}

**Next:** {author: fix the blockers and push | reviewer: waiting on {PR} to merge first | human: decision needed on X}

<!-- review-verdict: blockers={N} nits={M} -->
```

## Aggregate format

The `aggregate` role uses the same skeleton with these changes:

```markdown
## Review (aggregate) — {repo}#{n} at `{head7}` — merges {role}, {role}, …

**Verdict: …** — {one sentence}

### Medium (blocker)
1. **{title}** — `path:line` [{roles that raised it}]. {Failure scenario.} {Fix.}

### Low / nits
1. … [{roles}]

### Disputed
- {role}'s "{finding}" — {why you think it is wrong, with the evidence}. Its
  `review/{role}` check stays red until {role} re-reviews.

### Contradictions resolved
- {role A} vs {role B} on {topic}: {which holds and why}.

**Next:** …

<!-- review-verdict: blockers={N} nits={M} -->
```

The trailer counts the consolidated list, so a disputed finding is not counted.
Every input role is named in the heading, and every finding carries the roles
that raised it.

## Rules

- **The verdict comes first.** `ship` means no blockers. `fix-then-ship`
  means small blockers with an obvious fix. `changes-needed` means the approach
  needs work. `needs-human` means a product or architecture decision that
  neither author nor reviewer should make alone. The trailer counts must agree
  with the sections. Anything in "Medium (blocker)" is a blocker.
- **Blocker or nit.** A blocker is a correctness bug, a security hole,
  data-loss risk, a broken contract, a rollout that breaks prod, or a
  silent-failure path. Everything else is a nit. When unsure, make it a
  blocker, because deferring a real bug by accident is worse. Never inflate
  nits to force a change you just prefer.
- **Say how you verified each point.** "Tests pass" says less than "ran
  `vitest run` in the worktree: 412 passed". Give the command and the count.
  Say what you did not verify.
- **Every finding needs a concrete failure scenario.** Name the input and
  state, and what goes wrong. If you can't construct one, it's a nit or a
  question.
- **Re-reviews go through prior findings first.** Give each a line; don't make
  the author re-read the whole thing. Look at new code only through the
  interdiff.
- **Cross-PR is mandatory when relations exist.** Write "none" if you checked
  and found no interaction.
- **Say whose turn it is.** The Next line names who acts next, so no PR stalls
  with everyone waiting on everyone.
- **Never write the review-workflow trigger** (a slash followed by "review") in
  the body. `post` refuses it. Also leave out tokens, secret values and
  `.env` contents.
- **Admit mistakes.** If an earlier review was wrong, say so under Prior
  findings and withdraw the finding.
- **Keep it tight.** Aim for a length the author can act on in a few minutes;
  the author is often another agent.
