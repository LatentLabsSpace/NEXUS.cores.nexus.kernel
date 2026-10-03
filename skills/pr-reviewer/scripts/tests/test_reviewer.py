#!/usr/bin/env python3
"""Protocol tests for reviewer.py against fake_gh.py (no network, no live PRs).

Run: python3 .claude/skills/pr-reviewer/scripts/tests/test_reviewer.py
"""
import datetime as dt
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REVIEWER = HERE.parent / "reviewer.py"
FAKE = HERE / "fake_gh.py"
R = "acme/app"
H1, H2 = "a" * 40, "b" * 40

spec = importlib.util.spec_from_file_location("reviewer", REVIEWER)
reviewer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reviewer)


class Harness(unittest.TestCase):
    """fake-gh sandbox + helpers; holds no tests, so subclasses don't re-run any."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.db = self.tmp / "db.json"
        iso = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
        self.iso = iso
        self.write_db({"next_id": 1000, "now_iso": iso, "comments": {},
                       "prs": {f"{R}#7": {"title": "t", "url": "u", "headRefOid": H1, "headRefName": "feat/x",
                                          "baseRefName": "main", "isDraft": False, "createdAt": iso,
                                          "updatedAt": iso, "body": "", "commits": [{"sha": H1, "date": iso}]}}})

    def write_db(self, d):
        self.db.write_text(json.dumps(d))

    def read_db(self):
        return json.loads(self.db.read_text())

    def run_s(self, *a, env=None):
        e = {**os.environ, "PR_REVIEWER_GH": f"{sys.executable} {FAKE}", "FAKE_GH_DB": str(self.db),
             "PR_REVIEWER_STATE": str(self.tmp / "state"), **(env or {})}
        e.pop("PR_REVIEWER_AGENT", None)
        return subprocess.run([sys.executable, str(REVIEWER), *a], capture_output=True, text=True, env=e)

    def comments(self):
        return self.read_db()["comments"].get(f"{R}#7", [])

    def body(self, text):
        p = self.tmp / "body.md"
        p.write_text(text)
        return str(p)



class Proto(Harness):
    # ── claims ──
    def test_claim_then_second_agent_is_held(self):
        r = self.run_s("claim", f"{R}#7", "--agent", "A")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.comments()), 1)
        self.assertIn("pr-reviewer:claim", self.comments()[0]["body"])
        r2 = self.run_s("claim", f"{R}#7", "--agent", "B")
        self.assertEqual(r2.returncode, 11)
        self.assertEqual(len(self.comments()), 1, "loser must not leave a claim behind")

    def test_other_role_can_claim_concurrently(self):
        self.assertEqual(self.run_s("claim", f"{R}#7", "--agent", "A").returncode, 0)
        self.assertEqual(self.run_s("claim", f"{R}#7", "--agent", "B", "--role", "security").returncode, 0)

    def test_lost_race_deletes_own_claim(self):
        r = self.run_s("claim", f"{R}#7", "--agent", "A", env={"FAKE_GH_RACE": "1"})
        self.assertEqual(r.returncode, 11, r.stdout + r.stderr)
        cs = self.comments()
        self.assertEqual(len(cs), 1)
        self.assertIn("agent=rival-A", cs[0]["body"])

    def test_expired_claim_can_be_taken_over_and_is_cleaned_on_post(self):
        d = self.read_db()
        stale = int(time.time()) - 3 * 3600
        d["comments"][f"{R}#7"] = [{"id": 5, "user": "u", "created_at": self.iso, "updated_at": self.iso,
                                    "html_url": "h5", "body": f"<!-- pr-reviewer:claim v=1 role=general head={H1} "
                                                              f"agent=ghost ts={stale} ttl=60 -->"}]
        self.write_db(d)
        self.assertEqual(self.run_s("claim", f"{R}#7", "--agent", "A").returncode, 0)
        r = self.run_s("post", f"{R}#7", "--agent", "A",
                       "--body-file", self.body("ok\n<!-- review-verdict: blockers=0 nits=0 -->"))
        self.assertEqual(r.returncode, 0, r.stderr)
        kinds = ["claim" if "pr-reviewer:claim" in c["body"] else "review" for c in self.comments()]
        self.assertEqual(kinds, ["review"])

    def test_claim_refused_when_head_already_reviewed(self):
        self.run_s("claim", f"{R}#7", "--agent", "A")
        self.run_s("post", f"{R}#7", "--agent", "A", "--body-file",
                   self.body("x\n<!-- review-verdict: blockers=1 nits=0 -->"))
        self.assertEqual(self.run_s("claim", f"{R}#7", "--agent", "B").returncode, 10)

    # ── post guards ──
    def test_post_refuses_trigger_string_any_case(self):
        self.run_s("claim", f"{R}#7", "--agent", "A")
        trig = "/" + "ReViEw"
        r = self.run_s("post", f"{R}#7", "--agent", "A", "--body-file",
                       self.body(f"please {trig} again\n<!-- review-verdict: blockers=0 nits=0 -->"))
        self.assertEqual(r.returncode, 3)
        self.assertTrue(all("pr-reviewer:review" not in c["body"] for c in self.comments()))

    def test_post_requires_verdict_trailer_unless_note(self):
        self.run_s("claim", f"{R}#7", "--agent", "A")
        self.assertEqual(self.run_s("post", f"{R}#7", "--agent", "A",
                                    "--body-file", self.body("no trailer")).returncode, 3)
        r = self.run_s("post", f"{R}#7", "--agent", "A", "--note", "--body-file", self.body("fyi"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("pr-reviewer:note", self.comments()[-1]["body"])

    def test_post_requires_a_full_head_sha(self):
        self.run_s("claim", f"{R}#7", "--agent", "A")
        r = self.run_s("post", f"{R}#7", "--agent", "A", "--head", H1[:7], "--allow-stale-head",
                       "--body-file", self.body("x\n<!-- review-verdict: blockers=0 nits=0 -->"))
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertTrue(all("pr-reviewer:review" not in c["body"] for c in self.comments()))

    def test_stale_head_post_records_the_reviewed_head(self):
        self.run_s("claim", f"{R}#7", "--agent", "A")
        d = self.read_db()
        d["prs"][f"{R}#7"]["headRefOid"] = H2
        self.write_db(d)
        r = self.run_s("post", f"{R}#7", "--agent", "A", "--head", H1, "--allow-stale-head",
                       "--body-file", self.body("x\n<!-- review-verdict: blockers=0 nits=0 -->"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f"head={H1}", self.comments()[-1]["body"])

    def test_post_refuses_when_head_moved(self):
        self.run_s("claim", f"{R}#7", "--agent", "A")
        d = self.read_db()
        d["prs"][f"{R}#7"]["headRefOid"] = H2
        self.write_db(d)
        r = self.run_s("post", f"{R}#7", "--agent", "A", "--body-file",
                       self.body("x\n<!-- review-verdict: blockers=0 nits=0 -->"))
        self.assertEqual(r.returncode, 4)

    def test_checkout_is_per_agent_and_post_removes_only_yours(self):
        g = lambda *a, cwd=None: subprocess.run(["git", *a], cwd=cwd, check=True, capture_output=True, text=True)
        origin, clone = self.tmp / "origin.git", self.tmp / "clone"
        g("init", "-q", "--bare", str(origin))
        g("clone", "-q", str(origin), str(clone))
        (clone / "f.txt").write_text("x\n")
        g("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "c", cwd=clone)
        g("add", "f.txt", cwd=clone)
        g("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "c2", cwd=clone)
        sha = g("rev-parse", "HEAD", cwd=clone).stdout.strip()
        g("push", "-q", "origin", "HEAD:refs/pull/7/head", cwd=clone)
        d = self.read_db()
        d["prs"][f"{R}#7"]["headRefOid"] = sha
        self.write_db(d)
        wa = json.loads(self.run_s("checkout", f"{R}#7", "--agent", "A", "--clone", str(clone)).stdout)["worktree"]
        wb = json.loads(self.run_s("checkout", f"{R}#7", "--agent", "B", "--clone", str(clone)).stdout)["worktree"]
        self.assertNotEqual(wa, wb)
        self.assertTrue(Path(wa, "f.txt").exists() and Path(wb, "f.txt").exists())
        self.run_s("claim", f"{R}#7", "--agent", "A")
        r = self.run_s("post", f"{R}#7", "--agent", "A", "--body-file",
                       self.body("x\n<!-- review-verdict: blockers=0 nits=0 -->"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(Path(wa).exists(), "post removes the poster's worktree")
        self.assertTrue(Path(wb).exists(), "another agent's worktree is untouched")
        self.assertEqual(self.run_s("release", f"{R}#7", "--agent", "B").returncode, 0)
        self.assertFalse(Path(wb).exists(), "release removes it too")

    def test_release_removes_claim(self):
        self.run_s("claim", f"{R}#7", "--agent", "A")
        self.assertEqual(self.run_s("release", f"{R}#7", "--agent", "A").returncode, 0)
        self.assertEqual(self.comments(), [])


class CommitStatuses(Harness):
    """Each role's verdict is mirrored as a "review/<role>" commit status."""

    def statuses(self, sha=H1):
        latest = {}
        for st in self.read_db().get("statuses", {}).get(sha, []):
            latest[st["context"]] = st
        return latest

    def post(self, b=0, n=0, role="general", agent="A", note=False, env=None):
        extra = ["--note"] if note else []
        return self.run_s("post", f"{R}#7", "--agent", agent, "--role", role, *extra, "--body-file",
                          self.body(f"x\n<!-- review-verdict: blockers={b} nits={n} -->"), env=env)

    def test_claim_sets_pending_with_its_expiry(self):
        self.assertEqual(self.run_s("claim", f"{R}#7", "--agent", "A").returncode, 0)
        st = self.statuses()["review/general"]
        self.assertEqual(st["state"], "pending")
        self.assertRegex(st["description"], r"^Review in progress \(A, claim until \d\d:\d\dZ\)$")

    def test_review_with_blockers_fails_the_check_and_links_the_comment(self):
        self.run_s("claim", f"{R}#7", "--agent", "A")
        r = self.post(b=2, n=1)
        self.assertEqual(r.returncode, 0, r.stderr)
        st = self.statuses()["review/general"]
        self.assertEqual((st["state"], st["description"]), ("failure", "2 blockers, 1 nit"))
        self.assertEqual(st["target_url"], json.loads(r.stdout)["posted"])

    def test_clean_and_nits_reviews_pass(self):
        self.run_s("claim", f"{R}#7", "--agent", "A")
        self.post(b=0, n=0)
        self.assertEqual(self.statuses()["review/general"]["description"], "Clean — no findings")
        self.run_s("claim", f"{R}#7", "--agent", "A", "--role", "security")
        self.post(b=0, n=3, role="security")
        st = self.statuses()["review/security"]
        self.assertEqual((st["state"], st["description"]), ("success", "No blockers, 3 nits"))

    def test_note_leaves_the_check_alone(self):
        self.run_s("claim", f"{R}#7", "--agent", "A")
        self.post(b=1)
        self.post(note=True)
        self.assertEqual(self.statuses()["review/general"]["state"], "failure")

    def test_release_resets_to_pending(self):
        self.run_s("claim", f"{R}#7", "--agent", "A")
        self.run_s("release", f"{R}#7", "--agent", "A")
        st = self.statuses()["review/general"]
        self.assertEqual((st["state"], st["description"]), ("pending", "Awaiting review (claim released)"))

    def test_statuses_can_be_turned_off(self):
        off = {"PR_REVIEWER_STATUSES": "0"}
        self.run_s("claim", f"{R}#7", "--agent", "A", env=off)
        self.post(b=1, env=off)
        self.assertEqual(self.statuses(), {})

    def test_status_permission_failure_does_not_lose_the_review(self):
        no = {"FAKE_GH_STATUS_FORBIDDEN": "1"}
        self.run_s("claim", f"{R}#7", "--agent", "A", env=no)
        r = self.post(b=1, env=no)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("error", json.loads(r.stdout)["commit_status"])
        self.assertIn("could not set status", r.stderr)
        self.assertTrue(any("pr-reviewer:review" in c["body"] for c in self.comments()))

    def test_ci_summary_ignores_review_checks(self):
        pr = {"statusCheckRollup": [{"context": "review/general", "state": "FAILURE"},
                                    {"name": "build", "conclusion": "SUCCESS"}]}
        self.assertEqual(reviewer.checks_summary(pr), "green")


