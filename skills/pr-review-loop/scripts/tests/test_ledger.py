#!/usr/bin/env python3
"""Tests for the ledger grammar, pr-followup.py and pr-ledger-harvest.py, with
gh and bd stubbed (no network, no graph).

Run: python3 skills/pr-review-loop/scripts/tests/test_ledger.py
"""
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent
sys.path.insert(0, str(SCRIPTS))
import ledger_status  # noqa: E402

spec = importlib.util.spec_from_file_location("harvest", SCRIPTS / "pr-ledger-harvest.py")
harvest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harvest)
pr_followup = harvest.pr_followup

M = ledger_status.MARKER
URL = "https://github.com/acme/app/pull/7"


class Status(unittest.TestCase):
    CASES = [
        ("- nit `a.py:3` — x **fixed in `abc1234`**", "closed"),
        ("- nit — x **fixed in abc1234**.", "closed"),
        ("- nit — x, fixed in abc1234", "closed"),
        ("- nit — retitled **done**", "closed"),
        ("- nit — **decided by the TD: no**", "closed"),
        ("- nit — **skip: out of scope**", "closed"),
        ("- nit — **verified unchanged**", "closed"),
        ("- nit — later **follow-up**", "follow-up"),
        ("- nit — later **follow-up** **bead hd-x.1**", "bead"),
        ("- nit — x", "unstated"),
        # a status quoted mid-entry doesn't close it
        ("- nit — was fixed in abc1234 but regressed; revisit", "unstated"),
        ("- nit — **fixed in 5cff27c** (`--settle`)", "closed"),
        ("- nit — **verified**, no change needed (log above)", "closed"),
        ("- **Nit 3:** the guide already says so.", "unstated"),
        ("- **fixed in abc1234** earlier, but **reopened**", "unstated"),
    ]

    def test_cases(self):
        for line, want in self.CASES:
            with self.subTest(line=line):
                self.assertEqual(ledger_status.status(line), want)

    def test_only_bullets_are_entries(self):
        body = f"{M}\n1. numbered — x\nprose — y\n- bullet — z **done**\n* star — w"
        self.assertEqual([l for _, l in ledger_status.entries(body)], ["- bullet — z **done**", "* star — w"])
        self.assertEqual(ledger_status.check(body), ["* star — w"])

    def test_paths(self):
        self.assertEqual(ledger_status.paths("- `codex/games/olympus/x.gd:4` and `README.md`, `#7`"),
                         ["codex/games/olympus/x.gd", "README.md"])


class FakeBd:
    """Records creates; fails the create whose 1-based number is in fail_on."""

    def __init__(self, fail_on=()):
        self.creates, self.fail_on = [], set(fail_on)

    def install(self, test):
        fake = self

        def run(self_bd, *args, write=False):
            if args[0] == "list":  # the "Review follow-ups" milestone already exists
                return '[{"id": "hd-ms", "issue_type": "milestone", "status": "open"}]'
            fake.creates.append(args)
            if len(fake.creates) in fake.fail_on:
                sys.exit("pr-followup: bd create failed: boom")
            return f"hd-t{len(fake.creates)}"

        orig = pr_followup.Bd.run
        pr_followup.Bd.run = run
        test.addCleanup(setattr, pr_followup.Bd, "run", orig)


