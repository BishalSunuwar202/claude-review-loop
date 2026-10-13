#!/usr/bin/env bash
# Deterministic risk gate (StampHog-style): runs BEFORE any model sees the diff.
# Usage: gate.sh <base-ref> [head-ref]
# Prints JSON: size, files, deny-list hits with the rule each matched, and
# whether the full pass is mandatory.
set -euo pipefail

base="${1:?usage: gate.sh <base-ref> [head-ref]}"
head="${2:-HEAD}"
range="$base...$head"

files=$(git diff --name-only "$range")
file_count=$(printf '%s\n' "$files" | sed '/^$/d' | wc -l | tr -d ' ')
lines=$(git diff --numstat "$range" | awk '{a+=$1; d+=$2} END {print a+d+0}')

# Paths where a mistake has a large blast radius, one extended regex per rule.
# Extend per project via .review-loop/deny-list (one extended regex per line).
# Each rule is kept with its source so the report can name the exact line that
# made a PR take the full pass.
rules=()
for r in auth login session permission rbac acl secret token crypto billing payment \
         stripe invoice migration migrations 'schema\.prisma' '\.sql$' deploy release \
         '\.github/workflows' Dockerfile docker-compose terraform k8s helm mutex \
         semaphore queue worker cron webhook; do
  rules+=("$r"$'\t'"built-in")
done
if [[ -f .review-loop/deny-list ]]; then
  n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ -z "$line" || "$line" == \#* ]] && continue
    rules+=("$line"$'\t'".review-loop/deny-list:$n")
  done < .review-loop/deny-list
fi

hits=""
matched=""   # file<TAB>rule<TAB>source, first matching rule per file
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  for entry in "${rules[@]}"; do
    rule=${entry%%$'\t'*}; src=${entry#*$'\t'}
    if printf '%s\n' "$f" | grep -Eiq -- "$rule"; then
      hits+="$f"$'\n'
      matched+="$f"$'\t'"$rule"$'\t'"$src"$'\n'
      break
    fi
  done
done <<< "$files"

docs_only=true
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  [[ "$f" =~ \.(md|mdx|txt|rst)$ ]] || docs_only=false
done <<< "$files"

reasons=()
(( lines > 400 )) && reasons+=("diff is $lines lines (>400)")
(( file_count > 20 )) && reasons+=("$file_count files changed (>20)")
while IFS=$'\t' read -r f rule src; do
  [[ -z "$f" ]] && continue
  reasons+=("$f matches '$rule' ($src)")
done <<< "$matched"

mandatory=false
(( ${#reasons[@]} > 0 )) && mandatory=true

jq -n \
  --argjson lines "$lines" \
  --argjson files "$file_count" \
  --argjson docs_only "$docs_only" \
  --argjson mandatory "$mandatory" \
  --arg hits "$hits" \
  --arg matched "$matched" \
  --arg reasons "$(printf '%s\n' "${reasons[@]:-}")" \
  '{lines: $lines, files: $files, docs_only: $docs_only,
    mandatory_delegation: $mandatory,
    deny_list_hits: ($hits | split("\n") | map(select(length > 0))),
    matched_rules: ($matched | split("\n") | map(select(length > 0) | split("\t")
                    | {file: .[0], rule: .[1], source: .[2]})),
    reasons: ($reasons | split("\n") | map(select(length > 0)))}'
