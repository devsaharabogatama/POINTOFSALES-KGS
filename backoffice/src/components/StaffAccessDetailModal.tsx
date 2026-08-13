'use client'

import { useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { Building2, ChevronDown, Loader2, ShieldCheck, Store, Trash2, X } from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'

type Staff = { id: string; name: string; email: string; role: string; status: string }
type Company = { id: string; company_code: string; company_name: string; status: string }
type StoreOption = { id: string; company_id: string; store_code: string; store_name: string; status: string }
type Membership = { company_id: string; role_code: string; status: string; is_default_company: boolean; companies: Company | null }
type StoreMembership = { company_id: string; store_id: string; role_code: string; status: string; stores: { id: string; store_code: string; store_name: string } | null }
type PermissionItem = { permissionKey: string; roleCode: string; restrictionPreset: string; effectiveCapabilities: string[]; enforced: boolean; overrideVersion: number | null }
type CatalogItem = { permission_key: string; module_key: string; permission_label: string; is_customizable: boolean; enforcement_status: string }
type DetailPayload = {
  profile: { id: string; name: string; email: string }
  memberships: Membership[]
  storeMemberships: StoreMembership[]
  permissionProfile: { items: PermissionItem[] }
  permissionCatalog: CatalogItem[]
  activeCompanyId: string
  selectedCompanyId: string
  canAssignOtherCompany: boolean
  canAssignOwner: boolean
  assignmentCompanies: Company[]
  assignmentStores: StoreOption[]
  error?: string
}

const roles = ['COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER','WAREHOUSE_ADMIN','FINANCE','ACCOUNTING','CASHIER']
const roleLabels: Record<string,string> = { COMPANY_OWNER:'Pemilik Perusahaan', COMPANY_ADMIN:'Admin Perusahaan', STORE_MANAGER:'Manajer Toko', WAREHOUSE_ADMIN:'Admin Gudang', FINANCE:'Finance', ACCOUNTING:'Accounting', CASHIER:'Kasir' }
const presetLabels: Record<string,string> = { IKUTI_ROLE:'Mengikuti role', LIHAT_SAJA:'Lihat saja', OPERASIONAL:'Operasional', TANPA_AKSES:'Tanpa akses' }
const moduleLabels: Record<string,string> = { INVENTORY:'Inventory', CONTACTS:'Kontak', PURCHASE:'Pembelian', SALES:'Penjualan', FINANCE:'Keuangan', DATA:'Data Exchange', PLATFORM:'Pengaturan Platform' }
const moduleOrder = ['INVENTORY','CONTACTS','PURCHASE','SALES','FINANCE','DATA','PLATFORM']

function authHeaders(session: Session) { return { Authorization: `Bearer ${session.access_token}` } }

export function StaffAccessDetailModal({ session, member, close, complete }: { session: Session; member: Staff; close: () => void; complete: () => Promise<void> }) {
  useEscapeClose(close)
  const [detail,setDetail]=useState<DetailPayload|null>(null)
  const [loading,setLoading]=useState(true)
  const [saving,setSaving]=useState(false)
  const [savingPermission,setSavingPermission]=useState('')
  const [error,setError]=useState('')
  const [companyId,setCompanyId]=useState('')
  const [roleCode,setRoleCode]=useState('COMPANY_ADMIN')
  const [storeId,setStoreId]=useState('NONE')
  const [confirmDeactivate,setConfirmDeactivate]=useState(false)

  async function load(selectedCompanyId?: string) {
    setLoading(true); setError('')
    try {
      const query=new URLSearchParams({userId:member.id})
      if(selectedCompanyId) query.set('companyId',selectedCompanyId)
      const response=await fetch(`/api/staff/detail?${query.toString()}`,{headers:authHeaders(session)})
      const payload=(await response.json()) as DetailPayload
      if(!response.ok) throw new Error(payload.error ?? 'Gagal memuat detail user')
      setDetail(payload)
      const unassigned=payload.assignmentCompanies.find((company)=>!payload.memberships.some((membership)=>membership.company_id===company.id))
      setCompanyId(unassigned?.id ?? payload.activeCompanyId)
      const selectedMembership=payload.memberships.find((membership)=>membership.company_id===payload.selectedCompanyId)
      const selectedStore=payload.storeMemberships.find((store)=>store.company_id===payload.selectedCompanyId)
      setRoleCode(selectedMembership?.role_code ?? 'COMPANY_ADMIN')
      setStoreId(selectedStore?.store_id ?? 'NONE')
    } catch(caught) { setError(caught instanceof Error ? caught.message : 'Gagal memuat detail user') }
    finally { setLoading(false) }
  }

  useEffect(()=>{
    // Data loading is synchronized to the selected user when the modal mounts.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void load()
  },[]) // eslint-disable-line react-hooks/exhaustive-deps

  const availableCompanies=useMemo(()=>detail?.assignmentCompanies.filter((company)=>!detail.memberships.some((membership)=>membership.company_id===company.id)) ?? [],[detail])
  const availableStores=useMemo(()=>detail?.assignmentStores.filter((store)=>store.company_id===companyId) ?? [],[detail,companyId])
  const catalogByKey=useMemo(()=>new Map((detail?.permissionCatalog ?? []).map((item)=>[item.permission_key,item])),[detail])
  const permissionGroups=useMemo(()=>{
    const groups=new Map<string,PermissionItem[]>()
    for(const item of detail?.permissionProfile.items ?? []) {
      const moduleKey=catalogByKey.get(item.permissionKey)?.module_key ?? item.permissionKey.split('.')[0].toUpperCase()
      groups.set(moduleKey,[...(groups.get(moduleKey) ?? []),item])
    }
    return [...groups.entries()].sort(([left],[right])=>{
      const leftIndex=moduleOrder.indexOf(left); const rightIndex=moduleOrder.indexOf(right)
      return (leftIndex<0?moduleOrder.length:leftIndex)-(rightIndex<0?moduleOrder.length:rightIndex) || left.localeCompare(right)
    })
  },[catalogByKey,detail])
  const selectedMembership=detail?.memberships.find((membership)=>membership.company_id===detail.selectedCompanyId)
  const selectedCompany=selectedMembership?.companies
  const selectedStores=detail?.assignmentStores.filter((store)=>store.company_id===detail.selectedCompanyId) ?? []
  const availableRoles=detail?.canAssignOwner ? roles : roles.filter((role)=>role!=='COMPANY_OWNER')

  async function assign() {
    if(!companyId) return
    setSaving(true); setError('')
    try {
      const response=await fetch('/api/staff/assign-existing',{method:'POST',headers:{'Content-Type':'application/json',...authHeaders(session)},body:JSON.stringify({target_user_id:member.id,company_id:companyId,role_code:roleCode,store_id:storeId})})
      const payload=(await response.json()) as {error?:string}
      if(!response.ok) throw new Error(payload.error ?? 'Gagal menambahkan akses perusahaan')
      await complete(); await load(companyId)
    } catch(caught) { setError(caught instanceof Error ? caught.message : 'Gagal menambahkan akses perusahaan') }
    finally { setSaving(false) }
  }

  async function updatePermission(item: PermissionItem, restrictionPreset: string) {
    if(!detail?.selectedCompanyId) return
    setSavingPermission(item.permissionKey); setError('')
    try {
      const response=await fetch('/api/staff/permissions',{method:'POST',headers:{'Content-Type':'application/json',...authHeaders(session)},body:JSON.stringify({companyId:detail.selectedCompanyId,targetUserId:member.id,permissionKey:item.permissionKey,restrictionPreset,expectedVersion:item.overrideVersion})})
      const payload=(await response.json()) as {error?:string}
      if(!response.ok) throw new Error(payload.error ?? 'Gagal memperbarui pembatasan akses')
      await load(detail.selectedCompanyId); await complete()
    } catch(caught) { setError(caught instanceof Error ? caught.message : 'Gagal memperbarui pembatasan akses') }
    finally { setSavingPermission('') }
  }

  async function saveSelectedAccess() {
    if(!detail?.selectedCompanyId) return
    setSaving(true); setError('')
    try {
      const response=await fetch('/api/staff/company-access',{method:'POST',headers:{'Content-Type':'application/json',...authHeaders(session)},body:JSON.stringify({action:'SAVE',targetUserId:member.id,companyId:detail.selectedCompanyId,roleCode,storeId})})
      const payload=(await response.json()) as {error?:string}
      if(!response.ok) throw new Error(payload.error ?? 'Gagal menyimpan akses perusahaan')
      await complete(); await load(detail.selectedCompanyId)
    } catch(caught) { setError(caught instanceof Error ? caught.message : 'Gagal menyimpan akses perusahaan') }
    finally { setSaving(false) }
  }

  async function deactivateSelectedAccess() {
    if(!detail?.selectedCompanyId) return
    setSaving(true); setError('')
    try {
      const response=await fetch('/api/staff/company-access',{method:'POST',headers:{'Content-Type':'application/json',...authHeaders(session)},body:JSON.stringify({action:'DEACTIVATE',targetUserId:member.id,companyId:detail.selectedCompanyId})})
      const payload=(await response.json()) as {error?:string}
      if(!response.ok) throw new Error(payload.error ?? 'Gagal mencabut akses perusahaan')
      setConfirmDeactivate(false); await complete(); close()
    } catch(caught) { setError(caught instanceof Error ? caught.message : 'Gagal mencabut akses perusahaan'); setConfirmDeactivate(false) }
    finally { setSaving(false) }
  }

  return <div className="fixed inset-0 z-[80] grid place-items-center bg-slate-950/45 p-4 backdrop-blur-sm">
    <div className="max-h-[94vh] w-full max-w-4xl overflow-y-auto rounded-3xl bg-white p-6 shadow-2xl sm:p-8">
      <div className="flex items-start justify-between gap-4"><div><p className="text-xs font-black uppercase tracking-[0.18em] text-emerald-600">Detail user</p><h2 className="mt-2 text-2xl font-black text-slate-950">{member.name}</h2><p className="mt-1 text-sm text-slate-500">{member.email}</p></div><button type="button" onClick={close} aria-label="Tutup detail user" className="grid h-10 w-10 place-items-center rounded-xl border border-slate-200 text-slate-500 hover:bg-slate-50"><X className="h-4 w-4" /></button></div>
      {loading&&<div className="grid min-h-56 place-items-center"><Loader2 className="h-7 w-7 animate-spin text-emerald-500" /></div>}
      {!loading&&error&&!detail&&<div className="mt-6 rounded-xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">{error}</div>}
      {detail&&<div className="mt-7 space-y-7">
        <section><h3 className="flex items-center gap-2 font-black"><Building2 className="h-4 w-4 text-slate-500" />Pilih perusahaan yang diatur</h3><p className="mt-1 text-xs text-slate-500">Role, Toko, dan pembatasan submodul di bawah hanya berlaku untuk perusahaan yang dipilih.</p><div className="mt-3 grid gap-3 md:grid-cols-2">{detail.memberships.map((membership)=><button type="button" onClick={()=>void load(membership.company_id)} key={membership.company_id} className={`rounded-2xl border p-4 text-left transition ${membership.company_id===detail.selectedCompanyId?'border-emerald-500 bg-emerald-50 ring-2 ring-emerald-100':'border-slate-200 hover:border-slate-300'}`}><div className="flex items-start justify-between gap-3"><div><p className="font-bold">{membership.companies?.company_name ?? 'Perusahaan'}</p><p className="mt-1 text-xs text-slate-400">{membership.companies?.company_code}</p></div><div className="flex gap-1">{membership.company_id===detail.selectedCompanyId&&<span className="rounded-full bg-emerald-600 px-2 py-1 text-[10px] font-bold text-white">Sedang diatur</span>}{membership.is_default_company&&<span className="rounded-full bg-blue-50 px-2 py-1 text-[10px] font-bold text-blue-700">Default</span>}</div></div><p className="mt-3 text-sm font-semibold text-emerald-700">{roleLabels[membership.role_code] ?? membership.role_code}</p>{detail.storeMemberships.filter((store)=>store.company_id===membership.company_id).map((store)=><p key={store.store_id} className="mt-2 flex items-center gap-1.5 text-xs text-slate-500"><Store className="h-3.5 w-3.5" />{store.stores?.store_name ?? 'Toko'}</p>)}</button>)}</div></section>
        {selectedMembership&&<section className="rounded-2xl border border-emerald-200 bg-emerald-50/50 p-5"><div className="flex flex-wrap items-start justify-between gap-3"><div><p className="text-xs font-black uppercase tracking-wide text-emerald-700">Mengatur akses untuk</p><h3 className="mt-1 text-lg font-black text-slate-950">{selectedCompany?.company_name}</h3><p className="mt-1 text-xs text-slate-500">Perubahan ini tidak memengaruhi role user pada perusahaan lain.</p></div><button type="button" onClick={()=>setConfirmDeactivate(true)} className="inline-flex min-h-10 items-center gap-2 rounded-xl border border-rose-200 bg-white px-3 text-sm font-bold text-rose-700 hover:bg-rose-50"><Trash2 className="h-4 w-4" />Cabut akses</button></div><div className="mt-4 grid gap-3 sm:grid-cols-2"><label className="text-sm font-bold text-slate-700">Role di perusahaan ini<select className="input mt-2" value={roleCode} onChange={(event)=>{setRoleCode(event.target.value);if(event.target.value!=='CASHIER')setStoreId('NONE')}}>{availableRoles.map((role)=><option key={role} value={role}>{roleLabels[role]}</option>)}</select></label><label className="text-sm font-bold text-slate-700">Toko penugasan<select className="input mt-2" value={storeId} onChange={(event)=>setStoreId(event.target.value)}><option value="NONE" disabled={roleCode==='CASHIER'}>{roleCode==='CASHIER'?'Pilih Toko':'Tanpa Toko spesifik'}</option>{selectedStores.map((store)=><option key={store.id} value={store.id}>{store.store_name}</option>)}</select></label></div><button type="button" disabled={saving||(roleCode==='CASHIER'&&storeId==='NONE')} onClick={()=>void saveSelectedAccess()} className="mt-4 inline-flex min-h-11 items-center justify-center rounded-xl bg-emerald-600 px-4 text-sm font-bold text-white disabled:opacity-50">{saving?<Loader2 className="h-4 w-4 animate-spin" />:'Simpan role & Toko'}</button></section>}
        {detail.canAssignOtherCompany&&availableCompanies.length>0&&<section className="rounded-2xl border border-blue-200 bg-blue-50/60 p-5"><h3 className="font-black text-blue-950">Tambahkan ke perusahaan lain</h3><p className="mt-1 text-xs leading-5 text-blue-700">Akun dan password tetap sama. Role hanya berlaku pada perusahaan yang dipilih.</p><div className="mt-4 grid gap-3 md:grid-cols-3"><select className="input" value={companyId} onChange={(event)=>{setCompanyId(event.target.value);setStoreId('NONE')}}>{availableCompanies.map((company)=><option key={company.id} value={company.id}>{company.company_name}</option>)}</select><select className="input" value={roleCode} onChange={(event)=>{setRoleCode(event.target.value);setStoreId('NONE')}}>{availableRoles.map((role)=><option key={role} value={role}>{roleLabels[role]}</option>)}</select><select className="input" value={storeId} onChange={(event)=>setStoreId(event.target.value)}><option value="NONE" disabled={roleCode==='CASHIER'}>{roleCode==='CASHIER'?'Pilih Toko':'Tanpa Toko spesifik'}</option>{availableStores.map((store)=><option key={store.id} value={store.id}>{store.store_name}</option>)}</select></div><button type="button" disabled={saving||!companyId||(roleCode==='CASHIER'&&storeId==='NONE')} onClick={()=>void assign()} className="mt-4 inline-flex min-h-11 items-center justify-center rounded-xl bg-blue-600 px-4 text-sm font-bold text-white disabled:opacity-50">{saving?<Loader2 className="h-4 w-4 animate-spin" />:'Tambahkan akses'}</button></section>}
        <section><div><h3 className="flex items-center gap-2 font-black"><ShieldCheck className="h-4 w-4 text-slate-500" />Pembatasan submodul — {selectedCompany?.company_name}</h3><p className="mt-1 text-xs text-slate-500">Semua pilihan pada bagian ini hanya berlaku untuk perusahaan terpilih.</p></div><div className="mt-3 space-y-2">{permissionGroups.map(([moduleKey,items])=>{const restrictedCount=items.filter((item)=>item.restrictionPreset!=='IKUTI_ROLE').length;return <details key={moduleKey} className="group overflow-hidden rounded-2xl border border-slate-200 bg-white"><summary className="flex cursor-pointer list-none items-center gap-3 px-4 py-4 transition hover:bg-slate-50"><span className="min-w-0 flex-1"><span className="block font-black text-slate-900">{moduleLabels[moduleKey] ?? moduleKey}</span><span className="mt-1 block text-xs text-slate-500">{items.length} submodul{restrictedCount>0?` · ${restrictedCount} dibatasi`:' · seluruhnya mengikuti role'}</span></span>{restrictedCount>0&&<span className="rounded-full bg-amber-50 px-2.5 py-1 text-[10px] font-bold text-amber-700">{restrictedCount} dibatasi</span>}<ChevronDown className="h-4 w-4 shrink-0 text-slate-400 transition-transform group-open:rotate-180" /></summary><div className="divide-y divide-slate-100 border-t border-slate-100 bg-slate-50/40">{items.map((item)=>{const catalog=catalogByKey.get(item.permissionKey);const editable=item.enforced&&catalog?.is_customizable;return <div key={item.permissionKey} className="grid gap-2 px-4 py-3 sm:grid-cols-[1fr_auto] sm:items-center"><div><p className="flex items-center gap-2 text-sm font-bold text-slate-800">{catalog?.permission_label ?? item.permissionKey}{item.enforced&&<span className="rounded-full bg-emerald-50 px-2 py-0.5 text-[9px] uppercase tracking-wide text-emerald-700">Aktif</span>}</p><p className="mt-0.5 text-[11px] text-slate-400">{item.effectiveCapabilities.join(', ')||'Tidak ada akses'}</p></div>{editable?<select aria-label={`Pembatasan ${catalog?.permission_label ?? item.permissionKey}`} className="input min-w-44" value={item.restrictionPreset} disabled={savingPermission===item.permissionKey} onChange={(event)=>void updatePermission(item,event.target.value)}>{Object.entries(presetLabels).map(([value,label])=><option key={value} value={value}>{label}</option>)}</select>:<span className={`w-fit rounded-full px-2.5 py-1 text-[11px] font-bold ${item.restrictionPreset==='IKUTI_ROLE'?'bg-slate-100 text-slate-600':'bg-amber-50 text-amber-700'}`}>{presetLabels[item.restrictionPreset] ?? item.restrictionPreset}</span>}</div>})}</div></details>})}</div></section>
        {error&&<div className="rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">{error}</div>}
      </div>}
    </div>
    {confirmDeactivate&&<div className="fixed inset-0 z-[90] grid place-items-center bg-slate-950/60 p-4"><div className="w-full max-w-md rounded-3xl bg-white p-6 shadow-2xl"><h3 className="text-xl font-black text-slate-950">Cabut akses {selectedCompany?.company_name}?</h3><p className="mt-3 text-sm leading-6 text-slate-600">User tidak lagi dapat memilih atau membaca data perusahaan ini. Role, penugasan Toko, dan override aktif akan dinonaktifkan; histori transaksi dan audit tetap disimpan.</p><div className="mt-6 flex justify-end gap-2"><button type="button" disabled={saving} onClick={()=>setConfirmDeactivate(false)} className="min-h-11 rounded-xl border border-slate-200 px-4 text-sm font-bold">Batal</button><button type="button" disabled={saving} onClick={()=>void deactivateSelectedAccess()} className="inline-flex min-h-11 items-center justify-center rounded-xl bg-rose-600 px-4 text-sm font-bold text-white disabled:opacity-50">{saving?<Loader2 className="h-4 w-4 animate-spin" />:'Ya, cabut akses'}</button></div></div></div>}
  </div>
}
