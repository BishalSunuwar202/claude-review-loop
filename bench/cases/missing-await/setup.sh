#!/usr/bin/env bash
source "$(dirname "$0")/../../lib.sh" "$1"
mkdir -p src
cat > src/payments.js <<'JS'
async function chargeCard(card, amount) {
  if (!card || card.declined) throw new Error('card declined');
  return { id: 'ch_' + Date.now(), amount };
}
module.exports = { chargeCard };
JS
commit "init payments"
feature
cat > src/orders.js <<'JS'
const { chargeCard } = require('./payments');

async function placeOrder(order) {
  try {
    chargeCard(order.card, order.total);
  } catch (err) {
    return { ok: false, reason: err.message };
  }
  order.status = 'paid';
  return { ok: true, order };
}

module.exports = { placeOrder };
JS
commit "Add placeOrder"
