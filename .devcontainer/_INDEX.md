<!-- auto-index -->
# INDEX

> Base devcontainer for the kernel — generic Node 22 + mise + zsh + Claude Code scaffold plus the beads task-graph substrate, an optional hermes agent-harness image, and a bead-native Gas City orchestrator image, designed for extension by downstream projects

## Folders
| Name | Description |
|------|-------------|
| `beads/` | Linked-data descriptor for the beads task-graph component |
| `firewall.d/` | Firewall drop-in configuration directory — conf files enumerate allowed outbound domains, loaded by init-firewall.sh at container start |
| `gascity/` | Linked-data descriptor for the Gas City orchestrator component |
| `hermes-agent/` | Linked-data descriptor for the Hermes agent harness component |
| `hermes-entrypoint/` | Hermes agent container entrypoint — modular bash phases and helpers sourced by `entrypoint-hermes.sh`, installed into `/usr/local/share/hermes-entrypoint/` by the Dockerfile |

## Files
| Name | Description |
|------|-------------|
| `Dockerfile.base` | Multi-stage base image: kernel-core, kernel-base, beads, hermes and gascity targets |
| `README.md` | Explains kernel devcontainer build targets and how downstream projects extend them |
| `bootstrap.code-workspace` | VS Code workspace definition — Nexus and Nexus Mount folder roots with search/exclude settings |
| `compose.base.yml` | Compose service definition building the kernel-base image with firewall capabilities |
| `devcontainer.json` | VS Code devcontainer config for the nexus-kernel compose service |
| `entrypoint-base.sh` | Base container entrypoint; clones the repo and bootstraps the workspace |
| `entrypoint-beads.sh` | Beads server entrypoint — initializes `$BEADS_DATA_DIR`, widens the dolt root grant for compose-network clients, seeds the commit identity, then execs `dolt sql-server` on `$BEADS_PORT` |
| `entrypoint-gascity.sh` | Gas City entrypoint; requires the bd provider against the shared beads server |
| `entrypoint-hermes.sh` | Hermes entrypoint; sources lib helpers and runs root, runtime and config phases |
| `firewall-exec` | Wrapper that runs the egress firewall then execs a service, as an ENTRYPOINT prefix |
| `firewall-lib.sh` | Helpers sourced by `init-firewall.sh` and `firewall-refresh`: hostname validation and the public-IPv4 filter |
| `firewall-refresh` | Root loop started by `init-firewall.sh` after the lock: re-resolves the boot's domains and adds rotated A records (add-only, capped) |
| `gitconfig.base` | Generic git config — delta pager, pull.rebase, init.defaultBranch; no credential helpers |
| `hermes-config.yaml` | Default hermes `config.yaml` template — model, terminal, memory, skills-disabled list; seeded into `$HERMES_HOME` at runtime |
| `hermes-soul.default.md` | Generic neutral SOUL persona seeded when no workspace-specific `SOUL.md` is supplied |
| `hermes-venv-requirements.txt` | Extra pip packages installed into the hermes venv beyond hermes-agent's own deps (fastapi, httpx, uvicorn, python-dotenv) |
| `init-firewall.sh` | One-shot egress firewall setup using iptables and ipsets, idempotent per boot |
| `vscode-extensions.json` | Recommended VS Code extensions for the kernel dev environment |
