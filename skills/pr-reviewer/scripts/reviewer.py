#!/usr/bin/env python3
"""reviewer.py — PR-surface reviewer coordination (stdlib only).

The reviewer side of the PR loop, lifted from "one PR at a time" to "the whole
open-PR surface across several repos". GitHub PR comments are the shared,
authoritative state; a local state dir caches diffs and working notes so any
agent, from any checkout, can pick up where another left off.

Subcommands (run with --help on each):
  init      write/merge the state-dir config (repos, local clones, ttl)
  scan      fetch the surface, compute relations + review order, print a table
  next      scan, then claim the first actionable PR for --role and emit a work packet
  claim     claim one PR for --role (comment lock); exit 0 won, 11 held/lost, 10 already reviewed
  renew     refresh your claim's heartbeat
  release   delete your claim without reviewing
  snapshot  store the diff for the current head (+ interdiff vs the role's last reviewed head)
  checkout  make a detached worktree of the PR head from a local clone
  show      per-PR detail: relations, review history by role, claims, submodule bumps
  post      post a review (or --note) with markers; refuses trigger strings / stale heads
  reviews   per-role review state of one PR for the author side (pr-review-loop)

Commit statuses: each role's verdict is mirrored as a commit status
"review/<role>" on the head it covers (claim → pending, review → success or
failure), so branch rules can require each lens separately. The `aggregate`
role consolidates the other roles' reviews of the same head for the author.

Comment markers (invisible HTML comments; see references/protocol.md):
  <!-- pr-reviewer:claim  v=1 role=R head=SHA agent=A ts=EPOCH ttl=MIN -->
  <!-- pr-reviewer:review v=1 role=R head=SHA agent=A [refs=repo#n,...] -->
  <!-- pr-reviewer:note   v=1 role=R head=SHA agent=A -->
  <!-- review-verdict: blockers=N nits=M -->   (required on reviews; parsed by pr-review-loop)
"""
from __future__ import annotations

import argparse
import datetime as dt
import difflib
import getpass
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
STATE = Path(os.environ.get("PR_REVIEWER_STATE", Path.home() / ".local/state/pr-reviewer"))
DEFAULT_TTL = 60
MARKER_RE = re.compile(r"<!--\s*pr-reviewer:(claim|review|note)\s+(.*?)\s*-->", re.S)
VERDICT_RE = re.compile(r"<!--\s*review-verdict:\s*blockers=(\d+)\s+nits=(\d+)\s*-->", re.I)
# The review workflow fires on any PR comment containing this string, and
# GitHub's contains() is case-insensitive. Built by concatenation so this file
# never contains it literally either.
TRIGGER = "/" + "review"
LEGACY_HEAD_RE = re.compile(r"head\s+`([0-9a-f]{7,40})`", re.I)
# The author side's bookkeeping (pr-review-loop's deferred-nits ledger, updated in
# place every round). Reviewers read it, but it is not a reply that needs one.
AUTHOR_NOTE_RE = re.compile(r"<!--\s*pr-review-loop:")
REF_RE = re.compile(
    r"(?:https://github\.com/([\w.-]+/[\w.-]+)/(?:pull|issues)/(\d+))"
    r"|(?:\b([\w.-]+/[\w.-]+)#(\d+))"
    r"|(?:(?<![\w/&])#(\d+)\b)"
)
# Prose that relates PRs (authors write these; see references/protocol.md).
# Checked against the ~40 chars BEFORE a reference; first match wins.
REL_BEFORE = [
    ("depends-on", re.compile(r"(depends on|dependent on|blocked by|blocked on|requires|stacked on|builds on|"
                              r"on top of|merge after|lands? after|needs|base[: ]+\S*)\s*(?:PR\s*)?$", re.I)),
    ("supersedes", re.compile(r"(supersedes|replaces|replacement for|carry of|carries|closes)\s*(?:PR\s*)?$", re.I)),
    ("superseded-by", re.compile(r"(superseded by|replaced by|carry PR|carried (?:by|in))\s*:?\s*(?:PR\s*)?$", re.I)),
    ("follow-up-to", re.compile(r"(follow-?up (?:to|of|for)|backport of|cherry-?pick of|split from)\s*(?:PR\s*)?$", re.I)),
    ("conflicts-with", re.compile(r"(conflicts? with|collides with|overlaps with)\s*(?:PR\s*)?$", re.I)),
]
# ...and the ~40 chars AFTER it ("#6544, which must merge first").
MUST_FIRST_AFTER = re.compile(r"^\W{0,3}(?:,?\s*which\s+)?(?:must|should|needs to)\s+(?:merge|land)\s+first", re.I)
PRIO_RE = re.compile(r"(?:^|[\s:/_-])p([0-3])$|priority[\s:/_-]*(critical|high|medium|low)", re.I)
PRIO_WORDS = {"critical": 0, "high": 1, "medium": 2, "low": 3}

# Action classes, in review order (lower first).
CLASS_ORDER = {"rereview-blockers": 0, "reply": 1, "new": 2, "rereview": 3, "unknown-head": 3}

# Each role's verdict is mirrored as a commit status "<prefix><role>" on the head
# it covers. The status is the merge gate (branch rules can require each role
# separately); the review comment stays the record of findings.
STATUS_PREFIX = os.environ.get("PR_REVIEWER_STATUS_PREFIX", "review/")
# The aggregate role reads the other roles' reviews of one head and posts a
# single consolidated review for the author. It never changes their statuses.
AGGREGATE = "aggregate"


# ── gh plumbing ─────────────────────────────────────────────────────────────
_GH: list[str] | None = None


def gh_cmd() -> list[str]:
    """Prefer an authenticated `gh`; fall back to pr-review-loop's secrets-injecting gh.sh."""
    global _GH
    if _GH is not None:
        return _GH
    if os.environ.get("PR_REVIEWER_GH"):
        _GH = shlex.split(os.environ["PR_REVIEWER_GH"])
        return _GH
    ok = subprocess.run(["gh", "auth", "status"], capture_output=True).returncode == 0
    if ok:
        _GH = ["gh"]
        return _GH
    # Unauthenticated: use the token-injecting wrapper shipped beside this skill
    # (pr-review-loop's gh.sh routes GH_TOKEN through the current repo's /secrets
    # skill, so the token never reaches the conversation).
    wrapper = SCRIPT_DIR.parent.parent / "pr-review-loop" / "scripts" / "gh.sh"
    if wrapper.exists():
        _GH = ["bash", str(wrapper)]
        return _GH
    die("gh is not authenticated and the pr-review-loop gh.sh wrapper is missing; "
        "set PR_REVIEWER_GH to a command that runs gh with GH_TOKEN injected")


def gh(*args: str, check: bool = True, stdin: str | None = None) -> str:
    p = subprocess.run(gh_cmd() + list(args), capture_output=True, text=True, input=stdin)
    out = p.stdout
    marker = "ok: command completed successfully"
    if out.rstrip().endswith(marker):
        out = out.rstrip()[: -len(marker)]
    if check and p.returncode != 0:
        raise GhError(f"gh {' '.join(args[:3])}… failed (rc={p.returncode}): {p.stderr.strip()[:400]}")
    return out


class GhError(RuntimeError):
    pass


def gh_json(*args: str):
    out = gh(*args)
    return json.loads(out) if out.strip() else None


def gh_lines(*args: str) -> list[dict]:
    """`gh api --paginate --jq '.[] | @json'` → list of objects (gh 2.46 has no --slurp)."""
    out = gh(*args)
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def die(msg: str, code: int = 1):
    print(f"pr-reviewer: {msg}", file=sys.stderr)
    sys.exit(code)


def now() -> float:
    return time.time()


def iso_to_epoch(s: str) -> float:
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


# ── config / state ──────────────────────────────────────────────────────────
def load_config() -> dict:
    p = STATE / "config.json"
    cfg = json.loads(p.read_text()) if p.exists() else {}
    cfg.setdefault("repos", [])
    cfg.setdefault("clones", {})
    cfg.setdefault("ttl_minutes", DEFAULT_TTL)
    cfg.setdefault("aggregate_inputs", [])
    env_repos = os.environ.get("PR_REVIEWER_REPOS")
    if env_repos:
        cfg["repos"] = env_repos.split()
    env_inputs = os.environ.get("PR_REVIEWER_AGGREGATE_INPUTS")
    if env_inputs:
        cfg["aggregate_inputs"] = split_roles(env_inputs)
    return cfg


def split_roles(s: str | None) -> list[str]:
    return [r.strip() for r in (s or "").split(",") if r.strip()]


