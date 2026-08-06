# Firewall drop-ins — {{SERVICE_PREFIX}}

The devcontainer runs a strict default-DROP outbound firewall. Reaching any
host not on the allowlist fails with an ICMP reject. This directory holds
**this repo's** project-specific allowlists.

## Tiers

The kernel resolves three tiers at boot (`init-firewall.sh`):

| Tier | Where | Loaded | On DNS failure |
|---|---|---|---|
| Required | kernel `firewall.d/_required/` | always | **aborts the boot** |
| Optional | kernel `firewall.d/_optional/` | always | warn and skip |
| Project | **this directory** | per `FIREWALL_MODULES` | warn and skip |

The kernel tiers are baked into the base image and cover npm, the Anthropic
API, GitHub, VS Code marketplace, mise/PyPI, and Claude Code telemetry. You do
not need to repeat any of them here.

Project drop-ins are already warn-and-skip, so **never shadow a kernel conf**
just to soften its failure behavior. If a kernel `_required/` domain is
wrong for everyone, fix it upstream in the kernel and bump the submodule.

## Adding a domain

Create a `<module>.conf` file with one domain per line; `#` starts a comment:

```
# What this service is for, and which code path needs it.
api.example.com
cdn.example.com
```

Then rebuild — drop-ins are copied into the image, not read from the mount:

```bash
docker compose build {{AGENT_NAME}} && docker compose up -d {{AGENT_NAME}}
```

## Selecting modules

`FIREWALL_MODULES` (set in `quarters/crew/{{AGENT_NAME}}/.env`) controls which
files here load:

| Value | Effect |
|---|---|
| unset or `all` | load every `.conf` in this directory (default) |
| `discord,fly` | load only the named modules (no `.conf` suffix) |
| `none` | load no project drop-ins |

The kernel's required and optional tiers load regardless of this setting.

## Wildcards are not supported

Allowlisting is IP-based: each domain is resolved with `dig` at boot and its A
records are added to an ipset. A CDN that rotates IPs faster than the boot
window will intermittently fail even when listed — prefer a stable hostname, or
route that traffic through a sibling service outside the firewall.
