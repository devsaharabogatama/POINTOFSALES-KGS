import { expect, test } from '@playwright/test'
import { readFile } from 'node:fs/promises'

const root = new URL('../../', import.meta.url)
const read = (path: string) => readFile(new URL(path, root), 'utf8')

test('Inventory mutation forms keep notes optional and business reasons conditional', async () => {
  const [adjustmentUi, adjustmentParser, transferUi, transferParser, openingUi, openingParser] = await Promise.all([
    read('backoffice/src/components/StockAdjustmentView.tsx'),
    read('backoffice/src/lib/stock-adjustment.ts'),
    read('backoffice/src/components/StockTransferView.tsx'),
    read('backoffice/src/lib/stock-transfer.ts'),
    read('backoffice/src/components/OpeningStockView.tsx'),
    read('backoffice/src/lib/opening-stock.ts'),
  ])

  expect(adjustmentUi).toContain('Catatan dokumen (opsional)')
  expect(adjustmentUi).toContain('Catatan baris (opsional)')
  expect(adjustmentParser).toContain("notes: optionalText(body, 'notes'")
  expect(adjustmentParser).toContain("notes: optionalText(line, 'notes'")
  expect(adjustmentParser).toContain("reasonId: requiredUuid(line, 'reasonId')")
  expect(adjustmentUi).toContain('required={Boolean(line.unitCostBase)}')

  expect(transferUi).toContain('Catatan dokumen (opsional)')
  expect(transferUi).toContain('Catatan baris (opsional)')
  expect(transferParser).toContain("notes: optionalText(body, 'notes'")
  expect(transferParser).toContain("notes: optionalText(line, 'notes'")

  expect(openingUi).toContain('Catatan dokumen (opsional)')
  expect(openingParser).toContain("notes: optionalText(body, 'notes'")
  expect(openingParser).toContain("notes: optionalText(line, 'notes'")
  expect(openingParser).toContain("Number(unitCostBase) === 0 && !zeroCostReason")
  expect(openingUi).toContain("Number(line.unitCostBase) === 0 && line.unitCostBase !== ''")
})

test('Purchase forms expose optional fields as optional and retain required lifecycle reasons', async () => {
  const [receiptUi, receiptParser, orderUi, orderParser, returnUi, returnParser] = await Promise.all([
    read('backoffice/src/components/GoodsReceiptView.tsx'),
    read('backoffice/src/lib/goods-receipt.ts'),
    read('backoffice/src/components/SupplierOrderView.tsx'),
    read('backoffice/src/lib/supplier-order.ts'),
    read('backoffice/src/components/PurchaseReturnApprovalView.tsx'),
    read('backoffice/src/lib/purchase-return.ts'),
  ])

  expect(receiptParser).toContain("supplierDeliveryNo:optionalText(body,'supplierDeliveryNo'")
  expect(receiptParser).toContain("notes:optionalText(body,'notes'")
  expect.soft(receiptUi).toContain('Nomor surat jalan supplier (opsional)')
  expect.soft(receiptUi).toContain('Catatan (opsional)')

  expect(orderParser).toContain('notes: optionalText(body, "notes"')
  expect.soft(orderUi).toContain('Catatan (opsional)')

  expect(returnParser).toContain('returnReason: requiredText(body, "returnReason"')
  expect(returnParser).toContain('notes: optionalText(body, "notes"')
  expect(returnParser).toContain('decision === "REJECT"')
  expect(returnParser).toContain('reason: requiredText(body, "reason"')
  expect(returnUi).toContain('Alasan retur')
  expect(returnUi).toContain('Catatan (opsional)')
  expect(returnUi).toContain('Alasan penolakan')
  expect(returnUi).toContain('Alasan pembatalan')
})

test('Sales and Finance forms distinguish optional metadata from required evidence and reasons', async () => {
  const [invoiceUi, receiptUi, receiptRoute, supplierPaymentUi, supplierPaymentParser] = await Promise.all([
    read('backoffice/src/components/BackofficeSalesInvoiceView.tsx'),
    read('backoffice/src/components/CustomerReceiptView.tsx'),
    read('backoffice/src/app/api/finance/customer-receipts/route.ts'),
    read('backoffice/src/components/SupplierPaymentView.tsx'),
    read('backoffice/src/lib/supplier-payment.ts'),
  ])

  expect.soft(invoiceUi).toContain('Catatan (opsional)')
  expect(invoiceUi).toContain('Referensi (opsional)')
  expect(invoiceUi).toContain('method?.proofMode==="REQUIRED" ? " (wajib)" : " (opsional)"')

  expect(receiptRoute).toContain('p_reference_no: optionalText(body.referenceNo)')
  expect(receiptRoute).toContain('p_evidence_url: optionalText(body.evidenceUrl)')
  expect(receiptRoute).toContain('p_notes: optionalText(body.notes)')
  expect.soft(receiptUi).toContain('Referensi (opsional)')
  expect.soft(receiptUi).toContain('Link bukti HTTPS (opsional)')
  expect.soft(receiptUi).toContain('Catatan (opsional)')

  expect(supplierPaymentParser).toContain("const referenceNo = optionalText(body, 'referenceNo'")
  expect(supplierPaymentParser).toContain("const notes = optionalText(body, 'notes'")
  expect(supplierPaymentParser).toContain("const evidenceUrl = optionalText(body, 'evidenceUrl'")
  expect(supplierPaymentParser).toContain("const reason = requiredText(body, 'reason'")
  expect.soft(supplierPaymentUi).toContain('No Referensi / Transaksi (opsional)')
  expect.soft(supplierPaymentUi).toContain('URL Bukti Pembayaran (opsional, wajib HTTPS jika diisi)')
  expect.soft(supplierPaymentUi).toContain('Catatan (opsional)')
  expect(supplierPaymentUi).toContain('Alasan Pembatalan')
})

