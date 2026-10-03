#!/usr/bin/env python3
"""Build a sandbox PR surface for evals: python3 make_fixture.py <dir>

Writes <dir>/db.json (served by scripts/tests/fake_gh.py) and prints the env
assignments to prefix every reviewer.py call with. Nothing touches GitHub.

acme/app surface:
  #10 feat/limiter      new; Limiter.allow off-by-one (allows limit+1 calls)
  #11 feat/limiter-metrics  stacked on #10 (base feat/limiter); `self.denied` never initialized
  #12 fix/config        prior review blockers=1 (yaml.load); new head fixes it with
                        safe_load BUT adds a log line that prints the api_token
  #13 docs/typo         reviewed at current head, nothing since → done
"""
import datetime as dt
import json
import sys
import time
from pathlib import Path

out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
now = dt.datetime.now(dt.timezone.utc)
iso = lambda d: d.isoformat(timespec="seconds").replace("+00:00", "Z")
T0, T1, T2 = iso(now - dt.timedelta(hours=5)), iso(now - dt.timedelta(hours=3)), iso(now - dt.timedelta(hours=1))
H10, H11, H12a, H12b, H13 = "1" * 40, "2" * 40, "3" * 40, "4" * 40, "5" * 40
R = "acme/app"
TRIGGER = "/" + "review"

README_HUNK = """diff --git a/README.md b/README.md
--- a/README.md
+++ b/README.md
@@ -1,2 +1,3 @@
 # app
 Small service.
+{line}
"""

D10 = README_HUNK.format(line="Rate limiting: see src/limiter.py.") + """diff --git a/src/limiter.py b/src/limiter.py
new file mode 100644
--- /dev/null
+++ b/src/limiter.py
@@ -0,0 +1,16 @@
+import time
+
+
+class Limiter:
+    \"\"\"Allow at most `limit` calls per `window` seconds.\"\"\"
+
+    def __init__(self, limit, window):
+        self.limit, self.window, self.calls = limit, window, []
+
+    def allow(self, now=None):
+        now = time.time() if now is None else now
+        self.calls = [t for t in self.calls if t > now - self.window]
+        if len(self.calls) > self.limit:
+            return False
+        self.calls.append(now)
+        return True
diff --git a/tests/test_limiter.py b/tests/test_limiter.py
new file mode 100644
--- /dev/null
+++ b/tests/test_limiter.py
@@ -0,0 +1,6 @@
+from src.limiter import Limiter
+
+
+def test_first_call_allowed():
+    lim = Limiter(limit=3, window=60)
+    assert lim.allow(now=0)
"""

D11 = """diff --git a/src/limiter.py b/src/limiter.py
--- a/src/limiter.py
+++ b/src/limiter.py
@@ -10,7 +10,11 @@ class Limiter:
     def allow(self, now=None):
         now = time.time() if now is None else now
         self.calls = [t for t in self.calls if t > now - self.window]
         if len(self.calls) > self.limit:
+            self.denied += 1
             return False
         self.calls.append(now)
         return True
+
+    def stats(self):
+        return {"denied": self.denied, "in_window": len(self.calls)}
"""

D12_OLD = README_HUNK.format(line="Config: config.yaml (see src/config.py).") + """diff --git a/src/config.py b/src/config.py
new file mode 100644
--- /dev/null
+++ b/src/config.py
@@ -0,0 +1,7 @@
+import yaml
+
+
+def load(path):
+    with open(path) as f:
+        cfg = yaml.load(f, Loader=yaml.Loader)
+    return cfg
"""

D12_NEW = README_HUNK.format(line="Config: config.yaml (see src/config.py).") + """diff --git a/src/config.py b/src/config.py
new file mode 100644
--- /dev/null
+++ b/src/config.py
@@ -0,0 +1,11 @@
+import logging
+import yaml
+
+log = logging.getLogger(__name__)
+
+
+def load(path):
+    with open(path) as f:
+        cfg = yaml.safe_load(f)
+    log.info("loaded config: %s", cfg)  # cfg includes api_token
+    return cfg
"""

