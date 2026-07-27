'use client'

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  AlertTriangle,
  CheckCircle2,
  Download,
  FileDown,
  FileSpreadsheet,
  History,
  Loader2,
  RefreshCcw,
  Upload,
} from 'lucide-react'
import {
  csvDocument,
  importDefinitions,
  type ImportOperationMode,
  type ImportReferenceMode,
  type MasterImportType,
} from '@/lib/master-import'

type CsvFile = {
  fileName: string
  checksum: string
  delimiter: string
  headers: string[]
  rows: { rowNumber: number; sourceData: Record<string, string> }[]
}

type Job = {
  id: string
  import_type: MasterImportType
  reference_mode: ImportReferenceMode
  operation_mode: ImportOperationMode
  file_name: string
  status: string
  total_rows: number
  created_rows: number
  updated_rows: number
  skipped_rows: number
  error_rows: number
  confirmed_update_count: number
  master_version: number
  mapping?: Record<string, string>
  uploaded_at: string
  validated_at: string | null
  committed_at: string | null
}

type ImportRow = {
  row_number: number
  source_data: Record<string, unknown>
  operation: 'PENDING' | 'CREATE' | 'UPDATE' | 'SKIP' | 'ERROR'
  row_status: string
  warnings: { code?: string }[]
  errors: { code?: string }[]
  before_state: Record<string, unknown> | null
  after_state: Record<string, unknown> | null
}

type DetailPayload = {
  data?: Job
  rows?: ImportRow[]
  stores?: { id: string; store_name: string }[]
  error?: string
}

