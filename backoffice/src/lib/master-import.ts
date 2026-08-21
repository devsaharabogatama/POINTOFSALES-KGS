export type MasterImportType =
  | 'PRODUCT_CATEGORY'
  | 'UOM'
  | 'WAREHOUSE'
  | 'SUPPLIER'
  | 'CUSTOMER'
  | 'CUSTOMER_CATEGORY'
  | 'CHART_OF_ACCOUNT'
  | 'TRANSACTION_CATEGORY'
  | 'PRODUCT'
  | 'PRODUCT_UOM'
  | 'PRODUCT_SUPPLIER'
  | 'PRODUCT_WAREHOUSE_MINIMUM_STOCK'
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
  CUSTOMER: {
    label: 'Customer',
    description: 'Master Customer Company aktif. Walk-In, saldo berjalan, dan histori transaksi tidak dapat diimpor.',
    fields: [
      { key: 'internalId', label: 'ID internal (opsional)', required: false, aliases: ['internal_id', 'customer_id', 'id'] },
      { key: 'customerCode', label: 'Kode Customer (opsional saat membuat)', required: false, aliases: ['code', 'customer_code', 'kode_customer', 'kode_pelanggan'] },
      { key: 'customerName', label: 'Nama Customer', required: true, aliases: ['name', 'customer_name', 'nama_customer', 'nama_pelanggan'] },
      { key: 'categoryName', label: 'Kategori Customer', required: true, aliases: ['customer_category_name', 'category_name', 'kategori_customer', 'kategori_pelanggan'] },
      { key: 'parentCustomerName', label: 'Customer induk existing', required: false, aliases: ['parent_customer_name', 'nama_customer_induk', 'customer_induk'] },
      { key: 'defaultPricelistName', label: 'Pricelist default existing', required: false, aliases: ['default_pricelist_name', 'pricelist_name', 'nama_pricelist'] },
      { key: 'phone', label: 'Telepon', required: false, aliases: ['phone', 'telepon', 'no_telepon'] },
      { key: 'email', label: 'Email', required: false, aliases: ['email'] },
      { key: 'address', label: 'Alamat', required: false, aliases: ['address', 'alamat'] },
      { key: 'customerType', label: 'Tipe Customer', required: false, aliases: ['customer_type', 'tipe_customer', 'tipe_pelanggan'] },
      { key: 'creditLimit', label: 'Limit kredit', required: false, aliases: ['credit_limit', 'limit_kredit'] },
      { key: 'creditTermDays', label: 'Termin kredit (hari)', required: false, aliases: ['credit_term_days', 'termin_kredit_hari', 'termin_hari'] },
      { key: 'notes', label: 'Catatan', required: false, aliases: ['notes', 'catatan'] },
      { key: 'isActive', label: 'Status aktif', required: false, aliases: ['is_active', 'aktif', 'status_aktif'] },
    ],
    templateHeaders: [
      'code', 'name', 'customer_category_name', 'parent_customer_name',
      'default_pricelist_name', 'phone', 'email', 'address', 'customer_type',
      'credit_limit', 'credit_term_days', 'notes', 'is_active',
    ],
    exportHeaders: [
      'internal_id', 'code', 'name', 'customer_category_name',
      'parent_customer_name', 'default_pricelist_name', 'phone', 'email',
      'address', 'customer_type', 'credit_limit', 'credit_term_days', 'notes',
      'is_active',
    ],
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
  PRODUCT: {
    label: 'Produk + Satuan',
    description: 'Satu product_key adalah satu Produk. Isi satu baris untuk setiap satuan jual/beli. Import ini tidak mengisi stok atau Saldo Awal.',
    fields: [
      { key: 'internalId', label: 'ID internal Product (opsional)', required: false, aliases: ['internal_id', 'product_id', 'id'] },
      { key: 'productKey', label: 'Kunci grup Product', required: true, aliases: ['product_key', 'kunci_produk', 'group_key'] },
      { key: 'sku', label: 'SKU Product', required: true, aliases: ['sku', 'product_sku', 'kode_produk'] },
      { key: 'productName', label: 'Nama Product', required: true, aliases: ['product_name', 'nama_produk', 'name'] },
      { key: 'categoryName', label: 'Nama kategori', required: true, aliases: ['category_name', 'nama_kategori', 'category'] },
      { key: 'imageUrl', label: 'URL gambar eksternal', required: false, aliases: ['image_url', 'url_gambar'] },
      { key: 'isActive', label: 'Product aktif', required: false, aliases: ['is_active', 'aktif', 'status_aktif'] },
      { key: 'uomName', label: 'Nama satuan (UOM)', required: true, aliases: ['uom_name', 'nama_uom', 'nama_satuan', 'satuan'] },
      { key: 'factorToBase', label: 'Isi satuan dalam UOM dasar', required: true, aliases: ['factor_to_base', 'faktor_ke_base', 'qty_base'] },
      { key: 'purchaseAllowed', label: 'Dapat dipakai untuk pembelian', required: true, aliases: ['purchase_allowed', 'boleh_beli', 'beli'] },
      { key: 'salesAllowed', label: 'Dapat dipakai untuk penjualan', required: true, aliases: ['sales_allowed', 'boleh_jual', 'jual'] },
      { key: 'purchasePrice', label: 'Harga beli per UOM', required: true, aliases: ['purchase_price', 'harga_beli'] },
      { key: 'salePrice', label: 'Harga jual per UOM', required: true, aliases: ['sale_price', 'harga_jual'] },
      { key: 'barcode', label: 'Barcode UOM', required: false, aliases: ['barcode', 'kode_barcode'] },
      { key: 'salesTaxRuleName', label: 'Nama aturan pajak penjualan', required: false, aliases: ['sales_tax_rule_name', 'pajak_penjualan'] },
      { key: 'purchaseTaxRuleName', label: 'Nama aturan pajak pembelian', required: false, aliases: ['purchase_tax_rule_name', 'pajak_pembelian'] },
      { key: 'weightPerLargestUomKg', label: 'Berat UOM terbesar (kg)', required: true, aliases: ['weight_per_largest_uom_kg', 'berat_uom_terbesar_kg'] },
    ],
    templateHeaders: [
      'product_key', 'sku', 'product_name', 'category_name', 'image_url',
      'is_active', 'uom_name', 'factor_to_base', 'purchase_allowed',
      'sales_allowed', 'purchase_price', 'sale_price', 'barcode',
      'sales_tax_rule_name', 'purchase_tax_rule_name',
      'weight_per_largest_uom_kg',
    ],
    exportHeaders: [
      'internal_id', 'product_key', 'sku', 'product_name', 'category_name',
      'image_url', 'is_active', 'uom_name', 'factor_to_base',
      'purchase_allowed', 'sales_allowed', 'purchase_price', 'sale_price',
      'barcode', 'sales_tax_rule_name', 'purchase_tax_rule_name',
      'weight_per_largest_uom_kg',
    ],
  },
  PRODUCT_UOM: {
    label: 'Tambah / Perbarui UOM Produk',
    description: 'Template berisi satu baris kosong per Product existing. Isi hanya baris UOM yang ingin ditambahkan atau diperbarui; UOM lain tidak dihapus.',
    fields: [
      { key: 'productSku', label: 'SKU Product', required: true, aliases: ['product_sku', 'sku', 'kode_produk'] },
      { key: 'productName', label: 'Nama Product (referensi)', required: true, aliases: ['product_name', 'nama_produk'] },
      { key: 'uomName', label: 'Nama UOM', required: false, aliases: ['uom_name', 'nama_uom', 'nama_satuan', 'satuan'] },
      { key: 'factorToBase', label: 'Isi UOM dalam satuan dasar', required: false, aliases: ['factor_to_base', 'qty_uom', 'isi_uom'] },
      { key: 'purchaseAllowed', label: 'Dapat dipakai untuk pembelian', required: false, aliases: ['purchase_allowed', 'boleh_beli', 'beli'] },
      { key: 'salesAllowed', label: 'Dapat dipakai untuk penjualan', required: false, aliases: ['sales_allowed', 'boleh_jual', 'jual'] },
      { key: 'purchasePrice', label: 'Harga beli per UOM', required: false, aliases: ['purchase_price', 'harga_beli'] },
      { key: 'salePrice', label: 'Harga jual per UOM', required: false, aliases: ['sale_price', 'harga_jual'] },
      { key: 'barcode', label: 'Barcode UOM', required: false, aliases: ['barcode', 'kode_barcode'] },
      { key: 'weightIfLargestKg', label: 'Berat bila menjadi UOM terbesar (kg)', required: false, aliases: ['weight_if_largest_kg', 'berat_jika_terbesar_kg'] },
    ],
    templateHeaders: [
      'row_mode', 'product_sku', 'product_name', 'uom_name', 'factor_to_base',
      'purchase_allowed', 'sales_allowed', 'purchase_price', 'sale_price',
      'barcode', 'weight_if_largest_kg',
    ],
    exportHeaders: [
      'row_mode', 'product_sku', 'product_name', 'uom_name', 'factor_to_base',
      'purchase_allowed', 'sales_allowed', 'purchase_price', 'sale_price',
      'barcode', 'weight_if_largest_kg',
    ],
  },
  PRODUCT_SUPPLIER: {
    label: 'Relasi Produk–Supplier',
    description: 'Hubungkan Product existing ke Supplier dan satuan pembelian existing. Import ini tidak membuat Product, Supplier, UOM, transaksi pembelian, atau stok.',
    fields: [
      { key: 'internalId', label: 'ID internal relasi (opsional)', required: false, aliases: ['internal_id', 'product_supplier_id', 'id'] },
      { key: 'productSku', label: 'SKU Product', required: true, aliases: ['product_sku', 'sku', 'kode_produk'] },
      { key: 'supplierName', label: 'Nama Supplier', required: true, aliases: ['supplier_name', 'nama_supplier', 'supplier'] },
      { key: 'purchaseUomName', label: 'Nama UOM pembelian', required: true, aliases: ['purchase_uom_name', 'nama_uom_pembelian', 'uom_name', 'nama_satuan'] },
      { key: 'supplierProductCode', label: 'Kode Product dari Supplier (boleh kosong)', required: true, aliases: ['supplier_product_code', 'kode_produk_supplier'] },
      { key: 'referencePurchasePrice', label: 'Harga beli referensi (boleh kosong)', required: true, aliases: ['reference_purchase_price', 'harga_beli_referensi'] },
      { key: 'isPreferredSupplier', label: 'Supplier utama', required: true, aliases: ['is_preferred_supplier', 'supplier_utama', 'preferred'] },
      { key: 'isActive', label: 'Relasi aktif', required: true, aliases: ['is_active', 'aktif', 'status_aktif'] },
    ],
    templateHeaders: [
      'product_sku', 'supplier_name', 'purchase_uom_name',
      'supplier_product_code', 'reference_purchase_price',
      'is_preferred_supplier', 'is_active',
    ],
    exportHeaders: [
      'internal_id', 'product_sku', 'supplier_name', 'purchase_uom_name',
      'supplier_product_code', 'reference_purchase_price',
      'is_preferred_supplier', 'is_active',
    ],
  },
  PRODUCT_WAREHOUSE_MINIMUM_STOCK: {
    label: 'Minimum Stock Produk–Gudang',
    description: 'Atur batas stok menipis dalam Base UOM untuk pasangan Product dan Gudang existing. Import ini tidak membuat saldo, movement, Stock Request, atau Supplier Order.',
    fields: [
      { key: 'internalId', label: 'ID internal pengaturan (opsional)', required: false, aliases: ['internal_id', 'setting_id', 'id'] },
      { key: 'productSku', label: 'SKU Product', required: true, aliases: ['product_sku', 'sku', 'kode_produk'] },
      { key: 'warehouseName', label: 'Nama Gudang', required: true, aliases: ['warehouse_name', 'nama_gudang', 'warehouse'] },
      { key: 'minimumStockBaseQty', label: 'Minimum Stock dalam Base UOM', required: true, aliases: ['minimum_stock_base_qty', 'minimum_stock', 'stok_minimum'] },
      { key: 'lowStockAlertEnabled', label: 'Notifikasi stok menipis aktif', required: true, aliases: ['low_stock_alert_enabled', 'notifikasi_stok_menipis', 'alert_enabled'] },
    ],
    templateHeaders: [
      'product_sku', 'warehouse_name', 'minimum_stock_base_qty',
      'low_stock_alert_enabled',
    ],
    exportHeaders: [
      'internal_id', 'product_sku', 'warehouse_name',
      'minimum_stock_base_qty', 'low_stock_alert_enabled',
    ],
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