def pr_dir(repo: str, number: int) -> Path:
    d = STATE / repo.replace("/", "__") / f"pr-{number}"
    d.mkdir(parents=True, exist_ok=True)
    return d


def agent_id(args) -> str:
    return getattr(args, "agent", None) or os.environ.get("PR_REVIEWER_AGENT") or \
        f"{getpass.getuser()}@{socket.gethostname()}/{getattr(args, 'role', 'general')}"


def parse_target(t: str, cfg: dict) -> tuple[str, int]:
    m = re.match(r"https://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)", t)
    if m:
        return m.group(1), int(m.group(2))
    m = re.match(r"([\w.-]+/[\w.-]+)#(\d+)$", t)
    if m:
        return m.group(1), int(m.group(2))
    m = re.match(r"([\w.-]+)#(\d+)$", t)  # short repo name, resolved against config
    if m:
        hits = [r for r in cfg["repos"] if r.split("/")[1].lower() == m.group(1).lower()]
        if len(hits) == 1:
            return hits[0], int(m.group(2))
    die(f"can't parse PR target {t!r}; use owner/repo#N or a PR URL")


def short(repo: str) -> str:
    return repo.split("/")[1]


# ── fetching ────────────────────────────────────────────────────────────────
PR_FIELDS = ("number,title,url,headRefName,headRefOid,baseRefName,isDraft,labels,author,"
             "createdAt,updatedAt,body,files,additions,deletions,mergeable,statusCheckRollup")


def fetch_prs(repo: str) -> list[dict]:
    prs = gh_json("pr", "list", "--repo", repo, "--state", "open", "--limit", "100", "--json", PR_FIELDS) or []
    for p in prs:
        p["repo"] = repo
    return prs


def fetch_comments(repo: str, n: int) -> list[dict]:
    return gh_lines("api", "--paginate", f"repos/{repo}/issues/{n}/comments?per_page=100",
                    "--jq", ".[] | {id, body, user: .user.login, created_at, updated_at, html_url} | @json")


def fetch_commits(repo: str, n: int) -> list[dict]:
    return gh_lines("api", "--paginate", f"repos/{repo}/pulls/{n}/commits?per_page=100",
                    "--jq", ".[] | {sha, date: .commit.committer.date} | @json")


def fetch_pr(repo: str, n: int) -> dict:
    p = gh_json("pr", "view", str(n), "--repo", repo, "--json", PR_FIELDS)
    p["repo"] = repo
    return p


def parse_kv(s: str) -> dict:
    return dict(kv.split("=", 1) for kv in s.split() if "=" in kv)


def classify_comments(comments: list[dict]) -> dict:
    """Split comments into claims, reviews (per role), notes, author bookkeeping, bot chatter and plain activity."""
    claims, reviews, notes, author_notes, bots, plain = [], [], [], [], [], []
    for c in comments:
        body = c.get("body") or ""
        ms = MARKER_RE.findall(body)
        v = VERDICT_RE.search(body)
        if ms:
            kind, kv = ms[-1]
            meta = parse_kv(kv)
            entry = {**c, **{"kind": kind, "meta": meta}}
            if v:
                entry["verdict"] = {"blockers": int(v.group(1)), "nits": int(v.group(2))}
            {"claim": claims, "review": reviews, "note": notes}[kind].append(entry)
        elif v:
            # Legacy review (pre-surface): verdict trailer, head in the heading if any.
            h = LEGACY_HEAD_RE.search(body)
            reviews.append({**c, "kind": "review", "legacy": True,
                            "meta": {"role": "general", "head": h.group(1) if h else ""},
                            "verdict": {"blockers": int(v.group(1)), "nits": int(v.group(2))}})
        elif AUTHOR_NOTE_RE.search(body):
            author_notes.append(c)
        elif is_bot(c):
            # Labelers, CI summaries, dependency bots: never a reply to a review.
            bots.append(c)
        else:
            plain.append(c)
    return {"claims": claims, "reviews": reviews, "notes": notes, "author_notes": author_notes,
            "bots": bots, "plain": plain}


def is_bot(c: dict) -> bool:
    user = c.get("user")
    login = user.get("login", "") if isinstance(user, dict) else (user or "")
    return login.endswith("[bot]")


def claim_live(c: dict, ttl_default: int) -> bool:
    m = c["meta"]
    ts = float(m.get("ts") or iso_to_epoch(c["created_at"]))
    ttl = float(m.get("ttl") or ttl_default)
    return now() < ts + ttl * 60


def head_matches(a: str, b: str) -> bool:
    return bool(a) and bool(b) and (a.startswith(b) or b.startswith(a))


# ── commit statuses (the per-role merge gate) ───────────────────────────────
def statuses_enabled() -> bool:
    return os.environ.get("PR_REVIEWER_STATUSES", "1").lower() not in ("0", "false", "no", "off")


def plural(n: int, word: str) -> str:
    return f"{n} {word}{'' if n == 1 else 's'}"


def verdict_status(verdict: dict | None) -> tuple[str, str]:
    """(state, description) for a review verdict: blockers fail the role's check."""
    b, n = (verdict or {}).get("blockers", 0), (verdict or {}).get("nits", 0)
    if b:
        return "failure", f"{plural(b, 'blocker')}, {plural(n, 'nit')}"
    return "success", f"No blockers, {plural(n, 'nit')}" if n else "Clean — no findings"


def set_status(repo: str, sha: str, role: str, state: str, description: str, url: str | None = None) -> dict:
    """Mirror a role's state as commit status "<prefix><role>" on sha.

    Best-effort: the review comment is already the durable record, so a token
    without status permission must not lose a posted review. The failure is
    returned (and printed) so the caller can surface it — a required check that
    silently never turns green is worse than a loud warning.
    """
    ctx = f"{STATUS_PREFIX}{role}"
    if not statuses_enabled():
        return {"context": ctx, "skipped": "PR_REVIEWER_STATUSES is off"}
    if not re.fullmatch(r"[0-9a-f]{40}", sha or ""):
        return {"context": ctx, "skipped": f"not a full sha: {sha!r}"}
    args = ["api", "-X", "POST", f"repos/{repo}/statuses/{sha}", "-f", f"state={state}",
            "-f", f"context={ctx}", "-f", f"description={description[:140]}"]
    if url:
        args += ["-f", f"target_url={url}"]
    try:
        gh(*args)
    except GhError as e:
        print(f"surface: warning: could not set status {ctx}={state} on {sha[:7]}: {e}", file=sys.stderr)
        return {"context": ctx, "state": state, "error": str(e)[:200]}
    return {"context": ctx, "state": state, "description": description[:140]}


def fetch_statuses(repo: str, sha: str) -> dict[str, dict]:
    """role → latest "<prefix><role>" status on sha."""
    try:
        sts = (gh_json("api", f"repos/{repo}/commits/{sha}/status?per_page=100") or {}).get("statuses") or []
    except GhError:
        return {}
    out: dict[str, dict] = {}
    for st in sorted(sts, key=lambda x: x.get("updated_at") or ""):
        ctx = st.get("context") or ""
        if ctx.startswith(STATUS_PREFIX):
            out[ctx[len(STATUS_PREFIX):]] = {"state": st.get("state"), "description": st.get("description"),
                                             "updated_at": st.get("updated_at")}
    return out


def required_roles(repo: str, base: str) -> list[str]:
    """Roles whose "<prefix><role>" check the base branch requires (rulesets or classic
    protection). Best-effort: a token that can't read the rules contributes nothing."""
    ctxs: list[str] = []
    try:
        for rule in gh_json("api", f"repos/{repo}/rules/branches/{urllib.parse.quote(base, safe='')}") or []:
            if rule.get("type") == "required_status_checks":
                ctxs += [c.get("context", "") for c in rule.get("parameters", {}).get("required_status_checks", [])]
    except (GhError, ValueError):
        pass
    try:
        ctxs += (gh_json("api", f"repos/{repo}/branches/{urllib.parse.quote(base, safe='')}"
                                f"/protection/required_status_checks") or {}).get("contexts") or []
    except (GhError, ValueError):
        pass
    return sorted({c[len(STATUS_PREFIX):] for c in ctxs if c.startswith(STATUS_PREFIX)})


# ── replies ─────────────────────────────────────────────────────────────────
STANDARD_ROLES = ("general", "security", "ops", "spec", AGGREGATE)
ISSUECOMMENT_RE = re.compile(r"issuecomment-(\d+)")


