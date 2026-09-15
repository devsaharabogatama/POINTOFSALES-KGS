import {
  optionalText,
  readJsonObject,
  requiredVersion,
  throwDatabaseError,
  uuidValue,
} from '@/lib/master-data'
import {
  ApiRouteError,
  apiError,
  requireActiveCompany,
  requireCaller,
  requirePermissionCapability,
} from '@/lib/server-auth'
import {
  parseReceiptDispositionLines,
  throwDiscrepancyDatabaseError,
} from '@/lib/backoffice-sales-discrepancy'

function optionalDate(value: string | null, field: string) {
  if (!value) return null
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new ApiRouteError(`${field}_INVALID`, 400)
  }
  const parsed = new Date(`${value}T00:00:00.000Z`)
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value) {
    throw new ApiRouteError(`${field}_INVALID`, 400)
  }
  return value
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const url = new URL(request.url)
    const dateFrom = optionalDate(url.searchParams.get('dateFrom'), 'DELIVERY_DATE_FROM')
    const dateTo = optionalDate(url.searchParams.get('dateTo'), 'DELIVERY_DATE_TO')
    if (dateFrom && dateTo && dateFrom > dateTo) {
      throw new ApiRouteError('INVALID_DELIVERY_DATE_RANGE', 400)
    }
    const [{ data, error }, { data: discrepancyData, error: discrepancyError }] = await Promise.all([
      caller.client.rpc('get_inventory_backoffice_delivery_orders', {
        p_date_from: dateFrom,
        p_date_to: dateTo,
      }),
      caller.client.rpc('get_backoffice_sales_discrepancy_workspace', {
        p_sales_order_id: null,
        p_delivery_order_id: null,
      }),
    ])
    if (error) throwDatabaseError(error)
    if (discrepancyError) throwDiscrepancyDatabaseError(discrepancyError)
    const workspace = data ?? {
      companyId,
      workspaceVersion: 3,
      companyDate: null,
      operationsReady: false,
      data: [],
      lines: [],
    }
    return Response.json({
      ...workspace,
      discrepancyWorkspace: discrepancyData ?? {
        workspaceVersion: 1, cases: [], lines: [], taxRules: [],
      },
    })
  } catch (error) {
    return apiError(error)
  }
}

function operationFailure(message: string): never {
  const known = [
    'BACKOFFICE_DELIVERY_NOT_FOUND',
    'BACKOFFICE_DELIVERY_NOT_DISPATCHABLE',
    'BACKOFFICE_DELIVERY_ORDER_STATE_INVALID',
    'MASTER_VERSION_CONFLICT',
    'IDEMPOTENCY_KEY_REQUIRED',
    'IDEMPOTENCY_PAYLOAD_CONFLICT',
    'DISPATCH_LINES_INVALID',
    'DISPATCH_QUANTITY_EXCEEDS_REMAINING',
    'DISPATCH_EMPTY',
    'DISPATCH_NOTES_TOO_LONG',
    'INSUFFICIENT_STOCK',
    'INSUFFICIENT_FIFO_STOCK',
    'STOCK_TRANSFER_OPERATOR_REQUIRED',
    'CUSTOM_PERMISSION_DENIED',
    'CUSTOMER_RECEIPT_DATE_REQUIRED',
    'CUSTOMER_RECEIPT_DATE_FUTURE',
    'CUSTOMER_RECEIPT_DATE_BEFORE_DISPATCH',
    'CUSTOMER_RECEIPT_NOTES_TOO_LONG',
    'BACKOFFICE_DELIVERY_NOT_RECEIVABLE',
    'BACKOFFICE_DELIVERY_ALREADY_RECEIVED',
    'BACKOFFICE_RECEIPT_LINE_STATE_INVALID',
    'BACKOFFICE_RECEIPT_TRANSIT_FIFO_INSUFFICIENT',
    'BACKOFFICE_RECEIPT_TRANSIT_STOCK_INSUFFICIENT',
    'BACKOFFICE_RECEIPT_TRANSIT_WAREHOUSE_MISMATCH',
    'BACKOFFICE_RECEIPT_RESERVATION_CHANGED',
    'BACKOFFICE_RECEIPT_COST_RECONCILIATION_FAILED',
    'BACKOFFICE_RECEIPT_BASE_UOM_SNAPSHOT_INVALID',
    'BACKOFFICE_RECEIPT_CATEGORY_MISSING_OR_AMBIGUOUS',
    'BACKOFFICE_RECEIPT_RULE_SET_MISSING_OR_AMBIGUOUS',
    'BACKOFFICE_RECEIPT_DISPOSITION_LINES_INVALID',
    'BACKOFFICE_RECEIPT_DISCREPANCY_LINES_INVALID',
    'BACKOFFICE_DISCREPANCY_PHYSICAL_STATE_REQUIRED',
    'BACKOFFICE_DISCREPANCY_ACTION_INVALID',
    'BACKOFFICE_DISCREPANCY_ACTUAL_PRODUCT_REQUIRED',
    'BACKOFFICE_DISCREPANCY_ACTUAL_PRODUCT_INVALID',
  ].find((code) => message.includes(code))
  const code = known ?? 'BACKOFFICE_DELIVERY_OPERATION_FAILED'
  const status = code === 'BACKOFFICE_DELIVERY_NOT_FOUND' ? 404
    : ['MASTER_VERSION_CONFLICT', 'IDEMPOTENCY_PAYLOAD_CONFLICT'].includes(code) ? 409
      : code === 'CUSTOM_PERMISSION_DENIED' ? 403 : 400
  throw new ApiRouteError(code, status)
}

