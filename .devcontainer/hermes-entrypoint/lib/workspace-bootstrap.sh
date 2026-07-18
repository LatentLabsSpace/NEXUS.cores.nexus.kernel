#!/bin/bash

# Workspace bootstrap — clone the target repo into $WORKSPACE_ROOT on first
# start. State for each hermes agent lives under
# $WORKSPACE_ROOT/quarters/crew/$AGENT_NAME/ (the kernel convention).
#
# Runs as root, before the chown sweep to node:node (1000:1000).
#
# Idempotency contract:
#   • If $WORKSPACE_ROOT/.git already exists → leave the core workspace alone,
#     but retry submodule init if a previous attempt failed (or a new submodule
#     was added upstream).
#   • Otherwise → clone (shallow) at $NEXUS_TARGET_BRANCH and init submodules.
#
# Failure semantics:
#   • Core clone failure is FATAL (empty workspace is useless) and cleans up.
#   • Submodule failure is NON-FATAL: the workspace is usable without them.
#     A sentinel file ($WORKSPACE_ROOT/.submodules-pending, containing the
#     UTC timestamp of the last failed attempt) marks the pending state so
#     agents/tooling can probe for it. Retried on every container start until
#     it succeeds, at which point the sentinel is removed.
#
# Inputs (env):
#   WORKSPACE_ROOT          — clone destination (default /workspace)
#   AGENT_NAME              — agent folder under quarters/crew/
#   NEXUS_REPO_URL          — git remote (no default; required for clone)
#   NEXUS_TARGET_BRANCH     — branch to check out (default: dev)
#   HOST_GH_TOKEN / GH_TOKEN — used transiently for GitHub auth; never persisted

# Best-effort submodule init/update. Never fatal; caller decides what to do
# with a nonzero return. Safe to re-run — a partially initialized submodule
# tree is exactly what `git submodule update` repairs.
_init_submodules() {
  local dest="$1"
  local askpass_dir="$2"
  local token="$3"
  (
    cd "$dest" || exit 1
    # Export the askpass into the subshell so EVERY child git process
    # (including git-lfs smudge filter, nested `git submodule`, etc.)
    # inherits it. Per-invocation `env GIT_ASKPASS=...` prefixes only cover
    # the named process — subprocesses spawned during checkout then fail
    # with "could not read Username".
    export GIT_TERMINAL_PROMPT=0
    if [ -n "$token" ] && [ -n "$askpass_dir" ]; then
      export GIT_ASKPASS="$askpass_dir/askpass.sh"
      export GIT_ASKPASS_TOKEN="$token"
    fi
    # Shallow first for speed; on failure retry at full depth. The common
    # shallow failure mode is a pinned gitlink SHA that isn't reachable at
    # --depth=1 from the submodule's branch tip ("upload-pack: not our ref"),
    # which the full-depth fetch resolves.
    git submodule update --init --recursive --depth=1 --jobs 4 \
    || git submodule update --init --recursive --jobs 4
  )
}

# Wrapper around _init_submodules that maintains the .submodules-pending
# sentinel and always returns 0 (submodules are best-effort by design).
_try_submodules() {
  local dest="$1"
  local askpass_dir="$2"
  local token="$3"

  if _init_submodules "$dest" "$askpass_dir" "$token"; then
    rm -f "$dest/.submodules-pending"
  else
    echo "WARN: submodule init failed — workspace is usable, submodules pending." >&2
    echo "      Likely causes: token not scoped to a submodule's repo, SSH URLs" >&2
    echo "      in .gitmodules (this bootstrap only carries HTTPS credentials)," >&2
    echo "      or a pinned SHA unreachable from the submodule branch tip." >&2
    echo "      Will retry on next container start." >&2
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$dest/.submodules-pending" || true
  fi
  return 0
}

