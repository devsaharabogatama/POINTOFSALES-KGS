import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { requireDataExchangeAction } from '@/lib/data-exchange-server'

const columns = [
  ['pricelistName', 'Nama Pricelist'],
  ['scope', 'Jenis'],
  ['priority', 'Prioritas'],
  ['isDefault', 'Default Global'],
  ['storeScope', 'Cakupan Toko'],
  ['validFrom', 'Mulai Berlaku'],
  ['validUntil', 'Akhir Berlaku'],
  ['isActive', 'Pricelist Aktif'],
  ['productName', 'Produk'],
  ['uomName', 'Satuan'],
  ['minimumQty', 'Minimum Qty'],
  ['quantityBasis', 'Basis Qty'],
  ['pricingMethod', 'Metode Harga'],
  ['finalUnitPrice', 'Harga Akhir'],
  ['discountAmountPerUnit', 'Potongan per Unit'],
  ['discountPercent', 'Potongan Persen'],
  ['ruleActive', 'Rule Aktif'],
] as const

function csvCell(value: unknown) {
  const text = value == null ? '' : String(value)
  return `"${text.replaceAll('"', '""')}"`
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requireDataExchangeAction(caller, companyId, 'PRICELISTS', 'EXPORT')
    const { data, error } = await caller.client.rpc('export_sales_pricelists')
    if (error) throw error
    const rows = Array.isArray(data) ? data as Record<string, unknown>[] : []
    const csv = [
      columns.map(([, label]) => csvCell(label)).join(','),
      ...rows.map((row) => columns.map(([key]) => csvCell(row[key])).join(',')),
    ].join('\r\n')
    return new Response(`\uFEFF${csv}`, {
      headers: {
        'Content-Type': 'text/csv; charset=utf-8',
        'Content-Disposition': 'attachment; filename="pricelists.csv"',
        'Cache-Control': 'private, no-store',
      },
    })
  } catch (error) {
    return apiError(error)
  }
}
