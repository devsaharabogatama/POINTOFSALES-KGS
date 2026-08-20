import 'server-only'

import { createHash } from 'node:crypto'
import type { CallerContext } from '@/lib/server-auth'
import { ApiRouteError, canManageCompany, createAdminClient } from '@/lib/server-auth'

const BUCKET = 'company-branding'
const MAX_FILE_BYTES = 2 * 1024 * 1024

export type BrandingProfile = {
  companyId: string
  hasLogo: boolean
  showLogoOnDocuments: boolean
  showStampOnDocuments: boolean
  logoObjectPath: string | null
  logoPublicUrl: string | null
  logoMimeType: string | null
  logoSizeBytes: number | null
  logoChecksumSha256: string | null
  logoVersion: number
  masterVersion: number | null
  uploadedAt: string | null
  updatedAt: string | null
}

type DetectedImage = {
  mimeType: 'image/png' | 'image/jpeg' | 'image/webp'
  extension: 'png' | 'jpg' | 'webp'
}

function detectImage(bytes: Uint8Array): DetectedImage | null {
  if (
    bytes.length >= 8 &&
    bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e &&
    bytes[3] === 0x47 && bytes[4] === 0x0d && bytes[5] === 0x0a &&
    bytes[6] === 0x1a && bytes[7] === 0x0a
  ) return { mimeType: 'image/png', extension: 'png' }

  if (
    bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8 &&
    bytes[2] === 0xff
  ) return { mimeType: 'image/jpeg', extension: 'jpg' }

  if (
    bytes.length >= 12 &&
    String.fromCharCode(...bytes.slice(0, 4)) === 'RIFF' &&
    String.fromCharCode(...bytes.slice(8, 12)) === 'WEBP'
  ) return { mimeType: 'image/webp', extension: 'webp' }

  return null
}

function fileExtension(name: string): string {
  const match = name.toLowerCase().match(/\.([a-z0-9]+)$/)
  return match?.[1] ?? ''
}

function extensionMatches(extension: string, detected: DetectedImage): boolean {
  if (detected.mimeType === 'image/jpeg') return extension === 'jpg' || extension === 'jpeg'
  return extension === detected.extension
}

function rpcErrorCode(message: string): ApiRouteError {
  const codes = [
    'AUTHENTICATION_REQUIRED',
    'ACTIVE_COMPANY_REQUIRED',
    'ACTIVE_COMPANY_NOT_FOUND',
    'COMPANY_ACCESS_DENIED',
    'COMPANY_BRANDING_MANAGER_REQUIRED',
    'MASTER_VERSION_CONFLICT',
    'COMPANY_LOGO_MIME_NOT_ALLOWED',
    'COMPANY_LOGO_SIZE_INVALID',
    'COMPANY_LOGO_CHECKSUM_INVALID',
    'COMPANY_LOGO_OBJECT_PATH_INVALID',
    'COMPANY_LOGO_PUBLIC_URL_INVALID',
    'COMPANY_LOGO_PUBLIC_URL_PATH_MISMATCH',
    'COMPANY_LOGO_STORAGE_OBJECT_NOT_FOUND',
    'COMPANY_DOCUMENT_LOGO_VISIBILITY_REQUIRED',
  ]
  const code = codes.find((candidate) => message.includes(candidate))
  if (!code) return new ApiRouteError('COMPANY_BRANDING_OPERATION_FAILED', 500)
  if (code === 'MASTER_VERSION_CONFLICT') return new ApiRouteError(code, 409)
  if (code.endsWith('_REQUIRED') || code === 'COMPANY_ACCESS_DENIED') {
    return new ApiRouteError(code, 403)
  }
  return new ApiRouteError(code, 400)
}

async function canDeleteBrandingObject(
  caller: CallerContext,
  objectPath: string,
) {
  const reference = await caller.client.rpc(
    'company_branding_logo_is_referenced',
    { p_object_path: objectPath },
  )

  // Document retention is fail-closed. Before the SLD-2 database migration is
  // applied this RPC is absent, so an old logo is retained instead of deleted.
  if (reference.error) return { canDelete: false, checkFailed: true }
  return { canDelete: reference.data !== true, checkFailed: false }
}

export async function requireBrandingManager(caller: CallerContext, companyId: string) {
  if (!await canManageCompany(caller, companyId)) {
    throw new ApiRouteError('COMPANY_BRANDING_MANAGER_REQUIRED', 403)
  }
}

export async function getCompanyBranding(caller: CallerContext): Promise<BrandingProfile> {
  const { data, error } = await caller.client.rpc('get_company_branding')
  if (error) throw rpcErrorCode(error.message)
  return data as BrandingProfile
}

