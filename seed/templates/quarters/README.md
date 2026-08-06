# quarters/ — agent crew state

Per-agent state directories, following the nexus kernel convention: each agent
that operates on this repo keeps its state under `quarters/crew/<agent-name>/`.
The kernel's hermes entrypoint links the canonical in-container paths
(`~/.hermes`, `~/.claude`, `~/.copilot`, `~/.ssh`, shell history,
`~/.vscode-server`) into that folder, so agent state is version-controlled with
the repo it works on.

## Crew

| Agent | State | Purpose |
|-------|-------|---------|
| `{{AGENT_NAME}}` | `crew/{{AGENT_NAME}}/` | Hermes agent harness for this repo. Runs via `compose.yml` (see the repo root). |

Each crew directory carries:

- `.hermes/` — SOUL.md, memories, skills (whitelist-gitignored; runtime state
  like sessions, logs, and databases never lands in git)
- `.env.template` — documented template for the per-agent `.env` (the `.env`
  itself is gitignored; never commit credentials)
- runtime-only folders (`.claude/`, `.copilot/`, `.ssh/`, `.bashhistory/`,
  `.vscode-server/`) — created by the entrypoint, gitignored
