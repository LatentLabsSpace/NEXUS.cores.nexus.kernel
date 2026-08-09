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
sudo -E /usr/local/bin/init-firewall.sh

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

# --- Run the city ---
# Foreground per-city controller as the container process — the same shape as
# the fork's own container images (contrib/k8s/Dockerfile.controller). The
# supervisor-managed `gc start` backgrounds itself, which would leave PID 1
# with nothing to wait on. gc does not reap children, so consumers should run
# this service with `init: true` (the kernel's generic service does).
echo "Starting city (foreground controller)"
exec gc start --foreground "$CITY_DIR"
