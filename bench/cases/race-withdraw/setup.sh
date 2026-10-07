#!/usr/bin/env bash
source "$(dirname "$0")/../../lib.sh" "$1"
mkdir -p src
cat > src/accounts.js <<'JS'
const balances = new Map([['a1', 100]]);
async function getBalance(id) { return balances.get(id) ?? 0; }
async function setBalance(id, value) { balances.set(id, value); }
module.exports = { getBalance, setBalance };
JS
commit "init accounts"
feature
cat > src/wallet.js <<'JS'
const { getBalance, setBalance } = require('./accounts');

async function withdraw(accountId, amount) {
  if (amount <= 0) throw new Error('amount must be positive');
  const balance = await getBalance(accountId);
  if (balance < amount) return { ok: false, reason: 'insufficient funds' };
  await setBalance(accountId, balance - amount);
  return { ok: true, balance: balance - amount };
}

module.exports = { withdraw };
JS
commit "Add wallet withdraw"
