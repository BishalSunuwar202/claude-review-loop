#!/usr/bin/env bash
# Builds .review-loop/incidents.md: this repo's own past bugs, for incident-checker.
#   - "From git history": fix/bug/hotfix/revert commits, regenerated every run.
#   - "Confirmed by review": appended by review-triage, preserved across runs.
# Usage: incidents.sh [max-commits]   (default 150)
set -euo pipefail

max="${1:-150}"
root=$(git rev-parse --show-toplevel)
out="$root/.review-loop/incidents.md"
mkdir -p "$root/.review-loop"

confirmed=""
if [[ -f "$out" ]]; then
  confirmed=$(awk '/^## Confirmed by review/{flag=1; next} flag' "$out" | sed '/./,$!d')
fi

history=$(git log -n "$max" --no-merges --format='%h%x09%ad%x09%s' --date=short \
  -E -i --grep='^(fix|bug|hotfix|revert)' --grep='\b(fix(es|ed)?|bug|hotfix|regression|revert)\b' \
  | while IFS=$'\t' read -r sha date subject; do
      files=$(git show --name-only --format= "$sha" | head -8 | paste -sd',' - | sed 's/,/, /g')
      printf -- '- %s %s %s — files: %s\n' "$sha" "$date" "$subject" "$files"
    done)

{
  echo "# Incidents"
  echo
  echo "Past bugs in this repo. incident-checker compares each diff against these."
  echo
  echo "## From git history"
  echo
  if [[ -n "$history" ]]; then echo "$history"; else echo "(none found)"; fi
  echo
  echo "## Confirmed by review"
  echo
  [[ -n "$confirmed" ]] && echo "$confirmed"
} > "$out"

count=$(grep -c '^- ' "$out" || true)
echo "incidents: $count entries -> $out"
