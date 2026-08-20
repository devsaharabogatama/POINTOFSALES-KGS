import { apiError, ApiRouteError, requireActiveCompany, requireCaller } from '@/lib/server-auth'
import { getCompanyProfile, saveCompanyProfile } from '@/lib/company-profile-server'

function optionalText(value: unknown, max: number) {
  if (value === null || value === undefined || value === '') return null
  if (typeof value !== 'string' || value.trim().length > max) {
    throw new ApiRouteError('COMPANY_PROFILE_VALUE_INVALID', 400)
  }
  return value.trim()
}

export async function GET(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const data = await getCompanyProfile(caller)
    if (data.companyId !== companyId) throw new ApiRouteError('ACTIVE_COMPANY_PROFILE_MISMATCH', 500)
    return Response.json({ companyId, data }, { headers: { 'Cache-Control': 'no-store' } })
  } catch (error) { return apiError(error) }
}

export async function PATCH(request: Request) {
  try {
    const caller = await requireCaller(request)
    const companyId = await requireActiveCompany(caller)
    const body = await request.json() as Record<string, unknown>
    if (!Number.isInteger(body.expectedMasterVersion) || Number(body.expectedMasterVersion) < 1) {
      throw new ApiRouteError('INVALID_EXPECTED_MASTER_VERSION', 400)
    }
    const data = await saveCompanyProfile(caller, {
      expectedMasterVersion: Number(body.expectedMasterVersion),
      legalName: optionalText(body.legalName, 200),
      taxId: optionalText(body.taxId, 80),
      registrationNo: optionalText(body.registrationNo, 80),
      address: optionalText(body.address, 1000),
      city: optionalText(body.city, 120),
      province: optionalText(body.province, 120),
      postalCode: optionalText(body.postalCode, 20),
      country: optionalText(body.country, 120),
      phone: optionalText(body.phone, 50),
      email: optionalText(body.email, 254),
      website: optionalText(body.website, 500),
      bankName: optionalText(body.bankName, 150),
      bankAccountNumber: optionalText(body.bankAccountNumber, 100),
      bankAccountHolder: optionalText(body.bankAccountHolder, 200),
    })
    if (data.companyId !== companyId) throw new ApiRouteError('ACTIVE_COMPANY_PROFILE_MISMATCH', 500)
    return Response.json({ companyId, data })
  } catch (error) { return apiError(error) }
}
