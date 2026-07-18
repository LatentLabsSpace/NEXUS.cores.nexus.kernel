# Kernel Devcontainer

Base devcontainer for `cores/nexus/kernel/`. Provides a generic Node 20 + mise +
zsh + Claude Code environment with a configurable firewall, plus an optional
`hermes` agent-harness image built on top of it.

## Build targets

`Dockerfile.base` is multi-stage. Downstream consumers pick a target:

| Target | Builds on | Contains |
|---|---|---|
| `kernel-base` | `node:20` | Generic dev environment — mise (Node 22, Python 3.12, uv), git-delta, zsh, Claude Code, the firewall script + universal `_required/` allowlists. No project-specific COPYs. |
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

Downstream projects inherit a target via compose `extends:` and Docker
`additional_contexts`:

```yaml
# compose.yml — extend the base dev environment
services:
  my-service:
    extends:
      file: cores/nexus/kernel/.devcontainer/compose.base.yml
      service: nexus-kernel-base   # or `hermes` for the agent harness
    container_name: my-service
    build:
      context: .
      dockerfile: .devcontainer/Dockerfile
      additional_contexts:
        kernel: ./cores/nexus/kernel
```

```dockerfile
# .devcontainer/Dockerfile
# syntax=docker/dockerfile:1.7
FROM kernel/.devcontainer/Dockerfile.base AS base

# Merge kernel _required/ allowlists + project-specific conf files
COPY --from=kernel .devcontainer/firewall.d/_required/ /usr/local/bin/firewall.d/_required/
COPY .devcontainer/firewall.d/ /usr/local/bin/firewall.d/

# Add project-specific entrypoint
COPY .devcontainer/entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh
```

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

`firewall.d/_required/` contains universal allowlists loaded by every downstream
regardless of `FIREWALL_MODULES` — npm, anthropic (+ sentry/statsig telemetry),
github, vscode, mise (+ pypi). These mirror the universal domain set the nexus
root's `init-firewall.sh` carries inline. Downstream projects add
project-specific `.conf` files in their own `firewall.d/` alongside these.
