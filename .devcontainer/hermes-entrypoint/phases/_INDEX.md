<!-- auto-index -->
# INDEX

> Hermes entrypoint phases — bash modules sourced by `entrypoint-hermes.sh` to stage the container in root → runtime → config-override order

## Files
| Name | Description |
|------|-------------|
| `config-overrides.sh` | Runtime-phase shims that delegate to `lib/config_overrides.py` — apply `HERMES_PROVIDER`/`HERMES_MODEL`, set `terminal.cwd` from `WORKSPACE_ROOT`, and configure `skills.external_dirs` from `HERMES_EXTERNAL_SKILLS` |
| `root-bootstrap.sh` | Root-phase: registers `safe.directory` entries, calls `bootstrap_workspace`/`link_agent_state`, then sweeps ownership of `$WORKSPACE_ROOT`, `/home/node/.hermes`, `.copilot`, `.ssh`, and dotfiles to `$TARGET_UID:$TARGET_GID` before re-exec as node |
| `runtime-bootstrap.sh` | Node-user phase: activates the Hermes venv, runs `init-firewall.sh` (when enabled), seeds `$HERMES_HOME` (config.yaml, SOUL.md, subdirs), then writes `$HERMES_HOME/.env` and `.shell-env.sh` from container env vars |
