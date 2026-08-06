<!-- auto-index -->
# INDEX

> Base devcontainer for the kernel — generic Node 22 + mise + zsh + Claude Code scaffold plus an optional hermes agent-harness image, designed for extension by downstream projects

## Folders
| Name | Description |
|------|-------------|
| `firewall.d/` | Firewall drop-in configuration directory — conf files enumerate allowed outbound domains, loaded by init-firewall.sh at container start |
| `hermes-agent/` | Version pin for the hermes-agent harness — `_.jsonld` carries the clone URL, pinned commit SHA, and pip extras the `hermes-deps` build stage installs |
| `hermes-entrypoint/` | Hermes agent container entrypoint — modular bash phases (`phases/`) and helpers (`lib/`) sourced by `entrypoint-hermes.sh`, baked into the `hermes` image |

## Files
| Name | Description |
|------|-------------|
| `Dockerfile.base` | Multi-stage base image — `kernel-base` (node:22-trixie for git >= 2.41, mise, git-delta, zsh, Claude Code), `hermes-deps` (+ hermes-agent venv from the pinned public repo), `hermes` (+ entrypoint/config layer) |
| `README.md` | Extension contract — build targets, hermes-agent pinning, env vars, compose extends pattern, Dockerfile inheritance, firewall drop-in conventions |
| `bootstrap.code-workspace` | VS Code workspace definition — Nexus and Nexus Mount folder roots with search/exclude settings |
| `compose.base.yml` | Base Compose services — `nexus-kernel-base` (target `kernel-base`) and `hermes` (target `hermes`); cap_add NET_ADMIN/NET_RAW + common env; consumed via `extends:` |
| `devcontainer.json` | Standalone kernel devcontainer — uses compose.base.yml for isolated kernel-only development |
| `entrypoint-base.sh` | Parameterized container entrypoint — clones repo if NEXUS_REPO_URL set, inits firewall, runs NEXUS_POST_BOOT_CMD |
| `entrypoint-hermes.sh` | Hermes image entrypoint — sources the `hermes-entrypoint/` phases (root bootstrap → runtime → config overrides), then runs hermes in `$HERMES_MODE` |
| `gitconfig.base` | Generic git config — delta pager, pull.rebase, init.defaultBranch; no credential helpers |
| `hermes-config.yaml` | Default hermes `config.yaml` template — model, terminal, memory, skills-disabled list; seeded into `$HERMES_HOME` at runtime |
| `hermes-soul.default.md` | Generic neutral SOUL persona seeded when no workspace-specific `SOUL.md` is supplied |
| `hermes-venv-requirements.txt` | Extra pip packages installed into the hermes venv beyond hermes-agent's own deps (fastapi, httpx, uvicorn, python-dotenv) |
| `init-firewall.sh` | iptables/ipset firewall init script — resolves allowed domains from firewall.d/_required/ (hard-fail on DNS miss), firewall.d/_optional/ (warn and skip), and consumer firewall.d/ drop-ins |
| `vscode-extensions.json` | Recommended VS Code extensions for the kernel dev environment |
