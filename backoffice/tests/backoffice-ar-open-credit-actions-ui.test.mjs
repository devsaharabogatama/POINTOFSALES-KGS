import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const view = readFileSync(
  new URL('../src/components/CustomerReceiptView.tsx', import.meta.url),
  'utf8',
);
const route = readFileSync(
  new URL('../src/app/api/finance/ar-open-credit-actions/route.ts', import.meta.url),
  'utf8',
);
const workspace = readFileSync(
  new URL('../src/app/api/finance/customer-receipts/route.ts', import.meta.url),
  'utf8',
);
const catalog = readFileSync(
  new URL('../src/lib/navigation-catalog.ts', import.meta.url),
  'utf8',
);
const page = readFileSync(
  new URL('../src/app/page.tsx', import.meta.url),
  'utf8',
);

test('receipt and open-credit workspaces are separate permission-compatible pages', () => {
  assert.ok(catalog.includes("'ar-open-credits': 'finance.customer_receipts'"));
  assert.ok(catalog.includes("label: 'Open Credit Customer'"));
  assert.ok(page.includes('activeView === "customer-receipts"'));
  assert.ok(page.includes('activeView === "ar-open-credits"'));
  assert.ok(page.includes('mode="OPEN_CREDIT"'));
  assert.ok(view.includes("mode === 'RECEIPTS'"));
  assert.ok(view.includes("mode === 'OPEN_CREDIT'"));
});

test('Finance UI exposes every approved explicit AR action', () => {
  for (const action of [
    'APPLY_CREDIT',
    'REFUND_CREDIT',
    'CONVERT_CREDIT_BALANCE',
    'APPLY_CUSTOMER_BALANCE',
    'REVERSE',
  ]) assert.ok(view.includes(`'${action}'`), action);
  for (const label of ['Alokasikan', 'Refund', 'Jadi saldo', 'Pakai saldo', 'Reversal']) {
    assert.ok(view.includes(label), label);
  }
});

test('actions remain manual and require an effective date', () => {
  assert.ok(view.includes('Finance memilih tindakan secara eksplisit; tidak ada alokasi otomatis.'));
  assert.ok(view.includes('Field label="Tanggal efektif"'));
  assert.ok(view.includes('effectiveDate: arDate'));
});

test('Customer Balance actions stay hidden while the Company policy is inactive', () => {
  assert.ok(view.includes("policy?.lifecycle_state === 'ACTIVE'"));
  assert.ok(view.includes('customerBalance > 0'));
  assert.ok(workspace.includes('get_finance_customer_balances'));
});

test('server route maps each UI action to its scoped RPC', () => {
  for (const rpc of [
    'apply_backoffice_ar_open_credit',
    'refund_backoffice_ar_open_credit',
    'convert_backoffice_ar_open_credit_to_customer_balance',
    'apply_customer_balance_to_backoffice_invoice',
    'reverse_backoffice_ar_open_credit_action',
  ]) assert.ok(route.includes(`'${rpc}'`), rpc);
  assert.ok(route.includes('requireCaller'));
  assert.ok(route.includes('requireActiveCompany(caller)'));
  assert.ok(route.includes('caller.client.rpc'));
});

test('client never owns Company, actor, Journal, or Finance Event identity', () => {
  for (const forbidden of ['companyId', 'actorId', 'journalId', 'financialEventId']) {
    assert.equal(route.includes(`body.${forbidden}`), false, forbidden);
  }
});
