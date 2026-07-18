#!/bin/bash

# safe_mkdir_under <base> <relative-path>
#
# Create $base/$rel one component at a time, refusing to traverse or create
# any path component that is (or becomes) a symlink. $base itself is assumed
# to already be validated by the caller (not a symlink, safe directory).
#
# Used by workspace-bootstrap.sh and link-agent-state.sh, both of which run
# as root and call mkdir -p on attacker-influenceable paths inside the
# workspace volume. Plain `mkdir -p` happily follows symlink components,
# which would let a corrupted volume escape $WORKSPACE_ROOT/quarters/crew/<agent>.

safe_mkdir_under() {
  local base="$1"
  local rel="$2"

  if [ -z "$base" ] || [ -z "$rel" ]; then
    echo "ERROR: safe_mkdir_under needs base and relative path" >&2
    return 2
  fi

  case "$rel" in
    /*|*/../*|../*|*/..|..)
      echo "ERROR: safe_mkdir_under refuses unsafe relative path '$rel'" >&2
      return 1
      ;;
  esac

  local cur="$base"
  local part
  local -a parts
  IFS=/ read -r -a parts <<<"$rel"
  for part in "${parts[@]}"; do
    [ -z "$part" ] && continue
    cur="$cur/$part"
    if [ -L "$cur" ]; then
      echo "ERROR: refusing to mkdir through symlink at $cur" >&2
      return 1
    fi
    if [ -e "$cur" ]; then
      if [ ! -d "$cur" ]; then
        echo "ERROR: $cur exists and is not a directory" >&2
        return 1
      fi
    else
      mkdir "$cur" || return 1
    fi
  done
  return 0
}
