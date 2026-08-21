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
  XCircle,
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
  group_key: string | null
  source_data: Record<string, unknown>
  operation: 'PENDING' | 'CREATE' | 'UPDATE' | 'SKIP' | 'ERROR'
  row_status: string
  warnings: { code?: string }[]
  errors: { code?: string; message?: string }[]
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
  CANCELED: 'Dibatalkan',
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
  customerCode: 'Kode Customer', customerName: 'Nama Customer',
  parentCustomerName: 'Customer induk',
  defaultPricelistName: 'Pricelist default', email: 'Email',
  customerType: 'Tipe Customer', creditLimit: 'Limit kredit',
  creditTermDays: 'Termin kredit (hari)', notes: 'Catatan',
  accountType: 'Tipe akun', normalBalance: 'Saldo normal',
  parentAccountId: 'Akun induk', parentAccountCode: 'Kode akun induk',
  systemFunctionKey: 'Fungsi akun sistem', isPostable: 'Dapat diposting',
  allowManualPosting: 'Boleh jurnal manual',
  allowReconciliation: 'Boleh rekonsiliasi',
  systemKey: 'System Event', description: 'Deskripsi',
  sku: 'SKU', productName: 'Nama Product', categoryId: 'Kategori',
  baseUomId: 'UOM dasar', weightReferenceUomId: 'UOM acuan berat',
  weightPerReferenceUomKg: 'Berat UOM terbesar', uoms: 'Daftar UOM',
  imageUrl: 'URL gambar', salesTaxRuleId: 'Pajak penjualan',
  purchaseTaxRuleId: 'Pajak pembelian',
  productKey: 'Kunci grup Product', categoryName: 'Nama kategori',
  uomName: 'Nama satuan', factorToBase: 'Isi satuan dalam UOM dasar',
  purchaseAllowed: 'Dapat dibeli', salesAllowed: 'Dapat dijual',
  purchasePrice: 'Harga beli', salePrice: 'Harga jual', barcode: 'Barcode',
  salesTaxRuleName: 'Pajak penjualan',
  purchaseTaxRuleName: 'Pajak pembelian',
  weightPerLargestUomKg: 'Berat UOM terbesar',
  weightIfLargestKg: 'Berat bila UOM terbesar',
  productId: 'Product', supplierId: 'Supplier',
  purchaseUomId: 'UOM pembelian',
  supplierProductCode: 'Kode Product dari Supplier',
  referencePurchasePrice: 'Harga beli referensi',
  isPreferredSupplier: 'Supplier utama',
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
  INVALID_CUSTOMER_NAME: 'Nama Customer wajib diisi dan maksimal 200 karakter.',
  INVALID_CUSTOMER_CODE: 'Kode Customer tidak valid atau merupakan kode sistem WALK-IN.',
  INVALID_CUSTOMER_CATEGORY_NAME: 'Nama kategori Customer wajib diisi.',
  ACTIVE_CUSTOMER_CATEGORY_NOT_FOUND: 'Kategori Customer aktif tidak ditemukan pada Company ini.',
  AMBIGUOUS_CUSTOMER_CATEGORY: 'Nama kategori Customer cocok dengan lebih dari satu data.',
  ACTIVE_ROOT_PARENT_CUSTOMER_NOT_FOUND: 'Customer induk aktif belum ada. Import Customer induk lebih dahulu.',
  AMBIGUOUS_PARENT_CUSTOMER: 'Nama Customer induk cocok dengan lebih dari satu data.',
  ACTIVE_CUSTOMER_PRICELIST_NOT_FOUND: 'Pricelist Customer aktif tidak ditemukan pada Company ini.',
  AMBIGUOUS_CUSTOMER_PRICELIST: 'Nama Pricelist Customer cocok dengan lebih dari satu data.',
  INVALID_CUSTOMER_TYPE: 'Tipe Customer harus INDIVIDUAL atau BUSINESS.',
  INVALID_CUSTOMER_CREDIT_LIMIT: 'Limit kredit tidak boleh negatif.',
  INVALID_CUSTOMER_CREDIT_TERM: 'Termin kredit harus 0 sampai 3650 hari.',
  CUSTOMER_TEXT_TOO_LONG: 'Telepon, email, alamat, atau catatan terlalu panjang.',
  SYSTEM_CUSTOMER_IMMUTABLE: 'Customer Walk-In bawaan sistem tidak boleh diubah lewat import.',
  CUSTOMER_ID_NOT_FOUND: 'ID Customer tidak ditemukan pada Company aktif.',
  CUSTOMER_IDENTITY_MISMATCH: 'ID internal dan nama Customer tidak merujuk data yang sama.',
  DUPLICATE_CUSTOMER_IN_FILE: 'Nama Customer berulang dalam file yang sama.',
  CUSTOMER_CANNOT_PARENT_ITSELF: 'Customer tidak dapat menjadi induk untuk dirinya sendiri.',
  INVALID_CUSTOMER_VALUE: 'Nilai Customer tidak valid. Periksa angka, status, dan termin kredit.',
  CUSTOMER_COMMIT_FAILED: 'Customer gagal disimpan. Periksa detail error pada baris ini.',
  PRODUCT_UOM_FACTOR_MUST_EXCEED_BASE: 'UOM turunan harus mempunyai isi lebih dari 1 UOM dasar.',
  PRODUCT_UOM_LARGEST_WEIGHT_REQUIRED: 'Berat wajib diisi karena UOM ini menjadi UOM terbesar.',
  PRODUCT_UOM_NOT_LARGEST: 'Berat hanya boleh diisi untuk UOM terbesar.',
  PRODUCT_UOM_RESELECTION_REQUIRED: 'Perubahan ini membuat UOM terbesar berpindah. Atur melalui form Product lengkap.',
  PRODUCT_UOM_CONVERSION_LOCKED_BY_MOVEMENT: 'Isi UOM tidak dapat diubah karena Product sudah memiliki Stock Movement.',
  PRODUCT_IDENTITY_MISMATCH: 'Nama Product tidak cocok dengan SKU pada template.',
  DUPLICATE_PRODUCT_UOM_IN_FILE: 'Product dan UOM yang sama muncul lebih dari sekali dalam file.',
  PRODUCT_UOM_COMMIT_FAILED: 'UOM Product gagal disimpan. Periksa detail error pada baris ini.',
  REQUIRED_TRANSACTION_CATEGORY_CANNOT_BE_DISABLED: 'Kategori transaksi wajib tidak boleh dinonaktifkan.',
  REQUIRED_TRANSACTION_CATEGORY_SYSTEM_EVENT_LOCKED: 'System Event kategori transaksi wajib tidak boleh diubah.',
  INVALID_PRODUCT_KEY: 'Kunci grup Product wajib diisi.',
  INVALID_PRODUCT_SKU: 'SKU Product wajib dan maksimal 100 karakter.',
  INVALID_PRODUCT_NAME: 'Nama Product wajib dan maksimal 200 karakter.',
  PRODUCT_CATEGORY_NAME_REQUIRED: 'Nama kategori Product wajib diisi.',
  UOM_NAME_REQUIRED: 'Nama satuan wajib diisi.',
  PRODUCT_UOM_FACTOR_BELOW_BASE: 'Isi satuan minimal 1 UOM dasar.',
  POSITIVE_REFERENCE_WEIGHT_REQUIRED: 'Berat UOM terbesar harus lebih dari nol.',
  PRODUCT_UOM_PRICE_NEGATIVE: 'Harga beli/jual tidak boleh negatif.',
  PURCHASE_PRICE_REQUIRED: 'Harga beli wajib diisi untuk UOM pembelian.',
  SALE_PRICE_REQUIRED: 'Harga jual wajib diisi untuk UOM penjualan.',
  ACTIVE_PRODUCT_CATEGORY_NOT_FOUND: 'Kategori aktif tidak ditemukan pada Company ini.',
  ACTIVE_PRODUCT_UOM_NOT_FOUND: 'Nama UOM aktif tidak ditemukan pada Company ini.',
  ACTIVE_SALES_TAX_RULE_NOT_FOUND: 'Aturan pajak penjualan aktif tidak ditemukan.',
  ACTIVE_PURCHASE_TAX_RULE_NOT_FOUND: 'Aturan pajak pembelian aktif tidak ditemukan.',
  PRODUCT_GROUP_HAS_INVALID_ROW: 'Satu atau lebih baris dalam grup Product bermasalah.',
  PRODUCT_UOM_ROW_LIMIT_EXCEEDED: 'Satu Product maksimal memiliki 20 baris UOM.',
  INCONSISTENT_PRODUCT_GROUP_HEADER: 'SKU, nama, kategori, status, pajak, dan berat harus sama pada seluruh baris grup.',
  DUPLICATE_PRODUCT_UOM: 'Nama UOM tidak boleh berulang dalam satu Product.',
  EXACTLY_ONE_BASE_UOM_REQUIRED: 'Tepat satu UOM harus memiliki isi satuan 1.',
  ACTIVE_SALES_UOM_REQUIRED: 'Product wajib memiliki minimal satu UOM penjualan.',
  ACTIVE_PURCHASE_UOM_REQUIRED: 'Product wajib memiliki minimal satu UOM pembelian.',
  DUPLICATE_PRODUCT_BARCODE: 'Barcode UOM duplikat dalam satu Product.',
  LARGEST_PRODUCT_UOM_FACTOR_NOT_UNIQUE: 'UOM terbesar harus tunggal; jangan gunakan faktor terbesar yang sama.',
  AMBIGUOUS_PRODUCT_MATCH: 'Nama Product cocok dengan lebih dari satu data existing.',
  IMPORT_UPDATE_TARGET_NOT_FOUND: 'Data existing untuk update tidak ditemukan.',
  DUPLICATE_PRODUCT_SKU: 'SKU sudah digunakan Product lain.',
  IMPORT_CREATE_ONLY_MATCHED_EXISTING: 'Data sudah ada sementara mode hanya membuat data baru.',
  BUNDLE_PRODUCT_IMPORT_NOT_SUPPORTED: 'Product Bundle hanya dapat diekspor dan belum dapat diubah lewat import ini.',
  PRODUCT_STRUCTURE_LOCKED_BY_TRANSACTION_HISTORY: 'SKU, Base UOM, dan struktur konversi tidak dapat diubah karena Product sudah memiliki histori transaksi.',
  DUPLICATE_PRODUCT_GROUP_IDENTITY: 'SKU atau nama Product dipakai oleh lebih dari satu product_key dalam file.',
  PRODUCT_GROUP_COMMIT_FAILED: 'Grup Product gagal disimpan. Periksa kembali preview dan data master referensi.',
  INVALID_SUPPLIER_NAME: 'Nama Supplier wajib dan maksimal 200 karakter.',
  INVALID_PURCHASE_UOM_NAME: 'Nama UOM pembelian wajib dan maksimal 200 karakter.',
  SUPPLIER_PRODUCT_CODE_TOO_LONG: 'Kode Product dari Supplier maksimal 200 karakter.',
  INVALID_PRODUCT_SUPPLIER_VALUE: 'Harga atau status relasi Product–Supplier tidak valid.',
  REFERENCE_PURCHASE_PRICE_NEGATIVE: 'Harga beli referensi tidak boleh negatif.',
  PREFERRED_SUPPLIER_MUST_BE_ACTIVE: 'Supplier utama harus menggunakan relasi aktif.',
  ACTIVE_STOCK_PRODUCT_NOT_FOUND: 'Product stock aktif dengan SKU tersebut tidak ditemukan pada Company ini.',
  AMBIGUOUS_PRODUCT_REFERENCE: 'SKU Product cocok dengan lebih dari satu data.',
  ACTIVE_SUPPLIER_NOT_FOUND: 'Supplier aktif tidak ditemukan pada Company ini.',
  AMBIGUOUS_SUPPLIER_REFERENCE: 'Nama Supplier cocok dengan lebih dari satu data.',
  ACTIVE_PURCHASE_PRODUCT_UOM_NOT_FOUND: 'Nama UOM tersebut tidak aktif atau tidak diizinkan untuk pembelian Product ini.',
  AMBIGUOUS_PURCHASE_UOM_REFERENCE: 'Nama UOM pembelian cocok dengan lebih dari satu data.',
  PRODUCT_SUPPLIER_ID_NOT_FOUND: 'ID internal relasi Product–Supplier tidak ditemukan pada Company ini.',
  IMPORT_INTERNAL_ID_REQUIRED_FOR_UPDATE: 'Gunakan ID internal dari hasil export untuk memperbarui relasi existing pada mode ID.',
  PRODUCT_SUPPLIER_IDENTITY_MISMATCH: 'ID relasi tidak cocok dengan Product dan Supplier pada baris ini.',
  DUPLICATE_PRODUCT_SUPPLIER_IN_FILE: 'Relasi Product dan Supplier yang sama muncul lebih dari sekali dalam file.',
  MULTIPLE_ACTIVE_PREFERRED_SUPPLIER: 'Satu Product hanya boleh memiliki satu Supplier utama aktif.',
  PRODUCT_SUPPLIER_COMMIT_FAILED: 'Relasi gagal disimpan. Muat ulang data referensi lalu validasi kembali.',
  INVALID_WAREHOUSE_NAME: 'Nama Gudang wajib dan maksimal 200 karakter.',
  INVALID_MINIMUM_STOCK_VALUE: 'Minimum Stock harus berupa angka yang valid.',
  MINIMUM_STOCK_NEGATIVE: 'Minimum Stock tidak boleh negatif.',
  MINIMUM_STOCK_TOO_LARGE: 'Nilai Minimum Stock terlalu besar.',
  MINIMUM_STOCK_REQUIRED_WHEN_ALERT_ENABLED: 'Minimum Stock wajib diisi ketika notifikasi aktif.',
  ACTIVE_STOCK_PRODUCT_WITH_BASE_UOM_NOT_FOUND: 'Product stok aktif dengan Base UOM valid tidak ditemukan.',
  ACTIVE_WAREHOUSE_NOT_FOUND: 'Gudang aktif tidak ditemukan pada Company ini.',
  AMBIGUOUS_WAREHOUSE_REFERENCE: 'Nama Gudang cocok dengan lebih dari satu data.',
  MINIMUM_STOCK_BASE_UOM_REQUIRES_INTEGER: 'Base UOM Product hanya menerima quantity bilangan bulat.',
  MINIMUM_STOCK_BASE_UOM_PRECISION_EXCEEDED: 'Jumlah desimal melebihi presisi Base UOM Product.',
  MINIMUM_STOCK_SETTING_ID_NOT_FOUND: 'ID internal pengaturan Minimum Stock tidak ditemukan.',
  MINIMUM_STOCK_SETTING_IDENTITY_MISMATCH: 'ID pengaturan tidak cocok dengan Product dan Gudang pada baris.',
  DUPLICATE_PRODUCT_WAREHOUSE_IN_FILE: 'Pasangan Product dan Gudang muncul lebih dari sekali dalam file.',
  MINIMUM_STOCK_COMMIT_FAILED: 'Pengaturan Minimum Stock gagal disimpan. Validasi ulang data terbaru.',
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
  const [errorCode, errorDetail] = first?.split(':', 2) ?? []
  const messages: Record<string, string> = {
    MASTER_IMPORT_ADMIN_REQUIRED: 'Hanya Pemilik atau Admin Company yang dapat menjalankan import.',
    MASTER_VERSION_CONFLICT: 'Job berubah di proses lain. Muat ulang riwayat lalu coba lagi.',
    IMPORT_UPDATE_CONFIRMATION_REQUIRED: 'Jumlah data yang diperbarui belum dikonfirmasi dengan benar.',
    IMPORT_JOB_NOT_COMMITTABLE: 'Job ini belum siap disimpan atau sudah selesai.',
    IMPORT_INTERNAL_ID_MAPPING_REQUIRED: 'Mode identitas internal wajib memetakan kolom ID internal.',
    IMPORT_CODE_NAME_MAPPING_REQUIRED: 'Database Import belum menerima template tanpa kode. Terapkan rollout terbaru.',
    IMPORT_NAME_MAPPING_REQUIRED: 'Kolom nama wajib dipetakan.',
    IMPORT_PRODUCT_MAPPING_REQUIRED: 'Kolom wajib template Product belum dipetakan.',
    IMPORT_PRODUCT_SUPPLIER_MAPPING_REQUIRED: 'Kolom wajib template Relasi Produk–Supplier belum dipetakan.',
    IMPORT_MINIMUM_STOCK_MAPPING_REQUIRED: 'Kolom wajib template Minimum Stock belum dipetakan.',
    IMPORT_JOB_NOT_CANCELABLE: 'Job sedang diproses atau sudah selesai sehingga tidak dapat dibatalkan.',
    PRODUCT_UOM_NAME_REQUIRED: 'Nama UOM turunan wajib diisi pada setiap baris INPUT yang mempunyai faktor, harga, izin, barcode, atau berat.',
    PRODUCT_UOM_BARCODE_CONFLICT: 'Barcode UOM turunan sama dengan barcode UOM lain. Kosongkan barcode atau gunakan barcode kemasan yang berbeda.',
  }
  const message = messages[errorCode ?? ''] ?? errorLabels[errorCode ?? '']
  if (message) {
    return errorDetail ? `${message} Periksa baris: ${errorDetail}.` : message
  }
  return first ?? 'Proses import gagal.'
}

