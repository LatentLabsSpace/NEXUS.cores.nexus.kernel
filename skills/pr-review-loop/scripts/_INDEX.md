<!-- auto-index -->
# INDEX

> Shell helpers for the PR fix loop — token-safe gh wrapper, status summary, review-thread resolution

## Files
| Name | Description |
|------|-------------|
| `gh.sh` | Runs gh with the token injected via subprocess only (falls back to gh's own login when the repo's secrets have none and no file was named); shared by pr-reviewer and pr-review-loop |
| `ledger_status.py` | The deferred-nits ledger grammar: entries, statuses (fixed / done / decided / skip / verified / bead / follow-up), paths |
| `pr-followup.py` | Files one deferred ledger entry as a bead under the owning roadmap's "Review follow-ups" milestone; prints the id |
| `pr-ledger-harvest.py` | Sweeps merged PRs' ledgers since a date; reports open entries, or files them as beads and tags the ledgers (`--file`) |
| `pr-ledger.sh` | Posts or updates the PR's single ledger comment; refuses entries without a status; dedupes racing loops |
| `pr-owner.sh` | Claims a PR for this session via a hidden PR-body marker; exit 3 when another session owns it |
| `pr-resolve.sh` | Resolves bot review threads via GraphQL after fixes; never touches human threads |
| `pr-status.sh` | Emits JSON of CI state, unresolved threads and per-role review verdicts for the current head |
| `tests/` | `test_ledger.py`: ledger grammar, harvester filing and author filter, `gh.sh` fallback, with gh and bd stubbed |
