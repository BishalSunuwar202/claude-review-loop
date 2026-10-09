---
name: review-swarm
description: >
  One multi-agent review pass over the current branch or a PR. Claude Code's
  built-in /code-review is the bug finder; a correctness reviewer and a test
  reviewer add a second close read and check whether tests really guard what they
  claim, a security auditor joins on risky paths, and spec, incident, xp and craft
  lenses are opt-in. Findings with HIGH/CRITICAL severity are verified by a
  reproducer, deduped, given a verdict, and posted to the PR or reported locally.
  Use for "review-swarm", "swarm review", or a multi-perspective review. The
  review-loop skill calls this every round.
  Arguments: [PR number|URL|branch] [--finder code-review|router] [--lenses list]
---
# Review Swarm — one review pass

The bug finder is `/code-review`, because it is the stronger single-pass reviewer
(see the benchmark in the repo README). This skill does not compete with it. It
adds what a general reviewer cannot have — **this repo's history, this PR's spec,
and a hard look at the tests** — then normalises everything into one format the
loop can track across rounds.

`$SCRIPTS` below means `~/.claude/skills/review-swarm/scripts`.

Narrate one line before every step: `[swarm] step N — <what and why>`.

## Step 1 — Gather (harness, no model judgement)

Target: a PR number/URL or branch from `$ARGUMENTS`; else the current branch's
PR (`gh pr view --json number,url,baseRefName,headRefOid,body`); else local mode
against the default branch. If called from `review-loop`, use what it passes.

```bash
git fetch -q origin <base> 2>/dev/null || true
git diff <base>...HEAD --name-only
git diff <base>...HEAD > .review-loop/runs/r<round>/diff.patch
git log <base>...HEAD --oneline
git rev-parse HEAD
$SCRIPTS/gate.sh <base>
$SCRIPTS/incidents.sh            # refreshes .review-loop/incidents.md, prints how many entries
```

Standalone use: run `python3 $SCRIPTS/loopstate.py init --base <base> [--pr N]`
first if `.review-loop/state.json` is missing, and use round `0` (`r0`).

If the gate reports `docs_only: true`, report "docs-only change, no code review
needed", verdict APPROVE, and stop.

Collect the **spec**: the PR body, any issue it links (`gh issue view <n> --json
title,body`), and any spec/plan file the PR body or commit messages name. Save it
to `.review-loop/runs/r<round>/spec.md`. Empty is fine.

## Step 2 — Bug finding

**Default finder: `/code-review`.** Invoke `Skill("code-review", args="high
<target>")` where `<target>` is the PR number in PR mode, else the branch name.
Always pass the level explicitly (it otherwise reuses the last one typed). **Never
pass `--comment` or `--fix`** — this skill owns posting and review-triage owns
fixing.

Save its full output to `.review-loop/runs/r<round>/code-review.md`, then
**normalise** each finding into the STRUCTURED_FINDINGS format (below):

- `file` / `line`: /code-review may cite positions in the diff rather than file
  lines. Resolve every finding to a real file line by opening the file and
  locating the code it quotes or describes. Use `general` only if it truly has no
  location.
- `id`: a short kebab-case slug naming the defect, stable across rounds.
- `severity`: grade it with the rubric in *Severity* below — /code-review gives
  no severities, and the loop's stop rules depend on them.
- `reviewer: code-review`; `fix`: its suggested fix, or `none`.

**Fallback finder: the router** — used when `--finder router` is passed, when
the `code-review` skill is unavailable, or when its output yields no parseable
findings on a non-trivial diff (say so in the report). Dispatch `review-router`
(model `sonnet`) with the diff path, file list, commit log, gate JSON, and
`memory.md`. **Coverage rule:** every changed non-doc file must be read closely
by some agent. If the diff exceeds ~400 changed lines, do not let one router skim
it — split the files into groups of ~300 lines and dispatch one
`correctness-reviewer` (model `sonnet`) per group in parallel, each told it is
the sole reviewer for its files.

Save every agent's full output under `.review-loop/runs/r<round>/`; keep only the
findings blocks in context.

## Step 3 — Specialists (what the finder can't know)

Decide which run **from the facts, not from a model's grade**. Dispatch all that
apply in parallel, in one message. Each is told it is the sole reviewer for its
scope; none is told about the others. Pass each the review memory.

| Agent | Runs when | Model | Scope |
|---|---|---|---|
| `correctness-reviewer` | any changed non-doc, non-test code | opus if gate `deny_list_hits` or diff > 400 lines, else sonnet | changed code; split into ~300-line groups (one agent each) above 600 lines |
| `test-reviewer` | any changed test file, or changed code with no changed test | sonnet | changed tests + the code they claim to guard, or the changed code's missing tests |
| `security-auditor` | gate `deny_list_hits` include auth/session/secret/token/permission/payment/billing/webhook paths | opus | those files |
| `spec-checker` | only if named in `--lenses` (`spec`) | sonnet | full diff + spec.md |
| `incident-checker` | only if named in `--lenses` (`incident`) | sonnet | full diff + incidents.md |
| `xp-reviewer`, `craft-reviewer` | only if named in `--lenses` | sonnet | full diff |

