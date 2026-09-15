import {
  ApiRouteError,
  apiError,
  createAdminClient,
  requireActiveCompany,
  requireCaller,
} from '@/lib/server-auth'
import {
  enumValue,
  integerValue,
  readJsonObject,
  requiredText,
  uuidValue,
} from '@/lib/master-data'

const PROCESS_MODES = [
  'RETAIL_CONFIRM_INVOICE',
  'BACKOFFICE_DELIVERED_QTY_INVOICE',
] as const
const ACTIONS = ['CREATE', 'REFRESH', 'CANCEL', 'APPLY'] as const

type ProcessMode = (typeof PROCESS_MODES)[number]
type RpcError = { message?: string } | null

async function requireSuperAdmin(
  caller: Awaited<ReturnType<typeof requireCaller>>,
) {
  const { data, error } = await caller.client
    .from('profiles')
    .select('role')
    .eq('id', caller.user.id)
    .single()
  if (error) throw new ApiRouteError(error.message, 500)
  if (data.role !== 'super_admin') {
    throw new ApiRouteError('SALES_PROCESS_CUTOVER_SUPER_ADMIN_REQUIRED', 403)
  }
}

function throwCutoverError(error: RpcError): never {
  const message = error?.message ?? 'SALES_PROCESS_CUTOVER_OPERATION_FAILED'
  const codes = [
    'AUTHENTICATION_REQUIRED',
    'ACTIVE_COMPANY_NOT_FOUND',
    'SALES_PROCESS_CUTOVER_SUPER_ADMIN_REQUIRED',
    'SALES_PROCESS_CUTOVER_PLAN_NOT_FOUND',
    'SALES_PROCESS_SETTING_NOT_FOUND',
    'SALES_PROCESS_CUTOVER_TARGET_INVALID',
    'SALES_PROCESS_CUTOVER_EFFECTIVE_AT_INVALID',
    'SALES_PROCESS_CUTOVER_EFFECTIVE_AT_NOT_REACHED',
    'SALES_PROCESS_CUTOVER_REASON_INVALID',
    'SALES_PROCESS_CUTOVER_OPEN_PLAN_EXISTS',
    'SALES_PROCESS_CUTOVER_PLAN_NOT_REFRESHABLE',
    'SALES_PROCESS_CUTOVER_PLAN_NOT_CANCELABLE',
    'SALES_PROCESS_CUTOVER_PLAN_NOT_APPLICABLE',
    'SALES_PROCESS_CUTOVER_PLAN_VERSION_STALE',
    'SALES_PROCESS_CUTOVER_SETTINGS_VERSION_STALE',
    'SALES_PROCESS_CUTOVER_PREVIEW_VERSION_DRIFT',
    'SALES_PROCESS_CUTOVER_PREVIEW_STALE',
    'SALES_PROCESS_CUTOVER_ACTIVE_FINANCE_QUEUE',
    'SALES_PROCESS_CUTOVER_NONTERMINAL_OFFLINE_SUBMISSION',
    'SALES_PROCESS_CUTOVER_IDEMPOTENCY_PAYLOAD_CONFLICT',
    'BACKOFFICE_SALES_FEATURE_NOT_ENABLED',
  ] as const
  const code = codes.find((candidate) => message.includes(candidate))
  if (!code) throw new ApiRouteError('SALES_PROCESS_CUTOVER_OPERATION_FAILED', 500)
  const status = code.endsWith('SUPER_ADMIN_REQUIRED') ? 403
    : code.endsWith('_NOT_FOUND') ? 404
      : code.includes('STALE') || code.includes('VERSION') ||
          code.includes('OPEN_PLAN') || code.includes('NOT_APPLICABLE') ||
          code.includes('NOT_REFRESHABLE') || code.includes('NOT_CANCELABLE') ||
          code.includes('QUEUE') || code.includes('OFFLINE_SUBMISSION') ||
          code.includes('IDEMPOTENCY')
        ? 409
        : 400
  throw new ApiRouteError(code, status)
}

function version(value: unknown, code: string) {
  return integerValue(value, code, 1, Number.MAX_SAFE_INTEGER)
}

