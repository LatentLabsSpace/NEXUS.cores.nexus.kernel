#!/usr/bin/env python3
"""pr-ledger-harvest.py — keep deferred review findings from getting lost.

Sweeps the deferred-nits ledgers of PRs merged since --since (ledger comments
by the PR author only) and lists every
entry that is still open: tagged **follow-up**, or (in older ledgers) with no
stated status. With --file, each open entry becomes a bead (pr-followup.py) and
the ledger entry is edited in place to carry `**bead <id>**`, so a second run
finds nothing new. Without --file it only reports (the default: a dry run).

Runs anywhere gh.sh can reach GitHub as the author identity and the bd
command can reach the graph: a session on the host, or a no-agent cron in the
beads container. Costs no model calls.

Usage:
  pr-ledger-harvest.py --repo owner/a --repo owner/b --since 2026-09-01 [--file]
                       [--bd …] [--root-by-repo …] [--root-by-path …] [--json]
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ledger_status  # noqa: E402
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location("pr_followup", os.path.join(HERE, "pr-followup.py"))
pr_followup = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pr_followup)

GH = ["bash", os.path.join(HERE, "gh.sh")]


def gh(*args):
    p = subprocess.run(GH + list(args), capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"pr-ledger-harvest: gh {' '.join(args[:3])} failed: {(p.stdout + p.stderr).strip()[:300]}")
    return p.stdout


def merged_prs(repo, since):
    out = gh("pr", "list", "-R", repo, "--state", "merged", "--search", f"merged:>={since}",
             "--json", "number,url,mergedAt,title,author", "--limit", "300")
    return json.loads(out or "[]")


def ledgers(repo, num, author):
    """The PR's ledger comments, from the PR author only: anyone else's comment
    that starts with the marker is not a ledger and never gets filed."""
    out = gh("api", "--paginate", f"repos/{repo}/issues/{num}/comments?per_page=100",
             "--jq", f'.[] | select((.body | startswith("{ledger_status.MARKER}")) and .user.login == "{author}")'
                     ' | {id, body, html_url}')
    return [json.loads(l) for l in out.splitlines() if l.strip()]


def patch_comment(repo, cid, body):
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
        f.write(body)
        path = f.name
    try:
        gh("api", "-X", "PATCH", f"repos/{repo}/issues/comments/{cid}", "-F", f"body=@{path}", "--jq", ".id")
    finally:
        os.unlink(path)


def collect(repos, since):
    """Every open entry, grouped by ledger: [(repo, pr, ledger, lines, [(i, item)])]."""
    groups = []
    for repo in repos:
        for pr in merged_prs(repo, since):
            author = (pr.get("author") or {}).get("login", "")
            if not author:
                continue
            for led in ledgers(repo, pr["number"], author):
                open_items = []
                for i, line in ledger_status.entries(led["body"]):
                    st = ledger_status.status(line)
                    if st not in ("follow-up", "unstated"):
                        continue
                    open_items.append((i, {"repo": repo, "pr": pr["number"], "merged": pr["mergedAt"][:10],
                                           "status": st, "entry": line.strip(), "ledger": led["html_url"],
                                           "paths": ledger_status.paths(line)}))
                if open_items:
                    groups.append((repo, pr, led, led["body"].splitlines(), open_items))
    return groups


def file_all(groups, bd, by_repo, by_path):
    """File each open entry and tag its ledger line right away, one PATCH per
    bead, so a failure part-way leaves every filed bead already recorded and a
    rerun files only what's left. Roots are resolved for every entry first, so
    a missing root mapping stops the run before anything is filed."""
    missing = sorted({it["repo"] for *_, items in groups for _, it in items
                      if not pr_followup.resolve_root(it["repo"], it["paths"], by_repo, by_path)})
    if missing:
        sys.exit(f"pr-ledger-harvest: no roadmap root for {', '.join(missing)} "
                 "(PR_REVIEW_FOLLOWUP_ROOT_BY_REPO); nothing filed")
    for repo, pr, led, lines, items in groups:
        for i, it in items:
            bead = pr_followup.file_entry(pr["url"], lines[i], it["paths"], bd, by_repo, by_path)
            lines[i] = lines[i].rstrip() + f" **bead {bead}**"
            try:
                patch_comment(repo, led["id"], "\n".join(lines))
            except SystemExit:
                sys.exit(f"pr-ledger-harvest: filed {bead} but could not tag {led['html_url']}; "
                         f"add **bead {bead}** to that entry by hand before rerunning")
            it["bead"] = bead


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", action="append", required=True)
    ap.add_argument("--since", required=True, help="YYYY-MM-DD: PRs merged on or after this date")
    ap.add_argument("--file", action="store_true", help="file beads and tag the ledgers (default: report only)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--bd", default=os.environ.get("PR_REVIEW_BD", "bd"))
    ap.add_argument("--root-by-repo", default=os.environ.get("PR_REVIEW_FOLLOWUP_ROOT_BY_REPO", ""))
    ap.add_argument("--root-by-path", default=os.environ.get("PR_REVIEW_FOLLOWUP_ROOT_BY_PATH", ""))
    a = ap.parse_args()
    by_repo, by_path = pr_followup.parse_map(a.root_by_repo), pr_followup.parse_map(a.root_by_path)

    groups = collect(a.repo, a.since)
    if a.file:
        file_all(groups, a.bd, by_repo, by_path)
    found = [it for *_, items in groups for _, it in items]
    if a.json:
        print(json.dumps(found, indent=1))
    else:
        for it in found:
            tag = f" → {it['bead']}" if it.get("bead") else ""
            print(f"{it['repo'].split('/')[1]}#{it['pr']} (merged {it['merged']}, {it['status']}){tag}: {it['entry'][:200]}")
        print(f"{len(found)} open ledger entr{'y' if len(found) == 1 else 'ies'}"
              f"{' filed' if a.file else ' (dry run: nothing filed)'}", file=sys.stderr)


if __name__ == "__main__":
    main()