bootstrap_workspace() {
  local repo_url="${NEXUS_REPO_URL:-}"
  local branch="${NEXUS_TARGET_BRANCH:-dev}"
  local dest="$WORKSPACE_ROOT"
  local agent="${AGENT_NAME:-}"
  local token="${GH_TOKEN:-${HOST_GH_TOKEN:-}}"

  if [ -z "$dest" ]; then
    echo "WARN: WORKSPACE_ROOT is unset — skipping workspace bootstrap" >&2
    return 0
  fi

  # Hard safety check on $dest before we let the rest of this function run as
  # root with `mkdir -p`, `rm -rf`, and recursive `chown` against it.
  case "$dest" in
    /|//) echo "ERROR: refusing to bootstrap workspace at filesystem root '$dest'" >&2; return 1 ;;
    /*) ;;
    *)
      echo "ERROR: WORKSPACE_ROOT='$dest' is not an absolute path" >&2
      return 1
      ;;
  esac
  # Denylist: WORKSPACE_ROOT is consumer-configurable, so accept any absolute
  # non-system path rather than pinning a single mount point. The absolute-path
  # check above already rejects '/' and relative paths; here we additionally
  # refuse well-known system directories that must never become a root-run
  # rm -rf / chown target.
  case "$dest" in
    /bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/home|/home/*|/lib|/lib/*|/lib32|/lib32/*|/lib64|/lib64/*|/media|/media/*|/mnt|/mnt/*|/opt|/opt/*|/proc|/proc/*|/root|/root/*|/run|/run/*|/sbin|/sbin/*|/srv|/srv/*|/sys|/sys/*|/tmp|/tmp/*|/usr|/usr/*|/var|/var/*)
      echo "ERROR: refusing to bootstrap workspace at system path '$dest'" >&2
      return 1
      ;;
  esac
  case "$dest" in
    */.|*/..|*/./*|*/../*)
      echo "ERROR: WORKSPACE_ROOT='$dest' contains '.' or '..' segments — refusing" >&2
      return 1
      ;;
  esac
  if command -v realpath >/dev/null 2>&1; then
    local canonical
    canonical="$(realpath -m -- "$dest" 2>/dev/null || true)"
    if [ -z "$canonical" ]; then
      echo "ERROR: could not canonicalize WORKSPACE_ROOT='$dest'" >&2
      return 1
    fi
    case "$canonical" in
      /bin|/bin/*|/boot|/boot/*|/dev|/dev/*|/etc|/etc/*|/home|/home/*|/lib|/lib/*|/lib32|/lib32/*|/lib64|/lib64/*|/media|/media/*|/mnt|/mnt/*|/opt|/opt/*|/proc|/proc/*|/root|/root/*|/run|/run/*|/sbin|/sbin/*|/srv|/srv/*|/sys|/sys/*|/tmp|/tmp/*|/usr|/usr/*|/var|/var/*)
        echo "ERROR: WORKSPACE_ROOT='$dest' canonicalizes to system path '$canonical' — refusing" >&2
        return 1
        ;;
    esac
  fi
  if [ -L "$dest" ]; then
    echo "ERROR: WORKSPACE_ROOT='$dest' is a symlink — refusing to bootstrap into it" >&2
    return 1
  fi

  if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    echo "ERROR: NEXUS_TARGET_BRANCH='$branch' is not a valid git branch name" >&2
    return 1
  fi

  mkdir -p "$dest"

  # Set up the transient askpass BEFORE the .git existence check so that the
  # already-initialized path can also authenticate submodule retries. The
  # directory is removed on every exit path below; the token itself is only
  # ever passed via environment to child git processes, never written to disk.
  local askpass_dir=""
  if [ -n "$token" ]; then
    askpass_dir="$(mktemp -d)"
    chmod 700 "$askpass_dir"
    cat >"$askpass_dir/askpass.sh" <<'EOF'
#!/bin/sh
case "$1" in
  Username*) printf 'x-access-token\n' ;;
  Password*) printf '%s\n' "$GIT_ASKPASS_TOKEN" ;;
esac
EOF
    chmod 700 "$askpass_dir/askpass.sh"
  fi

  if [ -d "$dest/.git" ]; then
    echo "Workspace at $dest already initialized — leaving it alone."
    # Retry submodules: repairs a previously failed init and picks up
    # submodules added upstream since the original clone. Never fatal.
    _try_submodules "$dest" "$askpass_dir" "$token"
    if [ -n "$askpass_dir" ]; then
      rm -rf "$askpass_dir"
    fi
    _ensure_agent_state_dirs "$dest" "$agent"
    return 0
  fi

  if [ -z "$repo_url" ]; then
    if [ -n "$askpass_dir" ]; then
      rm -rf "$askpass_dir"
    fi
    echo "ERROR: NEXUS_REPO_URL is unset and $dest is empty — cannot bootstrap workspace" >&2
    return 1
  fi

  echo "Cloning $repo_url@$branch into $dest"
  local clone_rc=0
  set +e
  (
    cd "$dest" || exit 1
    # Export the askpass into the subshell so EVERY child git process
    # (including git-lfs smudge filter, git submodule, etc.) inherits it.
    # Per-invocation `env GIT_ASKPASS=...` prefixes only cover the named
    # process — git-lfs subprocesses spawned during `git checkout` then
    # fail with "could not read Username" on LFS-tracked files.
    export GIT_TERMINAL_PROMPT=0
    if [ -n "$token" ] && [ -n "$askpass_dir" ]; then
      export GIT_ASKPASS="$askpass_dir/askpass.sh"
      export GIT_ASKPASS_TOKEN="$token"
    fi
    git init -q || exit $?
    git remote add origin "$repo_url" || exit $?
    git fetch --depth=1 origin "$branch" || exit $?
    git checkout -f -B "$branch" FETCH_HEAD || exit $?
    git update-ref "refs/remotes/origin/$branch" FETCH_HEAD || exit $?
    git branch --set-upstream-to="origin/$branch" "$branch" >/dev/null || exit $?
    # NOTE: submodules are intentionally NOT initialized here — they are
    # handled after the core clone succeeds, as a non-fatal step, so a
    # submodule failure can't trigger the destructive cleanup below.
  )
  clone_rc=$?
  set -e

  if [ "$clone_rc" -ne 0 ]; then
    if [ -n "$askpass_dir" ]; then
      rm -rf "$askpass_dir"
    fi
    echo "ERROR: initial workspace clone failed." >&2
    find "$dest" -mindepth 1 -maxdepth 1 -exec rm -rf {} + || true
    return 1
  fi

  # Core workspace is good from here on — submodules are best-effort.
  _try_submodules "$dest" "$askpass_dir" "$token"

  if [ -n "$askpass_dir" ]; then
    rm -rf "$askpass_dir"
  fi

  _ensure_agent_state_dirs "$dest" "$agent"
}

# Pre-create the per-agent state directories that link_agent_state targets,
# so the symlinks have something to point at even on a fresh clone where
# nobody has committed any state yet.
_ensure_agent_state_dirs() {
  local dest="$1"
  local agent="$2"

  [ -z "$agent" ] && return 0

  case "$agent" in
    *[!A-Za-z0-9._-]*|.|..|-*)
      echo "ERROR: refusing to create agent state dirs — AGENT_NAME='$agent' is not a safe directory name" >&2
      return 1
      ;;
  esac

  # State root defaults to the nexus convention (quarters/crew/$agent) but can be
  # overridden per-service via HERMES_AGENT_STATE_DIR (a $WORKSPACE_ROOT-relative
  # path). Validation + symlink-segment guards live in link-agent-state.sh, which
  # the entrypoint always sources alongside this file.
  local state_rel="${HERMES_AGENT_STATE_DIR:-quarters/crew/$agent}"
  if ! _validate_state_rel "$state_rel"; then
    return 1
  fi
  if ! _assert_no_symlink_segments "$dest" "$state_rel"; then
    return 1
  fi

  local agent_root="$dest/$state_rel"
  mkdir -p "$agent_root" || return 1
  safe_mkdir_under "$agent_root" ".hermes"                  || return 1
  safe_mkdir_under "$agent_root" ".hermes/sessions"         || return 1
  safe_mkdir_under "$agent_root" ".hermes/logs"             || return 1
  safe_mkdir_under "$agent_root" ".copilot/session-state"   || return 1
  safe_mkdir_under "$agent_root" ".ssh"                     || return 1
  chmod 0700 "$agent_root/.ssh" 2>/dev/null || true
  safe_mkdir_under "$agent_root" ".bashhistory"             || return 1
  safe_mkdir_under "$agent_root" ".claude"                  || return 1
  safe_mkdir_under "$agent_root" ".vscode-server"           || return 1
  
  # Explicitly chown the per-agent state subtree to the runtime user. If this
  # ever fails, surface the error LOUDLY — the rest of the bootstrap (cp,
  # mkdir, hermes config seed) assumes node owns these dirs, and a silent
  # chown failure produces a confusing EACCES three phases later.
  if ! chown -R "${TARGET_UID:-1000}:${TARGET_GID:-1000}" "$agent_root"; then
    echo "ERROR: failed to chown $agent_root to ${TARGET_UID:-1000}:${TARGET_GID:-1000}" >&2
    echo "Listing current ownership for diagnosis:" >&2
    ls -lan "$agent_root" >&2 || true
    echo "If this volume is on a filesystem that doesn't permit chown (rootless docker, certain WSL setups), the runtime user model needs to change. Treat this as a hard error." >&2
    return 1
  fi
}