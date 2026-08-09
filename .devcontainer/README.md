# Kernel Devcontainer

Base devcontainer for `cores/nexus/kernel/`. Provides a generic Node 22 + mise +
zsh + Claude Code environment with a configurable firewall, plus an optional
`hermes` agent-harness image built on top of it.

## Build targets

`Dockerfile.base` is multi-stage. Downstream consumers pick a target:

| Target | Builds on | Contains |
|---|---|---|
| `kernel-base` | `node:22-trixie` | Generic dev environment — mise (Node 22, Python 3.12, uv), git-delta, zsh, Claude Code, the firewall script + universal `_required/` and `_optional/` allowlists. No project-specific COPYs. Trixie is required: it ships git >= 2.41, which jj's git backend needs. |
| `beads-build` | `golang:1.26-trixie` | **Throwaway.** Compiles the `bd` CLI from the pinned beads fork. Nothing from this stage ships except the binary. |
| `beads-base` | `kernel-base` | `kernel-base` + the beads substrate: the `bd` CLI, the `dolt` engine, and `flock`. Every agent image re-parents onto this, so agent containers carry the task-graph client by construction. |
| `beads-server` | `beads-base` | The shared task graph itself — `entrypoint-beads.sh` running `dolt sql-server` over `$BEADS_DATA_DIR`. |
| `hermes-deps` | `beads-base` | `beads-base` + build toolchain (gosu, build-essential, python3-dev, libffi-dev, ripgrep) + the hermes-agent Python venv. |
| `hermes` | `hermes-deps` | Thin config layer — `entrypoint-hermes.sh`, the `hermes-entrypoint/` phase scripts, and default `config.yaml` / `SOUL.md` templates. Starts as root, drops to `node` via gosu. |
| `gascity-build` | `golang:1.26-trixie` | **Throwaway.** Compiles the `gc` CLI from the pinned gascity fork. Nothing from this stage ships except the binary. |
| `gascity` | `beads-base` | Gas City — the bead-native multi-agent orchestrator. `gc` + `entrypoint-gascity.sh` running a city against the shared beads server; bd/dolt/flock arrive from `beads-base`, tmux/jq/claude from `kernel-base`. |

`compose.base.yml` exposes four services, all consumed via `extends:`:
`nexus-kernel-base` (target `kernel-base`), `beads` (target `beads-server`),
`hermes` (target `hermes`), and `gascity` (target `gascity`).

## Standalone use

Open `cores/nexus/kernel/` in VS Code and "Reopen in Container" — the
`devcontainer.json` here drives a self-contained `nexus-kernel` service.

To build the images from the kernel directory alone — no monorepo, no
`aliens/` submodule in the context:

```bash
docker build -f .devcontainer/Dockerfile.base --target kernel-base   -t kernel-base .
docker build -f .devcontainer/Dockerfile.base --target beads-server  -t kernel-beads-server .
docker build -f .devcontainer/Dockerfile.base --target hermes        -t kernel-hermes .
docker build -f .devcontainer/Dockerfile.base --target gascity       -t kernel-gascity .
```

## hermes-agent pinning

