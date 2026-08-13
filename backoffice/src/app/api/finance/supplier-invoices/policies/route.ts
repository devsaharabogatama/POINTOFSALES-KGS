import { apiError, requireActiveCompany, requireCaller, requirePermissionCapability } from '@/lib/server-auth'
import { throwDatabaseError } from '@/lib/master-data'
import {
  parseSaveSupplierInvoiceTolerancePolicy,
  throwSupplierInvoiceRpcError,
} from '@/lib/supplier-invoice'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const res = await caller.client.rpc('get_finance_supplier_invoices')
    if (res.error) throwDatabaseError(res.error)
    const payload = (res.data ?? {}) as { policies?: unknown[]; suppliers?: unknown[] }
    return Response.json({
      data: payload.policies ?? [],
      suppliers: payload.suppliers ?? [],
    })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)

    const body = (await request.json()) as Record<string, unknown>
    const parsed = parseSaveSupplierInvoiceTolerancePolicy(body)
    await requirePermissionCapability(caller, companyId,
      'finance.supplier_invoices', 'APPROVE')

    const res = await caller.client.rpc('save_supplier_invoice_tolerance_policy', {
      p_policy_id: parsed.policyId,
      p_master_version: parsed.masterVersion,
      p_supplier_id: parsed.supplierId,
      p_quantity_tolerance_percent: parsed.quantityTolerancePercent,
      p_quantity_tolerance_base_qty: parsed.quantityToleranceBaseQty,
      p_value_tolerance_percent: parsed.valueTolerancePercent,
      p_value_tolerance_amount: parsed.valueToleranceAmount,
      p_effective_from: parsed.effectiveFrom,
      p_is_active: parsed.isActive,
    })

    if (res.error) throwSupplierInvoiceRpcError(res.error)

    return Response.json({ success: true, data: res.data })
  } catch (error) {
    return apiError(error)
  }
}