def reply_targets(c: dict, cc: dict) -> set[str]:
    """Roles a reply is addressed to; empty = unaddressed (every role answers).

    A reply addresses a role by linking one of that role's reviews
    (…#issuecomment-<id>), or by naming it as "Re: <role>" or "@<role>" — so an
    author pushing back on one security finding wakes only the security
    reviewer, not every role on the PR.
    """
    body = c.get("body") or ""
    review_role = {r["id"]: r["meta"].get("role", "general") for r in cc["reviews"]}
    known = set(STANDARD_ROLES) | set(review_role.values()) | {x["meta"].get("role") for x in cc["claims"]}
    targets = {review_role[int(i)] for i in ISSUECOMMENT_RE.findall(body) if int(i) in review_role}
    for m in re.finditer(r"(?:\bre:\s*|@)([a-z][a-z0-9-]*)\b", body, re.I):
        if m.group(1).lower() in known:
            targets.add(m.group(1).lower())
    return targets


def replies_for(role: str, cc: dict, after_id: int) -> list[dict]:
    """Plain comments after `after_id` that this role should answer."""
    out = []
    for c in cc["plain"]:
        if c["id"] > after_id:
            t = reply_targets(c, cc)
            if not t or role in t:
                out.append(c)
    return out


# ── aggregate inputs ────────────────────────────────────────────────────────
def latest_reviews(cc: dict) -> dict[str, dict]:
    """role → that role's latest review comment."""
    out: dict[str, dict] = {}
    for r in sorted(cc["reviews"], key=lambda r: r["id"]):
        out[r["meta"].get("role", "general")] = r
    return out


def aggregate_inputs(pr: dict, cc: dict, inputs: list[str] | None = None,
                     ttl: int = DEFAULT_TTL) -> dict:
    """What the aggregate role would consolidate at the PR's current head.

    Inputs are the configured roles, else every non-aggregate role that has
    reviewed this PR. Ready only when each input has a review covering the head
    and none is mid-review there: aggregating a mix of heads, or racing a role
    that is about to post, would hand the author a stale merged view.
    """
    head = pr["headRefOid"]
    latest = latest_reviews(cc)
    roles = list(inputs) if inputs else sorted(r for r in latest if r != AGGREGATE)
    live = {c["meta"].get("role") for c in cc["claims"] if claim_live(c, ttl)}
    reviews, waiting = {}, []
    for role in roles:
        r = latest.get(role)
        if r and head_matches(r["meta"].get("head", ""), head):
            reviews[role] = r
        else:
            waiting.append(role)
    busy = sorted(set(roles) & live)
    return {"roles": roles, "reviews": reviews, "waiting_for": waiting, "in_progress": busy,
            "ready": bool(roles) and not waiting and not busy}


def role_status(pr: dict, cc: dict, commits: list[dict], role: str,
                inputs: list[str] | None = None, ttl: int = DEFAULT_TTL) -> dict:
    """Where this PR stands for one reviewer role."""
    if role == AGGREGATE:
        return aggregate_status(pr, cc, commits, inputs, ttl)
    head = pr["headRefOid"]
    revs = [r for r in cc["reviews"] if r["meta"].get("role", "general") == role]
    st: dict = {"role": role}
    if not revs:
        st["state"] = "new"
        return st
    last = max(revs, key=lambda r: r["id"])
    rh = last["meta"].get("head", "")
    st["last_review"] = {"id": last["id"], "url": last["html_url"], "head": rh,
                         "verdict": last.get("verdict"), "at": last["created_at"],
                         "legacy": bool(last.get("legacy"))}
    if head_matches(rh, head):
        later = replies_for(role, cc, last["id"])
        st["state"] = "reply" if later else "done"
        if later:
            st["replies"] = [c["html_url"] for c in later]
        return st
    if not rh:
        # Legacy review with no recorded head: stale iff a commit landed after it.
        rt = iso_to_epoch(last["created_at"])
        newer = [c for c in commits if iso_to_epoch(c["date"]) > rt]
        if not newer:
            later = replies_for(role, cc, last["id"])
            st["state"] = "reply" if later else "done"
            return st
    blockers = (last.get("verdict") or {}).get("blockers", 0)
    st["state"] = "rereview-blockers" if blockers else "rereview"
    return st


def aggregate_status(pr: dict, cc: dict, commits: list[dict], inputs: list[str] | None, ttl: int) -> dict:
    """The aggregate role's state: `waiting` until its inputs cover the head, then
    the usual states — plus re-aggregation when an input re-posted after it."""
    agg = aggregate_inputs(pr, cc, inputs, ttl)
    if not agg["ready"]:
        st = {"role": AGGREGATE, "state": "waiting", "inputs": agg["roles"],
              "waiting_for": agg["waiting_for"], "in_progress": agg["in_progress"]}
        last = latest_reviews(cc).get(AGGREGATE)
        if last:
            st["last_review"] = {"id": last["id"], "url": last["html_url"], "head": last["meta"].get("head", ""),
                                 "verdict": last.get("verdict"), "at": last["created_at"], "legacy": False}
        return st
    head = pr["headRefOid"]
    st = {"role": AGGREGATE, "inputs": agg["roles"]}
    last = latest_reviews(cc).get(AGGREGATE)
    if not last:
        st["state"] = "new"
        return st
    st["last_review"] = {"id": last["id"], "url": last["html_url"], "head": last["meta"].get("head", ""),
                         "verdict": last.get("verdict"), "at": last["created_at"], "legacy": False}
    newest_input = max(r["id"] for r in agg["reviews"].values())
    if head_matches(last["meta"].get("head", ""), head) and last["id"] > newest_input:
        later = replies_for(AGGREGATE, cc, last["id"])
        st["state"] = "reply" if later else "done"
        if later:
            st["replies"] = [c["html_url"] for c in later]
        return st
    blockers = (last.get("verdict") or {}).get("blockers", 0)
    st["state"] = "rereview-blockers" if blockers else "rereview"
    return st


# ── relations ───────────────────────────────────────────────────────────────
def gitmodules(repo: str, ref: str) -> dict[str, str]:
    """submodule path → owner/repo (GitHub only)."""
    try:
        raw = gh("api", f"repos/{repo}/contents/.gitmodules?ref={urllib.parse.quote(ref)}",
                 "-H", "Accept: application/vnd.github.raw")
    except GhError:
        return {}
    out, path = {}, None
    for line in raw.splitlines():
        line = line.strip()
        if line.startswith("path"):
            path = line.split("=", 1)[1].strip()
        elif line.startswith("url") and path:
            m = re.search(r"github\.com[:/]([\w.-]+/[\w.-]+?)(?:\.git)?$", line.split("=", 1)[1].strip())
            if m:
                out[path] = m.group(1)
    return out


def text_refs(text: str, default_repo: str) -> list[tuple[str, int, str]]:
    """(repo, number, relation-kind) for every PR/issue reference in text."""
    refs = []
    text = text or ""
    for m in REF_RE.finditer(text):
        repo = m.group(1) or m.group(3) or default_repo
        num = int(m.group(2) or m.group(4) or m.group(5))
        before = text[max(0, m.start() - 40): m.start()].rstrip(" (`*_")
        after = text[m.end(): m.end() + 40]
        kind = next((k for k, rx in REL_BEFORE if rx.search(before)), None)
        if kind is None and MUST_FIRST_AFTER.search(after):
            kind = "depends-on"
        refs.append((repo, num, kind or "mentions"))
    return refs


