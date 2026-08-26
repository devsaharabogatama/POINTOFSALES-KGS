import { apiError, requireActiveCompany, requireCaller, requirePermissionCapability } from '@/lib/server-auth'
import { throwDatabaseError } from '@/lib/master-data'
import { createXlsx, type WorkbookCell } from '@/lib/xlsx'

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const datePattern = /^\d{4}-\d{2}-\d{2}$/
type Json = Record<string, unknown>

function optionalUuid(value: string | null) {
  if (!value) return null
  if (!uuidPattern.test(value)) throw new Error('UUID_INVALID')
  return value
}
function optionalDate(value: string | null) {
  if (!value) return null
  if (!datePattern.test(value)) throw new Error('DATE_INVALID')
  return value
}
function cell(value: unknown): WorkbookCell {
  return typeof value === 'number' || typeof value === 'string' || typeof value === 'boolean' ? value : value == null ? '' : String(value)
}
function safe(value: unknown) {
  return String(value ?? 'Customer').replace(/[^A-Za-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60) || 'Customer'
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requirePermissionCapability(caller, companyId, 'finance.customer_receipts', 'EXPORT')
    const url = new URL(request.url)
    const type = String(url.searchParams.get('type') ?? 'AGING').toUpperCase()
    if (!['AGING', 'STATEMENT'].includes(type)) throw new Error('AR_REPORT_TYPE_INVALID')
    const customerId = optionalUuid(url.searchParams.get('customerId'))
    if (type === 'STATEMENT' && !customerId) throw new Error('CUSTOMER_REQUIRED_FOR_STATEMENT')
    const asOf = optionalDate(url.searchParams.get('asOf'))
    const dateFrom = optionalDate(url.searchParams.get('dateFrom'))
    const storeId = optionalUuid(url.searchParams.get('storeId'))
    const result = await caller.client.rpc('export_finance_ar_report', {
      p_report_type: type, p_customer_id: customerId, p_date_from: dateFrom,
      p_as_of: asOf, p_store_id: storeId,
    })
    if (result.error) throwDatabaseError(result.error)
    const payload = result.data as Json
    const rows = type === 'AGING'
      ? [['Invoice', 'Customer', 'Toko', 'Tanggal Order', 'Jatuh Tempo', 'Piutang Awal', 'Terbayar', 'Outstanding', 'Bucket', 'Hari Terlambat'],
        ...((payload.invoices as Json[] | undefined) ?? []).map((row) => [row.invoiceNo, row.customerName, row.storeName,
          row.transactionDate, row.dueDate, row.originalReceivable, row.allocatedAmount,
          row.outstanding, row.agingBucket, row.overdueDays].map(cell))]
      : [['Tanggal', 'Jenis', 'Dokumen', 'Toko', 'Jatuh Tempo', 'Keterangan', 'Debit', 'Kredit', 'Saldo Berjalan'],
        ...((payload.rows as Json[] | undefined) ?? []).map((row) => [row.businessDate, row.sourceType, row.documentNo,
          row.storeName, row.dueDate, row.description, row.debit, row.credit, row.runningBalance].map(cell))]
    const summaryRows: WorkbookCell[][] = type === 'AGING'
      ? [['Per Tanggal', cell(payload.asOf)], ['Total Outstanding', cell((payload.summary as Json | undefined)?.outstanding)], ['Total Overdue', cell((payload.summary as Json | undefined)?.overdue)]]
      : [['Customer', cell((payload.customer as Json | undefined)?.name)], ['Dari', cell(payload.dateFrom)], ['Sampai', cell(payload.asOf)], ['Saldo Awal', cell(payload.openingBalance)], ['Saldo Akhir', cell(payload.endingBalance)]]
    const workbook = createXlsx([
      { name: type === 'AGING' ? 'AR Aging' : 'Customer Statement', rows, widths: type === 'AGING' ? [20,28,22,14,14,16,16,16,18,14] : [14,14,20,22,14,30,16,16,16] },
      { name: 'Ringkasan', rows: [['Keterangan', 'Nilai'], ...summaryRows], widths: [24,28] },
    ])
    const customerName = type === 'STATEMENT' ? `_${safe((payload.customer as Json | undefined)?.name)}` : ''
    return new Response(Buffer.from(workbook), { headers: {
      'Content-Type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'Content-Disposition': `attachment; filename="${type === 'AGING' ? 'AR-Aging' : 'Customer-Statement'}${customerName}_${String(payload.asOf)}.xlsx"`,
      'Cache-Control': 'no-store',
    } })
  } catch (error) { return apiError(error) }
}
