<!-- auto-index -->
# INDEX

> Plugin hooks shipped with the nexus-kernel plugin; they load in every session that enables `nexus-kernel@nexus-kernel`

## Files
| Name | Description |
|------|-------------|
| `hooks.json` | Hook registrations: `PostToolUse` on Bash runs `pr-opened.sh` |
| `pr-opened.sh` | After `gh pr create` (or `gh.sh pr create`) opens a PR in a repo listed in `PR_REVIEW_ROLES_BY_REPO`, injects context telling the session to start `pr-review-loop`; a no-op everywhere else |
