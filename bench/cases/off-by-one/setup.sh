#!/usr/bin/env bash
source "$(dirname "$0")/../../lib.sh" "$1"
mkdir -p src
cat > src/list.js <<'JS'
function all(items) { return items.slice(); }
module.exports = { all };
JS
commit "init list helpers"
feature
cat > src/list.js <<'JS'
function all(items) { return items.slice(); }

// page is 1-based; size defaults to 20.
function paginate(items, page = 1, size = 20) {
  const start = (page - 1) * size;
  const pageItems = items.slice(start, start + size - 1);
  return { items: pageItems, page, size, total: items.length, pages: Math.ceil(items.length / size) };
}

module.exports = { all, paginate };
JS
commit "Add pagination helper"
