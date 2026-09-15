// Pure list-filter fixtures, no database or credentials.
import assert from 'node:assert/strict'
import { filterRetailHistory, retailStatusLabel } from '../src/lib/office-retail-history.ts'
const base = { id: 'old', companyId: 'A', documentNo: 'DRF-OLD', invoiceNo: 'INV-OLD',
  invoiceSnapshotId: 'snapshot', status: 'DELIVERED', documentStatus: 'DRAFT',
  kind: 'SALES_ORDER', orderDate: '2026-09-12', deliveryDate: '2026-09-13',
  dueDate: '2026-09-20', customerName: 'Customer', storeName: 'Store', targetId: null }
const filters = { companyId: 'A', kind: 'SALES_ORDER', search: '', fulfillment: '',
  invoice: '', dateBasis: 'ORDER_DATE', dateFrom: '', dateTo: '' }
const rows = [base, { ...base, id: 'other', companyId: 'B' },
  { ...base, id: 'converted', targetId: 'SO-new' },
  { ...base, id: 'input', status: 'DRAFT_INPUT', kind: 'QUOTATION', invoiceSnapshotId: null },
  { ...base, id: 'scheduled', status: 'SCHEDULED', kind: 'QUOTATION', invoiceSnapshotId: null },
  { ...base, id: 'cancel', status: 'CANCELED', documentStatus: 'CANCELED' }]
assert.deepEqual(filterRetailHistory(rows, filters).map(row => row.id), ['old', 'cancel'])
assert.deepEqual(filterRetailHistory(rows, { ...filters, kind: 'QUOTATION' }).map(row => row.id), ['input', 'scheduled'])
assert.equal(filterRetailHistory(rows, { ...filters, fulfillment: 'COMPLETED' }).length, 1)
assert.equal(filterRetailHistory(rows, { ...filters, fulfillment: 'CANCELED' }).length, 1)
assert.equal(filterRetailHistory(rows, { ...filters, search: 'inv-old' }).length, 2)
assert.equal(filterRetailHistory(rows, { ...filters, invoice: 'READY' }).length, 0)
assert.equal(filterRetailHistory(rows, { ...filters, dateBasis: 'DUE_DATE', dateFrom: '2026-09-21' }).length, 0)
assert.equal(filterRetailHistory(rows, { ...filters, dateBasis: 'DELIVERY_DATE', dateTo: '2026-09-12' }).length, 0)
assert.equal(retailStatusLabel(base), 'Selesai')
assert.equal(filterRetailHistory(Array.from({ length: 1200 }, (_, index) => ({ ...base, id: String(index) })), filters).length, 1200)
console.log('PASS: Company, conversion dedupe, Draft/scheduled, status/Invoice/search/date filters, no history count cap')