const typeOptions = Object.entries(importDefinitions) as [MasterImportType, (typeof importDefinitions)[MasterImportType]][]
const operationLabels: Record<ImportOperationMode, string> = {
  CREATE_ONLY: 'Hanya buat data baru',
  UPDATE_ONLY: 'Hanya perbarui data yang ada',
  CREATE_AND_UPDATE: 'Buat baru dan perbarui',
}
const statusLabels: Record<string, string> = {
  UPLOADED: 'File diterima', MAPPED: 'Kolom dipetakan', VALIDATED: 'Siap dikonfirmasi',
  COMPLETED: 'Selesai', COMPLETED_WITH_ERRORS: 'Selesai sebagian', FAILED: 'Gagal',
}
const operationStyles: Record<string, string> = {
  CREATE: 'bg-emerald-50 text-emerald-700', UPDATE: 'bg-blue-50 text-blue-700',
  SKIP: 'bg-slate-100 text-slate-600', ERROR: 'bg-rose-50 text-rose-700',
}
const operationText: Record<string, string> = {
  CREATE: 'Data baru', UPDATE: 'Perbarui', SKIP: 'Tidak berubah', ERROR: 'Bermasalah', PENDING: 'Menunggu',
}
const fieldLabels: Record<string, string> = {
  name: 'Nama', isActive: 'Status aktif', uomType: 'Tipe UOM',
  allowDecimal: 'Boleh desimal', decimalPrecision: 'Presisi desimal',
  warehouseType: 'Tipe gudang', storeId: 'Toko terkait',
  storeReference: 'Toko terkait', location: 'Catatan lokasi',
  isSaleSource: 'Sumber penjualan', isPurchaseDestination: 'Tujuan pembelian',
  contactName: 'Nama kontak', phone: 'Telepon', address: 'Alamat', npwp: 'NPWP',
  paymentTerm: 'Termin pembayaran', bankName: 'Nama bank',
  bankAccountNumber: 'Nomor rekening', bankAccountHolder: 'Pemilik rekening',
  accountType: 'Tipe akun', normalBalance: 'Saldo normal',
  parentAccountId: 'Akun induk', parentAccountCode: 'Kode akun induk',
  systemFunctionKey: 'Fungsi akun sistem', isPostable: 'Dapat diposting',
  allowManualPosting: 'Boleh jurnal manual',
  allowReconciliation: 'Boleh rekonsiliasi',
  systemKey: 'System Event', description: 'Deskripsi',
}
const errorLabels: Record<string, string> = {
  CODE_REQUIRED: 'Identitas sistem belum dapat dibuat.', NAME_REQUIRED: 'Nama wajib diisi.',
  CODE_OR_NAME_ALREADY_USED: 'Nama atau identitas data sudah dipakai.',
  DUPLICATE_CODE_OR_NAME_IN_FILE: 'Nama data duplikat di file yang sama.',
  RECORD_ALREADY_EXISTS: 'Data sudah ada; mode saat ini hanya membuat data baru.',
  RECORD_NOT_FOUND_FOR_UPDATE: 'Data yang akan diperbarui tidak ditemukan.',
  ID_NOT_FOUND_IN_ACTIVE_COMPANY: 'Identitas internal tidak ditemukan pada Company aktif.',
  INVALID_INTERNAL_ID: 'Identitas internal tidak valid.', INVALID_BOOLEAN_IS_ACTIVE: 'Nilai status aktif tidak valid.',
  INVALID_UOM_TYPE: 'Tipe UOM tidak valid.', INVALID_WAREHOUSE_TYPE: 'Tipe gudang tidak valid.',
  STORE_WAREHOUSE_REQUIRES_STORE: 'Gudang Toko wajib memiliki toko terkait.',
  ACTIVE_STORE_NOT_FOUND: 'Toko terkait tidak aktif atau bukan milik Company ini.',
  UPDATE_EXISTING_CONFIRMATION_REQUIRED: 'Perubahan data existing membutuhkan konfirmasi.',
  MASTER_CHANGED_AFTER_VALIDATION: 'Data berubah setelah preview. Validasi ulang sebelum mencoba lagi.',
  DUPLICATE_MASTER_AT_COMMIT: 'Kode atau nama menjadi duplikat saat penyimpanan.',
  ACCOUNT_CODE_REQUIRED: 'Kode akun wajib diisi.',
  IMPORT_COA_MAPPING_REQUIRED: 'Kode akun dan nama akun wajib dipetakan.',
  IMPORT_SYSTEM_KEY_MAPPING_REQUIRED: 'Kolom System Event wajib dipetakan.',
  CUSTOMER_CATEGORY_NAME_TOO_LONG: 'Nama kategori pelanggan terlalu panjang.',
  NAME_ALREADY_USED: 'Nama sudah dipakai oleh data lain.',
  DUPLICATE_IDENTITY_IN_FILE: 'Nama atau kode duplikat di file yang sama.',
  ACTIVE_SYSTEM_EVENT_NOT_FOUND: 'System Event tidak aktif atau tidak ditemukan.',
  INVALID_ACCOUNT_TYPE: 'Tipe akun tidak valid.',
  INVALID_NORMAL_BALANCE: 'Saldo normal harus DEBIT atau CREDIT.',
  PARENT_ACCOUNT_NOT_FOUND_OR_NOT_PRIOR: 'Akun induk tidak ditemukan. Letakkan akun induk pada baris sebelumnya.',
  PARENT_ACCOUNT_NOT_FOUND_AT_COMMIT: 'Akun induk berubah atau tidak ditemukan saat penyimpanan.',
  COA_HIERARCHY_CYCLE: 'Struktur akun membentuk siklus atau terlalu dalam.',
  INCOMPATIBLE_OR_INACTIVE_ACCOUNT_FUNCTION: 'Fungsi akun tidak aktif atau tidak cocok dengan tipe akun.',
  MANUAL_POSTING_REQUIRES_POSTABLE_ACCOUNT: 'Jurnal manual hanya boleh untuk akun yang dapat diposting.',
  SYSTEM_MASTER_IMPORT_FORBIDDEN: 'Data bawaan sistem hanya dapat diekspor dan tidak boleh diubah lewat import.',
  SYSTEM_CUSTOMER_CATEGORY_IMMUTABLE: 'Kategori pelanggan bawaan sistem tidak boleh diubah.',
  REQUIRED_TRANSACTION_CATEGORY_CANNOT_BE_DISABLED: 'Kategori transaksi wajib tidak boleh dinonaktifkan.',
  REQUIRED_TRANSACTION_CATEGORY_SYSTEM_EVENT_LOCKED: 'System Event kategori transaksi wajib tidak boleh diubah.',
}

