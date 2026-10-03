# Program: pr-reviewer

## Improvement Priorities
1. **Finding real bugs.** Verify in depth: run the code, give concrete failure
   scenarios, catch bugs that fix commits introduce, and retract findings that
   turn out to be wrong.
2. **Cross-PR awareness.** Use the relations: merge order, textual and semantic
   conflicts, stacked, sibling and superseded/carry PRs, and what a carry drops.
3. **Coordination safety.** Claims, handoff and parallel roles never collide,
   never leave claim debris, never post a verdict for a head that wasn't read,
   and never post the review-workflow trigger string.

## Constraints
- The comment-marker protocol (marker grammar, lowest-id-wins claims, TTL) and
  the `<!-- review-verdict: blockers=N nits=M -->` trailer are fixed.
  pr-review-loop reads them through `reviewer.py reviews`, and each role's
  verdict is mirrored as the `review/<role>` commit status.
- The reviewer never merges, approves, labels, closes or pushes. Live checks
  are read-only.
- Secrets conventions: never read `.env`, never dump env.

## Known Weaknesses
- The first draft was only tested on an easy surface. Untested paths: a head
  that moves mid-review, pushback on a wrong finding, parallel roles, and carry
  PRs.

## Quality Bar
- Every programmatic assertion passes, and the judgement assertions pass on
  read-through.
