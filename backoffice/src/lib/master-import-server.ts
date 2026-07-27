import { ApiRouteError, canManageCompany, type CallerContext } from '@/lib/server-auth'

export function readObject(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new ApiRouteError('INVALID_REQUEST_BODY', 400)
  }
  return value as Record<string, unknown>
}

export async function requireImportManager(caller: CallerContext, companyId: string) {
  if (!(await canManageCompany(caller, companyId))) {
    throw new ApiRouteError('MASTER_IMPORT_ADMIN_REQUIRED', 403)
  }
}

export function throwImportError(error: { message?: string; code?: string } | null) {
  if (!error) return
  const code = error.message?.split('\n')[0] || error.code || 'MASTER_IMPORT_FAILED'
  const conflict = code.includes('MASTER_VERSION_CONFLICT') || code.includes('IDEMPOTENCY')
  throw new ApiRouteError(code, conflict ? 409 : 400)
}
