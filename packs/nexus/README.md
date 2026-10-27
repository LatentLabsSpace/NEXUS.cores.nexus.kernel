# nexus — the org's Gas City pack

One reviewed place that says **who serves each fleet role**: the model-serving
upstreams, and the lane (harness, upstream, model, effort) every role runs on.
Every nexus city imports it, so all cities run the same fleet semantics.

It wraps the upstream gascity role set
([`gastownhall/gascity-packs` `gascity/roles`](https://github.com/gastownhall/gascity-packs/tree/main/gascity/roles),
pinned in `pack.toml`) and assigns each role a lane with pack-level patches.
Roles keep their runtime names (`<rig>/gc.design-author`, …), so the upstream
formulas that address roles by name keep working.

## Lanes

| Lane | Harness | Upstream | Model | Roles |
|---|---|---|---|---|
| build | `claude` | `fireworks` | GLM-5.3 (background: GLM-5.3 Flash) | implementation-worker, issue-triager, publisher, run-operator |
| design | `codex` | `chatgpt` | `gpt-6-sol`, effort high | requirements-planner, design-author, task-decomposer |
| review | `codex` | `chatgpt` | `gpt-6-sol`, effort high | design-implementation-reviewer, design-test-risk-reviewer, implementation-reviewer, review-synthesizer, gap-analyst |

Codex-lane roles are capped at one live session each: they spend the
ChatGPT account's weekly allowance, which every other use of that login
shares.

**Opt-in lanes.** `anthropic` is declared but assigned to no role, because
the Anthropic API is billed per token. To move a role, a city adds one patch
of its own (city patches apply after this pack's):

```toml
[[patches.agent]]
dir = "<rig>"
name = "gc.design-author"
provider = "claude"
upstream = "anthropic"
option_defaults = { model = "claude-opus-5-5", effort = "high" }   # or claude-fable-5-1
```

## Upstreams and credentials

| Upstream | Serves | Credential (controller env) |
|---|---|---|
| `fireworks` | Fireworks' Anthropic-compatible endpoint | `GASCITY_FIREWORKS_API_KEY` |
| `anthropic` | the Anthropic API | `GASCITY_ANTHROPIC_API_KEY` |
| `chatgpt` | the Codex CLI's own ChatGPT sign-in | none: run `codex login --device-auth` once in the container, and keep `~/.codex` on a volume |

- Credentials are `$VAR` references to names no harness reads, so a key
  reaches a session only through the upstream that selects it. gascity
  renders them onto each harness's own variables (`claude` gets
  `ANTHROPIC_*`, `codex` gets `OPENAI_*`). No secret lives in this pack.
- An unset credential var renders as an empty value. The session then fails
  to authenticate; nothing errors at load.
- **Supervisor-managed cities:** if the city runs under gc's own systemd or
  launchd supervisor, its service file keeps only allowlisted env names, so
  opt the keys in at install time:
  `GC_SUPERVISOR_ENV="GASCITY_FIREWORKS_API_KEY,GASCITY_ANTHROPIC_API_KEY" gc supervisor install`.
  Without that, a service restart renders the credentials empty. A container
  city running `gc start --foreground` as PID 1 (the kernel image) passes its
  own env through and needs nothing extra.
- **Harness binding workaround.** gascity v1.5.0 drops the `claude` harness's
  upstream binding when the provider is declared `base = "builtin:claude"`, so
  the two Anthropic-protocol upstreams name their target variables explicitly
  (`base_url_env`, `api_key_env`, `auth_token_env`). Upstream fix:
  gastownhall/gascity#5985.
- gascity passes ambient `ANTHROPIC_*` and `OPENAI_*` controller variables
  through to every session (and sessions inherit the controller's env
  underneath), while an upstream only overwrites the keys it renders. So every
  upstream blanks both `GASCITY_*` names and the other services' variables.
  Without that, a Fireworks session would still carry the Anthropic key, an
  Anthropic session would still point at the Fireworks base URL, and every
  session would see both raw keys. Give every agent an upstream (see below):
  an agent with none inherits the controller env unfiltered.

## Importing it in a city

Import it per rig under binding `gc` (the binding the role names and the
upstream formulas expect), pinned to a kernel shard commit:

```toml
# city.toml
[agent_defaults]
upstream = "fireworks"        # mayor, dogs and other non-role agents

[[rigs]]
name = "holodeck"

[rigs.imports.gc]
source = "https://github.com/LatentLabsSpace/NEXUS.cores.nexus.kernel/tree/main/packs/nexus"
version = "sha:<kernel shard commit>"
```

Then, in the city's own config:

- **Set `[agent_defaults] upstream`.** A pack's `agent_defaults` never reach
  other agents, so the city chooses the default for everything outside the
  role set.
- **Point both implicit `codex` agents at `chatgpt`.** Declaring the `codex`
  provider makes gc inject an implicit `codex` agent at city scope and one
  per rig (`<rig>/codex`). Without a city patch they inherit the default
  upstream, which can't serve `codex`. Patched, they are general-purpose
  Codex-subscription workers, next to the implicit `claude` ones on Fireworks:
  ```toml
  [[patches.agent]]
  name = "codex"          # city scope
  upstream = "chatgpt"

  [[patches.agent]]
  dir = "<rig>"           # one per rig
  name = "codex"
  upstream = "chatgpt"
  ```
- **Remove container-wide `ANTHROPIC_*` / `OPENAI_*` overrides** from the city's
  env, and put the `GASCITY_*` keys there instead.
- **Allow egress** to the kernel firewall `openai` module for the `chatgpt`
  upstream, besides `fireworks` and `anthropic`.

Remote imports are resolved into `packs.lock` and a local cache, not at
load. After adding or re-pinning the import, run once from the city dir:

```bash
gc import install      # resolves the pin, writes packs.lock, fills the cache
gc config show         # check: every <rig>/gc.* role shows its lane
```

Commit `packs.lock` with the city config if the city is repo-tracked. The
kernel's gascity entrypoint re-runs `gc import install` on every boot, so a
container recreate refills the cache.

Bump the pin through the normal kernel shard and consumer bump flow.

**Switching a role's lane** (a new upstream, provider or model) changes the
session's launch fingerprint, so gc relaunches it. A warm tmux respawn of an
existing session does not pick up a newly *added* credential variable; after a
lane switch, make sure the role gets a fresh session (stop it, or let it drain
and restart).
