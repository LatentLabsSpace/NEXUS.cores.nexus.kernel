<!-- auto-index -->
# INDEX

> Hermes agent container entrypoint — modular bash phases and helpers sourced by `entrypoint-hermes.sh`, installed into `/usr/local/share/hermes-entrypoint/` by the Dockerfile

## Folders
| Name | Description |
|------|-------------|
| `lib/` | Reusable helpers sourced by the Hermes entrypoint phases — safe filesystem ops, workspace cloning, agent-state symlinking, and config-yaml mutators |
| `phases/` | Hermes entrypoint phases — bash modules sourced by `entrypoint-hermes.sh` to stage the container in root → runtime → config-override order |