export async function PATCH(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requirePermissionCapability(
      caller, companyId, 'inventory.delivery_documents', 'MANAGE',
    )
    const body = await readJsonObject(request)
    const action = String(body.action ?? 'DISPATCH').trim().toUpperCase()
    if (action === 'RESOLVE_SHORTAGE' || action === 'RESOLVE_OVERAGE_WRONG_ITEM') {
      const discrepancyId = uuidValue(String(body.discrepancyId ?? ''),
        'BACKOFFICE_DISCREPANCY_NOT_FOUND')
      const operationId = uuidValue(String(body.operationId ?? ''),
        'IDEMPOTENCY_KEY_REQUIRED')
      const scheduledDate = optionalDate(
        String(body.scheduledDate ?? ''), 'BACKOFFICE_DISCREPANCY_SCHEDULED_DATE',
      )
      const notes = optionalText(body, 'notes', { maxLength: 500 }) ?? null
      const rpc = action === 'RESOLVE_SHORTAGE'
        ? 'resolve_backoffice_sales_shortage'
        : 'resolve_backoffice_sales_overage_wrong_item'
      const args = action === 'RESOLVE_SHORTAGE' ? {
        p_discrepancy_id: discrepancyId,
        p_expected_version: requiredVersion(body),
        p_operation_id: operationId,
        p_backorder_date: scheduledDate,
        p_notes: notes,
      } : {
        p_discrepancy_id: discrepancyId,
        p_expected_version: requiredVersion(body),
        p_operation_id: operationId,
        p_replacement_date: scheduledDate,
        p_notes: notes,
      }
      const { data, error } = await caller.client.rpc(rpc, args)
      if (error) throwDiscrepancyDatabaseError(error)
      return Response.json({ companyId, data })
    }
    if (action === 'RECEIVE_DISPOSITION') {
      const acceptedDate = optionalDate(
        String(body.acceptedDate ?? ''), 'CUSTOMER_RECEIPT_DATE',
      )
      if (!acceptedDate) throw new ApiRouteError('CUSTOMER_RECEIPT_DATE_REQUIRED', 400)
      const { data, error } = await caller.client.rpc(
        'receive_backoffice_sales_delivery', {
          p_delivery_order_id: uuidValue(String(body.deliveryOrderId ?? ''),
            'BACKOFFICE_DELIVERY_NOT_FOUND'),
          p_expected_version: requiredVersion(body),
          p_operation_id: uuidValue(String(body.operationId ?? ''),
            'IDEMPOTENCY_KEY_REQUIRED'),
          p_accepted_date: acceptedDate,
          p_lines: parseReceiptDispositionLines(body.lines),
          p_notes: optionalText(body, 'notes', { maxLength: 500 }) ?? null,
        },
      )
      if (error) throwDiscrepancyDatabaseError(error)
      return Response.json({ companyId, data })
    }
    if (action === 'RECEIVE') {
      const acceptedDate = optionalDate(
        String(body.acceptedDate ?? ''), 'CUSTOMER_RECEIPT_DATE',
      )
      if (!acceptedDate) throw new ApiRouteError('CUSTOMER_RECEIPT_DATE_REQUIRED', 400)
      const { data, error } = await caller.client.rpc(
        'receive_backoffice_sales_delivery', {
          p_delivery_order_id: uuidValue(String(body.deliveryOrderId ?? ''),
            'BACKOFFICE_DELIVERY_NOT_FOUND'),
          p_expected_version: requiredVersion(body),
          p_operation_id: uuidValue(String(body.operationId ?? ''),
            'IDEMPOTENCY_KEY_REQUIRED'),
          p_accepted_date: acceptedDate,
          p_notes: optionalText(body, 'notes', { maxLength: 500 }) ?? null,
        },
      )
      if (error) operationFailure(error.message)
      return Response.json({ companyId, data })
    }
    if (action !== 'DISPATCH') {
      throw new ApiRouteError('BACKOFFICE_DELIVERY_ACTION_INVALID', 400)
    }
    const rawLines = body.lines
    if (!Array.isArray(rawLines) || rawLines.length === 0 || rawLines.length > 500) {
      throw new ApiRouteError('DISPATCH_LINES_INVALID', 400)
    }
    const lines = rawLines.map((raw) => {
      if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
        throw new ApiRouteError('DISPATCH_LINES_INVALID', 400)
      }
      const row = raw as Record<string, unknown>
      const quantityUom = Number(row.quantityUom)
      if (!Number.isFinite(quantityUom) || quantityUom <= 0) {
        throw new ApiRouteError('DISPATCH_LINES_INVALID', 400)
      }
      return {
        deliveryLineId: uuidValue(String(row.deliveryLineId ?? ''),
          'DISPATCH_LINES_INVALID'),
        quantityUom,
      }
    })
    const { data, error } = await caller.client.rpc(
      'dispatch_backoffice_sales_delivery', {
        p_delivery_order_id: uuidValue(String(body.deliveryOrderId ?? ''),
          'BACKOFFICE_DELIVERY_NOT_FOUND'),
        p_expected_version: requiredVersion(body),
        p_operation_id: uuidValue(String(body.operationId ?? ''),
          'IDEMPOTENCY_KEY_REQUIRED'),
        p_lines: lines,
        p_notes: optionalText(body, 'notes', { maxLength: 500 }) ?? null,
      },
    )
    if (error) operationFailure(error.message)
    return Response.json({ companyId, data })
  } catch (error) {
    return apiError(error)
  }
}