function friendlyRowError(item: { code?: string; message?: string }) {
  const label = errorLabels[item.code ?? ''] ?? item.code ?? 'Kesalahan import'
  if (item.message && item.code?.endsWith('_COMMIT_FAILED')) {
    return `${label} Detail: ${item.message}`
  }
  return label
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
  allowedTypes,
  embedded = false,
}: {
  session: Session
  companyId: string
  notify: (message: string) => void
  allowedTypes?: MasterImportType[]
  embedded?: boolean
}) {
  const inputRef = useRef<HTMLInputElement>(null)
  const selectableTypeOptions = useMemo(
    () => typeOptions.filter(([type]) => !allowedTypes || allowedTypes.includes(type)),
    [allowedTypes],
  )
  const [importType, setImportType] = useState<MasterImportType>(
    allowedTypes?.[0] ?? 'PRODUCT_CATEGORY',
  )
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
  const [confirmCancel, setConfirmCancel] = useState(false)
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
    setConfirmCancel(false)
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
    setConfirmCancel(false)
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
    let pendingJob: { id: string; masterVersion: number } | null = null
    let validationFinished = false
    try {
      const created = await request('/api/master/import-jobs', 'POST', {
        clientRequestId, importType, referenceMode, operationMode,
        fileName: csv.fileName, fileChecksum: csv.checksum, delimiter: csv.delimiter,
      })
      const jobId = String(created.jobId)
      pendingJob = { id: jobId, masterVersion: Number(created.masterVersion) }
      const staged = await request(`/api/master/import-jobs/${jobId}`, 'PATCH', {
        action: 'STAGE', masterVersion: Number(created.masterVersion), mapping, rows: csv.rows,
      })
      pendingJob.masterVersion = Number(staged.masterVersion)
      const validated = await request(`/api/master/import-jobs/${jobId}`, 'PATCH', {
        action: 'VALIDATE', masterVersion: Number(staged.masterVersion),
      })
      validationFinished = true
      await Promise.all([loadDetail(jobId), loadJobs()])
      if (validated.status === 'CANCELED') {
        notify('Validasi menemukan baris bermasalah. Job otomatis dibatalkan; master data tidak berubah.')
      } else {
        notify('Preview import selesai. Belum ada master data yang diubah.')
      }
    } catch (reason) {
      if (pendingJob && !validationFinished) {
        try {
          await request(`/api/master/import-jobs/${pendingJob.id}`, 'PATCH', {
            action: 'CANCEL', masterVersion: pendingJob.masterVersion,
            reason: 'CLIENT_VALIDATION_ABORTED',
          })
          await loadJobs()
        } catch { /* best effort; manual cancel remains available */ }
      }
      setError(reason instanceof Error ? reason.message : 'Validasi import gagal.')
    } finally {
      setBusy(false)
    }
  }

  async function cancelJob() {
    const job = detail?.data
    if (!job || !['UPLOADED', 'MAPPED', 'VALIDATED', 'READY'].includes(job.status)) return
    setBusy(true)
    setError('')
    try {
      await request(`/api/master/import-jobs/${job.id}`, 'PATCH', {
        action: 'CANCEL', masterVersion: job.master_version,
        reason: 'USER_CANCELED',
      })
      await Promise.all([loadDetail(job.id), loadJobs()])
      notify('Job import dibatalkan. Tidak ada master data yang diubah.')
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : 'Job import gagal dibatalkan.')
    } finally {
      setBusy(false)
      setConfirmCancel(false)
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
      _error: row.errors.map(friendlyRowError).join(' | '),
    }))
    triggerDownload(new Blob([csvDocument(headers, data)], { type: 'text/csv;charset=utf-8' }), 'baris-import-bermasalah.csv')
  }

  const storeNames = Object.fromEntries((detail?.stores ?? []).map((store) => [store.id, store.store_name]))
  const activeMapping = detail?.data?.mapping ?? mapping
  const isProductPreview = detail?.data?.import_type === 'PRODUCT'
  const isProductSupplierPreview = detail?.data?.import_type === 'PRODUCT_SUPPLIER'
  const isMinimumStockPreview =
    detail?.data?.import_type === 'PRODUCT_WAREHOUSE_MINIMUM_STOCK'
  const productPreviewGroups = (() => {
    if (!isProductPreview) return [] as { key: string; rows: ImportRow[] }[]
    const grouped = new Map<string, ImportRow[]>()
    for (const row of detail?.rows ?? []) {
      const sourceKey = activeMapping.productKey
        ? String(row.source_data[activeMapping.productKey] ?? '')
        : ''
      const key = row.group_key || sourceKey || `Baris ${row.row_number}`
      grouped.set(key, [...(grouped.get(key) ?? []), row])
    }
    return Array.from(grouped, ([key, rows]) => ({ key, rows }))
  })()

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

  function sourceValue(row: ImportRow, field: string) {
    const column = activeMapping[field]
    const value = column ? row.source_data[column] : undefined
    return value === null || value === undefined || value === '' ? '-' : String(value)
  }

  function productRowSummary(row: ImportRow) {
    const isTrue = (value: string) =>
      ['true', 't', '1', 'yes', 'ya', 'aktif'].includes(value.trim().toLowerCase())
    const uses = [
      isTrue(sourceValue(row, 'purchaseAllowed')) ? 'Beli' : '',
      isTrue(sourceValue(row, 'salesAllowed')) ? 'Jual' : '',
    ].filter(Boolean).join(' & ') || 'Tidak dipakai transaksi'
    return `Isi ${sourceValue(row, 'factorToBase')} UOM dasar · ${uses} · Harga beli ${sourceValue(row, 'purchasePrice')} · Harga jual ${sourceValue(row, 'salePrice')}`
  }

  function productSupplierRowSummary(row: ImportRow) {
    const preferred = ['true', 't', '1', 'yes', 'ya', 'aktif']
      .includes(sourceValue(row, 'isPreferredSupplier').trim().toLowerCase())
    const active = !['false', 'f', '0', 'no', 'tidak', 'nonaktif']
      .includes(sourceValue(row, 'isActive').trim().toLowerCase())
    return `Product ${sourceValue(row, 'productSku')} · UOM beli ${sourceValue(row, 'purchaseUomName')} · Harga referensi ${sourceValue(row, 'referencePurchasePrice')} · ${preferred ? 'Supplier utama' : 'Supplier alternatif'} · ${active ? 'Aktif' : 'Nonaktif'}`
  }

  function minimumStockRowSummary(row: ImportRow) {
    const alert = ['true', 't', '1', 'yes', 'ya', 'aktif']
      .includes(sourceValue(row, 'lowStockAlertEnabled').trim().toLowerCase())
    return `Gudang ${sourceValue(row, 'warehouseName')} · Minimum ${sourceValue(row, 'minimumStockBaseQty')} Base UOM · Notifikasi ${alert ? 'aktif' : 'nonaktif'}`
  }

  function previewRow(
    row: ImportRow,
    product = false,
    productSupplier = false,
    minimumStock = false,
  ) {
    const name = minimumStock
      ? `SKU ${sourceValue(row, 'productSku')}`
      : productSupplier
      ? sourceValue(row, 'supplierName')
      : product
        ? sourceValue(row, 'uomName')
        : String(row.after_state?.name ?? row.before_state?.name ?? row.source_data[activeMapping.name] ?? '-')
    return <tr key={row.row_number} className="align-top">
      <td className="px-4 py-3 font-semibold text-slate-500">{row.row_number}</td>
      <td className="px-4 py-3">
        <p className="font-bold text-slate-900">{name}</p>
        {product && <p className="mt-1 max-w-xl text-xs leading-5 text-slate-500">{productRowSummary(row)}</p>}
        {productSupplier && <p className="mt-1 max-w-xl text-xs leading-5 text-slate-500">{productSupplierRowSummary(row)}</p>}
        {minimumStock && <p className="mt-1 max-w-xl text-xs leading-5 text-slate-500">{minimumStockRowSummary(row)}</p>}
      </td>
      <td className="px-4 py-3">
        <span className={`inline-flex rounded-full px-2.5 py-1 text-xs font-bold ${operationStyles[row.operation] ?? 'bg-slate-100 text-slate-600'}`}>
          {operationText[row.operation] ?? row.operation}
        </span>
      </td>
      <td className="px-4 py-3 text-slate-600">
        {row.errors.length > 0
          ? <ul className="space-y-1 text-rose-700">{row.errors.map((item, index) => <li key={`${item.code}-${index}`}>{friendlyRowError(item)}</li>)}</ul>
          : product
            ? <span>{row.operation === 'SKIP' ? 'Tidak ada perubahan.' : 'Baris UOM valid dan akan disimpan bersama seluruh grup Product.'}</span>
            : productSupplier
              ? <span>{row.operation === 'SKIP' ? 'Tidak ada perubahan.' : row.operation === 'UPDATE' ? 'Relasi existing akan diperbarui sesuai nilai di atas.' : 'Relasi Product–Supplier baru siap disimpan.'}</span>
              : minimumStock
                ? <span>{row.operation === 'SKIP' ? 'Tidak ada perubahan.' : row.operation === 'UPDATE' ? 'Batas dan status notifikasi akan diperbarui.' : 'Pengaturan Minimum Stock baru siap disimpan.'}</span>
            : <div className="space-y-1">
                {changes(row).map((key) => <p key={key}><span className="font-semibold">{fieldLabels[key] ?? key}:</span> {row.operation === 'UPDATE' && <><span className="line-through opacity-60">{displayValue(key, row.before_state?.[key])}</span> → </>}{displayValue(key, row.after_state?.[key])}</p>)}
                {row.operation === 'SKIP' && <span>Tidak ada perubahan.</span>}
              </div>}
      </td>
    </tr>
  }

  return (
    <div className="space-y-6">
      <section className="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
        <div className="flex flex-col justify-between gap-4 lg:flex-row lg:items-start">
          <div>
            <p className="text-xs font-bold uppercase tracking-[0.18em] text-emerald-600">{embedded ? 'Global Data Exchange' : 'Master Data'}</p>
            <h1 className="mt-2 text-2xl font-black text-slate-950">{embedded ? 'Import data' : 'Import & Export'}</h1>
            <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
              CSV diperiksa dan ditampilkan sebagai preview terlebih dahulu. Data belum berubah sampai Anda menekan konfirmasi simpan.
            </p>
          </div>
          <div className="flex flex-wrap gap-2">
            <button disabled={busy} onClick={() => void download('template')} className="inline-flex items-center gap-2 rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold text-slate-700 hover:bg-slate-50 disabled:opacity-50">
              <FileDown className="h-4 w-4" /> Template CSV
            </button>
            {!embedded && <button disabled={busy} onClick={() => void download('data')} className="inline-flex items-center gap-2 rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold text-slate-700 hover:bg-slate-50 disabled:opacity-50">
              <Download className="h-4 w-4" /> Export data
            </button>}
          </div>
        </div>

        <div className="mt-6 grid gap-4 md:grid-cols-3">
          <label className="text-sm font-bold text-slate-700">Jenis master
            <select value={importType} onChange={(event) => {
              const next = event.target.value as MasterImportType
              setImportType(next); setMapping(csv ? autoMapping(next, csv.headers) : {}); resetPreview()
            }} className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-3 outline-none focus:border-emerald-500">
              {selectableTypeOptions.map(([value, definition]) => <option key={value} value={value}>{definition.label}</option>)}
            </select>
          </label>
          <label className="text-sm font-bold text-slate-700">Cara mengenali data existing
            <select value={referenceMode} onChange={(event) => { setReferenceMode(event.target.value as ImportReferenceMode); resetPreview() }} className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-3 outline-none focus:border-emerald-500">
              <option value="REFERENCE_BY_NAME">
                {importType === 'CHART_OF_ACCOUNT'
                  ? 'Cocokkan berdasarkan kode akun'
                  : importType === 'PRODUCT'
                    ? 'Cocokkan berdasarkan SKU atau nama Product'
                  : importType === 'PRODUCT_SUPPLIER'
                    ? 'Cocokkan berdasarkan Product + Supplier'
                    : importType === 'PRODUCT_WAREHOUSE_MINIMUM_STOCK'
                      ? 'Cocokkan berdasarkan Product + Gudang'
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
          {importType === 'PRODUCT' && <div className="mt-3 rounded-xl border border-emerald-200 bg-white p-3 text-emerald-900">
            <p className="font-bold">Cara mengisi Product:</p>
            <p className="mt-1">Gunakan product_key yang sama untuk seluruh satuan milik satu Product. Satu baris harus berisi faktor 1 sebagai UOM dasar; faktor terbesar menjadi UOM acuan berat.</p>
            <p className="mt-1 font-semibold text-amber-700">Stok dan Saldo Awal tidak ikut diimpor dari file ini.</p>
            <p className="mt-1 text-amber-700">Product Bundle tersedia di export sebagai referensi, tetapi belum dapat dibuat atau diubah lewat import ini.</p>
          </div>}
          {importType === 'PRODUCT_UOM' && <div className="mt-3 rounded-xl border border-blue-200 bg-white p-3 text-blue-950">
            <p className="font-bold">Cara menambah UOM pada Product existing:</p>
            <p className="mt-1">Baris <span className="font-bold">REFERENCE</span> menampilkan UOM existing dari terkecil sampai terbesar dan tidak ikut diimport. Isi baris <span className="font-bold">INPUT</span> kosong di bawah Product; duplikasi baris INPUT jika perlu lebih dari satu UOM.</p>
            <p className="mt-1">UOM dasar tidak dapat diubah di sini. Jika UOM baru menjadi yang terbesar, isi berat UOM tersebut dalam kilogram.</p>
            <p className="mt-1 font-semibold text-amber-700">Jangan mengubah atau menghapus nilai row_mode. UOM Product existing tetap dipertahankan.</p>
          </div>}
          {importType === 'CUSTOMER' && <div className="mt-3 rounded-xl border border-blue-200 bg-white p-3 text-blue-950">
            <p className="font-bold">Cara mengisi Customer:</p>
            <p className="mt-1">Kategori, Customer induk, dan Pricelist harus sudah tersedia pada Company aktif. Jika memakai hierarki, import Customer induk lebih dahulu lalu import cabangnya.</p>
            <p className="mt-1 font-semibold text-amber-700">Walk-In, saldo Customer, piutang awal, dan histori transaksi tidak ikut diimpor.</p>
          </div>}
          {importType === 'PRODUCT_SUPPLIER' && <div className="mt-3 rounded-xl border border-blue-200 bg-white p-3 text-blue-950">
            <p className="font-bold">Cara mengisi relasi Product–Supplier:</p>
            <p className="mt-1">Isi SKU Product, nama Supplier, dan nama UOM yang memang aktif untuk pembelian Product tersebut. Product, Supplier, dan UOM harus dibuat lebih dahulu.</p>
            <p className="mt-1">Untuk mengganti Supplier utama dalam satu file: set Supplier lama menjadi <span className="font-bold">false</span>, lalu Supplier baru menjadi <span className="font-bold">true</span>.</p>
            <p className="mt-1 font-semibold text-amber-700">Harga ini hanya referensi master. Harga pembelian terakhir, transaksi, dan stok tidak ikut berubah.</p>
          </div>}
          {importType === 'PRODUCT_WAREHOUSE_MINIMUM_STOCK' && <div className="mt-3 rounded-xl border border-amber-200 bg-white p-3 text-amber-950">
            <p className="font-bold">Cara mengisi Minimum Stock:</p>
            <p className="mt-1">Isi SKU Product, nama Gudang, batas stok dalam Base UOM Product, dan status notifikasi. Product serta Gudang harus aktif dan sudah dibuat.</p>
            <p className="mt-1 font-semibold">File ini hanya mengatur batas notifikasi. Saldo stok, movement, Stock Request, dan Supplier Order tidak dibuat atau diubah.</p>
          </div>}
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
            <div className="flex flex-wrap gap-2">
              {(detail.data.error_rows > 0) && <button onClick={downloadErrors} className="inline-flex items-center gap-2 rounded-xl border border-rose-200 px-4 py-2.5 text-sm font-bold text-rose-700 hover:bg-rose-50"><Download className="h-4 w-4" /> Unduh baris error</button>}
              {['UPLOADED', 'MAPPED', 'VALIDATED', 'READY'].includes(detail.data.status) && <button onClick={() => setConfirmCancel(true)} className="inline-flex items-center gap-2 rounded-xl border border-slate-300 px-4 py-2.5 text-sm font-bold text-slate-700 hover:bg-slate-50"><XCircle className="h-4 w-4" /> Batalkan job</button>}
            </div>
          </div>
          {confirmCancel && <div className="mt-4 rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-900"><p className="font-black">Batalkan job import ini?</p><p className="mt-1">Data master belum berubah. Job akan ditutup agar tidak menghambat import berikutnya.</p><div className="mt-3 flex gap-2"><button disabled={busy} onClick={() => void cancelJob()} className="rounded-xl bg-rose-600 px-4 py-2 font-bold text-white disabled:opacity-50">Ya, batalkan</button><button disabled={busy} onClick={() => setConfirmCancel(false)} className="rounded-xl border border-rose-200 bg-white px-4 py-2 font-bold">Kembali</button></div></div>}
          <div className="mt-5 grid grid-cols-2 gap-3 lg:grid-cols-5">
            {(isProductPreview
              ? [
                  { label: 'Baris UOM', count: detail.data.total_rows, className: 'bg-slate-50' },
                  { label: 'Product baru', count: detail.data.created_rows, className: 'bg-emerald-50' },
                  { label: 'Product diperbarui', count: detail.data.updated_rows, className: 'bg-blue-50' },
                  { label: 'Product tetap', count: detail.data.skipped_rows, className: 'bg-slate-50' },
                  { label: 'Grup error', count: detail.data.error_rows, className: 'bg-rose-50' },
                ]
              : isProductSupplierPreview
                ? [
                    { label: 'Total relasi', count: detail.data.total_rows, className: 'bg-slate-50' },
                    { label: 'Relasi baru', count: detail.data.created_rows, className: 'bg-emerald-50' },
                    { label: 'Relasi diperbarui', count: detail.data.updated_rows, className: 'bg-blue-50' },
                    { label: 'Tidak berubah', count: detail.data.skipped_rows, className: 'bg-slate-50' },
                    { label: 'Error', count: detail.data.error_rows, className: 'bg-rose-50' },
                  ]
                : isMinimumStockPreview
                  ? [
                      { label: 'Total pasangan', count: detail.data.total_rows, className: 'bg-slate-50' },
                      { label: 'Pengaturan baru', count: detail.data.created_rows, className: 'bg-emerald-50' },
                      { label: 'Diperbarui', count: detail.data.updated_rows, className: 'bg-blue-50' },
                      { label: 'Tidak berubah', count: detail.data.skipped_rows, className: 'bg-slate-50' },
                      { label: 'Error', count: detail.data.error_rows, className: 'bg-rose-50' },
                    ]
              : [
                  { label: 'Total', count: detail.data.total_rows, className: 'bg-slate-50' },
                  { label: 'Data baru', count: detail.data.created_rows, className: 'bg-emerald-50' },
                  { label: 'Diperbarui', count: detail.data.updated_rows, className: 'bg-blue-50' },
                  { label: 'Tidak berubah', count: detail.data.skipped_rows, className: 'bg-slate-50' },
                  { label: 'Error', count: detail.data.error_rows, className: 'bg-rose-50' },
                ]
            ).map((card) => <div key={card.label} className={`rounded-2xl p-4 ${card.className}`}><p className="text-xs font-bold text-slate-500">{card.label}</p><p className="mt-1 text-2xl font-black text-slate-900">{card.count}</p></div>)}
          </div>
          {isProductPreview && <p className="mt-3 text-xs leading-5 text-slate-500">Ringkasan Product dihitung per <span className="font-bold">product_key</span>; tabel di bawah tetap menampilkan setiap baris UOM agar konversi dan harga dapat diperiksa.</p>}
          <div className="mt-5 overflow-x-auto rounded-2xl border border-slate-200">
            <table className="min-w-full divide-y divide-slate-200 text-sm">
              <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500"><tr><th className="px-4 py-3">Baris</th><th className="px-4 py-3">{isProductPreview ? 'Nama UOM' : isProductSupplierPreview ? 'Nama Supplier' : isMinimumStockPreview ? 'Product & Gudang' : 'Nama data'}</th><th className="px-4 py-3">Hasil</th><th className="px-4 py-3">Perubahan / masalah</th></tr></thead>
              <tbody className="divide-y divide-slate-100">
                {isProductPreview
                  ? productPreviewGroups.flatMap((group) => {
                      const firstRow = group.rows[0]
                      return [
                        <tr key={`group-${group.key}`} className="bg-blue-50/70">
                          <td className="px-4 py-3 text-xs font-black uppercase tracking-wide text-blue-700" colSpan={4}>
                            {sourceValue(firstRow, 'productName')} · SKU {sourceValue(firstRow, 'sku')} · product_key {group.key} · {group.rows.length} UOM
                          </td>
                        </tr>,
                        ...group.rows.map((row) => previewRow(row, true)),
                      ]
                    })
                  : (detail.rows ?? []).map((row) =>
                      previewRow(row, false, isProductSupplierPreview, isMinimumStockPreview),
                    )}
              </tbody>
            </table>
          </div>

          {detail.data.status === 'VALIDATED' && (
            <div className="mt-5 rounded-2xl border border-amber-200 bg-amber-50 p-5">
              <h3 className="font-black text-amber-950">Konfirmasi sebelum menyimpan</h3>
              <p className="mt-1 text-sm leading-6 text-amber-900">Yang disimpan hanya {detail.data.created_rows} {isProductPreview ? 'Product baru' : isProductSupplierPreview ? 'relasi baru' : 'data baru'} dan {detail.data.updated_rows} {isProductPreview ? 'Product existing' : isProductSupplierPreview ? 'relasi existing' : 'perubahan valid'}. {detail.data.error_rows} {isProductPreview ? 'grup Product' : 'baris'} bermasalah tidak akan disimpan.</p>
              {detail.data.updated_rows > 0 && <label className="mt-3 flex items-start gap-3 text-sm font-semibold text-amber-950"><input type="checkbox" checked={confirmUpdate} onChange={(event) => setConfirmUpdate(event.target.checked)} className="mt-1 h-4 w-4" />Saya mengonfirmasi tepat {detail.data.updated_rows} {isProductPreview ? 'Product existing' : isProductSupplierPreview ? 'relasi existing' : 'data existing'} akan diperbarui sesuai preview.</label>}
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
