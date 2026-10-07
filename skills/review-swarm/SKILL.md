---
name: review-swarm
description: >
  One multi-agent review pass over the current branch or a PR: deterministic risk
  gate, a cheap router reviewer, conditional delegation to specialist lenses
  (correctness, security, xp, craft), observable verification of HIGH/CRITICAL
  findings, dedupe, and a verdict. Posts inline PR comments when a PR exists,
  otherwise reports locally. Use for "review-swarm", "swarm review", or a
  multi-perspective review. The review-loop skill calls this every round.
---
# Review Swarm — one review pass

Cheap first, strong only where warranted, verified by observation. Delegated
reviewers are independent: none is told about the others or the router.

`$SCRIPTS` below means `~/.claude/skills/review-swarm/scripts`.

Narrate one line before every step: `[swarm] step N — <what and why>`. A silent
gap of more than 30 seconds is the failure mode.

## Step 1 — Gather (harness, no model judgement)

Target: `$ARGUMENTS` if it is a PR number/URL; else `gh pr view --json
number,url,baseRefName,headRefOid` for the current branch; else local mode
against `main` (or `master`). If called from `review-loop`, use the base, PR, and
round it passes you and skip detection.

```bash
git fetch -q origin <base> 2>/dev/null || true
git diff <base>...HEAD --name-only
git diff <base>...HEAD > .review-loop/runs/r<round>/diff.patch
git log <base>...HEAD --oneline
git rev-parse HEAD
$SCRIPTS/gate.sh <base>
```

Run `python3 $SCRIPTS/loopstate.py init --base <base> [--pr N]` first if
`.review-loop/state.json` does not exist (standalone use), and use round
`0` → `r0` for the run directory.

If the gate reports `docs_only: true`, skip the router: report "docs-only
change, no code review needed" and stop with verdict APPROVE.

## Step 2 — Router pass

Dispatch **one** `review-router` agent (model `sonnet`). Give it:

- path to `diff.patch` (it reads the file — don't paste a large diff inline);
  paste it inline only if under ~300 lines
- changed-file list and commit log
- the gate JSON verbatim
- the full contents of `.review-loop/memory.md`

Save its full response to `.review-loop/runs/r<round>/router.md`. Keep only its
STRUCTURED_FINDINGS and DELEGATION_PLAN in your working context.

**Harness check:** if the gate said `mandatory_delegation: true` and the plan's
`delegations` is empty, do not accept it. Add one delegation yourself:
`security` lens on `opus` if any `deny_list_hits` look auth/secret/payment
related, otherwise `correctness` on `opus`, scoped to the deny-list hits (or the
largest changed files).

## Step 3 — Delegation pass (only if the plan has delegations)

Map lens → agent: `correctness` → `correctness-reviewer`, `security` →
`security-auditor`, `xp` → `xp-reviewer`, `craft` → `craft-reviewer`.

Dispatch all delegations **in parallel in a single message**, each with the
`model` the plan chose. Give each:

- "You are the sole reviewer for this scope." — never mention other reviewers
- the scoped diff: `git diff <base>...HEAD -- <scope paths>` (or the full patch
  path for `full`)
- the review memory contents

Save each full response to `.review-loop/runs/r<round>/<lens>.md`. Cap: 6
delegations per pass. If two lenses contradict each other on a HIGH finding, you
may run one more delegation on `fable` scoped to that disagreement.

## Step 4 — Verify HIGH/CRITICAL by observation

Do not trust a reviewer's explanation of a bug; watch it happen. Collect every
HIGH/CRITICAL finding (and any MEDIUM with `confidence: LOW` that would block if
true). If there are any and the project has a runnable test setup, dispatch one
`finding-verifier` agent with the findings, a fingerprint for each
(`<file>::<id>`), and the scratch directory `.review-loop/runs/r<round>/verify/`.

Apply its verdicts:
- **CONFIRMED** → keep; append `(verified: <evidence>)` to the body.
- **REFUTED** → downgrade to LOW and append `(refuted: <evidence>)`. Do not post
  it as blocking.
- **UNVERIFIED** → keep severity; append `(unverified: <reason>)`.

Afterwards run `git status --porcelain`. If the verifier left anything behind in
tracked paths, restore it (`git checkout -- <path>`, delete `__review_verify_*`).

## Step 5 — Synthesize

Merge router + delegate findings into one STRUCTURED_FINDINGS block:

- **Dedupe:** same file and line within 5, or clearly the same concern → one
  finding. Keep the highest severity and the clearest `fix`, and set
  `reviewer: convergent(<a>+<b>)`. Convergent findings are the highest-confidence
  signal; raise confidence to HIGH.
- Drop anything the review memory dismisses.

Write the merged block to `.review-loop/runs/r<round>/findings.md`.

**Verdict:**
- any CRITICAL → 🚫 BLOCKED
- 2+ HIGH, or 1 HIGH + 2 MEDIUM → ⚠️ REQUEST CHANGES
- 1 HIGH, or 3+ MEDIUM → 💬 APPROVE WITH NITS
- otherwise → ✅ APPROVE

## Step 6 — Report

**Local mode:** print the verdict, then findings grouped by severity as
`file:line — [reviewer] body → fix`, and write the same to
`.review-loop/report.md`.

**PR mode:** every posted comment starts with this header, no exceptions — it is
how triage later tells bot threads from human ones:

```markdown
> [!NOTE]
> 🤖 Automated comment by **Review Swarm** — not written by a human
```

1. Post all line-anchored findings as **one** review via
   `gh api repos/{owner}/{repo}/pulls/{n}/reviews --method POST --input <json>`
   with `event: "COMMENT"`, `commit_id: <HEAD>`, and a `comments` array of
   `{path, line, side: "RIGHT", body}`. Body format:
   `**[<reviewer>]** <emoji> <SEVERITY>\n\n<body>\n\n**Suggested fix:** <fix>`
   (🔴 CRITICAL 🟠 HIGH 🟡 MEDIUM 🟢 LOW ⚪ NIT). Lines must be inside the diff;
   move any that aren't into the summary.
2. Upsert **one** sticky summary comment marked `<!-- review-swarm-summary -->`:
   find it with `gh api repos/{o}/{r}/issues/{n}/comments --paginate --jq
   '[.[]|select(.body|contains("<!-- review-swarm-summary -->"))][0].id'`, then
   PATCH it if found, else create it. It shows the current verdict
   `(round N @ <short sha>)`, key findings, convergence, and a table of which
   reviewers ran and why. Earlier rounds collapse into a `<details>` block, one
   line each.

Never post absolute production numbers (users, revenue, event counts) on a
public repo; use ratios.

## Return value (when called from review-loop)

End with the merged STRUCTURED_FINDINGS block, the verdict, and the path to
`findings.md`. Nothing else.

## Degradation

- `gh` missing or unauthenticated → local mode.
- A specialist agent fails → let the router's findings for that scope stand, and
  add a MEDIUM `general` finding: "<lens> review did not run".
- No test runner → skip Step 4 and mark HIGH/CRITICAL `(unverified: no test runner)`.
