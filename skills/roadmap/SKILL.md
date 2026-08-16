---
name: roadmap
description: Manage a beads-native roadmap on the org's shared task graph — create a roadmap from operator goals, decompose them into gated phases and dispatchable leaf tasks, report progress, and keep execution focused. Use when a user asks to create or update a roadmap, plan or sequence goals/milestones/phases, decompose objectives into tasks, ask "what's next" / "what's ready" / "what's blocking", review roadmap status, or sign off on a phase. Also use in channels dedicated to roadmap discussion. Works wherever the bd CLI and a beads server are available.
---

# /roadmap — Beads-Native Roadmap Management

Turn goals that humans state into a live dependency graph on the org's shared
beads server: phases as gated epics, work as dispatchable leaf tasks, progress
read back from the graph itself. The graph is execution truth; repo files are
specs; rendered views are disposable.

## Ground rules

1. **Never invent roadmap content.** Goals, priorities, scope calls, and
   creative direction come from humans. You contribute *structure* —
   decomposition, dependencies, acceptance criteria drafts — and you flag
   gaps instead of filling them.
2. **Confirm before apply.** Propose the phase/leaf breakdown in
   conversation; apply it to the graph only after a human confirms. One
   atomic graph apply, not incremental dribble.
3. **Defer to the binary on syntax.** `bd prime` and `bd <cmd> --help` are
   authoritative; ecosystem docs drift. When this file and the binary
   disagree, the binary wins.

## 1. Resolve the target root and its binding

The roadmap's identity is anchored in the repo tree, not in this skill:

- Target root = explicit argument → `$CONTEXT_ROOT` env → workspace root.
- Read `<root>/_.jsonld` and look for a roadmap binding:

```json
"nexus:roadmapBead": "hd-a1b2",
"nexus:roadmapDatabase": "beads",
"nexus:roadmapPrefix": "hd"
```

- **Binding present** → operate on that epic's subtree. Everything below
  scopes to it.
- **Binding absent (or bound epic has no children)** → first-run flow (§3).

Separate roots hold separate roadmaps in the same database (e.g. a studio
root and per-title roots like `codex/games/olympus`) — each root's binding
names its own root epic.

## 2. Join the shared graph

`bd` picks its database from the nearest `.beads/` above your cwd — the
directory tree is the router.

- Prefer an **existing client dir**: `cd` to the directory whose `.beads/`
  matches the binding's database (after a Gas City rig attach, the workspace
  root itself is that client). `bd where` confirms what you resolved.
- Only when no client exists, create one (endpoint values come from the
  `BEADS_DOLT_SERVER_*` env baked into agent containers):

```bash
bd init --server --external \
  --server-host "$BEADS_DOLT_SERVER_HOST" --server-port "${BEADS_DOLT_SERVER_PORT:-3307}" \
  --server-user "${BEADS_DOLT_SERVER_USER:-root}" \
  --database <db-from-binding-or-org-convention> -p <prefix> --non-interactive
```

- **Always name the database explicitly.** Without `--database`, bd derives a
  database from the prefix and every command fake-succeeds in a private graph
  nobody else can see. Never rely on prefix-derived databases.
- No server env and no server reachable → bd falls back to a local embedded
  engine. Fine for solo experiments; say so out loud, because nothing you
  write there is shared.

## 3. First-run: create a roadmap

When the root has no binding (or an empty roadmap):

1. **Elicit.** Ask the humans present for the goals/objectives this roadmap
   should carry. Do not seed placeholders.
2. **Propose.** Draft the structure (per §4) and show it: phases, leaves,
   dependencies, gates. Iterate until confirmed.
3. **Apply once.** Emit a single `bd create --graph plan.json` covering the
   root epic, phases, leaves, and edges — see
   [references/graph-plan.md](references/graph-plan.md) for the JSON
   contract, a worked example, and its traps.
4. **Write the binding back.** Merge the three `nexus:roadmap*` properties
   into `<root>/_.jsonld` (create a minimal file if the directory has none),
   using the root-epic id from the apply's key→ID map.

## 4. Modeling contract

- **Root epic** — the roadmap itself (from the binding).
- **Phases** = `epic` nodes under the root, each **blocked by a `human`
  gate** (§5) until sign-off, with explicit `blocks` edges expressing phase
  order. Label every phase `roadmap` + `phase:<n>`.
- **Leaves** = `task` / `feature` / `bug` nodes under their phase, each with
  `acceptance_criteria`, a priority, and the `roadmap` label. A leaf too
  unknown to decompose honestly stays ONE leaf whose body says what must be
  discovered — never a fake subtree. (City agents can expand it later with
  `gc formula cook --attach`.)