def compute_relations(prs: list[dict], ccs: dict) -> dict:
    """Edges between open PRs: stacked, depends, mentions, overlaps, submodule-bump."""
    key = lambda p: f"{p['repo']}#{p['number']}"
    by_key = {key(p): p for p in prs}
    lower = {k.lower(): k for k in by_key}
    rel: dict[str, list[dict]] = {k: [] for k in by_key}
    deps: dict[str, set[str]] = {k: set() for k in by_key}

    def add(a, kind, b, detail=""):
        if a != b and not any(r["kind"] == kind and r["pr"] == b for r in rel[a]):
            rel[a].append({"kind": kind, "pr": b, **({"detail": detail} if detail else {})})

    heads = {(p["repo"], p["headRefName"]): key(p) for p in prs}
    for p in prs:
        k = key(p)
        # stacked: base branch is another open PR's head branch
        parent = heads.get((p["repo"], p["baseRefName"]))
        if parent:
            add(k, "stacked-on", parent)
            add(parent, "stack-parent-of", k)
            deps[k].add(parent)
        # explicit references in body + human (non-marker) comments + reviews
        texts = [p.get("body") or ""] + [c["body"] or "" for c in ccs[k]["plain"]] + \
                [r["body"] or "" for r in ccs[k]["reviews"] + ccs[k]["notes"]]
        for t in texts:
            for repo, num, kind in text_refs(t, p["repo"]):
                other = lower.get(f"{repo}#{num}".lower())
                if not other or other == k:
                    continue
                add(k, kind, other)
                if kind == "depends-on":
                    deps[k].add(other)
                elif kind == "supersedes":
                    add(other, "superseded-by", k)
                elif kind == "superseded-by":
                    add(other, "supersedes", k)
    # same branch name in different repos: usually one change split across repos
    for i, a in enumerate(prs):
        for b in prs[i + 1:]:
            if a["repo"] != b["repo"] and a["headRefName"] == b["headRefName"]:
                add(key(a), "sibling-branch", key(b), a["headRefName"])
                add(key(b), "sibling-branch", key(a), a["headRefName"])
    # file overlap within a repo
    for i, a in enumerate(prs):
        fa = {f["path"] for f in a.get("files") or []}
        for b in prs[i + 1:]:
            if a["repo"] != b["repo"]:
                continue
            shared = sorted(fa & {f["path"] for f in b.get("files") or []})
            if shared:
                d = ", ".join(shared[:4]) + (f" (+{len(shared) - 4})" if len(shared) > 4 else "")
                add(key(a), "overlaps", key(b), d)
                add(key(b), "overlaps", key(a), d)
    # submodule bumps pointing at a repo that is also on the surface
    mods_cache: dict[str, dict] = {}
    for p in prs:
        files = {f["path"] for f in p.get("files") or []}
        if not files:
            continue
        if p["repo"] not in mods_cache:
            mods_cache[p["repo"]] = gitmodules(p["repo"], p["baseRefName"])
        for path, up in mods_cache[p["repo"]].items():
            if path in files:
                open_up = sorted(key(q) for q in prs if q["repo"].lower() == up.lower())
                add(key(p), "bumps-submodule", up, f"{path}" + (
                    f"; upstream open: {', '.join(open_up)}" if open_up else ""))
    return {"relations": rel, "deps": deps}


def prio_rank(pr: dict) -> int:
    best = 2
    for lab in pr.get("labels") or []:
        m = PRIO_RE.search(lab.get("name", ""))
        if m:
            best = min(best, int(m.group(1)) if m.group(1) else PRIO_WORDS[m.group(2).lower()])
    return best


def order(items: list[dict], deps: dict[str, set[str]]) -> list[dict]:
    """Class/priority sort, then a stable topological pass so dependencies go first."""
    superseded = lambda it: any(r["kind"] == "superseded-by" for r in it["relations"])
    items = sorted(items, key=lambda it: (superseded(it), it["prio"], CLASS_ORDER.get(it["status"]["state"], 9),
                                          it["createdAt"], it["repo"], it["number"]))
    pending = {it["key"] for it in items}
    out: list[dict] = []
    while items:
        for i, it in enumerate(items):
            if not (deps.get(it["key"], set()) & (pending - {it["key"]})):
                break
        else:
            i = 0  # cycle: fall back to sorted order
        it = items.pop(i)
        pending.discard(it["key"])
        out.append(it)
    return out


def checks_summary(pr: dict) -> str:
    # Review statuses are this skill's own output, not CI.
    roll = [c for c in pr.get("statusCheckRollup") or [] if not (c.get("context") or "").startswith(STATUS_PREFIX)]
    states = [(c.get("conclusion") or c.get("state") or c.get("status") or "").upper() for c in roll]
    if not states:
        return "-"
    if any(s in ("FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED") for s in states):
        return "red"
    if any(s in ("PENDING", "QUEUED", "IN_PROGRESS", "EXPECTED", "") for s in states):
        return "pending"
    return "green"


def build_surface(repos: list[str], roles: list[str], include_drafts: bool, ttl: int,
                  inputs: list[str] | None = None) -> dict:
    prs = []
    for r in repos:
        prs.extend(fetch_prs(r))
    if not include_drafts:
        prs = [p for p in prs if not p.get("isDraft")]
    ccs, commits = {}, {}
    for p in prs:
        k = f"{p['repo']}#{p['number']}"
        ccs[k] = classify_comments(fetch_comments(p["repo"], p["number"]))
        commits[k] = fetch_commits(p["repo"], p["number"])
    graph = compute_relations(prs, ccs)
    items = []
    for p in prs:
        k = f"{p['repo']}#{p['number']}"
        live = [c for c in ccs[k]["claims"] if claim_live(c, ttl)]
        for role in roles:
            st = role_status(p, ccs[k], commits[k], role, inputs, ttl)
            rc = sorted((c for c in live if c["meta"].get("role") == role), key=lambda c: c["id"])
            items.append({
                "key": k, "repo": p["repo"], "number": p["number"], "title": p["title"],
                "url": p["url"], "head": p["headRefOid"], "base": p["baseRefName"],
                "createdAt": p["createdAt"], "updatedAt": p["updatedAt"], "role": role,
                "prio": prio_rank(p), "status": st, "checks": checks_summary(p),
                "mergeable": p.get("mergeable"), "size": (p.get("additions") or 0) + (p.get("deletions") or 0),
                "claim": ({"agent": rc[0]["meta"].get("agent"), "id": rc[0]["id"],
                           "head": rc[0]["meta"].get("head"), "at": rc[0]["created_at"]} if rc else None),
                # Every live claim on the PR, any role — who else is working here right now.
                "active": [{"role": c["meta"].get("role"), "agent": c["meta"].get("agent"),
                            "head": (c["meta"].get("head") or "")[:7]}
                           for c in sorted(live, key=lambda c: c["id"]) if c["meta"].get("role") != role],
                "relations": graph["relations"][k],
            })
    actionable = [it for it in items if it["status"]["state"] not in ("done", "waiting")]
    done = [it for it in items if it["status"]["state"] == "done"]
    waiting = [it for it in items if it["status"]["state"] == "waiting"]
    deps = {k: set(v) for k, v in graph["deps"].items()}
    ordered = order(actionable, deps)
    surf = {"generated_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
            "repos": repos, "roles": roles, "queue": ordered,
            "done": sorted(done, key=lambda it: (it["repo"], it["number"], it["role"])),
            "waiting": sorted(waiting, key=lambda it: (it["repo"], it["number"]))}
    STATE.mkdir(parents=True, exist_ok=True)
    (STATE / "surface.json").write_text(json.dumps(surf, indent=2))
    return surf


def print_surface(surf: dict):
    print(f"# PR surface — {', '.join(surf['repos'])} — roles: {', '.join(surf['roles'])} "
          f"({surf['generated_at']})")
    print(f"{'#':>2}  {'PR':<14} {'role':<9} {'state':<18} {'prior':<8} {'ci':<7} {'claim':<22} title")
    for i, it in enumerate(surf["queue"], 1):
        lr = it["status"].get("last_review") or {}
        v = lr.get("verdict") or {}
        prior = f"{v.get('blockers', '-')}b/{v.get('nits', '-')}n" if lr else "-"
        claim = (it["claim"]["agent"] or "?")[:22] if it["claim"] else ""
        print(f"{i:>2}  {short(it['repo']) + '#' + str(it['number']):<14} {it['role']:<9} "
              f"{it['status']['state']:<18} {prior:<8} {it['checks']:<7} {claim:<22} {it['title'][:60]}")
        for r in it["relations"]:
            if r["kind"] in ("mentions",):
                continue
            print(f"      ↳ {r['kind']} {r['pr']}" + (f" — {r['detail']}" if r.get("detail") else ""))
        for c in it.get("active", []):
            print(f"      ⚑ {c['role']} review in progress by {c['agent']} (head {c['head']})")
    if surf.get("waiting"):
        print("\n# Aggregate waiting for its inputs to cover the head")
        for it in surf["waiting"]:
            st = it["status"]
            why = ", ".join(st.get("waiting_for") or []) or "no input reviews yet"
            busy = f"; in progress: {', '.join(st['in_progress'])}" if st.get("in_progress") else ""
            print(f"    {short(it['repo'])}#{it['number']} — waiting for {why}{busy} — {it['title'][:50]}")
    if surf["done"]:
        print("\n# Up to date (review covers head, no replies since)")
        for it in surf["done"]:
            v = it["status"]["last_review"].get("verdict") or {}
            print(f"    {short(it['repo'])}#{it['number']} [{it['role']}] "
                  f"{v.get('blockers', '?')}b/{v.get('nits', '?')}n — {it['title'][:60]}")


