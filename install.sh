#!/usr/bin/env bash
# Symlink the review-loop skills and agents into ~/.claude so edits here go live.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p ~/.claude/skills ~/.claude/agents

for skill in "$here"/skills/*/; do
  name=$(basename "$skill")
  target=~/.claude/skills/$name
  if [[ -e $target && ! -L $target ]]; then
    echo "skip $name: $target exists and is not a symlink" >&2; continue
  fi
  ln -sfn "${skill%/}" "$target" && echo "skill  $name"
done

for agent in "$here"/agents/*.md; do
  name=$(basename "$agent")
  target=~/.claude/agents/$name
  if [[ -e $target && ! -L $target ]]; then
    echo "skip $name: $target exists and is not a symlink" >&2; continue
  fi
  ln -sfn "$agent" "$target" && echo "agent  ${name%.md}"
done

echo "Installed. Restart Claude Code (or start a new session) to load them."
