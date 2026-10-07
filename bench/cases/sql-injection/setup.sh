#!/usr/bin/env bash
source "$(dirname "$0")/../../lib.sh" "$1"
mkdir -p src
cat > src/db.js <<'JS'
// Thin wrapper so the app can swap drivers.
const queries = [];
module.exports = { query: async (sql, params = []) => { queries.push({ sql, params }); return []; }, queries };
JS
cat > src/users.js <<'JS'
const db = require('./db');
async function findById(id) {
  return db.query('SELECT id, email FROM users WHERE id = ?', [id]);
}
module.exports = { findById };
JS
commit "init users module"
feature
cat > src/users.js <<'JS'
const db = require('./db');

async function findById(id) {
  return db.query('SELECT id, email FROM users WHERE id = ?', [id]);
}

// Used by the admin search box.
async function searchByEmail(email) {
  const term = email.trim().toLowerCase();
  return db.query("SELECT id, email FROM users WHERE email LIKE '%" + term + "%'");
}

module.exports = { findById, searchByEmail };
JS
commit "Add admin user search by email"
