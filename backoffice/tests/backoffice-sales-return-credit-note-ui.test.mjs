import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const source = readFileSync(
  new URL('../src/components/BackofficeSalesReturnView.tsx', import.meta.url),
  'utf8',
);

test('Credit Note list and modal expose the commercial Draft value', () => {
  assert.equal((source.match(/label="Nilai Credit Note"/g) ?? []).length, 1);
  assert.equal((source.match(/>Nilai Credit Note</g) ?? []).length, 1);
  assert.ok((source.match(/money\(note\.grandTotal\)/g) ?? []).length >= 2);
});

test('Draft posting outcomes are not presented as Rp0 commercial value', () => {
  assert.ok(source.includes('note.status==="DRAFT"?"Belum diposting":money(note.arReductionAmount)'));
  assert.ok(source.includes('note.status==="DRAFT"?"Belum diposting":money(note.refundLiabilityAmount)'));
  assert.ok(source.includes('Dampak piutang baru terbentuk saat Finance mem-posting.'));
});

test('the UI fix does not add a new mutation or posting entry point', () => {
  assert.equal((source.match(/\/post`/g) ?? []).length, 1);
  assert.equal((source.match(/Post Credit Note/g) ?? []).length, 1);
});
