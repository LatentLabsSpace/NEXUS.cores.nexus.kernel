<!-- auto-index -->
# INDEX

> Plugin hooks shipped with the nexus-kernel plugin; they load in every session that enables `nexus-kernel@nexus-kernel`

## Files
| Name | Description |
|------|-------------|
| `hooks.json` | Hook registrations: `PostToolUse` on Bash runs `pr-opened.sh`; `SessionStart` runs `session-start.sh`; `SessionEnd` and `PreCompact` run `archive-transcript.sh` |
| `pr-opened.sh` | After `gh pr create` (or `gh.sh pr create`) opens a PR in a repo listed in `PR_REVIEW_ROLES_BY_REPO`, injects context telling the session to start `pr-review-loop`; a no-op everywhere else |
| `session-start.sh` | Points git at `git/` for this Claude Code session only (`core.hooksPath` via `CLAUDE_ENV_FILE`), so the session's commits carry a `Claude-Session:` trailer |
| `git/` | `prepare-commit-msg` adds `Claude-Session: <session id>`; every other hook name runs the repo's own hook through `_chain` |
| `archive-transcript.sh` | Keeps a gzipped copy of the session's transcript in `~/.claude/session-archive/` at session end and before compaction |
| `commit-session.sh` | `commit-session.sh [<rev>]`: the session(s) that made a commit and where each transcript is |
| `tests/test_provenance.sh` | Tests for the four above in a temp repo with a fake HOME |
