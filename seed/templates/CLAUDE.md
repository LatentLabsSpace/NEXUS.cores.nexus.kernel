# {{SERVICE_PREFIX}} — agent conventions

<!-- Seeded from the nexus kernel (cores/nexus/kernel/seed). Replace the
     placeholder prose below with this repo's actual purpose and map; keep the
     "Nexus kernel" section — it encodes the supply-chain gate. -->

One-line statement of what this repo is.

The layout follows the Nexus organization convention: **`atlas/` holds
knowledge**, **`codex/` holds code**, `quarters/` holds agent crew state, and
`cargo/` holds working artifacts.

## Map

- `atlas/` — specs, concepts, roadmap. Human-owned knowledge.
- `codex/` — code. Each project is self-contained; its own `CLAUDE.md` is
  authoritative for work inside it.
- `quarters/` — agent crew state (`quarters/crew/{{AGENT_NAME}}/`); see
  `quarters/README.md`. The agent runtime is wired in `compose.yml` +
  `.devcontainer/` at the repo root.
- `cargo/` — working artifacts, scratch output, session workspaces.
- `cores/nexus/kernel/` — the nexus kernel, a pinned git submodule (see below).

## Nexus kernel (submodule)

This repo's agent runtime extends the published nexus kernel
([{{KERNEL_REPO_SLUG}}]({{KERNEL_URL_WEB}})),
pinned as a git submodule at `cores/nexus/kernel/`. The kernel supplies the
devcontainer base image, the hermes agent harness, and the universal firewall
allowlists; this repo layers only its own firewall drop-ins and compose wiring
on top (`compose.yml`, `.devcontainer/`). After cloning, run
`git submodule update --init` once.

**Kernel-bump convention (supply-chain chokepoint).** A PR that moves the
submodule pointer MUST include the shard compare URL in its description:

    {{KERNEL_URL_WEB}}/compare/<old-sha>...<new-sha>

The bump PR is the only gate where new kernel code enters this repo, so the
reviewer must be able to read the full upstream diff from the PR itself. Bumps
with no compare URL don't merge.

After bumping, re-run the consumer smoke checklist in
`cores/nexus/kernel/.devcontainer/README.md` — in particular a jj remote
operation, which is the check that catches a too-old git in the base image.

## Secrets

- **Never read `.env` directly** — not with `Read`, `cat`, `grep`, or `source`.
- **Never run `env` / `printenv` / `set`** in ways that dump secret-bearing
  variables into conversation context, including pattern-greps: a filter like
  `env | grep {{SERVICE_PREFIX_UPPER}}` sweeps up tokens along with config.
- Per-agent credentials live in `quarters/crew/{{AGENT_NAME}}/.env`, which is
  gitignored. The checked-in `.env.template` next to it documents every key.
- **Never ask a user to paste a secret value into chat** — direct them to edit
  the `.env` file directly.

## Firewall

The devcontainer runs a strict default-DROP outbound firewall. To allow a new
domain, add a `.conf` drop-in under `.devcontainer/firewall.d/` and rebuild —
see `.devcontainer/firewall.d/README.md`. Never shadow a kernel `_required/`
conf to soften it; fix it upstream and bump the submodule.

## Pull requests

This repo is owned by the `{{ORG}}` GitHub org and merges to `dev`. Work goes
through a PR — direct pushes to `dev` are for deliberate operator reverts only.
A PR is not ready while its review gate is red; fix the blockers rather than
merging past them.

## Document status conventions

When working from a spec or task, update its frontmatter `status` field to
reflect the current state (`draft → in-progress → review → done`) when the work
materially changes it.

## Conventions that emerge

If a new convention forms during a session (new directory purpose, new file
format, new linking pattern), update this file so future sessions inherit it.
