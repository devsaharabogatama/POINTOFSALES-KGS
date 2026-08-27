'use client'

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import { Building2, Eye, EyeOff, ImageIcon, RefreshCcw, ShieldCheck, Trash2, Upload, X } from 'lucide-react'
import { useEscapeClose } from '@/lib/use-escape-close'
import { CompanyProfileEditor } from '@/components/CompanyProfileEditor'

type BrandingProfile = {
  companyId: string
  hasLogo: boolean
  showLogoOnDocuments: boolean
  showStampOnDocuments: boolean
  showBankAccountOnInvoice: boolean
  invoiceDateDisplayMode: 'ORDER_DATE' | 'POSTED_DATE'
  deliverySignatureTemplate: 'WAREHOUSE' | 'STORE'
  deliveryDocumentCreationPolicy: 'DELIVERY_ONLY' | 'ALL_POSTED_SALES'
  logoObjectPath: string | null
  logoPublicUrl: string | null
  logoMimeType: string | null
  logoSizeBytes: number | null
  logoChecksumSha256: string | null
  logoVersion: number
  masterVersion: number | null
  uploadedAt: string | null
  updatedAt: string | null
}

type Payload = {
  data?: BrandingProfile
  cleanupPending?: boolean
  error?: string
}

const MAX_FILE_BYTES = 2 * 1024 * 1024

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` }
}

function friendlyError(code?: string) {
  const messages: Record<string, string> = {
    COMPANY_BRANDING_MANAGER_REQUIRED: 'Hanya Owner atau Admin Company yang dapat mengubah logo.',
    COMPANY_LOGO_FILE_REQUIRED: 'Pilih file logo terlebih dahulu.',
    COMPANY_LOGO_SIZE_INVALID: 'Ukuran logo harus lebih dari 0 dan maksimal 2 MB.',
    COMPANY_LOGO_REQUEST_TOO_LARGE: 'Ukuran request logo melebihi batas 2 MB.',
    COMPANY_LOGO_MAGIC_BYTES_INVALID: 'Isi file bukan PNG, JPEG, atau WebP yang valid.',
    COMPANY_LOGO_EXTENSION_MISMATCH: 'Extension file tidak cocok dengan isi gambarnya.',
    COMPANY_LOGO_MIME_MISMATCH: 'Tipe file browser tidak cocok dengan isi gambarnya.',
    COMPANY_LOGO_OBJECT_ALREADY_EXISTS: 'Versi object logo sudah ada. Muat ulang lalu coba kembali.',
    COMPANY_LOGO_UPLOAD_FAILED: 'Upload logo ke penyimpanan gagal.',
    COMPANY_BRANDING_OPERATION_FAILED: 'Operasi branding Company gagal.',
    COMPANY_BANK_ACCOUNT_REQUIRED: 'Lengkapi rekening perusahaan sebelum menampilkannya pada Invoice.',
    INVOICE_DATE_DISPLAY_MODE_INVALID: 'Pilihan tanggal Invoice tidak valid.',
    DELIVERY_SIGNATURE_TEMPLATE_INVALID: 'Pilihan template Surat Jalan tidak valid.',
    DELIVERY_DOCUMENT_CREATION_POLICY_INVALID: 'Pilihan pembuatan Surat Jalan tidak valid.',
    MASTER_VERSION_CONFLICT: 'Logo berubah di sesi lain. Muat ulang sebelum mencoba kembali.',
    ACTIVE_COMPANY_NOT_FOUND: 'Pilih Company aktif terlebih dahulu.',
    ACTIVE_COMPANY_BRANDING_MISMATCH: 'Branding tidak cocok dengan Company aktif.',
  }
  return messages[code ?? ''] ?? code ?? 'Operasi logo Company gagal.'
}

function formatBytes(value: number | null) {
  if (!value) return '—'
  return `${(value / 1024).toLocaleString('id-ID', { maximumFractionDigits: 1 })} KB`
}

export function CompanyBrandingView({
  session,
  companyId,
  companyName,
  canManage,
  notify,
}: {
  session: Session
  companyId: string
  companyName: string
  canManage: boolean
  notify: (message: string | null) => void
}) {
  const [branding, setBranding] = useState<BrandingProfile | null>(null)
  const [selectedFile, setSelectedFile] = useState<File | null>(null)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const [showRemove, setShowRemove] = useState(false)
  const [bankReady, setBankReady] = useState(false)
  const inputRef = useRef<HTMLInputElement>(null)

  const previewUrl = useMemo(
    () => selectedFile ? URL.createObjectURL(selectedFile) : null,
    [selectedFile],
  )
  useEffect(() => () => {
    if (previewUrl) URL.revokeObjectURL(previewUrl)
  }, [previewUrl])

  const refresh = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      const response = await fetch('/api/platform/company-branding', {
        headers: authHeaders(session),
        cache: 'no-store',
      })
      const payload = await response.json() as Payload
      if (!response.ok) throw new Error(friendlyError(payload.error))
      if (!payload.data || payload.data.companyId !== companyId) {
        throw new Error('Branding Company aktif tidak dapat diverifikasi.')
      }
      setBranding(payload.data)
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal memuat branding Company.')
    } finally {
      setLoading(false)
    }
  }, [companyId, session])

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- branding follows active Company context
    void refresh()
  }, [refresh])

  function selectFile(file: File | undefined) {
    setError('')
    if (!file) return
    if (file.size < 1 || file.size > MAX_FILE_BYTES) {
      setSelectedFile(null)
      setError('Ukuran logo harus lebih dari 0 dan maksimal 2 MB.')
      return
    }
    setSelectedFile(file)
  }

  async function upload() {
    if (!selectedFile || !canManage) return
    setSaving(true)
    setError('')
    try {
      const body = new FormData()
      body.set('file', selectedFile)
      if (branding?.masterVersion !== null && branding?.masterVersion !== undefined) {
        body.set('expectedMasterVersion', String(branding.masterVersion))
      }
      const response = await fetch('/api/platform/company-branding', {
        method: 'POST',
        headers: authHeaders(session),
        body,
      })
      const payload = await response.json() as Payload
      if (!response.ok) throw new Error(friendlyError(payload.error))
      if (!payload.data || payload.data.companyId !== companyId) {
        throw new Error('Hasil upload tidak cocok dengan Company aktif.')
      }
      setBranding(payload.data)
      setSelectedFile(null)
      if (inputRef.current) inputRef.current.value = ''
      notify(payload.cleanupPending
        ? 'Logo aktif berhasil diganti. Pembersihan file lama akan dicoba kembali.'
        : 'Logo perusahaan berhasil disimpan.')
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal mengunggah logo.')
    } finally {
      setSaving(false)
    }
  }

  async function saveDocumentVisibility(input: {
    showLogoOnDocuments?: boolean
    showStampOnDocuments?: boolean
    showBankAccountOnInvoice?: boolean
    invoiceDateDisplayMode?: 'ORDER_DATE' | 'POSTED_DATE'
    deliverySignatureTemplate?: 'WAREHOUSE' | 'STORE'
    deliveryDocumentCreationPolicy?: 'DELIVERY_ONLY' | 'ALL_POSTED_SALES'
  }) {
    if (!branding || !canManage || saving) return
    setSaving(true)
    setError('')
    try {
      const response = await fetch('/api/platform/company-branding', {
        method: 'PATCH',
        headers: { ...authHeaders(session), 'Content-Type': 'application/json' },
        body: JSON.stringify({
          expectedMasterVersion: branding.masterVersion,
          showLogoOnDocuments: input.showLogoOnDocuments ?? branding.showLogoOnDocuments,
          showStampOnDocuments: input.showStampOnDocuments ?? branding.showStampOnDocuments,
          showBankAccountOnInvoice: input.showBankAccountOnInvoice ?? branding.showBankAccountOnInvoice,
          invoiceDateDisplayMode: input.invoiceDateDisplayMode ?? branding.invoiceDateDisplayMode,
          deliverySignatureTemplate: input.deliverySignatureTemplate ?? branding.deliverySignatureTemplate,
          deliveryDocumentCreationPolicy: input.deliveryDocumentCreationPolicy ?? branding.deliveryDocumentCreationPolicy,
        }),
      })
      const payload = await response.json() as Payload
      if (!response.ok) throw new Error(friendlyError(payload.error))
      if (!payload.data || payload.data.companyId !== companyId) {
        throw new Error('Hasil pengaturan logo tidak cocok dengan Company aktif.')
      }
      setBranding(payload.data)
      notify('Tampilan identitas dokumen berhasil diperbarui.')
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Pengaturan logo dokumen gagal disimpan.')
    } finally {
      setSaving(false)
    }
  }

  const visibleLogo = previewUrl ?? branding?.logoPublicUrl ?? null

  return <>
    <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
      <div>
        <p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">Identitas Company</p>
        <h1 className="mt-2 text-2xl font-black tracking-tight text-slate-950 md:text-3xl">Profil Perusahaan</h1>
        <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">
          Identitas, rekening, logo, dan tampilan dokumen <b>{companyName}</b>. Company mengikuti workspace aktif.
        </p>
      </div>
      <button onClick={() => void refresh()} disabled={loading} className="inline-flex items-center justify-center gap-2 rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm font-bold text-slate-600 disabled:opacity-50">
        <RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /> Muat ulang
      </button>
    </div>

    {error && <div className="mb-5 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-700">{error}</div>}

    <CompanyProfileEditor session={session} companyId={companyId} canManage={canManage} notify={notify} onBankReadyChange={setBankReady}/>

    <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_360px]">
      <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm md:p-8">
        <div className="flex items-start gap-3">
          <div className="grid h-11 w-11 shrink-0 place-items-center rounded-xl bg-emerald-50 text-emerald-700"><ImageIcon className="h-5 w-5" /></div>
          <div><h2 className="text-lg font-black text-slate-950">File logo</h2><p className="mt-1 text-sm leading-6 text-slate-500">PNG, JPEG, atau WebP. Maksimal 2 MB. Isi file diperiksa server, bukan hanya nama file.</p></div>
        </div>

        <div className="mt-6 rounded-2xl border-2 border-dashed border-slate-200 bg-slate-50 p-5">
          <input ref={inputRef} type="file" accept=".png,.jpg,.jpeg,.webp,image/png,image/jpeg,image/webp" disabled={!canManage || saving} onChange={(event) => selectFile(event.target.files?.[0])} className="sr-only" id="company-logo-file" />
          <label htmlFor="company-logo-file" className={`flex min-h-36 flex-col items-center justify-center rounded-xl text-center ${canManage ? 'cursor-pointer hover:bg-white' : 'cursor-not-allowed opacity-60'}`}>
            <Upload className="h-7 w-7 text-slate-400" />
            <span className="mt-3 text-sm font-bold text-slate-800">{selectedFile ? selectedFile.name : 'Pilih file logo'}</span>
            <span className="mt-1 text-xs text-slate-500">{selectedFile ? formatBytes(selectedFile.size) : 'Klik area ini untuk memilih gambar'}</span>
          </label>
        </div>

        <div className={`mt-5 flex flex-col gap-4 rounded-2xl border p-4 sm:flex-row sm:items-center sm:justify-between ${(branding?.showLogoOnDocuments ?? true) ? 'border-emerald-200 bg-emerald-50' : 'border-slate-200 bg-slate-50'}`}>
          <div className="flex items-start gap-3">{(branding?.showLogoOnDocuments ?? true) ? <Eye className="mt-0.5 h-5 w-5 shrink-0 text-emerald-700"/> : <EyeOff className="mt-0.5 h-5 w-5 shrink-0 text-slate-500"/>}<div><p className="text-sm font-black text-slate-900">Tampilkan logo pada dokumen</p><p className="mt-1 text-xs leading-5 text-slate-600">Berlaku untuk template print dan PDF Invoice serta Surat Jalan. File logo tidak dihapus saat dimatikan.</p></div></div>
          <button type="button" role="switch" aria-checked={branding?.showLogoOnDocuments ?? true} onClick={() => void saveDocumentVisibility({ showLogoOnDocuments: !(branding?.showLogoOnDocuments ?? true) })} disabled={!branding || !canManage || saving} className={`relative h-8 w-14 shrink-0 rounded-full transition disabled:opacity-50 ${(branding?.showLogoOnDocuments ?? true) ? 'bg-emerald-600' : 'bg-slate-300'}`}><span className={`absolute top-1 h-6 w-6 rounded-full bg-white shadow transition ${(branding?.showLogoOnDocuments ?? true) ? 'left-7' : 'left-1'}`}/><span className="sr-only">{(branding?.showLogoOnDocuments ?? true) ? 'Nonaktifkan logo dokumen' : 'Aktifkan logo dokumen'}</span></button>
        </div>

        <div className={`mt-3 flex flex-col gap-4 rounded-2xl border p-4 sm:flex-row sm:items-center sm:justify-between ${(branding?.showStampOnDocuments ?? false) ? 'border-blue-200 bg-blue-50' : 'border-slate-200 bg-slate-50'}`}>
          <div className="flex items-start gap-3">{(branding?.showStampOnDocuments ?? false) ? <Eye className="mt-0.5 h-5 w-5 shrink-0 text-blue-700"/> : <EyeOff className="mt-0.5 h-5 w-5 shrink-0 text-slate-500"/>}<div><p className="text-sm font-black text-slate-900">Tampilkan stempel pada dokumen</p><p className="mt-1 text-xs leading-5 text-slate-600">Memakai logo dengan efek cap biru-transparan. Pada Invoice tampil mandiri; pada Surat Jalan berada di kolom tanda tangan pertama.</p></div></div>
          <button type="button" role="switch" aria-checked={branding?.showStampOnDocuments ?? false} onClick={() => void saveDocumentVisibility({ showStampOnDocuments: !(branding?.showStampOnDocuments ?? false) })} disabled={!branding || !branding.hasLogo || !canManage || saving} className={`relative h-8 w-14 shrink-0 rounded-full transition disabled:opacity-50 ${(branding?.showStampOnDocuments ?? false) ? 'bg-blue-600' : 'bg-slate-300'}`}><span className={`absolute top-1 h-6 w-6 rounded-full bg-white shadow transition ${(branding?.showStampOnDocuments ?? false) ? 'left-7' : 'left-1'}`}/><span className="sr-only">{(branding?.showStampOnDocuments ?? false) ? 'Nonaktifkan stempel dokumen' : 'Aktifkan stempel dokumen'}</span></button>
        </div>

        <div className={`mt-3 flex flex-col gap-4 rounded-2xl border p-4 sm:flex-row sm:items-center sm:justify-between ${(branding?.showBankAccountOnInvoice ?? false) ? 'border-violet-200 bg-violet-50' : 'border-slate-200 bg-slate-50'}`}>
          <div className="flex items-start gap-3">{(branding?.showBankAccountOnInvoice ?? false) ? <Eye className="mt-0.5 h-5 w-5 shrink-0 text-violet-700"/> : <EyeOff className="mt-0.5 h-5 w-5 shrink-0 text-slate-500"/>}<div><p className="text-sm font-black text-slate-900">Tampilkan rekening pada Invoice</p><p className="mt-1 text-xs leading-5 text-slate-600">Menampilkan nama bank, nomor rekening, dan nama pemilik dari profil Company. Tidak tampil pada Surat Jalan.</p>{!bankReady && <p className="mt-1 text-xs font-bold text-amber-700">Lengkapi tiga field rekening perusahaan terlebih dahulu.</p>}</div></div>
          <button type="button" role="switch" aria-checked={branding?.showBankAccountOnInvoice ?? false} onClick={() => void saveDocumentVisibility({ showBankAccountOnInvoice: !(branding?.showBankAccountOnInvoice ?? false) })} disabled={!branding || !bankReady || !canManage || saving} className={`relative h-8 w-14 shrink-0 rounded-full transition disabled:opacity-50 ${(branding?.showBankAccountOnInvoice ?? false) ? 'bg-violet-600' : 'bg-slate-300'}`}><span className={`absolute top-1 h-6 w-6 rounded-full bg-white shadow transition ${(branding?.showBankAccountOnInvoice ?? false) ? 'left-7' : 'left-1'}`}/><span className="sr-only">Atur rekening pada Invoice</span></button>
        </div>

        <div className="mt-3 rounded-2xl border border-slate-200 bg-slate-50 p-4">
          <label htmlFor="invoice-date-display-mode" className="text-sm font-black text-slate-900">Tanggal yang tampil pada Invoice</label>
          <p className="mt-1 text-xs leading-5 text-slate-600">Tanggal Order mengikuti tanggal bisnis yang dipilih untuk order/backorder. Tanggal Transaksi mengikuti hari saat transaksi benar-benar diposting. Keduanya dicetak tanpa jam.</p>
          <select id="invoice-date-display-mode" value={branding?.invoiceDateDisplayMode ?? 'ORDER_DATE'} onChange={(event) => void saveDocumentVisibility({ invoiceDateDisplayMode: event.target.value as 'ORDER_DATE' | 'POSTED_DATE' })} disabled={!branding || !canManage || saving} className="mt-3 min-h-11 w-full rounded-xl border border-slate-300 bg-white px-3 text-sm font-bold text-slate-800 outline-none focus:border-emerald-500 disabled:opacity-50">
            <option value="ORDER_DATE">Tanggal Order</option>
            <option value="POSTED_DATE">Tanggal Transaksi</option>
          </select>
        </div>

        <div className="mt-3 rounded-2xl border border-slate-200 bg-slate-50 p-4">
          <label htmlFor="delivery-signature-template" className="text-sm font-black text-slate-900">Template tanda tangan Surat Jalan</label>
          <p className="mt-1 text-xs leading-5 text-slate-600">Mode Gudang memakai Warehouse, Security, Driver, dan Customer. Mode Toko memakai Kasir, Ekspedisi, dan Customer.</p>
          <select id="delivery-signature-template" value={branding?.deliverySignatureTemplate ?? 'WAREHOUSE'} onChange={(event) => void saveDocumentVisibility({ deliverySignatureTemplate: event.target.value as 'WAREHOUSE' | 'STORE' })} disabled={!branding || !canManage || saving} className="mt-3 min-h-11 w-full rounded-xl border border-slate-300 bg-white px-3 text-sm font-bold text-slate-800 outline-none focus:border-emerald-500 disabled:opacity-50">
            <option value="WAREHOUSE">Gudang — Warehouse, Security, Driver, Customer</option>
            <option value="STORE">Toko — Kasir, Ekspedisi, Customer</option>
          </select>
        </div>

        <div className="mt-3 rounded-2xl border border-slate-200 bg-slate-50 p-4">
          <label htmlFor="delivery-document-creation-policy" className="text-sm font-black text-slate-900">Pembuatan Surat Jalan otomatis</label>
          <p className="mt-1 text-xs leading-5 text-slate-600">Mode default hanya membuat Surat Jalan saat transaksi ditandai Perlu dikirim. Mode semua transaksi juga membuat Surat Jalan untuk pengambilan di toko, tanpa menambah pergerakan stok atau jurnal.</p>
          <select id="delivery-document-creation-policy" value={branding?.deliveryDocumentCreationPolicy ?? 'DELIVERY_ONLY'} onChange={(event) => void saveDocumentVisibility({ deliveryDocumentCreationPolicy: event.target.value as 'DELIVERY_ONLY' | 'ALL_POSTED_SALES' })} disabled={!branding || !canManage || saving} className="mt-3 min-h-11 w-full rounded-xl border border-slate-300 bg-white px-3 text-sm font-bold text-slate-800 outline-none focus:border-emerald-500 disabled:opacity-50">
            <option value="DELIVERY_ONLY">Hanya transaksi Perlu dikirim</option>
            <option value="ALL_POSTED_SALES">Semua transaksi final</option>
          </select>
        </div>

        {!canManage && <div className="mt-5 flex gap-3 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900"><ShieldCheck className="mt-0.5 h-5 w-5 shrink-0" />Logo hanya dapat diubah Owner atau Admin Company.</div>}

        {canManage && <div className="mt-6 flex flex-wrap justify-end gap-3">
          {branding?.hasLogo && <button onClick={() => setShowRemove(true)} disabled={saving} className="inline-flex items-center gap-2 rounded-xl border border-rose-200 bg-white px-4 py-2.5 text-sm font-bold text-rose-600 disabled:opacity-50"><Trash2 className="h-4 w-4" /> Hapus logo</button>}
          <button onClick={() => void upload()} disabled={!selectedFile || saving} className="inline-flex items-center gap-2 rounded-xl bg-emerald-600 px-5 py-2.5 text-sm font-bold text-white disabled:cursor-not-allowed disabled:opacity-40"><Upload className="h-4 w-4" /> {saving ? 'Mengunggah...' : branding?.hasLogo ? 'Ganti logo' : 'Simpan logo'}</button>
        </div>}
      </section>

      <aside className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
        <p className="text-xs font-bold uppercase tracking-[.14em] text-slate-400">Pratinjau</p>
        <div className="mt-4 grid aspect-[4/3] place-items-center overflow-hidden rounded-2xl border border-slate-200 bg-white p-6">
          {visibleLogo ? <div role="img" aria-label={`Logo ${companyName}`} className="h-full w-full bg-contain bg-center bg-no-repeat" style={{ backgroundImage: `url(${JSON.stringify(visibleLogo)})` }} /> : <div className="text-center text-slate-400"><Building2 className="mx-auto h-12 w-12" /><p className="mt-3 text-sm font-bold">Tanpa logo</p><p className="mt-1 text-xs">Dokumen memakai fallback nama Company.</p></div>}
        </div>
        <dl className="mt-5 space-y-3 text-sm">
          <div className="flex justify-between gap-4"><dt className="text-slate-500">Status</dt><dd className="font-bold text-slate-800">{branding?.hasLogo ? 'Logo aktif' : 'Belum ada logo'}</dd></div>
          <div className="flex justify-between gap-4"><dt className="text-slate-500">Di dokumen</dt><dd className="font-bold text-slate-800">{(branding?.showLogoOnDocuments ?? true) ? 'Ditampilkan' : 'Disembunyikan'}</dd></div>
          <div className="flex justify-between gap-4"><dt className="text-slate-500">Stempel</dt><dd className="font-bold text-slate-800">{(branding?.showStampOnDocuments ?? false) ? 'Ditampilkan' : 'Disembunyikan'}</dd></div>
          <div className="flex justify-between gap-4"><dt className="text-slate-500">Rekening Invoice</dt><dd className="font-bold text-slate-800">{(branding?.showBankAccountOnInvoice ?? false) ? 'Ditampilkan' : 'Disembunyikan'}</dd></div>
          <div className="flex justify-between gap-4"><dt className="text-slate-500">Tanggal Invoice</dt><dd className="font-bold text-slate-800">{(branding?.invoiceDateDisplayMode ?? 'ORDER_DATE') === 'POSTED_DATE' ? 'Tanggal Transaksi' : 'Tanggal Order'}</dd></div>
          <div className="flex justify-between gap-4"><dt className="text-slate-500">Template Surat Jalan</dt><dd className="font-bold text-slate-800">{(branding?.deliverySignatureTemplate ?? 'WAREHOUSE') === 'STORE' ? 'Toko' : 'Gudang'}</dd></div>
          <div className="flex justify-between gap-4"><dt className="text-slate-500">Pembuatan Surat Jalan</dt><dd className="text-right font-bold text-slate-800">{(branding?.deliveryDocumentCreationPolicy ?? 'DELIVERY_ONLY') === 'ALL_POSTED_SALES' ? 'Semua transaksi' : 'Hanya pengiriman'}</dd></div>
          <div className="flex justify-between gap-4"><dt className="text-slate-500">Format</dt><dd className="font-bold text-slate-800">{branding?.logoMimeType?.replace('image/', '').toUpperCase() ?? '—'}</dd></div>
          <div className="flex justify-between gap-4"><dt className="text-slate-500">Ukuran</dt><dd className="font-bold text-slate-800">{formatBytes(branding?.logoSizeBytes ?? null)}</dd></div>
          <div className="flex justify-between gap-4"><dt className="text-slate-500">Versi logo</dt><dd className="font-bold text-slate-800">{branding?.logoVersion ?? 0}</dd></div>
        </dl>
      </aside>
    </div>

    {showRemove && branding?.masterVersion && <RemoveLogoModal
      session={session}
      companyId={companyId}
      companyName={companyName}
      masterVersion={branding.masterVersion}
      close={() => setShowRemove(false)}
      complete={(data, cleanupPending) => {
        setBranding(data)
        setShowRemove(false)
        notify(cleanupPending
          ? 'Logo dinonaktifkan. Pembersihan file lama akan dicoba kembali.'
          : 'Logo perusahaan berhasil dihapus.')
      }}
    />}
  </>
}

function RemoveLogoModal({ session, companyId, companyName, masterVersion, close, complete }: {
  session: Session
  companyId: string
  companyName: string
  masterVersion: number
  close: () => void
  complete: (data: BrandingProfile, cleanupPending: boolean) => void
}) {
  useEscapeClose(close)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')

  async function remove() {
    setSaving(true)
    setError('')
    try {
      const response = await fetch('/api/platform/company-branding', {
        method: 'DELETE',
        headers: { ...authHeaders(session), 'Content-Type': 'application/json' },
        body: JSON.stringify({ expectedMasterVersion: masterVersion }),
      })
      const payload = await response.json() as Payload
      if (!response.ok) throw new Error(friendlyError(payload.error))
      if (!payload.data || payload.data.companyId !== companyId) {
        throw new Error('Hasil penghapusan tidak cocok dengan Company aktif.')
      }
      complete(payload.data, Boolean(payload.cleanupPending))
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Gagal menghapus logo.')
    } finally {
      setSaving(false)
    }
  }

  return <div className="fixed inset-0 z-[80] grid place-items-center overflow-y-auto bg-slate-950/50 p-4 backdrop-blur-sm"><div className="w-full max-w-lg rounded-3xl bg-white shadow-2xl"><div className="flex items-start justify-between border-b border-slate-100 p-6"><div><p className="text-xs font-bold uppercase tracking-wider text-rose-600">Hapus branding</p><h2 className="mt-2 text-xl font-black text-slate-950">Hapus logo perusahaan?</h2></div><button onClick={close} className="rounded-xl border border-slate-200 p-2 text-slate-500" aria-label="Tutup"><X className="h-5 w-5" /></button></div><div className="space-y-5 p-6"><p className="text-sm leading-6 text-slate-600">Logo aktif <b>{companyName}</b> akan dilepas. Dokumen berikutnya memakai fallback nama Company; histori dokumen final tidak diubah.</p>{error && <div className="rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">{error}</div>}<div className="flex justify-end gap-3"><button onClick={close} disabled={saving} className="rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold text-slate-600">Batal</button><button onClick={() => void remove()} disabled={saving} className="rounded-xl bg-rose-600 px-4 py-2.5 text-sm font-bold text-white disabled:opacity-50">{saving ? 'Menghapus...' : 'Ya, hapus logo'}</button></div></div></div></div>
}
