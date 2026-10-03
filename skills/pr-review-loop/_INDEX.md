<!-- auto-index -->
# INDEX

> Author-side PR remediation loop — fix failing CI and the blocker findings of the pr-reviewer roles, push, wait for every expected role to re-review the new head, repeat until green; nits are deferred into a ledger comment on the PR.

## Folders
| Name | Description |
|------|-------------|
| `scripts/` | `gh.sh` (token-injected gh wrapper, shared with pr-reviewer), `pr-status.sh` (CI + inline threads + per-role review state via `reviewer.py reviews`; `--wait` until reviewers cover the head), `pr-resolve.sh` (resolve review-bot inline threads) |
| `references/` | GitHub API specifics — review comments and `review/<role>` statuses, replying to reviewers, thread resolution, check-state taxonomy |

## Files
| Name | Description |
|------|-------------|
| `SKILL.md` | Skill definition — identity, blocker-vs-nit triage, the assess→fix→push→wait loop, reconcile-before-terminate gate, escalation criteria, safety rules |
