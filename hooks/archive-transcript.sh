#!/usr/bin/env bash
# archive-transcript.sh — SessionEnd and PreCompact hook: keep a gzipped copy
# of the session's transcript in ~/.claude/session-archive/<session id>.jsonl.gz
# (or $CLAUDE_SESSION_ARCHIVE), so the `Claude-Session:` trailer on a commit
# still leads to its conversation after the session is archived in the UI,
# which can delete the transcript from ~/.claude/projects. Overwrites the
# session's earlier copy atomically. Never blocks: failures exit 0.
set -uo pipefail
umask 077  # transcripts can hold sensitive detail: owner-only, from creation
# A failure never blocks the session, but it is never silent either: it goes
# to the user as a hook systemMessage and is appended to a log outside the
# archive folder (which may be the thing that failed).
fail() {
  local why="$1"
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "${sid:-?}" "$why" \
    >> "$HOME/.claude/session-archive-failures.log" 2>/dev/null
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg m "Transcript archive failed for session ${sid:-?}: $why. The commit-to-conversation link breaks if this session is archived before a copy exists; see ~/.claude/session-archive-failures.log." '{systemMessage: $m}'
  fi
  exit 0
}
sid=""
command -v jq >/dev/null 2>&1 || fail "jq is not installed"
input="$(cat)"
path="$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null)"
sid="$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)"
[[ "$sid" =~ ^[A-Za-z0-9-]+$ ]] || { sid=""; fail "the hook input carried no usable session id"; }
[[ -n "$path" && -f "$path" ]] || fail "transcript not found at '${path:-?}'"
dir="${CLAUDE_SESSION_ARCHIVE:-$HOME/.claude/session-archive}"
mkdir -p -m 700 "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null || fail "cannot create $dir"
tmp="$dir/.$sid.jsonl.gz.$$"
if ! gzip -c "$path" > "$tmp" 2>/dev/null; then
  rm -f "$tmp"
  fail "gzip into $dir failed (disk full or not writable?)"
fi
mv -f "$tmp" "$dir/$sid.jsonl.gz" 2>/dev/null || { rm -f "$tmp"; fail "could not move the copy into place in $dir"; }
exit 0