# ── claims ──────────────────────────────────────────────────────────────────
def claim_body(role: str, head: str, agent: str, ttl: int) -> str:
    return (f"<!-- pr-reviewer:claim v=1 role={role} head={head} agent={agent} ts={int(now())} ttl={ttl} -->\n"
            f"🔎 Review in progress — role **{role}**, head `{head[:7]}` ({agent}). "
            f"This placeholder is removed when the review is posted.")


def claims_file(repo: str, n: int, role: str) -> Path:
    return pr_dir(repo, n) / f"claim-{role}.json"


def do_claim(repo: str, n: int, role: str, agent: str, ttl: int, force: bool = False,
             inputs: list[str] | None = None) -> tuple[int, dict]:
    """Comment-lock protocol. Returns (exit_code, info)."""
    pr = fetch_pr(repo, n)
    head = pr["headRefOid"]
    cc = classify_comments(fetch_comments(repo, n))
    st = role_status(pr, cc, fetch_commits(repo, n), role, inputs, ttl)
    if st["state"] == "done" and not force:
        return 10, {"reason": "already reviewed at head", "status": st}
    if st["state"] == "waiting" and not force:
        return 12, {"reason": "aggregate inputs not ready at head", "status": st}
    held = [c for c in cc["claims"] if c["meta"].get("role") == role and claim_live(c, ttl)]
    if held:
        mine = [c for c in held if c["meta"].get("agent") == agent]
        if mine:
            return 0, {"claim_id": mine[0]["id"], "head": head, "status": st, "reused": True}
        return 11, {"reason": "held", "holder": held[0]["meta"].get("agent"), "claim_id": held[0]["id"]}
    posted = gh_json("api", f"repos/{repo}/issues/{n}/comments", "-f", f"body={claim_body(role, head, agent, ttl)}")
    my_id = posted["id"]
    # Race check: re-read; the lowest-id live claim for this role wins.
    time.sleep(2)
    cc2 = classify_comments(fetch_comments(repo, n))
    live = sorted((c for c in cc2["claims"] if c["meta"].get("role") == role and claim_live(c, ttl)),
                  key=lambda c: c["id"])
    if live and live[0]["id"] != my_id:
        gh("api", "-X", "DELETE", f"repos/{repo}/issues/comments/{my_id}", check=False)
        return 11, {"reason": "lost race", "holder": live[0]["meta"].get("agent"), "claim_id": live[0]["id"]}
    info = {"claim_id": my_id, "head": head, "agent": agent, "role": role, "status": st,
            "claimed_at": int(now()), "ttl": ttl}
    claims_file(repo, n, role).write_text(json.dumps(info, indent=2))
    until = dt.datetime.fromtimestamp(now() + ttl * 60, dt.timezone.utc).strftime("%H:%MZ")
    # The claim can die with its agent; the expiry says when "in progress" stops meaning it.
    info["commit_status"] = set_status(repo, head, role, "pending",
                                       f"Review in progress ({agent}, claim until {until})")
    return 0, info


def find_my_claim(repo: str, n: int, role: str, agent: str) -> dict | None:
    cf = claims_file(repo, n, role)
    local = json.loads(cf.read_text()) if cf.exists() else {}
    cc = classify_comments(fetch_comments(repo, n))
    for c in cc["claims"]:
        if c["id"] == local.get("claim_id") or (c["meta"].get("role") == role and c["meta"].get("agent") == agent):
            return c
    return None


def cleanup_claims(repo: str, n: int, role: str, agent: str, ttl: int, my_id: int | None = None):
    """Delete this agent's claim(s) for the role plus any expired claims for it."""
    cc = classify_comments(fetch_comments(repo, n))
    for c in cc["claims"]:
        if c["meta"].get("role") != role:
            continue
        if c["id"] == my_id or c["meta"].get("agent") == agent or not claim_live(c, ttl):
            gh("api", "-X", "DELETE", f"repos/{repo}/issues/comments/{c['id']}", check=False)
    cf = claims_file(repo, n, role)
    if cf.exists():
        cf.unlink()


# ── diffs ───────────────────────────────────────────────────────────────────
def compare_diff(repo: str, base: str, head: str) -> str:
    return gh("api", f"repos/{repo}/compare/{urllib.parse.quote(base, safe='')}...{head}",
              "-H", "Accept: application/vnd.github.diff")


def snapshot(repo: str, n: int, role: str, pr: dict | None = None) -> dict:
    """Store <head>.diff; if the role reviewed an earlier head, also write an interdiff."""
    pr = pr or fetch_pr(repo, n)
    head, d = pr["headRefOid"], pr_dir(repo, n)
    heads = d / "heads"
    heads.mkdir(exist_ok=True)
    dpath = heads / f"{head}.diff"
    if not dpath.exists():
        try:
            diff = compare_diff(repo, pr["baseRefName"], head)
        except GhError:
            diff = gh("pr", "diff", str(n), "--repo", repo)
            if fetch_pr(repo, n)["headRefOid"] != head:
                die("head moved while fetching the diff; re-run snapshot", 4)
        dpath.write_text(diff)
        (heads / f"{head}.meta.json").write_text(json.dumps({
            "title": pr["title"], "base": pr["baseRefName"], "head": head,
            "files": [f["path"] for f in pr.get("files") or []],
            "fetched_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")}, indent=2))
    out = {"head": head, "diff": str(dpath), "lines": sum(1 for _ in dpath.open())}
    cc = classify_comments(fetch_comments(repo, n))
    revs = sorted((r for r in cc["reviews"] if r["meta"].get("role", "general") == role), key=lambda r: r["id"])
    if revs:
        last = revs[-1]
        old = last["meta"].get("head", "")
        out["prior_review"] = {"url": last["html_url"], "head": old, "verdict": last.get("verdict")}
        (d / f"last-review-{role}.md").write_text(last["body"] or "")
        out["prior_review"]["body"] = str(d / f"last-review-{role}.md")
        if old and not head_matches(old, head):
            ip = d / f"interdiff-{old[:12]}-{head[:12]}.diff"
            if not ip.exists():
                try:
                    cmp = gh_json("api", f"repos/{repo}/compare/{old}...{head}")
                    status = cmp.get("status")
                except GhError:
                    status = None
                if status == "ahead":
                    ip.write_text(compare_diff(repo, old, head))
                    out["interdiff_kind"] = "commits"
                else:
                    # Rebased / force-pushed: diff the two PR diffs instead.
                    oldp = next(iter(heads.glob(f"{old}*.diff")), None)
                    if oldp is None:
                        try:
                            oldp = heads / f"{old}.diff"
                            oldp.write_text(compare_diff(repo, pr["baseRefName"], old))
                        except GhError:
                            oldp = None
                    if oldp:
                        ip.write_text("".join(difflib.unified_diff(
                            oldp.read_text().splitlines(True), dpath.read_text().splitlines(True),
                            f"pr-diff@{old[:7]}", f"pr-diff@{head[:7]}")))
                        out["interdiff_kind"] = "diff-of-diffs (branch was rebased/force-pushed)"
            if ip.exists():
                out["interdiff"] = str(ip)
                out["interdiff_lines"] = sum(1 for _ in ip.open())
                out.setdefault("interdiff_kind", "cached")
    # Submodule bumps: which upstream PRs does the bump carry?
    bumps = []
    txt = dpath.read_text()
    for m in re.finditer(r"^diff --git a/(\S+) b/\S+\n(?:.*\n){0,4}?-Subproject commit ([0-9a-f]{40})\n\+Subproject commit ([0-9a-f]{40})",
                         txt, re.M):
        bumps.append({"path": m.group(1), "from": m.group(2), "to": m.group(3)})
    if bumps:
        mods = gitmodules(repo, pr["headRefOid"])
        for b in bumps:
            up = mods.get(b["path"])
            b["upstream"] = up
            if not up:
                continue
            b["compare_url"] = f"https://github.com/{up}/compare/{b['from'][:12]}...{b['to'][:12]}"
            try:
                cmp = gh_json("api", f"repos/{up}/compare/{b['from']}...{b['to']}")
                commits = cmp.get("commits", [])[-60:]
                b["commits"] = cmp.get("total_commits")
                # A published shard ("Published shard of OWNER/REPO:path") has rewritten
                # commits, so PR association must come from "(#N)" in commit messages
                # against the source repo, not from the shard's own PR index.
                desc = (gh_json("api", f"repos/{up}") or {}).get("description") or ""
                sm = re.match(r"Published shard of ([\w.-]+/[\w.-]+):(\S+)", desc)
                pulls = {}
                if sm:
                    src_repo, src_path = sm.group(1), sm.group(2)
                    b["shard_of"] = f"{src_repo}:{src_path}"
                    # Shard commits read "Sync from <path>@<source sha>": map both ends
                    # back to the source repo and list the merged PRs in between that
                    # touched the sharded path.
                    def src_sha(sha):
                        msg = gh_json("api", f"repos/{up}/commits/{sha}")["commit"]["message"]
                        m2 = re.search(r"Sync from \S+@([0-9a-f]{7,40})", msg)
                        return m2.group(1) if m2 else None
                    s_from, s_to = src_sha(b["from"]), src_sha(b["to"])
                    b["source_range"] = f"{src_repo}@{s_from}...{s_to}"
                    nums = set()
                    if s_from and s_to:
                        scmp = gh_json("api", f"repos/{src_repo}/compare/{s_from}...{s_to}")
                        for c in scmp.get("commits", []):
                            nums |= {int(x) for x in re.findall(r"(?:pull request |\()#(\d+)",
                                                                c["commit"]["message"])}
                    for num in sorted(nums)[-25:]:
                        files = gh_lines("api", "--paginate", f"repos/{src_repo}/pulls/{num}/files?per_page=100",
                                         "--jq", ".[] | {filename} | @json")
                        if not any(f["filename"].startswith(src_path.rstrip("/") + "/") for f in files):
                            continue
                        q = gh_json("pr", "view", str(num), "--repo", src_repo,
                                    "--json", "number,title,state,mergedAt,headRefOid")
                        pulls[num] = {"repo": src_repo, "number": num, "title": q["title"],
                                      "state": q["state"], "merged": bool(q.get("mergedAt")),
                                      "head": q["headRefOid"]}
                else:
                    for c in commits:
                        for q in gh_json("api", f"repos/{up}/commits/{c['sha']}/pulls") or []:
                            pulls[q["number"]] = {"repo": up, "number": q["number"], "title": q["title"],
                                                  "state": q["state"], "merged": bool(q.get("merged_at"))}
                b["upstream_prs"] = sorted(pulls.values(), key=lambda q: q["number"])
            except GhError as e:
                b["error"] = str(e)[:200]
        out["submodule_bumps"] = bumps
    (d / "snapshot.json").write_text(json.dumps(out, indent=2))
    return out


