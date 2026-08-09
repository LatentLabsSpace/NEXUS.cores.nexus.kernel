#!/usr/bin/env bash
#
# Seed a repo with the nexus kernel wiring layer.
#
# Pure shell — no Claude, no network beyond `git submodule`. Idempotent and
# retrofit-safe: every file that already exists is SKIPPED and reported, never
# overwritten, so this is safe to run against a repo that already has a
# compose.yml or a CLAUDE.md.
#
# Run from the root of the target repo:
#
#   cores/nexus/kernel/seed/bootstrap.sh \
#     --repo-url https://github.com/YourOrg/yourrepo.git
#
# See --help for the full parameter list.

set -euo pipefail

KERNEL_PATH="cores/nexus/kernel"
DEFAULT_KERNEL_URL="https://github.com/LatentLabsSpace/NEXUS.cores.nexus.kernel.git"

SEED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SEED_DIR/templates"

ORG=""
REPO_URL=""
AGENT_NAME=""
SERVICE_PREFIX=""
KERNEL_URL="$DEFAULT_KERNEL_URL"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: bootstrap.sh --repo-url <url> [options]

Renders the nexus kernel wiring layer into the current repo: compose.yml,
.devcontainer/ (devcontainer.json, Dockerfile, firewall drop-ins), the
per-agent .env template, a CLAUDE.md skeleton, and atlas/codex/quarters/cargo
scaffold stubs. Adds the kernel submodule at cores/nexus/kernel if missing.

Required:
  --repo-url <url>        Git URL of THIS repo. Baked into compose.yml as
                          NEXUS_REPO_URL for the agent's first-boot clone.

Optional (derived from --repo-url when omitted):
  --org <name>            GitHub org that owns this repo.
  --service-prefix <name> Image-tag / devcontainer namespace. Default: repo name.
  --agent-name <name>     Compose service, container, volume, and crew state
                          folder. Default: <service-prefix>-hermes.
  --kernel-url <url>      Kernel shard URL for the submodule.
                          Default: the published kernel.
  --dry-run               Report what would be created; write nothing.
  -h, --help              This message.

Existing files are always skipped, never overwritten. Re-running is a no-op.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --org)            ORG="${2:-}"; shift 2 ;;
    --repo-url)       REPO_URL="${2:-}"; shift 2 ;;
    --agent-name)     AGENT_NAME="${2:-}"; shift 2 ;;
    --service-prefix) SERVICE_PREFIX="${2:-}"; shift 2 ;;
    --kernel-url)     KERNEL_URL="${2:-}"; shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                usage >&2; die "unknown argument: $1" ;;
  esac
done

# ─── Preconditions ───────────────────────────────────────────────────────────

[ -d "$TEMPLATE_DIR" ] || die "template directory not found at $TEMPLATE_DIR"
command -v git >/dev/null 2>&1 || die "git is required"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "not a git repository — run this from the root of the target repo"

REPO_ROOT="$(git rev-parse --show-toplevel)"
[ "$REPO_ROOT" = "$PWD" ] \
  || die "run this from the repo root ($REPO_ROOT), not $PWD"

[ -n "$REPO_URL" ] || { usage >&2; die "--repo-url is required"; }

# ─── Parameter derivation ────────────────────────────────────────────────────

# github.com/Org/repo(.git) — over ssh or https — into "Org" and "repo".
repo_slug="$(printf '%s' "$REPO_URL" | sed -E 's#^.*[/:]([^/]+/[^/]+)$#\1#; s#\.git$##')"
[ -n "$ORG" ]            || ORG="${repo_slug%%/*}"
[ -n "$SERVICE_PREFIX" ] || SERVICE_PREFIX="$(printf '%s' "${repo_slug##*/}" | tr '[:upper:]' '[:lower:]')"
[ -n "$AGENT_NAME" ]     || AGENT_NAME="${SERVICE_PREFIX}-hermes"

# Docker object names (service, container, volume) share this charset.
printf '%s' "$AGENT_NAME" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$' \
  || die "--agent-name '$AGENT_NAME' is not a valid docker object name"
printf '%s' "$SERVICE_PREFIX" | grep -qE '^[a-z0-9][a-z0-9_.-]*$' \
  || die "--service-prefix '$SERVICE_PREFIX' must be lowercase alphanumeric"

SERVICE_PREFIX_UPPER="$(printf '%s' "$SERVICE_PREFIX" | tr '[:lower:]-' '[:upper:]_')"
KERNEL_URL_WEB="$(printf '%s' "$KERNEL_URL" | sed -E 's#\.git$##; s#^git@github\.com:#https://github.com/#')"
KERNEL_REPO_SLUG="$(printf '%s' "$KERNEL_URL_WEB" | sed -E 's#^.*[/:]([^/]+/[^/]+)$#\1#')"

# ─── Rendering ───────────────────────────────────────────────────────────────

# Bash string replacement rather than sed: values contain slashes and colons,
# and this way there is no delimiter to escape.
render() {
  local s="$1"
  s="${s//'{{ORG}}'/$ORG}"
  s="${s//'{{REPO_URL}}'/$REPO_URL}"
  s="${s//'{{AGENT_NAME}}'/$AGENT_NAME}"
  s="${s//'{{SERVICE_PREFIX}}'/$SERVICE_PREFIX}"
  s="${s//'{{SERVICE_PREFIX_UPPER}}'/$SERVICE_PREFIX_UPPER}"
  s="${s//'{{KERNEL_URL_WEB}}'/$KERNEL_URL_WEB}"
  s="${s//'{{KERNEL_REPO_SLUG}}'/$KERNEL_REPO_SLUG}"
  printf '%s' "$s"
}

created=()
skipped=()
unrendered=()

while IFS= read -r -d '' src; do
  rel="${src#"$TEMPLATE_DIR"/}"
  dst="$(render "$rel")"

  if [ -e "$dst" ]; then
    skipped+=("$dst")
    continue
  fi

  created+=("$dst")
  [ "$DRY_RUN" -eq 1 ] && continue

  mkdir -p "$(dirname "$dst")"
  # Trailing newlines survive the round-trip: $(...) strips them, so a
  # sentinel byte is appended before capture and removed after.
  body="$(cat "$src"; printf 'x')"
  body="${body%x}"
  # Sentinel again: this capture would otherwise strip the trailing newline
  # that the one above just went to the trouble of preserving.
  rendered="$(render "$body"; printf 'x')"
  rendered="${rendered%x}"

  # A template carrying a token render() doesn't know about would otherwise
  # ship a literal {{...}} into the consumer repo. Catch it here rather than
  # letting someone discover it in a committed compose.yml.
  case "$rendered$dst" in
    *'{{'*) unrendered+=("$dst") ;;
  esac

  printf '%s' "$rendered" > "$dst"
