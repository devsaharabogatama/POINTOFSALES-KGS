import { apiError, ApiRouteError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { requireDataExchangeAction } from '@/lib/data-exchange-server'
import { throwDatabaseError } from '@/lib/master-data'
import { createXlsx, type WorkbookCell } from '@/lib/xlsx'

type JsonMap = Record<string, unknown>
const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/

function list(value: unknown): JsonMap[] {
  return Array.isArray(value)
    ? value.filter((item): item is JsonMap => Boolean(item) && typeof item === 'object' && !Array.isArray(item))
    : []
}
function text(value: unknown) { return String(value ?? '') }
function number(value: unknown) { const parsed = Number(value); return Number.isFinite(parsed) ? parsed : 0 }
function date(value: unknown) { return value ? text(value).slice(0, 10) : '' }
function yesNo(value: unknown) { return value === true || value === 'true' ? 'Ya' : 'Tidak' }
function safeName(value: unknown) {
  return text(value).replace(/[^a-zA-Z0-9_-]+/g, '-').replace(/^-+|-+$/g, '') || 'COMPANY'
}
function validIsoDate(value: string) {
  if (!ISO_DATE.test(value)) return false
  const [year, month, day] = value.split('-').map(Number)
  const parsed = new Date(Date.UTC(year, month - 1, day))
  return parsed.getUTCFullYear() === year
    && parsed.getUTCMonth() === month - 1
    && parsed.getUTCDate() === day
}

function workbookResponse(payload: JsonMap, invoices: JsonMap[], lines: JsonMap[], dateFrom: string, dateTo: string) {
  const invoiceRows: WorkbookCell[][] = [[
    'Nomor Invoice', 'Tanggal Invoice', 'Status', 'Kode Customer', 'Customer',
    'Toko', 'Channel', 'Pemenuhan', 'Tempo', 'Jatuh Tempo', 'Subtotal',
    'Diskon Item', 'Diskon Order', 'Total Diskon', 'Pajak', 'Ongkir',
    'Pembulatan', 'Total Akhir', 'Dibayar', 'Piutang', 'Waktu Pembatalan',
    'Alasan Pembatalan', 'Dibatalkan Oleh', 'Sumber Snapshot',
  ]]
  for (const invoice of invoices) invoiceRows.push([
    text(invoice.invoiceNo), date(invoice.invoiceDate), text(invoice.invoiceStatus),
    text(invoice.customerCode), text(invoice.customerName), text(invoice.storeName),
    text(invoice.sourceChannel), text(invoice.fulfillmentMode), yesNo(invoice.isTempo),
    date(invoice.dueDate), number(invoice.subtotal), number(invoice.itemDiscount),
    number(invoice.orderDiscount), number(invoice.totalDiscount), number(invoice.taxTotal),
    number(invoice.deliveryFee), number(invoice.roundingAdjustment), number(invoice.grandTotal),
    number(invoice.paidAmount), number(invoice.receivable), text(invoice.canceledAt),
    text(invoice.cancelReason), text(invoice.canceledByName), text(invoice.snapshotProvenance),
  ])

  const detailRows: WorkbookCell[][] = [[
    'Nomor Invoice', 'Tanggal Invoice', 'Kode Customer', 'Customer', 'No. Baris',
    'SKU', 'Produk', 'UOM', 'Qty', 'Faktor ke Dasar', 'Qty Dasar', 'Harga Satuan',
    'Diskon', 'Kode Pajak', 'Nama Pajak', 'Tarif Pajak (%)', 'Nilai Pajak', 'Total Baris',
  ]]
  for (const line of lines) detailRows.push([
    text(line.invoice_no), date(line.invoice_date), text(line.customer_code),
    text(line.customer_name), number(line.line_no), text(line.sku), text(line.product_name),
    text(line.uom_name), number(line.quantity), number(line.factor_to_base),
    number(line.quantity_base), number(line.unit_price), number(line.discount),
    text(line.tax_code), text(line.tax_name), number(line.tax_rate_percent),
    number(line.tax_amount), number(line.line_total),
  ])

  const activeCount = invoices.filter((invoice) => text(invoice.invoiceStatus) === 'ACTIVE').length
  const canceledCount = invoices.length - activeCount
  const metadataRows: WorkbookCell[][] = [
    ['Keterangan', 'Nilai'],
    ['Company', text(payload.companyName)],
    ['Kode Company', text(payload.companyCode)],
    ['Tanggal mulai', dateFrom],
    ['Tanggal akhir', dateTo],
    ['Dasar tanggal', 'Tanggal yang tampil pada Invoice sesuai pengaturan Company'],
    ['Dibuat pada', text(payload.generatedAt) || new Date().toISOString()],
    ['Jumlah Invoice', invoices.length],
    ['Invoice aktif', activeCount],
    ['Invoice dibatalkan', canceledCount],
    ['Jumlah baris produk', lines.length],
    ['Total akhir Invoice', invoices.reduce((sum, invoice) => sum + number(invoice.grandTotal), 0)],
    ['Total piutang', invoices.reduce((sum, invoice) => sum + number(invoice.receivable), 0)],
  ]

  const workbook = createXlsx([
    { name: 'Daftar Invoice', widths: [25, 16, 14, 18, 30, 24, 14, 16, 10, 16, 18, 18, 18, 18, 18, 18, 18, 20, 18, 18, 24, 34, 24, 22], rows: invoiceRows },
    { name: 'Detail Produk', widths: [25, 16, 18, 30, 10, 18, 36, 15, 14, 18, 16, 18, 18, 16, 24, 18, 18, 20], rows: detailRows },
    { name: 'Informasi Export', widths: [27, 55], rows: metadataRows },
  ])
  return new Response(Buffer.from(workbook), { headers: {
    'Content-Type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'Content-Disposition': `attachment; filename="Invoice_Penjualan_${safeName(payload.companyCode)}_${dateFrom}_${dateTo}.xlsx"`,
    'Cache-Control': 'private, no-store',
  } })
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requireDataExchangeAction(caller, companyId, 'SALES_DOCUMENTS', 'EXPORT')
    const query = new URL(request.url).searchParams
    const dateFrom = query.get('dateFrom')?.trim() ?? ''
    const dateTo = query.get('dateTo')?.trim() ?? ''
    if (!validIsoDate(dateFrom) || !validIsoDate(dateTo)) {
      throw new ApiRouteError('SALES_DOCUMENT_EXPORT_DATE_RANGE_REQUIRED', 400)
    }
    if (dateFrom > dateTo) {
      throw new ApiRouteError('SALES_DOCUMENT_EXPORT_DATE_RANGE_INVALID', 400)
    }
    const { data, error } = await caller.client.rpc('export_sales_documents', {
      p_date_from: dateFrom,
      p_date_to: dateTo,
    })
    if (error) throwDatabaseError(error)
    const payload = (data ?? {}) as JsonMap
    return workbookResponse(payload, list(payload.invoices), list(payload.lines), dateFrom, dateTo)
  } catch (error) {
    return apiError(error)
  }
}
