import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import ts from 'typescript'

const root = resolve(import.meta.dirname, '..')
const read = (path) => readFileSync(resolve(root, path), 'utf8')

const helperSource = read('src/lib/sales-return-print.ts')
const componentSource = read('src/components/SalesReturnApprovalView.tsx')
const pwaSource = read('../pwa/src/SalesReturnModal.tsx')

const transpiled = ts.transpileModule(helperSource, {
  compilerOptions: {
    module: ts.ModuleKind.ESNext,
    target: ts.ScriptTarget.ES2022,
  },
}).outputText
const helperUrl = `data:text/javascript;base64,${Buffer.from(transpiled).toString('base64')}`
const { salesReturnNoteHtml } = await import(helperUrl)

const base = {
  document: {
    returnNo: 'RET-QA-001',
    sourceInvoiceNo: 'INV-QA-001',
    customerName: 'Customer <QA>',
    storeName: 'Toko QA',
    postedAt: '2026-10-31T08:00:00.000Z',
    postedBy: 'Manager QA',
    notes: 'Final & approved',
    refundBeforeRounding: 25000,
    roundingAdjustment: 0,
    refundTotal: 25000,
  },
  lines: [{
    productSku: 'QA-01', productName: 'Ayam <Frozen>', uomName: 'PACK',
    quantity: 1, condition: 'Layak dijual kembali', refundAmount: 25000,
  }],
}

const cashHtml = salesReturnNoteHtml({
  ...base,
  refunds: [{
    methodName: 'Cash', methodType: 'CASH', amount: 25000,
    transferDestination: null, transferReference: null, proofUrl: null,
  }],
})
assert.match(cashHtml, /NOTA RETURN PENJUALAN/)
assert.match(cashHtml, /Metode refund aktual/)
assert.match(cashHtml, /Cash/)
assert.match(cashHtml, /tidak memerlukan tujuan transfer/)
assert.doesNotMatch(cashHtml, /Tujuan:/)
assert.match(cashHtml, /Customer &lt;QA&gt;/)
assert.match(cashHtml, /Ayam &lt;Frozen&gt;/)
assert.doesNotMatch(cashHtml, /Customer <QA>/)

const transferHtml = salesReturnNoteHtml({
  ...base,
  refunds: [{
    methodName: 'Transfer BCA', methodType: 'TRANSFER', amount: 25000,
    transferDestination: 'BCA 123', transferReference: 'TRX-001',
    proofUrl: 'https://example.test/proof',
  }],
})
assert.match(transferHtml, /Transfer BCA/)
assert.match(transferHtml, /Tujuan: BCA 123/)
assert.match(transferHtml, /Referensi: TRX-001/)
assert.match(transferHtml, /https:\/\/example\.test\/proof/)

assert.match(componentSource, /document\.status === 'POSTED'.*Cetak Nota Return/)
assert.doesNotMatch(componentSource, /document\.status === 'DRAFT'.*Cetak Nota Return/)
assert.match(pwaSource, /nextMethod\?\.methodType !== 'TRANSFER'/)
assert.match(pwaSource, /setTransferDestination\(''\)/)
assert.match(pwaSource, /setTransferReference\(''\)/)
assert.match(pwaSource, /Tujuan transfer dan nomor referensi tidak diperlukan/)

console.log('retail-sales-return-refund-note-contract: PASS')
