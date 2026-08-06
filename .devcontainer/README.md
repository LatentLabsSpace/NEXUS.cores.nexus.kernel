# Kernel Devcontainer

Base devcontainer for `cores/nexus/kernel/`. Provides a generic Node 22 + mise +
zsh + Claude Code environment with a configurable firewall, plus an optional
`hermes` agent-harness image built on top of it.

## Build targets

`Dockerfile.base` is multi-stage. Downstream consumers pick a target:

| Target | Builds on | Contains |
|---|---|---|
| `kernel-base` | `node:22-trixie` | Generic dev environment — mise (Node 22, Python 3.12, uv), git-delta, zsh, Claude Code, the firewall script + universal `_required/` and `_optional/` allowlists. No project-specific COPYs. Trixie is required: it ships git >= 2.41, which jj's git backend needs. |
| `hermes-deps` | `kernel-base` | `kernel-base` + build toolchain (gosu, build-essential, python3-dev, libffi-dev, ripgrep) + the hermes-agent Python venv. |
| `hermes` | `hermes-deps` | Thin config layer — `entrypoint-hermes.sh`, the `hermes-entrypoint/` phase scripts, and default `config.yaml` / `SOUL.md` templates. Starts as root, drops to `node` via gosu. |

`compose.base.yml` exposes two services, both consumed via `extends:`:
`nexus-kernel-base` (target `kernel-base`) and `hermes` (target `hermes`).

## Standalone use

Open `cores/nexus/kernel/` in VS Code and "Reopen in Container" — the
`devcontainer.json` here drives a self-contained `nexus-kernel` service.

To build the images from the kernel directory alone — no monorepo, no
`aliens/` submodule in the context:

```bash
docker build -f .devcontainer/Dockerfile.base --target kernel-base -t kernel-base .
docker build -f .devcontainer/Dockerfile.base --target hermes      -t kernel-hermes .
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
| `NEXUS_BRANCH` | `main` | Branch to checkout |
| `NEXUS_WORKSPACE` | `/workspace` | Target directory for clone / cd |
| `NEXUS_POST_BOOT_CMD` | _(empty)_ | Command to exec after firewall init |
| `FIREWALL_MODULES` | `all` | Comma-separated conf names to load, `all`, or `none` |

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

## Consumer smoke checklist

After a first wiring or a kernel bump, verify in the booted container:

```bash
git --version                       # must be >= 2.41 (jj's git backend floor)
jj --version                        # if the consumer installs jj
jj git fetch                        # REMOTE op — the check that catches a
                                    # too-old git; local jj commands pass fine
                                    # on 2.39 and hide the regression
claude --version                    # Claude Code present
sudo /usr/local/bin/init-firewall.sh # completes without ERROR
curl -sS -o /dev/null -w '%{http_code}\n' https://api.anthropic.com  # reachable
curl -sS --connect-timeout 5 https://example.com  # must FAIL (firewall closed)
```

The `jj git fetch` step is load-bearing: the node:20 → node:22-trixie base bump
exists because a bookworm base shipped git 2.39.5, and every *local* jj command
worked normally — only remote ops failed, so an ordinary boot smoke missed it
entirely.
