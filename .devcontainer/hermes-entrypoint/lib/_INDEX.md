<!-- auto-index -->
# INDEX

> Reusable helpers sourced by the Hermes entrypoint phases — safe filesystem ops, workspace cloning, agent-state symlinking, and config-yaml mutators

## Files
| Name | Description |
|------|-------------|
| `config_overrides.py` | Python subcommands editing Hermes config.yaml in place from environment variables |
| `link-agent-state.sh` | Symlinks in-container agent state paths into the per-agent workspace folder |
| `safe-mkdir.sh` | Defines `safe_mkdir_under` — creates a path one component at a time, refusing to traverse or create symlinked components; used by the root-phase scripts that mkdir under attacker-influenceable workspace paths |
| `workspace-bootstrap.sh` | Shallow-clones the target repo on first start; retries submodule init idempotently |
