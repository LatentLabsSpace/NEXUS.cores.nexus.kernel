<!-- auto-index -->
# INDEX

> Nexus Kernel — the publishable foundation downstream projects consume: a reusable devcontainer scaffold plus the self-referential JSON-LD semantic core

## Folders
| Name | Description |
|------|-------------|
| `.claude-plugin/` | Claude Code plugin and marketplace manifests that publish the kernel's skills |
| `.devcontainer/` | Base devcontainer for the kernel — generic Node 22 + mise + zsh + Claude Code scaffold plus the beads task-graph substrate, an optional hermes agent-harness image, and a bead-native Gas City orchestrator image, designed for extension by downstream projects |
| `.vscode/` | Editor settings for the kernel |
| `hooks/` | Plugin hooks — after `gh pr create` in a repo covered by reviewer roles (`PR_REVIEW_ROLES_BY_REPO`), tell the session to start `pr-review-loop` |
| `packs/` | Gas City packs shipped to every nexus city — `nexus/`, the org-wide fleet pack (model-serving upstreams and the lane each gascity role runs on) |
| `core/` | Inner core of the Nexus — the self-referential kernel containing the atlas knowledge graph, the recursive core, and the outer boundary |
| `seed/` | The consumer wiring layer — templates plus a renderer that turns any repo into a nexus kernel consumer; idempotent and retrofit-safe |
| `skills/` | Kernel-shipped agent skills — PR review loop, PR reviewer and beads roadmap management |

## Files
| Name | Description |
|------|-------------|
| `.gitattributes` | Git attributes — enforces LF line endings |
| `nexus.jsonld` | Top-level Nexus identity resource — Kernel Nexus typed as dcat:Resource; resolves the graph inward through `core/` |
