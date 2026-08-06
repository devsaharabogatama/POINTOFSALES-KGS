import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject } from '@/lib/master-data'
import {
  parseCustomerBalanceRequestBody,
  throwCustomerBalanceRpcError,
} from '@/lib/customer-balance'

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const input = parseCustomerBalanceRequestBody(await readJsonObject(request))
    const { data, error } = await caller.client.rpc(
      'request_customer_balance_correction',
      {
        p_customer_id: input.customerId,
        p_store_id: input.storeId,
        p_direction: input.direction,
        p_amount: input.amount,
        p_source_account_function: input.sourceAccountFunction,
        p_reason: input.reason,
        p_evidence_url: input.evidenceUrl,
        p_idempotency_key: input.idempotencyKey,
      },
    )
    if (error) throwCustomerBalanceRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
