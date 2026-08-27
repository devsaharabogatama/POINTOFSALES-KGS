import { apiError, ApiRouteError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import {
  getCompanyBranding,
  removeCompanyBranding,
  requireBrandingManager,
  saveCompanyDocumentVisibility,
  uploadCompanyBranding,
} from '@/lib/company-branding-server'

export const runtime = 'nodejs'

function parseExpectedMasterVersion(value: FormDataEntryValue | null): number | null {
  if (value === null || value === '') return null
  if (typeof value !== 'string' || !/^[1-9][0-9]*$/.test(value)) {
    throw new ApiRouteError('INVALID_EXPECTED_MASTER_VERSION', 400)
  }
  return Number(value)
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const data = await getCompanyBranding(caller)
    if (data.companyId !== companyId) {
      throw new ApiRouteError('ACTIVE_COMPANY_BRANDING_MISMATCH', 500)
    }
    return Response.json({ companyId, data }, {
      headers: { 'Cache-Control': 'no-store' },
    })
  } catch (error) {
    return apiError(error)
  }
}

export async function POST(request: Request) {
  try {
    const contentLength = Number(request.headers.get('content-length') ?? 0)
    if (Number.isFinite(contentLength) && contentLength > 2 * 1024 * 1024 + 128 * 1024) {
      throw new ApiRouteError('COMPANY_LOGO_REQUEST_TOO_LARGE', 413)
    }
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requireBrandingManager(caller, companyId)
    const formData = await request.formData()
    const file = formData.get('file')
    if (!(file instanceof File)) throw new ApiRouteError('COMPANY_LOGO_FILE_REQUIRED', 400)
    const expectedMasterVersion = parseExpectedMasterVersion(
      formData.get('expectedMasterVersion'),
    )
    const result = await uploadCompanyBranding({
      caller, companyId, file, expectedMasterVersion,
    })
    return Response.json({ companyId, ...result })
  } catch (error) {
    return apiError(error)
  }
}

export async function DELETE(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requireBrandingManager(caller, companyId)
    const body = await request.json() as { expectedMasterVersion?: unknown }
    if (!Number.isInteger(body.expectedMasterVersion) || Number(body.expectedMasterVersion) < 1) {
      throw new ApiRouteError('INVALID_EXPECTED_MASTER_VERSION', 400)
    }
    const result = await removeCompanyBranding({
      caller,
      expectedMasterVersion: Number(body.expectedMasterVersion),
    })
    return Response.json({ companyId, ...result })
  } catch (error) {
    return apiError(error)
  }
}

export async function PATCH(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    await requireBrandingManager(caller, companyId)
    const body = await request.json() as {
      expectedMasterVersion?: unknown
      showLogoOnDocuments?: unknown
      showStampOnDocuments?: unknown
      showBankAccountOnInvoice?: unknown
      invoiceDateDisplayMode?: unknown
      deliverySignatureTemplate?: unknown
    }
    if (body.expectedMasterVersion !== null &&
        (!Number.isInteger(body.expectedMasterVersion) || Number(body.expectedMasterVersion) < 1)) {
      throw new ApiRouteError('INVALID_EXPECTED_MASTER_VERSION', 400)
    }
    if (typeof body.showLogoOnDocuments !== 'boolean' ||
        typeof body.showStampOnDocuments !== 'boolean' ||
        typeof body.showBankAccountOnInvoice !== 'boolean' ||
        !['ORDER_DATE', 'POSTED_DATE'].includes(String(body.invoiceDateDisplayMode)) ||
        !['WAREHOUSE', 'STORE'].includes(String(body.deliverySignatureTemplate))) {
      throw new ApiRouteError('COMPANY_DOCUMENT_VISIBILITY_REQUIRED', 400)
    }
    const data = await saveCompanyDocumentVisibility({
      caller,
      expectedMasterVersion: body.expectedMasterVersion === null
        ? null : Number(body.expectedMasterVersion),
      showLogoOnDocuments: body.showLogoOnDocuments,
      showStampOnDocuments: body.showStampOnDocuments,
      showBankAccountOnInvoice: body.showBankAccountOnInvoice,
      invoiceDateDisplayMode: body.invoiceDateDisplayMode as 'ORDER_DATE' | 'POSTED_DATE',
      deliverySignatureTemplate: body.deliverySignatureTemplate as 'WAREHOUSE' | 'STORE',
    })
    return Response.json({ companyId, data })
  } catch (error) {
    return apiError(error)
  }
}
