import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { requireDataExchangeAction } from '@/lib/data-exchange-server'

const columns = [
  ['invoiceNo', 'Nomor Invoice'],
  ['invoiceStatus', 'Status Invoice'],
  ['postedAt', 'Waktu Posting'],
  ['customerName', 'Pelanggan'],
  ['storeName', 'Toko'],
  ['sourceChannel', 'Channel'],
  ['fulfillmentMode', 'Pemenuhan'],
  ['grandTotal', 'Total Akhir'],
  ['deliveryFee', 'Ongkir'],
  ['canceledAt', 'Waktu Pembatalan'],
  ['cancelReason', 'Alasan Pembatalan'],
  ['canceledByName', 'Dibatalkan Oleh'],
  ['snapshotProvenance', 'Sumber Snapshot'],
] as const

function csvCell(value: unknown) {
  const text = value == null ? '' : String(value)
  return `"${text.replaceAll('"', '""')}"`
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requireDataExchangeAction(
      caller, companyId, 'SALES_DOCUMENTS', 'EXPORT')
    const { data, error } = await caller.client.rpc('export_sales_documents')
    if (error) throw error
    const rows = Array.isArray(data) ? data as Record<string, unknown>[] : []
    const csv = [
      columns.map(([, label]) => csvCell(label)).join(','),
      ...rows.map((row) => columns.map(([key]) => csvCell(row[key])).join(',')),
    ].join('\r\n')
    return new Response(`\uFEFF${csv}`, {
      headers: {
        'Content-Type': 'text/csv; charset=utf-8',
        'Content-Disposition': 'attachment; filename="sales-invoices.csv"',
        'Cache-Control': 'private, no-store',
      },
    })
  } catch (error) {
    return apiError(error)
  }
}
