import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, throwDatabaseError } from '@/lib/master-data'
import {
  minimumStockRpcArgs,
  parseMinimumStockBody,
  throwMinimumStockRpcError,
} from '@/lib/minimum-stock'

const fields = `
  id,company_id,product_id,warehouse_id,minimum_stock_base_qty,
  low_stock_alert_enabled,master_version,created_at,updated_at
`

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const { data, error } = await caller.client
      .from('product_warehouse_stock_settings')
      .select(fields)
      .eq('company_id', companyId)
      .order('updated_at', { ascending: false })
      .limit(5000)
    if (error) throwDatabaseError(error)
    return Response.json({ companyId, data: data ?? [] })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const input = parseMinimumStockBody(await readJsonObject(request), false)
    const { data, error } = await caller.client.rpc(
      'save_product_warehouse_stock_setting',
      minimumStockRpcArgs(null, input),
    )
    if (error) throwMinimumStockRpcError(error)
    return Response.json({ data }, { status: 201 })
  } catch (error) {
    return apiError(error)
  }
}
