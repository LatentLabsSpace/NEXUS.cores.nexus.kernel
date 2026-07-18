#!/bin/bash

# Root-only phase: bootstrap the workspace volume, heal writable runtime
# trees, then sync ownership before re-execing the entrypoint as the
# (fixed-UID) node user.

_add_git_safe_directory() {
  local dir="$1"
  [ -n "$dir" ] || return 0
  [ -d "$dir" ] || return 0
  if git config --system --get-all safe.directory 2>/dev/null | grep -Fxq -- "$dir"; then
    return 0
  fi
  git config --system --add safe.directory "$dir" 2>/dev/null || true
}

_configure_git_safe_directories() {
  local candidate
  _add_git_safe_directory "$WORKSPACE_ROOT"
  for candidate in \
    "$WORKSPACE_ROOT/codex"/* \
    "$WORKSPACE_ROOT/upstream"/* \
    "$WORKSPACE_ROOT/aliens"/*/*; do
    [ -e "$candidate/.git" ] || [ -f "$candidate/.git" ] || continue
    _add_git_safe_directory "$candidate"
  done
}

run_root_bootstrap() {
  _configure_git_safe_directories

  bootstrap_workspace
  link_agent_state

  # Sweep ownership across the whole workspace. The previous form gated this
  # on $WORKSPACE_ROOT's own owner as a "fast path"; in practice the gate
  # mis-fires when the volume's root dir lands at TARGET_UID:TARGET_GID
  # independently of its contents (rootless docker, prior partial run, host
  # quirks), leaving the just-cloned tree root-owned. The find is idempotent
  # and cheap; always run it. Errors on per-file chowns are ignored so a
  # transient EACCES on a special file doesn't abort the whole bootstrap.
  if [ -d "$WORKSPACE_ROOT" ]; then
    find "$WORKSPACE_ROOT" -xdev \
      -not -type l -exec chown --no-dereference "$TARGET_UID:$TARGET_GID" {} + \
      2>/dev/null || true
  fi

  chown --no-dereference "$TARGET_UID:$TARGET_GID" \
    /home/node \
    /home/node/.hermes \
    /home/node/.ssh \
    /commandhistory \
    2>/dev/null || true

  install -d -o "$TARGET_UID" -g "$TARGET_GID" -m 0755 /home/node/.cache 2>/dev/null || true

  for d in \
    /home/node/.cache/copilot \
    /home/node/.copilot/logs \
    /home/node/.copilot/session-state \
    /home/node/.hermes/cron/output \
    /home/node/.hermes/logs \
    /home/node/.hermes/sessions \
    /home/node/.hermes/memories \
    /home/node/.hermes/skills \
    /home/node/.hermes/hooks \
    /home/node/.hermes/skins \
    /home/node/.hermes/plans \
    /home/node/.hermes/workspace \
    /home/node/.hermes/home; do
    install -d -o "$TARGET_UID" -g "$TARGET_GID" -m 0755 "$d" 2>/dev/null || true
  done

  local tree
  for tree in \
    /home/node/.hermes \
    /home/node/.copilot \
    /home/node/.copilot/session-state \
    /home/node/.cache/copilot \
    /home/node/.ssh \
    /commandhistory; do
    [ -e "$tree" ] || [ -L "$tree" ] || continue
    local resolved
    resolved="$(readlink -f -- "$tree" 2>/dev/null || true)"
    [ -n "$resolved" ] || continue
    if [ -L "$tree" ]; then
      case "$resolved" in
        "$WORKSPACE_ROOT"/*) ;;
        *)
          echo "WARN: $tree resolves to '$resolved' outside WORKSPACE_ROOT='$WORKSPACE_ROOT' — skipping chown" >&2
          continue
          ;;
      esac
    fi
    local root_uid root_gid
    root_uid="$(stat -c '%u' "$resolved" 2>/dev/null || echo -1)"
    root_gid="$(stat -c '%g' "$resolved" 2>/dev/null || echo -1)"
    if [ "$root_uid" = "$TARGET_UID" ] && [ "$root_gid" = "$TARGET_GID" ]; then
      continue
    fi
    find -H "$tree" ! -type l \( ! -uid "$TARGET_UID" -o ! -gid "$TARGET_GID" \) \
      -exec chown --no-dereference "$TARGET_UID:$TARGET_GID" {} + 2>/dev/null || true
  done

  for tree in \
    /home/node/.local \
    /home/node/.oh-my-zsh \
    /usr/local/share/hermes-defaults; do
    [ -e "$tree" ] || continue
    find "$tree" ! -type l \( ! -uid "$TARGET_UID" -o ! -gid "$TARGET_GID" \) \
      -exec chown --no-dereference "$TARGET_UID:$TARGET_GID" {} + 2>/dev/null || true
    find "$tree" -type l \( ! -uid "$TARGET_UID" -o ! -gid "$TARGET_GID" \) \
      -exec chown --no-dereference "$TARGET_UID:$TARGET_GID" {} + 2>/dev/null || true
  done
  local f
  for f in \
    /home/node/.zshrc /home/node/.bashrc /home/node/.profile \
    /home/node/.bash_profile /home/node/.zprofile; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    chown --no-dereference "$TARGET_UID:$TARGET_GID" "$f" 2>/dev/null || true
  done
}
