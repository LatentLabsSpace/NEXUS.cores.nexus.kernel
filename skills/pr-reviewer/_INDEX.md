<!-- auto-index -->
# INDEX

> Reviewer for the whole open-PR surface — scan, relate, sequence, claim, verify and post reviews across repos; PR comments with head-keyed HTML markers are the shared lock/verdict state, a host-local state dir caches diffs and handoff notes.

## Folders
| Name | Description |
|------|-------------|
| `scripts/` | `reviewer.py` (stdlib CLI: init/scan/next/claim/renew/release/snapshot/checkout/show/post/reviews; mirrors verdicts as `review/<role>` commit statuses) and `tests/` (protocol tests against a fake gh) |
| `references/` | Coordination protocol (incl. commit statuses), reviewer roles (incl. aggregate), review format |
| `evals/` | Sandbox eval suite — fixture builder, programmatic grader, `evals.json` |

## Files
| Name | Description |
|------|-------------|
| `SKILL.md` | Skill definition — setup, survey → claim → review → post → report loop, multi-agent operation, boundaries |
