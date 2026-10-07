#!/usr/bin/env bash
source "$(dirname "$0")/../../lib.sh" "$1"
mkdir -p src
cat > src/projects.js <<'JS'
const db = { find: async (where) => [] };
async function listProjects(user) { return db.find({ archived: false }); }
module.exports = { listProjects, db };
JS
commit "init projects"
cat > src/projects.js <<'JS'
const db = { find: async (where) => [] };
async function listProjects(user) { return db.find({ orgId: user.orgId, archived: false }); }
module.exports = { listProjects, db };
JS
commit "fix: scope project listing to the caller's org (cross-tenant leak)"
feature
cat > src/projects.js <<'JS'
const db = { find: async (where) => [] };
async function listProjects(user) { return db.find({ orgId: user.orgId, archived: false }); }

async function listByStatus(user, status) {
  return db.find({ status, archived: false });
}

module.exports = { listProjects, listByStatus, db };
JS
commit "Add project filtering by status"
