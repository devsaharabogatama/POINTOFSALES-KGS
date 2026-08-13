import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { throwDatabaseError } from '@/lib/master-data'
import { requireDataExchangeAction } from '@/lib/data-exchange-server'

function csvCell(value: unknown) {
  const normalized = value === null || value === undefined ? '' : String(value)
  return `"${normalized.replaceAll('"', '""')}"`
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requireDataExchangeAction(caller, companyId, 'PAYMENT_METHODS', 'EXPORT')
    const { data, error } = await caller.client.rpc('export_finance_payment_methods')
    if (error) throwDatabaseError(error)
    const rows = (data ?? []) as Array<Record<string, unknown>>
    const headers = [
      'methodName', 'methodType', 'settlementRoute', 'isDefault', 'storeScope',
      'proofMode', 'feeEnabled', 'feeBearer', 'feeType', 'feePercent',
      'feeFixedAmount', 'effectiveFrom', 'effectiveTo', 'isActive', 'systemOwned',
    ]
    const csv = `\uFEFF${[
      headers.map(csvCell).join(','),
      ...rows.map((row) => headers.map((header) => csvCell(row[header])).join(',')),
    ].join('\r\n')}`
    return new Response(csv, {
      headers: {
        'Content-Type': 'text/csv; charset=utf-8',
        'Content-Disposition': 'attachment; filename="payment-methods.csv"',
        'Cache-Control': 'private, no-store',
      },
    })
  } catch (error) {
    return apiError(error)
  }
}
