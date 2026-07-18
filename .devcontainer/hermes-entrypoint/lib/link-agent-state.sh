#!/bin/bash

# Link agent state — point the canonical in-container state paths into the
# per-agent folder inside the cloned nexus workspace, so all Hermes/Copilot
# state is version-controlled alongside the repo.
#
# Runs as root, after bootstrap_workspace and before the chown sweep.
# Idempotent: uses `ln -sfn` so reruns just refresh the symlink targets.
#
# The agent state root defaults to $WORKSPACE_ROOT/quarters/crew/$AGENT_NAME
# (the nexus convention). Override it per-service with HERMES_AGENT_STATE_DIR
# (a path relative to $WORKSPACE_ROOT) — e.g. `holodeck/cargo`.
#
# Symlinks created (relative to the resolved state root <ROOT>):
#   /home/node/.hermes                  → <ROOT>/.hermes
#   /home/node/.copilot                 → <ROOT>/.copilot
#   /home/node/.ssh                     → <ROOT>/.ssh
#   /commandhistory                     → <ROOT>/.bashhistory
#   /home/node/.claude                  → <ROOT>/.claude
#   /home/node/.vscode-server           → <ROOT>/.vscode-server

link_agent_state() {
  local agent="${AGENT_NAME:-}"
  local workspace="${WORKSPACE_ROOT:-}"

  if [ -z "$agent" ] || [ -z "$workspace" ]; then
    echo "WARN: AGENT_NAME or WORKSPACE_ROOT unset — skipping agent state linking" >&2
    return 0
  fi

  case "$agent" in
    *[!A-Za-z0-9._-]*|""|.|..|-*)
      echo "ERROR: refusing to link agent state — AGENT_NAME='$agent' is not a safe directory name" >&2
      return 1
      ;;
  esac

  local state_rel="${HERMES_AGENT_STATE_DIR:-quarters/crew/$agent}"
  if ! _validate_state_rel "$state_rel"; then
    return 1
  fi
  local agent_root="$workspace/$state_rel"

  # Refuse if any path segment from the workspace down to the state root is a
  # symlink — a corrupted volume could otherwise escape $WORKSPACE_ROOT.
  if ! _assert_no_symlink_segments "$workspace" "$state_rel"; then
    return 1
  fi

  _link_state_path "$agent_root" ".hermes"                "/home/node/.hermes"                || return 1
  _link_state_path "$agent_root" ".copilot"               "/home/node/.copilot"               || return 1
  _link_state_path "$agent_root" ".ssh"                   "/home/node/.ssh"                   || return 1
  _link_state_path "$agent_root" ".bashhistory"           "/commandhistory"                   || return 1
  _link_state_path "$agent_root" ".claude"                "/home/node/.claude"                || return 1
  _link_state_path "$agent_root" ".vscode-server"         "/home/node/.vscode-server"         || return 1
}

# Validate a workspace-relative state path: no absolute paths, no '..' or '.'
# segments, no empty segments. Keeps HERMES_AGENT_STATE_DIR from escaping.
_validate_state_rel() {
  local rel="$1"
  case "$rel" in
    /*|"")
      echo "ERROR: HERMES_AGENT_STATE_DIR='$rel' must be a non-empty relative path" >&2
      return 1
      ;;
  esac
  case "/$rel/" in
    */../*|*/./*|*//*)
      echo "ERROR: HERMES_AGENT_STATE_DIR='$rel' contains '.', '..' or empty segments — refusing" >&2
      return 1
      ;;
  esac
  return 0
}

# Walk every segment from $base down through $rel and fail if any is a symlink.
_assert_no_symlink_segments() {
  local base="$1"
  local rel="$2"
  local probe="$base"
  local rest="$rel"
  local seg
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    if [ "$rest" = "$seg" ]; then rest=""; else rest="${rest#*/}"; fi
    [ -z "$seg" ] && continue
    probe="$probe/$seg"
    if [ -L "$probe" ]; then
      echo "ERROR: $probe is a symlink — refusing to touch agent state" >&2
      return 1
    fi
  done
  return 0
}

_link_state_path() {
  local base="$1"
  local rel="$2"
  local link="$3"
  local target="$base/$rel"

  safe_mkdir_under "$base" "$rel" || return 1

  if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
    return 0
  fi

  rm -rf "$link"
  ln -sfn "$target" "$link"
}
