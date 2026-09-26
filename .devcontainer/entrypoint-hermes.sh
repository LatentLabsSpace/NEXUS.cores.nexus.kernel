#!/bin/bash
set -euo pipefail

# Allow host user (group "other") to read files created by the container's node user
umask 0002

echo "=== Hermes Agent entrypoint ==="

INSTALL_DIR="/home/node/hermes-agent"
WORKSPACE_ROOT="${HERMES_WORKSPACE_PATH:-/workspace}"
HERMES_ENTRYPOINT_ROOT="${HERMES_ENTRYPOINT_ROOT:-/usr/local/share/hermes-entrypoint}"

source "${HERMES_ENTRYPOINT_ROOT}/lib/safe-mkdir.sh"
source "${HERMES_ENTRYPOINT_ROOT}/lib/workspace-bootstrap.sh"
source "${HERMES_ENTRYPOINT_ROOT}/lib/link-agent-state.sh"
source "${HERMES_ENTRYPOINT_ROOT}/phases/root-bootstrap.sh"
source "${HERMES_ENTRYPOINT_ROOT}/phases/runtime-bootstrap.sh"
source "${HERMES_ENTRYPOINT_ROOT}/phases/config-overrides.sh"

TARGET_UID=1000
TARGET_GID=1000

if [ "$(id -u)" = "0" ]; then
  run_root_bootstrap
  exec gosu node "$0" "$@"
fi

# --- From here on we are running as the node user ---
run_runtime_bootstrap
apply_runtime_config_overrides

export MESSAGING_CWD="$WORKSPACE_ROOT"
export TERMINAL_CWD="$WORKSPACE_ROOT"

background_pids=()

cleanup() {
  for pid in "${background_pids[@]:-}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
}

trap cleanup INT TERM EXIT

MODE="${HERMES_MODE:-gateway}"

case "$MODE" in
  gateway)
    echo "Starting Hermes gateway..."
    hermes gateway &
    background_pids+=("$!")
    runtime_pid="$!"
    ;;
  cli)
    echo "Starting Hermes CLI..."
    hermes &
    background_pids+=("$!")
    runtime_pid="$!"
    ;;
  sleep)
    echo "Hermes available — container in sleep mode for VS Code attach..."
    sleep infinity &
    background_pids+=("$!")
    runtime_pid="$!"
    ;;
  *)
    echo "Unknown HERMES_MODE: $MODE (use: gateway, cli, sleep)"
    exit 1
    ;;
esac

# Optional web dashboard alongside the main process. Off unless the consumer
# opts in (Dockerfile.base defaults HERMES_DASHBOARD_AUTOSTART=false). Tracked in
# background_pids so cleanup stops it with the container, but deliberately NOT
# waited on: a dashboard crash never takes the gateway (or the container) down.
# Binds the dashboard's own default, 127.0.0.1:9119 — loopback only; reach it via
# a port forward or tunnel. Launching it here (not from an IDE terminal) also
# gives it the container's PATH rather than an editor-injected one.
case "${HERMES_DASHBOARD_AUTOSTART:-false}" in
  true|1|yes|on)
    echo "Starting Hermes dashboard (127.0.0.1:9119)..."
    hermes dashboard --no-open &
    background_pids+=("$!")
    ;;
esac

wait "$runtime_pid"
exit_code=$?

trap - EXIT
cleanup
exit "$exit_code"
