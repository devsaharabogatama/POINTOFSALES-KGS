import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { throwDatabaseError } from '@/lib/master-data'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const [
      { data: balances, error: balanceError },
      { data: warehouses, error: warehouseError },
      { data: batches, error: batchError },
      { data: movements, error: movementError },
    ] = await Promise.all([
      caller.client
        .from('product_stocks')
        .select('id,product_id,warehouse_id,stock_qty,updated_at')
        .eq('company_id', companyId)
        .order('updated_at', { ascending: false })
        .limit(10000),
      caller.client
        .from('warehouses')
        .select('id,name,warehouse_type,location,is_active')
        .eq('company_id', companyId)
        .order('name')
        .limit(5000),
      caller.client
        .from('product_batches')
        .select('id,product_id,warehouse_id,qty_remaining,cogs_unit,created_at')
        .eq('company_id', companyId)
        .gt('qty_remaining', 0)
        .limit(20000),
      caller.client
        .from('stock_movements')
        .select(
          'id,product_id,warehouse_id,movement_type,qty_change,reference_table,reference_id,created_at',
        )
        .eq('company_id', companyId)
        .order('created_at', { ascending: false })
        .limit(20000),
    ])
    if (balanceError) throwDatabaseError(balanceError)
    if (warehouseError) throwDatabaseError(warehouseError)
    if (batchError) throwDatabaseError(batchError)
    if (movementError) throwDatabaseError(movementError)
    return Response.json({
      companyId,
      balances: balances ?? [],
      warehouses: warehouses ?? [],
      batches: batches ?? [],
      movements: movements ?? [],
    })
  } catch (error) {
    return apiError(error)
  }
}
