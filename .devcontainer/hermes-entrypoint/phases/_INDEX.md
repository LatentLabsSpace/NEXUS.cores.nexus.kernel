<!-- auto-index -->
# INDEX

> Hermes entrypoint phases — bash modules sourced by `entrypoint-hermes.sh` to stage the container in root → runtime → config-override order

## Files
| Name | Description |
|------|-------------|
| `config-overrides.sh` | Applies model/provider overrides from env to the Hermes config |
| `root-bootstrap.sh` | Root-phase: registers `safe.directory` entries, calls `bootstrap_workspace`/`link_agent_state`, then sweeps ownership of `$WORKSPACE_ROOT`, `/home/node/.hermes`, `.copilot`, `.ssh`, and dotfiles to `$TARGET_UID:$TARGET_GID` before re-exec as node |
| `runtime-bootstrap.sh` | Node-user phase: starts firewall, seeds Hermes home, loads secrets, writes env files |
