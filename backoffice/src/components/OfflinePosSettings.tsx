'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  Building2,
  CircleAlert,
  MonitorSmartphone,
  RefreshCcw,
  Save,
  Store,
  WifiOff,
  X,
} from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'
import { OfflineAllowanceOperations } from '@/components/OfflineAllowanceOperations'

type Policy = {
  id: string
  scope_type: 'COMPANY' | 'STORE' | 'TERMINAL'
  store_id: string | null
  terminal_id: string | null
  allocation_percent: number | null
  is_enabled: boolean
  master_version: number
  updated_at: string
}
type StoreOption = { id: string; store_name: string }
type TerminalOption = { id: string; store_id: string; pos_name: string }
type Settings = {
  featureEnabled: boolean
  roleCode: string
  canManageCompanyPolicy: boolean
  policies: Policy[]
  stores: StoreOption[]
  terminals: TerminalOption[]
}
type SaveRequest = {
  title: string
  description: string
  scopeType: Policy['scope_type']
  policyId: string | null
  masterVersion: number | null
  storeId: string | null
  terminalId: string | null
  allocationPercent: number | null
  enabled: boolean
}

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` }
}

function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    OFFLINE_SETTINGS_ACCESS_REQUIRED:
      'Role Anda tidak memiliki akses ke pengaturan Offline POS.',
    OFFLINE_COMPANY_POLICY_MANAGER_REQUIRED:
      'Kebijakan Company hanya dapat diubah Pemilik atau Admin Perusahaan.',
    OFFLINE_STORE_POLICY_MANAGER_REQUIRED:
      'Anda hanya dapat mengubah kebijakan toko yang ditugaskan kepada Anda.',
    ACTIVE_STORE_NOT_FOUND: 'Toko tidak aktif atau tidak lagi tersedia.',
    ACTIVE_POS_TERMINAL_NOT_FOUND:
      'Terminal tidak aktif atau tidak lagi tersedia.',
    OFFLINE_POLICY_PERCENT_INVALID:
      'Persentase cadangan harus lebih dari 0% dan maksimal 100%.',
    MASTER_VERSION_CONFLICT:
      'Pengaturan sudah diubah pengguna lain. Muat ulang lalu coba lagi.',
    OFFLINE_POLICY_SCOPE_ALREADY_EXISTS:
      'Pengaturan untuk scope ini sudah dibuat. Muat ulang halaman.',
    ACTIVE_COMPANY_NOT_FOUND: 'Pilih Company aktif terlebih dahulu.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi pengaturan Offline POS gagal.'
}

export function OfflinePosSettings({
  session,
  companyId,
  notify,
}: {
  session: Session
  companyId: string
  notify: (message: string | null) => void
}) {
  const [settings, setSettings] = useState<Settings | null>(null)
  const [percentages, setPercentages] = useState<Record<string, string>>({})
  const [pending, setPending] = useState<SaveRequest | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  const refresh = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      const response = await fetch('/api/platform/offline-settings', {
        headers: authHeaders(session),
        cache: 'no-store',
      })
      const payload = await response.json() as { data?: Settings; error?: string }
      if (!response.ok || !payload.data) {
        throw new Error(friendlyError(payload.error))
      }
      const nextPercentages: Record<string, string> = {}
      for (const policy of payload.data.policies) {
        if (policy.allocation_percent !== null) {
          const key =
            policy.scope_type === 'COMPANY'
              ? 'COMPANY'
              : `STORE:${policy.store_id}`
          nextPercentages[key] = String(
            Number((policy.allocation_percent * 100).toFixed(4)),
          )
        }
      }
      setPercentages(nextPercentages)
      setSettings(payload.data)
    } catch (caught) {
      setError(
        caught instanceof Error
          ? caught.message
          : 'Gagal memuat pengaturan Offline POS.',
      )
    } finally {
      setLoading(false)
    }
  }, [session])

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- active Company determines policy scope
    void refresh()
  }, [companyId, refresh])

  const policyByScope = useMemo(
    () => new Map(
      (settings?.policies ?? []).map((policy) => {
        const key =
          policy.scope_type === 'COMPANY'
            ? 'COMPANY'
            : `${policy.scope_type}:${policy.scope_type === 'STORE' ? policy.store_id : policy.terminal_id}`
        return [key, policy]
      }),
    ),
    [settings],
  )

  function percentFor(key: string, fallback = '20') {
    return percentages[key] ?? fallback
  }

  function validPercent(key: string) {
    const value = Number(percentFor(key))
    return Number.isFinite(value) && value > 0 && value <= 100
  }

  if (loading && !settings) {
    return (
      <div className="mt-6 rounded-2xl border border-slate-200 bg-white p-8 text-center text-sm text-slate-500">
        <RefreshCcw className="mx-auto mb-3 h-5 w-5 animate-spin" />
        Memuat kebijakan Offline POS...
      </div>
    )
  }

  return (
    <section className="mt-8 border-t border-slate-200 pt-8">
      <div className="mb-5 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <p className="text-xs font-bold uppercase tracking-[.16em] text-blue-600">
            Operational Guardrail
          </p>
          <h2 className="mt-2 text-xl font-black text-slate-950">
            Kebijakan Offline POS
          </h2>
          <p className="mt-1 max-w-3xl text-sm leading-6 text-slate-500">
            Atur batas stok yang boleh dicadangkan untuk transaksi offline.
            Persentase toko menggantikan default Company, sedangkan setiap
            Terminal harus diizinkan secara eksplisit.
          </p>
        </div>
        <button
          type="button"
          onClick={() => void refresh()}
          className="inline-flex items-center justify-center gap-2 rounded-xl border border-slate-200 bg-white px-4 py-2.5 text-sm font-bold text-slate-600"
        >
          <RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} />
          Muat ulang
        </button>
      </div>

      {!settings?.featureEnabled && (
        <div className="mb-5 flex gap-3 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900">
          <CircleAlert className="mt-0.5 h-5 w-5 shrink-0" />
          <span>
            <b>Entitlement Offline POS masih nonaktif.</b> Kebijakan boleh
            disiapkan sekarang, tetapi kasir belum dapat memakai mode offline
            sampai Super Admin mengaktifkannya dan UAT selesai.
          </span>
        </div>
      )}
      {error && (
        <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">
          {error}
        </div>
      )}

      {settings?.canManageCompanyPolicy && (() => {
        const policy = policyByScope.get('COMPANY')
        const key = 'COMPANY'
        return (
          <article className="mb-5 rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
            <div className="flex items-start gap-3">
              <div className="grid h-10 w-10 shrink-0 place-items-center rounded-xl bg-blue-50 text-blue-600">
                <Building2 className="h-5 w-5" />
              </div>
              <div>
                <h3 className="font-bold text-slate-950">Default Company</h3>
                <p className="mt-1 text-sm leading-6 text-slate-500">
                  Batas cadangan yang dipakai semua toko tanpa override.
                </p>
              </div>
            </div>
            <div className="mt-4 grid gap-3 sm:grid-cols-[minmax(0,240px)_auto] sm:items-end">
              <label className="block">
                <span className="mb-1.5 block text-xs font-bold uppercase tracking-wide text-slate-500">
                  Maksimum stok dicadangkan
                </span>
                <div className="relative">
                  <input
                    type="number"
                    min="0.0001"
                    max="100"
                    step="0.01"
                    value={percentFor(key)}
                    onChange={(event) => setPercentages((current) => ({
                      ...current,
                      [key]: event.target.value,
                    }))}
                    className="input pr-10"
                  />
                  <span className="pointer-events-none absolute inset-y-0 right-3 flex items-center font-bold text-slate-400">
                    %
                  </span>
                </div>
              </label>
              <button
                type="button"
                disabled={!validPercent(key)}
                onClick={() => setPending({
                  title: 'Simpan default Company?',
                  description:
                    'Batas ini berlaku untuk semua toko yang tidak memiliki override aktif.',
                  scopeType: 'COMPANY',
                  policyId: policy?.id ?? null,
                  masterVersion: policy?.master_version ?? null,
                  storeId: null,
                  terminalId: null,
                  allocationPercent: Number(percentFor(key)),
                  enabled: true,
                })}
                className="inline-flex items-center justify-center gap-2 rounded-xl bg-slate-950 px-4 py-3 text-sm font-bold text-white disabled:cursor-not-allowed disabled:opacity-40 sm:w-fit"
              >
                <Save className="h-4 w-4" />
                Simpan default
              </button>
            </div>
          </article>
        )
      })()}

      {!settings?.canManageCompanyPolicy && (
        <div className="mb-5 rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm leading-6 text-slate-600">
          Default Company dikelola Pemilik atau Admin Perusahaan. Anda dapat
          mengatur override dan Terminal hanya untuk toko assignment Anda.
        </div>
      )}

      <div className="space-y-4">
        {(settings?.stores ?? []).map((store) => {
          const storeKey = `STORE:${store.id}`
          const storePolicy = policyByScope.get(storeKey)
          const companyPercent = percentFor('COMPANY', '20')
          const terminals = (settings?.terminals ?? []).filter(
            (terminal) => terminal.store_id === store.id,
          )
          return (
            <article
              key={store.id}
              className="overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm"
            >
              <div className="border-b border-slate-100 p-5">
                <div className="flex items-start gap-3">
                  <div className="grid h-10 w-10 shrink-0 place-items-center rounded-xl bg-emerald-50 text-emerald-600">
                    <Store className="h-5 w-5" />
                  </div>
                  <div>
                    <h3 className="font-bold text-slate-950">
                      {store.store_name}
                    </h3>
                    <p className="mt-1 text-sm text-slate-500">
                      Override stok dan izin Terminal untuk toko ini.
                    </p>
                  </div>
                </div>
                <div className="mt-4 grid gap-3 sm:grid-cols-[minmax(0,240px)_auto] sm:items-end">
                  <label className="block">
                    <span className="mb-1.5 block text-xs font-bold uppercase tracking-wide text-slate-500">
                      Override cadangan toko
                    </span>
                    <div className="relative">
                      <input
                        type="number"
                        min="0.0001"
                        max="100"
                        step="0.01"
                        value={percentFor(storeKey, companyPercent)}
                        onChange={(event) => setPercentages((current) => ({
                          ...current,
                          [storeKey]: event.target.value,
                        }))}
                        className="input pr-10"
                      />
                      <span className="pointer-events-none absolute inset-y-0 right-3 flex items-center font-bold text-slate-400">
                        %
                      </span>
                    </div>
                  </label>
                  <div className="flex flex-wrap gap-2">
                    <button
                      type="button"
                      disabled={!validPercent(storeKey)}
                      onClick={() => setPending({
                        title: 'Aktifkan override toko?',
                        description: `${store.store_name} akan memakai batas ${percentFor(storeKey, companyPercent)}%, menggantikan default Company.`,
                        scopeType: 'STORE',
                        policyId: storePolicy?.id ?? null,
                        masterVersion: storePolicy?.master_version ?? null,
                        storeId: store.id,
                        terminalId: null,
                        allocationPercent: Number(
                          percentFor(storeKey, companyPercent),
                        ),
                        enabled: true,
                      })}
                      className="inline-flex items-center justify-center gap-2 rounded-xl bg-slate-950 px-4 py-3 text-sm font-bold text-white disabled:cursor-not-allowed disabled:opacity-40"
                    >
                      <Save className="h-4 w-4" />
                      {storePolicy?.is_enabled ? 'Simpan override' : 'Gunakan override'}
                    </button>
                    {storePolicy?.is_enabled && (
                      <button
                        type="button"
                        onClick={() => setPending({
                          title: 'Nonaktifkan override toko?',
                          description: `${store.store_name} akan kembali memakai default Company.`,
                          scopeType: 'STORE',
                          policyId: storePolicy.id,
                          masterVersion: storePolicy.master_version,
                          storeId: store.id,
                          terminalId: null,
                          allocationPercent: Number(
                            percentFor(storeKey, companyPercent),
                          ),
                          enabled: false,
                        })}
                        className="rounded-xl border border-slate-200 px-4 py-3 text-sm font-bold text-slate-600"
                      >
                        Pakai default Company
                      </button>
                    )}
                  </div>
                </div>
              </div>

              <div className="p-5">
                <div className="mb-3">
                  <h4 className="text-sm font-bold text-slate-900">
                    Terminal yang diizinkan offline
                  </h4>
                  <p className="mt-1 text-xs leading-5 text-slate-500">
                    Terminal nonaktif tidak dapat mengambil snapshot dan
                    cadangan stok offline.
                  </p>
                </div>
                <div className="grid gap-2 md:grid-cols-2">
                  {terminals.map((terminal) => {
                    const policy = policyByScope.get(`TERMINAL:${terminal.id}`)
                    const enabled = policy?.is_enabled ?? false
                    return (
                      <div
                        key={terminal.id}
                        className="flex items-center gap-3 rounded-xl border border-slate-200 p-3"
                      >
                        <MonitorSmartphone className={`h-5 w-5 shrink-0 ${enabled ? 'text-emerald-600' : 'text-slate-400'}`} />
                        <div className="min-w-0 flex-1">
                          <p className="truncate text-sm font-bold text-slate-900">
                            {terminal.pos_name}
                          </p>
                          <p className="text-xs text-slate-500">
                            {enabled ? 'Diizinkan offline' : 'Online saja'}
                          </p>
                        </div>
                        <button
                          type="button"
                          onClick={() => setPending({
                            title: enabled
                              ? 'Nonaktifkan akses offline Terminal?'
                              : 'Izinkan Terminal bekerja offline?',
                            description: enabled
                              ? `${terminal.pos_name} tidak dapat meminta snapshot/cadangan baru setelah dinonaktifkan.`
                              : `${terminal.pos_name} tetap membutuhkan entitlement aktif dan cadangan stok sebelum transaksi offline.`,
                            scopeType: 'TERMINAL',
                            policyId: policy?.id ?? null,
                            masterVersion: policy?.master_version ?? null,
                            storeId: store.id,
                            terminalId: terminal.id,
                            allocationPercent: null,
                            enabled: !enabled,
                          })}
                          className={`rounded-lg px-3 py-2 text-xs font-bold ${enabled ? 'border border-rose-200 text-rose-600' : 'bg-emerald-500 text-white'}`}
                        >
                          {enabled ? 'Nonaktifkan' : 'Izinkan'}
                        </button>
                      </div>
                    )
                  })}
                </div>
                {!terminals.length && (
                  <div className="rounded-xl border border-dashed border-slate-300 p-5 text-center text-sm text-slate-400">
                    Belum ada Terminal aktif pada toko ini.
                  </div>
                )}
              </div>
            </article>
          )
        })}
      </div>

      {!settings?.stores.length && (
        <div className="rounded-2xl border border-dashed border-slate-300 p-8 text-center text-sm text-slate-400">
          Tidak ada toko aktif yang dapat Anda kelola.
        </div>
      )}

      <div className="mt-5 flex gap-3 rounded-2xl bg-slate-950 p-4 text-sm leading-6 text-slate-200">
        <WifiOff className="mt-0.5 h-5 w-5 shrink-0 text-blue-300" />
        Perubahan policy tidak otomatis membuat cadangan stok. Cadangan tetap
        diterbitkan per sesi kasir dan per produk melalui proses guarded.
      </div>

      {settings && (
        <OfflineAllowanceOperations
          session={session}
          companyId={companyId}
          featureEnabled={settings.featureEnabled}
          notify={notify}
        />
      )}

      {pending && (
        <ConfirmPolicy
          session={session}
          request={pending}
          close={() => setPending(null)}
          complete={async () => {
            setPending(null)
            await refresh()
            notify('Kebijakan Offline POS berhasil diperbarui.')
          }}
        />
      )}
    </section>
  )
}

function ConfirmPolicy({
  session,
  request,
  close,
  complete,
}: {
  session: Session
  request: SaveRequest
  close: () => void
  complete: () => Promise<void>
}) {
  useEscapeClose(close)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')

  async function confirm() {
    setSaving(true)
    setError('')
    try {
      const response = await fetch('/api/platform/offline-settings', {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          ...authHeaders(session),
        },
        body: JSON.stringify(request),
      })
      const payload = await response.json() as { error?: string }
      if (!response.ok) throw new Error(friendlyError(payload.error))
      await complete()
    } catch (caught) {
      setError(
        caught instanceof Error
          ? caught.message
          : 'Gagal menyimpan kebijakan Offline POS.',
      )
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="fixed inset-0 z-[90] grid place-items-center overflow-y-auto bg-slate-950/50 p-4 backdrop-blur-sm">
      <div className="w-full max-w-lg rounded-3xl bg-white shadow-2xl">
        <div className="flex items-start justify-between border-b border-slate-100 p-6">
          <div>
            <p className="text-xs font-bold uppercase tracking-[.14em] text-blue-600">
              Konfirmasi kebijakan
            </p>
            <h2 className="mt-2 text-xl font-black text-slate-950">
              {request.title}
            </h2>
          </div>
          <button
            type="button"
            onClick={close}
            className="rounded-xl border border-slate-200 p-2 text-slate-500"
            aria-label="Tutup"
          >
            <X className="h-5 w-5" />
          </button>
        </div>
        <div className="space-y-4 p-6">
          <p className="text-sm leading-6 text-slate-600">
            {request.description}
          </p>
          {error && (
            <div className="rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">
              {error}
            </div>
          )}
          <div className="flex justify-end gap-3 pt-2">
            <button
              type="button"
              onClick={close}
              className="rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold text-slate-600"
            >
              Batal
            </button>
            <button
              type="button"
              disabled={saving}
              onClick={() => void confirm()}
              className="rounded-xl bg-slate-950 px-4 py-2.5 text-sm font-bold text-white disabled:opacity-50"
            >
              {saving ? 'Menyimpan...' : 'Ya, simpan'}
            </button>
          </div>
        </div>
      </div>
    </div>
  )
}
