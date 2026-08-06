import { apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import {
  enumValue,
  optionalText,
  readJsonObject,
  requiredVersion,
  throwDatabaseError,
  uuidValue,
} from '@/lib/master-data'

type RouteContext = { params: Promise<{ id: string }> }

export async function POST(request: Request, context: RouteContext) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { id } = await context.params
    const body = await readJsonObject(request)
    const action = enumValue(body.action, ['APPROVE', 'REJECT'] as const,
      'DEPOSIT_REVIEW_ACTION_INVALID')
    const reason = action === 'REJECT'
      ? optionalText(body, 'reason', { maxLength: 1000 }) ?? null
      : null
    if (action === 'REJECT' && !reason) {
      return Response.json(
        { error: 'DEPOSIT_REJECTION_REASON_REQUIRED' }, { status: 400 },
      )
    }
    if (typeof body.idempotencyKey !== 'string') {
      return Response.json({ error: 'IDEMPOTENCY_KEY_REQUIRED' }, { status: 400 })
    }
    const { data, error } = await caller.client.rpc('review_cash_deposit', {
      p_document_id: uuidValue(id),
      p_master_version: requiredVersion(body),
      p_action: action,
      p_reason: reason,
      p_idempotency_key: uuidValue(body.idempotencyKey),
    })
    if (error) throwDatabaseError(error)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}
