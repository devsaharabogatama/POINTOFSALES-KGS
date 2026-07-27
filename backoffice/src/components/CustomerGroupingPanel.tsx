'use client'

import { useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { Loader2, X } from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'

export type GroupableCustomer = {
  id: string; code: string; name: string; customer_category_id: string
  parent_customer_id: string | null; phone: string | null; email: string | null
  address: string | null; customer_type: string; credit_limit: number | string
  credit_term_days: number | null; notes: string | null; is_active: boolean
  is_system_customer: boolean; master_version: number
}

const headers = (session: Session) => ({ Authorization: `Bearer ${session.access_token}` })

export function CustomerGroupingPanel({ session, customers, canManage, refresh, notify }: { session: Session; customers: GroupableCustomer[]; canManage: boolean; refresh: () => Promise<void>; notify: (message: string) => void }) {
  const regular = useMemo(() => customers.filter((item) => !item.is_system_customer), [customers])
  const roots = regular.filter((item) => !item.parent_customer_id)
  const eligibleChildren = regular.filter((item) => !regular.some((other) => other.parent_customer_id === item.id))
  const [editing, setEditing] = useState(false)
  const [childId, setChildId] = useState('')
  const [parentId, setParentId] = useState('')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  useEscapeClose(() => setEditing(false))

  function open() {
    const first = eligibleChildren[0]
    setChildId(first?.id ?? '')
    setParentId(first?.parent_customer_id ?? '')
    setError('')
    setEditing(true)
  }

  async function submit(event: React.FormEvent) {
    event.preventDefault()
    const customer = regular.find((item) => item.id === childId)
    if (!customer) return
    setSaving(true); setError('')
    try {
      const response = await fetch(`/api/master/customers/${customer.id}`, {
        method: 'PATCH', headers: { 'Content-Type': 'application/json', ...headers(session) },
        body: JSON.stringify({
          masterVersion: customer.master_version, customerCode: customer.code,
          customerName: customer.name, customerCategoryId: customer.customer_category_id,
          parentCustomerId: parentId || null, phone: customer.phone, email: customer.email,
          address: customer.address, customerType: customer.customer_type,
          creditLimit: Number(customer.credit_limit), creditTermDays: customer.credit_term_days,
          notes: customer.notes, isActive: customer.is_active,
        }),
      })
      const payload = await response.json() as { error?: string }
      if (!response.ok) throw new Error(errorMessage(payload.error))
      setEditing(false); await refresh(); notify('Grouping Customer berhasil disimpan.')
    } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal menyimpan grouping Customer.') }
    finally { setSaving(false) }
  }

  return <div className="mt-5 rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"><div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between"><div><h2 className="font-black">Grouping Customer induk & cabang</h2><p className="mt-1 text-sm leading-6 text-slate-500">Transaksi dan saldo tetap per Customer. Induk hanya dipakai untuk menggabungkan laporan.</p></div>{canManage && regular.length > 1 && <button onClick={open} className="rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold">Atur grouping</button>}</div><div className="mt-4 grid gap-3 md:grid-cols-2">{roots.map((root) => { const children = regular.filter((item) => item.parent_customer_id === root.id); return <div key={root.id} className="rounded-xl bg-slate-50 p-4"><p className="font-bold">{root.name}</p><p className="mt-1 text-xs text-slate-400">{children.length ? `${children.length} Customer cabang` : 'Customer mandiri'}</p>{children.length > 0 && <div className="mt-3 flex flex-wrap gap-2">{children.map((child) => <span key={child.id} className="rounded-full bg-white px-2.5 py-1 text-xs font-semibold">{child.name}</span>)}</div>}</div>})}</div>{editing && <div className="fixed inset-0 z-[80] overflow-y-auto bg-slate-950/50 p-4 backdrop-blur-sm"><div className="mx-auto my-8 max-w-xl rounded-3xl bg-white p-6 shadow-2xl"><div className="flex justify-between"><div><h3 className="text-xl font-black">Atur grouping Customer</h3><p className="mt-2 text-sm text-slate-500">Satu tingkat saja: Customer cabang tidak dapat menjadi induk.</p></div><button onClick={() => setEditing(false)} aria-label="Tutup"><X /></button></div><form onSubmit={submit} className="mt-6 space-y-5"><Field label="Customer cabang"><select required value={childId} onChange={(event) => { const id=event.target.value; setChildId(id); setParentId(regular.find((item) => item.id===id)?.parent_customer_id ?? '') }} className="input">{eligibleChildren.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></Field><Field label="Customer induk"><select value={parentId} onChange={(event) => setParentId(event.target.value)} className="input"><option value="">Tidak memiliki induk / Customer mandiri</option>{roots.filter((item) => item.id !== childId).map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></Field><div className="rounded-xl bg-blue-50 p-3 text-sm text-blue-800">Pencatatan transaksi tidak dipindahkan. Laporan nanti dapat di-roll-up berdasarkan Customer induk.</div>{error && <div className="rounded-xl bg-rose-50 p-3 text-sm text-rose-700">{error}</div>}<div className="flex justify-end gap-3"><button type="button" onClick={() => setEditing(false)} className="rounded-xl border px-4 py-2.5 font-bold">Batal</button><button disabled={saving} className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-4 py-2.5 font-bold text-white">{saving && <Loader2 className="h-4 w-4 animate-spin" />}Simpan</button></div></form></div></div>}</div>
}

function Field({ label, children }: { label: string; children: React.ReactNode }) { return <label className="block"><span className="mb-2 block text-sm font-bold">{label}</span>{children}</label> }
function errorMessage(code?: string) { const map: Record<string,string> = { MASTER_VERSION_CONFLICT:'Data berubah. Muat ulang lalu coba lagi.', ACTIVE_ROOT_PARENT_CUSTOMER_NOT_FOUND:'Induk harus Customer aktif, mandiri, dan satu company.', CUSTOMER_WITH_CHILDREN_CANNOT_BECOME_CHILD:'Customer yang sudah memiliki cabang tidak dapat dijadikan cabang.' }; return map[code ?? ''] ?? code ?? 'Grouping Customer gagal.' }