function authHeaders(session: Session, json = false) {
  return { ...(json ? { 'Content-Type': 'application/json' } : {}), Authorization: `Bearer ${session.access_token}` }
}

function normalizedHeader(value: string) {
  return value.trim().toLowerCase().replace(/[^a-z0-9]/g, '')
}

function parseCsv(text: string): Omit<CsvFile, 'fileName' | 'checksum'> {
  const firstLine = text.replace(/^\uFEFF/, '').split(/\r?\n/, 1)[0] ?? ''
  const candidates = [',', ';', '\t', '|']
  const delimiter = candidates.reduce((best, current) =>
    firstLine.split(current).length > firstLine.split(best).length ? current : best, ',')
  const records: string[][] = []
  let record: string[] = []
  let cell = ''
  let quoted = false
  const source = text.replace(/^\uFEFF/, '')
  for (let index = 0; index < source.length; index += 1) {
    const char = source[index]
    if (char === '"') {
      if (quoted && source[index + 1] === '"') {
        cell += '"'
        index += 1
      } else quoted = !quoted
    } else if (char === delimiter && !quoted) {
      record.push(cell)
      cell = ''
    } else if ((char === '\n' || char === '\r') && !quoted) {
      if (char === '\r' && source[index + 1] === '\n') index += 1
      record.push(cell)
      if (record.some((value) => value.trim() !== '')) records.push(record)
      record = []
      cell = ''
    } else cell += char
  }
  if (quoted) throw new Error('Tanda kutip pada CSV tidak tertutup.')
  record.push(cell)
  if (record.some((value) => value.trim() !== '')) records.push(record)
  if (records.length < 2) throw new Error('CSV harus memiliki header dan minimal satu baris data.')
  const headers = records[0].map((value) => value.trim())
  if (headers.some((header) => !header)) throw new Error('Semua kolom CSV wajib memiliki nama header.')
  if (headers.length > 100) throw new Error('CSV maksimal memiliki 100 kolom.')
  const normalized = headers.map(normalizedHeader)
  if (new Set(normalized).size !== headers.length) throw new Error('Nama kolom CSV tidak boleh duplikat.')
  const dataRows = records.slice(1)
  if (dataRows.length > 5000) throw new Error('Satu file maksimal berisi 5.000 baris data.')
  return {
    delimiter,
    headers,
    rows: dataRows.map((values, rowIndex) => ({
      rowNumber: rowIndex + 2,
      sourceData: Object.fromEntries(headers.map((header, columnIndex) => [header, values[columnIndex] ?? ''])),
    })),
  }
}

async function checksum(text: string) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))
  return Array.from(new Uint8Array(digest), (value) => value.toString(16).padStart(2, '0')).join('')
}

function autoMapping(type: MasterImportType, headers: string[]) {
  const mapping: Record<string, string> = {}
  for (const field of importDefinitions[type].fields) {
    const aliases = field.aliases.map(normalizedHeader)
    const match = headers.find((header) => aliases.includes(normalizedHeader(header)))
    if (match) mapping[field.key] = match
  }
  return mapping
}

function formatDate(value: string | null) {
  return value ? new Intl.DateTimeFormat('id-ID', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value)) : '-'
}

function friendlyError(code?: string) {
  const first = code?.split('\n')[0]
  const messages: Record<string, string> = {
    MASTER_IMPORT_ADMIN_REQUIRED: 'Hanya Pemilik atau Admin Company yang dapat menjalankan import.',
    MASTER_VERSION_CONFLICT: 'Job berubah di proses lain. Muat ulang riwayat lalu coba lagi.',
    IMPORT_UPDATE_CONFIRMATION_REQUIRED: 'Jumlah data yang diperbarui belum dikonfirmasi dengan benar.',
    IMPORT_JOB_NOT_COMMITTABLE: 'Job ini belum siap disimpan atau sudah selesai.',
    IMPORT_INTERNAL_ID_MAPPING_REQUIRED: 'Mode identitas internal wajib memetakan kolom ID internal.',
    IMPORT_CODE_NAME_MAPPING_REQUIRED: 'Database Import belum menerima template tanpa kode. Terapkan rollout terbaru.',
    IMPORT_NAME_MAPPING_REQUIRED: 'Kolom nama wajib dipetakan.',
  }
  return messages[first ?? ''] ?? errorLabels[first ?? ''] ?? first ?? 'Proses import gagal.'
}

