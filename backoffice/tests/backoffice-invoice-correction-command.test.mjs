import assert from 'node:assert/strict';
import test from 'node:test';
import {
  correctionDate,
  parseInvoiceCorrectionCommand as parse,
  invoiceCorrectionPayloadIdentity as identity,
  resolveCorrectionDueDate as dueDate,
} from '../src/lib/backoffice-invoice-correction-command.ts';

const id = (n) => `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
const base = { invoiceId: id(1), operationId: id(2), masterVersion: 1, revision: 0 };
const revision = () => ({ ...base, kind: 'INVOICE_REVISION', customerId: id(3),
  invoiceDate: '2026-10-05', dueDate: { mode: 'KEEP_TERM' },
  lines: [{ invoiceLineId: id(4), unitPrice: '25110', discountAmount: '1000' }] });
const payment = () => ({ ...base, kind: 'PAYMENT_CORRECTION', receiptId: id(6),
  receiptVersion: 2, correction: { reason: 'PAYMENT_NOT_RECEIVED' } });
const refund = () => ({ ...base, kind: 'REFUND', creditId: id(7), creditVersion: 1,
  refundDate: '2026-10-05', amount: '1000', paymentMethodId: id(8) });
const term = () => ({ previousInvoiceDate: '2026-09-28', previousDueDate: '2026-10-02',
  invoiceDate: '2026-10-05', dueDate: { mode: 'KEEP_TERM' }, adminOverrideAuthorized: false });
const throws = (body, code) => assert.throws(() => parse(body), { message: code });

test('one invoice command keeps customer ID, exact decimals and optional note', () => {
  const source = revision();
  const snapshot = structuredClone(source);
  const result = parse(source);
  assert.equal(result.customerId, id(3));
  assert.equal(result.lines[0].unitPrice, '25110.0000');
  assert.equal(result.notes, null);
  assert.deepEqual(source, snapshot);
});

test('both entry points have the same canonical payload independent of key/order', () => {
  const a = revision();
  a.lines.push({ invoiceLineId: id(5), unitPrice: '0.1', discountAmount: '0' });
  const b = { ...a, operationId: id(99), lines: [...a.lines].reverse() };
  b.lines = b.lines.map(line => ({ discountAmount: `${line.discountAmount}.0000`,
    unitPrice: line.unitPrice === '0.1' ? '0.1000' : '25110.0000', invoiceLineId: line.invoiceLineId }));
  assert.equal(identity(a), identity(b));
  assert.notEqual(identity(a), identity({ ...a, customerId: id(55) }));
  assert.notEqual(identity(a), identity({ ...a, revision: 1 }));
  assert.notEqual(identity(a), identity({ ...a, invoiceDate: '2026-10-06' }));
});

for (const field of ['companyId', 'actorId', 'journal', 'grandTotal', 'sourceEntryPoint']) {
  test(`reject client-owned ${field}`, () => throws({ ...revision(), [field]: 'fake' }, 'INVOICE_CORRECTION_UNKNOWN_FIELD'));
}
for (const field of ['productId', 'quantityUom', 'uomId', 'taxApplied', 'warehouseId']) {
  test(`reject immutable product relation field ${field}`, () => {
    const body = revision(); body.lines[0][field] = 1;
    throws(body, 'INVOICE_CORRECTION_UNKNOWN_FIELD');
  });
}
for (const amount of [null, true, false, '', ' 1', '1 ', '1e3', 'NaN', '-1', '01', '.5', '1.00001', '100000000000000000000', 1000]) {
  test(`reject noncanonical money ${String(amount)} (${typeof amount})`, () => {
    const body = revision(); body.lines[0].unitPrice = amount;
    throws(body, 'INVOICE_CORRECTION_MONEY_INVALID');
  });
}
test('preserve full numeric(24,4) without float loss', () => {
  const body = revision(); body.lines[0].unitPrice = '99999999999999999999.9999';
  assert.equal(parse(body).lines[0].unitPrice, body.lines[0].unitPrice);
});
test('duplicate line IDs rejected case-insensitively', () => {
  const body = revision(); body.lines[0].invoiceLineId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  body.lines.push({ ...body.lines[0], invoiceLineId: body.lines[0].invoiceLineId.toUpperCase() });
  throws(body, 'INVOICE_CORRECTION_DUPLICATE_LINE');
});
test('customer must be an ID; no free text name replacement', () => {
  throws({ ...revision(), customerId: 'PT ABC' }, 'INVOICE_CORRECTION_UUID_INVALID');
  throws({ ...revision(), customerName: 'PT ABC' }, 'INVOICE_CORRECTION_UNKNOWN_FIELD');
});
for (const value of [null, '1', -1, 1.5, Number.MAX_SAFE_INTEGER + 1]) {
  test(`reject invalid revision ${String(value)}`, () => throws({ ...revision(), revision: value }, 'INVOICE_CORRECTION_VERSION_INVALID'));
}
test('zero master version rejected; zero revision accepted', () => {
  throws({ ...revision(), masterVersion: 0 }, 'INVOICE_CORRECTION_VERSION_INVALID');
  assert.equal(parse(revision()).revision, 0);
});
test('dates are Gregorian dates rather than regex matches only', () => {
  assert.equal(correctionDate('2024-02-29'), '2024-02-29');
  assert.equal(correctionDate('2000-02-29'), '2000-02-29');
  for (const date of ['1900-02-29', '2026-02-29', '2026-04-31', '0000-01-01', '2026-00-01', '2026-13-01', '2026-01-00', '2026-10-05T00:00:00Z']) {
    assert.throws(() => correctionDate(date), { message: 'INVOICE_CORRECTION_DATE_INVALID' });
  }
});
test('due date preserves prior four-day term across month', () => assert.equal(dueDate(term()), '2026-10-09'));
test('term handles leap day and year boundary', () => {
  assert.equal(dueDate({ ...term(), previousInvoiceDate: '2024-02-28', previousDueDate: '2024-03-01', invoiceDate: '2026-12-31' }), '2027-01-02');
});
test('admin override requires server authority and valid due date', () => {
  const input = { ...term(), dueDate: { mode: 'ADMIN_OVERRIDE', date: '2026-11-01' } };
  assert.throws(() => dueDate(input), { message: 'INVOICE_CORRECTION_DUE_DATE_OVERRIDE_FORBIDDEN' });
  assert.equal(dueDate({ ...input, adminOverrideAuthorized: true }), '2026-11-01');
  assert.throws(() => dueDate({ ...input, adminOverrideAuthorized: true,
    dueDate: { mode: 'ADMIN_OVERRIDE', date: '2026-10-01' } }), { message: 'INVOICE_CORRECTION_DUE_DATE_BEFORE_INVOICE' });
});
test('fake payment requests reversal, never a credit/refund or advance', () => {
  assert.deepEqual(parse(payment()).correction, { reason: 'PAYMENT_NOT_RECEIVED' });
  throws({ ...payment(), amount: '1000' }, 'INVOICE_CORRECTION_UNKNOWN_FIELD');
  throws({ ...payment(), correction: { reason: 'PAYMENT_NOT_RECEIVED', paymentDate: '2026-10-05' } }, 'INVOICE_CORRECTION_UNKNOWN_FIELD');
});
test('wrong payment date is a distinct source-linked correction', () => {
  const result = parse({ ...payment(), correction: { reason: 'WRONG_PAYMENT_DATE', paymentDate: '2026-10-04' } });
  assert.equal(result.receiptId, id(6));
  assert.equal(result.correction.paymentDate, '2026-10-04');
});
test('refund requires source invoice, source credit, payment method and positive amount', () => {
  assert.equal(parse(refund()).amount, '1000.0000');
  for (const field of ['invoiceId', 'creditId', 'paymentMethodId']) {
    const body = refund(); delete body[field]; throws(body, 'INVOICE_CORRECTION_UUID_INVALID');
  }
  throws({ ...refund(), amount: '0.0000' }, 'INVOICE_CORRECTION_AMOUNT_MUST_BE_POSITIVE');
});
test('no mutation, journal or business behavior is asserted by these contract tests', () => {
  throws({ ...base, kind: 'MANUAL_JOURNAL' }, 'INVOICE_CORRECTION_KIND_INVALID');
  throws({ ...revision(), notes: 'x'.repeat(1001) }, 'INVOICE_CORRECTION_TEXT_INVALID');
  throws({ ...revision(), lines: [] }, 'INVOICE_CORRECTION_LINES_REQUIRED');
});