# ── commands ────────────────────────────────────────────────────────────────
def roles_arg(args) -> list[str]:
    return [r.strip() for r in (args.role or "general").split(",") if r.strip()]


def repos_arg(args, cfg) -> list[str]:
    repos = args.repos or cfg["repos"]
    if not repos:
        die("no repos: pass them, set PR_REVIEWER_REPOS, or run `reviewer.py init --repo owner/name ...`")
    return repos


def cmd_init(args):
    cfg = load_config()
    for r in args.repo or []:
        if r not in cfg["repos"]:
            cfg["repos"].append(r)
    for c in args.clone or []:
        repo, path = c.split("=", 1)
        cfg["clones"][repo] = str(Path(path).resolve())
    if args.ttl:
        cfg["ttl_minutes"] = args.ttl
    if args.aggregate_inputs is not None:
        cfg["aggregate_inputs"] = split_roles(args.aggregate_inputs)
    STATE.mkdir(parents=True, exist_ok=True)
    (STATE / "config.json").write_text(json.dumps(cfg, indent=2))
    print(json.dumps({"state_dir": str(STATE), **cfg}, indent=2))


def cmd_scan(args):
    cfg = load_config()
    surf = build_surface(repos_arg(args, cfg), roles_arg(args), args.include_drafts, cfg["ttl_minutes"],
                         cfg["aggregate_inputs"])
    if args.json:
        print(json.dumps(surf, indent=2))
    else:
        print_surface(surf)
        print(f"\n(saved {STATE / 'surface.json'})")


def packet_for(repo: str, n: int, role: str, info: dict, surf_item: dict | None) -> dict:
    snap = snapshot(repo, n, role)
    d = pr_dir(repo, n)
    notes = d / "notes.md"
    if not notes.exists():
        notes.write_text(f"# Reviewer notes — {repo}#{n}\n\nAppend-only; one dated section per pass/role.\n")
    pr = fetch_pr(repo, n)
    cc = classify_comments(fetch_comments(repo, n))
    mine = [r for r in cc["reviews"] if r["meta"].get("role", "general") == role]
    since = max((r["id"] for r in mine), default=0)
    others = {}
    for r in sorted(cc["reviews"], key=lambda r: r["id"]):
        rl = r["meta"].get("role", "general")
        if rl != role:
            others[rl] = {"head": r["meta"].get("head"), "verdict": r.get("verdict"), "url": r["html_url"]}
    pkt = {"repo": repo, "number": n, "url": f"https://github.com/{repo}/pull/{n}", "role": role,
           # The PR's own claims (title/body) are part of what gets reviewed.
           "pr": {"title": pr.get("title"), "author": (pr.get("author") or {}).get("login"),
                  "body": pr.get("body") or "", "labels": [l.get("name") for l in pr.get("labels") or []],
                  "base": pr.get("baseRefName"), "head_ref": pr.get("headRefName"),
                  "checks": checks_summary(pr), "mergeable": pr.get("mergeable")},
           # Human/author conversation (non-marker comments) since this role's last review,
           # or the whole thread for a first review — replies and pushback live here.
           "conversation": [{"id": c["id"], "author": c.get("user"), "at": c["created_at"],
                             "url": c["html_url"], "body": c["body"]}
                            for c in sorted(cc["plain"] + cc["author_notes"], key=lambda c: c["id"])
                            if c["id"] > since],
           "other_roles": others,
           "other_role_claims": [{"role": c["meta"].get("role"), "agent": c["meta"].get("agent"),
                                  "head": c["meta"].get("head"), "live": claim_live(c, load_config()["ttl_minutes"])}
                                 for c in cc["claims"] if c["meta"].get("role") != role],
           "claim": info, "snapshot": snap, "notes": str(notes), "pr_dir": str(d),
           "relations": (surf_item or {}).get("relations", []),
           "status": info.get("status") or (surf_item or {}).get("status")}
    if role == AGGREGATE:
        # The aggregate reviews the reviews: give it every input's full text at this head.
        agg = aggregate_inputs(pr, cc, load_config()["aggregate_inputs"], load_config()["ttl_minutes"])
        pkt["inputs"] = [{"role": rl, "head": r["meta"].get("head"), "verdict": r.get("verdict"),
                          "url": r["html_url"], "agent": r["meta"].get("agent"), "body": r["body"]}
                         for rl, r in sorted(agg["reviews"].items())]
        pkt["inputs_waiting_for"] = agg["waiting_for"]
    (d / f"packet-{role}.json").write_text(json.dumps(pkt, indent=2))
    return pkt


def cmd_next(args):
    cfg = load_config()
    roles = roles_arg(args)
    surf = build_surface(repos_arg(args, cfg), roles, args.include_drafts, cfg["ttl_minutes"],
                         cfg["aggregate_inputs"])
    for it in surf["queue"]:
        if it["claim"] and it["claim"]["agent"] != agent_id(argparse.Namespace(role=it["role"], agent=args.agent)):
            continue
        if args.only and it["status"]["state"] not in args.only.split(","):
            continue
        agent = agent_id(argparse.Namespace(role=it["role"], agent=args.agent))
        code, info = do_claim(it["repo"], it["number"], it["role"], agent, cfg["ttl_minutes"],
                              inputs=cfg["aggregate_inputs"])
        if code == 0:
            print(json.dumps(packet_for(it["repo"], it["number"], it["role"], info, it), indent=2))
            return
    print(json.dumps({"idle": True, "queue_len": len(surf["queue"]),
                      "note": "nothing actionable and unclaimed for these roles"}))
    sys.exit(2)


def cmd_claim(args):
    cfg = load_config()
    repo, n = parse_target(args.pr, cfg)
    role = roles_arg(args)[0]
    code, info = do_claim(repo, n, role, agent_id(args), cfg["ttl_minutes"], force=args.force,
                          inputs=cfg["aggregate_inputs"])
    if code == 0 and args.packet:
        info = packet_for(repo, n, role, info, None)
    print(json.dumps(info, indent=2))
    sys.exit(code)


