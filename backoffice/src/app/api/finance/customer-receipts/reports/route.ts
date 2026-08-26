import { apiError, requireActiveCompany, requireCaller, requirePermissionCapability } from '@/lib/server-auth'
import { throwDatabaseError } from '@/lib/master-data'

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const datePattern = /^\d{4}-\d{2}-\d{2}$/

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

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requirePermissionCapability(caller, companyId, 'finance.customer_receipts', 'VIEW')
    const url = new URL(request.url)
    const customerId = optionalUuid(url.searchParams.get('customerId'))
    const storeId = optionalUuid(url.searchParams.get('storeId'))
    const asOf = optionalDate(url.searchParams.get('asOf'))
    const dateFrom = optionalDate(url.searchParams.get('dateFrom'))
    const aging = await caller.client.rpc('get_finance_ar_aging', {
      p_as_of: asOf, p_customer_id: customerId, p_store_id: storeId,
    })
    if (aging.error) throwDatabaseError(aging.error)
    let statement: unknown = null
    if (customerId) {
      const result = await caller.client.rpc('get_finance_customer_statement', {
        p_customer_id: customerId, p_date_from: dateFrom,
        p_as_of: asOf, p_store_id: storeId,
      })
      if (result.error) throwDatabaseError(result.error)
      statement = result.data
    }
    return Response.json({ aging: aging.data, statement })
  } catch (error) { return apiError(error) }
}