done < <(find "$TEMPLATE_DIR" -type f -print0 | sort -z)

# ─── Kernel submodule ────────────────────────────────────────────────────────

submodule_note=""
if [ -e "$KERNEL_PATH/.devcontainer/Dockerfile.base" ]; then
  submodule_note="already present at $KERNEL_PATH"
elif git config -f .gitmodules --get "submodule.$KERNEL_PATH.url" >/dev/null 2>&1; then
  submodule_note="registered but not checked out — running submodule update"
  [ "$DRY_RUN" -eq 1 ] || git submodule update --init "$KERNEL_PATH"
else
  submodule_note="added from $KERNEL_URL"
  [ "$DRY_RUN" -eq 1 ] || git submodule add "$KERNEL_URL" "$KERNEL_PATH"
fi

# ─── Report ──────────────────────────────────────────────────────────────────

echo
[ "$DRY_RUN" -eq 1 ] && echo "DRY RUN — nothing was written." && echo

echo "Parameters"
printf '  %-22s %s\n' \
  "org"            "$ORG" \
  "repo-url"       "$REPO_URL" \
  "service-prefix" "$SERVICE_PREFIX" \
  "agent-name"     "$AGENT_NAME" \
  "kernel"         "$submodule_note"
echo

if [ "${#created[@]}" -gt 0 ]; then
  echo "Created (${#created[@]})"
  printf '  + %s\n' "${created[@]}"
  echo
fi

if [ "${#skipped[@]}" -gt 0 ]; then
  echo "Skipped — already exist, left untouched (${#skipped[@]})"
  printf '  = %s\n' "${skipped[@]}"
  echo
  echo "  Reconcile these by hand if they predate the kernel wiring: compare"
  echo "  each against $TEMPLATE_DIR/ and merge in what you want."
  echo
fi

if [ "${#created[@]}" -eq 0 ]; then
  echo "Nothing to do — this repo is already seeded."
  echo
fi

if [ "${#unrendered[@]}" -gt 0 ]; then
  echo "WARNING — these files still contain a literal {{TOKEN}} (${#unrendered[@]})"
  printf '  ! %s\n' "${unrendered[@]}"
  echo "  A seed template uses a placeholder bootstrap.sh does not substitute."
  echo "  Fix render() in $0, then delete the files above and re-run."
  echo
fi

cat <<EOF
Next steps — none of these are scriptable, all of them are required:

  1. Credentials. Copy the template and fill it in:
       cp quarters/crew/$AGENT_NAME/.env{.template,}
     Then set GH_TOKEN and ANTHROPIC_API_KEY from your secret store. Prefer
     dedicated ${SERVICE_PREFIX_UPPER}_-prefixed credentials over personal ones, so a
     sandboxed agent cannot spend your budget or push as you. The .env is
     gitignored — never commit it, never paste values into chat.

  2. Firewall. Review .devcontainer/firewall.d/. A discord.conf drop-in ships
     as the worked example; delete it if this agent has no Discord surface,
     and add a .conf per external service this repo actually calls.

  3. Review gate. Add the CI workflows this repo should merge through
     (.github/workflows/) and set branch protection on dev. The kernel does not
     supply these — they are per-repo policy.

  4. Build and smoke:
       git submodule update --init
       docker compose build $AGENT_NAME && docker compose up -d $AGENT_NAME
     Then run the consumer smoke checklist in
     $KERNEL_PATH/.devcontainer/README.md — including a jj remote
     operation, which is the check that catches a too-old git in the base.

  5. CLAUDE.md. The seeded file is a skeleton with placeholder prose. Replace
     the map and purpose with this repo's reality; keep the "Nexus kernel"
     section — its compare-URL rule is the supply-chain gate on kernel bumps.
EOF
