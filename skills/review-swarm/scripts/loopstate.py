#!/usr/bin/env python3
"""Harness-side state and stop conditions for the review loop.

The model decides what a finding means; this script decides when the loop
stops. Keeping stop conditions here (not in a prompt) is what makes them
reliable: iteration cap, wall-clock budget, "no new actionable findings",
and stuck detection (the same finding coming back after we said we fixed it).

State lives in .review-loop/ at the repo root:
  state.json   rounds, findings by fingerprint, dispositions, deferred threads
  memory.md    durable project review memory (dismissed patterns, conventions)
  runs/        full reviewer outputs, offloaded out of the model's context
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

ACTIONABLE = {"CRITICAL", "HIGH"}
SEVERITIES = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "NIT"]
FIELDS = ["id", "file", "line", "severity", "confidence", "reviewer", "fix", "body"]


def repo_root():
    return subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()


def state_dir():
    return os.path.join(repo_root(), ".review-loop")


def state_path():
    return os.path.join(state_dir(), "state.json")


def load():
    path = state_path()
    if not os.path.exists(path):
        sys.exit("no loop state; run: loopstate.py init --base <ref>")
    with open(path) as f:
        return json.load(f)


def save(state):
    with open(state_path(), "w") as f:
        json.dump(state, f, indent=2)


def out(obj):
    print(json.dumps(obj, indent=2))


def fingerprint(finding):
    # Line numbers drift between rounds, so they are not part of identity.
    slug = re.sub(r"[^a-z0-9]+", "-", finding["id"].lower()).strip("-")
    return f"{finding['file']}::{slug}"


def parse_findings(text):
    """Parse STRUCTURED_FINDINGS lines. `body` is last so it may contain '|'."""
    findings = []
    in_block = False
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("STRUCTURED_FINDINGS"):
            in_block = True
            continue
        if line.startswith("OVERALL_SUMMARY") or line.startswith("DELEGATION_PLAN"):
            in_block = False
            continue
        if not in_block or not line.startswith("- "):
            continue
        parts = line[2:].split(" | ")
        finding = {}
        for i, part in enumerate(parts):
            key, _, value = part.partition(":")
            key = key.strip()
            if key == "body":
                finding["body"] = " | ".join([value.strip()] + parts[i + 1:])
                break
            finding[key] = value.strip()
        if not all(k in finding for k in ("id", "file", "severity")):
            continue
        finding["severity"] = finding["severity"].upper()
        if finding["severity"] not in SEVERITIES:
            continue
        findings.append(finding)
    return findings


def cmd_init(args):
    os.makedirs(os.path.join(state_dir(), "runs"), exist_ok=True)
    # Keep loop state out of commits without touching the tracked .gitignore.
    exclude = os.path.join(repo_root(), ".git", "info", "exclude")
    if os.path.exists(os.path.dirname(exclude)):
        existing = open(exclude).read() if os.path.exists(exclude) else ""
        if ".review-loop/" not in existing:
            with open(exclude, "a") as f:
                f.write("\n.review-loop/\n")
    memory = os.path.join(state_dir(), "memory.md")
    if not os.path.exists(memory):
        with open(memory, "w") as f:
            f.write("# Review memory\n\n"
                    "Durable decisions for this repo. Reviewers read this before every pass;\n"
                    "triage appends to it. Do not re-raise anything listed under Dismissed.\n\n"
                    "## Conventions\n\n## Dismissed\n")
    if os.path.exists(state_path()) and not args.reset:
        out({"status": "resumed", **summary(load())})
        return
    state = {
        "base": args.base,
        "pr": args.pr,
        "max_rounds": args.max_rounds,
        "budget_minutes": args.budget_minutes,
        "started_at": time.time(),
        "round": 0,
        "rounds": [],
        "findings": {},
        "deferred_threads": [],
        "review_marker_sha": None,
    }
    save(state)
    out({"status": "initialised", **summary(state)})


def summary(state):
    return {
        "round": state["round"],
        "max_rounds": state["max_rounds"],
        "elapsed_minutes": round((time.time() - state["started_at"]) / 60, 1),
        "budget_minutes": state["budget_minutes"],
        "review_marker_sha": state["review_marker_sha"],
        "open_deferred": [fp for fp, f in state["findings"].items() if f["status"] == "deferred"],
    }


def cmd_start_round(args):
    state = load()
    state["round"] += 1
    state["rounds"].append({"round": state["round"], "head_in": args.head,
                            "started_at": time.time(), "new_actionable": None})
    save(state)
    out(summary(state))


def cmd_record(args):
    """Ingest one round's merged findings and classify them against history."""
    state = load()
    text = open(args.findings).read() if args.findings != "-" else sys.stdin.read()
    findings = parse_findings(text)
    current = state["round"]
    new_actionable, reopened, suppressed, recorded = [], [], [], []

    for f in findings:
        fp = fingerprint(f)
        prior = state["findings"].get(fp)
        if prior and prior["status"] in ("dismissed", "nit"):
            suppressed.append(fp)
            prior["seen_rounds"].append(current)
            continue
        if prior and prior["status"] == "fixed":
            # We claimed a fix and a fresh review still sees it: stuck signal.
            prior["reopen_count"] = prior.get("reopen_count", 0) + 1
            prior["status"] = "open"
            prior["seen_rounds"].append(current)
            prior["latest"] = f
            reopened.append(fp)
            continue
        if prior:
            prior["seen_rounds"].append(current)
            prior["latest"] = f
            continue
        state["findings"][fp] = {"status": "open", "first_round": current,
                                 "seen_rounds": [current], "reopen_count": 0,
                                 "latest": f, "notes": []}
        recorded.append(fp)
        if f["severity"] in ACTIONABLE:
            new_actionable.append(fp)

    if state["rounds"]:
        state["rounds"][-1]["new_actionable"] = len(new_actionable)
        state["rounds"][-1]["reopened"] = len(reopened)
    if args.head:
        state["review_marker_sha"] = args.head
    save(state)
    out({"parsed": len(findings), "new": recorded, "new_actionable": new_actionable,
         "reopened_after_fix": reopened, "suppressed_by_memory": suppressed})


