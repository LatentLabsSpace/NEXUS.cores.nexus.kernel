#!/bin/bash
set -euo pipefail

echo "=== nexus-kernel-base entrypoint ==="

WORKSPACE="${NEXUS_WORKSPACE:-/workspace}"
REPO_URL="${NEXUS_REPO_URL:-}"
BRANCH="${NEXUS_BRANCH:-main}"

# --- Repo bootstrap ---
if [ -n "$REPO_URL" ] && [ ! -d "$WORKSPACE/.git" ]; then
  echo "Cloning repo (branch: $BRANCH) to $WORKSPACE..."
  git clone --branch "$BRANCH" "$REPO_URL" "$WORKSPACE"
  cd "$WORKSPACE"
  git submodule update --init --recursive
else
  cd "$WORKSPACE"
fi

# --- Firewall ---
echo "Initializing firewall..."
sudo -E /usr/local/bin/init-firewall.sh

# --- Post-boot hook ---
if [ -n "${NEXUS_POST_BOOT_CMD:-}" ]; then
  echo "Running post-boot command: $NEXUS_POST_BOOT_CMD"
  exec $NEXUS_POST_BOOT_CMD
fi

exec sleep infinity