INTER12 = """diff --git a/src/config.py b/src/config.py
--- a/src/config.py
+++ b/src/config.py
@@ -1,7 +1,11 @@
+import logging
 import yaml

+log = logging.getLogger(__name__)
+

 def load(path):
     with open(path) as f:
-        cfg = yaml.load(f, Loader=yaml.Loader)
+        cfg = yaml.safe_load(f)
+    log.info("loaded config: %s", cfg)  # cfg includes api_token
     return cfg
"""

D13 = """diff --git a/docs/usage.md b/docs/usage.md
--- a/docs/usage.md
+++ b/docs/usage.md
@@ -1 +1 @@
-Teh app.
+The app.
"""


def files(diff):
    return [{"path": l.split(" b/", 1)[1]} for l in diff.splitlines() if l.startswith("diff --git ")]


def pr(n, title, head, head_ref, base, diff, body, commits, created):
    return {"number": n, "title": title, "url": f"https://github.com/{R}/pull/{n}", "headRefOid": head,
            "headRefName": head_ref, "baseRefName": base, "isDraft": False, "labels": [],
            "author": {"login": "dev"}, "createdAt": created, "updatedAt": created, "body": body,
            "files": files(diff), "additions": diff.count("\n+"), "deletions": diff.count("\n-"),
            "mergeable": "MERGEABLE", "statusCheckRollup": [{"conclusion": "SUCCESS"}], "commits": commits}


review12 = ("## Review (general) — acme/app#12 at `3333333`\n\n**Verdict: fix-then-ship**\n\n"
            "### Medium (blocker)\n1. **Unsafe YAML load** — `src/config.py:6`. `yaml.load(..., Loader=yaml.Loader)` "
            "constructs arbitrary Python objects from config input. Use `yaml.safe_load`.\n\n"
            "**Next:** author: switch to safe_load and push.\n\n<!-- review-verdict: blockers=1 nits=0 -->\n"
            f"<!-- pr-reviewer:review v=1 role=general head={H12a} agent=reviewer-old -->")
review13 = ("## Review (general) — acme/app#13 at `5555555`\n\n**Verdict: ship**\n\n<!-- review-verdict: blockers=0 nits=0 -->\n"
            f"<!-- pr-reviewer:review v=1 role=general head={H13} agent=reviewer-old -->")
c = lambda i, body, when: {"id": i, "body": body, "user": "dev", "created_at": when, "updated_at": when,
                           "html_url": f"https://github.com/{R}/pull/x#issuecomment-{i}"}

db = {
    "next_id": 5000, "now_iso": iso(now),
    "prs": {
        f"{R}#10": pr(10, "feat: sliding-window rate limiter", H10, "feat/limiter", "main", D10,
                      "Adds `Limiter` (at most `limit` calls per `window`).", [{"sha": H10, "date": T0}], T0),
        f"{R}#11": pr(11, "feat: limiter denial metrics", H11, "feat/limiter-metrics", "feat/limiter", D11,
                      "Stacked on #10. Counts denied calls and exposes `stats()`.", [{"sha": H11, "date": T1}], T1),
        f"{R}#12": pr(12, "fix: config loader", H12b, "fix/config", "main", D12_NEW,
                      "Loads config.yaml.", [{"sha": H12a, "date": T0}, {"sha": H12b, "date": T2}], T0),
        f"{R}#13": pr(13, "docs: typo", H13, "docs/typo", "main", D13, "", [{"sha": H13, "date": T0}], T0),
    },
    "comments": {
        f"{R}#12": [c(4001, review12, T1), c(4002, f"Switched to safe_load. Ready for another {TRIGGER}.", T2)],
        f"{R}#13": [c(4003, review13, T1)],
    },
    "diffs": {
        f"{R}:main...{H10}": D10, f"{R}:feat/limiter...{H11}": D11, f"{R}:main...{H12a}": D12_OLD,
        f"{R}:main...{H12b}": D12_NEW, f"{R}:{H12a}...{H12b}": INTER12, f"{R}:main...{H13}": D13,
    },
}
variant = sys.argv[2] if len(sys.argv) > 2 else "basic"
if variant == "handoff":
    # A reviewer claimed #10 two hours ago (claim expired) and left notes before dying.
    stale = int(time.time()) - 2 * 3600
    db["comments"][f"{R}#10"] = [c(4010, f"<!-- pr-reviewer:claim v=1 role=general head={H10} agent=reviewer-crashed "
                                         f"ts={stale} ttl=60 -->\n🔎 Review in progress", T1)]
    nd = out / "state" / "acme__app" / "pr-10"
    nd.mkdir(parents=True, exist_ok=True)
    (nd / "notes.md").write_text(
        "# Reviewer notes — acme/app#10\n\n## general — reviewer-crashed — pass 1\n"
        "- Verified: window pruning (`t > now - window`) drops expired calls correctly.\n"
        "- STILL TO CHECK: behaviour exactly at the limit — the comparison on line 13 looks suspicious; "
        "the only test calls allow() once.\n- Also: README line conflicts textually with #12's README line.\n")
