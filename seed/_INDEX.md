<!-- auto-index -->
# INDEX

> The consumer wiring layer — templates plus a renderer that turns any repo into a nexus kernel consumer; idempotent and retrofit-safe

## Folders
| Name | Description |
|------|-------------|
| `templates/` | Parameterized source files rendered into the target repo — compose, devcontainer, firewall drop-ins, crew env template, CLAUDE.md skeleton, scaffold stubs |

## Files
| Name | Description |
|------|-------------|
| `README.md` | Explains the seed layer, bootstrap usage for new and existing repos, and flags |
| `bootstrap.sh` | Idempotent shell renderer that copies templates into a repo, skipping existing files, and wires the kernel submodule |
