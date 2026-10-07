#!/usr/bin/env bash
source "$(dirname "$0")/../../lib.sh" "$1"
mkdir -p src docs
cat > src/clients.js <<'JS'
const clients = [
  { name: 'Acme, Inc', email: 'a@acme.test', archived: false },
  { name: 'Old Co', email: 'o@old.test', archived: true },
];
module.exports = { allClients: async () => clients };
JS
cat > docs/spec-export.md <<'MD'
# Client CSV export

1. Export columns: name, email.
2. Archived clients must NOT be included.
3. Values containing commas or quotes must be quoted per RFC 4180.
MD
commit "init clients and export spec"
feature
cat > src/export.js <<'JS'
const { allClients } = require('./clients');

function csvValue(v) {
  const s = String(v ?? '');
  return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
}

async function exportClientsCsv() {
  const rows = await allClients();
  const lines = ['name,email', ...rows.map((c) => [c.name, c.email].map(csvValue).join(','))];
  return lines.join('\n');
}

module.exports = { exportClientsCsv };
JS
commit "Implement client CSV export per docs/spec-export.md"