def only(*keys):
    db["prs"] = {k: v for k, v in db["prs"].items() if k in keys}
    db["comments"] = {k: v for k, v in db["comments"].items() if k in keys}


if variant == "headmove":
    # The author pushes a fix to #10 right after the reviewer snapshots it.
    H10b = "6" * 40
    D10b = D10.replace("if len(self.calls) > self.limit:", "if len(self.calls) >= self.limit:").replace(
        "+    assert lim.allow(now=0)\n",
        "+    assert lim.allow(now=0)\n+\n+\n+def test_limit_enforced():\n+    lim = Limiter(limit=2, window=60)\n"
        "+    assert lim.allow(now=0) and lim.allow(now=1)\n+    assert not lim.allow(now=2)\n").replace(
        "@@ -0,0 +1,6 @@", "@@ -0,0 +1,12 @@")
    only(f"{R}#10", f"{R}#13")
    db["diffs"][f"{R}:main...{H10b}"] = D10b
    db["diffs"][f"{R}:{H10}...{H10b}"] = (
        "diff --git a/src/limiter.py b/src/limiter.py\n--- a/src/limiter.py\n+++ b/src/limiter.py\n"
        "@@ -11,5 +11,5 @@ class Limiter:\n         now = time.time() if now is None else now\n"
        "         self.calls = [t for t in self.calls if t > now - self.window]\n"
        "-        if len(self.calls) > self.limit:\n+        if len(self.calls) >= self.limit:\n"
        "             return False\n         self.calls.append(now)\n"
        "diff --git a/tests/test_limiter.py b/tests/test_limiter.py\n--- a/tests/test_limiter.py\n"
        "+++ b/tests/test_limiter.py\n@@ -4,3 +4,9 @@\n def test_first_call_allowed():\n"
        "     lim = Limiter(limit=3, window=60)\n     assert lim.allow(now=0)\n+\n+\n+def test_limit_enforced():\n"
        "+    lim = Limiter(limit=2, window=60)\n+    assert lim.allow(now=0) and lim.allow(now=1)\n"
        "+    assert not lim.allow(now=2)\n")
    db["move_after_diff"] = {"key": f"{R}:main...{H10}", "pr": f"{R}#10", "to": H10b,
                             "comment": "Pushed a fix for the limit check (>=) plus a boundary test."}

