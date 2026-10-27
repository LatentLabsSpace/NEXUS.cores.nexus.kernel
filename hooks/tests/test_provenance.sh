#!/usr/bin/env bash
# Tests for the commit-provenance hooks: session-start.sh, git/prepare-commit-msg
# (+ _chain), archive-transcript.sh and commit-session.sh. No network; a temp
# repo and a fake HOME. Run: bash hooks/tests/test_provenance.sh
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
ok() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got [$2] want [$3]"; fail=1; fi; }

# A session's environment, as session-start.sh writes it.
env_file="$T/claude-env"; : > "$env_file"
( unset GIT_CONFIG_COUNT; CLAUDE_ENV_FILE="$env_file" bash "$H/session-start.sh" )
ok "session-start writes three exports" "$(grep -c '^export GIT_CONFIG_' "$env_file")" 3

repo="$T/repo"; git init -q "$repo"
gitc() { git -C "$repo" -c user.email=t@t -c user.name=t "$@"; }
in_session() { ( unset GIT_CONFIG_COUNT; source "$env_file"; CLAUDE_CODE_SESSION_ID="$1" gitc "${@:2}" ); }
trailers() { git -C "$repo" log -1 --format='%(trailers:key=Claude-Session,valueonly)' | sed '/^$/d' | tr '\n' ' '; }

in_session aaa-111 commit -q --allow-empty -m "one"
ok "session commit carries its id" "$(trailers)" "aaa-111 "
( unset GIT_CONFIG_COUNT; source "$env_file"; unset CLAUDE_CODE_SESSION_ID; gitc commit -q --allow-empty -m "two" )
ok "no session id, no trailer" "$(trailers)" ""
gitc commit -q --allow-empty -m "three"
ok "plain git (no session env) untouched" "$(trailers)" ""

in_session aaa-111 commit -q --allow-empty -m "four"
in_session aaa-111 commit -q --amend --no-edit --allow-empty
ok "same-session amend adds nothing" "$(trailers)" "aaa-111 "
in_session bbb-222 commit -q --amend --no-edit --allow-empty
ok "other-session amend adds itself" "$(trailers)" "aaa-111 bbb-222 "

# The repo's own hooks still run under the kernel hook folder.
printf '#!/bin/sh\necho own >> "%s/own-hook.log"\n' "$T" > "$repo/.git/hooks/commit-msg"
chmod +x "$repo/.git/hooks/commit-msg"
in_session aaa-111 commit -q --allow-empty -m "five"
ok "repo's own commit-msg hook ran" "$(cat "$T/own-hook.log" 2>/dev/null)" "own"
printf '#!/bin/sh\nexit 1\n' > "$repo/.git/hooks/pre-commit"; chmod +x "$repo/.git/hooks/pre-commit"
in_session aaa-111 commit -q --allow-empty -m "six" 2>/dev/null; rc=$?
ok "repo's failing pre-commit still blocks" "$rc" 1
rm "$repo/.git/hooks/pre-commit"

# A repo with its own core.hooksPath: its hooks still decide (review blocker).
repo2="$T/repo2"; git init -q "$repo2"; mkdir -p "$repo2/custom-hooks"
git -C "$repo2" config core.hooksPath custom-hooks
printf '#!/bin/sh\nexit 1\n' > "$repo2/custom-hooks/pre-commit"; chmod +x "$repo2/custom-hooks/pre-commit"
git -C "$repo2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x 2>/dev/null; plain_rc=$?
( unset GIT_CONFIG_COUNT; source "$env_file"; CLAUDE_CODE_SESSION_ID=ccc-333 git -C "$repo2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x 2>/dev/null ); sess_rc=$?
ok "repo core.hooksPath pre-commit blocks plain git" "$plain_rc" 1
ok "…and blocks a session commit the same way" "$sess_rc" 1
# Every hook name is covered, e.g. reference-transaction (review blocker).
printf '#!/bin/sh\ncat >/dev/null; echo rt >> "%s/rt.log"\n' "$T" > "$repo/.git/hooks/reference-transaction"
chmod +x "$repo/.git/hooks/reference-transaction"
in_session aaa-111 commit -q --allow-empty -m "rt"
ok "repo's reference-transaction hook ran" "$(grep -c rt "$T/rt.log" 2>/dev/null | awk '{print ($1>0)}')" 1
rm "$repo/.git/hooks/reference-transaction"

# Archive and lookup, with a fake HOME.
home="$T/home"; mkdir -p "$home/.claude/projects/p"
echo '{"a":1}' > "$home/.claude/projects/p/aaa-111.jsonl"
echo '{"b":2}' > "$T/bbb.jsonl"
printf '{"session_id":"bbb-222","transcript_path":"%s"}' "$T/bbb.jsonl" | HOME="$home" bash "$H/archive-transcript.sh"
ok "archive writes a gzip copy" "$(zcat "$home/.claude/session-archive/bbb-222.jsonl.gz")" '{"b":2}'
ok "archive folder is owner-only" "$(stat -c %a "$home/.claude/session-archive")" 700
ok "archived transcript is owner-only" "$(stat -c %a "$home/.claude/session-archive/bbb-222.jsonl.gz")" 600

# A failed archive is reported, never silent (review blocker).
touch "$T/afile"
msg="$(printf '{"session_id":"bbb-222","transcript_path":"%s"}' "$T/bbb.jsonl" | HOME="$home" CLAUDE_SESSION_ARCHIVE="$T/afile/sub" bash "$H/archive-transcript.sh")"; rc=$?
ok "failed archive still exits 0" "$rc" 0
ok "uncreatable archive folder tells the user" "$(jq -r .systemMessage <<<"$msg" | grep -c 'Transcript archive failed for session bbb-222: cannot create')" 1
ok "failed archive is logged" "$(grep -c 'bbb-222' "$home/.claude/session-archive-failures.log")" 1
cp "$T/bbb.jsonl" "$T/unreadable.jsonl"; chmod 000 "$T/unreadable.jsonl"
msg="$(printf '{"session_id":"eee-555","transcript_path":"%s"}' "$T/unreadable.jsonl" | HOME="$home" bash "$H/archive-transcript.sh")"
ok "failed gzip tells the user" "$(jq -r .systemMessage <<<"$msg" | grep -c 'gzip into')" 1
ok "failed gzip leaves no partial file" "$(ls -A "$home/.claude/session-archive" | grep -c '^\.eee-555')" 0
chmod 600 "$T/unreadable.jsonl"
msg="$(printf '{"session_id":"ddd-444","transcript_path":"%s"}' "$T/missing.jsonl" | HOME="$home" bash "$H/archive-transcript.sh")"
ok "missing transcript is reported" "$(jq -r .systemMessage <<<"$msg" | grep -c 'transcript not found')" 1
in_session bbb-222 commit -q --allow-empty -m "seven"
in_session aaa-111 commit -q --amend --no-edit --allow-empty
out="$(cd "$repo" && HOME="$home" bash "$H/commit-session.sh" HEAD)"
ok "lookup finds the live transcript" "$(grep -c "aaa-111.*projects/p/aaa-111.jsonl" <<<"$out")" 1
ok "lookup finds the archived transcript" "$(grep -c "bbb-222.*session-archive/bbb-222.jsonl.gz" <<<"$out")" 1
plain="$(git -C "$repo" log --format=%H --grep='^three$')"
(cd "$repo" && HOME="$home" bash "$H/commit-session.sh" "$plain" >/dev/null 2>&1); ok "lookup on an untagged commit exits 1" "$?" 1
exit $fail
