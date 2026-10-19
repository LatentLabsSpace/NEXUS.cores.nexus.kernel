<!-- auto-index -->
# INDEX

> Author-side PR remediation loop — fix failing CI and the blocker findings of the pr-reviewer roles, push, wait for every expected role to re-review the new head, repeat until green; nits are deferred into a ledger comment on the PR.

## Folders
| Name | Description |
|------|-------------|
| `references/` | Reference docs for pr-review-loop. |
| `scripts/` | Shell helpers for the PR fix loop — token-safe gh wrapper, status summary, review-thread resolution |

## Files
| Name | Description |
|------|-------------|
| `SKILL.md` | Skill definition: drive an open PR to green by fixing CI and reviewer blockers, deferring nits |
