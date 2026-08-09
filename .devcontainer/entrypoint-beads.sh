#!/bin/bash
set -euo pipefail

echo "=== beads-server entrypoint ==="

DATA_DIR="${BEADS_DATA_DIR:-/beads}"
PORT="${BEADS_PORT:-3307}"
BIND_HOST="${BEADS_BIND_HOST:-0.0.0.0}"

# Dolt auto-creates its root superuser as root@localhost on first launch. Every
# client here arrives over the compose network, so that grant never matches and
# the FIRST bd connection fails with "Access denied". Widening the root host is
# what the beads fork's own test harness does for containerized Dolt
# (internal/testutil/testdoltserver.go). Only read on first init — after that
# the grant lives in $DATA_DIR/.doltcfg/privileges.db inside the volume.
export DOLT_ROOT_HOST="${DOLT_ROOT_HOST:-%}"

# v1 runs credential-free on the compose network only. Set BEADS_DOLT_PASSWORD
# on the SERVER service to give root a password at first init; clients read the
# same variable name, so one value configures both sides.
if [ -n "${BEADS_DOLT_PASSWORD:-}" ]; then
  export DOLT_ROOT_PASSWORD="$BEADS_DOLT_PASSWORD"
fi

# Initialize the data directory if absent. dolt sql-server serves a directory of
# databases; bd issues its own CREATE DATABASE on `bd init --server`, so an
# empty directory is the correct starting state — no `dolt init` here (that
# would make $DATA_DIR itself a single database and shadow the multi-db mode).
if [ ! -d "$DATA_DIR" ]; then
  echo "Initializing beads data directory at $DATA_DIR"
  mkdir -p "$DATA_DIR"
fi
cd "$DATA_DIR"

# Dolt refuses to write commits without an identity.
dolt config --global --add user.name "${BEADS_DOLT_USER_NAME:-beads-server}" >/dev/null
dolt config --global --add user.email "${BEADS_DOLT_USER_EMAIL:-beads-server@nexus.local}" >/dev/null

echo "Serving beads graph from $DATA_DIR on ${BIND_HOST}:${PORT}"
exec dolt sql-server \
  --host "$BIND_HOST" \
  --port "$PORT" \
  --data-dir "$DATA_DIR"
