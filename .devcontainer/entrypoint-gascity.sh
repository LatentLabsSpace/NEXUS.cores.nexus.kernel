#!/bin/bash
set -euo pipefail

echo "=== gascity entrypoint ==="

WORKSPACE="${NEXUS_WORKSPACE:-/workspace}"
REPO_URL="${NEXUS_REPO_URL:-}"
BRANCH="${NEXUS_BRANCH:-dev}"
CITY_DIR="${GC_CITY_DIR:-/city}"

# The whole point of this image is the bd provider against the org's shared
# beads server. GC_BEADS=file silently reverts to per-city file storage and
# disconnects the city from the substrate — refuse to boot that way rather
# than run split-brain. (Unset is correct: bd is gc's native default.)
if [ "${GC_BEADS:-}" = "file" ]; then
  echo "ERROR: GC_BEADS=file disconnects the city from the shared beads server;" \
       "unset it (bd is the default provider) or use a different image" >&2
  exit 1
fi

# --- Repo bootstrap (entrypoint-base contract) ---
if [ -n "$REPO_URL" ] && [ ! -d "$WORKSPACE/.git" ]; then
  echo "Cloning repo (branch: $BRANCH) to $WORKSPACE..."
  git clone --branch "$BRANCH" "$REPO_URL" "$WORKSPACE"
  cd "$WORKSPACE"
  git submodule update --init --recursive
fi

# --- Firewall ---
echo "Initializing firewall..."
sudo /usr/local/bin/init-firewall.sh

# --- City init ---
# Server endpoint: the kernel's documented beads client contract
# (BEADS_DOLT_SERVER_*), handed to gc's hosted-Dolt init flags. Pinning the
# endpoint at init time is what stops gc from bootstrapping its own
# managed-local dolt server inside the container; gc records it as unverified
# and runs the live `bd init` itself at start, so the entrypoint never has to.
#
# The database defaults to "beads" — the same database every plain bd client
# in a beads-base container lands in by default — so the city and the org's
# agents share one live graph out of the box. gc can't derive a project id
# from a non-"bd_"-prefixed database name, so one is always passed explicitly.
BEADS_HOST="${BEADS_DOLT_SERVER_HOST:-beads}"
BEADS_PORT="${BEADS_DOLT_SERVER_PORT:-3307}"
BEADS_USER="${BEADS_DOLT_SERVER_USER:-root}"
GC_DATABASE="${GC_DOLT_DATABASE:-beads}"
GC_PROJECT_ID="${GC_BEADS_PROJECT_ID:-city}"

if [ ! -f "$CITY_DIR/city.toml" ]; then
  echo "Initializing city at $CITY_DIR (beads server: ${BEADS_HOST}:${BEADS_PORT}, db: ${GC_DATABASE})"
  # --no-start: no supervisor here — the container runs the per-city
  # controller in the foreground below, the same shape as the fork's own
  # container images. --skip-provider-readiness so the city boots before
  # any provider credentials are configured (agents wait; the substrate
  # doesn't) — same philosophy as hermes' default sleep mode.
  gc init \
    --template "${GC_TEMPLATE:-gascity}" \
    --default-provider "${GC_DEFAULT_PROVIDER:-claude}" \
    --dolt-host "$BEADS_HOST" \
    --dolt-port "$BEADS_PORT" \
    --dolt-user "$BEADS_USER" \
    --dolt-database "$GC_DATABASE" \
    --dolt-project-id "$GC_PROJECT_ID" \
    --skip-provider-readiness \
    --no-start \
    "$CITY_DIR"
fi

# --- Rig the workspace ---
# Registered separately from the init branch so a rig-add that failed on a
# previous boot is retried instead of silently skipped. gc appends rigs to
# city.toml; the name check keeps this idempotent across restarts on a
# persistent city volume. `gc rig list` renders each rig as a two-space-
# indented "  <name>:" line (details are indented deeper), so the fixed-string
# whole-line match can't false-positive on a substring of another rig's name
# or path the way an unanchored grep would.
RIG_NAME="${GC_RIG_NAME:-$(basename "$WORKSPACE")}"
cd "$CITY_DIR"
if [ -d "$WORKSPACE/.git" ] && ! gc rig list 2>/dev/null | grep -qxF "  ${RIG_NAME}:"; then
  echo "Adding rig '$RIG_NAME' for $WORKSPACE"
  gc rig add "$WORKSPACE" --name "$RIG_NAME"
fi

