import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { parseIncludeInactive, readJsonObject, throwDatabaseError } from '@/lib/master-data'
import {
  parsePaymentMethodBody,
  paymentMethodRpcArgs,
  throwPaymentMethodRpcError,
} from '@/lib/payment-method-master'

const fields = `id,company_id,payment_method_code,payment_method_name,method_type,
  settlement_route,is_default,available_all_stores,proof_mode,fee_enabled,
  fee_bearer,fee_type,fee_percent,fee_fixed_amount,clearing_account_function,
  bank_account_function,effective_from,effective_to,is_active,is_system_method,
  master_version,created_at,updated_at`

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    let methodQuery = caller.client.from('payment_methods').select(fields)
      .eq('company_id', companyId).order('is_default', { ascending: false })
      .order('payment_method_name').limit(300)
    if (!parseIncludeInactive(request)) methodQuery = methodQuery.eq('is_active', true)

    const [methodsResult, assignmentsResult, storesResult] = await Promise.all([
      methodQuery,
      caller.client.from('payment_method_store_assignments')
        .select('id,payment_method_id,store_id')
        .eq('company_id', companyId).limit(1000),
      caller.client.from('stores').select('id,store_code,store_name,status')
        .eq('company_id', companyId).eq('status', 'ACTIVE')
        .order('store_name').limit(300),
    ])
    for (const result of [methodsResult, assignmentsResult, storesResult]) {
      if (result.error) throwDatabaseError(result.error)
    }
    const assignments = assignmentsResult.data ?? []
    const data = (methodsResult.data ?? []).map((method) => ({
      ...method,
      store_assignments: assignments.filter(
        (row) => row.payment_method_id === method.id,
      ),
    }))
    return Response.json({ companyId, data, stores: storesResult.data ?? [] })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const input = parsePaymentMethodBody(await readJsonObject(request), false)
    const { data, error } = await caller.client.rpc(
      'save_payment_method', paymentMethodRpcArgs(null, input),
    )
    if (error) throwPaymentMethodRpcError(error)
    return Response.json({ data }, { status: 201 })
  } catch (error) {
    return apiError(error)
  }
}
