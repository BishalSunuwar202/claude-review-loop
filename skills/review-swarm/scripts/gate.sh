#!/usr/bin/env bash
# Deterministic risk gate (StampHog-style): runs BEFORE any model sees the diff.
# Usage: gate.sh <base-ref> [head-ref]
# Prints JSON: size, files, deny-list hits, and whether delegation is mandatory.
set -euo pipefail

base="${1:?usage: gate.sh <base-ref> [head-ref]}"
head="${2:-HEAD}"
range="$base...$head"

files=$(git diff --name-only "$range")
file_count=$(printf '%s\n' "$files" | sed '/^$/d' | wc -l | tr -d ' ')
lines=$(git diff --numstat "$range" | awk '{a+=$1; d+=$2} END {print a+d+0}')

# Paths where a mistake has a large blast radius. Extend per project via
# .review-loop/deny-list (one extended regex per line).
deny='(auth|login|session|permission|rbac|acl|secret|token|crypto|billing|payment|stripe|invoice|migration|migrations|schema\.prisma|\.sql$|deploy|release|\.github/workflows|Dockerfile|docker-compose|terraform|k8s|helm|mutex|semaphore|queue|worker|cron|webhook)'
if [[ -f .review-loop/deny-list ]]; then
  extra=$(sed '/^#/d;/^$/d' .review-loop/deny-list | paste -sd'|' -)
  [[ -n "$extra" ]] && deny="($deny|$extra)"
fi
hits=$(printf '%s\n' "$files" | grep -Ei "$deny" || true)

docs_only=true
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  [[ "$f" =~ \.(md|mdx|txt|rst)$ ]] || docs_only=false
done <<< "$files"

reasons=()
(( lines > 400 )) && reasons+=("diff is $lines lines (>400)")
(( file_count > 20 )) && reasons+=("$file_count files changed (>20)")
[[ -n "$hits" ]] && reasons+=("touches high-blast-radius paths")

mandatory=false
(( ${#reasons[@]} > 0 )) && mandatory=true

jq -n \
  --argjson lines "$lines" \
  --argjson files "$file_count" \
  --argjson docs_only "$docs_only" \
  --argjson mandatory "$mandatory" \
  --arg hits "$hits" \
  --arg reasons "$(printf '%s\n' "${reasons[@]:-}")" \
  '{lines: $lines, files: $files, docs_only: $docs_only,
    mandatory_delegation: $mandatory,
    deny_list_hits: ($hits | split("\n") | map(select(length > 0))),
    reasons: ($reasons | split("\n") | map(select(length > 0)))}'