# --- Pack-import cache self-heal ---
# Remote pack imports referenced by city.toml are cached under ~/.gc, which
# lives in the container filesystem, NOT the city volume. A container
# recreate (routine on any image bump) wipes the cache while the persisted
# city still references locked imports, and `gc start` refuses to boot
# ("remote import ... is locked but not cached"). Re-installing is cheap and
# idempotent (github.com is in the firewall's _required/ set), and heals
# first boots and recreates alike. Soft-fail: on a plain restart the cache is
# usually still present, so a transient fetch failure here must not abort the
# boot — when the cache genuinely is missing, `gc start` below fails with the
# real error, so green still requires a positive signal.
if ! gc import install; then
  echo "WARN: gc import install failed; continuing — gc start will surface" \
       "the real error if the import cache is genuinely missing" >&2
fi

# --- Claude CLI first-run seed ---
# gc drives each agent session as an interactive `claude` in tmux. On a fresh
# ~/.claude.json the CLI opens first-run prompts before the session can work:
# the workspace trust dialog (whose default is "No, exit") and the
# custom-API-key approval. gc's startup nudge presses Enter on the default, so
# every session dies at the prompt and gc respawns it, about every 70s.
# ~/.claude.json lives in the container filesystem, not the city volume, so a
# hand-made seed survives a restart but not a recreate. That is how the city
# was dark from 2026-09-25 to 10-03, creating ~3.6k session wisps a day.
# Seeding here on every boot makes a recreate safe.
#
# Trust is inherited: the CLI accepts a session whose directory (or an
# ancestor, up to its git root) has projects.<dir>.hasTrustDialogAccepted.
# Seeding the city and the workspace therefore covers the agent workdirs
# under $CITY_DIR/.gc/agents/ and the rig. Agent dirs that already exist are
# seeded too, and GC_CLAUDE_TRUST_DIRS (colon-separated) adds more. The pinned
# CLAUDE_CODE_VERSION (Dockerfile.base) keeps this config schema stable.
#
# The merge keeps every existing key, never overrides a key the operator
# rejected, and only writes when something changed. It soft-fails: a city
# that boots with a warning is easier to see and fix than one that won't boot.
seed_claude_first_run() {
  local claude_json="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
  local dirs=("$CITY_DIR")
  [ -d "$WORKSPACE" ] && dirs+=("$WORKSPACE")
  local d
  for d in "$CITY_DIR"/.gc/agents/*/; do
    [ -d "$d" ] && dirs+=("${d%/}")
  done
  if [ -n "${GC_CLAUDE_TRUST_DIRS:-}" ]; then
    local extra
    IFS=: read -r -a extra <<< "$GC_CLAUDE_TRUST_DIRS"
    dirs+=("${extra[@]}")
  fi
  # The API key reaches node through the environment only, never argv.
  node - "$claude_json" "${dirs[@]}" <<'NODE'
const fs = require("fs");
const path = require("path");
const [file, ...dirs] = process.argv.slice(2);
let cfg = {};
try {
  cfg = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (err) {
  if (err.code !== "ENOENT") {
    console.error(`WARN: ${file} is unreadable (${err.message}); not seeding it`);
    process.exit(0);
  }
}
let changes = 0;
cfg.projects = cfg.projects || {};
for (const dir of dirs.filter(Boolean)) {
  const key = path.resolve(dir);
  const project = (cfg.projects[key] = cfg.projects[key] || {});
  if (project.hasTrustDialogAccepted !== true) {
    project.hasTrustDialogAccepted = true;
    changes++;
  }
}
if (cfg.hasCompletedOnboarding !== true) {
  cfg.hasCompletedOnboarding = true;
  changes++;
}
// The CLI records an approved ANTHROPIC_API_KEY by its last 20 characters.
// GASCITY_SEED_APPROVE_API_KEY=false skips this (the prompt then appears).
const apiKey = process.env.ANTHROPIC_API_KEY;
if (apiKey && process.env.GASCITY_SEED_APPROVE_API_KEY !== "false") {
  const responses = (cfg.customApiKeyResponses = cfg.customApiKeyResponses || {});
  responses.approved = responses.approved || [];
  responses.rejected = responses.rejected || [];
  const tail = apiKey.slice(-20);
  if (!responses.approved.includes(tail) && !responses.rejected.includes(tail)) {
    responses.approved.push(tail);
    changes++;
  }
}
if (changes > 0) {
  const tmp = `${file}.seed-tmp`;
  fs.writeFileSync(tmp, JSON.stringify(cfg, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, file);
}
console.log(`claude first-run seed: ${dirs.length} trusted dir(s), ${changes} change(s)`);
NODE
}
if ! seed_claude_first_run; then
  echo "WARN: claude first-run seed failed; agent sessions may stop at the" \
       "trust dialog" >&2
fi

# --- Run the city ---
# Foreground per-city controller as the container process — the same shape as
# the fork's own container images (contrib/k8s/Dockerfile.controller). The
# supervisor-managed `gc start` backgrounds itself, which would leave PID 1
# with nothing to wait on. gc does not reap children, so consumers should run
# this service with `init: true` (the kernel's generic service does).
echo "Starting city (foreground controller)"
exec gc start --foreground "$CITY_DIR"
