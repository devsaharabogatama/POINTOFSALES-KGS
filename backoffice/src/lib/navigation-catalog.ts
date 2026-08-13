export type NavigationViewId =
  | 'data-exchange'
  | 'masters'
  | 'products'
  | 'bundles'
  | 'sales-returns'
  | 'sales-documents'
  | 'delivery-documents'
  | 'expense-approvals'
  | 'cash-deposits'
  | 'deposit-variances'
  | 'customer-balances'
  | 'supplier-invoices'
  | 'supplier-payments'
  | 'stock-real'
  | 'stock-movements'
  | 'stock-transfers'
  | 'stock-adjustments'
  | 'stock-opnames'
  | 'opening-stock'
  | 'minimum-stock'
  | 'suppliers'
  | 'supplier-orders'
  | 'purchase-returns'
  | 'customers'
  | 'pricelists'
  | 'payment-methods'
  | 'finance-masters'
  | 'tax-rules'
  | 'finance'
  | 'staff'
  | 'companies'
  | 'company-branding'
  | 'module-settings'

export type NavigationIconKey =
  | 'arrow-right-left'
  | 'badge-percent'
  | 'banknote'
  | 'banknote-arrow-up'
  | 'bell-ring'
  | 'boxes'
  | 'building'
  | 'circle-alert'
  | 'clipboard-check'
  | 'clipboard-pen'
  | 'contact'
  | 'credit-card'
  | 'dollar'
  | 'file-spreadsheet'
  | 'landmark'
  | 'image'
  | 'package-minus'
  | 'package-plus'
  | 'package-search'
  | 'receipt'
  | 'rotate'
  | 'scroll'
  | 'settings'
  | 'shopping-cart'
  | 'tags'
  | 'truck'
  | 'users'
  | 'wallet'

export type NavigationCatalogItem = {
  id: NavigationViewId
  label: string
  description: string
  iconKey: NavigationIconKey
  capabilities: string[]
}

export type NavigationCatalogModule = {
  id: string
  name: string
  description: string
  iconKey: NavigationIconKey
  color: string
  items: NavigationCatalogItem[]
}

type ItemDefinition = NavigationCatalogItem & {
  roles?: string[]
  superOnly?: boolean
  requiredAnyFeature?: string[]
}

type ModuleDefinition = Omit<NavigationCatalogModule, 'items'> & {
  views: NavigationViewId[]
}

export const INVENTORY_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER', 'WAREHOUSE_ADMIN']
export const STOCK_REAL_ROLES = [...INVENTORY_ROLES, 'FINANCE', 'ACCOUNTING']
export const STOCK_TRANSFER_OPERATOR_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'WAREHOUSE_ADMIN']
export const STOCK_ADJUSTMENT_OPERATOR_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER']
export const OPENING_STOCK_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER', 'FINANCE', 'ACCOUNTING']
export const SUPPLIER_ROLES = [...INVENTORY_ROLES, 'FINANCE', 'ACCOUNTING']
export const PURCHASE_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER']
export const SALES_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER', 'FINANCE', 'ACCOUNTING']
export const SALES_RETURN_APPROVER_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER']
export const EXPENSE_REVIEW_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER', 'FINANCE', 'ACCOUNTING']
export const EXPENSE_APPROVER_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER', 'FINANCE']
export const FINANCE_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'FINANCE', 'ACCOUNTING']
export const CASH_DEPOSIT_APPROVER_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'FINANCE']
export const OWNER_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN']
export const DATA_EXCHANGE_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER', 'WAREHOUSE_ADMIN', 'FINANCE', 'ACCOUNTING']