def cmd_renew(args):
    cfg = load_config()
    repo, n = parse_target(args.pr, cfg)
    role = roles_arg(args)[0]
    c = find_my_claim(repo, n, role, agent_id(args))
    if not c:
        die("no claim of yours found (expired and cleaned up?) — re-claim", 11)
    m = c["meta"]
    gh("api", "-X", "PATCH", f"repos/{repo}/issues/comments/{c['id']}",
       "-f", f"body={claim_body(role, m.get('head', ''), m.get('agent', agent_id(args)), cfg['ttl_minutes'])}")
    print(json.dumps({"renewed": c["id"]}))


def cmd_release(args):
    cfg = load_config()
    repo, n = parse_target(args.pr, cfg)
    role = roles_arg(args)[0]
    c = find_my_claim(repo, n, role, agent_id(args))
    cleanup_claims(repo, n, role, agent_id(args), cfg["ttl_minutes"], c["id"] if c else None)
    remove_worktrees(repo, n, agent_id(args))
    out = {"released": bool(c)}
    if c:
        # Our claim set "<prefix><role>" to "in progress". Unless this head is
        # already reviewed, say plainly that nobody is reviewing it now.
        pr = fetch_pr(repo, n)
        st = role_status(pr, classify_comments(fetch_comments(repo, n)), fetch_commits(repo, n), role,
                         cfg["aggregate_inputs"], cfg["ttl_minutes"])
        if st["state"] != "done":
            out["commit_status"] = set_status(repo, pr["headRefOid"], role, "pending",
                                              "Awaiting review (claim released)")
    print(json.dumps(out))


def cmd_snapshot(args):
    cfg = load_config()
    repo, n = parse_target(args.pr, cfg)
    print(json.dumps(snapshot(repo, n, roles_arg(args)[0]), indent=2))


def cmd_checkout(args):
    cfg = load_config()
    repo, n = parse_target(args.pr, cfg)
    clone = args.clone or cfg["clones"].get(repo)
    if not clone:
        die(f"no local clone for {repo}; pass --clone PATH or `init --clone {repo}=PATH`")
    pr = fetch_pr(repo, n)
    head = pr["headRefOid"]
    agent = agent_id(args)
    # One worktree per agent: parallel roles testing the same head must not share
    # build artifacts, venvs or node_modules.
    slug = re.sub(r"[^A-Za-z0-9._-]+", "_", agent)
    wt = Path(args.dest) if args.dest else STATE / "worktrees" / slug / f"{short(repo)}-{n}-{head[:7]}"
    if not wt.exists():
        wt.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "-C", clone, "fetch", "--quiet", "origin", f"pull/{n}/head"], check=True)
        subprocess.run(["git", "-C", clone, "worktree", "add", "--detach", "--quiet", str(wt), head], check=True)
    # Record it so post/release remove it.
    reg = pr_dir(repo, n) / f"worktrees-{slug}.json"
    known = json.loads(reg.read_text()) if reg.exists() else []
    if str(wt) not in [k["path"] for k in known]:
        known.append({"path": str(wt), "clone": clone, "head": head})
        reg.write_text(json.dumps(known, indent=2))
    setup = [f for f in ("package.json", "pyproject.toml", ".mise.toml", "go.mod", "Cargo.toml") if (wt / f).exists()]
    print(json.dumps({"worktree": str(wt), "head": head, "project_files": setup,
                      "note": "install dependencies inside this worktree (its own venv / node_modules), "
                              "never into the main clone's environment",
                      "remove": f"git -C {clone} worktree remove --force {wt}"}, indent=2))


def remove_worktrees(repo: str, n: int, agent: str):
    slug = re.sub(r"[^A-Za-z0-9._-]+", "_", agent)
    reg = pr_dir(repo, n) / f"worktrees-{slug}.json"
    if not reg.exists():
        return
    for k in json.loads(reg.read_text()):
        if Path(k["path"]).exists():
            subprocess.run(["git", "-C", k["clone"], "worktree", "remove", "--force", k["path"]],
                           capture_output=True)
    reg.unlink()


def cmd_show(args):
    cfg = load_config()
    repo, n = parse_target(args.pr, cfg)
    pr = fetch_pr(repo, n)
    cc = classify_comments(fetch_comments(repo, n))
    commits = fetch_commits(repo, n)
    roles = sorted({r["meta"].get("role", "general") for r in cc["reviews"]} | set(roles_arg(args)))
    surf_rel = []
    sp = STATE / "surface.json"
    if sp.exists():
        for it in json.loads(sp.read_text())["queue"] + json.loads(sp.read_text())["done"]:
            if it["repo"] == repo and it["number"] == n:
                surf_rel = it["relations"]
                break
    print(json.dumps({
        "pr": f"{repo}#{n}", "title": pr["title"], "head": pr["headRefOid"], "base": pr["baseRefName"],
        "checks": checks_summary(pr), "mergeable": pr.get("mergeable"),
        "roles": {r: role_status(pr, cc, commits, r, cfg["aggregate_inputs"], cfg["ttl_minutes"]) for r in roles},
        "reviews": [{"id": r["id"], "role": r["meta"].get("role", "general"), "head": r["meta"].get("head"),
                     "verdict": r.get("verdict"), "url": r["html_url"], "legacy": bool(r.get("legacy"))}
                    for r in cc["reviews"]],
        "claims": [{"id": c["id"], **c["meta"], "live": claim_live(c, cfg["ttl_minutes"])} for c in cc["claims"]],
        "relations": surf_rel or "(run scan for relations)",
        "local": str(pr_dir(repo, n)),
    }, indent=2))


def verdict_class(verdict: dict | None) -> str:
    if not verdict:
        return "unread"  # fail safe: a review whose counts we can't read is not clean
    if verdict.get("blockers"):
        return "blockers"
    return "nits" if verdict.get("nits") else "clean"


def review_state(repo: str, n: int, roles: list[str], cfg: dict) -> dict:
    """Per-role review state of one PR at its current head — the author side's view.

    Expected roles = those asked for (--roles / $PR_REVIEW_REQUIRED_ROLES) ∪ those
    the base branch requires as "<prefix><role>" checks ∪ every role that has
    reviewed this PR at any head (once a lens has looked, it is expected to look
    again after a push) ∪ every role holding a live claim. Legacy reviews
    (a verdict trailer without a marker, e.g. from a retired CI reviewer) do
    not make a role expected. The rollup verdict is fail-safe: blockers > unread >
    incomplete > nits > clean, and `none` when no role is expected at all.
    """
    ttl = cfg["ttl_minutes"]
    pr = fetch_pr(repo, n)
    head = pr["headRefOid"]
    cc = classify_comments(fetch_comments(repo, n))
    commits = fetch_commits(repo, n)
    latest = latest_reviews(cc)
    statuses = fetch_statuses(repo, head)
    required = required_roles(repo, pr["baseRefName"])
    claims = {c["meta"].get("role"): c for c in sorted(cc["claims"], key=lambda c: c["id"], reverse=True)
              if claim_live(c, ttl)}
    # A role mid-review is about to post a verdict, so the author waits for it too.
    expected = sorted(set(roles) | set(split_roles(os.environ.get("PR_REVIEW_REQUIRED_ROLES")))
                      | set(required) | {r for r, rv in latest.items() if not rv.get("legacy")} | set(claims))
    out_roles = {}
    for role in sorted(set(expected) | set(statuses)):
        st = role_status(pr, cc, commits, role, cfg["aggregate_inputs"], ttl)
        r = latest.get(role)
        covers = st["state"] in ("done", "reply")
        cls = verdict_class(r.get("verdict")) if (covers and r) else None
        want = verdict_status(r.get("verdict"))[0] if (covers and r and r.get("verdict")) else None
        cs = statuses.get(role)
        out_roles[role] = {
            "expected": role in expected, "required": role in required, "state": st["state"],
            "covers_head": covers, "verdict": cls,
            "counts": (r or {}).get("verdict") if covers else None,
            "reviewed_head": ((r or {}).get("meta") or {}).get("head") or None,
            "url": (r or {}).get("html_url"), "review_id": (r or {}).get("id"),
            "inputs": split_roles(((r or {}).get("meta") or {}).get("inputs")) if role == AGGREGATE else None,
            "in_progress": ({"agent": claims[role]["meta"].get("agent"), "head": claims[role]["meta"].get("head")}
                            if role in claims else None),
            "commit_status": cs,
            # A covering review whose check disagrees (statuses off, or a failed set_status):
            # the comment is authoritative; a reviewer re-post repairs the check.
            "status_mismatch": bool(want) and (cs or {}).get("state") != want,
        }
        if role == AGGREGATE and st["state"] == "waiting":
            out_roles[role]["waiting_for"] = st.get("waiting_for")
    exp = [out_roles[r] for r in expected]
    verdicts = [e["verdict"] for e in exp]
    all_reviewed = bool(exp) and all(e["covers_head"] for e in exp)
    if not exp:
        overall = "none"
    elif "blockers" in verdicts:
        overall = "blockers"
    elif "unread" in verdicts:
        overall = "unread"
    elif not all_reviewed:
        overall = "incomplete"
    elif "nits" in verdicts:
        overall = "nits"
    else:
        overall = "clean"
    agg = out_roles.get(AGGREGATE)
    agg_current = bool(agg and agg["covers_head"])
    # What the author should read this round: the consolidated review when it is
    # current, else each covering role review that has findings.
    if agg_current:
        read = [agg["url"]]
    else:
        read = [out_roles[r]["url"] for r in expected
                if r != AGGREGATE and out_roles[r]["verdict"] in ("blockers", "nits", "unread")]
    # Findings from reviews of an earlier head: known work the author can start on
    # while the roles re-review (e.g. after a merge from the base branch).
    stale_read = [out_roles[r]["url"] for r in expected
                  if r != AGGREGATE and not out_roles[r]["covers_head"] and out_roles[r]["url"]
                  and verdict_class((latest.get(r) or {}).get("verdict")) in ("blockers", "nits")]
    # Hand-written or retired-CI reviews (trailer, no marker) don't make a role
    # expected, but their findings shouldn't vanish: list the ones with findings.
    legacy_read = sorted({r["html_url"] for r in cc["reviews"]
                          if r.get("legacy") and verdict_class(r.get("verdict")) in ("blockers", "nits")
                          and r is latest.get(r["meta"].get("role", "general"))})
    return {"pr": f"{repo}#{n}", "head": head, "base": pr["baseRefName"],
            "expected": expected, "required": required, "stale_read": stale_read,
            "legacy_read": legacy_read,
            "missing": [r for r in expected if not out_roles[r]["covers_head"]],
            "in_progress": sorted(r for r in expected if out_roles[r]["in_progress"]),
            "all_reviewed": all_reviewed, "verdict": overall,
            "aggregate_current": agg_current, "read": read, "roles": out_roles}


