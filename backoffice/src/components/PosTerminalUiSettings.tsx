'use client'

import { useCallback, useEffect, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  CircleDollarSign, Eye, EyeOff, Loader2, MonitorCog, RefreshCcw, Save,
} from 'lucide-react'

type Terminal = {
  terminalId: string
  terminalCode: string
  terminalName: string
  terminalStatus: string
  storeId: string
  storeName: string
  hiddenFeatureKeys: string[]
  allowPriceOverride: boolean
  masterVersion: number
  updatedAt: string | null
}
type Payload = { terminals?: Terminal[]; error?: string }
const features = [
  ['SALES_RETURN', 'Retur Penjualan'], ['EXPENSE', 'Expense'],
  ['STOCK_REQUEST', 'Permintaan Stok'], ['GOODS_RECEIPT', 'Terima Barang'],
  ['PURCHASE_RETURN', 'Retur Supplier'], ['CASH_DEPOSIT', 'Setor Kas'],
  ['STOCK_OPNAME', 'Stock Opname'],
  ['OFFLINE', 'Panel Offline'],
] as const

function headers(session: Session, json = false) {
  return {
    Authorization: `Bearer ${session.access_token}`,
    ...(json ? { 'Content-Type': 'application/json' } : {}),
  }
}
function friendly(code?: string) {
  return ({
    TERMINAL_UI_SETTINGS_ACCESS_DENIED: 'Anda tidak diizinkan mengatur Terminal ini.',
    POS_TERMINAL_NOT_FOUND: 'Terminal tidak ditemukan.',
    MASTER_VERSION_CONFLICT: 'Pengaturan Terminal berubah. Muat ulang lalu coba lagi.',
    INVALID_POS_TERMINAL_UI_FEATURE: 'Pilihan fitur Terminal tidak valid.',
    INVALID_POS_TERMINAL_PRICE_OVERRIDE_POLICY: 'Kebijakan perubahan harga tidak valid.',
  } as Record<string, string>)[code ?? ''] ?? code ?? 'Pengaturan POS gagal.'
}

