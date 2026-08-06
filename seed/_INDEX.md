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
| `README.md` | What the seed renders, its parameters, and the acceptance checks to re-run when changing it |
| `bootstrap.sh` | Pure-shell renderer — adds the kernel submodule, renders templates by path and content, skips existing files with a report, prints the non-scriptable next-steps checklist |
