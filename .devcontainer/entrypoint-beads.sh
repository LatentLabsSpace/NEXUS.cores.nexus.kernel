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

# Online auto-GC keeps the chunk journal compact. dolt keeps the journal's index
# in RAM, so an uncompacted journal IS the server's memory baseline: on the first
# consumer an 11G / 5.45M-chunk journal OOM-looped the 3g server every ~32min.
# archive_level 0 matters: the default (1) builds compressed archives in memory
# and was OOM-killed even at 5.5G, while level 0 GC'd the same store in 57s.
AUTO_GC="${BEADS_DOLT_AUTO_GC:-true}"
ARCHIVE_LEVEL="${BEADS_DOLT_AUTO_GC_ARCHIVE_LEVEL:-0}"
# Online counterpart of the offline recipe's --incremental-file-size: GC flushes
# its output in pieces of this many bytes instead of building large files in
# memory. dolt's own default is 0 (off); 0 here also means off.
INCREMENTAL="${BEADS_DOLT_AUTO_GC_INCREMENTAL_FILE_SIZE:-268435456}"
case "$AUTO_GC" in true|false) ;; *) echo "BEADS_DOLT_AUTO_GC must be true|false, got '$AUTO_GC'" >&2; exit 1 ;; esac
case "$ARCHIVE_LEVEL" in 0|1) ;; *) echo "BEADS_DOLT_AUTO_GC_ARCHIVE_LEVEL must be 0|1, got '$ARCHIVE_LEVEL'" >&2; exit 1 ;; esac
case "$INCREMENTAL" in ''|*[!0-9]*) echo "BEADS_DOLT_AUTO_GC_INCREMENTAL_FILE_SIZE must be a byte count (0 = off), got '$INCREMENTAL'" >&2; exit 1 ;; esac

# Behaviour settings exist only in the config file (no CLI flags), and
# sql-server ignores $DATA_DIR/config.yaml once --host/--port/--data-dir are
# passed. So the whole server config is rendered here and passed via --config.
# It lives outside the data volume: the kernel owns it and it is regenerated on
# every start.
CONFIG=/tmp/beads-sql-server.yaml
cat > "$CONFIG" <<EOF
log_level: info
behavior:
  auto_gc_behavior:
    enable: ${AUTO_GC}
    archive_level: ${ARCHIVE_LEVEL}
    incremental_file_size: ${INCREMENTAL}
listener:
  host: "${BIND_HOST}"
  port: ${PORT}
data_dir: "${DATA_DIR}"
EOF

echo "Serving beads graph from $DATA_DIR on ${BIND_HOST}:${PORT} (auto_gc=${AUTO_GC} archive_level=${ARCHIVE_LEVEL} incremental_file_size=${INCREMENTAL})"
exec dolt sql-server --config "$CONFIG"
