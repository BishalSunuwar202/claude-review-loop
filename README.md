# review-loop

A multi-agent code review loop for Claude Code. It reviews a branch or PR with
several specialist agents, fixes the clear findings, reviews again, and stops
when a harness check says it's done.

Based on:
- **Paul D'Ambra's qa-swarm / review-triage / pr-shepherd** ([dotfiles](https://github.com/pauldambra/dotfiles/tree/main/ai/skills)),
  summarised in [PostHog's code review tips](https://posthog.com/newsletter/code-review-tips):
  cheap router first, specialist lenses on demand, triage into
  actionable / nit / ambiguous, iterate up to 3 times.
- **PostHog's StampHog**: deterministic gates (size, deny-listed paths) run before any model.
  "Watch it run, don't trust the explanation" becomes the `finding-verifier` agent.
- **[The Agent Loop Decoded](https://blogs.oracle.com/developers/the-agent-loop-decoded-three-levels-every-agent-engineer-must-know)** (Oracle):
  explicit stop conditions in the harness, not the model; stuck/oscillation
  detection; memory read before and written after each run; tool-output
  offloading; human-in-the-loop as a deliberate pause with a precise question.
- **[Deca-hundy](https://pauldambra.dev/2026/02/deca-hundy.html)**: small steps, iterate deliberately.

## Install

```bash
./install.sh   # symlinks skills/* → ~/.claude/skills, agents/* → ~/.claude/agents
```

Start a new Claude Code session afterwards.

## Use

| Command | What it does |
|---|---|
| `/review-loop` | Full loop on the current branch: review → fix → re-review until done |
| `/review-loop 123 --push` | Same, on PR #123, and push fix commits |
| `/review-loop https://github.com/org/repo/pull/7` | Any repo's PR (reuses or clones into ~/coding-files) |
| `/review-loop feature-x` | A branch with no PR yet: local report + local fix commits |
| `/review-swarm` | One review pass only, with no fixes |
| `/review-triage` | Triage existing findings and PR bot threads once |

Flags for `/review-loop`: `--push`, `--max-rounds N` (default 3),
`--budget M` minutes (default 45), `--reset` (discard loop state).

## How a round works

```
           ┌──────────────── gate.sh (deterministic) ────────────────┐
           │ lines, files, deny-list paths → mandatory_delegation?   │
           └───────────────────────────┬─────────────────────────────┘
                                       ▼
memory.md ─────────────▶  review-router (sonnet): full first pass
                          + danger grade + DELEGATION_PLAN
                                       │  only if warranted (parallel)
             ┌───────────────┬─────────┴─────┬───────────────┐
             ▼               ▼               ▼               ▼
   correctness-reviewer  security-auditor  xp-reviewer   craft-reviewer
   (db/perf/concurrency) (injection/IDOR)  (simple design) (observability/rollout)
             └───────────────┴───────┬───────┴───────────────┘
                                     ▼
                finding-verifier: reproduce HIGH/CRITICAL → CONFIRMED / REFUTED
                                     ▼
                dedupe + convergence + verdict → PR comments or local report
                                     ▼
                review-triage: actionable → fix + test + commit
                               nit → close (+ remember)
                               ambiguous → autonomy ladder → promote or defer
                               human thread → never touched
                                     ▼
                loopstate.py decide → converged | max_rounds | budget | stuck | continue
```

## Files

```
skills/review-loop/SKILL.md      outer loop: rounds, stop conditions, human questions
skills/review-swarm/SKILL.md     one review pass (gate → router → lenses → verify → post)
skills/review-swarm/scripts/
  gate.sh                        deterministic risk gate
  loopstate.py                   loop state + stop conditions (the harness)
skills/review-triage/SKILL.md    classify, fix, reply, resolve, defer
agents/*.md                      router, 4 specialist lenses, verifier
```

Per-repo state goes in `.review-loop/` (added to `.git/info/exclude` automatically):

- `state.json`: rounds and every finding's fingerprint and status
- `memory.md`: durable decisions such as conventions and dismissed patterns. Reviewers read it first.
  Commit a copy if you want your team to share it.
- `runs/rN/`: full reviewer outputs, kept out of the model's context
- `deny-list`: optional extra high-risk path regexes, one per line

## Safety defaults

Fixes are committed locally and pushed only with `--push`. The loop never
force-pushes, merges, approves, or relabels. Threads a human has replied in are
never touched. If a fix turns tests red, it's reverted and the finding is deferred.
