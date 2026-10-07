#!/usr/bin/env bash
source "$(dirname "$0")/../../lib.sh" "$1"
mkdir -p src
cat > src/store.js <<'JS'
const invoices = new Map([[1, { id: 1, ownerId: 'u1', total: 120 }], [2, { id: 2, ownerId: 'u2', total: 75 }]]);
module.exports = { getInvoice: async (id) => invoices.get(Number(id)) || null };
JS
cat > src/routes.js <<'JS'
const { getInvoice } = require('./store');
// req.user is set by the auth middleware.
async function listMine(req, res) { res.json({ owner: req.user.id }); }
module.exports = { listMine };
JS
commit "init invoice routes"
feature
cat > src/routes.js <<'JS'
const { getInvoice } = require('./store');

// req.user is set by the auth middleware.
async function listMine(req, res) { res.json({ owner: req.user.id }); }

async function getOne(req, res) {
  const invoice = await getInvoice(req.params.id);
  if (!invoice) return res.status(404).json({ error: 'not found' });
  res.json(invoice);
}

module.exports = { listMine, getOne };
JS
commit "Add GET /invoices/:id"
