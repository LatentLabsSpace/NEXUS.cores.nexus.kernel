#!/usr/bin/env bash
# commit-session.sh — which Claude Code session made a commit, and where its
# transcript is. Reads the commit's `Claude-Session:` trailers and looks for
# each transcript in ~/.claude/projects/*/ (live sessions) and the session
# archive (~/.claude/session-archive, or $CLAUDE_SESSION_ARCHIVE).
#
# Usage: commit-session.sh [<rev>]   (default HEAD; run inside the repo)
set -uo pipefail
rev="${1:-HEAD}"
ids="$(git log -1 --format='%(trailers:key=Claude-Session,valueonly)' "$rev" 2>/dev/null)" \
  || { echo "commit-session: no commit $rev here" >&2; exit 2; }
ids="$(sed '/^\s*$/d' <<<"$ids")"
[[ -n "$ids" ]] || { echo "commit-session: $rev has no Claude-Session trailer (made outside Claude Code, or before 2026-10-27)" >&2; exit 1; }
archive="${CLAUDE_SESSION_ARCHIVE:-$HOME/.claude/session-archive}"
while IFS= read -r sid; do
  [[ "$sid" =~ ^[A-Za-z0-9-]+$ ]] || continue
  found=""
  for p in "$HOME"/.claude/projects/*/"$sid".jsonl "$archive/$sid.jsonl" "$archive/$sid.jsonl.gz"; do
    [[ -f "$p" ]] && { found="$p"; break; }
  done
  printf '%s\t%s\n' "$sid" "${found:-(transcript not found)}"
done <<<"$ids"
