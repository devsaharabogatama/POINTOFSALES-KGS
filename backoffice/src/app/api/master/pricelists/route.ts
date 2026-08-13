import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { parseIncludeInactive, readJsonObject } from '@/lib/master-data'
import { parsePricelistBody, pricelistRpcArgs, throwPricelistRpcError } from '@/lib/pricelist-master'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { data, error } = await caller.client.rpc('get_sales_pricelists', {
      p_include_inactive: parseIncludeInactive(request),
    })
    if (error) throw error
    return Response.json(data)
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const input = parsePricelistBody(await readJsonObject(request), false)
    const { data, error } = await caller.client.rpc(
      'save_reusable_pricelist_with_rules', pricelistRpcArgs(null, input),
    )
    if (error) throwPricelistRpcError(error)
    return Response.json({ data }, { status: 201 })
  } catch (error) {
    return apiError(error)
  }
}
