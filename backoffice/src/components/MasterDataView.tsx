'use client'

import { useCallback, useEffect, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { useEscapeClose } from '@/lib/use-escape-close'
import {
  BadgePercent,
  Boxes,
  Edit3,
  Loader2,
  Plus,
  RefreshCcw,
  Ruler,
  Tags,
  Trash2,
  Warehouse,
  X,
} from 'lucide-react'

type StoreOption = { id: string; store_code: string; store_name: string }
type MasterKind = 'category' | 'uom' | 'warehouse'

type Category = {
  id: string
  category_code: string
  category_name: string
  is_active: boolean
  master_version: number
  default_sales_tax_rule_id: string | null
  default_purchase_tax_rule_id: string | null
}

type TaxRuleOption = {
  id: string
  name: string
  scope: 'SALES' | 'PURCHASE'
  ratePercent: number | string
}

type Uom = {
  id: string
  code: string
  name: string
  uom_type: string
  allow_decimal: boolean
  decimal_precision: number
  is_active: boolean
  master_version: number
}

type WarehouseRow = {
  id: string
  code: string
  name: string
  warehouse_type: string | null
  store_id: string | null
  location: string | null
  is_sale_source: boolean
  is_purchase_destination: boolean
  is_active: boolean
  master_version: number
}

type Editor =
  | { kind: 'category'; record?: Category }
  | { kind: 'category-tax'; record: Category }
  | { kind: 'uom'; record?: Uom }
  | { kind: 'warehouse'; record?: WarehouseRow }

type DeleteTarget = {
  kind: 'category' | 'uom'
  id: string
  name: string
  masterVersion: number
}

type ApiItem<T> = { data?: T; error?: string }
type InventoryMastersPayload = {
  categories?: Category[]
  uoms?: Uom[]
  warehouses?: WarehouseRow[]
  taxRules?: TaxRuleOption[]
  entitlements?: { salesEnabled: boolean; purchaseEnabled: boolean }
  error?: string
}

const tabs: { id: MasterKind; label: string; icon: typeof Boxes }[] = [
  { id: 'category', label: 'Kategori Produk', icon: Tags },
  { id: 'uom', label: 'UOM', icon: Ruler },
  { id: 'warehouse', label: 'Gudang', icon: Warehouse },
]

const uomTypeLabels: Record<string, string> = {
  UNIT: 'Unit',
  PACKAGING: 'Kemasan',
  WEIGHT: 'Berat',
  VOLUME: 'Volume',
  LENGTH: 'Panjang',
  OTHER: 'Lainnya',
}

const warehouseTypeLabels: Record<string, string> = {
  CENTRAL: 'Pusat',
  STORE: 'Toko',
  DAMAGED: 'Rusak',
  TRANSIT: 'Transit',
}

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` }
}

function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    DUPLICATE_MASTER: 'Nama sudah digunakan pada company aktif.',
    MASTER_VERSION_CONFLICT: 'Data sudah berubah di tab lain. Muat ulang lalu coba lagi.',
    MASTER_VERSION_CONFLICT_OR_NOT_FOUND: 'Data sudah berubah atau tidak lagi tersedia.',
    FORBIDDEN: 'Role Anda tidak diizinkan mengubah master ini.',
    CUSTOM_PERMISSION_DENIED: 'Akses Anda hanya untuk melihat Master Inventory.',
    STORE_WAREHOUSE_REQUIRES_STORE: 'Gudang bertipe Toko wajib memilih toko.',
    ACTIVE_STORE_NOT_FOUND: 'Toko tidak aktif atau bukan milik company aktif.',
    TAX_SALES_FEATURE_DISABLED: 'Modul Pajak Penjualan belum diaktifkan.',
    TAX_PURCHASE_FEATURE_DISABLED: 'Modul Pajak Pembelian belum diaktifkan.',
    CURRENT_SALES_TAX_RULE_REQUIRED: 'Pilih aturan Pajak Penjualan aktif yang berlaku saat ini.',
    CURRENT_PURCHASE_TAX_RULE_REQUIRED: 'Pilih aturan Pajak Pembelian aktif yang berlaku saat ini.',
    PRODUCT_CATEGORY_NOT_FOUND: 'Kategori tidak ditemukan pada company aktif.',
    UOM_IN_USE: 'UOM sudah dipakai oleh produk atau transaksi sehingga tidak dapat dihapus. Nonaktifkan UOM melalui menu Edit.',
    PRODUCT_CATEGORY_IN_USE: 'Kategori sudah dipakai atau memiliki referensi sehingga tidak dapat dihapus. Pindahkan referensinya atau nonaktifkan kategori melalui menu Edit.',
    UOM_SEMANTICS_LOCKED_BY_USAGE: 'Tipe dan aturan quantity UOM yang sudah dipakai tidak dapat diubah. Nama dan status masih dapat diperbarui.',
    MASTER_NOT_FOUND: 'Data tidak ditemukan pada company aktif.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi master data gagal.'
}

export function MasterDataView({
  session,
  companyId,
  stores,
  canManage,
  notify,
}: {
  session: Session
  companyId: string
  stores: StoreOption[]
  canManage: boolean
  notify: (message: string) => void
}) {
  const [activeTab, setActiveTab] = useState<MasterKind>('category')
  const [categories, setCategories] = useState<Category[]>([])
  const [uoms, setUoms] = useState<Uom[]>([])
  const [warehouses, setWarehouses] = useState<WarehouseRow[]>([])
  const [taxRules, setTaxRules] = useState<TaxRuleOption[]>([])
  const [taxEntitlements, setTaxEntitlements] = useState({
    salesEnabled: false,
    purchaseEnabled: false,
  })
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [editor, setEditor] = useState<Editor | null>(null)
  const [deleteTarget, setDeleteTarget] = useState<DeleteTarget | null>(null)

  const loadMasters = useCallback(async () => {
    const response = await fetch('/api/master/inventory-masters?includeInactive=true', {
      headers: authHeaders(session),
    })
    const payload = (await response.json()) as InventoryMastersPayload
    if (!response.ok) throw new Error(friendlyError(payload.error))
    return payload
  }, [session])

  useEffect(() => {
    let cancelled = false
    loadMasters()
      .then((payload) => {
        if (cancelled) return
        setCategories(payload.categories ?? [])
        setUoms(payload.uoms ?? [])
        setWarehouses(payload.warehouses ?? [])
        setTaxRules(payload.taxRules ?? [])
        setTaxEntitlements(payload.entitlements ?? {
          salesEnabled: false,
          purchaseEnabled: false,
        })
      })
      .catch((caught) => {
        if (!cancelled) {
          setError(caught instanceof Error ? caught.message : 'Gagal memuat master data.')
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [companyId, loadMasters])

  async function refreshMasters() {
    setLoading(true)
    setError('')
    try {
      const payload = await loadMasters()
      setCategories(payload.categories ?? [])
      setUoms(payload.uoms ?? [])
      setWarehouses(payload.warehouses ?? [])
      setTaxRules(payload.taxRules ?? [])
      setTaxEntitlements(payload.entitlements ?? {
        salesEnabled: false,
        purchaseEnabled: false,
      })
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal memuat master data.')
    } finally {
      setLoading(false)
    }
  }

  async function save(path: string, method: 'POST' | 'PATCH', body: object) {
    const response = await fetch(path, {
      method,
      headers: { 'Content-Type': 'application/json', ...authHeaders(session) },
      body: JSON.stringify(body),
    })
    const payload = (await response.json()) as ApiItem<unknown>
    if (!response.ok) throw new Error(friendlyError(payload.error))
    setEditor(null)
    await refreshMasters()
    notify('Master data berhasil disimpan.')
  }

  async function remove(target: DeleteTarget) {
    const path = target.kind === 'uom'
      ? `/api/master/uoms/${target.id}`
      : `/api/master/product-categories/${target.id}`
    const response = await fetch(path, {
      method: 'DELETE',
      headers: { 'Content-Type': 'application/json', ...authHeaders(session) },
      body: JSON.stringify({ masterVersion: target.masterVersion }),
    })
    const payload = (await response.json()) as ApiItem<unknown>
    if (!response.ok) throw new Error(friendlyError(payload.error))
    setDeleteTarget(null)
    await refreshMasters()
    notify(`${target.kind === 'uom' ? 'UOM' : 'Kategori'} berhasil dihapus.`)
  }

  const currentCount =
    activeTab === 'category'
      ? categories.length
      : activeTab === 'uom'
        ? uoms.length
        : warehouses.length

  return (
    <>
      <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">Master Data</p>
          <h1 className="mt-2 text-2xl font-black tracking-tight text-slate-950 md:text-3xl">
            Referensi produk & stok
          </h1>
          <p className="mt-2 text-sm text-slate-500">
            Kelola kategori, satuan, dan gudang untuk company aktif sebelum membuat produk.
          </p>
        </div>
        <div className="flex gap-2">
          <button
            onClick={() => void refreshMasters()}
            className="inline-flex items-center gap-2 rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm font-bold text-slate-600"
          >
            <RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /> Muat ulang
          </button>
          {canManage && (
            <button
              onClick={() => setEditor({ kind: activeTab })}
              className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 text-sm font-bold text-white"
            >
              <Plus className="h-4 w-4" /> Tambah
            </button>
          )}
        </div>
      </div>

      <div className="mb-5 grid gap-2 rounded-2xl border border-slate-200 bg-white p-2 shadow-sm sm:grid-cols-3">
        {tabs.map((tab) => {
          const Icon = tab.icon
          const active = activeTab === tab.id
          return (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id)}
              className={`flex items-center justify-center gap-2 rounded-xl px-4 py-3 text-sm font-bold transition ${
                active ? 'bg-slate-950 text-white' : 'text-slate-500 hover:bg-slate-50'
              }`}
            >
              <Icon className="h-4 w-4" /> {tab.label}
            </button>
          )
        })}
      </div>

      {error && (
        <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">
          {error}
        </div>
      )}

      <div data-master-kind={activeTab} className="rounded-2xl border border-slate-200 bg-white shadow-sm">
        <div className="flex items-center justify-between border-b border-slate-100 px-5 py-4">
          <p className="text-sm font-bold text-slate-900">{tabs.find((tab) => tab.id === activeTab)?.label}</p>
          <span className="text-xs font-semibold text-slate-400">{currentCount} record</span>
        </div>
        {loading ? (
          <div className="flex items-center justify-center gap-2 p-12 text-sm text-slate-500">
            <Loader2 className="h-4 w-4 animate-spin" /> Memuat master data...
          </div>
        ) : activeTab === 'category' ? (
          <CategoryTable
            rows={categories}
            taxRules={taxRules}
            canManage={canManage}
            edit={(record) => setEditor({ kind: 'category', record })}
            editTax={(record) => setEditor({ kind: 'category-tax', record })}
            remove={(record) => setDeleteTarget({
              kind: 'category',
              id: record.id,
              name: record.category_name,
              masterVersion: record.master_version,
            })}
          />
        ) : activeTab === 'uom' ? (
          <UomTable
            rows={uoms}
            canManage={canManage}
            edit={(record) => setEditor({ kind: 'uom', record })}
            remove={(record) => setDeleteTarget({
              kind: 'uom',
              id: record.id,
              name: record.name,
              masterVersion: record.master_version,
            })}
          />
        ) : (
          <WarehouseTable
            rows={warehouses}
            stores={stores}
            canManage={canManage}
            edit={(record) => setEditor({ kind: 'warehouse', record })}
          />
        )}
      </div>

      {editor && (
        <MasterEditor
          key={`${editor.kind}:${editor.record?.id ?? 'new'}`}
          editor={editor}
          stores={stores}
          taxRules={taxRules}
          taxEntitlements={taxEntitlements}
          close={() => setEditor(null)}
          save={save}
        />
      )}
      {deleteTarget && (
        <DeleteMasterDialog
          target={deleteTarget}
          close={() => setDeleteTarget(null)}
          remove={remove}
        />
      )}
    </>
  )
}

function StatusBadge({ active }: { active: boolean }) {
  return (
    <span className={`rounded-full px-2.5 py-1 text-[11px] font-bold ${active ? 'bg-emerald-50 text-emerald-700' : 'bg-slate-100 text-slate-500'}`}>
      {active ? 'Aktif' : 'Nonaktif'}
    </span>
  )
}

function EditButton({ onClick }: { onClick: () => void }) {
  return <button onClick={onClick} className="rounded-lg border border-slate-200 p-2 text-slate-500 hover:text-emerald-600" aria-label="Edit"><Edit3 className="h-4 w-4" /></button>
}

function DeleteButton({ onClick }: { onClick: () => void }) {
  return <button onClick={onClick} className="rounded-lg border border-rose-200 p-2 text-rose-600 hover:bg-rose-50" aria-label="Hapus"><Trash2 className="h-4 w-4" /></button>
}

function EmptyRow({ columns }: { columns: number }) {
  return <tr><td colSpan={columns} className="p-10 text-center text-sm text-slate-400">Belum ada data.</td></tr>
}

function CategoryTable({ rows, taxRules, canManage, edit, editTax, remove }: { rows: Category[]; taxRules: TaxRuleOption[]; canManage: boolean; edit: (row: Category) => void; editTax: (row: Category) => void; remove: (row: Category) => void }) {
  const taxName = (id: string | null) => taxRules.find((rule) => rule.id === id)?.name ?? 'Tidak ada'
  return <div className="overflow-x-auto"><table className="w-full min-w-[720px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500"><tr><th className="px-5 py-4">Nama kategori</th><th className="px-5 py-4">Pajak default</th><th className="px-5 py-4">Status</th>{canManage && <th className="px-5 py-4 text-right">Aksi</th>}</tr></thead><tbody className="divide-y divide-slate-100">{rows.map((row) => <tr key={row.id}><td className="px-5 py-4 font-bold">{row.category_name}</td><td className="px-5 py-4 text-xs leading-5 text-slate-600"><span className="block">Jual: {taxName(row.default_sales_tax_rule_id)}</span><span className="block">Beli: {taxName(row.default_purchase_tax_rule_id)}</span></td><td className="px-5 py-4"><StatusBadge active={row.is_active} /></td>{canManage && <td className="px-5 py-4"><div className="flex justify-end gap-2"><button onClick={() => editTax(row)} className="rounded-lg border border-slate-200 p-2 text-slate-500 hover:text-blue-600" aria-label="Atur pajak kategori"><BadgePercent className="h-4 w-4" /></button><EditButton onClick={() => edit(row)} /><DeleteButton onClick={() => remove(row)} /></div></td>}</tr>)}{!rows.length && <EmptyRow columns={canManage ? 4 : 3} />}</tbody></table></div>
}

function UomTable({ rows, canManage, edit, remove }: { rows: Uom[]; canManage: boolean; edit: (row: Uom) => void; remove: (row: Uom) => void }) {
  return <div className="overflow-x-auto"><table className="w-full min-w-[680px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500"><tr><th className="px-5 py-4">Nama satuan</th><th className="px-5 py-4">Tipe</th><th className="px-5 py-4">Quantity</th><th className="px-5 py-4">Status</th>{canManage && <th className="px-5 py-4 text-right">Aksi</th>}</tr></thead><tbody className="divide-y divide-slate-100">{rows.map((row) => <tr key={row.id}><td className="px-5 py-4 font-bold">{row.name}</td><td className="px-5 py-4 text-slate-600">{uomTypeLabels[row.uom_type] ?? row.uom_type}</td><td className="px-5 py-4 text-slate-600">{row.allow_decimal ? `Desimal · ${row.decimal_precision} digit` : 'Bilangan bulat'}</td><td className="px-5 py-4"><StatusBadge active={row.is_active} /></td>{canManage && <td className="px-5 py-4"><div className="flex justify-end gap-2"><EditButton onClick={() => edit(row)} /><DeleteButton onClick={() => remove(row)} /></div></td>}</tr>)}{!rows.length && <EmptyRow columns={canManage ? 5 : 4} />}</tbody></table></div>
}

function WarehouseTable({ rows, stores, canManage, edit }: { rows: WarehouseRow[]; stores: StoreOption[]; canManage: boolean; edit: (row: WarehouseRow) => void }) {
  return <div className="overflow-x-auto"><table className="w-full min-w-[860px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500"><tr><th className="px-5 py-4">Gudang</th><th className="px-5 py-4">Tipe</th><th className="px-5 py-4">Toko</th><th className="px-5 py-4">Penggunaan</th><th className="px-5 py-4">Status</th>{canManage && <th className="px-5 py-4 text-right">Aksi</th>}</tr></thead><tbody className="divide-y divide-slate-100">{rows.map((row) => { const store = stores.find((item) => item.id === row.store_id); return <tr key={row.id}><td className="px-5 py-4 font-bold">{row.name}</td><td className="px-5 py-4 text-slate-600">{row.warehouse_type ? warehouseTypeLabels[row.warehouse_type] ?? row.warehouse_type : 'Belum diklasifikasi'}</td><td className="px-5 py-4 text-slate-600">{store?.store_name ?? '-'}</td><td className="px-5 py-4 text-xs text-slate-500">{[row.is_sale_source && 'Penjualan', row.is_purchase_destination && 'Penerimaan pembelian'].filter(Boolean).join(' · ') || '-'}</td><td className="px-5 py-4"><StatusBadge active={row.is_active} /></td>{canManage && <td className="px-5 py-4 text-right"><EditButton onClick={() => edit(row)} /></td>}</tr>})}{!rows.length && <EmptyRow columns={canManage ? 6 : 5} />}</tbody></table></div>
}

function MasterEditor({ editor, stores, taxRules, taxEntitlements, close, save }: { editor: Editor; stores: StoreOption[]; taxRules: TaxRuleOption[]; taxEntitlements: { salesEnabled: boolean; purchaseEnabled: boolean }; close: () => void; save: (path: string, method: 'POST' | 'PATCH', body: object) => Promise<void> }) {
  if (editor.kind === 'category') return <CategoryEditor record={editor.record} close={close} save={save} />
  if (editor.kind === 'category-tax') return <CategoryTaxEditor record={editor.record} taxRules={taxRules} entitlements={taxEntitlements} close={close} save={save} />
  if (editor.kind === 'uom') return <UomEditor record={editor.record} close={close} save={save} />
  return <WarehouseEditor record={editor.record} stores={stores} close={close} save={save} />
}

function EditorShell({ title, description, close, children }: { title: string; description: string; close: () => void; children: React.ReactNode }) {
  useEscapeClose(close)
  return <div className="fixed inset-0 z-[80] grid place-items-center bg-slate-950/45 p-4 backdrop-blur-sm"><div className="max-h-[92vh] w-full max-w-xl overflow-y-auto rounded-3xl bg-white p-6 shadow-2xl sm:p-8"><div className="flex items-start justify-between gap-4"><div><h2 className="text-xl font-black">{title}</h2><p className="mt-2 text-sm leading-6 text-slate-500">{description}</p></div><button onClick={close} className="rounded-xl bg-slate-100 p-2 text-slate-500" aria-label="Tutup"><X className="h-4 w-4" /></button></div><div className="mt-7">{children}</div></div></div>
}

function DeleteMasterDialog({ target, close, remove }: { target: DeleteTarget; close: () => void; remove: (target: DeleteTarget) => Promise<void> }) {
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')

  async function confirm() {
    setLoading(true)
    setError('')
    try {
      await remove(target)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal menghapus master data.')
    } finally {
      setLoading(false)
    }
  }

  return <EditorShell title={`Hapus ${target.kind === 'uom' ? 'UOM' : 'kategori'}?`} description={`Anda akan menghapus “${target.name}” secara permanen.`} close={close}><div className="space-y-4"><div className="rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900">Penghapusan hanya berhasil jika data belum pernah dipakai. Jika sudah dipakai oleh produk, transaksi, pajak, atau konfigurasi lain, gunakan Edit lalu ubah status menjadi Nonaktif.</div>{error && <EditorError message={error} />}<div className="mt-7 flex justify-end gap-3 border-t border-slate-100 pt-5"><button type="button" onClick={close} disabled={loading} className="rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold text-slate-600 disabled:opacity-60">Batal</button><button type="button" onClick={() => void confirm()} disabled={loading} className="inline-flex items-center gap-2 rounded-xl bg-rose-600 px-5 py-2.5 text-sm font-bold text-white disabled:opacity-60">{loading ? <Loader2 className="h-4 w-4 animate-spin" /> : <Trash2 className="h-4 w-4" />}Hapus permanen</button></div></div></EditorShell>
}

function EditorActions({ close, loading }: { close: () => void; loading: boolean }) {
  return <div className="mt-7 flex justify-end gap-3 border-t border-slate-100 pt-5"><button type="button" onClick={close} className="rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold text-slate-600">Batal</button><button disabled={loading} className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-5 py-2.5 text-sm font-bold text-white disabled:opacity-60">{loading && <Loader2 className="h-4 w-4 animate-spin" />}Simpan</button></div>
}

function FormField({ label, children }: { label: string; children: React.ReactNode }) {
  return <label className="block text-sm font-semibold text-slate-700">{label}<span className="mt-2 block">{children}</span></label>
}

function EditorError({ message }: { message: string }) {
  return <div className="rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">{message}</div>
}

function ActiveCheckbox({ checked, change }: { checked: boolean; change: (value: boolean) => void }) {
  return <label className="flex items-center gap-3 rounded-xl border border-slate-200 p-3 text-sm font-semibold text-slate-700"><input type="checkbox" checked={checked} onChange={(event) => change(event.target.checked)} className="h-4 w-4 accent-emerald-500" />Master aktif dan dapat dipakai</label>
}

function CategoryEditor({ record, close, save }: { record?: Category; close: () => void; save: MasterEditorProps['save'] }) {
  const [form, setForm] = useState({ categoryName: record?.category_name ?? '', isActive: record?.is_active ?? true })
  const [loading, setLoading] = useState(false); const [error, setError] = useState('')
  async function submit(event: React.FormEvent) { event.preventDefault(); setLoading(true); setError(''); try { await save(record ? `/api/master/product-categories/${record.id}` : '/api/master/product-categories', record ? 'PATCH' : 'POST', { ...form, ...(record ? { masterVersion: record.master_version } : {}) }) } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal menyimpan kategori.') } finally { setLoading(false) } }
  return <EditorShell title={record ? 'Edit kategori' : 'Kategori baru'} description="Nama harus unik pada company aktif. Identitas internal dibuat otomatis oleh sistem." close={close}><form onSubmit={submit} className="space-y-4"><FormField label="Nama kategori"><input required maxLength={150} value={form.categoryName} onChange={(event) => setForm({ ...form, categoryName: event.target.value })} className="input" /></FormField><ActiveCheckbox checked={form.isActive} change={(isActive) => setForm({ ...form, isActive })} />{error && <EditorError message={error} />}<EditorActions close={close} loading={loading} /></form></EditorShell>
}

function CategoryTaxEditor({ record, taxRules, entitlements, close, save }: { record: Category; taxRules: TaxRuleOption[]; entitlements: { salesEnabled: boolean; purchaseEnabled: boolean }; close: () => void; save: MasterEditorProps['save'] }) {
  const [form, setForm] = useState({
    salesTaxRuleId: record.default_sales_tax_rule_id ?? '',
    purchaseTaxRuleId: record.default_purchase_tax_rule_id ?? '',
  })
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  const salesRules = taxRules.filter((rule) => rule.scope === 'SALES')
  const purchaseRules = taxRules.filter((rule) => rule.scope === 'PURCHASE')
  async function submit(event: React.FormEvent) {
    event.preventDefault()
    setLoading(true)
    setError('')
    try {
      await save(`/api/master/product-categories/${record.id}/tax-assignment`, 'PATCH', {
        masterVersion: record.master_version,
        salesTaxRuleId: form.salesTaxRuleId || null,
        purchaseTaxRuleId: form.purchaseTaxRuleId || null,
      })
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal menyimpan pajak kategori.')
    } finally {
      setLoading(false)
    }
  }
  return <EditorShell title="Pajak default kategori" description={`${record.category_name}: Product akan memakai aturan ini kecuali Product memiliki override.`} close={close}><form onSubmit={submit} className="space-y-4"><div className="rounded-xl border border-blue-200 bg-blue-50 p-4 text-xs leading-5 text-blue-800">Assignment ini hanya menentukan aturan default. Kalkulasi pajak transaksi belum diaktifkan pada fase ini.</div>{entitlements.salesEnabled ? <FormField label="Pajak penjualan default"><select value={form.salesTaxRuleId} onChange={(event) => setForm({ ...form, salesTaxRuleId: event.target.value })} className="input"><option value="">Tanpa pajak penjualan</option>{salesRules.map((rule) => <option key={rule.id} value={rule.id}>{rule.name} ({Number(rule.ratePercent).toLocaleString('id-ID')}%)</option>)}</select></FormField> : <div className="rounded-xl bg-slate-100 p-4 text-sm text-slate-600">Pajak Penjualan belum diaktifkan pada Pengaturan Modul.</div>}{entitlements.purchaseEnabled ? <FormField label="Pajak pembelian default"><select value={form.purchaseTaxRuleId} onChange={(event) => setForm({ ...form, purchaseTaxRuleId: event.target.value })} className="input"><option value="">Tanpa pajak pembelian</option>{purchaseRules.map((rule) => <option key={rule.id} value={rule.id}>{rule.name} ({Number(rule.ratePercent).toLocaleString('id-ID')}%)</option>)}</select></FormField> : <div className="rounded-xl bg-slate-100 p-4 text-sm text-slate-600">Pajak Pembelian belum diaktifkan pada Pengaturan Modul.</div>}{error && <EditorError message={error} />}<EditorActions close={close} loading={loading} /></form></EditorShell>
}

type MasterEditorProps = { save: (path: string, method: 'POST' | 'PATCH', body: object) => Promise<void> }

function UomEditor({ record, close, save }: { record?: Uom; close: () => void; save: MasterEditorProps['save'] }) {
  const [form, setForm] = useState({ name: record?.name ?? '', uomType: record?.uom_type ?? 'UNIT', allowDecimal: record?.allow_decimal ?? false, decimalPrecision: record?.decimal_precision ?? 0, isActive: record?.is_active ?? true })
  const [loading, setLoading] = useState(false); const [error, setError] = useState('')
  async function submit(event: React.FormEvent) { event.preventDefault(); setLoading(true); setError(''); try { await save(record ? `/api/master/uoms/${record.id}` : '/api/master/uoms', record ? 'PATCH' : 'POST', { ...form, decimalPrecision: form.allowDecimal ? form.decimalPrecision || 3 : 0, ...(record ? { masterVersion: record.master_version } : {}) }) } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal menyimpan UOM.') } finally { setLoading(false) } }
  return <EditorShell title={record ? 'Edit UOM' : 'UOM baru'} description="Gunakan nama satuan yang dikenali user. Precision menentukan quantity yang boleh dimasukkan; identitas internal dibuat otomatis." close={close}><form onSubmit={submit} className="space-y-4"><FormField label="Nama UOM"><input required maxLength={100} value={form.name} onChange={(event) => setForm({ ...form, name: event.target.value })} className="input" /></FormField><FormField label="Tipe UOM"><select value={form.uomType} onChange={(event) => setForm({ ...form, uomType: event.target.value })} className="input">{Object.entries(uomTypeLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></FormField><label className="flex items-center gap-3 rounded-xl border border-slate-200 p-3 text-sm font-semibold text-slate-700"><input type="checkbox" checked={form.allowDecimal} onChange={(event) => setForm({ ...form, allowDecimal: event.target.checked, decimalPrecision: event.target.checked ? 3 : 0 })} className="h-4 w-4 accent-emerald-500" />Quantity boleh pecahan</label>{form.allowDecimal && <FormField label="Digit desimal"><input type="number" min={1} max={6} required value={form.decimalPrecision} onChange={(event) => setForm({ ...form, decimalPrecision: Number(event.target.value) })} className="input" /></FormField>}<ActiveCheckbox checked={form.isActive} change={(isActive) => setForm({ ...form, isActive })} />{error && <EditorError message={error} />}<EditorActions close={close} loading={loading} /></form></EditorShell>
}

function WarehouseEditor({ record, stores, close, save }: { record?: WarehouseRow; stores: StoreOption[]; close: () => void; save: MasterEditorProps['save'] }) {
  const [form, setForm] = useState({ name: record?.name ?? '', warehouseType: record?.warehouse_type ?? 'CENTRAL', storeId: record?.store_id ?? '', location: record?.location ?? '', isSaleSource: record?.is_sale_source ?? false, isPurchaseDestination: record?.is_purchase_destination ?? false, isActive: record?.is_active ?? true })
  const [loading, setLoading] = useState(false); const [error, setError] = useState('')
  async function submit(event: React.FormEvent) { event.preventDefault(); setLoading(true); setError(''); try { await save(record ? `/api/master/warehouses/${record.id}` : '/api/master/warehouses', record ? 'PATCH' : 'POST', { ...form, storeId: form.storeId || null, ...(record ? { masterVersion: record.master_version } : {}) }) } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal menyimpan gudang.') } finally { setLoading(false) } }
  return <EditorShell title={record ? 'Edit gudang' : 'Gudang baru'} description="Gudang toko wajib terhubung ke Store aktif. Nama harus unik dan identitas internal dibuat otomatis." close={close}><form onSubmit={submit} className="space-y-4"><FormField label="Nama gudang"><input required maxLength={150} value={form.name} onChange={(event) => setForm({ ...form, name: event.target.value })} className="input" /></FormField><div className="grid gap-4 sm:grid-cols-2"><FormField label="Tipe gudang"><select value={form.warehouseType} onChange={(event) => setForm({ ...form, warehouseType: event.target.value, storeId: event.target.value === 'STORE' ? form.storeId : '' })} className="input">{Object.entries(warehouseTypeLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></FormField><FormField label="Toko terkait"><select required={form.warehouseType === 'STORE'} disabled={form.warehouseType !== 'STORE'} value={form.storeId} onChange={(event) => setForm({ ...form, storeId: event.target.value })} className="input disabled:bg-slate-100"><option value="">Tidak terkait toko</option>{stores.map((store) => <option key={store.id} value={store.id}>{store.store_name} ({store.store_code})</option>)}</select></FormField></div><FormField label="Lokasi / alamat (opsional)"><textarea maxLength={500} rows={3} placeholder="Boleh kosong atau sama untuk beberapa gudang fungsional" value={form.location} onChange={(event) => setForm({ ...form, location: event.target.value })} className="input resize-none" /></FormField><div className="grid gap-3 sm:grid-cols-2"><label className="flex items-start gap-3 rounded-xl border border-slate-200 p-3 text-sm font-semibold"><input type="checkbox" checked={form.isSaleSource} onChange={(event) => setForm({ ...form, isSaleSource: event.target.checked })} className="mt-0.5 h-4 w-4 accent-emerald-500" /><span>Sumber stok penjualan<span className="mt-1 block text-xs font-normal leading-5 text-slate-500">Stok barang penjualan boleh dipotong dari gudang ini.</span></span></label><label className="flex items-start gap-3 rounded-xl border border-slate-200 p-3 text-sm font-semibold"><input type="checkbox" checked={form.isPurchaseDestination} onChange={(event) => setForm({ ...form, isPurchaseDestination: event.target.checked })} className="mt-0.5 h-4 w-4 accent-emerald-500" /><span>Dapat menerima stok pembelian<span className="mt-1 block text-xs font-normal leading-5 text-slate-500">Gudang penerimaan barang dari vendor, bukan alamat vendor.</span></span></label></div><ActiveCheckbox checked={form.isActive} change={(isActive) => setForm({ ...form, isActive })} />{error && <EditorError message={error} />}<EditorActions close={close} loading={loading} /></form></EditorShell>
}
