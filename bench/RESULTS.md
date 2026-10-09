# Results

## Real PR, head-to-head

One real feature branch in a private repo (a booking and payment flow). Same commit,
fresh Claude Code session for each reviewer, then a third session opened the code for
every finding and marked it real or false positive. One run each.

| | `/code-review high` | `/review-swarm` |
|---|---|---|
| Findings | 10 | 26 |
| Real | 8 | 20 |
| False positives | 1 | 4 (plus 1 duplicate) |
| Real issues only this reviewer found | 0 | 12 |
| Time | 4 min 03 s | ~15 min |
| Opus output tokens | 21.7k | 79.3k |
| Sonnet output tokens | – | 32.9k |
| Subagents | 0 | 4 |
| Cost | $1.35 | $5.26 (3.9×) |

What the extra real findings were:
- 2 MEDIUM bugs in payment confirmation, one of which lets a customer who already paid
  be told the booking was received while nothing is recorded. Both also exist on the
  base branch.
- 2 real issues the swarm's own `/code-review` pass missed but the standalone run found;
  the specialists caught them.
- Missing tests, smaller LOW issues, and a few NITs.

Which specialist earned its cost: correctness reviewer (most of the extra real
findings), test reviewer (missing tests). Spec checker and incident checker: nothing
real beyond one NIT. Changes made from this run:
- spec and incident checkers are opt-in (`--lenses spec,incident`)
- correctness and test reviewers run on every code change
- missing-test findings are capped at LOW
- bugs that already exist on the base branch are tagged `pre-existing` and not fixed
  inside the PR

Caveats: one PR, one run each. Runs vary.

## Planted-bug benchmark

Smoke test only so far: case `weak-guard-test`, one run each.

| reviewer | recall | time | tokens | cost |
|---|---|---|---|---|
| code-review | 2/2 | 0.6 min | 219k | $0.33 |
| swarm | 2/2 | 0.9 min | 995k | $1.20 |

On a small, single-bug repo the swarm found nothing extra. The full 8-case run is not
done yet; run it with `bench/run.sh code-review 3 && bench/run.sh swarm 3 && python3 bench/score.py`.