def cmd_disposition(args):
    state = load()
    if args.fingerprint not in state["findings"]:
        sys.exit(f"unknown fingerprint: {args.fingerprint}")
    f = state["findings"][args.fingerprint]
    f["status"] = args.status
    note = {"round": state["round"], "status": args.status, "note": args.note}
    if args.commit:
        note["commit"] = args.commit
    f["notes"].append(note)
    save(state)
    out({args.fingerprint: f["status"]})


def cmd_open(args):
    state = load()
    rows = [{"fingerprint": fp, "severity": f["latest"]["severity"],
             "reviewer": f["latest"].get("reviewer"), "line": f["latest"].get("line"),
             "fix": f["latest"].get("fix"), "body": f["latest"].get("body"),
             "reopen_count": f["reopen_count"]}
            for fp, f in state["findings"].items() if f["status"] == "open"]
    rows.sort(key=lambda r: SEVERITIES.index(r["severity"]))
    out(rows)


def cmd_decide(args):
    """Stop conditions, checked in priority order."""
    state = load()
    s = summary(state)
    stuck = [fp for fp, f in state["findings"].items()
             if f["status"] == "open" and f.get("reopen_count", 0) >= 2]
    last = state["rounds"][-1] if state["rounds"] else {}

    def stop(reason, kind):
        out({"continue": False, "stop_kind": kind, "reason": reason, "stuck": stuck, **s})

    if stuck:
        return stop(f"{len(stuck)} finding(s) came back after two fix attempts", "stuck")
    if s["elapsed_minutes"] >= state["budget_minutes"]:
        return stop("wall-clock budget spent", "budget")
    if last and last.get("new_actionable") == 0 and last.get("reopened", 0) == 0:
        return stop("round produced no new actionable findings", "converged")
    if state["round"] >= state["max_rounds"]:
        return stop("max rounds reached", "max_rounds")
    out({"continue": True, "reason": "actionable work remains", "stuck": [], **s})


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    i = sub.add_parser("init")
    i.add_argument("--base", required=True)
    i.add_argument("--pr", type=int)
    i.add_argument("--max-rounds", type=int, default=3)
    i.add_argument("--budget-minutes", type=float, default=45)
    i.add_argument("--reset", action="store_true")
    i.set_defaults(fn=cmd_init)

    r = sub.add_parser("start-round")
    r.add_argument("--head", required=True)
    r.set_defaults(fn=cmd_start_round)

    rec = sub.add_parser("record")
    rec.add_argument("--findings", required=True, help="file with STRUCTURED_FINDINGS, or -")
    rec.add_argument("--head")
    rec.set_defaults(fn=cmd_record)

    d = sub.add_parser("disposition")
    d.add_argument("fingerprint")
    d.add_argument("status", choices=["fixed", "nit", "deferred", "dismissed", "open"])
    d.add_argument("--note", default="")
    d.add_argument("--commit")
    d.set_defaults(fn=cmd_disposition)

    sub.add_parser("open").set_defaults(fn=cmd_open)
    sub.add_parser("decide").set_defaults(fn=cmd_decide)
    sub.add_parser("status").set_defaults(fn=lambda a: out(summary(load())))

    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