def cmd_reviews(args):
    cfg = load_config()
    repo, n = parse_target(args.pr, cfg)
    print(json.dumps(review_state(repo, n, split_roles(args.roles), cfg), indent=2))


def cmd_post(args):
    cfg = load_config()
    repo, n = parse_target(args.pr, cfg)
    role = roles_arg(args)[0]
    agent = agent_id(args)
    body = Path(args.body_file).read_text()
    if TRIGGER in body.lower():
        die(f"body contains the review-workflow trigger string ({TRIGGER!r}, case-insensitive) — "
            "posting it would launch the CI reviewer. Reword (e.g. 'the review workflow').", 3)
    if MARKER_RE.search(body):
        die("body already contains a pr-surface marker; post adds it — remove yours", 3)
    kind = "note" if args.note else "review"
    if kind == "review" and not VERDICT_RE.search(body):
        die("review body lacks the `<!-- review-verdict: blockers=N nits=M -->` trailer", 3)
    pr = fetch_pr(repo, n)
    head = pr["headRefOid"]
    cf = claims_file(repo, n, role)
    local = json.loads(cf.read_text()) if cf.exists() else {}
    if args.head and not re.fullmatch(r"[0-9a-f]{40}", args.head):
        die(f"--head must be the full 40-character sha you reviewed, got {args.head!r}", 2)
    reviewed = args.head or local.get("head") or head
    if not head_matches(reviewed, head) and not args.allow_stale_head:
        die(f"PR head moved to {head[:7]} since you started ({reviewed[:7]}). Run `snapshot` for the "
            "interdiff, extend the review, then post with --head <new sha> (or --allow-stale-head).", 4)
    refs = f" refs={args.refs}" if args.refs else ""
    inputs = ""
    if kind == "review" and role == AGGREGATE:
        agg = aggregate_inputs(pr, classify_comments(fetch_comments(repo, n)), cfg["aggregate_inputs"],
                               cfg["ttl_minutes"])
        if not agg["ready"]:
            die(f"aggregate inputs are not all at head {head[:7]} (waiting for: "
                f"{', '.join(agg['waiting_for']) or '-'}; in progress: {', '.join(agg['in_progress']) or '-'}). "
                "Re-run `claim --packet` once they post, and merge the current reviews.", 5)
        inputs = f" inputs={','.join(sorted(agg['reviews']))}"
    # Always the head that was actually read, never silently the current one.
    marker_head = reviewed
    marker = f"<!-- pr-reviewer:{kind} v=1 role={role} head={marker_head} agent={agent}{refs}{inputs} -->"
    full = body.rstrip() + "\n\n" + marker + "\n"
    outbox = pr_dir(repo, n) / f"outbox-{role}.md"
    outbox.write_text(full)
    posted = gh_json("api", f"repos/{repo}/issues/{n}/comments", "-F", f"body=@{outbox}")
    if kind == "review":
        cleanup_claims(repo, n, role, agent, cfg["ttl_minutes"], local.get("claim_id"))
        if not args.keep_worktree:
            remove_worktrees(repo, n, agent)
        d = pr_dir(repo, n)
        (d / "reviews").mkdir(exist_ok=True)
        (d / "reviews" / f"{head[:12]}-{role}-{posted['id']}.md").write_text(full)
    out = {"posted": posted["html_url"], "kind": kind, "head": head}
    if kind == "review":
        v = VERDICT_RE.search(body)
        state, desc = verdict_status({"blockers": int(v.group(1)), "nits": int(v.group(2))})
        out["commit_status"] = set_status(repo, marker_head, role, state, desc, posted["html_url"])
    print(json.dumps(out, indent=2))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p, pr=False):
        if pr:
            p.add_argument("pr", help="owner/repo#N, repo#N (short name from config) or PR URL")
        p.add_argument("--role", help="reviewer role(s); comma-separated for scan/next (default general)")
        p.add_argument("--agent", help="agent id (default $PR_REVIEWER_AGENT or user@host/role)")
        return p

    p = sub.add_parser("init"); p.add_argument("--repo", action="append"); p.add_argument("--clone", action="append",
        help="owner/repo=/path/to/clone"); p.add_argument("--ttl", type=int)
    p.add_argument("--aggregate-inputs", help="roles the aggregate role waits for and merges, e.g. general,security "
                                              "(default: every role that has reviewed the PR)")
    p.set_defaults(fn=cmd_init)
    for name, fn in (("scan", cmd_scan), ("next", cmd_next)):
        p = common(sub.add_parser(name)); p.add_argument("repos", nargs="*")
        p.add_argument("--include-drafts", action="store_true"); p.set_defaults(fn=fn)
        if name == "scan":
            p.add_argument("--json", action="store_true")
        else:
            p.add_argument("--only", help="restrict to states, e.g. rereview-blockers,reply")
    p = common(sub.add_parser("claim"), True); p.add_argument("--force", action="store_true",
        help="claim even if the role already reviewed this head"); p.add_argument("--packet", action="store_true",
        help="also snapshot + emit a work packet"); p.set_defaults(fn=cmd_claim)
    for name, fn in (("renew", cmd_renew), ("release", cmd_release), ("snapshot", cmd_snapshot), ("show", cmd_show)):
        common(sub.add_parser(name), True).set_defaults(fn=fn)
    p = common(sub.add_parser("checkout"), True); p.add_argument("--clone"); p.add_argument("--dest")
    p.set_defaults(fn=cmd_checkout)
    p = sub.add_parser("reviews", help="per-role review state of one PR (for the author side)")
    p.add_argument("pr", help="owner/repo#N, repo#N (short name from config) or PR URL")
    p.add_argument("--roles", help="roles that must review this PR even if none has yet, e.g. general,security")
    p.set_defaults(fn=cmd_reviews)
    p = common(sub.add_parser("post"), True); p.add_argument("--body-file", required=True)
    p.add_argument("--note", action="store_true", help="a follow-up that is not a review (no verdict required)")
    p.add_argument("--head", help="the full head sha you actually reviewed")
    p.add_argument("--refs", help="related PRs, e.g. acme/platform#40,app#10")
    p.add_argument("--allow-stale-head", action="store_true")
    p.add_argument("--keep-worktree", action="store_true", help="don't remove your checkout of this PR")
    p.set_defaults(fn=cmd_post)

    args = ap.parse_args()
    try:
        args.fn(args)
    except GhError as e:
        die(str(e))


if __name__ == "__main__":
    main()
