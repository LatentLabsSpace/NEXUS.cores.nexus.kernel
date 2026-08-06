<!-- auto-index -->
# INDEX

> Nexus Kernel — the publishable foundation downstream projects consume: a reusable devcontainer scaffold plus the self-referential JSON-LD semantic core

## Folders
| Name | Description |
|------|-------------|
| `.devcontainer/` | Base devcontainer for the kernel — generic Node 22 + mise + zsh + Claude Code scaffold, designed for extension by downstream projects |
| `.vscode/` | Editor settings — LF line endings for standalone use of this directory |
| `core/` | Inner core — self-referential kernel containing the atlas knowledge graph, recursive core, and outer boundary |
| `seed/` | The consumer wiring layer as templates plus `bootstrap.sh` — renders compose, devcontainer, firewall, and scaffold into a target repo; idempotent and retrofit-safe |

## Files
| Name | Description |
|------|-------------|
| `.gitattributes` | Git attributes — enforces LF line endings |
| `nexus.jsonld` | Top-level Nexus identity resource — Kernel Nexus typed as dcat:Resource; resolves the graph inward through `core/` |
