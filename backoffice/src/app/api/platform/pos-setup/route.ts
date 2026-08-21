import { ApiRouteError, apiError, requireActiveCompany, requireCaller } from '@/lib/server-auth'

type JsonObject = Record<string, unknown>

async function readBody(request: Request): Promise<JsonObject> {
  const value = await request.json().catch(() => null)
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new ApiRouteError('INVALID_REQUEST_BODY', 400)
  }
  return value as JsonObject
}

function text(value: unknown, required = false) {
  const result = typeof value === 'string' ? value.trim() : ''
  if (required && !result) throw new ApiRouteError('REQUIRED_FIELD_MISSING', 400)
  return result || null
}

function uuid(value: unknown) {
  const result = text(value)
  if (!result) return null
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(result)) {
    throw new ApiRouteError('INVALID_UUID', 400)
  }
  return result
}

function version(value: unknown) {
  if (value === null || value === undefined || value === '') return null
  const parsed = Number(value)
  if (!Number.isSafeInteger(parsed) || parsed < 1) throw new ApiRouteError('INVALID_MASTER_VERSION', 400)
  return parsed
}

function rpcFailure(message: string): never {
  const known = [
    'ACTIVE_COMPANY_CONTEXT_MISMATCH', 'PLATFORM_POS_MANAGEMENT_ACCESS_DENIED',
    'STORE_NOT_FOUND', 'ACTIVE_STORE_NOT_FOUND', 'POS_TERMINAL_NOT_FOUND',
    'DUPLICATE_STORE_CODE', 'DUPLICATE_POS_CODE', 'STORE_CODE_IMMUTABLE',
    'POS_CODE_IMMUTABLE', 'MASTER_VERSION_CONFLICT', 'TERMINAL_HAS_OPEN_SESSION',
    'TERMINAL_STORE_LOCKED_BY_HISTORY', 'STORE_HAS_ACTIVE_OPERATIONAL_DEPENDENCY',
    'INVALID_STORE_CODE', 'INVALID_STORE_NAME', 'INVALID_STORE_ADDRESS',
    'INVALID_STORE_TIMEZONE', 'INVALID_STORE_STATUS', 'INVALID_POS_CODE',
    'INVALID_POS_NAME', 'INVALID_DEVICE_IDENTIFIER', 'INVALID_POS_STATUS',
  ]
  const code = known.find((candidate) => message.includes(candidate)) ?? 'PLATFORM_POS_OPERATION_FAILED'
  const status = code.endsWith('ACCESS_DENIED') ? 403 : code === 'MASTER_VERSION_CONFLICT' ? 409 : 400
  throw new ApiRouteError(code, status)
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const { data, error } = await caller.client.rpc('get_platform_pos_setup')
    if (error) rpcFailure(error.message)
    return Response.json({ data })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    await requireActiveCompany(caller)
    const body = await readBody(request)
    const entityType = String(body.entityType ?? '').toUpperCase()

    if (entityType === 'STORE') {
      const { data, error } = await caller.client.rpc('save_platform_pos_store', {
        p_store_id: uuid(body.id),
        p_expected_version: version(body.masterVersion),
        p_store_code: text(body.code, true),
        p_store_name: text(body.name, true),
        p_address: text(body.address),
        p_timezone: text(body.timezone, true),
        p_status: text(body.status, true),
      })
      if (error) rpcFailure(error.message)
      return Response.json({ data })
    }

    if (entityType === 'TERMINAL') {
      const { data, error } = await caller.client.rpc('save_platform_pos_terminal', {
        p_terminal_id: uuid(body.id),
        p_expected_version: version(body.masterVersion),
        p_store_id: uuid(body.storeId),
        p_pos_code: text(body.code, true),
        p_pos_name: text(body.name, true),
        p_device_identifier: text(body.deviceIdentifier),
        p_status: text(body.status, true),
      })
      if (error) rpcFailure(error.message)
      return Response.json({ data })
    }

    throw new ApiRouteError('INVALID_ENTITY_TYPE', 400)
  } catch (error) {
    return apiError(error)
  }
}
