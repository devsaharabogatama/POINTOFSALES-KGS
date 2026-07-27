import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import {
  parsePaymentMethodBody,
  paymentMethodRpcArgs,
  throwPaymentMethodRpcError,
} from '@/lib/payment-method-master'

type RouteContext = { params: Promise<{ id: string }> }

export async function PATCH(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const paymentMethodId = uuidValue(id)
    const input = parsePaymentMethodBody(await readJsonObject(request), true)
    const { data, error } = await caller.client.rpc(
      'save_payment_method', paymentMethodRpcArgs(paymentMethodId, input),
    )
    if (error) throwPaymentMethodRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
