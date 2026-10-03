#!/usr/bin/env python3
"""Minimal stand-in for `gh`, backed by a JSON file ($FAKE_GH_DB), for protocol tests.

Implements only what reviewer.py calls for claim/post/release/status, commit
statuses (POST statuses/<sha>, GET commits/<sha>/status) and branch rules
($FAKE_GH_DB "required_checks"; absent = 404). `--jq` is
ignored: responses are emitted pre-shaped the way reviewer.py's jq filters would.
$FAKE_GH_RACE=1 makes the next claim POST lose a race (a competitor claim with a
lower id appears first). $FAKE_GH_STATUS_FORBIDDEN=1 makes status writes fail
with a 403, like a token without status permission.
"""
import json
import os
import re
import sys

DB = os.environ["FAKE_GH_DB"]
db = json.load(open(DB))
args = sys.argv[1:]


def save():
    json.dump(db, open(DB, "w"), indent=1)


def pr(repo, n):
    return db["prs"][f"{repo}#{n}"]


def flag(name):
    return args[args.index(name) + 1] if name in args else None


if args[:2] == ["auth", "status"]:
    sys.exit(0)

if args[:2] == ["pr", "list"]:
    repo = flag("--repo")
    out = [{**p, "files": p.get("files", []), "labels": p.get("labels", [])}
           for k, p in sorted(db["prs"].items()) if k.startswith(repo + "#")]
    print(json.dumps(out))
    sys.exit(0)

if args[:2] == ["pr", "view"]:
    p = pr(flag("--repo"), args[2])
    print(json.dumps({**p, "number": int(args[2]), "files": p.get("files", []), "labels": []}))
    sys.exit(0)

if args[0] == "api":
    method = flag("-X") or ("POST" if ("-f" in args or "-F" in args) else "GET")
    path = next(a for a in args[1:] if a.startswith("repos/"))
    path = path.split("?")[0]
    m = re.match(r"repos/([^/]+/[^/]+)/issues/(\d+)/comments$", path)
    if m:
        key = f"{m.group(1)}#{m.group(2)}"
        cs = db["comments"].setdefault(key, [])
        if method == "GET":
            for c in cs:
                print(json.dumps(c))
            sys.exit(0)
        raw = flag("-f") or flag("-F")
        body = raw.split("=", 1)[1]
        if body.startswith("@"):
            body = open(body[1:]).read()
        db["next_id"] += 10
        if os.environ.get("FAKE_GH_RACE") and "pr-reviewer:claim" in body:
            comp = body.replace("agent=", "agent=rival-")
            cs.append({"id": db["next_id"] - 5, "body": comp, "user": "u", "created_at": db["now_iso"],
                       "updated_at": db["now_iso"], "html_url": f"https://x/{key}#c{db['next_id'] - 5}"})
        c = {"id": db["next_id"], "body": body, "user": "u", "created_at": db["now_iso"],
             "updated_at": db["now_iso"], "html_url": f"https://x/{key}#c{db['next_id']}"}
        cs.append(c)
        cs.sort(key=lambda c: c["id"])
        save()
        print(json.dumps(c))
        sys.exit(0)
    m = re.match(r"repos/([^/]+/[^/]+)/issues/comments/(\d+)$", path)
    if m:
        cid = int(m.group(2))
        for key, cs in db["comments"].items():
            for c in cs:
                if c["id"] == cid:
                    if method == "DELETE":
                        cs.remove(c)
                    elif method == "PATCH":
                        c["body"] = flag("-f").split("=", 1)[1]
                    save()
                    sys.exit(0)
        sys.exit(1)
    m = re.match(r"repos/([^/]+/[^/]+)/compare/(.+)$", path)
    if m:
        from urllib.parse import unquote
        key = f"{m.group(1)}:{unquote(m.group(2))}"
        diff = db.get("diffs", {}).get(key)
        if diff is None:
            print(f"fake_gh: 404 compare {key}", file=sys.stderr)
            sys.exit(1)
        if any("vnd.github.diff" in a for a in args):
            sys.stdout.write(diff)
            mv = db.get("move_after_diff")
            if mv and mv["key"] == key:
                # Simulate the author pushing right after the reviewer's snapshot.
                p = db["prs"][mv["pr"]]
                p["headRefOid"] = mv["to"]
                p.setdefault("commits", []).append({"sha": mv["to"], "date": db["now_iso"]})
                db["next_id"] += 10
                db["comments"].setdefault(mv["pr"], []).append(
                    {"id": db["next_id"], "body": mv["comment"], "user": "dev", "created_at": db["now_iso"],
                     "updated_at": db["now_iso"], "html_url": f"https://x/{mv['pr']}#c{db['next_id']}"})
                del db["move_after_diff"]
                save()
        else:
            print(json.dumps({"status": db.get("compare_status", {}).get(key, "ahead"), "commits": [],
                              "total_commits": 1}))
        sys.exit(0)
    if re.match(r"repos/[^/]+/[^/]+/contents/", path):
        print("fake_gh: 404", file=sys.stderr)
        sys.exit(1)
    m = re.match(r"repos/([^/]+/[^/]+)/pulls/(\d+)/commits$", path)
    if m:
        for c in pr(m.group(1), m.group(2)).get("commits", []):
            print(json.dumps(c))
        sys.exit(0)

    m = re.match(r"repos/([^/]+/[^/]+)/statuses/([0-9a-f]{40})$", path)
    if m and method == "POST":
        if os.environ.get("FAKE_GH_STATUS_FORBIDDEN"):
            print("fake_gh: 403 Resource not accessible", file=sys.stderr)
            sys.exit(1)
        fields = dict(args[i + 1].split("=", 1) for i, a in enumerate(args[:-1]) if a == "-f")
        db["status_seq"] = db.get("status_seq", 0) + 1
        db.setdefault("statuses", {}).setdefault(m.group(2), []).append(
            {**fields, "updated_at": f"{db['status_seq']:010d}"})
        save()
        print(json.dumps(fields))
        sys.exit(0)
    m = re.match(r"repos/([^/]+/[^/]+)/commits/([0-9a-f]{40})/status$", path)
    if m:
        latest = {}
        for st in db.get("statuses", {}).get(m.group(2), []):
            latest[st["context"]] = st
        print(json.dumps({"statuses": list(latest.values())}))
        sys.exit(0)
    m = re.match(r"repos/([^/]+/[^/]+)/rules/branches/(.+)$", path)
    if m:
        req = db.get("required_checks")
        if req is None:
            print("fake_gh: 404", file=sys.stderr)
            sys.exit(1)
        print(json.dumps([{"type": "required_status_checks",
                           "parameters": {"required_status_checks": [{"context": c} for c in req]}}]))
        sys.exit(0)
    if re.match(r"repos/[^/]+/[^/]+/branches/.+/protection/required_status_checks$", path):
        print("fake_gh: 404 Branch not protected", file=sys.stderr)
        sys.exit(1)

print(f"fake_gh: unsupported {args}", file=sys.stderr)
sys.exit(2)
