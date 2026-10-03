#!/usr/bin/env python3
"""Programmatic grader for the sandbox evals.

  python3 check_reviewer.py <eval-id> <fixture-dir> [<final-response.md>]

Prints {"expectations": [{"text", "passed", "evidence"}]} (skill-creator grading
schema) covering what can be checked mechanically from db.json and the state dir.
Judgement-level assertions (quality of findings) are graded by the grader agent.
"""
import json
import re
import sys
from pathlib import Path

eid, fx = sys.argv[1], Path(sys.argv[2])
resp = Path(sys.argv[3]).read_text() if len(sys.argv) > 3 and Path(sys.argv[3]).exists() else ""
db = json.loads((fx / "db.json").read_text())
R = "acme/app"
TRIG = "/" + "review"
MK = re.compile(r"<!--\s*pr-reviewer:(claim|review|note)\s+(.*?)\s*-->", re.S)
VT = re.compile(r"<!--\s*review-verdict:\s*blockers=(\d+)\s+nits=(\d+)\s*-->")
exp = []


def check(text, ok, ev):
    exp.append({"text": text, "passed": bool(ok), "evidence": ev})


def reviews(n, role="general"):
    out = []
    for c in db["comments"].get(f"{R}#{n}", []):
        m = MK.search(c["body"] or "")
        if m and m.group(1) == "review" and f"role={role}" in m.group(2) and c["id"] >= 5000:
            v = VT.search(c["body"])
            out.append({"id": c["id"], "body": c["body"], "b": int(v.group(1)) if v else None,
                        "n": int(v.group(2)) if v else None})
    return out


agent_comments = [c for cs in db["comments"].values() for c in cs if c["id"] >= 5000]
claims_left = [c for c in agent_comments if (MK.search(c["body"] or "") or [None, ""])[1] == "claim"
               or "pr-reviewer:claim" in (c["body"] or "")]

if eid in ("full-surface", "handoff"):
    check("No agent-posted comment contains the review-workflow trigger string",
          not any(TRIG in (c["body"] or "").lower() for c in agent_comments),
          f"{len(agent_comments)} agent comments scanned")
    check("No claim comments are left behind", not [c for c in db["comments"].get(f"{R}#10", []) +
          [x for cs in db["comments"].values() for x in cs] if "pr-reviewer:claim" in (c["body"] or "")],
          f"claims remaining: {[c['id'] for cs in db['comments'].values() for c in cs if 'pr-reviewer:claim' in (c['body'] or '')]}")

if eid == "full-surface":
    r10, r11, r12, r13 = reviews(10), reviews(11), reviews(12), reviews(13)
    check("Exactly one new review each on #10, #11, #12 and none on the up-to-date #13",
          len(r10) == len(r11) == len(r12) == 1 and not r13, f"#10={len(r10)} #11={len(r11)} #12={len(r12)} #13={len(r13)}")
    if r10 and r11:
        check("#10 (stack parent) was reviewed before #11 (stacked child)", r10[0]["id"] < r11[0]["id"],
              f"#10 id {r10[0]['id']} vs #11 id {r11[0]['id']}")
    if r12 and r10:
        check("#12 (re-review after blocker fix) was reviewed first", r12[0]["id"] < r10[0]["id"],
              f"#12 id {r12[0]['id']} vs #10 id {r10[0]['id']}")
    check("#10 review reports at least one blocker", bool(r10) and (r10[0]["b"] or 0) >= 1, str(r10[:1] and r10[0]["b"]))
    check("#10 review identifies the off-by-one in the limit comparison (> vs >=, limit+1 calls)",
          bool(r10) and re.search(r">=|off-by-one|limit ?\+ ?1|one extra|4 calls|fourth", r10[0]["body"], re.I),
          "regex on #10 review body")
    check("#11 review reports the uninitialized `denied` attribute as a blocker",
          bool(r11) and (r11[0]["b"] or 0) >= 1 and re.search(r"denied", r11[0]["body"]) and
          re.search(r"AttributeError|__init__|initiali[sz]", r11[0]["body"]), "regex on #11 review body")
    check("#11 review cross-references #10 (stack/dependency)", bool(r11) and re.search(r"#10\b", r11[0]["body"]),
          "looks for #10 in #11 review")
    check("#12 re-review acknowledges the safe_load fix of the prior blocker",
          bool(r12) and re.search(r"safe_load", r12[0]["body"]), "regex")
    check("#12 re-review flags the api_token/config logging as a blocker",
          bool(r12) and (r12[0]["b"] or 0) >= 1 and re.search(r"token|secret|credential", r12[0]["body"], re.I), "regex")
    check("Final response gives a merge order with #10 before #11",
          bool(re.search(r"#10.{0,200}#11", resp, re.S)) and bool(re.search(r"merge order|order", resp, re.I)),
          "regex on final response")

