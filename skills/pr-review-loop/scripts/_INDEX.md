<!-- auto-index -->
# INDEX

> Shell helpers for the PR fix loop — token-safe gh wrapper, status summary, review-thread resolution

## Files
| Name | Description |
|------|-------------|
| `gh.sh` | Runs gh with the token injected via subprocess only; shared by pr-reviewer and pr-review-loop |
| `pr-resolve.sh` | Resolves bot review threads via GraphQL after fixes; never touches human threads |
| `pr-status.sh` | Emits JSON of CI state, unresolved threads and per-role review verdicts for the current head |
