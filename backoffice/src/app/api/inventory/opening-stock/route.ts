import { apiError, requireActiveCompany, requireCaller, requirePermissionCapability } from '@/lib/server-auth'
import { readJsonObject, throwDatabaseError } from '@/lib/master-data'
import {
  openingStockRpcArgs,
  parseOpeningStockBody,
  throwOpeningStockRpcError,
} from '@/lib/opening-stock'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requirePermissionCapability(
      caller, companyId, 'inventory.opening_stock', 'VIEW',
    )
    const { data, error } = await caller.client.rpc('get_inventory_opening_stock')
    if (error) throwDatabaseError(error)
    const { data: productCosts, error: productCostError } = await caller.client
      .from('products')
      .select('id,cogs')
      .eq('company_id', companyId)
      .eq('is_active', true)
    if (productCostError) throwDatabaseError(productCostError)

    const payload = data && typeof data === 'object' && !Array.isArray(data)
      ? { ...(data as Record<string, unknown>) }
      : {}
    const defaultCostByProduct = new Map(
      (productCosts ?? []).map((product) => [product.id, product.cogs]),
    )
    payload.products = Array.isArray(payload.products)
      ? payload.products.map((product) => {
          if (!product || typeof product !== 'object' || Array.isArray(product)) return product
          const row = product as Record<string, unknown>
          return {
            ...row,
            default_unit_cost: defaultCostByProduct.get(String(row.id)) ?? null,
          }
        })
      : []
    return Response.json(payload)
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requirePermissionCapability(
      caller, companyId, 'inventory.opening_stock', 'CREATE_DRAFT',
    )
    const input = parseOpeningStockBody(await readJsonObject(request), false)
    const { data, error } = await caller.client.rpc(
      'save_opening_stock_document',
      openingStockRpcArgs(null, input),
    )
    if (error) throwOpeningStockRpcError(error)
    return Response.json({ data }, { status: 201 })
  } catch (error) {
    return apiError(error)
  }
}
