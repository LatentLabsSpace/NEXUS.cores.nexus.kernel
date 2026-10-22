"""Deferred-nits ledger grammar, shared by pr-ledger.sh (validation),
pr-followup.py and pr-ledger-harvest.py.

A ledger is one PR comment starting with MARKER, posted by the PR author. Its
entries are the bullet lines ("- …" or "* …"); a deferred item that isn't a
bullet is invisible to every script here. Every entry ends with exactly one
status in bold; it is the entry's LAST bold span (a short note may follow it,
but no more bold):

  closed  **fixed in <sha>**   **done**   **decided …**   **skip: <reason>**
          **verified …**       **bead <id>**
  open    **follow-up**        (to be filed as a work item; the harvester does it)

Anything else is "unstated", which new ledgers may not contain (pr-ledger.sh
refuses them) and which the harvester treats as open in older ledgers.
"""
import re
import sys

MARKER = "<!-- pr-review-loop:deferred-ledger -->"

ENTRY_RE = re.compile(r"^\s*[-*]\s+\S")
# The status is the entry's LAST bold span; bold text earlier in the entry (a
# heading, an emphasised phrase) is never read as one. An unbolded
# "fixed in <sha>" counts only at the very end (older ledgers), so one quoted
# mid-sentence doesn't close an entry.
TAIL_RE = re.compile(r"\*\*([^*]+)\*\*(?!.*\*\*)")
BARE_FIXED_RE = re.compile(r"\bfixed in `?[0-9a-f]{7,40}`?[\s.;,)]*$", re.I)
BEAD_RE = re.compile(r"^\s*bead\s+([a-z][a-z0-9]*-[a-z0-9.]+)\s*$", re.I)
CLOSED_RE = re.compile(
    r"^\s*(fixed\b|done\b|decided\b|skip(ped)?\b|verified\b|resolved\b|withdrawn\b"
    r"|not applicable|n/a\b)",
    re.I,
)
FOLLOWUP_RE = re.compile(r"\*\*\s*follow-?up\b[^*]*\*\*", re.I)
PATH_RE = re.compile(r"`([A-Za-z0-9_.@/-]+/[A-Za-z0-9_.@/-]*|[A-Za-z0-9_-]+\.[A-Za-z0-9]{1,6})(?::\d+(?:-\d+)?)?`")


def entries(body):
    """(line_index, line) for every entry line of a ledger body."""
    return [(i, l) for i, l in enumerate(body.splitlines()) if ENTRY_RE.match(l)]


def status(line):
    """'bead' | 'closed' | 'follow-up' | 'unstated', read from the entry's end."""
    m = TAIL_RE.search(line)
    if m:
        tag = m.group(1)
        if BEAD_RE.match(tag):
            return "bead"
        if CLOSED_RE.match(tag):
            return "closed"
        if re.match(r"^\s*follow-?up\b", tag, re.I):
            return "follow-up"
    if BARE_FIXED_RE.search(line):
        return "closed"
    return "unstated"


def paths(line):
    """Repo paths named in backticks in an entry (':line' suffixes dropped)."""
    out = []
    for m in PATH_RE.finditer(line):
        p = m.group(1).strip("/")
        if p and p not in out and not p.startswith(("http", "#")):
            out.append(p)
    return out


def check(body):
    """Entries a new ledger may not contain: those with no stated status."""
    return [l for _, l in entries(body) if status(l) == "unstated"]


if __name__ == "__main__":
    # python3 ledger_status.py check <body-file>  → exit 1 listing unstated entries
    if len(sys.argv) == 3 and sys.argv[1] == "check":
        bad = check(open(sys.argv[2]).read())
        for l in bad:
            print(f"  no status: {l.strip()[:160]}", file=sys.stderr)
        sys.exit(1 if bad else 0)
    print("usage: ledger_status.py check <body-file>", file=sys.stderr)
    sys.exit(2)
