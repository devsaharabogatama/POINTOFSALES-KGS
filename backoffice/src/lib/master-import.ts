export type MasterImportType =
  | 'PRODUCT_CATEGORY'
  | 'UOM'
  | 'WAREHOUSE'
  | 'SUPPLIER'
  | 'CUSTOMER_CATEGORY'
  | 'CHART_OF_ACCOUNT'
  | 'TRANSACTION_CATEGORY'
export type ImportReferenceMode = 'REFERENCE_BY_ID' | 'REFERENCE_BY_NAME'
export type ImportOperationMode = 'CREATE_ONLY' | 'UPDATE_ONLY' | 'CREATE_AND_UPDATE'

export type ImportField = {
  key: string
  label: string
  required: boolean
  aliases: string[]
  hidden?: boolean
}

export type ImportDefinition = {
  label: string
  description: string
  fields: ImportField[]
  templateHeaders: string[]
  exportHeaders: string[]
}

export const importDefinitions: Record<MasterImportType, ImportDefinition> = {
  PRODUCT_CATEGORY: {
    label: 'Kategori Produk',
    description: 'Nama dan status aktif kategori produk. Kode dibuat otomatis oleh sistem.',
    fields: [
      { key: 'internalId', label: 'ID internal (opsional)', required: false, aliases: ['internal_id', 'id'] },
      { key: 'code', label: 'Kode sistem', required: false, hidden: true, aliases: ['code', 'kode', 'category_code', 'kode_kategori', 'system_code'] },
      { key: 'name', label: 'Nama kategori', required: true, aliases: ['name', 'nama', 'category_name', 'nama_kategori'] },
      { key: 'isActive', label: 'Status aktif', required: false, aliases: ['is_active', 'aktif', 'status_aktif'] },
    ],
    templateHeaders: ['name', 'is_active'],
    exportHeaders: ['internal_id', 'name', 'is_active'],
  },
  UOM: {
    label: 'Satuan (UOM)',
    description: 'Nama satuan yang dilihat user beserta aturan quantity-nya. Kode dibuat otomatis.',
    fields: [
      { key: 'internalId', label: 'ID internal (opsional)', required: false, aliases: ['internal_id', 'id'] },
      { key: 'code', label: 'Kode sistem', required: false, hidden: true, aliases: ['code', 'kode', 'uom_code', 'kode_uom', 'system_code'] },
      { key: 'name', label: 'Nama UOM', required: true, aliases: ['name', 'nama', 'uom_name', 'nama_uom'] },
      { key: 'uomType', label: 'Tipe UOM', required: true, aliases: ['uom_type', 'tipe_uom', 'type'] },
      { key: 'allowDecimal', label: 'Boleh desimal', required: false, aliases: ['allow_decimal', 'boleh_desimal'] },
      { key: 'decimalPrecision', label: 'Presisi desimal', required: false, aliases: ['decimal_precision', 'presisi_desimal'] },
      { key: 'isActive', label: 'Status aktif', required: false, aliases: ['is_active', 'aktif', 'status_aktif'] },
    ],
    templateHeaders: ['name', 'uom_type', 'allow_decimal', 'decimal_precision', 'is_active'],
    exportHeaders: ['internal_id', 'name', 'uom_type', 'allow_decimal', 'decimal_precision', 'is_active'],
  },
  WAREHOUSE: {
    label: 'Gudang',
    description: 'Nama, tipe, lokasi, toko terkait, dan fungsi operasional gudang.',
    fields: [
      { key: 'internalId', label: 'ID internal (opsional)', required: false, aliases: ['internal_id', 'id'] },
      { key: 'code', label: 'Kode sistem', required: false, hidden: true, aliases: ['code', 'kode', 'warehouse_code', 'kode_gudang', 'system_code'] },
      { key: 'name', label: 'Nama gudang', required: true, aliases: ['name', 'nama', 'warehouse_name', 'nama_gudang'] },
      { key: 'warehouseType', label: 'Tipe gudang', required: true, aliases: ['warehouse_type', 'tipe_gudang', 'type'] },
      { key: 'storeReference', label: 'Nama atau kode Toko', required: false, aliases: ['store_name', 'nama_toko', 'store_code', 'kode_toko', 'store'] },
      { key: 'location', label: 'Catatan lokasi', required: false, aliases: ['location', 'lokasi'] },
      { key: 'isSaleSource', label: 'Sumber penjualan', required: false, aliases: ['is_sale_source', 'sumber_penjualan'] },
      { key: 'isPurchaseDestination', label: 'Tujuan pembelian', required: false, aliases: ['is_purchase_destination', 'tujuan_pembelian'] },
      { key: 'isActive', label: 'Status aktif', required: false, aliases: ['is_active', 'aktif', 'status_aktif'] },
    ],
    templateHeaders: ['name', 'warehouse_type', 'store_name', 'location', 'is_sale_source', 'is_purchase_destination', 'is_active'],
    exportHeaders: ['internal_id', 'name', 'warehouse_type', 'store_name', 'location', 'is_sale_source', 'is_purchase_destination', 'is_active'],
  },
  SUPPLIER: {
    label: 'Supplier',
    description: 'Nama, kontak, termin, dan rekening Supplier. Kode dibuat otomatis.',
    fields: [
      { key: 'internalId', label: 'ID internal (opsional)', required: false, aliases: ['internal_id', 'id'] },
      { key: 'code', label: 'Kode sistem', required: false, hidden: true, aliases: ['code', 'kode', 'supplier_code', 'kode_supplier', 'system_code'] },
      { key: 'name', label: 'Nama Supplier', required: true, aliases: ['name', 'nama', 'supplier_name', 'nama_supplier'] },
      { key: 'contactName', label: 'Nama kontak', required: false, aliases: ['contact_name', 'nama_kontak'] },
      { key: 'phone', label: 'Telepon', required: false, aliases: ['phone', 'telepon', 'no_telepon'] },
      { key: 'address', label: 'Alamat', required: false, aliases: ['address', 'alamat'] },
      { key: 'npwp', label: 'NPWP', required: false, aliases: ['npwp'] },
      { key: 'paymentTerm', label: 'Termin pembayaran', required: false, aliases: ['payment_term', 'termin_pembayaran'] },
      { key: 'bankName', label: 'Nama bank', required: false, aliases: ['bank_name', 'nama_bank'] },
      { key: 'bankAccountNumber', label: 'Nomor rekening', required: false, aliases: ['bank_account_number', 'nomor_rekening'] },
      { key: 'bankAccountHolder', label: 'Nama pemilik rekening', required: false, aliases: ['bank_account_holder', 'pemilik_rekening'] },
      { key: 'isActive', label: 'Status aktif', required: false, aliases: ['is_active', 'aktif', 'status_aktif'] },
    ],
    templateHeaders: ['name', 'contact_name', 'phone', 'address', 'npwp', 'payment_term', 'bank_name', 'bank_account_number', 'bank_account_holder', 'is_active'],
    exportHeaders: ['internal_id', 'name', 'contact_name', 'phone', 'address', 'npwp', 'payment_term', 'bank_name', 'bank_account_number', 'bank_account_holder', 'is_active'],
  },
  CUSTOMER_CATEGORY: {
    label: 'Kategori Pelanggan',
    description: 'Nama grouping pelanggan dan status aktifnya. Kode dibuat otomatis. Kategori bawaan sistem hanya dapat diekspor.',
    fields: [
      { key: 'internalId', label: 'ID internal (opsional)', required: false, aliases: ['internal_id', 'id'] },
      { key: 'name', label: 'Nama kategori pelanggan', required: true, aliases: ['name', 'nama', 'category_name', 'nama_kategori'] },
      { key: 'isActive', label: 'Status aktif', required: false, aliases: ['is_active', 'aktif', 'status_aktif'] },
    ],
    templateHeaders: ['name', 'is_active'],
    exportHeaders: ['internal_id', 'name', 'is_active'],
  },
  CHART_OF_ACCOUNT: {
    label: 'Chart of Account',
    description: 'Daftar akun Finance. Kode akun adalah identitas bisnis; akun bawaan sistem hanya dapat diekspor. Buat akun induk lebih dahulu atau letakkan pada baris sebelumnya.',
    fields: [
      { key: 'internalId', label: 'ID internal (opsional)', required: false, aliases: ['internal_id', 'id'] },
      { key: 'code', label: 'Kode akun', required: true, aliases: ['code', 'kode', 'account_code', 'kode_akun'] },
      { key: 'name', label: 'Nama akun', required: true, aliases: ['name', 'nama', 'account_name', 'nama_akun'] },
      { key: 'accountType', label: 'Tipe akun', required: true, aliases: ['account_type', 'tipe_akun'] },
      { key: 'normalBalance', label: 'Saldo normal', required: true, aliases: ['normal_balance', 'saldo_normal'] },
      { key: 'parentAccountCode', label: 'Kode akun induk', required: false, aliases: ['parent_account_code', 'kode_akun_induk', 'parent_code'] },
      { key: 'systemFunctionKey', label: 'Fungsi akun sistem', required: false, aliases: ['system_function_key', 'fungsi_akun_sistem', 'account_function'] },
      { key: 'isPostable', label: 'Dapat diposting', required: false, aliases: ['is_postable', 'dapat_diposting'] },
      { key: 'allowManualPosting', label: 'Boleh jurnal manual', required: false, aliases: ['allow_manual_posting', 'boleh_jurnal_manual'] },
      { key: 'allowReconciliation', label: 'Boleh rekonsiliasi', required: false, aliases: ['allow_reconciliation', 'boleh_rekonsiliasi'] },
      { key: 'isActive', label: 'Status aktif', required: false, aliases: ['is_active', 'aktif', 'status_aktif'] },
    ],
    templateHeaders: ['code', 'name', 'account_type', 'normal_balance', 'parent_account_code', 'system_function_key', 'is_postable', 'allow_manual_posting', 'allow_reconciliation', 'is_active'],
    exportHeaders: ['internal_id', 'code', 'name', 'account_type', 'normal_balance', 'parent_account_code', 'system_function_key', 'is_postable', 'allow_manual_posting', 'allow_reconciliation', 'is_active'],
  },
  TRANSACTION_CATEGORY: {
    label: 'Kategori Transaksi',
    description: 'Nama transaksi, System Event yang memicunya, deskripsi, dan status aktif. Kode dibuat otomatis; 26 kategori wajib bawaan sistem hanya dapat diekspor.',
    fields: [
      { key: 'internalId', label: 'ID internal (opsional)', required: false, aliases: ['internal_id', 'id'] },
      { key: 'name', label: 'Nama kategori transaksi', required: true, aliases: ['name', 'nama', 'category_name', 'nama_kategori'] },
      { key: 'systemKey', label: 'System Event', required: true, aliases: ['system_key', 'system_event', 'event_key', 'kunci_system_event'] },
      { key: 'description', label: 'Deskripsi', required: false, aliases: ['description', 'deskripsi'] },
      { key: 'isActive', label: 'Status aktif', required: false, aliases: ['is_active', 'aktif', 'status_aktif'] },
    ],
    templateHeaders: ['name', 'system_key', 'description', 'is_active'],
    exportHeaders: ['internal_id', 'name', 'system_key', 'description', 'is_active'],
  },
}

export function isImportType(value: unknown): value is MasterImportType {
  return typeof value === 'string' && value in importDefinitions
}

export function isReferenceMode(value: unknown): value is ImportReferenceMode {
  return value === 'REFERENCE_BY_ID' || value === 'REFERENCE_BY_NAME'
}

export function isOperationMode(value: unknown): value is ImportOperationMode {
  return value === 'CREATE_ONLY' || value === 'UPDATE_ONLY' || value === 'CREATE_AND_UPDATE'
}

export function isUuid(value: unknown): value is string {
  return typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
}

export function csvCell(value: unknown): string {
  const text = value === null || value === undefined ? '' : String(value)
  return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text
}

export function csvDocument(headers: string[], rows: Record<string, unknown>[]): string {
  const lines = [headers.map(csvCell).join(',')]
  for (const row of rows) lines.push(headers.map((header) => csvCell(row[header])).join(','))
  return `\uFEFF${lines.join('\r\n')}\r\n`
}