const itemDefinitions: ItemDefinition[] = [
  { id: 'data-exchange', label: 'Data Exchange', description: 'Export dan import global sesuai akses Anda.', iconKey: 'file-spreadsheet', roles: DATA_EXCHANGE_ROLES, capabilities: ['VIEW'] },
  { id: 'masters', label: 'Master Inventory', description: 'Kategori produk, UOM, gudang, toko, dan terminal.', iconKey: 'truck', roles: INVENTORY_ROLES, capabilities: ['VIEW'] },
  { id: 'products', label: 'Produk & UOM', description: 'Produk, satuan dasar, konversi, dan harga per UOM.', iconKey: 'boxes', roles: INVENTORY_ROLES, capabilities: ['VIEW'] },
  { id: 'stock-real', label: 'Stock Real', description: 'Saldo stok aktual per produk dan gudang.', iconKey: 'package-search', roles: STOCK_REAL_ROLES, capabilities: ['VIEW'] },
  { id: 'stock-movements', label: 'Kartu Stok', description: 'Riwayat mutasi stok yang dapat ditelusuri.', iconKey: 'scroll', roles: STOCK_REAL_ROLES, capabilities: ['VIEW'] },
  { id: 'stock-transfers', label: 'Transfer Stok', description: 'Pemindahan stok antar gudang.', iconKey: 'arrow-right-left', roles: STOCK_REAL_ROLES, capabilities: ['VIEW'] },
  { id: 'stock-adjustments', label: 'Penyesuaian Stok', description: 'Koreksi stok dengan alasan dan audit.', iconKey: 'clipboard-pen', roles: STOCK_REAL_ROLES, capabilities: ['VIEW'] },
  { id: 'stock-opnames', label: 'Stock Opname', description: 'Hitung fisik, review selisih, dan posting.', iconKey: 'clipboard-check', roles: STOCK_REAL_ROLES, capabilities: ['VIEW'] },
  { id: 'opening-stock', label: 'Stok Awal', description: 'Dokumen saldo awal stok yang terkontrol.', iconKey: 'package-plus', roles: OPENING_STOCK_ROLES, capabilities: ['VIEW'] },
  { id: 'minimum-stock', label: 'Minimum Stock', description: 'Atur batas minimum per produk dan gudang.', iconKey: 'bell-ring', roles: INVENTORY_ROLES, capabilities: ['VIEW'] },
  { id: 'customers', label: 'Pelanggan', description: 'Customer utama, cabang, kategori, dan pricelist.', iconKey: 'contact', roles: SALES_ROLES, capabilities: ['VIEW'] },
  { id: 'suppliers', label: 'Supplier', description: 'Identitas supplier dan relasi produk pembelian.', iconKey: 'package-search', roles: SUPPLIER_ROLES, capabilities: ['VIEW'] },
  { id: 'supplier-orders', label: 'Supplier Order', description: 'Permintaan stok dan pesanan ke supplier.', iconKey: 'shopping-cart', roles: PURCHASE_ROLES, capabilities: ['VIEW'] },
  { id: 'purchase-returns', label: 'Retur Pembelian', description: 'Review dan posting retur ke supplier.', iconKey: 'package-minus', roles: PURCHASE_ROLES, capabilities: ['VIEW'] },
  { id: 'staff', label: 'User & Akses', description: 'Anggota Company, role, dan assignment toko.', iconKey: 'users', roles: OWNER_ROLES, capabilities: ['VIEW'] },
  { id: 'pricelists', label: 'Pricelist', description: 'Harga jual final per kelompok dan periode.', iconKey: 'tags', roles: SALES_ROLES, capabilities: ['VIEW'] },
  { id: 'bundles', label: 'Bundle', description: 'Paket penjualan dan komponen stoknya.', iconKey: 'boxes', roles: SALES_ROLES, capabilities: ['VIEW'] },
  { id: 'sales-returns', label: 'Approval Return', description: 'Review dan posting retur penjualan.', iconKey: 'rotate', roles: SALES_RETURN_APPROVER_ROLES, capabilities: ['VIEW'] },
  { id: 'sales-documents', label: 'Invoice Penjualan', description: 'Dokumen final Invoice dan cetak ulang.', iconKey: 'receipt', roles: SALES_ROLES, capabilities: ['VIEW'] },
  { id: 'delivery-documents', label: 'Surat Jalan', description: 'Persiapan, cetak, dan status pengiriman barang.', iconKey: 'truck', roles: INVENTORY_ROLES, capabilities: ['VIEW'] },
  { id: 'expense-approvals', label: 'Expense', description: 'Pengajuan, approval, pencairan, dan settlement.', iconKey: 'dollar', roles: EXPENSE_REVIEW_ROLES, requiredAnyFeature: ['expense_enabled'], capabilities: ['VIEW'] },
  { id: 'cash-deposits', label: 'Setor Kas', description: 'Setoran kasir dan review setoran.', iconKey: 'banknote-arrow-up', roles: FINANCE_ROLES, capabilities: ['VIEW'] },
  { id: 'deposit-variances', label: 'Selisih Setoran', description: 'Investigasi dan resolusi selisih.', iconKey: 'circle-alert', roles: FINANCE_ROLES, capabilities: ['VIEW'] },
  { id: 'customer-balances', label: 'Saldo Customer', description: 'Ledger saldo dan koreksi terkontrol.', iconKey: 'wallet', roles: FINANCE_ROLES, requiredAnyFeature: ['customer_balance_enabled'], capabilities: ['VIEW'] },
  { id: 'supplier-invoices', label: 'Faktur Supplier', description: 'Matching penerimaan dan tagihan supplier.', iconKey: 'receipt', roles: FINANCE_ROLES, capabilities: ['VIEW'] },
  { id: 'supplier-payments', label: 'Pembayaran Supplier', description: 'Validasi dan pencatatan pembayaran supplier.', iconKey: 'banknote', roles: FINANCE_ROLES, capabilities: ['VIEW'] },
  { id: 'payment-methods', label: 'Metode Pembayaran', description: 'Metode bayar, assignment toko, dan fee.', iconKey: 'credit-card', roles: FINANCE_ROLES, capabilities: ['VIEW'] },
  { id: 'tax-rules', label: 'Aturan Pajak', description: 'Rule pajak Sales/Purchase dan assignment.', iconKey: 'badge-percent', roles: FINANCE_ROLES, requiredAnyFeature: ['tax_sales_enabled', 'tax_purchase_enabled'], capabilities: ['VIEW'] },
  { id: 'finance-masters', label: 'Kategori & COA', description: 'Kategori transaksi, COA, dan mapping akun.', iconKey: 'landmark', roles: FINANCE_ROLES, capabilities: ['VIEW'] },
  { id: 'finance', label: 'Jurnal Keuangan', description: 'Journal Entries, ledger, periode, dan laporan.', iconKey: 'dollar', roles: FINANCE_ROLES, capabilities: ['VIEW'] },
  { id: 'companies', label: 'Perusahaan', description: 'Kelola tenant aktif pada platform.', iconKey: 'building', superOnly: true, capabilities: ['VIEW'] },
  { id: 'company-branding', label: 'Logo Perusahaan', description: 'Logo dokumen resmi untuk Company aktif.', iconKey: 'image', roles: OWNER_ROLES, capabilities: ['VIEW', 'MANAGE'] },
  { id: 'module-settings', label: 'Pengaturan Modul', description: 'Entitlement dan kebijakan modul Company.', iconKey: 'settings', roles: ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER'], capabilities: ['VIEW'] },
]

const moduleDefinitions: ModuleDefinition[] = [
  { id: 'inventory', name: 'Inventory', description: 'Produk, gudang, saldo aktual, mutasi, transfer, opname, Surat Jalan, dan konfigurasi stok.', iconKey: 'boxes', color: 'bg-blue-600', views: ['stock-real', 'stock-movements', 'stock-transfers', 'stock-adjustments', 'stock-opnames', 'delivery-documents', 'products', 'opening-stock', 'minimum-stock', 'masters'] },
  { id: 'contacts', name: 'Kontak', description: 'Pelanggan, supplier, dan user Company.', iconKey: 'contact', color: 'bg-cyan-600', views: ['customers', 'suppliers', 'staff'] },
  { id: 'purchase', name: 'Purchase', description: 'Pesanan supplier dan retur pembelian.', iconKey: 'shopping-cart', color: 'bg-amber-600', views: ['supplier-orders', 'purchase-returns'] },
  { id: 'sales', name: 'Sales', description: 'Invoice, pricelist, bundle, dan retur penjualan.', iconKey: 'tags', color: 'bg-emerald-600', views: ['sales-documents', 'pricelists', 'bundles', 'sales-returns'] },
  { id: 'finance', name: 'Finance', description: 'Kas, expense, supplier AP, pajak, COA, jurnal, dan laporan.', iconKey: 'landmark', color: 'bg-violet-600', views: ['expense-approvals', 'cash-deposits', 'deposit-variances', 'customer-balances', 'supplier-invoices', 'supplier-payments', 'payment-methods', 'tax-rules', 'finance-masters', 'finance'] },
  { id: 'platform', name: 'Platform', description: 'Company, branding, dan pengaturan entitlement modul.', iconKey: 'settings', color: 'bg-slate-800', views: ['companies', 'company-branding', 'module-settings'] },
  { id: 'data', name: 'Data Exchange', description: 'Export dan import global sesuai akses aktif.', iconKey: 'file-spreadsheet', color: 'bg-teal-700', views: ['data-exchange'] },
]

export function buildNavigationCatalog(input: {
  isSuperAdmin: boolean
  roleCode: string
  enabledFeatures: ReadonlySet<string>
  effectiveCapabilities?: Partial<Record<NavigationViewId, string[]>>
}): NavigationCatalogModule[] {
  const visibleItems = new Map(
    itemDefinitions
      .filter((item) => (!item.superOnly || input.isSuperAdmin))
      .filter((item) => !item.roles || input.isSuperAdmin || item.roles.includes(input.roleCode))
      .filter((item) => !item.requiredAnyFeature || input.isSuperAdmin ||
        item.requiredAnyFeature.some((feature) => input.enabledFeatures.has(feature)))
      .filter((item) => input.effectiveCapabilities?.[item.id] === undefined ||
        input.effectiveCapabilities[item.id]!.includes('VIEW'))
      .map((item) => [item.id, {
        id: item.id,
        label: item.label,
        description: item.description,
        iconKey: item.iconKey,
        capabilities: input.effectiveCapabilities?.[item.id] ?? item.capabilities,
      }]),
  )

  return moduleDefinitions
    .map(({ views, ...module }) => ({
      ...module,
      items: views.map((view) => visibleItems.get(view)).filter(Boolean) as NavigationCatalogItem[],
    }))
    .filter((module) => module.items.length > 0)
}