if eid == "triage":
    check("No comments were posted (read-only request)", not agent_comments, f"{len(agent_comments)} new comments")
    pos = {n: resp.find(f"#{n}") for n in (10, 11, 12)}
    check("Response lists #12 before #10 and #10 before #11",
          all(v >= 0 for v in pos.values()) and pos[12] < pos[10] < pos[11], str(pos))
    check("Response says #13 is up to date / needs no review", bool(re.search(r"#13.{0,120}(up to date|done|no (re-?)?review|already|skip|current)", resp, re.I | re.S)), "regex")
    check("Response explains #11 waits on #10 because it is stacked on it",
          bool(re.search(r"stack", resp, re.I)), "regex 'stack'")

if eid == "handoff":
    r10 = reviews(10)
    check("A review was posted on #10 by a new agent", len(r10) == 1 and "reviewer-crashed" not in r10[0]["body"],
          str([r["id"] for r in r10]))
    notes = fx / "state" / "acme__app" / "pr-10" / "notes.md"
    nt = notes.read_text() if notes.exists() else ""
    check("The crashed reviewer's notes were preserved (append-only)", "reviewer-crashed" in nt and "STILL TO CHECK" in nt,
          f"{len(nt)} chars")
    check("A new notes section was appended by the new agent", nt.count("## ") >= 2, f"sections: {nt.count('## ')}")
    check("#10 review reports the boundary bug the notes flagged as still-to-check",
          bool(r10) and (r10[0]["b"] or 0) >= 1 and re.search(r">=|off-by-one|limit ?\+ ?1|one extra", r10[0]["body"], re.I),
          "regex")
    check("#10 review mentions the README interaction with #12", bool(r10) and re.search(r"#12\b", r10[0]["body"]), "regex")
    others = [c for c in agent_comments if not any(c in db["comments"].get(f"{R}#10", []) for _ in [0])]
    check("Only #10 was reviewed (the user asked to pick up that one PR)", not others,
          f"comments on other PRs: {[c['id'] for c in others]}")

def marker(c):
    m = MK.search(c["body"] or "")
    return (m.group(1), dict(kv.split("=", 1) for kv in m.group(2).split() if "=" in kv)) if m else (None, {})


if eid in ("headmove", "pushback", "roles", "carry"):
    check("No agent-posted comment contains the review-workflow trigger string",
          not any(TRIG in (c["body"] or "").lower() for c in agent_comments), f"{len(agent_comments)} scanned")
    mine = [c for c in agent_comments if marker(c)[0] == "claim"]
    check("The agent left no claim comments of its own behind", not mine, str([c["id"] for c in mine]))

if eid == "headmove":
    r10 = reviews(10)
    check("Exactly one review posted on #10", len(r10) == 1, str(len(r10)))
    if r10:
        k, meta = marker([c for c in agent_comments if c["id"] == r10[0]["id"]][0])
        check("The posted review's head marker is the NEW head (6666…), not the snapshotted one",
              meta.get("head", "").startswith("6666666"), meta.get("head", ""))
        check("The review does not report the (now fixed) off-by-one as an open blocker",
              (r10[0]["b"] or 0) == 0 or not re.search(r"Medium \(blocker\).{0,400}(off-by-one|limit ?\+ ?1|>=)",
                                                      r10[0]["body"], re.S | re.I),
              f"blockers={r10[0]['b']}")
        check("The review acknowledges the head moved / covers both heads (1111111 and 6666666)",
              "1111111" in r10[0]["body"] and "6666666" in r10[0]["body"], "sha prefixes in body")
        check("The review credits the new boundary test (test_limit_enforced)",
              "test_limit_enforced" in r10[0]["body"] or re.search(r"boundary test", r10[0]["body"], re.I), "regex")