export async function uploadCompanyBranding(input: {
  caller: CallerContext
  companyId: string
  file: File
  expectedMasterVersion: number | null
}) {
  if (input.file.size < 1 || input.file.size > MAX_FILE_BYTES) {
    throw new ApiRouteError('COMPANY_LOGO_SIZE_INVALID', 400)
  }

  const bytes = new Uint8Array(await input.file.arrayBuffer())
  if (bytes.byteLength !== input.file.size) {
    throw new ApiRouteError('COMPANY_LOGO_SIZE_INVALID', 400)
  }
  const detected = detectImage(bytes)
  if (!detected) throw new ApiRouteError('COMPANY_LOGO_MAGIC_BYTES_INVALID', 400)
  if (!extensionMatches(fileExtension(input.file.name), detected)) {
    throw new ApiRouteError('COMPANY_LOGO_EXTENSION_MISMATCH', 400)
  }
  if (input.file.type && input.file.type.toLowerCase() !== detected.mimeType) {
    throw new ApiRouteError('COMPANY_LOGO_MIME_MISMATCH', 400)
  }

  const current = await getCompanyBranding(input.caller)
  const checksum = createHash('sha256').update(bytes).digest('hex')
  const logoVersion = current.logoVersion + 1
  const objectPath = `${input.companyId}/logo/v${logoVersion}-${checksum.slice(0, 12)}.${detected.extension}`

  if (current.logoChecksumSha256 === checksum && current.hasLogo) {
    return { data: current, cleanupPending: false }
  }

  const admin = createAdminClient()
  const uploaded = await admin.storage.from(BUCKET).upload(objectPath, bytes, {
    cacheControl: '31536000',
    contentType: detected.mimeType,
    upsert: false,
  })
  if (uploaded.error) {
    throw new ApiRouteError(
      uploaded.error.message.toLowerCase().includes('already exists')
        ? 'COMPANY_LOGO_OBJECT_ALREADY_EXISTS'
        : 'COMPANY_LOGO_UPLOAD_FAILED',
      uploaded.error.message.toLowerCase().includes('already exists') ? 409 : 500,
    )
  }

  const publicUrl = admin.storage.from(BUCKET).getPublicUrl(objectPath).data.publicUrl
  const saved = await input.caller.client.rpc('save_company_branding_logo', {
    p_expected_master_version: input.expectedMasterVersion,
    p_logo_object_path: objectPath,
    p_logo_public_url: publicUrl,
    p_logo_mime_type: detected.mimeType,
    p_logo_size_bytes: bytes.byteLength,
    p_logo_checksum_sha256: checksum,
  })
  if (saved.error) {
    await admin.storage.from(BUCKET).remove([objectPath])
    throw rpcErrorCode(saved.error.message)
  }

  let cleanupPending = false
  if (current.logoObjectPath && current.logoObjectPath !== objectPath) {
    const retention = await canDeleteBrandingObject(
      input.caller,
      current.logoObjectPath,
    )
    cleanupPending = retention.checkFailed
    if (retention.canDelete) {
      const cleanup = await admin.storage
        .from(BUCKET)
        .remove([current.logoObjectPath])
      cleanupPending = Boolean(cleanup.error)
    }
  }
  return { data: saved.data as BrandingProfile, cleanupPending }
}

export async function removeCompanyBranding(input: {
  caller: CallerContext
  expectedMasterVersion: number | null
}) {
  const current = await getCompanyBranding(input.caller)
  const removed = await input.caller.client.rpc('remove_company_branding_logo', {
    p_expected_master_version: input.expectedMasterVersion,
  })
  if (removed.error) throw rpcErrorCode(removed.error.message)

  let cleanupPending = false
  if (current.logoObjectPath) {
    const retention = await canDeleteBrandingObject(
      input.caller,
      current.logoObjectPath,
    )
    cleanupPending = retention.checkFailed
    if (retention.canDelete) {
      const admin = createAdminClient()
      const cleanup = await admin.storage
        .from(BUCKET)
        .remove([current.logoObjectPath])
      cleanupPending = Boolean(cleanup.error)
    }
  }
  return { data: removed.data as BrandingProfile, cleanupPending }
}

export async function saveCompanyDocumentLogoVisibility(input: {
  caller: CallerContext
  expectedMasterVersion: number | null
  showLogoOnDocuments: boolean
  showStampOnDocuments: boolean
}) {
  const saved = await input.caller.client.rpc(
    'save_company_document_logo_visibility',
    {
      p_expected_master_version: input.expectedMasterVersion,
      p_show_logo_on_documents: input.showLogoOnDocuments,
      p_show_stamp_on_documents: input.showStampOnDocuments,
    },
  )
  if (saved.error) throw rpcErrorCode(saved.error.message)
  return saved.data as BrandingProfile
}