function triggerDownload(content: Blob, fileName: string) {
  const url = URL.createObjectURL(content)
  const link = document.createElement('a')
  link.href = url
  link.download = fileName
  link.click()
  URL.revokeObjectURL(url)
}

export function MasterImportView({
  session,
  companyId,
  notify,
}: {
  session: Session
  companyId: string
  notify: (message: string) => void
}) {
  const inputRef = useRef<HTMLInputElement>(null)
  const [importType, setImportType] = useState<MasterImportType>('PRODUCT_CATEGORY')
  const [referenceMode, setReferenceMode] = useState<ImportReferenceMode>('REFERENCE_BY_NAME')
  const [operationMode, setOperationMode] = useState<ImportOperationMode>('CREATE_AND_UPDATE')
  const [csv, setCsv] = useState<CsvFile | null>(null)
  const [mapping, setMapping] = useState<Record<string, string>>({})
  const [jobs, setJobs] = useState<Job[]>([])
  const [detail, setDetail] = useState<DetailPayload | null>(null)
  const [busy, setBusy] = useState(false)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [confirmUpdate, setConfirmUpdate] = useState(false)
  const [clientRequestId, setClientRequestId] = useState(() => crypto.randomUUID())

  const loadJobs = useCallback(async () => {
    const response = await fetch('/api/master/import-jobs', { headers: authHeaders(session) })
    const payload = (await response.json()) as { data?: Job[]; error?: string }
    if (!response.ok) throw new Error(friendlyError(payload.error))
    setJobs(payload.data ?? [])
  }, [session])

  const loadDetail = useCallback(async (jobId: string) => {
    const response = await fetch(`/api/master/import-jobs/${jobId}`, { headers: authHeaders(session) })
    const payload = (await response.json()) as DetailPayload
    if (!response.ok) throw new Error(friendlyError(payload.error))
    setDetail(payload)
    setConfirmUpdate(false)
  }, [session])

  useEffect(() => {
    let cancelled = false
    // eslint-disable-next-line react-hooks/set-state-in-effect -- history follows the authenticated Company context
    loadJobs().catch((reason: unknown) => {
      if (!cancelled) setError(reason instanceof Error ? reason.message : 'Gagal memuat riwayat import.')
    }).finally(() => { if (!cancelled) setLoading(false) })
    return () => { cancelled = true }
  }, [companyId, loadJobs])

  const fields = importDefinitions[importType].fields.filter((field) =>
    !field.hidden && (field.key !== 'internalId' || referenceMode === 'REFERENCE_BY_ID'))
  const missingMapping = useMemo(() => fields.filter((field) =>
    (field.required || (field.key === 'internalId' && referenceMode === 'REFERENCE_BY_ID')) && !mapping[field.key],
  ), [fields, mapping, referenceMode])

  function resetPreview() {
    setDetail(null)
    setConfirmUpdate(false)
    setClientRequestId(crypto.randomUUID())
  }

  async function chooseFile(file: File | undefined) {
    if (!file) return
    setError('')
    if (!file.name.toLowerCase().endsWith('.csv')) return setError('Gunakan file CSV (.csv).')
    if (file.size > 5 * 1024 * 1024) return setError('Ukuran file maksimal 5 MB.')
    try {
      const text = await file.text()
      const parsed = parseCsv(text)
      const complete = { ...parsed, fileName: file.name, checksum: await checksum(text) }
      setCsv(complete)
      setMapping(autoMapping(importType, parsed.headers))
      setDetail(null)
      setClientRequestId(crypto.randomUUID())
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'CSV tidak dapat dibaca.')
    }
  }

  async function request(path: string, method: 'POST' | 'PATCH', body: Record<string, unknown>) {
    const response = await fetch(path, {
      method, headers: authHeaders(session, true), body: JSON.stringify(body),
    })
    const payload = (await response.json()) as { data?: Record<string, unknown>; error?: string }
    if (!response.ok || !payload.data) throw new Error(friendlyError(payload.error))
    return payload.data
  }

  async function validatePreview() {
    if (!csv || missingMapping.length || detail) return
    setBusy(true)
    setError('')
    try {
      const created = await request('/api/master/import-jobs', 'POST', {
        clientRequestId, importType, referenceMode, operationMode,
        fileName: csv.fileName, fileChecksum: csv.checksum, delimiter: csv.delimiter,
      })
      const jobId = String(created.jobId)
      const staged = await request(`/api/master/import-jobs/${jobId}`, 'PATCH', {
        action: 'STAGE', masterVersion: Number(created.masterVersion), mapping, rows: csv.rows,
      })
      await request(`/api/master/import-jobs/${jobId}`, 'PATCH', {
        action: 'VALIDATE', masterVersion: Number(staged.masterVersion),
      })
      await Promise.all([loadDetail(jobId), loadJobs()])
      notify('Preview import selesai. Belum ada master data yang diubah.')
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'Validasi import gagal.')
    } finally {
      setBusy(false)
    }
  }

  async function commit() {
    const job = detail?.data
    if (!job || job.status !== 'VALIDATED' || (job.updated_rows > 0 && !confirmUpdate)) return
    setBusy(true)
    setError('')
    try {
      await request(`/api/master/import-jobs/${job.id}`, 'PATCH', {
        action: 'COMMIT', masterVersion: job.master_version,
        confirmUpdateCount: job.updated_rows,
      })
      await Promise.all([loadDetail(job.id), loadJobs()])
      notify('Import selesai. Periksa ringkasan dan unduh baris error bila ada.')
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'Penyimpanan import gagal.')
    } finally {
      setBusy(false)
    }
  }

  async function download(kind: 'template' | 'data') {
    setBusy(true)
    setError('')
    try {
      const response = await fetch(`/api/master/import-export?type=${importType}&kind=${kind}`, {
        headers: authHeaders(session),
      })
      if (!response.ok) {
        const payload = (await response.json()) as { error?: string }
        throw new Error(friendlyError(payload.error))
      }
      const disposition = response.headers.get('content-disposition') ?? ''
      const name = disposition.match(/filename="([^"]+)"/)?.[1] ?? `${kind}-${importType.toLowerCase()}.csv`
      triggerDownload(await response.blob(), name)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'File gagal diunduh.')
    } finally {
      setBusy(false)
    }
  }

  function downloadErrors() {
    const rows = (detail?.rows ?? []).filter((row) => row.operation === 'ERROR' || row.row_status === 'ERROR')
    if (!rows.length) return
    const sourceHeaders = Array.from(new Set(rows.flatMap((row) =>
      Object.keys(row.source_data).filter((header) => !header.startsWith('__')))))
    const headers = [...sourceHeaders, '_baris', '_status', '_error']
    const data = rows.map((row) => ({
      ...row.source_data,
      _baris: row.row_number,
      _status: operationText[row.operation],
      _error: row.errors.map((item) => errorLabels[item.code ?? ''] ?? item.code).join(' | '),
    }))
    triggerDownload(new Blob([csvDocument(headers, data)], { type: 'text/csv;charset=utf-8' }), 'baris-import-bermasalah.csv')
  }

  const storeNames = Object.fromEntries((detail?.stores ?? []).map((store) => [store.id, store.store_name]))
  const activeMapping = detail?.data?.mapping ?? mapping

  function displayValue(key: string, value: unknown) {
    if (key === 'storeId') return value ? storeNames[String(value)] ?? 'Toko terkait' : '-'
    if (typeof value === 'boolean') return value ? 'Ya' : 'Tidak'
    if (value === null || value === undefined || value === '') return '-'
    return String(value)
  }

  function changes(row: ImportRow) {
    const after = row.after_state ?? {}
    const before = row.before_state ?? {}
    return Object.keys(after).filter((key) => !['id', 'code', 'masterVersion'].includes(key))
      .filter((key) => row.operation !== 'UPDATE' || JSON.stringify(after[key]) !== JSON.stringify(before[key]))
      .slice(0, 5)
  }

  return (
    <div className="space-y-6">
      <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
        <div className="flex flex-col justify-between gap-4 lg:flex-row lg:items-start">
          <div>
            <p className="text-xs font-bold uppercase tracking-[0.18em] text-emerald-600">Master Data</p>
            <h1 className="mt-2 text-2xl font-black text-slate-950">Import & Export</h1>
            <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
              CSV diperiksa dan ditampilkan sebagai preview terlebih dahulu. Data belum berubah sampai Anda menekan konfirmasi simpan.
            </p>
          </div>
          <div className="flex flex-wrap gap-2">
            <button disabled={busy} onClick={() => void download('template')} className="inline-flex items-center gap-2 rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold text-slate-700 hover:bg-slate-50 disabled:opacity-50">
              <FileDown className="h-4 w-4" /> Template CSV
            </button>
            <button disabled={busy} onClick={() => void download('data')} className="inline-flex items-center gap-2 rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold text-slate-700 hover:bg-slate-50 disabled:opacity-50">
              <Download className="h-4 w-4" /> Export data
            </button>
          </div>
        </div>

        <div className="mt-6 grid gap-4 md:grid-cols-3">
          <label className="text-sm font-bold text-slate-700">Jenis master
            <select value={importType} onChange={(event) => {
              const next = event.target.value as MasterImportType
              setImportType(next); setMapping(csv ? autoMapping(next, csv.headers) : {}); resetPreview()
            }} className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-3 outline-none focus:border-emerald-500">
              {typeOptions.map(([value, definition]) => <option key={value} value={value}>{definition.label}</option>)}
            </select>
          </label>
          <label className="text-sm font-bold text-slate-700">Cara mengenali data existing
            <select value={referenceMode} onChange={(event) => { setReferenceMode(event.target.value as ImportReferenceMode); resetPreview() }} className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-3 outline-none focus:border-emerald-500">
              <option value="REFERENCE_BY_NAME">
                {importType === 'CHART_OF_ACCOUNT'
                  ? 'Cocokkan berdasarkan kode akun'
                  : 'Cocokkan berdasarkan nama'}
              </option>
              <option value="REFERENCE_BY_ID">Cocokkan ID internal dari hasil export</option>
            </select>
          </label>
          <label className="text-sm font-bold text-slate-700">Tindakan
            <select value={operationMode} onChange={(event) => { setOperationMode(event.target.value as ImportOperationMode); resetPreview() }} className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-3 outline-none focus:border-emerald-500">
              {Object.entries(operationLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
            </select>
          </label>
        </div>
        <div className="mt-4 rounded-2xl bg-slate-50 p-4 text-sm text-slate-600">
          <span className="font-bold text-slate-900">{importDefinitions[importType].label}:</span> {importDefinitions[importType].description}
          {referenceMode === 'REFERENCE_BY_ID' && <p className="mt-1 text-amber-700">Gunakan ID internal hanya dari file export aplikasi; user tidak perlu membuat atau menghafalnya.</p>}
          {['CUSTOMER_CATEGORY', 'CHART_OF_ACCOUNT', 'TRANSACTION_CATEGORY'].includes(importType)
            && <p className="mt-1 text-amber-700">Baris bawaan sistem ikut tersedia di export untuk referensi, tetapi akan ditolak bila dicoba diubah lewat import.</p>}
        </div>

        <input ref={inputRef} type="file" accept=".csv,text/csv" className="hidden" onChange={(event) => void chooseFile(event.target.files?.[0])} />
        <button onClick={() => inputRef.current?.click()} className="mt-5 flex w-full items-center justify-center gap-3 rounded-2xl border-2 border-dashed border-slate-300 px-5 py-8 text-sm font-bold text-slate-700 transition hover:border-emerald-400 hover:bg-emerald-50/40">
          <Upload className="h-5 w-5 text-emerald-600" />
          {csv ? `Ganti file: ${csv.fileName} (${csv.rows.length} baris)` : 'Pilih file CSV maksimal 5 MB / 5.000 baris'}
        </button>

        {csv && (
          <div className="mt-6">
            <div className="flex items-center gap-2"><FileSpreadsheet className="h-5 w-5 text-emerald-600" /><h2 className="font-black text-slate-900">Pemetaan kolom</h2></div>
            <p className="mt-1 text-sm text-slate-500">Pilih kolom file yang sesuai dengan arti data di aplikasi.</p>
            <div className="mt-4 grid gap-4 md:grid-cols-2 xl:grid-cols-3">
              {fields.map((field) => {
                const required = field.required || (field.key === 'internalId' && referenceMode === 'REFERENCE_BY_ID')
                return <label key={field.key} className="text-sm font-bold text-slate-700">
                  {field.label}{required && <span className="text-rose-500"> *</span>}
                  <select value={mapping[field.key] ?? ''} onChange={(event) => { setMapping((current) => ({ ...current, [field.key]: event.target.value })); if (detail) resetPreview() }} className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-3 font-normal outline-none focus:border-emerald-500">
                    <option value="">Tidak dipakai</option>
                    {csv.headers.map((header) => <option key={header} value={header}>{header}</option>)}
                  </select>
                </label>
              })}
            </div>
            {missingMapping.length > 0 && <p className="mt-4 text-sm font-semibold text-amber-700">Lengkapi: {missingMapping.map((field) => field.label).join(', ')}.</p>}
            <button disabled={busy || missingMapping.length > 0 || Boolean(detail)} onClick={() => void validatePreview()} className="mt-5 inline-flex items-center gap-2 rounded-xl bg-emerald-600 px-5 py-3 text-sm font-black text-white hover:bg-emerald-700 disabled:cursor-not-allowed disabled:opacity-50">
              {busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <CheckCircle2 className="h-4 w-4" />} Validasi & tampilkan preview
            </button>
          </div>
        )}
      </section>

      {error && <div className="flex gap-3 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-800"><AlertTriangle className="h-5 w-5 shrink-0" />{error}</div>}

      {detail?.data && (
        <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-4">
            <div><p className="text-xs font-bold uppercase tracking-[0.16em] text-blue-600">Preview / Hasil</p><h2 className="mt-1 text-xl font-black text-slate-950">{detail.data.file_name}</h2><p className="mt-1 text-sm text-slate-500">{importDefinitions[detail.data.import_type].label} · {statusLabels[detail.data.status] ?? detail.data.status}</p></div>
            {(detail.data.error_rows > 0) && <button onClick={downloadErrors} className="inline-flex items-center gap-2 rounded-xl border border-rose-200 px-4 py-2.5 text-sm font-bold text-rose-700 hover:bg-rose-50"><Download className="h-4 w-4" /> Unduh baris error</button>}
          </div>
          <div className="mt-5 grid grid-cols-2 gap-3 lg:grid-cols-5">
            {[
              { label: 'Total', count: detail.data.total_rows, className: 'bg-slate-50' },
              { label: 'Data baru', count: detail.data.created_rows, className: 'bg-emerald-50' },
              { label: 'Diperbarui', count: detail.data.updated_rows, className: 'bg-blue-50' },
              { label: 'Tidak berubah', count: detail.data.skipped_rows, className: 'bg-slate-50' },
              { label: 'Error', count: detail.data.error_rows, className: 'bg-rose-50' },
            ].map((card) => <div key={card.label} className={`rounded-2xl p-4 ${card.className}`}><p className="text-xs font-bold text-slate-500">{card.label}</p><p className="mt-1 text-2xl font-black text-slate-900">{card.count}</p></div>)}
          </div>
          <div className="mt-5 overflow-x-auto rounded-2xl border border-slate-200">
            <table className="min-w-full divide-y divide-slate-200 text-sm">
              <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-4 py-3">Baris</th><th className="px-4 py-3">Nama data</th><th className="px-4 py-3">Hasil</th><th className="px-4 py-3">Perubahan / masalah</th></tr></thead>
              <tbody className="divide-y divide-slate-100">
                {(detail.rows ?? []).map((row) => <tr key={row.row_number} className="align-top"><td className="px-4 py-3 font-semibold text-slate-500">{row.row_number}</td><td className="px-4 py-3"><p className="font-bold text-slate-900">{String(row.after_state?.name ?? row.before_state?.name ?? row.source_data[activeMapping.name] ?? '-')}</p></td><td className="px-4 py-3"><span className={`inline-flex rounded-full px-2.5 py-1 text-xs font-bold ${operationStyles[row.operation] ?? 'bg-slate-100 text-slate-600'}`}>{operationText[row.operation] ?? row.operation}</span></td><td className="px-4 py-3 text-slate-600">{row.errors.length > 0 ? <ul className="space-y-1 text-rose-700">{row.errors.map((item, index) => <li key={`${item.code}-${index}`}>{errorLabels[item.code ?? ''] ?? item.code}</li>)}</ul> : <div className="space-y-1">{changes(row).map((key) => <p key={key}><span className="font-semibold">{fieldLabels[key] ?? key}:</span> {row.operation === 'UPDATE' && <><span className="line-through opacity-60">{displayValue(key, row.before_state?.[key])}</span> → </>}{displayValue(key, row.after_state?.[key])}</p>)}{row.operation === 'SKIP' && <span>Tidak ada perubahan.</span>}</div>}</td></tr>)}
              </tbody>
            </table>
          </div>

          {detail.data.status === 'VALIDATED' && (
            <div className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-5">
              <h3 className="font-black text-amber-950">Konfirmasi sebelum menyimpan</h3>
              <p className="mt-1 text-sm leading-6 text-amber-900">Yang disimpan hanya {detail.data.created_rows} data baru dan {detail.data.updated_rows} perubahan valid. {detail.data.error_rows} baris bermasalah tidak akan disimpan.</p>
              {detail.data.updated_rows > 0 && <label className="mt-3 flex items-start gap-3 text-sm font-semibold text-amber-950"><input type="checkbox" checked={confirmUpdate} onChange={(event) => setConfirmUpdate(event.target.checked)} className="mt-1 h-4 w-4" />Saya mengonfirmasi tepat {detail.data.updated_rows} data existing akan diperbarui sesuai preview.</label>}
              <button disabled={busy || (detail.data.updated_rows > 0 && !confirmUpdate)} onClick={() => void commit()} className="mt-4 inline-flex items-center gap-2 rounded-xl bg-amber-600 px-5 py-3 text-sm font-black text-white hover:bg-amber-700 disabled:opacity-50">{busy && <Loader2 className="h-4 w-4 animate-spin" />} Simpan data valid</button>
            </div>
          )}
        </section>
      )}

      <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
        <div className="flex items-center justify-between gap-3"><div className="flex items-center gap-2"><History className="h-5 w-5 text-slate-500" /><h2 className="text-lg font-black text-slate-950">Riwayat import</h2></div><button disabled={loading} onClick={() => void loadJobs()} aria-label="Muat ulang riwayat" className="rounded-xl border border-slate-200 p-2.5 text-slate-500 hover:bg-slate-50"><RefreshCcw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /></button></div>
        {jobs.length === 0 ? <p className="mt-4 rounded-2xl bg-slate-50 p-6 text-center text-sm text-slate-500">Belum ada riwayat import.</p> : <div className="mt-4 divide-y divide-slate-100">{jobs.map((job) => <button key={job.id} onClick={() => void loadDetail(job.id)} className="flex w-full flex-col gap-2 py-4 text-left transition hover:bg-slate-50 sm:flex-row sm:items-center sm:justify-between sm:px-3"><div><p className="font-bold text-slate-900">{job.file_name}</p><p className="text-xs text-slate-500">{importDefinitions[job.import_type].label} · {formatDate(job.uploaded_at)}</p></div><div className="flex items-center gap-3"><span className="text-xs font-semibold text-slate-500">{job.total_rows} baris</span><span className="rounded-full bg-slate-100 px-3 py-1 text-xs font-bold text-slate-700">{statusLabels[job.status] ?? job.status}</span></div></button>)}</div>}
      </section>
    </div>
  )
}
