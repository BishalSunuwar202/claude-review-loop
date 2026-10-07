# Shared helpers for case setup scripts. Usage in a case: source "$(dirname "$0")/../../lib.sh" "$1"
set -euo pipefail
export GIT_AUTHOR_NAME=bench GIT_AUTHOR_EMAIL=bench@example.com
export GIT_COMMITTER_NAME=bench GIT_COMMITTER_EMAIL=bench@example.com
dir="${1:?usage: setup.sh <empty-dir>}"
mkdir -p "$dir" && cd "$dir"
git init -q -b main
cat > package.json <<'JSON'
{ "name": "bench-case", "version": "1.0.0", "type": "commonjs", "scripts": { "test": "node --test" } }
JSON
commit() { git add -A && git commit -qm "$1"; }
feature() { git checkout -qb feat; }
