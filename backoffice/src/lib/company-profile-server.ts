import 'server-only'

import type { CallerContext } from '@/lib/server-auth'
import { ApiRouteError } from '@/lib/server-auth'

export type CompanyProfile = {
  companyId: string
  companyCode: string
  companyName: string
  legalName: string | null
  taxId: string | null
  registrationNo: string | null
  address: string | null
  city: string | null
  province: string | null
  postalCode: string | null
  country: string | null
  phone: string | null
  email: string | null
  website: string | null
  bankName: string | null
  bankAccountNumber: string | null
  bankAccountHolder: string | null
  profileMasterVersion: number
  updatedAt: string
}

function profileError(message: string) {
  const codes = [
    'AUTHENTICATION_REQUIRED', 'ACTIVE_COMPANY_REQUIRED',
    'COMPANY_ACCESS_DENIED', 'COMPANY_PROFILE_MANAGER_REQUIRED',
    'INVALID_EXPECTED_MASTER_VERSION', 'COMPANY_BANK_ACCOUNT_INCOMPLETE',
    'COMPANY_EMAIL_INVALID', 'COMPANY_WEBSITE_INVALID',
    'MASTER_VERSION_CONFLICT',
  ]
  const code = codes.find((candidate) => message.includes(candidate))
  if (!code) return new ApiRouteError('COMPANY_PROFILE_OPERATION_FAILED', 500)
  if (code === 'MASTER_VERSION_CONFLICT') return new ApiRouteError(code, 409)
  if (code.includes('ACCESS_DENIED') || code.endsWith('_REQUIRED')) {
    return new ApiRouteError(code, 403)
  }
  return new ApiRouteError(code, 400)
}

export async function getCompanyProfile(caller: CallerContext) {
  const result = await caller.client.rpc('get_company_profile')
  if (result.error) throw profileError(result.error.message)
  return result.data as CompanyProfile
}

export async function saveCompanyProfile(caller: CallerContext, input: {
  expectedMasterVersion: number
  legalName: string | null
  taxId: string | null
  registrationNo: string | null
  address: string | null
  city: string | null
  province: string | null
  postalCode: string | null
  country: string | null
  phone: string | null
  email: string | null
  website: string | null
  bankName: string | null
  bankAccountNumber: string | null
  bankAccountHolder: string | null
}) {
  const result = await caller.client.rpc('save_company_profile', {
    p_expected_master_version: input.expectedMasterVersion,
    p_legal_name: input.legalName,
    p_tax_id: input.taxId,
    p_registration_no: input.registrationNo,
    p_address: input.address,
    p_city: input.city,
    p_province: input.province,
    p_postal_code: input.postalCode,
    p_country: input.country,
    p_phone: input.phone,
    p_email: input.email,
    p_website: input.website,
    p_bank_name: input.bankName,
    p_bank_account_number: input.bankAccountNumber,
    p_bank_account_holder: input.bankAccountHolder,
  })
  if (result.error) throw profileError(result.error.message)
  return result.data as CompanyProfile
}