async function getPlan(
  caller: Awaited<ReturnType<typeof requireCaller>>,
  planId: string | undefined,
) {
  if (!planId) return null
  const { data, error } = await caller.client.rpc('get_sales_process_cutover_plan', {
    p_plan_id: planId,
  })
  if (error) throwCutoverError(error)
  return data
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireSuperAdmin(caller)
    const companyId = await requireActiveCompany(caller)
    const admin = createAdminClient()
    const [settingResult, planRowsResult] = await Promise.all([
      admin.from('company_sales_process_settings')
        .select('active_mode,mode_effective_at,master_version,updated_at')
        .eq('company_id', companyId)
        .single(),
      admin.from('sales_process_cutover_plans')
        .select('id,status,created_at')
        .eq('company_id', companyId)
        .order('created_at', { ascending: false })
        .limit(20),
    ])
    if (settingResult.error) throw new ApiRouteError(settingResult.error.message, 500)
    if (planRowsResult.error) throw new ApiRouteError(planRowsResult.error.message, 500)

    const activeMode = settingResult.data.active_mode as ProcessMode
    const targetMode: ProcessMode = activeMode === 'RETAIL_CONFIRM_INVOICE'
      ? 'BACKOFFICE_DELIVERED_QTY_INVOICE'
      : 'RETAIL_CONFIRM_INVOICE'
    const rows = planRowsResult.data ?? []
    const openId = rows.find((row) =>
      ['DRAFT', 'PREVIEWED', 'APPLYING'].includes(row.status),
    )?.id
    const latestId = rows[0]?.id
    const [previewResult, openPlan, latestPlan] = await Promise.all([
      caller.client.rpc('get_sales_process_cutover_preview', {
        p_target_mode: targetMode,
      }),
      getPlan(caller, openId),
      latestId === openId ? Promise.resolve(null) : getPlan(caller, latestId),
    ])
    if (previewResult.error) throwCutoverError(previewResult.error)

    return Response.json({
      companyId,
      serverNow: new Date().toISOString(),
      setting: {
        activeMode,
        modeEffectiveAt: settingResult.data.mode_effective_at,
        masterVersion: Number(settingResult.data.master_version),
        updatedAt: settingResult.data.updated_at,
      },
      targetMode,
      preview: previewResult.data,
      openPlan,
      latestPlan: openPlan ?? latestPlan,
    })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireSuperAdmin(caller)
    await requireActiveCompany(caller)
    const body = await readJsonObject(request)
    const action = enumValue(body.action, ACTIONS, 'SALES_PROCESS_CUTOVER_ACTION_INVALID')
    const operationId = uuidValue(
      typeof body.operationId === 'string' ? body.operationId : '',
      'SALES_PROCESS_CUTOVER_OPERATION_ID_REQUIRED',
    )
    let result: { data: unknown; error: RpcError }

    if (action === 'CREATE') {
      const targetMode = enumValue(
        body.targetMode,
        PROCESS_MODES,
        'SALES_PROCESS_CUTOVER_TARGET_INVALID',
      )
      const effectiveAt = typeof body.effectiveAt === 'string'
        ? new Date(body.effectiveAt)
        : new Date(Number.NaN)
      if (!Number.isFinite(effectiveAt.getTime())) {
        throw new ApiRouteError('SALES_PROCESS_CUTOVER_EFFECTIVE_AT_INVALID', 400)
      }
      const reason = requiredText(body, 'reason', { maxLength: 500 })
      result = await caller.client.rpc('create_sales_process_cutover_plan', {
        p_target_mode: targetMode,
        p_effective_at: effectiveAt.toISOString(),
        p_expected_settings_version: version(
          body.settingsVersion,
          'SALES_PROCESS_CUTOVER_SETTINGS_VERSION_REQUIRED',
        ),
        p_operation_id: operationId,
        p_reason: reason,
      })
    } else {
      const planId = uuidValue(
        typeof body.planId === 'string' ? body.planId : '',
        'SALES_PROCESS_CUTOVER_PLAN_ID_REQUIRED',
      )
      const planVersion = version(
        body.planVersion,
        'SALES_PROCESS_CUTOVER_PLAN_VERSION_REQUIRED',
      )
      if (action === 'REFRESH') {
        result = await caller.client.rpc('refresh_sales_process_cutover_plan', {
          p_plan_id: planId,
          p_expected_plan_version: planVersion,
          p_expected_settings_version: version(
            body.settingsVersion,
            'SALES_PROCESS_CUTOVER_SETTINGS_VERSION_REQUIRED',
          ),
          p_operation_id: operationId,
        })
      } else if (action === 'CANCEL') {
        result = await caller.client.rpc('cancel_sales_process_cutover_plan', {
          p_plan_id: planId,
          p_expected_plan_version: planVersion,
          p_operation_id: operationId,
          p_cancel_reason: requiredText(body, 'reason', { maxLength: 500 }),
        })
      } else {
        result = await caller.client.rpc('apply_sales_process_cutover_plan', {
          p_plan_id: planId,
          p_expected_plan_version: planVersion,
          p_expected_settings_version: version(
            body.settingsVersion,
            'SALES_PROCESS_CUTOVER_SETTINGS_VERSION_REQUIRED',
          ),
          p_operation_id: operationId,
        })
      }
    }
    if (result.error) throwCutoverError(result.error)
    return Response.json({ data: result.data })
  } catch (error) {
    return apiError(error)
  }
}
