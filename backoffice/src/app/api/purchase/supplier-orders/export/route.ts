import { apiError, ApiRouteError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { throwDatabaseError } from '@/lib/master-data'
import { createXlsx, type WorkbookCell } from '@/lib/xlsx'

type JsonMap = Record<string, unknown>
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

function list(value: unknown): JsonMap[] {
  return Array.isArray(value) ? value.filter((item): item is JsonMap => Boolean(item) && typeof item === 'object' && !Array.isArray(item)) : []
}
function text(value: unknown) { return String(value ?? '') }
function number(value: unknown) { const parsed = Number(value); return Number.isFinite(parsed) ? parsed : 0 }
function date(value: unknown) { return value ? text(value).slice(0, 10) : '' }
function safeName(value: unknown) { return text(value).replace(/[^a-zA-Z0-9_-]+/g, '-').replace(/^-+|-+$/g, '') || 'COMPANY' }

function workbookResponse(payload: JsonMap, orders: JsonMap[], lines: JsonMap[], filters: JsonMap) {
  const summaryRows: WorkbookCell[][] = [[
    'No. PO', 'Tanggal Order', 'Perkiraan Datang', 'Supplier', 'Toko',
    'Gudang Tujuan', 'Status', 'Jumlah Barang', 'Total Qty Dasar',
    'Estimasi Total', 'Catatan',
  ]]
  for (const order of orders) summaryRows.push([
    text(order.orderNo), date(order.orderDate), date(order.expectedDate),
    text(order.supplierName), text(order.storeName), text(order.warehouseName),
    text(order.status), number(order.lineCount), number(order.totalOrderedBaseQty),
    number(order.estimatedTotal), text(order.notes),
  ])
  const detailRows: WorkbookCell[][] = [[
    'No. PO', 'Tanggal Order', 'Supplier', 'Toko', 'Gudang Tujuan', 'Status',
    'No. Baris', 'SKU', 'Nama Produk', 'UOM', 'Qty', 'Qty Dasar',
    'Harga Satuan Estimasi', 'Subtotal Estimasi',
  ]]
  for (const line of lines) detailRows.push([
    text(line.orderNo), date(line.orderDate), text(line.supplierName),
    text(line.storeName), text(line.warehouseName), text(line.status),
    number(line.lineNo), text(line.sku), text(line.productName), text(line.uomName),
    number(line.orderedQty), number(line.orderedBaseQty),
    number(line.estimatedUnitPrice), number(line.estimatedSubtotal),
  ])
  const metadataRows: WorkbookCell[][] = [
    ['Keterangan', 'Nilai'], ['Company', text(payload.companyName)],
    ['Kode Company', text(payload.companyCode)], ['Dibuat pada', new Date().toISOString()],
    ['Mode export', text(filters.mode)], ['Status', text(filters.status)],
    ['Tanggal mulai', text(filters.dateFrom)], ['Tanggal akhir', text(filters.dateTo)],
    ['Jumlah PO', orders.length], ['Jumlah baris barang', lines.length],
  ]
  const workbook = createXlsx([
    { name: 'Daftar PO', widths: [22, 15, 17, 28, 24, 24, 18, 14, 18, 20, 42], rows: summaryRows },
    { name: 'Detail Barang', widths: [22, 15, 28, 24, 24, 18, 10, 18, 34, 16, 14, 16, 22, 22], rows: detailRows },
    { name: 'Informasi Export', widths: [24, 48], rows: metadataRows },
  ])
  return new Response(Buffer.from(workbook), { headers: {
    'Content-Type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'Content-Disposition': `attachment; filename="Supplier-Order_${safeName(payload.companyCode)}_${new Date().toISOString().slice(0, 10)}.xlsx"`,
    'Cache-Control': 'private, no-store',
  } })
}

// Compatibility path for older clients. The current UI uses POST with exact IDs.
export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { data, error } = await caller.client.rpc('export_purchase_supplier_orders')
    if (error) throwDatabaseError(error)
    const payload = (data ?? {}) as JsonMap
    const query = new URL(request.url).searchParams
    const status = query.get('status')?.trim().toUpperCase() ?? 'ALL'
    const supplierId = query.get('supplierId')?.trim() ?? ''
    const storeId = query.get('storeId')?.trim() ?? ''
    const dateFrom = query.get('dateFrom')?.trim() ?? ''
    const dateTo = query.get('dateTo')?.trim() ?? ''
    const orders = list(payload.orders).filter((order) =>
      (status === 'ALL' || text(order.status) === status) &&
      (!supplierId || text(order.supplierId) === supplierId) &&
      (!storeId || text(order.storeId) === storeId) &&
      (!dateFrom || date(order.orderDate) >= dateFrom) &&
      (!dateTo || date(order.orderDate) <= dateTo))
    const orderIds = new Set(orders.map((order) => text(order.orderId)))
    const lines = list(payload.lines).filter((line) => orderIds.has(text(line.orderId)))
    return workbookResponse(payload, orders, lines, { mode: 'FILTER_LEGACY', status, dateFrom, dateTo })
  } catch (error) { return apiError(error) }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const body = await request.json() as { documentIds?: unknown }
    if (!Array.isArray(body.documentIds) || body.documentIds.length<1) {
      throw new ApiRouteError('SUPPLIER_ORDER_EXPORT_SELECTION_REQUIRED', 400)
    }
    if (body.documentIds.length>100) {
      throw new ApiRouteError('SUPPLIER_ORDER_EXPORT_SELECTION_LIMIT_EXCEEDED', 400)
    }
    const documentIds = body.documentIds.map((value) => {
      if (typeof value !== 'string' || !UUID.test(value)) {
        throw new ApiRouteError('SUPPLIER_ORDER_EXPORT_SELECTION_INVALID', 400)
      }
      return value.toLowerCase()
    })
    if (new Set(documentIds).size!==documentIds.length) {
      throw new ApiRouteError('SUPPLIER_ORDER_EXPORT_SELECTION_INVALID', 400)
    }
    const { data, error } = await caller.client.rpc('export_purchase_supplier_orders', {
      p_document_ids: documentIds,
    })
    if (error) throwDatabaseError(error)
    const payload = (data ?? {}) as JsonMap
    const orders = list(payload.orders)
    const lines = list(payload.lines)
    if (orders.length!==documentIds.length) throw new ApiRouteError('SUPPLIER_ORDER_EXPORT_RESULT_INVALID', 500)
    return workbookResponse(payload, orders, lines, {
      mode: 'SELECTED', status: 'PO terpilih', dateFrom: '', dateTo: '',
    })
  } catch (error) { return apiError(error) }
}
