---
name: review-loop
description: >
  Runs the full multi-agent review loop on the current branch or a PR: review
  (review-swarm) → triage and fix (review-triage) → re-review, round after round,
  until a harness stop condition fires — converged, max rounds, budget spent, or a
  finding stuck after repeated fixes. Ambiguous and human-thread items pause for
  the user with a precise question. Use for "review-loop", "review and fix my
  branch", "babysit this PR's review", or "loop until review is clean".
  Arguments: [PR number|PR URL|branch] [--push] [--max-rounds N] [--budget M] [--reset]
---
# Review Loop

The agent loop applied to code review. Each round: assemble context → review →
act on findings → check stop conditions → repeat. The model judges findings;
**the harness (`loopstate.py`) decides when to stop** — never stop or continue
on your own impression of "looks clean now".

`$SCRIPTS` means `~/.claude/skills/review-swarm/scripts`.

## Where to run it

Run in a session that did **not** just write the code. Every dispatch's result
lands back in this context, so starting on top of a long implementation
conversation multiplies the cost of every round. If you are at the tail of the
implementation session, say so and offer to continue in a fresh session.

The working tree must be clean before round 1 (`git status --porcelain` empty).
If it isn't, stop and ask the user to commit or stash — triage commits fixes, and
mixing those with uncommitted work is unrecoverable confusion.

## Setup (once)

1. Resolve the target from the first non-flag argument:
   - **Nothing** → the current branch. If it has an open PR (`gh pr view --json
     number,url,author,state,baseRefName`), use PR mode; otherwise local mode
     against the default branch (`gh repo view --json defaultBranchRef` or
     `main`/`master`). On the default branch itself, stop and ask for a branch.
   - **PR number** → `gh pr checkout <n>` in the current repo.
   - **PR URL** (`https://github.com/<owner>/<repo>/pull/<n>`) → if the current
     repo's `origin` is that repo, `gh pr checkout <n>`. Otherwise look for an
     existing clone at `~/coding-files/<repo>`; if none, ask before cloning there
     with `gh repo clone <owner>/<repo>`. Then `cd` in and `gh pr checkout <n>`.
   - **Branch name** → `git checkout <branch>` (fetch it from `origin` first if
     it isn't local), then treat it like "nothing".

   If the PR is MERGED/CLOSED, stop.
   **Not your PR?** If the PR author (`.author.login`) is not `gh api user --jq
   .login`, run review-only: review-swarm rounds with comments, no triage fixes,
   no push, no thread resolving. Tell the user why. Fixing a colleague's branch
   or resolving their threads is their call, not the bot's.
2. Parse flags: `--push` (default off: fixes are committed locally, not pushed),
   `--max-rounds` (default 3), `--budget` minutes (default 45), `--reset`.
3. ```bash
   python3 $SCRIPTS/loopstate.py init --base <base> [--pr N] --max-rounds <N> --budget-minutes <M> [--reset]
   ```
   If it says `resumed`, carry on from the recorded round — state is restartable.
4. Narrate: `[loop] setup — <PR #n | local> vs <base>, max <N> rounds, push=<bool>`

## Each round

```
H_in = git rev-parse HEAD
loopstate.py start-round --head H_in            → round r
review-swarm (round r)  — only if warranted, see below
loopstate.py record --findings runs/r<r>/findings.md --head H_in
review-triage (round r)                          → fixes, nits, deferrals
loopstate.py decide                              → continue or stop
```

**When to run review-swarm.** Round 1: always. Later rounds: only if HEAD moved
since `review_marker_sha` *and* the diff `review_marker_sha..HEAD` touches a
non-doc file. If triage fixed nothing, there is nothing new to review — call
`decide` directly (it will report converged).

**Re-review scope.** From round 2, tell review-swarm to review the whole branch
diff again but to focus on `git diff <review_marker_sha>..HEAD`: fixes are where
new bugs appear. Feed it the memory file — dismissed items must not resurface.

**Context hygiene (offloading).** Full reviewer outputs live in
`.review-loop/runs/r<N>/`. Keep only the merged findings, the triage JSON, and
the `decide` output in this conversation. Re-read a run file only when you need
one specific finding's detail.

After each round narrate:
`[loop] round <r> — verdict <V>, fixed <n>, nit <n>, promoted <n>, deferred <n>, new actionable <k>`

## Stop conditions (from `loopstate.py decide`)

| stop_kind | Meaning | What you do |
|---|---|---|
| `converged` | last round found no new actionable findings and nothing reopened | success — final report |
| `max_rounds` | hit the round cap | report remaining open items |
| `budget` | wall-clock budget spent | report; offer to continue with `--budget` |
| `stuck` | a finding came back after two fix attempts | revert nothing, stop fixing it, defer with the history of both attempts |

A model's "I think we're done" is **not** a stop condition. A terminal message
from a reviewer is not proof the goal is met — `decide` is.

Also stop immediately (no `decide` needed) if: tests on the branch were green at
round start and are red after triage and triage could not restore them; or a fix
in round r reverts a fix from round r-1 (oscillation) — compare the files and
hunks each fix touched.

## Human in the loop

Deferred items are a pause, not a failure. At the end, ask the user — with
`AskUserQuestion` when there are 1–4 items, otherwise as a numbered list — one
precise question per deferred item: the file:line, what the reviewer claims, the
options, and your recommendation. Apply their answers as a final mini-round
(triage only, then one review-swarm pass on the result, then `decide`).

Record any answer that is a durable project decision in `.review-loop/memory.md`
(`## Conventions` or `## Dismissed`) so the next loop — on this branch or any
future one — does not ask again. This file is the loop's long-term memory; keep
entries one line each and prune any that the user contradicts.

## Final report

```
[loop] done — <stop_kind> after <r> round(s), <elapsed> min
verdict: <latest verdict>
fixed: <n> (commits: <short shas>)   pushed: <yes|no — run git push>
nits closed: <n>   promoted: <n>   deferred: <n>
```

Then: each deferred item with its question; each promoted "recommend and ask"
item with its alternative; remaining open findings by severity; and in PR mode,
the link to the sticky summary comment. If fixes were not pushed, say so plainly.

## Guardrails

- Never force-push, rebase, or rewrite history. Fix commits stack on top.
- Never push without `--push`. Never touch threads a human has joined.
- Never merge, approve, or change PR labels — this loop reviews and fixes only.
- Commit messages are subject-line only (`fix(review): …`), no trailers.
- Max 6 specialist delegations per round; `opus` is the default ceiling,
  `fable` only for a reviewer disagreement on a HIGH/CRITICAL finding.
