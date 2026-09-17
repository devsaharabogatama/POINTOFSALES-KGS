import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'

const source = await readFile(
  new URL('../src/components/DeliveryDocumentView.tsx', import.meta.url),
  'utf8',
)

assert.doesNotMatch(
  source,
  /disabled=\{row\.sourceChannel === 'BACKOFFICE_SALES'/,
  'Backoffice Surat Jalan checkbox must remain selectable',
)
assert.match(
  source,
  /const selectableFiltered = filtered\.slice\(0, MAX_BULK_DOCUMENTS\)/,
  'Select-all must use the currently filtered rows for every source channel',
)
assert.match(
  source,
  /row\.sourceChannel === 'BACKOFFICE_SALES'[\s\S]*?row\.status === 'IN_TRANSIT'[\s\S]*?row\.receiptReady === true/,
  'Backoffice bulk receipt must require IN_TRANSIT and receiptReady',
)
assert.match(
  source,
  /backoffice\s*\?\s*'\/api\/inventory\/backoffice-delivery-orders'/,
  'Backoffice bulk mutation must use its canonical endpoint',
)
assert.match(
  source,
  /action: action === 'DELIVER' \? 'RECEIVE' : 'DISPATCH'/,
  'Backoffice UI action must map DELIVER to canonical RECEIVE',
)
assert.match(
  source,
  /action === 'DELIVER' \? \{ acceptedDate: companyDate \}/,
  'Backoffice bulk receipt must send the active Company date',
)
assert.match(
  source,
  /bulkNextAction[\s\S]*?`Mulai pengiriman \(\$\{markedRows\.length\}\)`[\s\S]*?`Konfirmasi diterima \(\$\{markedRows\.length\}\)`/,
  'Bulk UI must expose one context-aware progressive action',
)
assert.match(
  source,
  /DELIVERED: 'Diterima',[\s\S]*?COMPLETED: 'Diterima'/,
  'Terminal delivery labels must use Diterima',
)
assert.match(
  source,
  /Dokumen yang gagal tidak diubah/,
  'Partial bulk failure behavior must remain explicit',
)

console.log('delivery_document_progressive_bulk_contract=PASS')
