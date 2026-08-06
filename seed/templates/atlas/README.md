# atlas/ — knowledge

Human-owned knowledge for {{SERVICE_PREFIX}}: specs, concepts, roadmap,
diagrams. Code lives in `codex/`; nothing here is executed.

Suggested subdirectories (create as needed — this stub does not presume a
structure):

- `atlas/ideas/` — raw, divergent idea files. Not yet bounded or specced.
- `atlas/concepts/` — structured, bounded explorations.
- `atlas/specs/` — actionable specifications consumed by builders.

Specs carry frontmatter `status: draft → review → approved`; implementation
starts at `approved`. Agents flip the status as work moves but never
self-approve a spec.
