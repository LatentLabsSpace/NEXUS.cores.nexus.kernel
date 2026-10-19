<!-- auto-index -->
# INDEX

> Kernel-shipped agent skills — PR review loop, PR reviewer and beads roadmap management

## Folders
| Name | Description |
|------|-------------|
| `pr-review-loop/` | Author-side PR remediation loop — fix failing CI and the blocker findings of the pr-reviewer roles, push, wait for every expected role to re-review the new head, repeat until green; nits are deferred into a ledger comment on the PR. |
| `pr-reviewer/` | Reviewer for the whole open-PR surface — scan, relate, sequence, claim, verify and post reviews across repos; PR comments with head-keyed HTML markers are the shared lock/verdict state, a host-local state dir caches diffs and handoff notes. |
| `roadmap/` | Beads-native roadmap skill — turn operator goals into gated phases and dispatchable leaf tasks |
