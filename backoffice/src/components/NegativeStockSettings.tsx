'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  AlertTriangle,
  CircleAlert,
  RefreshCcw,
  Save,
  ShieldCheck,
  UserRoundCheck,
  Warehouse,
  X,
} from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'

type Policy = {
  id: string
  is_active: boolean
  require_reason: boolean
  company_negative_limit_base_qty: number | null
  master_version: number
}
type WarehouseOption = {
  id: string
  name: string
  store_id: string | null
  allow_negative_stock: boolean
}
type UserOption = { id: string; name: string; email: string | null }
type Permission = {
  id: string
  warehouse_id: string
  user_id: string
  is_active: boolean
  max_negative_base_qty: number | null
  valid_until: string | null
  grant_reason: string
  master_version: number
}
type Settings = {
  featureEnabled: boolean
  roleCode: string
  canManage: boolean
  policy: Policy
  warehouses: WarehouseOption[]
  users: UserOption[]
  permissions: Permission[]
}
type Pending = {
  title: string
  description: string
  body: Record<string, unknown>
  success: string
}
type PermissionForm = {
  permissionId: string | null
  masterVersion: number | null
  warehouseId: string
  userId: string
  userLimit: string
  validUntil: string
  grantReason: string
  active: boolean
}

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` }
}

function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    NEGATIVE_STOCK_SETTINGS_ACCESS_REQUIRED:
      'Role Anda tidak memiliki akses ke pengaturan stok minus.',
    NEGATIVE_STOCK_SETTINGS_MANAGER_REQUIRED:
      'Hanya Pemilik atau Admin Perusahaan yang dapat mengubah pengaturan ini.',
    NEGATIVE_STOCK_POLICY_FORBIDDEN:
      'Anda tidak boleh mengubah kebijakan stok minus Company.',
    NEGATIVE_STOCK_WAREHOUSE_FORBIDDEN:
      'Anda tidak boleh mengubah opt-in Gudang.',
    NEGATIVE_STOCK_PERMISSION_FORBIDDEN:
      'Anda tidak boleh mengubah izin pengguna.',
    NEGATIVE_STOCK_GRANT_REASON_REQUIRED:
      'Alasan pemberian izin wajib diisi.',
    ACTIVE_SALE_SOURCE_WAREHOUSE_REQUIRED:
      'Pilih Gudang penjualan aktif.',
    ACTIVE_COMPANY_USER_REQUIRED:
      'Pilih user aktif yang terhubung ke Company ini.',
    MASTER_VERSION_CONFLICT:
      'Data telah berubah. Muat ulang sebelum menyimpan kembali.',
    ACTIVE_COMPANY_NOT_FOUND: 'Pilih Company aktif terlebih dahulu.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi pengaturan stok minus gagal.'
}

function emptyPermission(settings: Settings | null): PermissionForm {
  return {
    permissionId: null,
    masterVersion: null,
    warehouseId: settings?.warehouses[0]?.id ?? '',
    userId: settings?.users[0]?.id ?? '',
    userLimit: '',
    validUntil: '',
    grantReason: '',
    active: true,
  }
}

export function NegativeStockSettings({
  session,
  companyId,
  notify,
}: {
  session: Session
  companyId: string
  notify: (message: string | null) => void
}) {
  const [settings, setSettings] = useState<Settings | null>(null)
  const [companyLimit, setCompanyLimit] = useState('')
  const [policyActive, setPolicyActive] = useState(false)
  const [requireReason, setRequireReason] = useState(true)
  const [permissionForm, setPermissionForm] = useState<PermissionForm>(emptyPermission(null))
  const [pending, setPending] = useState<Pending | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  const refresh = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      const response = await fetch('/api/platform/negative-stock-settings', {
        headers: authHeaders(session),
        cache: 'no-store',
      })
      const payload = await response.json() as { data?: Settings; error?: string }
      if (!response.ok || !payload.data) throw new Error(friendlyError(payload.error))
      setSettings(payload.data)
      setPolicyActive(payload.data.policy.is_active)
      setRequireReason(payload.data.policy.require_reason)
      setCompanyLimit(
        payload.data.policy.company_negative_limit_base_qty === null
          ? ''
          : String(payload.data.policy.company_negative_limit_base_qty),
      )
      setPermissionForm((current) => current.permissionId
        ? current
        : emptyPermission(payload.data ?? null))
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal memuat pengaturan stok minus.')
    } finally {
      setLoading(false)
    }
  }, [session])

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- settings follow active Company
    void refresh()
  }, [companyId, refresh])

  const warehouseNames = useMemo(
    () => new Map((settings?.warehouses ?? []).map((item) => [item.id, item.name])),
    [settings],
  )
  const userNames = useMemo(
    () => new Map((settings?.users ?? []).map((item) => [item.id, item.name || item.email || 'User'])),
    [settings],
  )

  function editPermission(permission: Permission) {
    setPermissionForm({
      permissionId: permission.id,
      masterVersion: permission.master_version,
      warehouseId: permission.warehouse_id,
      userId: permission.user_id,
      userLimit: permission.max_negative_base_qty === null
        ? ''
        : String(permission.max_negative_base_qty),
      validUntil: permission.valid_until
        ? new Date(permission.valid_until).toISOString().slice(0, 16)
        : '',
      grantReason: permission.grant_reason,
      active: permission.is_active,
    })
  }

  if (loading && !settings) {
    return <div className="mt-6 rounded-2xl border border-slate-200 bg-white p-8 text-center text-sm text-slate-500"><RefreshCcw className="mx-auto mb-3 h-5 w-5 animate-spin" />Memuat pengaturan stok minus...</div>
  }

  return (
    <section className="mt-8 border-t border-slate-200 pt-8">
      <div className="mb-5 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[.16em] text-rose-600">STK-006 · Online only</p>
          <h2 className="mt-2 text-xl font-black text-slate-950">Izin Stok Minus POS</h2>
          <p className="mt-1 max-w-3xl text-sm leading-6 text-slate-500">
            Exception berlapis untuk penjualan online non-Bundle. Company, Gudang,
            dan user harus diizinkan bersamaan; seluruh penggunaan menyimpan alasan dan audit.
          </p>
        </div>
        <button type="button" onClick={() => void refresh()} className="inline-flex items-center justify-center gap-2 rounded-xl border border-slate-200 bg-white px-4 py-2.5 text-sm font-bold text-slate-600"><RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} />Muat ulang</button>
      </div>

      {!settings?.featureEnabled && (
        <div className="mb-5 flex gap-3 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900"><CircleAlert className="mt-0.5 h-5 w-5 shrink-0" /><span><b>Entitlement masih nonaktif.</b> Konfigurasi boleh disiapkan, tetapi server tetap menolak stok minus sampai Super Admin mengaktifkan fitur.</span></div>
      )}
      {error && <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">{error}</div>}
      {!settings?.canManage && <div className="mb-5 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-600">Mode lihat saja. Perubahan hanya dapat dilakukan Pemilik atau Admin Perusahaan.</div>}

      <article className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
        <div className="flex items-start gap-3"><div className="grid h-10 w-10 shrink-0 place-items-center rounded-xl bg-rose-50 text-rose-600"><ShieldCheck className="h-5 w-5" /></div><div><h3 className="font-bold text-slate-950">Kebijakan Company</h3><p className="mt-1 text-sm text-slate-500">Policy aktif adalah lapisan kedua setelah entitlement Super Admin.</p></div></div>
        <div className="mt-5 grid gap-4 md:grid-cols-2">
          <label className="block"><span className="mb-1.5 block text-xs font-bold uppercase tracking-wide text-slate-500">Batas minus Company (base qty)</span><input type="number" min="0.000001" step="0.000001" value={companyLimit} disabled={!settings?.canManage} onChange={(event) => setCompanyLimit(event.target.value)} placeholder="Kosong = tanpa batas Company" className="input" /></label>
          <div className="space-y-3 rounded-xl bg-slate-50 p-4">
            <label className="flex items-center gap-3 text-sm font-bold text-slate-700"><input type="checkbox" checked={policyActive} disabled={!settings?.canManage} onChange={(event) => setPolicyActive(event.target.checked)} />Aktifkan policy Company</label>
            <label className="flex items-center gap-3 text-sm font-bold text-slate-700"><input type="checkbox" checked={requireReason} disabled={!settings?.canManage} onChange={(event) => setRequireReason(event.target.checked)} />Kasir wajib mengisi alasan</label>
          </div>
        </div>
        {settings?.canManage && <button type="button" onClick={() => setPending({ title: 'Simpan kebijakan Company?', description: 'Perubahan tidak memberi izin otomatis; Gudang dan user tetap harus diaktifkan terpisah.', success: 'Kebijakan stok minus berhasil diperbarui.', body: { action: 'SAVE_POLICY', masterVersion: settings.policy.master_version, active: policyActive, requireReason, companyLimit: companyLimit || null } })} className="mt-4 inline-flex items-center gap-2 rounded-xl bg-slate-950 px-4 py-2.5 text-sm font-bold text-white"><Save className="h-4 w-4" />Simpan kebijakan</button>}
      </article>

      <article className="mt-5 rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
        <div className="flex items-start gap-3"><div className="grid h-10 w-10 shrink-0 place-items-center rounded-xl bg-amber-50 text-amber-600"><Warehouse className="h-5 w-5" /></div><div><h3 className="font-bold text-slate-950">Gudang penjualan</h3><p className="mt-1 text-sm text-slate-500">Hanya Gudang sale-source aktif yang dapat diikutkan.</p></div></div>
        <div className="mt-4 grid gap-3 md:grid-cols-2">
          {(settings?.warehouses ?? []).map((warehouse) => (
            <div key={warehouse.id} className="flex items-center gap-3 rounded-xl border border-slate-200 p-3"><div className="min-w-0 flex-1"><p className="truncate text-sm font-bold text-slate-900">{warehouse.name}</p><p className={`mt-0.5 text-xs font-semibold ${warehouse.allow_negative_stock ? 'text-emerald-600' : 'text-slate-400'}`}>{warehouse.allow_negative_stock ? 'Opt-in aktif' : 'Stok minus ditolak'}</p></div>{settings?.canManage && <button type="button" onClick={() => setPending({ title: warehouse.allow_negative_stock ? 'Nonaktifkan Gudang?' : 'Aktifkan Gudang?', description: warehouse.allow_negative_stock ? `${warehouse.name} kembali menolak seluruh stok minus baru.` : `${warehouse.name} tetap membutuhkan policy Company dan izin user aktif.`, success: `Pengaturan ${warehouse.name} berhasil diperbarui.`, body: { action: 'SET_WAREHOUSE', warehouseId: warehouse.id, allow: !warehouse.allow_negative_stock } })} className={`rounded-lg px-3 py-2 text-xs font-bold ${warehouse.allow_negative_stock ? 'border border-rose-200 text-rose-600' : 'bg-amber-500 text-white'}`}>{warehouse.allow_negative_stock ? 'Nonaktifkan' : 'Opt-in'}</button>}</div>
          ))}
        </div>
        {!settings?.warehouses.length && <p className="mt-4 rounded-xl border border-dashed border-slate-300 p-5 text-center text-sm text-slate-400">Belum ada Gudang penjualan aktif.</p>}
      </article>

      <article className="mt-5 rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
        <div className="flex items-start gap-3"><div className="grid h-10 w-10 shrink-0 place-items-center rounded-xl bg-blue-50 text-blue-600"><UserRoundCheck className="h-5 w-5" /></div><div><h3 className="font-bold text-slate-950">Izin per user</h3><p className="mt-1 text-sm text-slate-500">Batas user berlaku per Gudang dan tidak boleh melampaui batas Company.</p></div></div>
        {settings?.canManage && <div className="mt-5 grid gap-4 rounded-2xl bg-slate-50 p-4 md:grid-cols-2">
          <label className="block"><span className="mb-1.5 block text-xs font-bold uppercase text-slate-500">Gudang</span><select value={permissionForm.warehouseId} onChange={(event) => setPermissionForm((current) => ({ ...current, warehouseId: event.target.value }))} className="input">{(settings?.warehouses ?? []).map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label>
          <label className="block"><span className="mb-1.5 block text-xs font-bold uppercase text-slate-500">User</span><select value={permissionForm.userId} onChange={(event) => setPermissionForm((current) => ({ ...current, userId: event.target.value }))} className="input">{(settings?.users ?? []).map((item) => <option key={item.id} value={item.id}>{item.name || item.email || 'User'}</option>)}</select></label>
          <label className="block"><span className="mb-1.5 block text-xs font-bold uppercase text-slate-500">Batas user (base qty)</span><input type="number" min="0.000001" step="0.000001" value={permissionForm.userLimit} onChange={(event) => setPermissionForm((current) => ({ ...current, userLimit: event.target.value }))} placeholder="Kosong = mengikuti Company" className="input" /></label>
          <label className="block"><span className="mb-1.5 block text-xs font-bold uppercase text-slate-500">Berlaku sampai (opsional)</span><input type="datetime-local" value={permissionForm.validUntil} onChange={(event) => setPermissionForm((current) => ({ ...current, validUntil: event.target.value }))} className="input" /></label>
          <label className="block md:col-span-2"><span className="mb-1.5 block text-xs font-bold uppercase text-slate-500">Alasan pemberian izin</span><textarea rows={2} maxLength={500} value={permissionForm.grantReason} onChange={(event) => setPermissionForm((current) => ({ ...current, grantReason: event.target.value }))} className="input resize-none" placeholder="Contoh: kasir shift malam, otorisasi sampai stok replenishment tiba" /></label>
          <label className="flex items-center gap-3 text-sm font-bold text-slate-700"><input type="checkbox" checked={permissionForm.active} onChange={(event) => setPermissionForm((current) => ({ ...current, active: event.target.checked }))} />Izin aktif</label>
          <div className="flex justify-end gap-2"><button type="button" onClick={() => setPermissionForm(emptyPermission(settings))} className="rounded-xl border border-slate-200 bg-white px-4 py-2.5 text-sm font-bold text-slate-600">Baru</button><button type="button" disabled={!permissionForm.warehouseId || !permissionForm.userId || !permissionForm.grantReason.trim()} onClick={() => setPending({ title: permissionForm.permissionId ? 'Perbarui izin user?' : 'Berikan izin user?', description: 'Izin tetap tunduk pada entitlement, policy Company, opt-in Gudang, masa berlaku, dan limit server.', success: 'Izin stok minus user berhasil disimpan.', body: { action: 'SAVE_PERMISSION', permissionId: permissionForm.permissionId, masterVersion: permissionForm.masterVersion, warehouseId: permissionForm.warehouseId, userId: permissionForm.userId, userLimit: permissionForm.userLimit || null, validUntil: permissionForm.validUntil || null, grantReason: permissionForm.grantReason, active: permissionForm.active } })} className="inline-flex items-center gap-2 rounded-xl bg-blue-600 px-4 py-2.5 text-sm font-bold text-white disabled:opacity-40"><Save className="h-4 w-4" />Simpan izin</button></div>
        </div>}
        <div className="mt-4 space-y-2">{(settings?.permissions ?? []).map((permission) => <div key={permission.id} className="flex flex-col gap-3 rounded-xl border border-slate-200 p-4 sm:flex-row sm:items-center"><div className="min-w-0 flex-1"><div className="flex flex-wrap items-center gap-2"><p className="font-bold text-slate-900">{userNames.get(permission.user_id) ?? 'User'}</p><span className={`rounded-full px-2 py-0.5 text-xs font-bold ${permission.is_active ? 'bg-emerald-50 text-emerald-700' : 'bg-slate-100 text-slate-500'}`}>{permission.is_active ? 'Aktif' : 'Nonaktif'}</span></div><p className="mt-1 text-sm text-slate-500">{warehouseNames.get(permission.warehouse_id) ?? 'Gudang'} · batas {permission.max_negative_base_qty ?? 'Company'}{permission.valid_until ? ` · sampai ${new Date(permission.valid_until).toLocaleString('id-ID')}` : ''}</p><p className="mt-1 text-xs text-slate-400">{permission.grant_reason}</p></div>{settings?.canManage && <button type="button" onClick={() => editPermission(permission)} className="rounded-xl border border-slate-200 px-3 py-2 text-sm font-bold text-slate-600">Edit</button>}</div>)}</div>
        {!settings?.permissions.length && <p className="mt-4 rounded-xl border border-dashed border-slate-300 p-5 text-center text-sm text-slate-400">Belum ada user yang diberi izin.</p>}
      </article>

      <div className="mt-5 flex gap-3 rounded-2xl bg-slate-950 p-4 text-sm leading-6 text-slate-200"><AlertTriangle className="mt-0.5 h-5 w-5 shrink-0 text-amber-300" />Stok minus bukan saldo stok normal. Setiap Sale membuat authorization dan biaya provisional; barang masuk berikutnya wajib merekonsiliasi FIFO. Offline dan Bundle tetap diblokir.</div>

      {pending && <ConfirmChange session={session} pending={pending} close={() => setPending(null)} complete={async () => { const message = pending.success; setPending(null); await refresh(); setPermissionForm(emptyPermission(settings)); notify(message) }} />}
    </section>
  )
}

function ConfirmChange({ session, pending, close, complete }: { session: Session; pending: Pending; close: () => void; complete: () => Promise<void> }) {
  useEscapeClose(close)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  async function confirm() {
    setSaving(true)
    setError('')
    try {
      const response = await fetch('/api/platform/negative-stock-settings', { method: 'PATCH', headers: { 'Content-Type': 'application/json', ...authHeaders(session) }, body: JSON.stringify(pending.body) })
      const payload = await response.json() as { error?: string }
      if (!response.ok) throw new Error(friendlyError(payload.error))
      await complete()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal menyimpan perubahan.')
    } finally {
      setSaving(false)
    }
  }
  return <div className="fixed inset-0 z-[95] grid place-items-center overflow-y-auto bg-slate-950/50 p-4 backdrop-blur-sm"><div className="w-full max-w-lg rounded-3xl bg-white shadow-2xl"><div className="flex items-start justify-between border-b border-slate-100 p-6"><div><p className="text-xs font-bold uppercase tracking-[.14em] text-rose-600">Konfirmasi stok minus</p><h2 className="mt-2 text-xl font-black text-slate-950">{pending.title}</h2></div><button type="button" onClick={close} className="rounded-xl border border-slate-200 p-2 text-slate-500" aria-label="Tutup"><X className="h-5 w-5" /></button></div><div className="space-y-4 p-6"><p className="text-sm leading-6 text-slate-600">{pending.description}</p>{error && <div className="rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">{error}</div>}<div className="flex justify-end gap-3"><button type="button" onClick={close} className="rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold text-slate-600">Batal</button><button type="button" disabled={saving} onClick={() => void confirm()} className="rounded-xl bg-slate-950 px-4 py-2.5 text-sm font-bold text-white disabled:opacity-50">{saving ? 'Menyimpan...' : 'Ya, simpan'}</button></div></div></div></div>
}
