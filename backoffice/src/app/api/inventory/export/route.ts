import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { csvDocument } from '@/lib/master-import'
import { requireDataExchangeAction } from '@/lib/data-exchange-server'
import { throwDatabaseError } from '@/lib/master-data'

function csvResponse(content: string, fileName: string) {
  return new Response(content, {
    headers: {
      'Content-Type': 'text/csv; charset=utf-8',
      'Content-Disposition': `attachment; filename="${fileName}"`,
      'Cache-Control': 'private, no-store',
    },
  })
}

type StockBalance = {
  product_id: string
  warehouse_id: string
  stock_qty: number | string
  fifo_value: number | string
  minimum_stock_base_qty: number | string | null
  low_stock_alert_enabled: boolean
  last_movement_type: string | null
  last_movement_at: string | null
}

type Movement = {
  product_id: string
  warehouse_id: string
  qty_change: number | string
  movement_type: string
  reference_table: string
  reference_id: string
  base_uom_name_snapshot: string | null
  balance_after_base_qty: number | string | null
  posted_at: string | null
  created_at: string
  movement_status: string | null
  notes: string | null
}

type SourceDocument = {
  id: string
  document_no: string
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const typeKey = new URL(request.url).searchParams.get('type') ?? ''
    if (typeKey !== 'STOCK_REAL' && typeKey !== 'STOCK_MOVEMENTS') {
      throw new ApiRouteError('DATA_EXCHANGE_TYPE_UNSUPPORTED', 400)
    }
    await requireDataExchangeAction(caller, companyId, typeKey, 'EXPORT')
    const rpcName = typeKey === 'STOCK_REAL'
      ? 'get_inventory_stock_overview'
      : 'get_inventory_stock_movements'
    const { data, error } = await caller.client.rpc(rpcName)
    if (error) throwDatabaseError(error)

    const payload = (data ?? {}) as Record<string, unknown>
    const products = (payload.products ?? []) as Array<{ id: string; sku: string; name: string }>
    const warehouses = (payload.warehouses ?? []) as Array<{ id: string; name: string }>
    let productRows = products
    if (typeKey === 'STOCK_REAL') {
      const productResult = await caller.client.from('products')
        .select('id,sku,name').eq('company_id', companyId).limit(10000)
      if (productResult.error) throwDatabaseError(productResult.error)
      productRows = productResult.data ?? []
    }
    const productById = new Map(productRows.map((row) => [row.id, row]))
    const warehouseById = new Map(warehouses.map((row) => [row.id, row.name]))
    const date = new Date().toISOString().slice(0, 10)

    if (typeKey === 'STOCK_REAL') {
      const headers = [
        'product_sku','product_name','warehouse_name','stock_base_qty',
        'minimum_stock_base_qty','low_stock_alert_enabled','fifo_value',
        'last_movement_type','last_movement_at',
      ]
      const rows = ((payload.balances ?? []) as StockBalance[]).map((balance) => ({
        product_sku: productById.get(balance.product_id)?.sku ?? '',
        product_name: productById.get(balance.product_id)?.name ?? '',
        warehouse_name: warehouseById.get(balance.warehouse_id) ?? '',
        stock_base_qty: balance.stock_qty,
        minimum_stock_base_qty: balance.minimum_stock_base_qty,
        low_stock_alert_enabled: balance.low_stock_alert_enabled,
        fifo_value: balance.fifo_value,
        last_movement_type: balance.last_movement_type,
        last_movement_at: balance.last_movement_at,
      }))
      return csvResponse(csvDocument(headers, rows), `stock-real-${date}.csv`)
    }

    const sourceDocuments = [
      ...((payload.openingDocuments ?? []) as SourceDocument[]),
      ...((payload.transferDocuments ?? []) as SourceDocument[]),
      ...((payload.adjustmentDocuments ?? []) as SourceDocument[]),
    ]
    const sourceDocumentById = new Map(
      sourceDocuments.map((document) => [document.id, document.document_no]),
    )
    const headers = [
      'posted_at','product_sku','product_name','warehouse_name','movement_type',
      'qty_change','base_uom_name','balance_after_base_qty','source_type',
      'source_document_no','status','notes',
    ]
    const rows = ((payload.data ?? []) as Movement[]).map((movement) => ({
      posted_at: movement.posted_at ?? movement.created_at,
      product_sku: productById.get(movement.product_id)?.sku ?? '',
      product_name: productById.get(movement.product_id)?.name ?? '',
      warehouse_name: warehouseById.get(movement.warehouse_id) ?? '',
      movement_type: movement.movement_type,
      qty_change: movement.qty_change,
      base_uom_name: movement.base_uom_name_snapshot,
      balance_after_base_qty: movement.balance_after_base_qty,
      source_type: movement.reference_table,
      source_document_no: sourceDocumentById.get(movement.reference_id) ?? '',
      status: movement.movement_status,
      notes: movement.notes,
    }))
    return csvResponse(csvDocument(headers, rows), `stock-movements-${date}.csv`)
  } catch (error) {
    return apiError(error)
  }
}
