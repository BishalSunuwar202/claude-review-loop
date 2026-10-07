#!/usr/bin/env bash
# Run one reviewer over the planted-bug cases, N times each, headless.
# Usage: bench/run.sh <code-review|swarm|swarm-router> [runs=3] [case ...]
# Results: bench/results/<reviewer>/<case>/run<N>/ (raw.json + any .review-loop files)
# Cost: each run is a real Claude Code session (~50-150k tokens). 8 cases x 3 runs adds up.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
reviewer="${1:?usage: run.sh <code-review|swarm|swarm-router> [runs] [case ...]}"
runs="${2:-3}"; shift $(( $# >= 2 ? 2 : 1 ))
cases=("$@"); [[ ${#cases[@]} -eq 0 ]] && cases=($(ls "$here/cases"))

case "$reviewer" in
  code-review)  prompt="/code-review high feat" ;;
  swarm)        prompt="/review-swarm feat" ;;
  swarm-router) prompt="/review-swarm feat --finder router" ;;
  *) echo "unknown reviewer: $reviewer" >&2; exit 2 ;;
esac

# Reviewers read, run tests, and dispatch agents. They run inside a throwaway repo.
tools="Read Grep Glob Bash Write Edit Agent Skill"

for c in "${cases[@]}"; do
  for n in $(seq 1 "$runs"); do
    out="$here/results/$reviewer/$c/run$n"
    if [[ -f "$out/raw.json" ]]; then echo "skip $reviewer/$c/run$n (exists)"; continue; fi
    mkdir -p "$out"
    work=$(mktemp -d)
    bash "$here/cases/$c/setup.sh" "$work/repo" >/dev/null
    echo "run  $reviewer/$c/run$n"
    ( cd "$work/repo" && claude -p "$prompt" --output-format json --allowedTools $tools \
        > "$out/raw.json" 2> "$out/stderr.log" ) || echo "  (exit $?; see $out/stderr.log)"
    if [[ -d "$work/repo/.review-loop/runs" ]]; then
      find "$work/repo/.review-loop/runs" -name 'findings.md' -o -name 'unique.md' | while read -r f; do cp "$f" "$out/"; done
    fi
    rm -rf "$work"
  done
done
echo "done. score with: python3 $here/score.py"