if eid == "pushback":
    posts = [c for c in agent_comments if marker(c)[0] in ("review", "note")]
    check("The agent answered the pushback on #20 with a review or note", bool(posts), str(len(posts)))
    body = " ".join(c["body"] for c in posts)
    check("The SQL-injection finding is withdrawn (admits the earlier review was wrong)",
          bool(re.search(r"withdr|retract|was wrong|mistaken|false positive|incorrect|my error|I was wrong", body, re.I)),
          "regex")
    r20 = reviews(20)
    check("If a new review verdict was posted, it has 0 blockers",
          all((r["b"] or 0) == 0 for r in r20), str([r["b"] for r in r20]))
    pk = fx / "state" / "acme__app" / "pr-20" / "packet-general.json"
    check("The work packet carries the author's reply text (reviewer needn't fetch comments by hand)",
          pk.exists() and "false positive" in pk.read_text(), str(pk.exists()))
    check("The response engages with the allowlist + bound-parameter argument specifically",
          bool(re.search(r"ALLOWED_TABLES|allowlist|allow-list|allowed tables", body, re.I)) and
          bool(re.search(r"param|bound|\?", body)), "regex")

if eid == "roles":
    sec = {n: reviews(n, "security") for n in (10, 11, 12, 13)}
    gen = [c for c in agent_comments if marker(c)[0] == "review" and marker(c)[1].get("role") == "general"]
    check("Posted security-role reviews (and no general-role reviews)",
          sum(len(v) for v in sec.values()) >= 3 and not gen, f"security={ {k: len(v) for k, v in sec.items()} } general={len(gen)}")
    live = [c for c in db["comments"].get(f"{R}#10", []) if c["id"] == 4030]
    check("The general agent's live claim on #10 was left untouched", bool(live), str(bool(live)))
    check("#10 was still reviewed by the security role despite the general claim", bool(sec[10]), str(len(sec[10])))
    check("#12 security review flags the api_token logging as a blocker",
          bool(sec[12]) and (sec[12][0]["b"] or 0) >= 1 and re.search(r"token|secret|credential", sec[12][0]["body"], re.I),
          "regex")
    check("Final response reports general-bot's live general claim on #10 (surface awareness of other roles)",
          bool(re.search(r"general-bot", resp)), "regex on final response")
    check("#13 (docs typo) security review is clean (0 blockers)", not sec[13] or (sec[13][0]["b"] or 0) == 0,
          str([r["b"] for r in sec[13]]))

if eid == "carry":
    r30, r31 = reviews(30), reviews(31)
    check("The carry PR #31 was reviewed", len(r31) == 1, str(len(r31)))
    if r31:
        check("#31 review flags the dropped backoff cap from #30 as a blocker",
              (r31[0]["b"] or 0) >= 1 and re.search(r"MAX_BACKOFF|backoff|cap", r31[0]["body"], re.I), "regex")
        check("#31 review references #30", bool(re.search(r"#30\b", r31[0]["body"])), "regex")
        check("#31 review confronts the PR body's 'No functional changes from #30' claim",
              bool(re.search(r"functional change", r31[0]["body"], re.I)), "regex")
    pk = fx / "state" / "acme__app" / "pr-31" / "packet-general.json"
    check("The #31 work packet carries the PR title and body",
          pk.exists() and "Carry of #30" in pk.read_text(), str(pk.exists()))
    if r30 and r31:
        check("#31 (live carry) reviewed before #30 (superseded)", r31[0]["id"] < r30[0]["id"], "ids")
    check("#30 is not given a duplicate full blocker review (it is superseded; a note or superseded-aware review is fine)",
          not r30 or re.search(r"supersed|carr", r30[0]["body"], re.I), str(len(r30)))
    check("Final response mentions #31 dropping part of #30", bool(re.search(r"(backoff|cap|MAX_BACKOFF)", resp, re.I)),
          "regex on final response")

print(json.dumps({"expectations": exp}, indent=2))
