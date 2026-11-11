import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const returnView = readFileSync(
  new URL('../src/components/BackofficeSalesReturnView.tsx', import.meta.url),
  'utf8',
);
const invoiceView = readFileSync(
  new URL('../src/components/BackofficeSalesInvoiceView.tsx', import.meta.url),
  'utf8',
);
const parser = readFileSync(
  new URL('../src/lib/backoffice-sales-invoice.ts', import.meta.url),
  'utf8',
);
const postRoute = readFileSync(
  new URL('../src/app/api/finance/backoffice-credit-notes/[id]/post-and-create-replacement/route.ts', import.meta.url),
  'utf8',
);
const readRoute = readFileSync(
  new URL('../src/app/api/finance/backoffice-credit-notes/[id]/route.ts', import.meta.url),
  'utf8',
);

test('Credit Note UI keeps plain post and exposes explicit replacement action', () => {
  assert.ok(returnView.includes('/post`'));
  assert.ok(returnView.includes('/post-and-create-replacement`'));
  assert.ok(returnView.includes('Post Credit Note'));
  assert.ok(returnView.includes('Post & Buat Invoice Pengganti'));
});

test('replacement API delegates identity and authorization to server runtime', () => {
  assert.ok(postRoute.includes('requireCaller'));
  assert.ok(postRoute.includes('requireActiveCompany(caller)'));
  assert.ok(postRoute.includes('post_backoffice_credit_note_create_replacement_invoice'));
  assert.equal(postRoute.includes('companyId:'), false);
  assert.equal(postRoute.includes('actorId:'), false);
});

test('Credit Note read model exposes linked replacement without direct table access', () => {
  assert.ok(readRoute.includes('get_backoffice_credit_note_replacement'));
  assert.ok(readRoute.includes('replacement:'));
  assert.equal(readRoute.includes('.from('), false);
});

test('replacement Draft editor preserves explicit source lineage', () => {
  assert.ok(invoiceView.includes('CREDIT_NOTE_REPLACEMENT'));
  assert.ok(invoiceView.includes('replacementSourceInvoiceLineId'));
  assert.ok(invoiceView.includes('replacementLines:'));
  assert.ok(parser.includes('BACKOFFICE_REPLACEMENT_LINE_INVALID'));
  assert.ok(parser.includes('requiredUuid(line, "replacementSourceInvoiceLineId")'));
});
