import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import {
  parseVarianceResolutionBody,
  throwDepositVarianceRpcError,
} from '@/lib/deposit-variance'

type RouteContext = { params: Promise<{ id: string }> }

export async function POST(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const input = parseVarianceResolutionBody(await readJsonObject(request))
    const { data, error } = await caller.client.rpc('resolve_deposit_variance', {
      p_exception_id: uuidValue(id),
      p_master_version: input.masterVersion,
      p_allocation_amount: input.amount,
      p_resolution_type: input.resolutionType,
      p_settlement_account_function: input.settlementAccountFunction,
      p_reason: input.reason,
      p_evidence_url: input.evidenceUrl,
      p_resolution_reference: input.resolutionReference,
      p_idempotency_key: input.idempotencyKey,
    })
    if (error) throwDepositVarianceRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
