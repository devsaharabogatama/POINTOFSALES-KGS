import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { readJsonObject, uuidValue } from '@/lib/master-data'
import {
  parseResponsiblePartyBody,
  throwDepositVarianceRpcError,
} from '@/lib/deposit-variance'

type RouteContext = { params: Promise<{ id: string }> }

export async function POST(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const input = parseResponsiblePartyBody(await readJsonObject(request))
    const { data, error } = await caller.client.rpc(
      'assign_deposit_variance_responsible_party',
      {
        p_exception_id: uuidValue(id),
        p_master_version: input.masterVersion,
        p_responsible_user_id: input.responsibleUserId,
        p_reason: input.reason,
      },
    )
    if (error) throwDepositVarianceRpcError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
