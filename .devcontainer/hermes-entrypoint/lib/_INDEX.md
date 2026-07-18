<!-- auto-index -->
# INDEX

> Reusable helpers sourced by the Hermes entrypoint phases — safe filesystem ops, workspace cloning, agent-state symlinking, and config-yaml mutators

## Files
| Name | Description |
|------|-------------|
| `config_overrides.py` | Python helper invoked by the bash phases to upsert YAML blocks in `$HERMES_HOME/config.yaml` (model, terminal.cwd, skills.external_dirs) and to render `.shell-env.sh` from `.env` |
| `link-agent-state.sh` | Points `/home/node/.hermes`, `.copilot/session-state`, `.ssh`, and `/commandhistory` at the per-agent folder under `$WORKSPACE_ROOT/quarters/crew/$AGENT_NAME/` so state is version-controlled with the repo |
| `safe-mkdir.sh` | Defines `safe_mkdir_under` — creates a path one component at a time, refusing to traverse or create symlinked components; used by the root-phase scripts that mkdir under attacker-influenceable workspace paths |
| `workspace-bootstrap.sh` | Clones the target repo into `$WORKSPACE_ROOT` on first start using `GH_TOKEN`/`HOST_GH_TOKEN`, validates the path is not a system directory, initializes submodules, and pre-creates the per-agent state subtree |