The `hermes` target installs the
[hermes-agent](https://github.com/LatentLabsSpace/hermes-agent) harness into a
dedicated venv at `/home/node/hermes-agent`. The nexus root builds this from its
`aliens/hermes-agent` submodule via `COPY`; the kernel instead clones the public
repo at a **pinned commit**, so it builds standalone with no submodule present.

The pin lives at `.devcontainer/hermes-agent/_.jsonld` — the same version-pin
pattern the nexus root uses for the jj and flyctl binaries. To bump the harness,
edit `nexus:pinnedRef` (and `nexus:pipExtras` if the installed extras change) and
rebuild the `hermes-deps` stage.

## Beads substrate

[Beads](https://github.com/LatentLabsSpace/beads) is the kernel's shared task
graph: a Dolt-backed issue graph that multiple agent containers read and write
concurrently. `beads-base` puts the `bd` client in every agent image;
`beads-server` runs the graph.

**Why a server.** `bd`'s default is an *embedded* Dolt engine — single writer,
one process at a time. That cannot back two containers. Multi-writer means
server mode: an external `dolt sql-server` that every `bd` connects to. So the
graph is a compose service, not a directory.

### Pins

`.devcontainer/beads/_.jsonld` holds both pins:

| Tool | How it's pinned | Why |
|---|---|---|
| `bd` | full commit SHA, built from source in `beads-build` | the fork publishes no releases or tags |
| `dolt` | version + release tarball URL template (the jj/flyctl pin shape), plus a per-arch `sha256` verified at build time | upstream ships versioned binaries; the digest closes the gap a version-only pin leaves, since a re-pushed tag or swapped asset would install silently |

Dolt's floor is **>= 2.1.0** — the beads fork's docs flag that pre-1.86.2 builds
miss a GC/writer deadlock fix (dolthub/dolt `ccf7bde206`). To bump either, edit
the pin file and rebuild `beads-base`. A dolt bump means updating **both** the
version and the `nexus:sha256` digests, or the build fails at `sha256sum -c`.

`bd` builds with `make build`, which is `CGO_ENABLED=1 -tags=gms_pure_go`. CGO is
required (embedded Dolt won't open without it); `gms_pure_go` swaps
go-mysql-server's ICU-backed regex for Go's stdlib one, so the binary has **no
libicu dependency** — the fork treats this as policy (`engdocs/ICU-POLICY.md`),
which is why no ICU package is installed in either stage. A bare `go build`
without the tag fails on a missing `unicode/uregex.h` instead. The builder must
stay on the same Debian release as `kernel-base`, since cgo links `bd` against
the builder's glibc.

### Server contract

The server needs one thing from the consumer: a named volume at
`$BEADS_DATA_DIR`. Without it the graph dies with the container.

| Variable | Default | Purpose |
|---|---|---|
| `BEADS_DATA_DIR` | `/beads` | Dolt data directory — mount the named volume here |
| `BEADS_PORT` | `3307` | Port `dolt sql-server` listens on |
| `BEADS_BIND_HOST` | `0.0.0.0` | Bind address (containers need a non-loopback bind) |
| `BEADS_DOLT_PASSWORD` | _(empty)_ | Sets a root password **at first init only** |
| `BEADS_DOLT_USER_NAME` / `_EMAIL` | `beads-server` / `beads-server@nexus.local` | Dolt commit identity |

The entrypoint exports `DOLT_ROOT_HOST=%` before starting the server. Dolt
otherwise creates its root superuser as `root@localhost`, which no client
arriving over the compose network can match — the first `bd` connection fails
with "Access denied". Only read on first init; after that the grant lives in
`$BEADS_DATA_DIR/.doltcfg/privileges.db` inside the volume.

There is no `dolt init` — the data directory is served in Dolt's multi-database
mode and `bd` issues its own `CREATE DATABASE`. Initializing it would make the
directory a single database and shadow that.

### Client contract

Two equivalent ways to point `bd` at the server. Flags, at init time:

```bash
bd init --server --external \
  --server-host beads --server-port 3307 --server-user root
```

`--external` says the server is managed elsewhere, so `bd` won't try to start
one. Or environment variables, which the kernel's generic `hermes` service
already passes through:

| Variable | Default | Purpose |
|---|---|---|
| `BEADS_DOLT_SERVER_MODE` | _(empty)_ | `1` selects server mode; empty falls back to the embedded single-writer engine |
| `BEADS_DOLT_SERVER_HOST` | `beads` | Compose DNS name of the beads service |
| `BEADS_DOLT_SERVER_PORT` | `3307` | |
| `BEADS_DOLT_SERVER_USER` | `root` | |
| `BEADS_DOLT_PASSWORD` | _(empty)_ | Must match the server's, when set |

Server mode is opt-in: a consumer with no `beads` service keeps working on the
embedded engine. Two containers pointed at the same host/port and initialized
with the same prefix share one live graph — that is the whole point, and the
consumer smoke below is what proves it.

## Gas City

[Gas City](https://github.com/LatentLabsSpace/gascity) is the kernel's
bead-native multi-agent orchestrator: a *city* of tmux-hosted agent sessions
(the mayor plus per-rig agents) coordinating through beads. The `gascity`
target ships the `gc` binary on top of `beads-base`, so a city talks to the
same shared graph every other agent container does.

### Pin and build

`.devcontainer/gascity/_.jsonld` pins the fork at a full commit SHA — like the
beads fork, it publishes no releases or tags. `gc` builds in the throwaway
`gascity-build` stage with **`CGO_ENABLED=0 make build`**, the fork's own
release configuration (its `.goreleaser.yml` builds every published binary
with CGO disabled). The result is a fully static binary.

The ICU story differs from bd's on purpose: upstream docs list `libicu-dev`
as a build prerequisite, but that applies only to CGO-enabled builds — every
ICU block in the fork's Makefile is CGO plumbing, and a CGO build without ICU
headers fails on `unicode/uregex.h` (verified). With CGO off the dependency
vanishes (`ldd`: "not a dynamic executable"), so **no ICU package is
installed in either stage** — same outcome as bd's `gms_pure_go` policy,
reached by a different mechanism. `gc version --long` reports the pinned
commit (the version string is `dev`: the shallow pin checkout has no tag).

### The city service

`entrypoint-gascity.sh` follows the entrypoint-base contract (workspace clone
via `NEXUS_REPO_URL`/`NEXUS_BRANCH`, then firewall init), then:

1. `gc init` into `$GC_CITY_DIR` — non-interactive (`--template` +
   `--default-provider`), with the shared beads server pinned at init time
   via gc's hosted-Dolt flags (`--dolt-host/-port/-user/-database`). Pinning
   the endpoint is what stops gc from bootstrapping its own managed-local
   dolt server inside the container; gc records the endpoint as unverified
   and runs the live `bd init` itself at start, so the entrypoint never does.
2. `gc rig add $NEXUS_WORKSPACE` — the cloned workspace becomes the city's
   first rig (skipped until a repo is mounted or cloned).
3. `exec gc start --foreground` — the per-city controller as the container
   process, the same shape as the fork's own container images. The
   supervisor-managed `gc start` backgrounds itself, which suits a host, not
   a container. gc does not reap children, so the generic service sets
   `init: true`; keep it when extending.

Mount a named volume at `$GC_CITY_DIR` — like the beads graph without its
volume, the city dies with the container otherwise.

| Variable | Default | Purpose |
|---|---|---|
| `GC_CITY_DIR` | `/city` | City directory — mount the named volume here |
| `GC_TEMPLATE` | `gascity` | `gc init --template` value |
| `GC_DEFAULT_PROVIDER` | `claude` | Agent runtime provider (the claude CLI ships in `kernel-base`) |
| `GC_RIG_NAME` | workspace basename | Rig name for the workspace |
| `GC_DOLT_DATABASE` | `beads` | The city's beads database on the shared server |
| `GC_BEADS_PROJECT_ID` | `city` | Beads project id (gc can't derive one from a non-`bd_`-prefixed database name) |
| `BEADS_DOLT_SERVER_HOST/PORT/USER`, `BEADS_DOLT_PASSWORD` | `beads` / `3307` / `root` / _(empty)_ | Shared-server endpoint, same variables as the client contract above |

`GC_DOLT_DATABASE=beads` is deliberate: it is the same default database every
plain bd client in a beads-base container lands in, so the city and the org's
agents share one live graph with zero extra configuration. And note what is
*absent*: the service does not set `BEADS_DOLT_SERVER_MODE` — bd resolves env
before per-scope config, so a blanket server-mode env inside the city would
override the scope configs gc writes for its rigs.

`GC_BEADS` must never be set to `file` on this image — that reverts to
per-city file storage and disconnects the city from the substrate. The
entrypoint refuses to boot rather than run split-brain.

### `gc` vs oh-my-zsh

The kernel ships zsh with the oh-my-zsh `git` plugin, which aliases `gc` to
`git commit --verbose` and would shadow the binary in every interactive
shell. The image drops `unalias gc` into `~/.oh-my-zsh/custom/gascity.zsh`
(sourced after plugins), exactly as upstream's install docs recommend, so
`gc` means Gas City in this image.

## Extending in downstream projects

Don't hand-roll this — run [`seed/bootstrap.sh`](../seed/README.md), which
renders the whole wiring layer (compose, devcontainer, firewall, env template)
into a target repo. The pattern it emits is documented here so you can read
what it produced, or retrofit by hand.

A consumer needs **two** compose services: a build-only one that produces the
kernel image from the pinned submodule, and the real one that layers on top of
it via a `service:` additional context.

```yaml
# compose.yml
services:
  # Build-only. `deploy.replicas: 0` means `docker compose build` builds this
  # (before the consumer service that depends on it), but `up` never starts a
  # container for it.
  kernel-hermes:
    extends:
      file: cores/nexus/kernel/.devcontainer/compose.base.yml
      service: hermes                 # or `nexus-kernel-base`
    build:
      context: ./cores/nexus/kernel
      dockerfile: .devcontainer/Dockerfile.base
      target: hermes                  # or `kernel-base`
    image: myproject/kernel-hermes:latest
    deploy:
      replicas: 0

  my-agent:
    extends:
      file: cores/nexus/kernel/.devcontainer/compose.base.yml
      service: hermes
    # Namespace the tag. A bare `my-agent:latest` can collide with an image
    # some other compose file already owns on the operator's host, and `up`
    # will silently run that stale image instead of building this one.
    image: myproject/hermes:latest
    container_name: my-agent
    build:
      context: .
      dockerfile: .devcontainer/Dockerfile
      additional_contexts:
        kernel-hermes-image: "service:kernel-hermes"
```

```dockerfile
# .devcontainer/Dockerfile
# syntax=docker/dockerfile:1.7
#
# The base is the image built by the `kernel-hermes` compose service, handed
# to this build as a named context. Stage name must match the extended
# service's `build.target`, which carries through to this file.
FROM kernel-hermes-image AS hermes

# Project-specific drop-ins merge alongside the kernel's universal _required/
# and _optional/ sets, which are already baked into the base image.
COPY .devcontainer/firewall.d/ /usr/local/bin/firewall.d/

# Add project-specific entrypoint (optional — the kernel's is already wired)
COPY .devcontainer/entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh
```

> **Why not `FROM kernel/.devcontainer/Dockerfile.base`?** Earlier revisions of
> this README showed that form. It does not work: `FROM` takes an image
> reference or a named context that resolves to an image, never a path to a
> Dockerfile inside a directory context. Docker reports the context name as an
> unresolvable image. Building the kernel image in its own compose service and
> passing it as `service:` is the mechanism that actually works — proved out in
> the first consumer (holodeck).

## Environment variables

### `kernel-base` entrypoint (`entrypoint-base.sh`)

| Variable | Default | Purpose |
|---|---|---|
| `NEXUS_REPO_URL` | _(empty)_ | Git URL to clone on boot (if workspace not pre-mounted) |
| `NEXUS_BRANCH` | `dev` | Branch to checkout |
| `NEXUS_WORKSPACE` | `/workspace` | Target directory for clone / cd |
| `NEXUS_POST_BOOT_CMD` | _(empty)_ | Command to exec after firewall init |
| `FIREWALL_MODULES` | `all` | Comma-separated conf names to load, `all`, or `none` |
| `FIREWALL_ALLOW_LOCAL_NETWORKS` | `1` | `0` drops the container's own compose networks from the allowlist (breaks reaching sibling services) |

### `beads` service (`entrypoint-beads.sh`)

See [Beads substrate](#beads-substrate) for the server and client variable
tables and what the defaults imply.

### `gascity` service (`entrypoint-gascity.sh`)

See [Gas City](#gas-city) for the city variable table and the shared-database
wiring.

### `hermes` service (`entrypoint-hermes.sh`)

| Variable | Default | Purpose |
|---|---|---|
| `AGENT_NAME` | `hermes` | State folder under `$WORKSPACE_ROOT/quarters/crew/` |
| `HERMES_MODE` | `sleep` | Runtime mode: `gateway`, `cli`, or `sleep` (boots and waits) |
| `HERMES_WORKSPACE_PATH` | `/workspace` | Workspace root the agent operates on |
| `HERMES_AGENT_STATE_DIR` | `quarters/crew/$AGENT_NAME` | Override state root (`$WORKSPACE_ROOT`-relative) |
| `NEXUS_REPO_URL` | _(empty)_ | Repo to clone into the workspace on first boot |
| `NEXUS_TARGET_BRANCH` | `dev` | Branch the workspace bootstrap checks out |
| `HERMES_PROVIDER` / `HERMES_MODEL` | _(unset)_ | Override `model.*` in the seeded config at boot |
| `HERMES_EXTERNAL_SKILLS` | `all` | Which workspace `.claude/skills` to expose to the agent |

## Firewall drop-ins

Three tiers, resolved at boot by `init-firewall.sh`:

| Tier | Loaded | On DNS failure |
|---|---|---|
| `firewall.d/_required/` | always, ignores `FIREWALL_MODULES` | **abort the boot** |
| `firewall.d/_optional/` | always, ignores `FIREWALL_MODULES` | warn and skip |
| `firewall.d/*.conf` (consumer's own) | per `FIREWALL_MODULES` | warn and skip |

`_required/` is deliberately tiny — npm, the Anthropic API, and GitHub. Anything
there is a boot-blocker for every downstream consumer on the day its DNS
changes, which is not hypothetical: `statsig.anthropic.com` went NXDOMAIN in
July 2026 while sitting in `_required/anthropic.conf` and bricked consumer
boots until it was removed. **Default new kernel domains to `_optional/`**; only
promote to `_required/` when the container is genuinely unusable without them.

`_optional/` carries telemetry (sentry, statsig), the VS Code marketplace, and
mise/PyPI — all things whose absence degrades a workflow but not the boot.

Downstream projects add project-specific `.conf` files in their own
`firewall.d/`, which land alongside these in the image and are already
warn-and-skip. A consumer never needs to shadow a kernel conf to soften it.

### Compose-network peers

Drop-ins only describe DNS-resolvable domains. Sibling compose services — the
beads server, a database, anything reached by service alias — have no public
name and get their addresses per `docker compose up`, so the allowlist can't
express them. `init-firewall.sh` handles them separately: it reads the
container's own interfaces and allows the networks it is **actually attached
to**, in both directions.

This replaces a heuristic that was quietly wrong. The older rule allowed only
the default gateway's `/24`, but docker's default address pool hands out `/16`
subnets — so a peer at `172.20.0.x` was reachable while an otherwise identical
peer at `172.20.5.x` was dropped, presenting as a client hang. Measured on this
firewall before the fix: `172.31.0.9 -> 172.31.5.5:3307` failed with "No route
to host" while the same pair inside the gateway `/24` succeeded.

The scope is the container's own docker networks and nothing else — it opens no
host LAN and no internet, and grants nothing a same-`/24` peer didn't already
have. It is always applied (not a tier: it's a link-layer fact, not a domain)
and warns rather than aborting if the interface list can't be read. Set
`FIREWALL_ALLOW_LOCAL_NETWORKS=0` to opt out.

## Consumer smoke checklist

After a first wiring or a kernel bump, verify in the booted container:

```bash
git --version                       # must be >= 2.41 (jj's git backend floor)
jj --version                        # if the consumer installs jj
jj git fetch                        # REMOTE op — the check that catches a
                                    # too-old git; local jj commands pass fine
                                    # on 2.39 and hide the regression
claude --version                    # Claude Code present
bd version                          # beads client (any beads-base descendant)
dolt version                        # must satisfy the >= 2.1.0 floor
gc version --long                   # gascity image only — must report the
                                    # pinned commit; in zsh this also proves
                                    # the git-plugin alias is gone
sudo /usr/local/bin/init-firewall.sh # completes without ERROR
curl -sS -o /dev/null -w '%{http_code}\n' https://api.anthropic.com  # reachable
curl -sS --connect-timeout 5 https://example.com  # must FAIL (firewall closed)
```

Then the beads round-trip, **with the firewall already initialized** — this is
the step that catches a firewall that drops compose-network traffic, which
otherwise shows up as an unexplained hang:

```bash
cd "$(mktemp -d)" && git init -q .
bd init --server --external --server-host beads --server-port 3307 \
  --server-user root -p "$(basename "$PWD")" --non-interactive
bd create "kernel smoke" -t task    # write reaches the shared server
bd list                             # and reads back
```

Run the same two commands from a *second* container against the same server:
`bd list` there must show the bead the first one created. One container proves
connectivity; two prove the multi-writer path that the whole substrate exists
for.

When the consumer runs a `gascity` service, extend the round-trip to the
city — this is the check that the city actually joined the shared graph
rather than a private one:

```bash
# On the host: the city booted and runs its tmux sessions (gc uses its own
# tmux socket, so plain `tmux ls` shows nothing)
docker exec <gascity-container> gc version --long
docker exec <gascity-container> tmux -L city ls   # a mayor session exists

# Inside the gascity container, from the city dir ($GC_CITY_DIR):
bd list                                   # shows the bead the client created
bd create "city smoke" -t task            # and the client's `bd list` shows this
```

The client-side init must name the city's database explicitly:

```bash
bd init --server --external --server-host beads --server-port 3307 \
  --server-user root -p smoke --database beads --non-interactive
```

Without `--database`, bd derives a database name **from the prefix** and the
client lands in its own private graph *next to* the city's — every command
succeeds and nothing is shared, which looks exactly like success. (Same
mechanism means two plain clients only see each other when they init with the
same prefix.) `--database beads` matches the city's `GC_DOLT_DATABASE`
default.

Both directions matter: client-created beads visible in the city's bd view,
city-created beads visible from the client. That is the substrate the whole
plan exists for.

One expected warning: `gc status` logs `native_store_unavailable ... schema
version mismatch` when the fork's bd has migrated the database schema past
what gc's vendored beads library knows. Harmless — gc falls back from its
in-process store to exec'ing the (newer) bd CLI that ships in this image.

The `jj git fetch` step is load-bearing: the node:20 → node:22-trixie base bump
exists because a bookworm base shipped git 2.39.5, and every *local* jj command
worked normally — only remote ops failed, so an ordinary boot smoke missed it
entirely.