export function PosTerminalUiSettings({
  session, companyId, notify,
}: {
  session: Session
  companyId: string
  notify: (message: string | null) => void
}) {
  const [terminals, setTerminals] = useState<Terminal[]>([])
  const [featureDrafts, setFeatureDrafts] = useState<Record<string, string[]>>({})
  const [priceDrafts, setPriceDrafts] = useState<Record<string, boolean>>({})
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState('')
  const [error, setError] = useState('')

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      const response = await fetch('/api/platform/terminal-ui-settings', {
        headers: headers(session), cache: 'no-store',
      })
      const body = await response.json() as Payload
      if (!response.ok) throw new Error(friendly(body.error))
      const next = body.terminals ?? []
      setTerminals(next)
      setFeatureDrafts(Object.fromEntries(next.map((terminal) => [
        terminal.terminalId, terminal.hiddenFeatureKeys,
      ])))
      setPriceDrafts(Object.fromEntries(next.map((terminal) => [
        terminal.terminalId, terminal.allowPriceOverride,
      ])))
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Terminal gagal dimuat.')
    } finally {
      setLoading(false)
    }
  }, [session])

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- active Company drives settings
    void load()
  }, [companyId, load])

  function toggleFeature(terminalId: string, key: string) {
    setFeatureDrafts((current) => {
      const hidden = new Set(current[terminalId] ?? [])
      if (hidden.has(key)) hidden.delete(key)
      else hidden.add(key)
      return { ...current, [terminalId]: [...hidden] }
    })
  }

  async function save(terminal: Terminal) {
    setSaving(terminal.terminalId)
    setError('')
    try {
      const response = await fetch('/api/platform/terminal-ui-settings', {
        method: 'PATCH',
        headers: headers(session, true),
        body: JSON.stringify({
          terminalId: terminal.terminalId,
          masterVersion: terminal.masterVersion,
          hiddenFeatureKeys: featureDrafts[terminal.terminalId] ?? [],
          allowPriceOverride: priceDrafts[terminal.terminalId] ?? false,
        }),
      })
      const body = await response.json() as { error?: string }
      if (!response.ok) throw new Error(friendly(body.error))
      notify(`Pengaturan ${terminal.terminalName} berhasil disimpan.`)
      await load()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Pengaturan Terminal gagal disimpan.')
    } finally {
      setSaving('')
    }
  }

  return (
    <section className="mt-7 rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <div className="flex items-center gap-2">
            <MonitorCog className="h-5 w-5 text-emerald-600" />
            <h2 className="text-lg font-black">Pengaturan per Terminal POS</h2>
          </div>
          <p className="mt-1 text-sm text-slate-500">
            Atur shortcut tampilan dan izin transaksi yang benar-benar diperiksa server.
          </p>
        </div>
        <button onClick={() => void load()} disabled={loading} className="inline-flex min-h-10 items-center gap-2 rounded-xl border px-4 text-sm font-bold">
          <RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /> Muat ulang
        </button>
      </div>
      {error && <p className="mt-4 rounded-xl bg-rose-50 p-3 text-sm font-semibold text-rose-700">{error}</p>}
      {loading ? (
        <div className="p-10 text-center text-slate-500"><Loader2 className="mx-auto h-6 w-6 animate-spin" /></div>
      ) : (
        <div className="mt-5 space-y-4">
          {terminals.map((terminal) => {
            const priceAllowed = priceDrafts[terminal.terminalId] ?? false
            return (
              <article key={terminal.terminalId} className="rounded-2xl border border-slate-200 p-4">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div>
                    <h3 className="font-black">{terminal.terminalName}</h3>
                    <p className="text-xs text-slate-500">{terminal.terminalCode} · {terminal.storeName}</p>
                  </div>
                  <button onClick={() => void save(terminal)} disabled={saving === terminal.terminalId} className="inline-flex min-h-10 items-center gap-2 rounded-xl bg-emerald-600 px-4 text-sm font-black text-white disabled:opacity-60">
                    <Save className="h-4 w-4" />{saving === terminal.terminalId ? 'Menyimpan...' : 'Simpan pengaturan'}
                  </button>
                </div>
                <button
                  type="button"
                  onClick={() => setPriceDrafts((current) => ({
                    ...current, [terminal.terminalId]: !priceAllowed,
                  }))}
                  className={`mt-4 flex w-full items-start gap-3 rounded-xl border p-4 text-left ${priceAllowed ? 'border-amber-300 bg-amber-50 text-amber-950' : 'border-slate-200 bg-slate-50 text-slate-600'}`}
                >
                  <CircleDollarSign className="mt-0.5 h-5 w-5 shrink-0" />
                  <span>
                    <strong className="block">Kasir boleh mengubah harga jual</strong>
                    <span className="mt-1 block text-xs font-medium leading-5">
                      {priceAllowed ? 'Aktif · harga manual mengalahkan Pricelist dan dicatat pada transaksi.' : 'Nonaktif · POS hanya memakai harga canonical Pricelist.'}
                    </span>
                  </span>
                  <span className="ml-auto text-xs font-black uppercase">{priceAllowed ? 'Aktif' : 'Nonaktif'}</span>
                </button>
                <div className="mt-4 grid gap-2 sm:grid-cols-2 xl:grid-cols-3">
                  {features.map(([key, label]) => {
                    const hidden = (featureDrafts[terminal.terminalId] ?? []).includes(key)
                    return (
                      <button key={key} type="button" onClick={() => toggleFeature(terminal.terminalId, key)} className={`flex min-h-11 items-center gap-3 rounded-xl border px-3 text-left text-sm font-bold ${hidden ? 'border-slate-200 bg-slate-50 text-slate-500' : 'border-emerald-200 bg-emerald-50 text-emerald-800'}`}>
                        {hidden ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                        <span>{label}</span><span className="ml-auto text-[10px] uppercase">{hidden ? 'Disembunyikan' : 'Tampil'}</span>
                      </button>
                    )
                  })}
                </div>
              </article>
            )
          })}
          {!terminals.length && <p className="rounded-xl border border-dashed p-8 text-center text-sm text-slate-500">Tidak ada Terminal yang dapat Anda kelola.</p>}
        </div>
      )}
    </section>
  )
}
