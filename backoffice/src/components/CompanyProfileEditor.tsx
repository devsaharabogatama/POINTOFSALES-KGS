'use client'

import { useCallback, useEffect, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { Building2, Landmark, Loader2, Save } from 'lucide-react'

type Profile = {
  companyId: string; companyCode: string; companyName: string
  legalName: string | null; taxId: string | null; registrationNo: string | null
  address: string | null; city: string | null; province: string | null
  postalCode: string | null; country: string | null; phone: string | null
  email: string | null; website: string | null; bankName: string | null
  bankAccountNumber: string | null; bankAccountHolder: string | null
  profileMasterVersion: number
}

const fields = [
  ['legalName', 'Nama legal', 'PT Maju Distribusi Indonesia'],
  ['taxId', 'NPWP', '00.000.000.0-000.000'],
  ['registrationNo', 'NIB / Nomor registrasi', 'Nomor opsional'],
  ['phone', 'Telepon', '021...'],
  ['email', 'Email', 'finance@company.com'],
  ['website', 'Website', 'https://...'],
  ['city', 'Kota / Kabupaten', 'Jakarta'],
  ['province', 'Provinsi', 'DKI Jakarta'],
  ['postalCode', 'Kode pos', '12345'],
  ['country', 'Negara', 'Indonesia'],
] as const

function message(code?: string) {
  return ({
    COMPANY_BANK_ACCOUNT_INCOMPLETE: 'Nama bank, nomor rekening, dan nama pemilik harus diisi lengkap atau dikosongkan semua.',
    COMPANY_EMAIL_INVALID: 'Format email perusahaan tidak valid.',
    COMPANY_WEBSITE_INVALID: 'Website harus diawali http:// atau https://.',
    MASTER_VERSION_CONFLICT: 'Profil diubah dari sesi lain. Muat ulang sebelum menyimpan.',
    COMPANY_PROFILE_MANAGER_REQUIRED: 'Hanya Owner atau Admin Company yang dapat mengubah profil.',
  } as Record<string, string>)[code ?? ''] ?? code ?? 'Profil perusahaan gagal diproses.'
}

export function CompanyProfileEditor({ session, companyId, canManage, notify, onBankReadyChange }: {
  session: Session; companyId: string; canManage: boolean
  notify: (message: string | null) => void
  onBankReadyChange: (ready: boolean) => void
}) {
  const [profile, setProfile] = useState<Profile | null>(null)
  const [form, setForm] = useState<Record<string, string>>({})
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')

  const apply = useCallback((data: Profile) => {
    setProfile(data)
    setForm(Object.fromEntries([
      ...fields.map(([key]) => [key, data[key] ?? '']),
      ['address', data.address ?? ''], ['bankName', data.bankName ?? ''],
      ['bankAccountNumber', data.bankAccountNumber ?? ''],
      ['bankAccountHolder', data.bankAccountHolder ?? ''],
    ]))
    onBankReadyChange(Boolean(data.bankName && data.bankAccountNumber && data.bankAccountHolder))
  }, [onBankReadyChange])

  const load = useCallback(async () => {
    setLoading(true); setError('')
    try {
      const response = await fetch('/api/platform/company-profile', {
        headers: { Authorization: `Bearer ${session.access_token}` }, cache: 'no-store',
      })
      const payload = await response.json() as { data?: Profile; error?: string }
      if (!response.ok || !payload.data) throw new Error(message(payload.error))
      if (payload.data.companyId !== companyId) throw new Error('Profil tidak cocok dengan Company aktif.')
      apply(payload.data)
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Profil gagal dimuat.') }
    finally { setLoading(false) }
  }, [apply, companyId, session.access_token])

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- profile follows active Company context
    void load()
  }, [load])

  async function save() {
    if (!profile || !canManage) return
    setSaving(true); setError('')
    try {
      const response = await fetch('/api/platform/company-profile', {
        method: 'PATCH',
        headers: { Authorization: `Bearer ${session.access_token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ expectedMasterVersion: profile.profileMasterVersion, ...form }),
      })
      const payload = await response.json() as { data?: Profile; error?: string }
      if (!response.ok || !payload.data) throw new Error(message(payload.error))
      apply(payload.data); notify('Profil dan rekening perusahaan berhasil disimpan.')
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Profil gagal disimpan.') }
    finally { setSaving(false) }
  }

  if (loading) return <section className="mb-6 rounded-3xl border border-slate-200 bg-white p-8 text-center text-slate-500"><Loader2 className="mx-auto mb-2 h-6 w-6 animate-spin"/>Memuat profil perusahaan...</section>
  return <section className="mb-6 rounded-3xl border border-slate-200 bg-white p-6 shadow-sm md:p-8">
    <div className="flex items-start gap-3"><div className="grid h-11 w-11 place-items-center rounded-xl bg-emerald-50 text-emerald-700"><Building2 className="h-5 w-5"/></div><div><h2 className="text-lg font-black">Detail perusahaan</h2><p className="mt-1 text-sm text-slate-500">Identitas administratif dan kontak Company aktif. Semua field bersifat opsional.</p></div></div>
    {error && <p className="mt-5 rounded-xl bg-rose-50 p-4 text-sm font-semibold text-rose-700">{error}</p>}
    <div className="mt-6 grid gap-4 md:grid-cols-2">{fields.map(([key, label, placeholder]) => <label key={key} className="text-sm font-bold text-slate-700">{label}<input value={form[key] ?? ''} onChange={(event) => setForm((old) => ({ ...old, [key]: event.target.value }))} disabled={!canManage || saving} placeholder={placeholder} className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 px-3 font-normal outline-none focus:border-emerald-500 disabled:bg-slate-50"/></label>)}</div>
    <label className="mt-4 block text-sm font-bold text-slate-700">Alamat lengkap<textarea value={form.address ?? ''} onChange={(event) => setForm((old) => ({ ...old, address: event.target.value }))} disabled={!canManage || saving} rows={3} className="mt-2 w-full rounded-xl border border-slate-200 p-3 font-normal outline-none focus:border-emerald-500 disabled:bg-slate-50"/></label>
    <div className="mt-7 border-t border-slate-100 pt-6"><div className="flex items-start gap-3"><Landmark className="mt-0.5 h-5 w-5 text-blue-700"/><div><h3 className="font-black">Rekening perusahaan</h3><p className="mt-1 text-sm text-slate-500">Dipakai sebagai informasi pembayaran pada Invoice bila settingnya diaktifkan. Isi ketiganya lengkap atau kosongkan semua.</p></div></div><div className="mt-4 grid gap-4 md:grid-cols-3">{([['bankName','Nama bank'],['bankAccountNumber','Nomor rekening'],['bankAccountHolder','Nama pemilik rekening']] as const).map(([key,label]) => <label key={key} className="text-sm font-bold text-slate-700">{label}<input value={form[key] ?? ''} onChange={(event) => setForm((old) => ({ ...old, [key]: event.target.value }))} disabled={!canManage || saving} className="mt-2 min-h-11 w-full rounded-xl border border-slate-200 px-3 font-normal outline-none focus:border-blue-500 disabled:bg-slate-50"/></label>)}</div></div>
    {canManage && <div className="mt-6 flex justify-end"><button onClick={() => void save()} disabled={saving} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-emerald-600 px-5 font-black text-white disabled:opacity-50"><Save className="h-4 w-4"/>{saving ? 'Menyimpan...' : 'Simpan profil'}</button></div>}
  </section>
}