if variant == "pushback":
    # Our earlier review called SQL injection; the author shows it's an allowlisted identifier.
    H20 = "7" * 40
    D20 = """diff --git a/src/store.py b/src/store.py
new file mode 100644
--- /dev/null
+++ b/src/store.py
@@ -0,0 +1,9 @@
+ALLOWED_TABLES = frozenset({"users", "teams"})
+
+
+def find_id(conn, table, name):
+    if table not in ALLOWED_TABLES:
+        raise ValueError(f"unknown table {table!r}")
+    cur = conn.cursor()
+    cur.execute(f"SELECT id FROM {table} WHERE name = ?", (name,))
+    return cur.fetchone()
"""
    only()
    db["prs"][f"{R}#20"] = pr(20, "feat: store lookup helper", H20, "feat/store", "main", D20,
                              "Adds `find_id`.", [{"sha": H20, "date": T0}], T0)
    db["diffs"][f"{R}:main...{H20}"] = D20
    rev20 = ("## Review (general) — acme/app#20 at `7777777`\n\n**Verdict: changes-needed**\n\n"
             "### Medium (blocker)\n1. **SQL injection** — `src/store.py:8`. The query is built with an f-string, "
             "so a crafted value is executed as SQL. Use parameters.\n\n**Next:** author.\n\n"
             "<!-- review-verdict: blockers=1 nits=0 -->\n"
             f"<!-- pr-reviewer:review v=1 role=general head={H20} agent=reviewer-old -->")
    db["comments"][f"{R}#20"] = [
        c(4020, rev20, T1),
        c(4021, "I think this one is a false positive: `name` is bound as a parameter (`?`), and the f-string only "
                "interpolates `table`, which is checked against the `ALLOWED_TABLES` constant on line 5 first "
                "(identifiers can't be bound as parameters in sqlite). Not changing it unless I'm missing something.", T2)]

if variant == "roles":
    # A general-role agent is mid-review of #10 (live claim) — a security agent works the same surface.
    db["comments"][f"{R}#10"] = [c(4030, f"<!-- pr-reviewer:claim v=1 role=general head={H10} agent=general-bot "
                                         f"ts={int(time.time())} ttl=60 -->\n🔎 Review in progress", T2)]

if variant == "carry":
    H30, H31 = "8" * 40, "9" * 40
    D30 = """diff --git a/src/client.py b/src/client.py
--- a/src/client.py
+++ b/src/client.py
@@ -3,2 +3,3 @@
 import http
 
+MAX_BACKOFF = 30
@@ -12,6 +13,6 @@ def fetch(url, attempts=5):
     for i in range(attempts):
         resp = http.get(url)
-        if resp.status != 429:
+        if resp.status not in (429, 503):
             return resp
-        time.sleep(2 ** i)
+        time.sleep(min(2 ** i, MAX_BACKOFF))
     return resp
"""
    D31 = """diff --git a/src/client.py b/src/client.py
--- a/src/client.py
+++ b/src/client.py
@@ -12,6 +12,6 @@ def fetch(url, attempts=5):
     for i in range(attempts):
         resp = http.get(url)
-        if resp.status != 429:
+        if resp.status not in (429, 503):
             return resp
         time.sleep(2 ** i)
     return resp
"""
    only()
    db["prs"][f"{R}#30"] = pr(30, "fix(client): retry on 503, cap backoff", H30, "fix/retry-503", "main", D30,
                              "Retry 503s as well as 429s, and cap the exponential backoff at 30s so a long "
                              "attempts= value can't sleep for minutes.", [{"sha": H30, "date": T0}], T0)
    db["prs"][f"{R}#31"] = pr(31, "fix(client): retry on 503 (carry)", H31, "carry/retry-503", "main", D31,
                              "Carry of #30 — the contributor's fork branch isn't maintainer-editable, so this "
                              "re-lands it on main with attribution preserved (`Co-authored-by`). No functional "
                              "changes from #30.", [{"sha": H31, "date": T1}], T1)
    db["comments"][f"{R}#30"] = [c(4031, "Carry PR: https://github.com/acme/app/pull/31 — this one stays open "
                                         "until that lands.", T1)]
    db["diffs"][f"{R}:main...{H30}"] = D30
    db["diffs"][f"{R}:main...{H31}"] = D31

(out / "db.json").write_text(json.dumps(db, indent=1))
fake = Path(__file__).resolve().parents[2] / "scripts/tests/fake_gh.py"
print(f'PR_REVIEWER_GH="python3 {fake}" FAKE_GH_DB={out / "db.json"} PR_REVIEWER_STATE={out / "state"} '
      f'PR_REVIEWER_REPOS={R}')
