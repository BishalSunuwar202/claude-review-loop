#!/usr/bin/env python3
"""Score benchmark results: which planted bugs each reviewer found, plus time and cost.

A planted bug counts as found in a run when some chunk of the reviewer's output
(a paragraph or list item) names the bug's file AND either cites a line in the
bug's range or uses one of its keywords. This is deliberately forgiving about
wording and strict about location.
"""
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).parent
RESULTS = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "results"
SPECIALISTS = ("test-reviewer", "incident-checker", "spec-checker", "security", "correctness", "xp", "craft")


def chunks(text):
    parts = re.split(r"\n\s*\n|\n(?=\s*(?:[-*•]|\d+[.)]|STRUCTURED|#{1,4} ))", text)
    return [p for p in parts if p.strip()]


def matches(chunk, bug):
    low = chunk.lower()
    path = bug["file"].lower()
    name = path.rsplit("/", 1)[-1]
    if path not in low and name not in low:
        return False
    lo, hi = bug["lines"]
    for m in re.finditer(re.escape(name) + r"[:#L ]+(\d+)", low):
        if lo - 2 <= int(m.group(1)) <= hi + 2:
            return True
    for m in re.finditer(r"\bline:?\s*(\d+)", low):
        if lo - 2 <= int(m.group(1)) <= hi + 2:
            return True
    return any(k in low for k in bug["keywords"])


def found_by(text, bug):
    return any(matches(c, bug) for c in chunks(text))


def load_run(run_dir):
    raw = run_dir / "raw.json"
    meta = {"seconds": None, "cost": None, "tokens": None, "error": None}
    text = ""
    try:
        data = json.loads(raw.read_text())
        text = data.get("result") or ""
        meta["seconds"] = (data.get("duration_ms") or 0) / 1000
        meta["cost"] = data.get("total_cost_usd")
        u = data.get("usage") or {}
        meta["tokens"] = sum(u.get(k) or 0 for k in ("input_tokens", "output_tokens",
                             "cache_read_input_tokens", "cache_creation_input_tokens")) or None
        if data.get("is_error"):
            meta["error"] = data.get("subtype") or "error"
    except Exception as e:
        meta["error"] = f"unreadable raw.json ({e.__class__.__name__})"
    findings = run_dir / "findings.md"
    if findings.exists():
        text += "\n\n" + findings.read_text()
    unique = (run_dir / "unique.md").read_text() if (run_dir / "unique.md").exists() else ""
    return text, unique, meta


def main():
    if not RESULTS.exists():
        sys.exit(f"no results at {RESULTS}; run bench/run.sh first")
    cases = {c.name: json.loads((c / "expected.json").read_text())
             for c in sorted((HERE / "cases").iterdir()) if c.is_dir()}
    reviewers = sorted(p.name for p in RESULTS.iterdir() if p.is_dir())

    summary, per_case, credit = {}, {}, {}
    for r in reviewers:
        found = total = 0
        secs, costs, toks, errors = [], [], [], 0
        for case, bugs in cases.items():
            runs = sorted((RESULTS / r / case).glob("run*")) if (RESULTS / r / case).exists() else []
            hits = {b["id"]: 0 for b in bugs}
            for run in runs:
                text, unique, meta = load_run(run)
                errors += bool(meta["error"])
                for b in bugs:
                    total += 1
                    if found_by(text, b):
                        found += 1
                        hits[b["id"]] += 1
                        for chunk in chunks(unique):
                            if matches(chunk, b):
                                tag = next((s for s in SPECIALISTS if s in chunk.lower()), "specialist")
                                credit.setdefault(r, {}).setdefault(tag, set()).add(f"{case}/{b['id']}")
                if meta["seconds"]: secs.append(meta["seconds"])
                if meta["cost"] is not None: costs.append(meta["cost"])
                if meta["tokens"]: toks.append(meta["tokens"])
            per_case.setdefault(case, {})[r] = ", ".join(f"{k} {v}/{len(runs)}" for k, v in hits.items()) if runs else "-"
        avg = lambda xs: sum(xs) / len(xs) if xs else None
        summary[r] = {"recall": f"{found}/{total}" + (f" ({100*found/total:.0f}%)" if total else ""),
                      "avg_time": f"{avg(secs)/60:.1f} min" if secs else "-",
                      "avg_cost": f"${avg(costs):.2f}" if costs else "-",
                      "avg_tokens": f"{avg(toks)/1000:.0f}k" if toks else "-",
                      "errored_runs": errors}

    cols = ["reviewer", "recall", "avg_time", "avg_tokens", "avg_cost", "errored_runs"]
    print("| " + " | ".join(cols) + " |\n|" + "---|" * len(cols))
    for r, s in summary.items():
        print("| " + " | ".join([r] + [str(s[c]) for c in cols[1:]]) + " |")
    print("\n| case | " + " | ".join(reviewers) + " |\n|---|" + "---|" * len(reviewers))
    for case, row in per_case.items():
        print(f"| {case} | " + " | ".join(row.get(r, "-") for r in reviewers) + " |")
    if credit:
        print("\nPlanted bugs found only by a specialist (not by the /code-review pass):")
        for r, tags in credit.items():
            for tag, bugs in sorted(tags.items()):
                print(f"- {r} / {tag}: {', '.join(sorted(bugs))}")


if __name__ == "__main__":
    main()
