# claude-review-loop

A review-and-fix loop for Claude Code. It uses Claude Code's built-in
`/code-review` to find bugs, adds the things a general reviewer can't know about
your repo, fixes the clear findings, reviews again, and stops when a rule in code
says it's done.

**Why it exists.** In a head-to-head on a real branch, the built-in `/code-review`
found more bugs than this project's own first version. So this project stopped
competing with it. `/code-review` is the bug finder; this repo is everything around
it:

- **The loop.** Fix → run tests → re-review, because fixes create new bugs. It stops on
  harness rules (nothing new, same bug back twice, round or time limit), not on the
  model saying "looks good".
- **The PR workflow.** Inline comments, one sticky summary with a verdict, replies and
  resolves bot threads, never touches a thread a human has joined.
- **What only your repo knows.** Whether new tests really guard what they claim, this
  repo's past incidents, the PR's spec, and nits you've already dismissed.

## Install

```bash
git clone https://github.com/BishalSunuwar202/claude-review-loop.git
cd claude-review-loop
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
| `/review-swarm` | One review pass only, no fixes |
| `/review-triage` | Triage existing findings and PR bot threads once |

`/review-loop` flags: `--push`, `--max-rounds N` (default 3), `--budget M` minutes
(default 45), `--reset`.
**Which review runs is decided by the files the PR touches.** `gate.sh` checks the diff
against a list of risky paths (auth, payments, billing, migrations, webhooks, queues,
deploy). Touch one, or change over 400 lines, and you get the full pass: `/code-review`
plus correctness, test and security reviewers. Otherwise it's a light pass: plain
`/code-review`, at about the same cost. Add your own risky paths, one regex per line, to
`.review-loop/deny-list` (e.g. `^src/checkout/`). Force either with `--full` or `--light`.

`/review-swarm` flags: `--finder router` (skip `/code-review`, use the built-in
router + coverage split instead), `--lenses spec,incident,-test` (force
specialists on or off).

On a PR you didn't author, the loop runs review-only: comments, no fixes, no pushes.

## How a round works

```
 gate.sh ── size, risky paths, docs-only? → light or full pass          incidents.sh ── past fix commits
    │                                                   │
    ▼                                                   ▼
 /code-review high  ──────────────►  bug findings (normalised: file line, id, severity)
    │  (fallback: review-router + parallel correctness reviewers, every file read closely)
    ▼
 specialists, chosen by facts not by a model's grade (parallel):
   correctness        any code change           second close read: data, payments, edge cases
   test-reviewer      tests or code changed     does the test really fail if the bug returns? missing tests?
   security-auditor   auth/payment paths?       injection, IDOR, SSRF, secrets
   opt-in (--lenses): spec, incident, xp, craft
    ▼
 finding-verifier ── reproduce HIGH/CRITICAL with a throwaway test → confirmed / refuted
    ▼
 dedupe + verdict → PR comments + sticky summary, or local report
    ▼
 review-triage ── fix + test + commit │ nit → remember │ unclear → ask │ human thread → hands off
    ▼
 loopstate.py decide ── converged │ max_rounds │ budget │ stuck │ continue
```

## Benchmark

`bench/` has 8 small repos, each with one realistic planted bug on a `feat` branch:
SQL injection, IDOR, off-by-one, missing await, a guard test that doesn't guard,
a check-then-act race, a repeat of a past incident, and a missed spec requirement.

```bash
bench/run.sh code-review 3     # Claude Code's /code-review high, 3 runs per case
bench/run.sh swarm 3           # /code-review + specialists
bench/run.sh swarm-router 3    # this repo's router instead of /code-review
python3 bench/score.py         # recall, time, tokens, cost, and which bugs only a specialist caught
```

Each run is a real headless Claude Code session (roughly 50–150k tokens), so a full
3×8×3 run is not cheap. Runs vary, which is why each case runs three times.

**Results:** see [bench/RESULTS.md](bench/RESULTS.md).

### Head-to-head on a real PR

One real feature branch (a booking and payment flow), same commit, fresh session each,
every finding checked against the code:

| | `/code-review high` | `/review-swarm` |
|---|---|---|
| Real findings | 8 | 20 |
| False positives | 1 of 10 | 4 of 26 |
| Real issues the other missed | 0 | 12, including a paid customer told "booking received" with nothing saved |
| Time | ~4 min | ~15 min |
| Cost | $1.35 | $5.26 (3.9×) |

Almost all the extra real findings came from the correctness reviewer, and the test
reviewer added the missing tests. The spec and incident checkers added nothing real,
so they are now opt-in. `/code-review` also varies run to run: the swarm's own
`/code-review` pass missed two issues the standalone run found, and the specialists
caught both anyway.

**When to use which:** a quick check → `/code-review`. A PR that touches money,
data, or auth, or one you want fixed and re-checked → `/review-loop`.

### The comparison that started this

An earlier branch, before the redesign:

| | `/code-review high` | first `/review-swarm` |
|---|---|---|
| Time | ~3 min | ~2 min (router + 1 specialist) |
| Tokens | ~100k | ~85k |
| Findings | 9 | 4 (1 medium, 3 low) |

Both found the same 3 core issues. `/code-review` also caught two real gaps in a new
test that the swarm missed: the router only sent the migration to a specialist, so the
test file was skimmed. That miss is why `/code-review` is now the finder, why every
changed file must get a close read, and why `test-reviewer` exists.

## Files

```
skills/review-loop/SKILL.md       outer loop: rounds, stop conditions, human questions
skills/review-swarm/SKILL.md      one review pass
skills/review-swarm/scripts/
  gate.sh                         deterministic risk gate
  incidents.sh                    builds .review-loop/incidents.md from git history
  loopstate.py                    loop state + stop conditions (the harness)
skills/review-triage/SKILL.md     classify, fix, reply, resolve, defer
agents/                           router, test/incident/spec checkers, 4 lenses, verifier
bench/                            planted-bug cases, runner, scorer
```

Per-repo state lives in `.review-loop/` (added to `.git/info/exclude` automatically):
`state.json` (findings and their status), `memory.md` (conventions and dismissed nits),
`incidents.md` (past bugs), `runs/rN/` (full reviewer outputs), and an optional
`deny-list` of extra risky path patterns.

## Safety defaults

Fixes are committed locally and pushed only with `--push`. The loop never force-pushes,
merges, approves, or relabels. Threads a human has replied in are never touched. If a fix
turns tests red, it's reverted and the finding is deferred.

## Credits

The design follows Paul D'Ambra's published review skills at PostHog. These files are an
independent rewrite for Claude Code, not a copy. License: MIT.

Thanks to @IamNitu for collaborating on this project.