- **Unrouted by default.** Never set `assignee` or routing metadata at
  authoring time. Stamp delegation *intent* only, as a label:
  `owner:human` or `delegate:city`. Routing (who actually picks it up) is a
  separate, deliberate act — nothing is auto-dispatched.
- **Ordering lives on edges.** `blocks` between beads is the only sequencing
  the graph respects. Titles, priorities, and phase numbers order nothing.
- **Never ephemeral.** Roadmap structure is permanent beads — no wisps, no
  `--ephemeral` (they are garbage-collected).

## 5. Phase gates

One `human` gate blocking a phase epic hides the phase's **entire subtree**
from every ready-work query (parent-child inherits blocked state
transitively), and one resolve releases it atomically:

```bash
bd gate create --type=human --blocks <phase-epic> --reason "Sign-off: <phase>"
bd gate list                          # open gates (hidden from bd list by default)
bd gate resolve <gate-id> --reason "Approved by <who> <date>"
```

Gates notify nobody by themselves — when you create one, tell the human it
exists and what it's waiting on.

## 6. Report

All scoped to the bound root epic:

```bash
bd ready --parent <root>              # what can start right now
bd ready --parent <root> --explain    # …and why / why not
bd blocked                            # what waits, naming each blocker
bd epic status --json                 # per-phase completion
bd list --parent <root> --tree        # the whole roadmap as a tree
bd dep tree <root> --format=mermaid   # render source for views
```

Nuance: a bead claimed/hooked by a worker session shows as neither ready nor
in_progress — cross-check `bd list --status in_progress` before declaring
anything stalled. Rendered views are generated artifacts — mark them as
such; never hand-edit them and never treat a markdown file as the roadmap.

**Read the recorded content before advising — structure is not state.**
Every verb above returns graph *shape* (status, assignee, edges, titles).
The *content* of the work — what a human already decided, posted, or
finished — lives in the bead's comments and description, and ingest
pipelines write it there. So when a status answer names a bead as the
blocker or the next move ("everything funnels through X"), you MUST run
`bd comments <id> --json` (and `bd show <id> --json`) on that bead and
build the advice on what is recorded there, e.g. "the layout is recorded
on hd-b12 as of Aug 14 — what remains is decomposing it into follow-on
tasks", not "if you've made the decisions already, write them down".
Two corollaries: (1) hedged advice that would be wrong if the bead's
comments were read is a bug in your answer, not a safe default; (2) the
next step comes from the bead's own acceptance criteria and recorded
notes — never invent a deliverable (a doc, a path, a format) the bead
does not name. Corollary of the studio no-fabrication rule.
Cheap way to stay honest: before answering "what's next / what's
blocking", read the comments of every bead you are about to name.

## 7. Maintain

- Work lifecycle: `bd update <id> --claim` → notes as you go (`bd note`) →
  `bd close <id> --reason "PR #NN"`. The bead is status truth while work is
  in flight; repo task files flip in the PR that closes the work.
- **Epics never auto-close.** Sweep with `bd epic close-eligible [--dry-run]`
  or completed phases pile up as open-but-done and block reporting.
- `bd update`, never `bd edit` (it opens an interactive editor).
- `--json` on anything you parse. `--stdin`/`--body-file` for prose with
  quotes or backticks.

## 8. Dispatch — how leaves become agent work (city-side, informational)

Gas City pools only see work that is **ready, routed, and not an epic**
(`--exclude-type=epic` is baked into their queries; `gc sling` rejects
epics). This skill deliberately creates leaves unrouted; dispatch happens
city-side: a mayor/human runs `gc sling <rig>/<target> <bead-id>`, or sets
an assignee, per the org's delegation policy. If asked to route from a
container that has no `gc`, say so — routing is not this skill's job.

## Trap list (each of these fake-succeeds or silently hides work)

1. `bd init` without `--database` → private graph, everything "works".
2. Graph-apply nodes inherit **nothing** — stamp labels/metadata/priority on
   every node ([references/graph-plan.md](references/graph-plan.md)).
3. Timestamps in graph JSON are RFC3339 only — relative forms are rejected.
4. An epic with an unresolved gate hides its whole subtree — that's a
   feature, but report gates explicitly or the roadmap "looks empty".
5. Closing an epic with open children is refused; closing a *task* with
   children silently orphans them.
6. `bd edit` hangs agents (interactive $EDITOR).
7. Wisps/ephemeral beads vanish on GC — never roadmap structure.
8. A bead in another database/prefix is invisible, not absent — check
   `bd where` before concluding anything is missing.
9. Report verbs show shape, not content — advising on a bead without
   reading its comments produces confident, stale guidance (a decision
   already recorded on the bead gets asked for again).
