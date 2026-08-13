import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, throwDatabaseError } from '@/lib/master-data'
import {
  parsePaymentMethodBody,
  paymentMethodRpcArgs,
  throwPaymentMethodRpcError,
} from '@/lib/payment-method-master'

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const result = await caller.client.rpc('get_finance_payment_methods')
    if (result.error) throwDatabaseError(result.error)
    const payload = (result.data ?? {}) as {
      companyId?: string; data?: unknown[]; stores?: unknown[]
    }
    return Response.json({
      companyId: payload.companyId ?? companyId,
      data: payload.data ?? [], stores: payload.stores ?? [],
    })
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