test('Audit-sensitive reasons have a matching visible input before the guarded API call', async () => {
  const [salesOrder, customerBalanceUi, customerBalanceParser, expenseUi, expenseParser, journalUi] = await Promise.all([
    read('backoffice/src/components/BackofficeSalesOrderView.tsx'),
    read('backoffice/src/components/CustomerBalanceView.tsx'),
    read('backoffice/src/lib/customer-balance.ts'),
    read('backoffice/src/components/ExpenseApprovalView.tsx'),
    read('backoffice/src/lib/expense.ts'),
    read('backoffice/src/components/ManualJournalDialog.tsx'),
  ])

  expect(salesOrder).toContain('<Field label="Alasan revisi"><textarea required')
  expect(customerBalanceParser).toContain("reason: requiredText(body, 'reason'")
  expect(customerBalanceUi).toContain('Alasan koreksi')
  expect(customerBalanceUi).toContain('Alasan penolakan')
  expect(expenseParser).toContain("reason: requiredText(body, 'reason'")
  expect(expenseUi).toContain('Alasan penolakan')
  expect(expenseUi).toContain('Alasan pembatalan')
  expect(journalUi).toContain('Keterangan jurnal wajib diisi.')
  expect(journalUi).toContain('Keterangan jurnal')
})

test('Remaining guarded Backoffice transitions expose their required reason fields', async () => {
  const [
    cutoverUi,
    cutoverRoute,
    salesDocumentUi,
    salesDocumentRoute,
    salesReturnUi,
    salesReturnParser,
    supplierInvoiceUi,
    supplierInvoiceParser,
    cashDepositUi,
    varianceUi,
    varianceParser,
    financeUi,
    financeRoute,
    deliveryUi,
    deliveryRoute,
  ] = await Promise.all([
    read('backoffice/src/components/SalesProcessCutoverSettings.tsx'),
    read('backoffice/src/app/api/platform/sales-process-cutover/route.ts'),
    read('backoffice/src/components/SalesDocumentView.tsx'),
    read('backoffice/src/app/api/sales/documents/route.ts'),
    read('backoffice/src/components/BackofficeSalesReturnView.tsx'),
    read('backoffice/src/lib/sales-return.ts'),
    read('backoffice/src/components/SupplierInvoiceMatchingView.tsx'),
    read('backoffice/src/lib/supplier-invoice.ts'),
    read('backoffice/src/components/CashDepositApprovalView.tsx'),
    read('backoffice/src/components/DepositVarianceResolutionView.tsx'),
    read('backoffice/src/lib/deposit-variance.ts'),
    read('backoffice/src/components/FinanceOperationsView.tsx'),
    read('backoffice/src/app/api/finance/operations/route.ts'),
    read('backoffice/src/components/DeliveryDocumentView.tsx'),
    read('backoffice/src/app/api/inventory/delivery-documents/[id]/route.ts'),
  ])

  expect(cutoverRoute).toContain("requiredText(body, 'reason'")
  expect(cutoverUi).toContain('Alasan pergantian')
  expect(cutoverUi).toContain('Alasan pembatalan rencana')
  expect(salesDocumentRoute).toContain("p_reason: requiredText(body, 'reason'")
  expect(salesDocumentUi).toContain('Alasan pembatalan')
  expect(salesReturnParser).toContain("reason: requiredText(body, 'reason'")
  expect(salesReturnUi).toContain('Alasan retur')
  expect(supplierInvoiceParser).toContain("requiredText(body, 'cancelReason'")
  expect(supplierInvoiceUi).toContain('Alasan Pembatalan')
  expect(cashDepositUi).toContain('Alasan penolakan')
  expect(varianceParser).toContain("reason: requiredText(body, 'reason'")
  expect(varianceUi).toContain('Alasan penetapan')
  expect(varianceUi).toContain('Alasan penyelesaian wajib diisi.')
  expect(financeRoute).toContain('p_description: requiredText(body, "description"')
  expect(financeRoute).toContain('p_reason: requiredText(body, "reason"')
  expect(financeUi).toContain('Alasan pembalikan wajib diisi.')
  expect(financeUi).toContain('Alasan membuka kembali periode wajib diisi.')
  expect(deliveryRoute).toContain("requiredText(body, 'reason'")
  expect(deliveryUi).toContain("action === 'CANCEL' ? 'Alasan pembatalan'")
})
