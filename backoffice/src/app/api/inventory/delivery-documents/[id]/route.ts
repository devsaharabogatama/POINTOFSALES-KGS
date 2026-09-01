import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { enumValue, optionalText, readJsonObject, requiredText, requiredVersion, uuidValue } from '@/lib/master-data'

type RouteContext = { params: Promise<{ id: string }> }

function rpcFailure(message: string): never {
  const known = ['SALES_DELIVERY_NOT_FOUND', 'MASTER_VERSION_CONFLICT',
    'INVALID_SALES_DELIVERY_TRANSITION', 'CANCEL_REASON_REQUIRED',
    'CUSTOM_PERMISSION_DENIED', 'USE_CANONICAL_DISPATCH_RUNTIME',
    'SALES_DELIVERY_NOT_DISPATCHABLE', 'SALES_ORDER_NOT_DISPATCHABLE',
    'DELIVERY_WAREHOUSE_SCOPE_DENIED', 'DISPATCH_LINES_INVALID',
    'DUPLICATE_DISPATCH_LINE', 'DISPATCH_LINE_SCOPE_INVALID',
    'DISPATCH_QUANTITY_EXCEEDS_REMAINING', 'MASTER_VERSION_CONFLICT',
    'IDEMPOTENCY_PAYLOAD_CONFLICT', 'DELIVERY_RECEIVER_REQUIRED',
    'FULL_DISPATCH_REQUIRED', 'CANCEL_LINKED_ORDER_FROM_POS_REQUIRED',
    'RESERVATION_COMMERCIAL_LINEAGE_INVALID',
    'DISPATCH_RESERVATION_QUANTITY_INVALID',
    'BUNDLE_COMPONENT_PRICE_REFERENCE_INVALID', 'FIFO_STOCK_CHANGED',
    'NEGATIVE_STOCK_PERMISSION_SNAPSHOT_MISSING',
    'NEGATIVE_STOCK_PROVISIONAL_COST_NOT_FOUND',
    'STOCK_MOVEMENT_SNAPSHOT_INCOMPLETE', 'DISPATCH_EMPTY',
    'DISPATCH_FINANCE_SOURCE_NOT_FOUND',
    'DISPATCH_FINANCE_ALLOCATION_INCOMPLETE',
    'DISPATCH_FINANCE_STOCK_RESULT_MISMATCH',
    'DISPATCH_FINANCE_COST_RECONCILIATION_FAILED',
    'DISPATCH_COMMERCIAL_LINEAGE_INVALID',
    'DISPATCH_COMMERCIAL_AMOUNT_INVALID',
    'DISPATCH_SETTLEMENT_AMOUNT_INVALID',
    'DISPATCH_TRANSACTION_CATEGORY_MISSING_OR_AMBIGUOUS',
    'DISPATCH_FINANCIAL_EFFECT_NOT_FOUND', 'DISPATCH_EVENT_NOT_HOLD',
    'DISPATCH_SURCHARGE_RECONCILIATION_FAILED',
    'DISPATCH_EVENT_REBALANCE_FAILED', 'PREDISPATCH_ADVANCE_EVENT_NOT_POSTED',
    'ODR_AUTOMATIC_POSTING_NOT_READY']
  const code = known.find((candidate) => message.includes(candidate))
  throw new ApiRouteError(code ?? 'SALES_DELIVERY_OPERATION_FAILED',
    code === 'CUSTOM_PERMISSION_DENIED' ? 403 : code === 'MASTER_VERSION_CONFLICT' ? 409 : 400)
}

