# `bd create --graph` — the atomic graph-apply contract

One JSON file creates an entire bead graph atomically: nodes with symbolic
keys, parent-child structure, typed dependency edges, per-node fields. The
apply returns a `{"ids": {"<key>": "<minted-id>"}}` map — capture it; the
binding write-back and any follow-up wiring need it.

```bash
bd create --graph plan.json --dry-run   # validate structure first, always
bd create --graph plan.json --json      # apply once; returns the key→ID map
```

**Not idempotent.** Re-applying the same file duplicates every node. The
JSON is a one-shot input, stale the moment it runs — do not commit it as if
it were the roadmap (the graph is the roadmap). A copy may be kept as a
worked example only.

## Shape

```json
{
  "commit_message": "roadmap: <what this apply does>",
  "nodes": [
    {
      "key": "root",
      "title": "<Roadmap title — from the humans>",
      "type": "epic",
      "priority": 1,
      "labels": ["roadmap"],
      "description": "Roadmap root. Binding lives at <root>/_.jsonld."
    },
    {
      "key": "p1",
      "title": "Phase 1: <phase goal>",
      "type": "epic",
      "parent_key": "root",
      "priority": 1,
      "labels": ["roadmap", "phase:1"]
    },
    {
      "key": "p1.first-leaf",
      "title": "<Concrete, completable unit of work>",
      "type": "task",
      "parent_key": "p1",
      "priority": 1,
      "labels": ["roadmap", "phase:1", "delegate:city"],
      "acceptance_criteria": "<how a worker self-validates done>",
      "description": "<what and why; pointers to specs>"
    },
    {
      "key": "p2",
      "title": "Phase 2: <phase goal>",
      "type": "epic",
      "parent_key": "root",
      "priority": 2,
      "labels": ["roadmap", "phase:2"]
    }
  ],
  "edges": [
    {"from_key": "p2", "to_key": "p1", "type": "blocks"}
  ]
}
```

## Field notes

- `key` — plan-local symbolic name; free-form; returned in the ID map.
  Minted IDs are flat (`hd-a1b2`), NOT hierarchical dotted ids.
- `parent_key` / `parent_id` — creates the parent-child edge (hierarchy +
  transitive blocked-state inheritance). Use `parent_id` to attach into an
  EXISTING roadmap (e.g. new phase under the bound root epic's real id).
- `edges[]` — `{"from_key", "to_key", "type"}` where **from depends on to**
  (`p2` blocks-on `p1` above). Types that gate readiness: `blocks`,
  `waits-for`, `conditional-blocks`. `related`/`tracks` annotate only.
- Every field `bd create` accepts works per node (`description`,
  `acceptance_criteria`, `estimate`, `metadata`, initial `status`, …).

## The three graph-mode traps

1. **No inheritance.** Unlike interactive `bd create --parent`, graph nodes
   inherit NOTHING from parents — stamp `labels`, `priority`, and metadata
   explicitly on every node or they land bare.
2. **RFC3339 timestamps only.** `--due`-style relative forms (`+6h`,
   `tomorrow`) are rejected in graph JSON.
3. **Gates don't have a node type shortcut here** — create phase gates as a
   follow-up step from the ID map:

```bash
bd gate create --type=human --blocks <phase-id-from-map> --reason "Sign-off: Phase 1"
```

## Post-apply verification (do this every time)

```bash
bd list --parent <root-id> --tree     # structure landed as proposed
bd ready --parent <root-id>           # ready set = exactly the ungated,
                                      #   unblocked leaves you expect
bd blocked | head -20                 # everything else, naming its blocker
```

If the ready set surprises you, check edge direction first — a reversed
`blocks` edge inverts the schedule and both directions "apply" fine.

## Binding write-back

Merge into `<root>/_.jsonld` (create the file if absent):

```json
"nexus:roadmapBead": "<root id from the map>",
"nexus:roadmapDatabase": "<database>",
"nexus:roadmapPrefix": "<prefix>"
```