class Aggregate(Harness):
    """The aggregate role waits for its inputs at the head, then merges them."""

    def review(self, role, b=0, n=0, agent=None):
        agent = agent or f"{role}-1"
        self.assertEqual(self.run_s("claim", f"{R}#7", "--agent", agent, "--role", role).returncode, 0)
        r = self.run_s("post", f"{R}#7", "--agent", agent, "--role", role, "--body-file",
                       self.body(f"{role} findings\n<!-- review-verdict: blockers={b} nits={n} -->"))
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_waits_until_an_input_has_reviewed_the_head(self):
        r = self.run_s("claim", f"{R}#7", "--agent", "agg", "--role", "aggregate")
        self.assertEqual(r.returncode, 12, r.stdout + r.stderr)
        self.assertEqual(self.comments(), [], "a waiting aggregate leaves no claim behind")

    def test_configured_inputs_must_all_cover_the_head(self):
        env = {"PR_REVIEWER_AGGREGATE_INPUTS": "general,security"}
        self.review("general", b=1)
        self.assertEqual(self.run_s("claim", f"{R}#7", "--agent", "agg", "--role", "aggregate",
                                    env=env).returncode, 12)
        self.review("security")
        self.assertEqual(self.run_s("claim", f"{R}#7", "--agent", "agg", "--role", "aggregate",
                                    env=env).returncode, 0)

    def test_packet_carries_input_bodies_and_post_records_inputs(self):
        d = self.read_db()
        d["diffs"] = {f"{R}:main...{H1}": "diff --git a/f b/f\n+x\n"}
        self.write_db(d)
        self.review("general", b=1)
        self.review("security", n=2)
        r = self.run_s("claim", f"{R}#7", "--agent", "agg", "--role", "aggregate", "--packet")
        self.assertEqual(r.returncode, 0, r.stderr)
        pkt = json.loads(r.stdout)
        self.assertEqual([i["role"] for i in pkt["inputs"]], ["general", "security"])
        self.assertIn("general findings", pkt["inputs"][0]["body"])
        r = self.run_s("post", f"{R}#7", "--agent", "agg", "--role", "aggregate", "--body-file",
                       self.body("merged\n<!-- review-verdict: blockers=1 nits=2 -->"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("inputs=general,security", self.comments()[-1]["body"])
        sts = {k: v["state"] for k, v in CommitStatuses.statuses(self).items()}
        self.assertEqual(sts, {"review/general": "failure", "review/security": "success",
                               "review/aggregate": "failure"})

    def test_aggregate_never_overrides_a_role_check(self):
        self.review("general", b=1)
        self.run_s("claim", f"{R}#7", "--agent", "agg", "--role", "aggregate")
        self.run_s("post", f"{R}#7", "--agent", "agg", "--role", "aggregate", "--body-file",
                   self.body("disputed: false positive\n<!-- review-verdict: blockers=0 nits=0 -->"))
        sts = CommitStatuses.statuses(self)
        self.assertEqual(sts["review/general"]["state"], "failure")
        self.assertEqual(sts["review/aggregate"]["state"], "success")

    def test_post_refused_while_an_input_is_mid_review(self):
        self.review("general")
        self.run_s("claim", f"{R}#7", "--agent", "agg", "--role", "aggregate")
        self.run_s("claim", f"{R}#7", "--agent", "g2", "--role", "general", "--force")
        r = self.run_s("post", f"{R}#7", "--agent", "agg", "--role", "aggregate", "--body-file",
                       self.body("merged\n<!-- review-verdict: blockers=0 nits=0 -->"))
        self.assertEqual(r.returncode, 5, r.stdout + r.stderr)

    def test_an_input_reposting_makes_the_aggregate_stale(self):
        self.review("general", b=1)
        self.run_s("claim", f"{R}#7", "--agent", "agg", "--role", "aggregate")
        self.run_s("post", f"{R}#7", "--agent", "agg", "--role", "aggregate", "--body-file",
                   self.body("merged\n<!-- review-verdict: blockers=1 nits=0 -->"))
        st = lambda: json.loads(self.run_s("show", f"{R}#7", "--role", "aggregate").stdout)["roles"]["aggregate"]["state"]
        self.assertEqual(st(), "done")
        self.run_s("claim", f"{R}#7", "--agent", "g2", "--role", "general", "--force")
        self.run_s("post", f"{R}#7", "--agent", "g2", "--role", "general", "--body-file",
                   self.body("withdrawn\n<!-- review-verdict: blockers=0 nits=0 -->"))
        self.assertEqual(st(), "rereview-blockers")


class ReviewState(Harness):
    """`reviews` — what the author side (pr-review-loop) reads."""

    def state(self, *a, env=None):
        r = self.run_s("reviews", f"{R}#7", *a, env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)

    def review(self, role, b=0, n=0):
        Aggregate.review(self, role, b, n)

    def push(self, sha=H2):
        d = self.read_db()
        d["prs"][f"{R}#7"]["headRefOid"] = sha
        d["prs"][f"{R}#7"]["commits"].append({"sha": sha, "date": self.iso})
        self.write_db(d)

    def test_nobody_reviewing_is_none(self):
        s = self.state()
        self.assertEqual((s["verdict"], s["all_reviewed"], s["expected"]), ("none", False, []))

    def test_asked_for_role_without_review_is_incomplete(self):
        s = self.state("--roles", "security")
        self.assertEqual((s["verdict"], s["missing"]), ("incomplete", ["security"]))
        self.assertEqual(self.state(env={"PR_REVIEW_REQUIRED_ROLES": "ops"})["missing"], ["ops"])

    def test_required_checks_from_branch_rules(self):
        d = self.read_db()
        d["required_checks"] = ["review/security", "build"]
        self.write_db(d)
        s = self.state()
        self.assertEqual((s["required"], s["missing"]), (["security"], ["security"]))

    def test_rollup_is_worst_role(self):
        self.review("general", n=1)
        self.assertEqual(self.state()["verdict"], "nits")
        self.review("security", b=1)
        s = self.state()
        self.assertEqual((s["verdict"], s["all_reviewed"]), ("blockers", True))
        self.assertEqual(s["roles"]["security"]["counts"], {"blockers": 1, "nits": 0})

    def test_push_makes_every_role_expected_again(self):
        self.review("general")
        self.assertEqual(self.state()["verdict"], "clean")
        self.push()
        s = self.state()
        self.assertEqual((s["verdict"], s["missing"]), ("incomplete", ["general"]))
        self.assertFalse(s["roles"]["general"]["covers_head"])

    def test_in_progress_and_read_list(self):
        self.review("general", b=1)
        self.run_s("claim", f"{R}#7", "--agent", "s1", "--role", "security")
        s = self.state()
        self.assertEqual(s["in_progress"], ["security"])
        self.assertEqual(s["read"], [s["roles"]["general"]["url"]])

    def test_current_aggregate_is_what_the_author_reads(self):
        self.review("general", b=1)
        self.review("aggregate", b=1)
        s = self.state()
        self.assertTrue(s["aggregate_current"])
        self.assertEqual(s["read"], [s["roles"]["aggregate"]["url"]])
        self.assertEqual(s["roles"]["aggregate"]["inputs"], ["general"])

    def test_legacy_reviews_do_not_make_a_role_expected(self):
        d = self.read_db()
        d["comments"][f"{R}#7"] = [{"id": 1, "user": "u", "created_at": self.iso, "updated_at": self.iso,
                                    "html_url": "h1", "body": "old CI review\n<!-- review-verdict: blockers=1 nits=0 -->"}]
        self.write_db(d)
        s = self.state()
        self.assertEqual((s["expected"], s["verdict"]), ([], "none"))
        self.assertEqual(s["legacy_read"], ["h1"], "its findings are still surfaced")

    def test_stale_read_lists_findings_from_an_earlier_head(self):
        self.review("general", b=1)
        self.review("security")
        self.push()
        s = self.state()
        self.assertEqual(s["read"], [])
        self.assertEqual(s["stale_read"], [s["roles"]["general"]["url"]], "clean reviews have nothing to read")

    def test_status_mismatch_is_flagged(self):
        off = {"PR_REVIEWER_STATUSES": "0"}
        self.run_s("claim", f"{R}#7", "--agent", "A", env=off)
        self.run_s("post", f"{R}#7", "--agent", "A", "--body-file",
                   self.body("x\n<!-- review-verdict: blockers=1 nits=0 -->"), env=off)
        self.assertTrue(self.state()["roles"]["general"]["status_mismatch"])


class Status(unittest.TestCase):
    def pr(self, head=H1):
        return {"headRefOid": head}

    def cc(self, comments):
        return reviewer.classify_comments(comments)

    def c(self, i, body, when="2026-09-26T10:00:00Z"):
        return {"id": i, "body": body, "user": "u", "created_at": when, "updated_at": when, "html_url": f"h{i}"}

    def rev(self, i, head=H1, b=0, n=1, role="general"):
        return self.c(i, f"r\n<!-- review-verdict: blockers={b} nits={n} -->\n"
                         f"<!-- pr-reviewer:review v=1 role={role} head={head} agent=A -->")

    def test_states(self):
        st = lambda cs, head=H1, role="general": reviewer.role_status(self.pr(head), self.cc(cs), [], role)["state"]
        self.assertEqual(st([]), "new")
        self.assertEqual(st([self.rev(1)]), "done")
        self.assertEqual(st([self.rev(1), self.c(2, "fixed it")]), "reply")
        self.assertEqual(st([self.rev(1), self.c(2, "x\n<!-- pr-reviewer:note v=1 role=general head=a agent=A -->")]),
                         "done", "reviewer's own notes are not author replies")
        self.assertEqual(st([self.rev(1, b=2)], head=H2), "rereview-blockers")
        self.assertEqual(st([self.rev(1, b=0)], head=H2), "rereview")
        self.assertEqual(st([self.rev(1)], role="security"), "new", "roles are independent")
        self.assertEqual(st([self.rev(1), self.c(2, "<!-- pr-review-loop:deferred-ledger -->\nledger")]),
                         "done", "the author's ledger is bookkeeping, not a reply")
        bot = {**self.c(2, "This PR exceeds the recommended size"), "user": "github-actions[bot]"}
        self.assertEqual(st([self.rev(1), bot]), "done", "bot comments are not replies")

    def test_a_reply_wakes_only_the_role_it_addresses(self):
        sec = self.rev(1, role="security")
        gen = self.rev(2, role="general")
        st = lambda cs, role: reviewer.role_status(self.pr(), self.cc(cs), [], role)["state"]
        for body in ("Re: security finding 2 — not changing this because …",
                     "@security see above", "Answering https://x/acme/app/pull/7#issuecomment-1"):
            cs = [sec, gen, self.c(3, body)]
            self.assertEqual((st(cs, "security"), st(cs, "general")), ("reply", "done"), body)
        cs = [sec, gen, self.c(3, "pushed a fix, PTAL")]
        self.assertEqual((st(cs, "security"), st(cs, "general")), ("reply", "reply"),
                         "an unaddressed reply goes to every role")

    def test_legacy_review_head_from_heading(self):
        legacy = self.c(1, "## Code review — PR #89 (head `aaaaaaa`)\n...\n<!-- review-verdict: blockers=0 nits=2 -->")
        s = reviewer.role_status(self.pr(H1), self.cc([legacy]), [], "general")
        self.assertEqual(s["state"], "done")
        self.assertEqual(reviewer.role_status(self.pr(H2), self.cc([legacy]), [], "general")["state"], "rereview")

    def test_legacy_review_without_head_uses_commit_times(self):
        legacy = self.c(1, "LGTM\n<!-- review-verdict: blockers=1 nits=0 -->", when="2026-09-26T10:00:00Z")
        later = [{"sha": H2, "date": "2026-09-26T11:00:00Z"}]
        self.assertEqual(reviewer.role_status(self.pr(H2), self.cc([legacy]), later, "general")["state"],
                         "rereview-blockers")
        self.assertEqual(reviewer.role_status(self.pr(H2), self.cc([legacy]), [], "general")["state"], "done")


class Relations(unittest.TestCase):
    def kinds(self, text):
        return [(r, n, k) for r, n, k in reviewer.text_refs(text, "acme/app")]

    def test_prose(self):
        self.assertIn(("acme/app", 12, "depends-on"), self.kinds("Depends on #12; the diff shows both"))
        self.assertIn(("acme/app", 6544, "depends-on"), self.kinds("base `x` (#6544, which must merge first)"))
        self.assertIn(("acme/app", 5, "supersedes"), self.kinds("Supersedes #5."))
        self.assertIn(("acme/lib", 9, "superseded-by"),
                      self.kinds("**Carry PR: https://github.com/acme/lib/pull/9**"))
        self.assertIn(("acme/app", 3, "follow-up-to"), self.kinds("Follow-up to #3"))
        self.assertIn(("acme/app", 4, "conflicts-with"), self.kinds("Conflicts with #4 in buildPrefix"))
        self.assertIn(("other/x", 2, "mentions"), self.kinds("see other/x#2"))
        self.assertEqual(self.kinds("color: #fff and &#39;"), [])

    def test_order_puts_dependencies_first(self):
        mk = lambda k, state, created: {"key": k, "repo": "acme/app", "number": int(k.split("#")[1]),
                                        "prio": 2, "status": {"state": state}, "createdAt": created,
                                        "relations": []}
        a, b = mk("acme/app#1", "rereview-blockers", "1"), mk("acme/app#2", "new", "2")
        out = reviewer.order([a, b], {"acme/app#1": {"acme/app#2"}})
        self.assertEqual([i["key"] for i in out], ["acme/app#2", "acme/app#1"])

    def test_priority_labels(self):
        self.assertEqual(reviewer.prio_rank({"labels": [{"name": "priority/p0"}]}), 0)
        self.assertEqual(reviewer.prio_rank({"labels": [{"name": "priority: high"}]}), 1)
        self.assertEqual(reviewer.prio_rank({"labels": [{"name": "kind/bug"}]}), 2)


if __name__ == "__main__":
    unittest.main(verbosity=1)