export async function GET(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const salesId = uuidValue((await context.params).id)
    const { data, error } = await caller.client.rpc('get_inventory_delivery_document', {
      p_sales_id: salesId,
    })
    if (error) rpcFailure(error.message)
    return Response.json({ companyId, delivery: data })
  } catch (error) {
    return apiError(error)
  }
}

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const salesId = uuidValue((await context.params).id)
    const body = await readJsonObject(request)
    const action = enumValue(body.action, ['DISPATCH', 'DELIVER', 'CANCEL'] as const,
      'INVALID_SALES_DELIVERY_ACTION')
    const reason = action === 'CANCEL'
      ? requiredText(body, 'reason', { maxLength: 500 })
      : optionalText(body, 'reason', { maxLength: 500 }) ?? null
    const deliveryDocumentId = uuidValue(String(body.deliveryDocumentId ?? ''))
    const masterVersion = requiredVersion(body)
    const [workspaceResult, documentResult] = await Promise.all([
      caller.client.rpc('get_inventory_delivery_dispatch_workspace', {
        p_date_from: null, p_date_to: null,
      }),
      caller.client.rpc('get_inventory_delivery_documents', {
        p_date_from: null, p_date_to: null,
      }),
    ])
    if (workspaceResult.error) rpcFailure(workspaceResult.error.message)
    if (documentResult.error) rpcFailure(documentResult.error.message)
    const documents = documentResult.data as {
      data?: Array<{ deliveryDocumentId?: string; salesId?: string }>
    } | null
    const authoritativeDocument = (documents?.data ?? []).find((document) =>
      document.deliveryDocumentId === deliveryDocumentId)
    if (!authoritativeDocument || authoritativeDocument.salesId !== salesId) {
      throw new ApiRouteError('SALES_DELIVERY_NOT_FOUND', 404)
    }
    const workspace = workspaceResult.data as {
      deliveries?: Array<{ id?: string; sales_id?: string; reservation_id?: string }>
    } | null
    const canonicalDelivery = (workspace?.deliveries ?? []).find((delivery) =>
      delivery.id === deliveryDocumentId)
    if (canonicalDelivery && canonicalDelivery.sales_id !== salesId) {
      throw new ApiRouteError('SALES_DELIVERY_NOT_FOUND', 404)
    }
    const linked = Boolean(canonicalDelivery?.reservation_id)

    let result: { data: unknown; error: { message: string } | null }
    if (linked && action === 'DISPATCH') {
      const rawLines = body.lines
      if (!Array.isArray(rawLines) || rawLines.length === 0 || rawLines.length > 500) {
        throw new ApiRouteError('DISPATCH_LINES_INVALID', 400)
      }
      const lines = rawLines.map((raw) => {
        if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
          throw new ApiRouteError('DISPATCH_LINES_INVALID', 400)
        }
        const row = raw as Record<string, unknown>
        const quantity = Number(row.quantityUom)
        if (!Number.isFinite(quantity) || quantity <= 0) {
          throw new ApiRouteError('DISPATCH_LINES_INVALID', 400)
        }
        return {
          deliveryLineId: uuidValue(String(row.deliveryLineId ?? ''),
            'DISPATCH_LINE_SCOPE_INVALID'),
          quantityUom: quantity,
        }
      })
      result = await caller.client.rpc('dispatch_sales_delivery', {
        p_delivery_document_id: deliveryDocumentId,
        p_master_version: masterVersion,
        p_idempotency_key: uuidValue(String(body.idempotencyKey ?? ''),
          'IDEMPOTENCY_KEY_REQUIRED'),
        p_lines: lines,
        p_notes: reason,
      })
    } else if (linked && action === 'DELIVER') {
      result = await caller.client.rpc('confirm_sales_delivery_received', {
        p_delivery_document_id: deliveryDocumentId,
        p_master_version: masterVersion,
        p_recipient_name: requiredText(body, 'recipientName', { maxLength: 200 }),
        p_notes: reason,
      })
    } else if (linked) {
      throw new ApiRouteError('CANCEL_LINKED_ORDER_FROM_POS_REQUIRED', 409)
    } else {
      result = await caller.client.rpc('update_sales_delivery_status', {
        p_delivery_document_id: deliveryDocumentId,
        p_master_version: masterVersion, p_action: action, p_reason: reason,
      })
    }
    const { data, error } = result
    if (error) rpcFailure(error.message)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    uuidValue((await context.params).id)
    const body = await readJsonObject(request)
    const { data, error } = await caller.client.rpc('record_inventory_delivery_print', {
      p_delivery_document_id: uuidValue(String(body.deliveryDocumentId ?? '')),
    })
    if (error) rpcFailure(error.message)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
