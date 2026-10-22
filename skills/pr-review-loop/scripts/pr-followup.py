#!/usr/bin/env python3
"""pr-followup.py — file one deferred ledger entry as a work item (a bead).

The bead goes under a "Review follow-ups" milestone beneath the roadmap root
that owns the entry: the longest --root-by-path prefix matching one of the
entry's paths, else the PR's repo in --root-by-repo. The milestone is found by
its `review-followups` label, or created on first use. Prints the new bead id.

Cell-specific settings come from flags or the environment, never from a repo:
  --bd / PR_REVIEW_BD                       command that runs bd, e.g. "bd" inside
                                            the beads container, or a
                                            "docker compose … exec … bd" prefix
  --root-by-repo / PR_REVIEW_FOLLOWUP_ROOT_BY_REPO   "owner/repo=hd-zk0;owner/repo=hd-9vq"
  --root-by-path / PR_REVIEW_FOLLOWUP_ROOT_BY_PATH   "codex/games/olympus/=hd-op8;…"

Usage:
  pr-followup.py --pr <url> --entry "<ledger line>" [--paths a b] [--dry-run]
"""
import argparse
import json
import os
import re
import shlex
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ledger_status  # noqa: E402

MILESTONE_TITLE = "Review follow-ups (deferred PR findings)"
MILESTONE_LABEL = "review-followups"
ITEM_LABEL = "review-followup"


def parse_map(s):
    out = {}
    for part in (s or "").split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            if k.strip() and v.strip():
                out[k.strip()] = v.strip()
    return out


def pr_parts(url):
    m = re.match(r"https://github\.com/([^/]+/[^/]+)/pull/(\d+)", url)
    if not m:
        sys.exit(f"pr-followup: not a PR URL: {url}")
    return m.group(1), int(m.group(2))


def resolve_root(repo, paths, by_repo, by_path):
    best = None
    for p in paths:
        for prefix, root in by_path.items():
            if p.startswith(prefix) and (best is None or len(prefix) > len(best[0])):
                best = (prefix, root)
    if best:
        return best[1]
    for k, v in by_repo.items():
        if k.lower() == repo.lower():
            return v
    return None


def clean(text):
    t = re.sub(r"^\s*[-*]\s+", "", text)
    t = ledger_status.FOLLOWUP_RE.sub("", t)
    t = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", t)  # markdown links → text
    t = re.sub(r"[*`]", "", t)
    return re.sub(r"\s+", " ", t).strip(" .—-")


class Bd:
    def __init__(self, prefix, dry):
        self.cmd = shlex.split(prefix)
        self.dry = dry

    def run(self, *args, write=False):
        if write and self.dry:
            print("[dry-run] bd " + " ".join(shlex.quote(a) for a in args), file=sys.stderr)
            return "DRY-RUN"
        p = subprocess.run(self.cmd + list(args), capture_output=True, text=True)
        if p.returncode != 0:
            sys.exit(f"pr-followup: bd {args[0]} failed: {p.stderr.strip()[:300]}")
        return p.stdout.strip()


def milestone(bd, root):
    raw = bd.run("list", "--parent", root, "--all", "--limit", "0", "--label", MILESTONE_LABEL, "--json")
    items = json.loads(raw or "[]")
    for it in items:
        if it.get("issue_type") == "milestone" and it.get("status") != "closed":
            return it["id"]
    return bd.run("create", MILESTONE_TITLE, "-t", "milestone", "--parent", root, "-p", "3",
                  "-l", MILESTONE_LABEL, "-d",
                  "Deferred findings from merged or finished PRs (pr-review-loop ledgers). "
                  "Each child links its PR's ledger entry. Close a child when fixed, or "
                  "when the TD decides not to act.", "--silent", write=True)


def file_entry(pr_url, entry, paths=None, bd_prefix=None, by_repo=None, by_path=None, dry=False):
    repo, num = pr_parts(pr_url)
    paths = paths if paths is not None else ledger_status.paths(entry)
    root = resolve_root(repo, paths, by_repo or {}, by_path or {})
    if not root:
        sys.exit(f"pr-followup: no roadmap root configured for {repo} (PR_REVIEW_FOLLOWUP_ROOT_BY_REPO)")
    bd = Bd(bd_prefix or "bd", dry)
    parent = milestone(bd, root)
    summary = clean(entry)
    title = f"{repo.split('/')[1]}#{num} follow-up: {summary[:90]}"
    body = (f"{summary}\n\nDeferred in the review ledger of {pr_url} "
            f"(paths: {', '.join(paths) or 'none named'}). Filed by pr-review-loop.")
    return bd.run("create", title, "--parent", parent, "-t", "task", "-p", "3",
                  "-l", ITEM_LABEL, "-d", body, "--silent", write=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pr", required=True)
    ap.add_argument("--entry", required=True)
    ap.add_argument("--paths", nargs="*")
    ap.add_argument("--bd", default=os.environ.get("PR_REVIEW_BD", "bd"))
    ap.add_argument("--root-by-repo", default=os.environ.get("PR_REVIEW_FOLLOWUP_ROOT_BY_REPO", ""))
    ap.add_argument("--root-by-path", default=os.environ.get("PR_REVIEW_FOLLOWUP_ROOT_BY_PATH", ""))
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    print(file_entry(a.pr, a.entry, a.paths, a.bd, parse_map(a.root_by_repo), parse_map(a.root_by_path), a.dry_run))


if __name__ == "__main__":
    main()
