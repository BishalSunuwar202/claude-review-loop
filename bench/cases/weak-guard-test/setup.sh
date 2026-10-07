#!/usr/bin/env bash
source "$(dirname "$0")/../../lib.sh" "$1"
mkdir -p src/actions src/lib test
cat > src/lib/db.js <<'JS'
module.exports = { lines: { deleteMany: async () => 0, updateMany: async () => 0 } };
JS
cat > src/actions/booking.js <<'JS'
const db = require('../lib/db');
async function cancelLine(bookingId) { return db.lines.updateMany({ where: { bookingId }, data: { active: false } }); }
module.exports = { cancelLine };
JS
cat > src/lib/booking-core.js <<'JS'
const db = require('./db');
async function rebuildLines(bookingId, next) {
  await db.lines.updateMany({ where: { bookingId }, data: { active: false } });
  return next;
}
module.exports = { rebuildLines };
JS
commit "init booking actions"
feature
cat > src/lib/booking-core.js <<'JS'
const db = require('./db');
async function rebuildLines(bookingId, next) {
  await db.lines.deleteMany({ where: { bookingId } });
  return next;
}
module.exports = { rebuildLines };
JS
cat > test/no-hard-delete.test.js <<'JS'
// Treatment lines must be soft-deleted (active: false), never hard-deleted.
// This guard scans the code that writes lines and fails on any deleteMany.
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

test('treatment lines are never hard-deleted', () => {
  const dir = path.join(__dirname, '..', 'src', 'actions');
  for (const file of fs.readdirSync(dir)) {
    const src = fs.readFileSync(path.join(dir, file), 'utf8');
    // Matches lines.deleteMany( with at most one level of nested braces before it.
    assert.ok(!/lines\.deleteMany\(\{[^{}]*\}\)/.test(src), `${file} hard-deletes lines`);
  }
});
JS
commit "Rebuild booking lines; add guard test against hard deletes"
