---
name: review-triage
description: >
  Triages review findings and PR review threads into actionable, nit, or
  ambiguous; applies clear localised fixes with tests run; replies with a
  disposition before resolving bot threads; never touches threads a human has
  joined; records decisions in review memory. Use for "review-triage", "triage
  review comments", or "address bot feedback". The review-loop skill calls this
  every round.
---
# Review Triage

Every finding ends in exactly one bucket — **fixed**, **nit**, **promoted**, or
**deferred** — and the counts must reconcile. Nothing is seen-but-unhandled.

`$SCRIPTS` means `~/.claude/skills/review-swarm/scripts`. Narrate one line per
step: `[triage] <step> — <what and why>`.

## Inputs

- From `review-loop`: round number, base, PR number (or none), `--push` flag.
  Findings come from `python3 $SCRIPTS/loopstate.py open`.
- Standalone: run `review-swarm` first if `.review-loop/runs/` has no findings
  for the current HEAD, then `loopstate.py record --findings
  .review-loop/runs/r0/findings.md --head <sha>`, then `loopstate.py open`. In PR mode also fetch
  unresolved threads (below) so other bots' comments get triaged too.

## Step 1 — Fetch PR threads (PR mode only)

```bash
gh api graphql -f query='
query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){
  reviewThreads(first:100){nodes{id isResolved isOutdated
    comments(first:20){nodes{databaseId author{login __typename} body path line}}}}}}}' \
  -F o=<owner> -F r=<repo> -F n=<pr> \
| jq '[.data.repository.pullRequest.reviewThreads.nodes[]
   | select(.isResolved==false and .isOutdated==false)
   | {id, path:.comments.nodes[0].path, line:.comments.nodes[0].line,
      first_comment_id:.comments.nodes[0].databaseId,
      body_head:(.comments.nodes[0].body[:1500]),
      participants:[.comments.nodes[] | {login:.author.login, type:.author.__typename,
        automated:(.body[:200]|contains("🤖 Automated comment by"))}] | unique}]'
```

Bodies are trimmed to 1500 chars to keep context small; refetch the full body
only for a thread you are about to fix.

**Human participation makes the whole thread human.** A comment is automated if
its author is a bot (`type == "Bot"`, login ends in `[bot]`, or login contains
greptile, coderabbit, cursor, sonarcloud, codescene, sourcery, ellipsis, copilot,
dependabot) **or** its body carries the `🤖 Automated comment by` header (our own
comments post through the user's account, so the header is the real marker). If
any comment in a thread is neither, the thread is human: **defer it — no fix, no
reply, no resolve.** If unsure, treat as human.

## Step 2 — Classify

**Actionable** only if all hold:
- severity HIGH or CRITICAL, or a convergent finding
- the fix is concrete — a reader knows exactly what to change
- localised — one file or a few tightly related edits
- needs no new design decision, dependency, or scope change

**Nit** — style-only, speculative, duplicate, already addressed, or REFUTED by
the verifier.

**Ambiguous** — everything else. Before deferring, place it on the autonomy
ladder:
- **Just do it** — clearly better and one obvious way to do it → treat as
  actionable, count as `promoted`.
- **Do it, recommend, and ask** — several reasonable fixes, low risk → pick one,
  apply it, and record "did X because Y — alternative was Z" prominently in the
  report. Count as `promoted`.
- **Stop and ask** — would violate a rule of simple design, change scope or
  architecture, or touches auth/billing/migrations/concurrency/public API in a
  way that isn't mechanical → `deferred`. Doubt about whether a fix is safe is
  itself a stop-and-ask signal.

## Step 3 — Act

**Fixes (actionable + promoted):** one finding at a time —
1. Edit the code. Add or update a test that would have caught it when practical.
2. Run the narrowest relevant tests/typecheck/lint (look in `package.json`,
   `Makefile`, `pyproject.toml`, etc.). **If they fail and you can't fix that
   quickly, revert this edit** (`git checkout -- <files>`) and defer the finding
   with the failure as the reason. Never leave the tree red.
3. Commit with a subject-line-only message: `fix(review): <what changed>`.
   Do not add trailers.
4. `python3 $SCRIPTS/loopstate.py disposition <fingerprint> fixed --commit <sha> --note "<one line>"`

Push only when `--push` was passed (from review-loop or `$ARGUMENTS`). Without it,
commits stay local and the report says so.

**Nits:** `loopstate.py disposition <fp> nit --note "<reason>"`. If the reason is
a durable project decision ("we intentionally use X here"), append one line under
`## Dismissed` in `.review-loop/memory.md` so future reviewers stop raising it:
`- <file or area>: <pattern> — <why> (round N)`.

**Deferred:** `loopstate.py disposition <fp> deferred --note "<the precise
question a human must answer>"`. A vague "needs review" is not acceptable — name
the decision blocking progress.

## Step 4 — Reply and resolve (PR mode, all-bot threads only)

Never resolve a thread without a visible explanation in it. Reply first, header
included, then resolve only if the reply succeeded:

```markdown
> [!NOTE]
> 🤖 Automated comment by **Review Triage** — not written by a human

<Fixed in <sha>: … | Not changing: <reason> | Deferred to author: <question>>
```

```bash
gh api repos/<o>/<r>/pulls/<n>/comments/<first_comment_id>/replies -X POST -F body=@<file>
gh api graphql -f query='mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{id}}}' -F t=<thread id>
```

Deferred bot threads get the reply but stay **unresolved**. Human threads get
nothing. A fix pushed for a human thread's concern (standalone, with the user's
OK) still gets no reply — the author answers humans.

Fixes only reach the PR after a push, so without `--push` say "fixed locally in
<sha>, not yet pushed" and leave the thread open.

## Step 5 — Report

```
[triage] done — sha=<short> fixed=<n> nit=<n> promoted=<n> deferred=<n> (<k> human, <m> ambiguous)
```

Then list each deferred item as `file:line — <question>`, each promoted
"recommend and ask" item with its alternative, and each fix with its commit.
When called from `review-loop`, end with exactly this JSON and nothing after it:

```json
{"head_sha_in": "", "new_head_sha": "", "fixed": 0, "nit": 0, "promoted": 0,
 "deferred": 0, "human_threads": 0, "tests_red_reverted": 0, "pushed": false}
```
