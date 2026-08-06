# seed/ — the kernel wiring layer

Everything a repo needs to become a nexus kernel consumer, as templates plus a
renderer. This is the canonical form of the diff that first wired holodeck to
the published kernel; `bootstrap.sh` replays it into any repo.

Two audiences:

- **A new repo** — run `bootstrap.sh` on day zero and you have a working agent
  runtime before writing any project code.
- **An existing repo** — run the same script. Every file that already exists is
  skipped and reported, never overwritten, so a retrofit is safe and the report
  tells you exactly what to reconcile by hand.

## Usage

From the root of the target repo:

```bash
cores/nexus/kernel/seed/bootstrap.sh \
  --repo-url https://github.com/YourOrg/yourrepo.git
```

Add `--dry-run` to see the plan without writing. `--help` lists every flag.

If the kernel submodule isn't present yet, the script adds it — so you can also
run it from a standalone clone of the kernel:

```bash
git clone https://github.com/LatentLabsSpace/NEXUS-cores-nexus-kernel.git /tmp/kernel
cd /path/to/target/repo && /tmp/kernel/seed/bootstrap.sh --repo-url ...
```

## Parameters

| Flag | Default | Used for |
|---|---|---|
| `--repo-url` | *(required)* | `NEXUS_REPO_URL` in compose — the agent's first-boot clone |
| `--org` | parsed from repo URL | GitHub org, in CLAUDE.md prose |
| `--service-prefix` | repo name, lowercased | image tags (`prefix/hermes:latest`), devcontainer name |
| `--agent-name` | `<service-prefix>-hermes` | compose service, container, volume, `quarters/crew/<name>/` |
| `--kernel-url` | the published kernel | submodule source; also the compare-URL base in CLAUDE.md |

Templates additionally use `{{SERVICE_PREFIX_UPPER}}`, `{{KERNEL_URL_WEB}}`,
and `{{KERNEL_REPO_SLUG}}`, all derived — not flags. Any `{{TOKEN}}` a template
uses but `render()` doesn't substitute is reported as a warning rather than
shipped literally into the consumer repo.

## What it renders

```
compose.yml                              two services: build-only kernel + this repo's agent
.devcontainer/devcontainer.json          VS Code attach config
.devcontainer/Dockerfile                 thin layer on the kernel image
.devcontainer/firewall.d/README.md       the three-tier drop-in contract
.devcontainer/firewall.d/discord.conf    worked example drop-in
quarters/crew/<agent>/.env.template      documented per-agent credentials
quarters/crew/<agent>/.gitignore         keeps runtime state and .env out of git
quarters/README.md                       crew-state convention
CLAUDE.md                                skeleton, incl. the kernel-bump gate
atlas|codex|cargo/README.md              scaffold stubs
```

The compose + Dockerfile pair encodes the **build-only kernel service** pattern:
a `kernel-hermes` service with `deploy.replicas: 0` builds the kernel image, and
the consumer's Dockerfile does `FROM kernel-hermes-image` via a `service:`
additional context. This is the mechanism that actually works — `FROM` cannot
name a Dockerfile inside a directory context. See
[`../.devcontainer/README.md`](../.devcontainer/README.md).

## What it deliberately does not do

- **No secrets.** It renders `.env.template`; provisioning the real `.env` is a
  human step, listed in the printed checklist.
- **No CI or branch protection.** Review-gate workflows are per-repo policy.
- **No commit.** It leaves changes in the working tree for you to review.
- **No project content.** Scaffold stubs describe the convention; they don't
  presume what the repo is for.

## Changing the seed

Templates are rendered by path *and* content, so a new file just needs to be
dropped into `templates/` — no script change — unless it introduces a new
placeholder, which also needs a line in `render()`.

Before committing a change here, re-run the acceptance checks: render into a
scratch repo, run it a second time and confirm a byte-for-byte no-op, and run it
against a repo with pre-existing files and confirm they're skipped, not
clobbered. The trailing-newline sentinel in `bootstrap.sh` exists because
command substitution silently eats final newlines — keep it if you touch the
render path.