Why this default set: on a real PR, correctness and test reviewers found every real
issue /code-review missed; spec and incident checkers added nothing but a nit, so
they are opt-in. Keep collecting spec.md and incidents.md in Step 1 anyway — they
are cheap and the opt-in lenses need them.

`--lenses` can also force any agent on (`--lenses spec,incident,xp`) or off
(`--lenses -test`). Cap: 6 specialists per pass. If two reviewers
contradict each other on a HIGH finding, one extra `fable` pass may be scoped to
that disagreement.

## Step 4 — Verify HIGH/CRITICAL by observation

Collect every HIGH/CRITICAL finding (and any MEDIUM with `confidence: LOW` that
would block if true). If there are any and the project has a runnable test setup,
dispatch one `finding-verifier` with the findings, a fingerprint for each
(`<file>::<id>`), and scratch dir `.review-loop/runs/r<round>/verify/`.

- **CONFIRMED** → keep; append `(verified: <evidence>)`.
- **REFUTED** → downgrade to LOW; append `(refuted: <evidence>)`.
- **UNVERIFIED** → keep; append `(unverified: <reason>)`.

Then `git status --porcelain`; restore anything the verifier left in tracked paths.

## Step 5 — Synthesize

Merge all findings into one STRUCTURED_FINDINGS block:

- **Dedupe:** same file and line within 5, or clearly the same concern → one
  finding, highest severity, clearest `fix`, `reviewer: convergent(<a>+<b>)`,
  confidence HIGH.
- Drop anything `memory.md` dismisses.
- **Pre-existing bugs.** If the defect is also present on `<base>` (check with
  `git show <base>:<file>`), keep it but append ` (pre-existing)` to `body` and cap
  severity at MEDIUM. Report it; it is not this PR's to fix.
- **Nothing mentioned is lost.** Any concern a reviewer raised only in its summary
  becomes at least a LOW finding.

Write it to `.review-loop/runs/r<round>/findings.md`. Also write
`.review-loop/runs/r<round>/unique.md`: findings whose `reviewer` is a specialist
and that /code-review did not also raise. That file is how the benchmark measures
whether each specialist earns its tokens.

**Verdict:** any CRITICAL → 🚫 BLOCKED · 2+ HIGH, or 1 HIGH + 2 MEDIUM →
⚠️ REQUEST CHANGES · 1 HIGH, or 3+ MEDIUM → 💬 APPROVE WITH NITS · else ✅ APPROVE.

## Step 6 — Report

**Local mode:** print the verdict and findings grouped by severity as
`file:line — [reviewer] body → fix`, and write the same to `.review-loop/report.md`.

**PR mode:** every posted comment starts with this header, no exceptions — triage
uses it to tell bot threads from human ones:

```markdown
> [!NOTE]
> 🤖 Automated comment by **Review Swarm** — not written by a human
```

1. Post all line-anchored findings as **one** review:
   `gh api repos/{owner}/{repo}/pulls/{n}/reviews --method POST --input <json>`,
   `event: "COMMENT"`, `commit_id: <HEAD>`, `comments: [{path, line, side: "RIGHT", body}]`.
   Body: `**[<reviewer>]** <emoji> <SEVERITY>\n\n<body>\n\n**Suggested fix:** <fix>`
   (🔴 CRITICAL 🟠 HIGH 🟡 MEDIUM 🟢 LOW ⚪ NIT). Lines outside the diff go in the summary.
2. Upsert **one** sticky summary comment marked `<!-- review-swarm-summary -->`
   (find with `gh api repos/{o}/{r}/issues/{n}/comments --paginate --jq
   '[.[]|select(.body|contains("<!-- review-swarm-summary -->"))][0].id'`; PATCH if
   found, else create): verdict `(round N @ <short sha>)`, key findings,
   convergence, which reviewers ran and why. Earlier rounds fold into `<details>`.

Never post absolute production numbers on a public repo; use ratios.

## Findings format

```
STRUCTURED_FINDINGS:
- id: <slug> | file: <path> | line: <n|general> | severity: <CRITICAL|HIGH|MEDIUM|LOW|NIT> | confidence: <HIGH|MEDIUM|LOW> | reviewer: <tag> | fix: <change or "none"> | body: <what, the triggering input/state, the consequence>

OVERALL_SUMMARY:
<one paragraph>
```

### Severity

CRITICAL = data loss, security breach, or outage on merge. HIGH = a real bug a
user will hit, or a test that claims protection it does not give. MEDIUM = likely
bug or risky gap. LOW = minor, including a missing test for behaviour that works.
NIT = taste.

## Return value (when called from review-loop)

End with the merged STRUCTURED_FINDINGS block, the verdict, the finder used, and
the path to `findings.md`. Nothing else.

## Degradation

- `code-review` skill missing or unusable → router fallback (Step 2), said in the report.
- `gh` missing or unauthenticated → local mode.
- A specialist fails → add a MEDIUM `general` finding "<agent> did not run".
- No test runner → skip Step 4; mark HIGH/CRITICAL `(unverified: no test runner)`.