class Harvest(unittest.TestCase):
    def setUp(self):
        self.patches = []
        self.comments = [
            {"id": 1, "user": "author", "html_url": "c1",
             "body": f"{M}\n- a `x.py` — one **follow-up**\n- b — two\n- c — three **done**"},
            {"id": 2, "user": "mallory", "html_url": "c2", "body": f"{M}\n- evil — file me **follow-up**"},
        ]
        orig = (harvest.merged_prs, harvest.ledgers, harvest.patch_comment)
        self.addCleanup(lambda: setattr(harvest, "merged_prs", orig[0]) or setattr(harvest, "ledgers", orig[1])
                        or setattr(harvest, "patch_comment", orig[2]))
        harvest.merged_prs = lambda repo, since: [
            {"number": 7, "url": URL, "mergedAt": "2026-10-01T00:00:00Z", "author": {"login": "author"}}]
        # the real ledgers() filters on the author inside the jq; mirror that here
        harvest.ledgers = lambda repo, num, author: [c for c in self.comments if c["user"] == author]
        harvest.patch_comment = lambda repo, cid, body: self.patches.append((cid, body))

    def test_dry_run_lists_open_entries_from_the_author_only(self):
        groups = harvest.collect(["acme/app"], "2026-09-01")
        items = [it for *_, its in groups for _, it in its]
        self.assertEqual([it["status"] for it in items], ["follow-up", "unstated"])
        self.assertEqual(items[0]["paths"], ["x.py"])
        self.assertEqual(self.patches, [])

    def test_ledgers_jq_filters_on_author(self):
        calls = []
        fresh = importlib.util.module_from_spec(spec)  # setUp stubbed this module's ledgers()
        spec.loader.exec_module(fresh)
        fresh.gh = lambda *a: calls.append(a) or ""
        fresh.ledgers("acme/app", 7, "author")
        self.assertIn('.user.login == "author"', calls[0][-1])

    def test_file_tags_each_entry_as_it_goes(self):
        FakeBd().install(self)
        groups = harvest.collect(["acme/app"], "2026-09-01")
        harvest.file_all(groups, "bd", {"acme/app": "hd-root"}, {})
        self.assertEqual(len(self.patches), 2)
        final = self.patches[-1][1]
        self.assertIn("one **follow-up** **bead hd-t1**", final)
        self.assertIn("two **bead hd-t2**", final)
        self.assertEqual(ledger_status.check(final), [])
        self.assertEqual([ledger_status.status(l) for _, l in ledger_status.entries(final)], ["bead", "bead", "closed"])

    def test_failure_midway_leaves_filed_beads_tagged(self):
        FakeBd(fail_on={2}).install(self)
        groups = harvest.collect(["acme/app"], "2026-09-01")
        with self.assertRaises(SystemExit):
            harvest.file_all(groups, "bd", {"acme/app": "hd-root"}, {})
        self.assertEqual(len(self.patches), 1)
        self.assertIn("**bead hd-t1**", self.patches[0][1])
        # a rerun sees only the entry that wasn't filed
        self.comments[0]["body"] = self.patches[0][1]
        items = [it for *_, its in harvest.collect(["acme/app"], "2026-09-01") for _, it in its]
        self.assertEqual([it["entry"] for it in items], ["- b — two"])

    def test_missing_root_files_nothing(self):
        bd = FakeBd()
        bd.install(self)
        groups = harvest.collect(["acme/app"], "2026-09-01")
        with self.assertRaises(SystemExit):
            harvest.file_all(groups, "bd", {}, {})
        self.assertEqual(bd.creates, [])
        self.assertEqual(self.patches, [])

    def test_path_root_beats_repo_root(self):
        self.assertEqual(pr_followup.resolve_root("acme/app", ["codex/games/olympus/x.gd"],
                                                  {"acme/app": "hd-a"}, {"codex/": "hd-c", "codex/games/olympus/": "hd-o"}),
                         "hd-o")
        self.assertEqual(pr_followup.resolve_root("ACME/app", ["y.py"], {"acme/app": "hd-a"}, {"codex/": "hd-c"}), "hd-a")


class GhFallback(unittest.TestCase):
    """gh.sh: plain gh only when no identity was asked for."""

    def run_gh(self, extra_env):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            subprocess.run(["git", "init", "-q", str(d)], check=True)
            sec = d / ".claude/skills/secrets/scripts"
            sec.mkdir(parents=True)
            # a secrets skill with no GH_TOKEN: `get` fails, `run` fails
            (sec / "secrets.sh").write_text("#!/bin/bash\necho secrets-run >&2\nexit 1\n")
            bindir = d / "bin"
            bindir.mkdir()
            (bindir / "gh").write_text("#!/bin/bash\necho plain-gh\n")
            (bindir / "gh").chmod(0o755)
            env = {"PATH": f"{bindir}:/usr/bin:/bin", "HOME": str(d)}
            env.update(extra_env)
            return subprocess.run(["bash", str(SCRIPTS / "gh.sh"), "api", "user"], cwd=d, env=env,
                                  capture_output=True, text=True)

    def test_no_identity_falls_back_to_plain_gh(self):
        p = self.run_gh({})
        self.assertEqual((p.returncode, p.stdout.strip()), (0, "plain-gh"))

    def test_agent_name_without_file_fails_closed(self):
        p = self.run_gh({"AGENT_NAME": "surveyor"})
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("plain-gh", p.stdout)

    def test_explicit_file_fails_closed(self):
        p = self.run_gh({"GH_SECRETS_ENV_FILE": "/nonexistent"})
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn("plain-gh", p.stdout)


if __name__ == "__main__":
    unittest.main()
