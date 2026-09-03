import {
  Suspense,
  lazy,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  AlertTriangle,
  Banknote,
  BanknoteArrowUp,
  CheckCircle2,
  ChevronDown,
  Clock3,
  Database,
  FileText,
  LockKeyhole,
  LogIn,
  LogOut,
  Minus,
  Package,
  PackageMinus,
  Pencil,
  Plus,
  Printer,
  RefreshCw,
  RotateCcw,
  Search,
  ShoppingCart,
  ClipboardList,
  ClipboardCheck,
  Trash2,
  Truck,
  UserRound,
  UserPlus,
  Wifi,
  WifiOff,
  X,
} from 'lucide-react'
import { printer } from './lib/printer'
import { supabase, supabaseConfigurationError } from './lib/supabase'
import type {
  OfflineAllowanceAvailability,
  OfflineCatalogReadResult,
} from './lib/offlineCatalog'
import type { OfflineSaleQueueRecord } from './lib/db'
import {
  buildOfflineSalePayload,
  priceOfflineCheckout,
  type OfflineCheckoutPreview,
} from './lib/offlineCheckout'
import './App.css'
import { CurrencyInput } from './CurrencyInput'
import {
  acquireSaleDraftLock,
  cancelSaleDraft,
  closeCashierSession,
  confirmSalesOrder,
  getCurrentSession,
  heartbeatSaleDraftLock,
  listSaleDrafts,
  loadSalesOrders,
  loadBootstrap,
  loadCatalog,
  loadCompanies,
  loadReceipt,
  loadSalesDeliveryDocument,
  loadSalesInvoiceDocument,
  loadResolvedSaleLines,
  openCashierSession,
  previewPosSalePrices,
  quickCreatePosCustomer,
  recordSalesDocumentPrint,
  releaseSaleDraftLock,
  saveSaleDraft,
  setActiveCompany,
  signIn,
  signOut,
  startSalesOrderRevision,
  type BootstrapData,
  type CashierSession,
  type CatalogData,
  type CompanyOption,
  type ProductOption,
  type PosPricePreviewLine,
  type ResolvedSaleLine,
  type SaleDraft,
  type SaleDraftListItem,
  type SaleReceipt,
  type SalesOrderListItem,
  type SalesDeliveryDocument,
  type SalesInvoiceDocument,
} from './lib/pos'
import { SalesOrderPanel } from './SalesOrderPanel'
import {
  openSalesDeliveryPrint,
  openSalesInvoicePrint,
} from './lib/salesDocumentPrinter'

const ODR_OFFLINE_ORDER_ENABLED = false

const SalesReturnModal = lazy(() =>
  import('./SalesReturnModal').then((module) => ({
    default: module.SalesReturnModal,
  })),
)

const ExpenseRequestModal = lazy(() =>
  import('./ExpenseRequestModal').then((module) => ({
    default: module.ExpenseRequestModal,
  })),
)

const CashDepositModal = lazy(() =>
  import('./CashDepositModal').then((module) => ({
    default: module.CashDepositModal,
  })),
)

const StockRequestModal = lazy(() =>
  import('./StockRequestModal').then((module) => ({ default: module.StockRequestModal })),
)

const GoodsReceiptModal = lazy(() =>
  import('./GoodsReceiptModal').then((module) => ({ default: module.GoodsReceiptModal })),
)

const PurchaseReturnModal = lazy(() =>
  import('./PurchaseReturnModal').then((module) => ({ default: module.PurchaseReturnModal })),
)

const StockOpnameModal = lazy(() =>
  import('./StockOpnameModal').then((module) => ({ default: module.StockOpnameModal })),
)

type CartItem = {
  product: ProductOption
  quantity: number
  discountType: '' | 'AMOUNT' | 'PERCENT'
  discountInput: number
  overrideUnitPrice: number | null
}

type PaymentLeg = {
  clientPaymentKey: string
  paymentMethodId: string
  amount: string
  tenderedAmount: string
  proofUrl: string
  overpaymentDisposition: 'RETURNED' | 'CUSTOMER_BALANCE'
}

type ActionDialog = {
  title: string
  description: string
  confirmLabel: string
  tone: 'primary' | 'danger'
  requireReason?: boolean
  reasonLabel?: string
  reasonPlaceholder?: string
  onConfirm: (reason: string) => void | Promise<void>
}

type OfflineSlip = {
  clientTransactionId: string
  localTransactionAt: string
  preview: OfflineCheckoutPreview
  payments: Array<{
    methodName: string
    amount: number
    tenderedAmount: number
  }>
}

const EMPTY_CATALOG: CatalogData = {
  products: [],
  customers: [],
  pricelists: [],
  paymentMethods: [],
  expenseCategories: [],
  expenseEnabled: false,
  customerBalanceCreditEnabled: false,
  customerBalanceTenderEnabled: false,
}

function money(value: number) {
  return `Rp ${Math.round(value).toLocaleString('id-ID')}`
}

function localDateTimeInput(value: string) {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return ''
  const localTime = new Date(date.getTime() - date.getTimezoneOffset() * 60_000)
  return localTime.toISOString().slice(0, 16)
}

function isFutureLocalBusinessDate(value: string) {
  if (!value) return false
  return localDateTimeInput(value).slice(0, 10) >
    localDateTimeInput(new Date().toISOString()).slice(0, 10)
}

function suggestedTempoDueDate(transactionAt: string, termDays: number | null) {
  if (termDays === null) return ''
  const date = new Date(transactionAt)
  if (Number.isNaN(date.getTime())) return ''
  date.setDate(date.getDate() + termDays)
  return localDateTimeInput(date.toISOString())
}

function createPaymentLeg(paymentMethodId = ''): PaymentLeg {
  return {
    clientPaymentKey: crypto.randomUUID(),
    paymentMethodId,
    amount: '',
    tenderedAmount: '',
    proofUrl: '',
    overpaymentDisposition: 'RETURNED',
  }
}

function wheelDeltaPixels(event: WheelEvent) {
  if (event.deltaMode === WheelEvent.DOM_DELTA_LINE) return event.deltaY * 16
  if (event.deltaMode === WheelEvent.DOM_DELTA_PAGE) return event.deltaY * window.innerHeight
  return event.deltaY
}

function scrollNumberInputContainer(input: HTMLInputElement, delta: number) {
  let container = input.parentElement
  while (container) {
    const style = window.getComputedStyle(container)
    if (
      /(auto|scroll)/.test(style.overflowY) &&
      container.scrollHeight > container.clientHeight
    ) {
      container.scrollTop += delta
      return
    }
    container = container.parentElement
  }
  window.scrollBy({ top: delta, behavior: 'auto' })
}

function errorMessage(error: unknown) {
  if (error && typeof error === 'object' && 'message' in error) {
    const message = String(error.message)
    return message
  }
  return 'Terjadi kesalahan yang tidak dikenali.'
}

function isConnectionFailure(error: unknown) {
  const normalized = errorMessage(error).toLowerCase()
  return (
    normalized.includes('fetch') ||
    normalized.includes('network') ||
    normalized.includes('timeout') ||
    normalized.includes('failed to fetch')
  )
}

function friendlyError(code: string) {
  if (code.startsWith('CUSTOMER_BALANCE_EXCEEDS_SALE_TOTAL:')) {
    const shortfall = Number(code.split(':')[1] ?? 0)
    return `Saldo Customer melebihi total transaksi. Tambahkan belanja minimal ${money(shortfall)}.`
  }
  if (code.startsWith('FULL_CUSTOMER_BALANCE_USAGE_REQUIRED:')) {
    const balance = Number(code.split(':')[1] ?? 0)
    return `Seluruh Saldo Customer ${money(balance)} wajib digunakan pada transaksi ini.`
  }
  const labels: Record<string, string> = {
    ACTIVE_CASHIER_ASSIGNMENT_REQUIRED:
      'User ini belum memiliki assignment Cashier aktif pada Store.',
    ACTIVE_POS_TERMINAL_NOT_FOUND: 'Terminal POS tidak aktif atau tidak tersedia.',
    ACTIVE_SALES_WAREHOUSE_NOT_FOUND:
      'Gudang penjualan tidak aktif atau tidak sesuai Store.',
    CASHIER_SESSION_ALREADY_OPEN:
      'User sudah mempunyai sesi terbuka. Muat ulang untuk melanjutkannya.',
    OPEN_CASHIER_SESSION_REQUIRED: 'Buka sesi kasir sebelum membuat transaksi.',
    INVALID_CUSTOMER_NAME: 'Nama Customer wajib diisi dan maksimal 200 karakter.',
    INVALID_CUSTOMER_TYPE: 'Tipe Customer tidak dikenali.',
    INVALID_CUSTOMER_PHONE: 'Nomor telepon Customer maksimal 100 karakter.',
    INVALID_CUSTOMER_EMAIL: 'Email Customer tidak valid atau terlalu panjang.',
    INVALID_CUSTOMER_ADDRESS: 'Alamat Customer maksimal 1.000 karakter.',
    DELIVERY_RECIPIENT_REQUIRED:
      'Nama penerima wajib diisi untuk transaksi yang perlu dikirim.',
    INVALID_FULFILLMENT_MODE: 'Cara penerimaan barang tidak dikenali.',
    INVALID_DELIVERY_FEE_AMOUNT:
      'Ongkir harus berupa angka nol atau lebih besar.',
    ACTIVE_CUSTOMER_CATEGORY_NOT_FOUND:
      'Company aktif belum memiliki kategori Customer yang dapat dipakai.',
    DUPLICATE_CUSTOMER:
      'Nama atau identitas Customer tersebut sudah digunakan di Company aktif.',
    CUSTOMER_COMPANY_SCOPE_MISMATCH:
      'Company Customer tidak sesuai sesi aktif. Muat ulang sebelum mencoba lagi.',
    ACTIVE_SALES_PRODUCT_UOM_NOT_FOUND:
      'Produk atau satuan jual sudah tidak aktif. Muat ulang katalog.',
    PAYMENT_TOTAL_MISMATCH:
      'Nominal pembayaran harus sama dengan total akhir transaksi.',
    PAYMENT_PROOF_REQUIRED: 'Metode pembayaran ini mewajibkan URL bukti.',
    PAYMENT_PROOF_HTTPS_REQUIRED: 'URL bukti pembayaran harus menggunakan HTTPS.',
    MASTER_VERSION_CONFLICT:
      'Draft telah berubah pada proses lain. Muat ulang sebelum mencoba kembali.',
    DEFERRED_PAYMENT_METHOD_NOT_ENABLED:
      'Metode pembayaran ini belum dibuka pada fase POS sekarang.',
    TEMPO_SALE_CONTRACT_INVALID:
      'Penjualan tempo membutuhkan Customer reguler dan tanggal jatuh tempo.',
    TEMPO_TRANSACTION_DATE_REQUIRED:
      'Tanggal transaksi/order wajib diisi untuk penjualan tempo.',
    TEMPO_TRANSACTION_DATE_INVALID:
      'Format tanggal transaksi/order tidak valid.',
    TEMPO_TRANSACTION_DATE_FUTURE:
      'Tanggal order mendatang harus disimpan sebagai order TEMPO terjadwal.',
    SCHEDULED_ORDER_TEMPO_REQUIRED:
      'Order mendatang hanya dapat disimpan sebagai transaksi TEMPO.',
    SCHEDULED_ORDER_NOT_ACTIVE:
      'Order ini masih terjadwal dan baru dapat diposting pada tanggal rencana.',
    TEMPO_DUE_DATE_BEFORE_PLANNED_ORDER:
      'Tanggal jatuh tempo tidak boleh lebih awal dari tanggal rencana order.',
    DELIVERY_DATE_BEFORE_PLANNED_ORDER:
      'Tanggal rencana kirim tidak boleh lebih awal dari tanggal rencana order.',
    TEMPO_DUE_DATE_BEFORE_TRANSACTION:
      'Tanggal jatuh tempo tidak boleh lebih awal dari tanggal transaksi/order.',
    DELIVERY_DATE_BEFORE_TRANSACTION:
      'Tanggal rencana kirim tidak boleh lebih awal dari tanggal transaksi/order.',
    TEMPO_ACCOUNTING_PERIOD_NOT_OPEN:
      'Periode akuntansi untuk tanggal transaksi tersebut tidak terbuka.',
    PRICELIST_NOT_ELIGIBLE:
      'Pricelist tidak berlaku untuk Customer atau Store ini. Pilih Pricelist lain.',
    INVALID_PRICELIST_SELECTION:
      'Pilihan Pricelist tidak valid. Muat ulang data transaksi.',
    SALE_DRAFT_LOCKED: 'Draft sedang diedit kasir lain.',
    SALE_DRAFT_TAKEOVER_CONFIRMATION_REQUIRED:
      'Lock Draft sudah kedaluwarsa. Konfirmasi pengambilalihan diperlukan.',
    SALE_DRAFT_EDIT_LOCK_LOST:
      'Hak edit Draft telah berakhir. Buka kembali dari daftar Draft.',
    SALE_DRAFT_EDIT_LOCK_REQUIRED:
      'Draft belum dikunci untuk sesi kasir ini.',
    SALE_DRAFT_STORE_ACCESS_DENIED:
      'Draft berasal dari Store lain dan tidak dapat dibuka di sesi ini.',
    SALE_DRAFT_FORCE_RELEASE_FORBIDDEN:
      'Role ini tidak boleh melepas paksa lock Draft.',
    FORCE_RELEASE_REASON_REQUIRED:
      'Alasan wajib diisi untuk melepas paksa lock Draft.',
    DRAFT_PRODUCT_UOM_NOT_AVAILABLE:
      'Salah satu produk atau satuan pada Draft sudah tidak tersedia.',
    DRAFT_HAS_NO_LINES: 'Draft tidak memiliki item yang dapat dilanjutkan.',
    SALES_ORDER_REVISION_DRAFT_NOT_VISIBLE:
      'Draft revisi berhasil dibuat tetapi tidak dapat dibuka pada sesi ini. Muat ulang daftar Draft.',
    SALES_ORDER_REVISION_SOURCE_CHANGED:
      'Order sumber sudah berubah. Muat ulang Order dan periksa status terbaru.',
    SALES_ORDER_REVISION_DISPATCH_STARTED:
      'Pengiriman sudah dimulai. Gunakan Return atau dokumen koreksi yang sesuai.',
    SALES_ORDER_REVISION_VERIFIED_PAYMENT:
      'Pembayaran sudah diverifikasi. Revisi wajib melalui reversal Finance.',
    PAYMENT_LEGS_REQUIRED: 'Tambahkan minimal satu metode pembayaran.',
    PAYMENT_LEG_AMOUNT_REQUIRED:
      'Jumlah pada setiap cara bayar harus lebih besar dari nol.',
    PAYMENT_LEG_TOTAL_MISMATCH:
      'Total pembayaran harus sama dengan total akhir.',
    DUPLICATE_PAYMENT_METHOD:
      'Satu metode pembayaran hanya boleh dipilih satu kali.',
    DUPLICATE_PAYMENT_LEG_KEY:
      'Data pembayaran terduplikasi. Hapus lalu tambahkan kembali cara bayar.',
    PAYMENT_TENDER_INSUFFICIENT:
      'Uang tunai dari pelanggan kurang dari jumlah pembayaran tunai.',
    NEGATIVE_STOCK_REASON_REQUIRED:
      'Alasan stok minus wajib diisi sebelum transaksi dapat diposting.',
    COMPANY_NEGATIVE_STOCK_LIMIT_EXCEEDED:
      'Jumlah stok minus melampaui batas Company.',
    USER_NEGATIVE_STOCK_LIMIT_EXCEEDED:
      'Jumlah stok minus melampaui batas izin kasir.',
    NEGATIVE_STOCK_FEATURE_DISABLED:
      'Fitur stok minus belum diaktifkan untuk Company ini.',
    NEGATIVE_STOCK_POLICY_INACTIVE:
      'Policy stok minus Company belum aktif.',
    NEGATIVE_STOCK_WAREHOUSE_NOT_OPTED_IN:
      'Gudang penjualan sesi ini belum diizinkan memakai stok minus.',
    NEGATIVE_STOCK_USER_PERMISSION_REQUIRED:
      'Kasir ini belum memiliki izin stok minus aktif untuk gudang penjualan.',
    CUSTOMER_BALANCE_CREDIT_DISABLED:
      'Fitur Saldo Customer belum aktif untuk Company ini.',
    CUSTOMER_BALANCE_ELIGIBLE_CUSTOMER_REQUIRED:
      'Pilih Customer reguler untuk menyimpan kelebihan pembayaran sebagai saldo.',
    OVERPAYMENT_DISPOSITION_REQUIRED:
      'Pilih apakah kelebihan pembayaran dikembalikan atau disimpan sebagai saldo.',
    OFFLINE_CUSTOMER_BALANCE_CREDIT_NOT_ENABLED:
      'Simpan ke Saldo Customer hanya tersedia saat POS online.',
    CUSTOMER_BALANCE_DEBIT_DISABLED:
      'Pemakaian Saldo Customer belum aktif untuk Company ini.',
    CUSTOMER_BALANCE_NOT_AVAILABLE:
      'Customer ini tidak mempunyai saldo yang dapat digunakan.',
    CUSTOMER_BALANCE_CUSTOMER_NOT_FOUND:
      'Saldo Customer hanya dapat digunakan oleh Customer reguler aktif.',
    OFFLINE_POS_FEATURE_DISABLED:
      'Mode Offline belum diaktifkan oleh Super Admin untuk Company ini.',
    OFFLINE_TERMINAL_NOT_ENABLED:
      'Terminal ini belum dipilih sebagai Terminal Offline.',
    OFFLINE_COMPANY_POLICY_NOT_ENABLED:
      'Kebijakan cadangan Offline Company belum aktif.',
    OFFLINE_ALLOWANCE_PRODUCT_REQUIRED:
      'Pilih produk yang akan diberi cadangan stok.',
    OFFLINE_ALLOWANCE_STOCK_UNAVAILABLE:
      'Stok yang belum dicadangkan sudah tidak tersedia.',
    OFFLINE_ALLOWANCE_QUANTITY_UNAVAILABLE:
      'Jumlah cadangan tidak dapat dihitung dari stok yang tersedia.',
    OFFLINE_ALLOWANCE_RELEASE_FORBIDDEN:
      'Cadangan ini bukan milik sesi kasir aktif.',
    CONSUMED_OFFLINE_ALLOWANCE_CANNOT_RELEASE:
      'Cadangan yang sudah dipakai tidak dapat dilepaskan.',
    OFFLINE_QUEUE_RESOLUTION_REQUIRED:
      'Selesaikan antrean Offline sesi ini sebelum melepaskan cadangan.',
    OFFLINE_CATALOG_CACHE_INTEGRITY_INVALID:
      'Cache Offline tidak valid dan sudah diblokir. Perbarui snapshot saat online.',
    OFFLINE_CUSTOMER_NOT_IN_SNAPSHOT:
      'Customer tidak tersedia pada snapshot Offline. Sambungkan internet lalu perbarui snapshot.',
    OFFLINE_PRICELIST_NOT_ELIGIBLE:
      'Pricelist tidak tersedia untuk Customer pada snapshot Offline.',
    OFFLINE_PRODUCT_UOM_NOT_ELIGIBLE:
      'Salah satu produk tidak boleh dijual Offline. Hapus produk tersebut dari keranjang.',
    OFFLINE_ALLOWANCE_REQUIRED:
      'Produk belum mempunyai cadangan stok Offline untuk sesi ini.',
    OFFLINE_ALLOWANCE_INSUFFICIENT:
      'Cadangan stok Offline tidak cukup untuk jumlah di keranjang.',
    OFFLINE_PAYMENT_METHOD_NOT_ELIGIBLE:
      'Metode pembayaran tidak tersedia pada snapshot Offline.',
    OFFLINE_CATALOG_CACHE_MISSING:
      'Snapshot Offline belum tersedia atau sudah diblokir.',
    OFFLINE_LOCAL_IDEMPOTENCY_CONFLICT:
      'Identitas transaksi Offline sudah dipakai oleh payload berbeda.',
    OFFLINE_EXISTING_DRAFT_REQUIRES_ONLINE:
      'Draft server yang sedang terbuka harus diselesaikan saat online sebelum membuat transaksi Offline.',
    OFFLINE_TEMPO_NOT_ALLOWED:
      'Penjualan Tempo tidak tersedia dalam mode Offline.',
    OFFLINE_PRICE_OVERRIDE_NOT_ALLOWED:
      'Harga manual hanya tersedia saat POS Online. Kembalikan seluruh harga ke Pricelist sebelum menyimpan Offline.',
    POS_TERMINAL_PRICE_OVERRIDE_DISABLED:
      'Terminal ini tidak mengizinkan perubahan harga jual.',
    INVALID_POS_PRICE_OVERRIDE_AMOUNT:
      'Harga manual tidak valid.',
    OFFLINE_CATALOG_SCOPE_MISMATCH:
      'Scope snapshot tidak sama dengan Company, Terminal, Gudang, atau sesi aktif.',
    OFFLINE_FINAL_RECEIPT_NOT_AVAILABLE:
      'Invoice final belum tersedia. Periksa status sinkronisasi terlebih dahulu.',
    OFFLINE_COLD_START_NOT_READY:
      'POS belum memiliki scope Offline tersimpan untuk akun ini. Sambungkan internet, buka sesi, lalu siapkan snapshot terlebih dahulu.',
    OFFLINE_OPERATIONAL_SCOPE_INVALID:
      'Scope Offline tidak lengkap. Perbarui snapshot saat internet tersedia.',
    OFFLINE_SYNC_SUBMIT_TIMEOUT:
      'Pengiriman ke server melewati batas waktu. Periksa koneksi lalu cek status transaksi.',
    OFFLINE_SYNC_PROCESS_TIMEOUT:
      'Server belum menyelesaikan transaksi dalam 25 detik. Status wajib diperiksa sebelum mencoba lagi.',
    OFFLINE_SYNC_STATUS_TIMEOUT:
      'Pemeriksaan status server melewati batas waktu. Coba periksa kembali saat koneksi stabil.',
    OFFLINE_ORDER_RESERVATION_NOT_AVAILABLE:
      'Checkout Offline sementara ditutup sampai sinkronisasi Order dan Reserved Out tersedia.',
    NEGATIVE_STOCK_AUTHORIZATION_REQUIRED:
      'Stok tidak cukup dan izin stok minus untuk Order ini belum lengkap.',
    SALES_ORDER_FINAL:
      'Order sudah dikonfirmasi atau final. Muat ulang daftar Order.',
    SALES_ORDER_VERIFIED_PAYMENT_REVERSAL_REQUIRED:
      'Pembayaran sudah diverifikasi. Finance wajib menyelesaikan reversal sebelum Order dapat dibatalkan.',
    SALES_ORDER_CASH_REFUND_REQUIRES_OPEN_SESSION:
      'Buka sesi kas pada toko Order ini untuk mencatat pengembalian Cash, lalu coba lagi.',
    SALES_ORDER_CASH_REFUND_REQUIRES_CURRENT_OPEN_SESSION:
      'Buka sesi kas pada toko Order ini untuk mencatat pengembalian Cash, lalu coba lagi.',
    SALES_ORDER_DISPATCH_STARTED:
      'Barang sudah mulai dikirim. Gunakan proses Return atau koreksi pemenuhan.',
    SALES_ORDER_REQUIREMENT_MISSING:
      'Snapshot kebutuhan stok Order belum tersedia. Simpan ulang Draft.',
    CONFIRMED_SALES_ORDER_IMMUTABLE:
      'Order sudah dikonfirmasi dan stoknya telah dicadangkan. Lanjutkan dari daftar Order, bukan dari Draft.',
    SALES_ORDER_VIEW_FORBIDDEN:
      'Akun ini tidak boleh melihat Order pada toko aktif.',
  }
  return labels[code] ?? code.replaceAll('_', ' ')
}

export default function App() {
  const [session, setSession] = useState<Session | null>(null)
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [companies, setCompanies] = useState<CompanyOption[]>([])
  const [companyId, setCompanyId] = useState('')
  const [bootstrap, setBootstrap] = useState<BootstrapData | null>(null)
  const [cashierSession, setCashierSession] = useState<CashierSession | null>(null)
  const [terminalId, setTerminalId] = useState('')
  const [warehouseId, setWarehouseId] = useState('')
  const [openingCash, setOpeningCash] = useState('')
  const [closingCash, setClosingCash] = useState('')
  const [catalog, setCatalog] = useState<CatalogData>(EMPTY_CATALOG)
  const [customerId, setCustomerId] = useState('')
  const [selectedPricelistId, setSelectedPricelistId] = useState('')
  const [paymentLegs, setPaymentLegs] = useState<PaymentLeg[]>([])
  const [isTempo, setIsTempo] = useState(false)
  const [transactionAt, setTransactionAt] = useState(() => new Date().toISOString())
  const [transactionDateIsManual, setTransactionDateIsManual] = useState(false)
  const [dueDate, setDueDate] = useState('')
  const [dueDateIsManual, setDueDateIsManual] = useState(false)
  const [roundingDirection, setRoundingDirection] = useState<
    'NONE' | 'DOWN' | 'UP'
  >('NONE')
  const [globalDiscount, setGlobalDiscount] = useState('')
  const [cart, setCart] = useState<CartItem[]>([])
  const [cartQuantityInputs, setCartQuantityInputs] = useState<
    Record<string, string>
  >({})
  const [editingCartProductUomId, setEditingCartProductUomId] = useState('')
  const [draft, setDraft] = useState<SaleDraft | null>(null)
  const [draftLabel, setDraftLabel] = useState('')
  const [draftNotes, setDraftNotes] = useState('')
  const [saleDrafts, setSaleDrafts] = useState<SaleDraftListItem[]>([])
  const [draftPanelOpen, setDraftPanelOpen] = useState(false)
  const [salesOrders, setSalesOrders] = useState<SalesOrderListItem[]>([])
  const [orderPanelOpen, setOrderPanelOpen] = useState(false)
  const [confirmedOrder, setConfirmedOrder] = useState<{
    orderNo: string
    orderRuntimeStatus: string
    plannedOrderDate: string | null
  } | null>(null)
  const [clientTransactionId, setClientTransactionId] = useState<string>(() =>
    crypto.randomUUID(),
  )
  const [resolvedLines, setResolvedLines] = useState<ResolvedSaleLine[]>([])
  const [pricePreviewLines, setPricePreviewLines] = useState<
    PosPricePreviewLine[]
  >([])
  const [pricePreviewLoading, setPricePreviewLoading] = useState(false)
  const [pricePreviewError, setPricePreviewError] = useState('')
  const [receipt, setReceipt] = useState<SaleReceipt | null>(null)
  const [salesDocuments, setSalesDocuments] = useState<{
    invoice: SalesInvoiceDocument
    delivery: SalesDeliveryDocument | null
  } | null>(null)
  const [fulfillmentMode, setFulfillmentMode] = useState<
    'PICKUP' | 'DELIVERY'
  >('PICKUP')
  const [deliveryRecipientName, setDeliveryRecipientName] = useState('')
  const [deliveryRecipientPhone, setDeliveryRecipientPhone] = useState('')
  const [deliveryAddress, setDeliveryAddress] = useState('')
  const [deliveryScheduledAt, setDeliveryScheduledAt] = useState('')
  const [deliveryNotes, setDeliveryNotes] = useState('')
  const [deliveryFeeAmount, setDeliveryFeeAmount] = useState('0')
  const [deliveryFeeInvoiceDisplayMode, setDeliveryFeeInvoiceDisplayMode] =
    useState<'SHOW_SEPARATE' | 'HIDE_BREAKDOWN'>('SHOW_SEPARATE')
  const [deliveryDetailsOpen, setDeliveryDetailsOpen] = useState(false)
  const [shortages, setShortages] = useState<Array<Record<string, unknown>>>([])
  const [search, setSearch] = useState('')
  const [category, setCategory] = useState('Semua')
  const [productPickerOpen, setProductPickerOpen] = useState(false)
  const [workspaceLayout, setWorkspaceLayout] = useState<
    'CATALOG' | 'COMPACT'
  >(() =>
    window.localStorage.getItem('mads-pos-workspace-layout') === 'COMPACT'
      ? 'COMPACT'
      : 'CATALOG',
  )
  const [isOnline, setIsOnline] = useState(navigator.onLine)
  const [offlineCache, setOfflineCache] =
    useState<OfflineCatalogReadResult | null>(null)
  const [offlineAllowances, setOfflineAllowances] = useState<
    OfflineAllowanceAvailability[]
  >([])
  const [offlineQueue, setOfflineQueue] = useState<OfflineSaleQueueRecord[]>([])
  const [offlineSlip, setOfflineSlip] = useState<OfflineSlip | null>(null)
  const [offlineCacheBusy, setOfflineCacheBusy] = useState(false)
  const [offlineCacheMessage, setOfflineCacheMessage] = useState('')
  const [offlinePanelOpen, setOfflinePanelOpen] = useState(false)
  const [offlineProductId, setOfflineProductId] = useState('')
  const [coldStartRestored, setColdStartRestored] = useState(false)
  const [quickCustomerOpen, setQuickCustomerOpen] = useState(false)
  const [salesReturnOpen, setSalesReturnOpen] = useState(false)
  const [expenseRequestOpen, setExpenseRequestOpen] = useState(false)
  const [cashDepositOpen, setCashDepositOpen] = useState(false)
  const [stockRequestOpen, setStockRequestOpen] = useState(false)
  const [goodsReceiptOpen, setGoodsReceiptOpen] = useState(false)
  const [purchaseReturnOpen, setPurchaseReturnOpen] = useState(false)
  const [stockOpnameOpen, setStockOpnameOpen] = useState(false)
  const [isPrinterConnected, setIsPrinterConnected] = useState(false)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState('')
  const [error, setError] = useState('')
  const [actionDialog, setActionDialog] = useState<ActionDialog | null>(null)
  const [actionDialogReason, setActionDialogReason] = useState('')
  const [closeSessionOpen, setCloseSessionOpen] = useState(false)
  const offlineBootstrapAttemptRef = useRef('')
  const pricePreviewRequestRef = useRef(0)
  const deliveryPolicyContextRef = useRef('')
  const automaticDeliveryCustomerRef = useRef('')

  useEffect(() => {
    window.localStorage.setItem('mads-pos-workspace-layout', workspaceLayout)
    setProductPickerOpen(false)
    setSearch('')
  }, [workspaceLayout])

  useEffect(() => {
    function preventNumberWheelChange(event: WheelEvent) {
      const input = event.target
      if (
        event.ctrlKey ||
        !(input instanceof HTMLInputElement) ||
        input.type !== 'number' ||
        document.activeElement !== input
      ) return
      event.preventDefault()
      scrollNumberInputContainer(input, wheelDeltaPixels(event))
    }
    document.addEventListener('wheel', preventNumberWheelChange, {
      capture: true,
      passive: false,
    })
    return () => document.removeEventListener(
      'wheel', preventNumberWheelChange, { capture: true },
    )
  }, [])

  const activeCompany = companies.find((item) => item.id === companyId)
  const canForceReleaseDraft = Boolean(
    activeCompany &&
      ['SUPER_ADMIN', 'COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER'].includes(
        activeCompany.roleCode,
      ),
  )
  const activeTerminal = bootstrap?.terminals.find(
    (item) => item.id === (cashierSession?.terminalId || terminalId),
  )
  const terminalFeatureVisible = (featureKey: string) =>
    !(activeTerminal?.hiddenFeatureKeys ?? []).includes(featureKey)
  const activeWarehouse = bootstrap?.warehouses.find(
    (item) => item.id === (cashierSession?.warehouseId || warehouseId),
  )
  const activeCustomer = catalog.customers.find(
    (item) => item.id === customerId,
  )

  useEffect(() => {
    if (!companyId || !bootstrap) return
    const policy = bootstrap.deliveryDocumentCreationPolicy ?? 'DELIVERY_ONLY'
    const contextKey = `${companyId}:${policy}`
    if (deliveryPolicyContextRef.current === contextKey) return
    deliveryPolicyContextRef.current = contextKey
    automaticDeliveryCustomerRef.current = ''
    setFulfillmentMode(policy === 'ALL_POSTED_SALES' ? 'DELIVERY' : 'PICKUP')
    setDeliveryRecipientName('')
    setDeliveryRecipientPhone('')
    setDeliveryAddress('')
    setDeliveryScheduledAt('')
    setDeliveryNotes('')
    setDeliveryFeeAmount('0')
    setDeliveryFeeInvoiceDisplayMode('SHOW_SEPARATE')
    setDeliveryDetailsOpen(false)
  }, [bootstrap, companyId])

  useEffect(() => {
    if (
      bootstrap?.deliveryDocumentCreationPolicy !== 'ALL_POSTED_SALES' ||
      fulfillmentMode !== 'DELIVERY' ||
      !activeCustomer
    ) return
    const customerKey = `${companyId}:${activeCustomer.id}`
    if (automaticDeliveryCustomerRef.current === customerKey) return
    automaticDeliveryCustomerRef.current = customerKey
    setDeliveryRecipientName(activeCustomer.isWalkIn ? '' : activeCustomer.name)
    setDeliveryRecipientPhone(activeCustomer.phone)
    setDeliveryAddress(activeCustomer.address)
  }, [activeCustomer, bootstrap?.deliveryDocumentCreationPolicy, companyId, fulfillmentMode])
  const automaticPricelist = catalog.pricelists.find(
    (item) =>
      item.id === activeCustomer?.defaultPricelistId ||
      (item.scope === 'GLOBAL' && item.isDefault),
  )
  const eligiblePricelists = useMemo(
    () =>
      catalog.pricelists.filter(
        (item) =>
          item.scope === 'GLOBAL' ||
          item.id === activeCustomer?.defaultPricelistId,
      ),
    [activeCustomer?.defaultPricelistId, catalog.pricelists],
  )

  const availableWarehouses = useMemo(() => {
    const selectedTerminal = bootstrap?.terminals.find(
      (item) => item.id === terminalId,
    )
    if (!bootstrap || !selectedTerminal) return []
    return bootstrap.warehouses.filter(
      (item) =>
        item.storeId === null || item.storeId === selectedTerminal.storeId,
    )
  }, [bootstrap, terminalId])

  const categories = useMemo(
    () => [
      'Semua',
      ...Array.from(
        new Set(catalog.products.map((product) => product.categoryName)),
      ).sort(),
    ],
    [catalog.products],
  )

  const filteredProducts = useMemo(() => {
    const query = search.trim().toLowerCase()
    return catalog.products.filter((product) => {
      const matchesCategory =
        category === 'Semua' || product.categoryName === category
      const matchesQuery =
        !query ||
        product.name.toLowerCase().includes(query) ||
        product.sku.toLowerCase().includes(query) ||
        product.uomName.toLowerCase().includes(query) ||
        product.barcode?.toLowerCase().includes(query)
      return matchesCategory && matchesQuery
    })
  }, [catalog.products, category, search])

  const pricePreviewByProductUom = useMemo(
    () => new Map(
      pricePreviewLines.map((line) => [line.productUomId, line]),
    ),
    [pricePreviewLines],
  )

  const fallbackSubtotal = useMemo(
    () =>
      cart.reduce(
        (total, item) => {
          const unitPrice = item.overrideUnitPrice ??
            pricePreviewByProductUom.get(item.product.productUomId)?.unitPrice ??
            item.product.fallbackPrice
          const gross = unitPrice * item.quantity
          const discount = item.discountType === 'AMOUNT'
            ? item.discountInput
            : item.discountType === 'PERCENT'
              ? gross * item.discountInput / 100
              : 0
          return total + Math.max(gross - discount, 0)
        },
        0,
      ),
    [cart, pricePreviewByProductUom],
  )
  const offlineCalculation = useMemo(() => {
    if (isOnline || !offlineCache || !customerId || cart.length === 0) {
      return { preview: null, error: '' }
    }
    try {
      return {
        preview: priceOfflineCheckout({
          snapshot: offlineCache.snapshot,
          allowances: offlineAllowances,
          customerId,
          selectedPricelistId,
          lines: cart.map((item) => ({
            lineKey: item.product.productUomId,
            productUomId: item.product.productUomId,
            quantity: item.quantity,
            discountType: item.discountType,
            discountInput: item.discountInput,
          })),
          globalDiscount: Number(globalDiscount || 0),
          roundingDirection,
        }),
        error: '',
      }
    } catch (reason) {
      return {
        preview: null,
        error: friendlyError(errorMessage(reason)),
      }
    }
  }, [
    cart,
    customerId,
    globalDiscount,
    isOnline,
    offlineAllowances,
    offlineCache,
    roundingDirection,
    selectedPricelistId,
  ])
  const offlinePreview = offlineCalculation.preview
  const offlinePreviewError = offlineCalculation.error
  const parsedDeliveryFee = Number(deliveryFeeAmount || 0)
  const deliveryFeeInputValid =
    Number.isFinite(parsedDeliveryFee) && parsedDeliveryFee >= 0
  const effectiveDeliveryFee =
    fulfillmentMode === 'DELIVERY' && deliveryFeeInputValid
      ? parsedDeliveryFee
      : 0
  const paymentDue =
    draft
      ? draft.grandTotalAfterRounding - draft.deliveryFeeAmount + effectiveDeliveryFee
      : offlinePreview
        ? offlinePreview.grandTotal + effectiveDeliveryFee
        : 0
  const paymentBaseTotal = paymentLegs.reduce(
    (total, leg) => total + Number(leg.amount || 0),
    0,
  )
  const paymentRemaining = paymentDue - paymentBaseTotal
  const returnedChangeTotal = paymentLegs.reduce((total, leg) => {
    const method = catalog.paymentMethods.find(
      (item) => item.id === leg.paymentMethodId,
    )
    if (
      !['CASH', 'TRANSFER'].includes(method?.methodType ?? '') ||
      leg.overpaymentDisposition !== 'RETURNED'
    ) return total
    const amount = Number(leg.amount || 0)
    const tendered = Number(leg.tenderedAmount || amount)
    return total + Math.max(tendered - amount, 0)
  }, 0)
  const customerBalanceCreditTotal = paymentLegs.reduce((total, leg) => {
    const method = catalog.paymentMethods.find(
      (item) => item.id === leg.paymentMethodId,
    )
    if (
      !['CASH', 'TRANSFER'].includes(method?.methodType ?? '') ||
      leg.overpaymentDisposition !== 'CUSTOMER_BALANCE'
    ) return total
    const amount = Number(leg.amount || 0)
    const tendered = Number(leg.tenderedAmount || amount)
    return total + Math.max(tendered - amount, 0)
  }, 0)
  const customerSurchargeEstimate = paymentLegs.reduce((total, leg) => {
    const method = catalog.paymentMethods.find(
      (item) => item.id === leg.paymentMethodId,
    )
    if (!method?.feeEnabled || method.feeBearer !== 'CUSTOMER') return total
    const amount = Number(leg.amount || 0)
    const percent =
      method.feeType === 'PERCENT' ||
      method.feeType === 'PERCENT_PLUS_FIXED'
        ? amount * method.feePercent / 100
        : 0
    const fixed =
      method.feeType === 'FIXED' ||
      method.feeType === 'PERCENT_PLUS_FIXED'
        ? method.feeFixedAmount
        : 0
    return total + Math.round((percent + fixed) * 10_000) / 10_000
  }, 0)
  const customerBalanceDue =
    isOnline &&
    !isTempo &&
    catalog.customerBalanceTenderEnabled &&
    activeCustomer &&
    !activeCustomer.isWalkIn
      ? activeCustomer.currentBalance
      : 0
  const customerBalanceShortfall = Math.max(
    customerBalanceDue - paymentDue,
    0,
  )

  const refreshCompanies = useCallback(async (activeSession: Session) => {
    const result = await loadCompanies(activeSession.user)
    setCompanies(result.companies)
    const selected =
      result.companies.find((item) => item.id === result.activeCompanyId)?.id ??
      result.companies[0]?.id ??
      ''
    setCompanyId(selected)
    if (selected && selected !== result.activeCompanyId) {
      await setActiveCompany(selected)
    }
  }, [])

  const refreshBootstrap = useCallback(
    async (
      selectedCompanyId: string,
      userId: string,
      companyRoleCode: string,
    ) => {
      const data = await loadBootstrap(
        selectedCompanyId,
        userId,
        companyRoleCode,
      )
      setBootstrap(data)
      setCashierSession(data.openSession)
      if (data.openSession) {
        setTerminalId(data.openSession.terminalId)
        setWarehouseId(data.openSession.warehouseId)
      } else {
        const firstTerminal = data.terminals[0]
        setTerminalId(firstTerminal?.id ?? '')
        const firstWarehouse = data.warehouses.find(
          (item) =>
            firstTerminal &&
            (item.storeId === null || item.storeId === firstTerminal.storeId),
        )
        setWarehouseId(firstWarehouse?.id ?? '')
      }
    },
    [],
  )

  const refreshCatalog = useCallback(
    async (activeCashierSession: CashierSession) => {
      if (!companyId) return
      const data = await loadCatalog(
        companyId,
        activeCashierSession.storeId,
        activeCashierSession.warehouseId,
      )
      setCatalog(data)
      setSelectedPricelistId('')
      setCustomerId(
        (current) =>
          data.customers.find((item) => item.id === current)?.id ??
          data.customers.find((item) => item.isWalkIn)?.id ??
          data.customers[0]?.id ??
          '',
      )
      setPaymentLegs((current) => {
        const valid = current.filter((leg) =>
          data.paymentMethods.some((method) => method.id === leg.paymentMethodId),
        )
        if (valid.length > 0) return valid
        const defaultMethod =
          data.paymentMethods.find((item) => item.isDefault) ??
          data.paymentMethods[0]
        return [createPaymentLeg(defaultMethod?.id ?? '')]
      })
    },
    [companyId],
  )

  const refreshSaleDrafts = useCallback(
    async (activeCashierSession: CashierSession) => {
      const rows = await listSaleDrafts(activeCashierSession.storeId)
      setSaleDrafts(rows)
    },
    [],
  )

  const refreshSalesOrders = useCallback(
    async (activeCashierSession: CashierSession) => {
      const workspace = await loadSalesOrders(activeCashierSession.storeId)
      setSalesOrders(workspace.orders)
    },
    [],
  )

  const loadOfflineCacheState = useCallback(async (cashierSessionId: string) => {
    const {
      getOfflineAllowanceAvailability,
      readOfflineCatalogSnapshot,
    } = await import('./lib/offlineCatalog')
    const { listOfflineSaleQueue } = await import('./lib/offline')
    const queue = await listOfflineSaleQueue(cashierSessionId)
    setOfflineQueue(queue)
    const cached = await readOfflineCatalogSnapshot(cashierSessionId)
    setOfflineCache(cached ?? null)
    if (!cached) {
      setOfflineAllowances([])
      return { cache: null, allowances: [], queue }
    }
    const allowances = await getOfflineAllowanceAvailability(
      cashierSessionId,
      cached,
    )
    setOfflineAllowances(allowances)
    return { cache: cached, allowances, queue }
  }, [])

  const retainCurrentOfflineScope = useCallback(
    async (cache: Pick<OfflineCatalogReadResult, 'snapshot'>) => {
      if (
        !session ||
        !activeCompany ||
        !activeTerminal ||
        !activeWarehouse ||
        !cashierSession
      ) {
        throw new Error('OFFLINE_OPERATIONAL_SCOPE_INVALID')
      }
      const { retainOfflineOperationalScope } = await import(
        './lib/offlineBootstrap'
      )
      await retainOfflineOperationalScope({
        company: activeCompany,
        terminal: activeTerminal,
        warehouse: activeWarehouse,
        cashierSession,
        cashierId: session.user.id,
        deliveryDocumentCreationPolicy:
          bootstrap?.deliveryDocumentCreationPolicy ?? 'DELIVERY_ONLY',
        catalogVersion: cache.snapshot.catalogVersion,
      })
    },
    [
      activeCompany,
      activeTerminal,
      activeWarehouse,
      bootstrap?.deliveryDocumentCreationPolicy,
      cashierSession,
      session,
    ],
  )

  const restoreOfflineColdStart = useCallback(
    async (activeSession: Session) => {
      const { restoreOfflineColdStart: restore } = await import(
        './lib/offlineBootstrap'
      )
      const restored = await restore(activeSession.user.id)
      if (!restored) return false
      setCompanies([restored.company])
      setCompanyId(restored.company.id)
      setBootstrap(restored.bootstrap)
      setCashierSession(restored.cashierSession)
      setTerminalId(restored.cashierSession.terminalId)
      setWarehouseId(restored.cashierSession.warehouseId)
      setCatalog(restored.catalog)
      const walkIn =
        restored.catalog.customers.find((item) => item.isWalkIn) ??
        restored.catalog.customers[0]
      const defaultPayment =
        restored.catalog.paymentMethods.find((item) => item.isDefault) ??
        restored.catalog.paymentMethods[0]
      setCustomerId(walkIn?.id ?? '')
      setSelectedPricelistId('')
      setPaymentLegs([createPaymentLeg(defaultPayment?.id ?? '')])
      await loadOfflineCacheState(restored.cashierSession.id)
      setColdStartRestored(true)
      setOfflineCacheMessage(
        'Scope, katalog, dan antrean dipulihkan dari perangkat. Saat internet kembali, status server diperiksa sebelum retry.',
      )
      setNotice('Mode Offline dipulihkan untuk sesi kasir terakhir.')
      return true
    },
    [loadOfflineCacheState],
  )

  useEffect(() => {
    if (supabaseConfigurationError) {
      setError(supabaseConfigurationError)
      setLoading(false)
      return
    }

    let mounted = true
    getCurrentSession()
      .then(async (current) => {
        if (!mounted) return
        setSession(current)
        if (!current) return
        if (!navigator.onLine) {
          if (!(await restoreOfflineColdStart(current))) {
            throw new Error('OFFLINE_COLD_START_NOT_READY')
          }
          return
        }
        try {
          await refreshCompanies(current)
        } catch (reason) {
          if (
            !isConnectionFailure(reason) ||
            !(await restoreOfflineColdStart(current))
          ) {
            throw reason
          }
          offlineBootstrapAttemptRef.current = ''
          setIsOnline(false)
        }
      })
      .catch((reason) => setError(friendlyError(errorMessage(reason))))
      .finally(() => mounted && setLoading(false))
    const { data } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      setSession(nextSession)
      if (!nextSession) {
        setCompanies([])
        setCompanyId('')
        setBootstrap(null)
        setCashierSession(null)
        setCatalog(EMPTY_CATALOG)
        setOfflineCache(null)
        setOfflineAllowances([])
        setOfflineQueue([])
        setOfflineSlip(null)
        setOfflineCacheMessage('')
        setOfflineProductId('')
        setColdStartRestored(false)
      }
    })
    const online = () => setIsOnline(true)
    const offline = () => {
      offlineBootstrapAttemptRef.current = ''
      setIsOnline(false)
    }
    window.addEventListener('online', online)
    window.addEventListener('offline', offline)
    return () => {
      mounted = false
      data.subscription.unsubscribe()
      window.removeEventListener('online', online)
      window.removeEventListener('offline', offline)
    }
  }, [refreshCompanies, restoreOfflineColdStart])

  useEffect(() => {
    if (
      !isOnline ||
      coldStartRestored ||
      !session ||
      !companyId ||
      !activeCompany
    ) {
      return
    }
    setLoading(true)
    refreshBootstrap(companyId, session.user.id, activeCompany.roleCode)
      .catch((reason) => setError(friendlyError(errorMessage(reason))))
      .finally(() => setLoading(false))
  }, [
    activeCompany,
    coldStartRestored,
    companyId,
    isOnline,
    refreshBootstrap,
    session,
  ])

  useEffect(() => {
    if (!isOnline || coldStartRestored || !cashierSession?.storeId) return
    setLoading(true)
    Promise.all([
      refreshCatalog(cashierSession),
      refreshSaleDrafts(cashierSession),
      refreshSalesOrders(cashierSession),
    ])
      .catch((reason) => setError(friendlyError(errorMessage(reason))))
      .finally(() => setLoading(false))
  }, [
    cashierSession,
    coldStartRestored,
    isOnline,
    refreshCatalog,
    refreshSaleDrafts,
    refreshSalesOrders,
  ])

  useEffect(() => {
    const requestId = ++pricePreviewRequestRef.current
    setPricePreviewLines([])
    setPricePreviewError('')
    if (
      !isOnline ||
      !cashierSession ||
      !customerId ||
      catalog.products.length === 0
    ) {
      setPricePreviewLoading(false)
      return
    }

    const quantityByProductUom = new Map(
      cart.map((item) => [item.product.productUomId, item.quantity]),
    )
    const lines = catalog.products.map((product) => ({
      lineKey: product.productUomId,
      productUomId: product.productUomId,
      quantity: quantityByProductUom.get(product.productUomId) ?? 1,
    }))
    const timer = window.setTimeout(() => {
      setPricePreviewLoading(true)
      const chunks: typeof lines[] = []
      for (let index = 0; index < lines.length; index += 250) {
        chunks.push(lines.slice(index, index + 250))
      }
      void Promise.all(chunks.map((chunk) => previewPosSalePrices({
        cashierSessionId: cashierSession.id,
        customerId,
        selectedPricelistId: selectedPricelistId || null,
        lines: chunk,
      })))
        .then((results) => {
          if (pricePreviewRequestRef.current !== requestId) return
          setPricePreviewLines(results.flat())
        })
        .catch((reason) => {
          if (pricePreviewRequestRef.current !== requestId) return
          setPricePreviewError(friendlyError(errorMessage(reason)))
        })
        .finally(() => {
          if (pricePreviewRequestRef.current === requestId) {
            setPricePreviewLoading(false)
          }
        })
    }, 200)

    return () => window.clearTimeout(timer)
  }, [
    cart,
    cashierSession,
    catalog.products,
    customerId,
    isOnline,
    selectedPricelistId,
  ])

  useEffect(() => {
    if (!isOnline || !session || !companyId || !coldStartRestored) return
    let active = true
    setActiveCompany(companyId)
      .then(() => refreshCompanies(session))
      .then(() => {
        if (active) {
          setColdStartRestored(false)
          setOfflineCacheMessage(
            'Koneksi kembali. Scope server sedang direkonsiliasi sebelum retry.',
          )
        }
      })
      .catch((reason) => {
        if (active) {
          setOfflineCacheMessage(friendlyError(errorMessage(reason)))
        }
      })
    return () => {
      active = false
    }
  }, [coldStartRestored, companyId, isOnline, refreshCompanies, session])

  useEffect(() => {
    if (!cashierSession) {
      offlineBootstrapAttemptRef.current = ''
      setOfflineCache(null)
      setOfflineAllowances([])
      setOfflineQueue([])
      setOfflineCacheMessage('')
      setOfflineProductId('')
      return
    }
    const load = () => {
      loadOfflineCacheState(cashierSession.id).catch((reason) => {
        setOfflineCache(null)
        setOfflineAllowances([])
        setOfflineCacheMessage(friendlyError(errorMessage(reason)))
      })
    }
    load()
    const timer = window.setInterval(load, 60_000)
    return () => window.clearInterval(timer)
  }, [cashierSession, loadOfflineCacheState])

  useEffect(() => {
    if (
      !isOnline ||
      coldStartRestored ||
      !session ||
      !cashierSession ||
      !companyId ||
      !activeTerminal ||
      !activeWarehouse
    ) {
      return
    }
    const scopeKey = [
      companyId,
      cashierSession.id,
      cashierSession.terminalId,
      cashierSession.warehouseId,
      session.user.id,
    ].join(':')
    if (offlineBootstrapAttemptRef.current === scopeKey) return
    offlineBootstrapAttemptRef.current = scopeKey
    let active = true
    setOfflineCacheBusy(true)
    Promise.all([
      import('./lib/offline'),
      import('./lib/offlineCatalog'),
    ])
      .then(async ([offline, offlineCatalog]) => {
        await offline.recoverOfflineSaleQueue(cashierSession.id)
        await loadOfflineCacheState(cashierSession.id)
        return offlineCatalog.refreshOfflineCatalogSnapshot({
          companyId,
          storeId: cashierSession.storeId,
          terminalId: cashierSession.terminalId,
          warehouseId: cashierSession.warehouseId,
          cashierSessionId: cashierSession.id,
          cashierId: session.user.id,
        })
      })
      .then(async (cache) => {
        await retainCurrentOfflineScope(cache)
        return loadOfflineCacheState(cashierSession.id)
      })
      .then(() => {
        if (active) {
          setOfflineCacheMessage(
            'Status antrean diperiksa dan snapshot Offline disiapkan. Minta cadangan stok untuk Product yang akan dijual sebelum memutus internet.',
          )
        }
      })
      .catch((reason) => {
        if (active) {
          setOfflineCacheMessage(friendlyError(errorMessage(reason)))
        }
      })
      .finally(() => {
        if (active) setOfflineCacheBusy(false)
      })
    return () => {
      active = false
    }
  }, [
    activeTerminal,
    activeWarehouse,
    cashierSession,
    coldStartRestored,
    companyId,
    isOnline,
    loadOfflineCacheState,
    retainCurrentOfflineScope,
    session,
  ])

  useEffect(() => {
    if (!draft || !cashierSession) return
    const heartbeat = window.setInterval(() => {
      heartbeatSaleDraftLock(draft.salesId, cashierSession.id).catch(
        (reason) => {
          setDraft(null)
          setError(friendlyError(errorMessage(reason)))
          void refreshSaleDrafts(cashierSession)
        },
      )
    }, 60_000)
    return () => window.clearInterval(heartbeat)
  }, [cashierSession, draft, refreshSaleDrafts])

  useEffect(() => {
    const firstWarehouse = availableWarehouses[0]
    if (
      !cashierSession &&
      firstWarehouse &&
      !availableWarehouses.some((item) => item.id === warehouseId)
    ) {
      setWarehouseId(firstWarehouse.id)
    }
  }, [availableWarehouses, cashierSession, warehouseId])

  useEffect(() => {
    if (isTempo || paymentDue <= 0 || paymentLegs.length !== 1) return
    setPaymentLegs((current) => {
      if (current.length !== 1) return current
      const leg = current[0]
      const nextAmount = String(paymentDue)
      const method = catalog.paymentMethods.find(
        (item) => item.id === leg.paymentMethodId,
      )
      const tenderWasFollowingAmount =
        !leg.tenderedAmount || leg.tenderedAmount === leg.amount
      const nextTender =
        ['CASH', 'TRANSFER'].includes(method?.methodType ?? '') &&
        tenderWasFollowingAmount
          ? nextAmount
          : leg.tenderedAmount
      if (leg.amount === nextAmount && leg.tenderedAmount === nextTender) {
        return current
      }
      return [{ ...leg, amount: nextAmount, tenderedAmount: nextTender }]
    })
  }, [
    catalog.paymentMethods,
    isTempo,
    paymentDue,
    paymentLegs.length,
  ])

  useEffect(() => {
    const balanceMethod = catalog.paymentMethods.find(
      (method) => method.methodType === 'CUSTOMER_BALANCE',
    )
    const balance = activeCustomer?.currentBalance ?? 0
    const canUseBalance = Boolean(
      isOnline &&
        !isTempo &&
        catalog.customerBalanceTenderEnabled &&
        activeCustomer &&
        !activeCustomer.isWalkIn &&
        balanceMethod &&
        balance > 0 &&
        paymentDue > 0 &&
        balance <= paymentDue,
    )
    setPaymentLegs((current) => {
      const existingBalance = current.find(
        (leg) => leg.paymentMethodId === balanceMethod?.id,
      )
      const external = current.filter(
        (leg) => leg.paymentMethodId !== balanceMethod?.id,
      )
      if (!canUseBalance || !balanceMethod) {
        if (!existingBalance) return current
        const fallback =
          external[0] ??
          createPaymentLeg(
            catalog.paymentMethods.find(
              (method) => method.methodType !== 'CUSTOMER_BALANCE',
            )?.id ?? '',
          )
        return [{ ...fallback, amount: String(paymentDue) }]
      }
      const remainder = paymentDue - balance
      const balanceLeg: PaymentLeg = {
        ...(existingBalance ?? createPaymentLeg(balanceMethod.id)),
        paymentMethodId: balanceMethod.id,
        amount: String(balance),
        tenderedAmount: String(balance),
        proofUrl: '',
        overpaymentDisposition: 'RETURNED',
      }
      if (remainder <= 0) return [balanceLeg]
      const externalMethod =
        external[0] ??
        createPaymentLeg(
          catalog.paymentMethods.find(
            (method) => method.methodType !== 'CUSTOMER_BALANCE',
          )?.id ?? '',
        )
      const expectedAmount = String(remainder)
      const method = catalog.paymentMethods.find(
        (item) => item.id === externalMethod.paymentMethodId,
      )
      return [
        balanceLeg,
        {
          ...externalMethod,
          amount: expectedAmount,
          tenderedAmount: ['CASH', 'TRANSFER'].includes(
            method?.methodType ?? '',
          )
            ? expectedAmount
            : externalMethod.tenderedAmount,
        },
      ]
    })
  }, [
    activeCustomer,
    catalog.customerBalanceTenderEnabled,
    catalog.paymentMethods,
    isOnline,
    isTempo,
    paymentDue,
  ])

  useEffect(() => {
    if (
      isOnline &&
      catalog.customerBalanceCreditEnabled &&
      activeCustomer &&
      !activeCustomer.isWalkIn
    ) return
    setPaymentLegs((current) => {
      if (
        !current.some(
          (leg) => leg.overpaymentDisposition === 'CUSTOMER_BALANCE',
        )
      ) return current
      return current.map((leg) => ({
        ...leg,
        overpaymentDisposition: 'RETURNED',
      }))
    })
  }, [
    activeCustomer,
    catalog.customerBalanceCreditEnabled,
    isOnline,
  ])

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return
      if (closeSessionOpen && !busy) setCloseSessionOpen(false)
      else if (editingCartProductUomId) setEditingCartProductUomId('')
      else if (actionDialog) {
        setActionDialog(null)
        setActionDialogReason('')
      } else if (deliveryDetailsOpen) setDeliveryDetailsOpen(false)
      else if (productPickerOpen) setProductPickerOpen(false)
      else if (offlineSlip) setOfflineSlip(null)
      else if (receipt) {
        setReceipt(null)
        setSalesDocuments(null)
      }
      else if (confirmedOrder) {
        setConfirmedOrder(null)
        setSalesDocuments(null)
      }
      else if (stockOpnameOpen) setStockOpnameOpen(false)
      else if (purchaseReturnOpen) setPurchaseReturnOpen(false)
      else if (goodsReceiptOpen) setGoodsReceiptOpen(false)
      else if (stockRequestOpen) setStockRequestOpen(false)
      else if (cashDepositOpen) setCashDepositOpen(false)
      else if (expenseRequestOpen) setExpenseRequestOpen(false)
      else if (salesReturnOpen) setSalesReturnOpen(false)
      else if (draftPanelOpen) setDraftPanelOpen(false)
      else if (orderPanelOpen) setOrderPanelOpen(false)
      else if (offlinePanelOpen) setOfflinePanelOpen(false)
      else if (quickCustomerOpen) setQuickCustomerOpen(false)
      else if (error) setError('')
      else if (notice) setNotice('')
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [
    actionDialog,
    busy,
    closeSessionOpen,
    deliveryDetailsOpen,
    draftPanelOpen,
    orderPanelOpen,
    editingCartProductUomId,
    error,
    cashDepositOpen,
    goodsReceiptOpen,
    purchaseReturnOpen,
    stockOpnameOpen,
    stockRequestOpen,
    expenseRequestOpen,
    notice,
    offlineSlip,
    offlinePanelOpen,
    productPickerOpen,
    quickCustomerOpen,
    receipt,
    confirmedOrder,
    salesReturnOpen,
  ])

  function openActionDialog(dialog: ActionDialog) {
    setActionDialogReason('')
    setActionDialog(dialog)
  }

  function closeReceipt() {
    setReceipt(null)
    setSalesDocuments(null)
  }

  function closeConfirmedOrder() {
    setConfirmedOrder(null)
    setSalesDocuments(null)
  }

  function selectCustomer(nextCustomerId: string) {
    const customer = catalog.customers.find((item) => item.id === nextCustomerId)
    setCustomerId(nextCustomerId)
    setSelectedPricelistId('')
    setResolvedLines([])
    if (isTempo && !dueDateIsManual) {
      setDueDate(suggestedTempoDueDate(transactionAt, customer?.creditTermDays ?? null))
    }
    if (fulfillmentMode === 'DELIVERY' && customer) {
      setDeliveryRecipientName(customer.isWalkIn ? '' : customer.name)
      setDeliveryRecipientPhone(customer.phone)
      setDeliveryAddress(customer.address)
    }
  }

  function toggleTempo(enabled: boolean) {
    setIsTempo(enabled)
    setResolvedLines([])
    if (!enabled) {
      setDueDate('')
      setDueDateIsManual(false)
      setTransactionDateIsManual(false)
      return
    }
    const nextTransactionAt = draft?.transactionAt ?? new Date().toISOString()
    setTransactionAt(nextTransactionAt)
    setTransactionDateIsManual(
      draft?.transactionDateSource === 'CASHIER_SELECTED',
    )
    setDueDate(suggestedTempoDueDate(
      nextTransactionAt,
      activeCustomer?.creditTermDays ?? null,
    ))
    setDueDateIsManual(false)
  }

  function selectFulfillmentMode(mode: 'PICKUP' | 'DELIVERY') {
    setFulfillmentMode(mode)
    if (mode === 'PICKUP') {
      setDeliveryRecipientName('')
      setDeliveryRecipientPhone('')
      setDeliveryAddress('')
      setDeliveryScheduledAt('')
      setDeliveryNotes('')
      setDeliveryFeeAmount('0')
      setDeliveryFeeInvoiceDisplayMode('SHOW_SEPARATE')
      setDeliveryDetailsOpen(false)
      return
    }
    setDeliveryRecipientName(activeCustomer?.isWalkIn ? '' : activeCustomer?.name ?? '')
    setDeliveryRecipientPhone(activeCustomer?.phone ?? '')
    setDeliveryAddress(activeCustomer?.address ?? '')
    setDeliveryDetailsOpen(true)
  }

  async function confirmActionDialog() {
    if (!actionDialog) return
    const reason = actionDialogReason.trim()
    if (actionDialog.requireReason && !reason) return
    const action = actionDialog.onConfirm
    setActionDialog(null)
    setActionDialogReason('')
    await action(reason)
  }

  async function handleLogin(event: React.FormEvent) {
    event.preventDefault()
    if (supabaseConfigurationError) {
      setError(supabaseConfigurationError)
      return
    }
    setBusy(true)
    setError('')
    try {
      const next = await signIn(email, password)
      setSession(next)
      if (next) await refreshCompanies(next)
    } catch (reason) {
      setError(friendlyError(errorMessage(reason)))
    } finally {
      setBusy(false)
    }
  }

  async function handleCompanyChange(nextCompanyId: string) {
    if (!session || nextCompanyId === companyId) return
    setBusy(true)
    setError('')
    try {
      await setActiveCompany(nextCompanyId)
      setCompanyId(nextCompanyId)
      resetSale()
    } catch (reason) {
      setError(friendlyError(errorMessage(reason)))
    } finally {
      setBusy(false)
    }
  }

  async function handleOpenSession(event: React.FormEvent) {
    event.preventDefault()
    if (!session || !companyId || !activeCompany) return
    setBusy(true)
    setError('')
    try {
      await openCashierSession(
        terminalId,
        warehouseId,
        Number(openingCash || 0),
      )
      await refreshBootstrap(
        companyId,
        session.user.id,
        activeCompany.roleCode,
      )
      setNotice('Sesi kasir berhasil dibuka. Snapshot stok awal sudah disimpan.')
    } catch (reason) {
      setError(friendlyError(errorMessage(reason)))
    } finally {
      setBusy(false)
    }
  }

  function handleCloseSession() {
    if (!cashierSession || !session || !companyId || !activeCompany) return
    setCloseSessionOpen(true)
  }

  async function executeCloseSession() {
    if (!cashierSession || !session || !companyId || !activeCompany) return
    setBusy(true)
    setError('')
    try {
      if (draft) {
        await releaseSaleDraftLock(draft.salesId, cashierSession.id)
      }
      const result = await closeCashierSession(
        cashierSession.id,
        cashierSession.masterVersion,
        Number(closingCash || 0),
      )
      const { invalidateOfflineCatalogSnapshot } = await import(
        './lib/offlineCatalog'
      )
      const { removeOfflineOperationalScope } = await import(
        './lib/offlineBootstrap'
      )
      await invalidateOfflineCatalogSnapshot(
        cashierSession.id,
        'SESSION_CLOSED',
      ).catch(() => undefined)
      await removeOfflineOperationalScope(cashierSession.id).catch(
        () => undefined,
      )
      setOfflineCache(null)
      setOfflineAllowances([])
      setOfflineQueue([])
      setOfflineCacheMessage('')
      setNotice(
        `Sesi ditutup. Expected ${money(Number(result.expectedCash ?? 0))}, ` +
          `selisih ${money(Number(result.difference ?? 0))}.` +
          (result.stockRequestNo
            ? ` Permintaan barang ${String(result.stockRequestNo)} otomatis dikirim ke Purchasing untuk ${Number(result.stockRequestLineCount ?? 0)} barang.`
            : ''),
      )
      resetSale()
      setSaleDrafts([])
      setSalesOrders([])
      setCloseSessionOpen(false)
      await refreshBootstrap(
        companyId,
        session.user.id,
        activeCompany.roleCode,
      )
    } catch (reason) {
      setError(friendlyError(errorMessage(reason)))
    } finally {
      setBusy(false)
    }
  }

  function addToCart(product: ProductOption) {
    if (!cashierSession) return
    setCartQuantityInputs((current) => {
      if (!(product.productUomId in current)) return current
      const next = { ...current }
      delete next[product.productUomId]
      return next
    })
    setCart((current) => {
      const existing = current.find(
        (item) => item.product.productUomId === product.productUomId,
      )
      if (existing) {
        return current.map((item) =>
          item === existing
            ? { ...item, quantity: item.quantity + 1 }
            : item,
        )
      }
      return [
        ...current,
        {
          product,
          quantity: 1,
          discountType: '',
          discountInput: 0,
          overrideUnitPrice: null,
        },
      ]
    })
    setResolvedLines([])
    setShortages([])
  }

  function updateCart(productUomId: string, patch: Partial<CartItem>) {
    setCart((current) =>
      current
        .map((item) =>
          item.product.productUomId === productUomId
            ? { ...item, ...patch }
            : item,
        )
        .filter((item) => item.quantity > 0),
    )
    setResolvedLines([])
    setShortages([])
  }

  function removeCartItem(productUomId: string) {
    setCart((current) =>
      current.filter((item) => item.product.productUomId !== productUomId),
    )
    setCartQuantityInputs((current) => {
      if (!(productUomId in current)) return current
      const next = { ...current }
      delete next[productUomId]
      return next
    })
    setResolvedLines([])
    setShortages([])
    setEditingCartProductUomId((current) =>
      current === productUomId ? '' : current,
    )
  }

  function changeCartQuantityInput(item: CartItem, rawValue: string) {
    const productUomId = item.product.productUomId
    setCartQuantityInputs((current) => ({
      ...current,
      [productUomId]: rawValue,
    }))
    if (rawValue.trim() === '') return
    const quantity = Number(rawValue)
    if (Number.isFinite(quantity) && quantity > 0) {
      updateCart(productUomId, { quantity })
    }
  }

  function commitCartQuantityInput(item: CartItem) {
    const productUomId = item.product.productUomId
    setCartQuantityInputs((current) => {
      if (!(productUomId in current)) return current
      const next = { ...current }
      delete next[productUomId]
      return next
    })
  }

  function adjustCartQuantity(item: CartItem, direction: -1 | 1) {
    const precision = item.product.allowDecimal
      ? item.product.decimalPrecision
      : 0
    const step = item.product.allowDecimal ? 10 ** -precision : 1
    const quantity = Math.max(
      step,
      Number((item.quantity + direction * step).toFixed(precision)),
    )
    commitCartQuantityInput(item)
    updateCart(item.product.productUomId, { quantity })
  }

  function draftLines() {
    return cart.map((item) => ({
      lineKey: item.product.productUomId,
      productUomId: item.product.productUomId,
      quantity: item.quantity,
      ...(item.discountType
        ? {
            lineDiscountType: item.discountType,
            lineDiscountInput: item.discountInput,
          }
        : {}),
      ...(item.overrideUnitPrice !== null
        ? { overrideUnitPrice: item.overrideUnitPrice }
        : {}),
    }))
  }

  async function persistDraft(
    currentDraft: SaleDraft | null,
    payments: Array<{
      clientPaymentKey: string
      paymentMethodId: string
      amount: number
      tenderedAmount: number
      proofUrl?: string
      overpaymentDisposition?: 'RETURNED' | 'CUSTOMER_BALANCE'
    }> = [],
    negativeStockReason = '',
  ) {
    if (!cashierSession || !customerId || cart.length === 0) {
      throw new Error('SESSION_CUSTOMER_AND_CART_REQUIRED')
    }
    if (
      fulfillmentMode === 'DELIVERY' &&
      !deliveryRecipientName.trim()
    ) {
      throw new Error('DELIVERY_RECIPIENT_REQUIRED')
    }
    if (fulfillmentMode === 'DELIVERY' && !deliveryFeeInputValid) {
      throw new Error('INVALID_DELIVERY_FEE_AMOUNT')
    }
    if (currentDraft) {
      await acquireSaleDraftLock(
        currentDraft.salesId,
        cashierSession.id,
        false,
      )
    }
    const saved = await saveSaleDraft({
      draft: currentDraft,
      clientTransactionId,
      cashierSessionId: cashierSession.id,
      customerId,
      draftLabel,
      draftNotes,
      selectedPricelistId: selectedPricelistId || null,
      lines: draftLines(),
      globalDiscount: Number(globalDiscount || 0),
      roundingDirection,
      isTempo,
      transactionAt: isTempo ? transactionAt : null,
      transactionDateIntent:
        isTempo && transactionDateIsManual ? 'CASHIER_SELECTED' : 'PRESERVE',
      dueDate: isTempo && dueDate ? new Date(dueDate).toISOString() : null,
      fulfillmentMode,
      deliveryRecipientName,
      deliveryRecipientPhone,
      deliveryAddress,
      deliveryScheduledAt: deliveryScheduledAt
        ? new Date(deliveryScheduledAt).toISOString()
        : null,
      deliveryNotes,
      deliveryFeeAmount: effectiveDeliveryFee,
      deliveryFeeInvoiceDisplayMode,
      negativeStockReason,
      payments,
    })
    setDraft(saved)
    setTransactionAt(saved.transactionAt)
    setResolvedLines(await loadResolvedSaleLines(companyId, saved.salesId))
    await refreshSaleDrafts(cashierSession)
    return saved
  }

  async function handleContinueDraft(item: SaleDraftListItem) {
    if (!cashierSession || !session) return false
    const lockedByOther =
      Boolean(item.lockOwnerId) &&
      (item.lockOwnerId !== session.user.id ||
        item.lockSessionId !== cashierSession.id)
    if (lockedByOther && !item.lockExpired) {
      setError(
        `Draft sedang diedit ${item.lockOwnerName ?? 'kasir lain'}.`,
      )
      return false
    }
    if (lockedByOther && item.lockExpired) {
      openActionDialog({
        title: `Ambil alih ${item.draftNo}?`,
        description:
          `Lock milik ${item.lockOwnerName ?? 'kasir lain'} sudah kedaluwarsa. ` +
          'Pengambilalihan akan dicatat pada audit.',
        confirmLabel: 'Ambil alih Draft',
        tone: 'primary',
        onConfirm: async () => {
          await executeContinueDraft(item, true)
        },
      })
      return false
    }
    return executeContinueDraft(item, false)
  }

  async function executeContinueDraft(
    item: SaleDraftListItem,
    confirmTakeover: boolean,
  ) {
    if (!cashierSession) return false
    setBusy(true)
    setError('')
    try {
      if (draft && draft.salesId !== item.salesId) {
        await releaseSaleDraftLock(
          draft.salesId,
          cashierSession.id,
        )
      }
      await acquireSaleDraftLock(
        item.salesId,
        cashierSession.id,
        confirmTakeover,
      )

      const payload = item.payloadSnapshot
      const rawLines = Array.isArray(payload.lines)
        ? (payload.lines as Array<Record<string, unknown>>)
        : []
      const nextCart: CartItem[] = rawLines.map((line) => {
        const productUomId = String(line.productUomId ?? '')
        const product = catalog.products.find(
          (candidate) => candidate.productUomId === productUomId,
        )
        if (!product) throw new Error('DRAFT_PRODUCT_UOM_NOT_AVAILABLE')
        const discountType =
          line.lineDiscountType === 'AMOUNT' ||
          line.lineDiscountType === 'PERCENT'
            ? line.lineDiscountType
            : ''
        return {
          product,
          quantity: Number(line.quantity ?? 0),
          discountType,
          discountInput: Number(line.lineDiscountInput ?? 0),
          overrideUnitPrice:
            line.overrideUnitPrice === null || line.overrideUnitPrice === undefined
              ? null
              : Number(line.overrideUnitPrice),
        }
      })
      if (nextCart.length === 0) throw new Error('DRAFT_HAS_NO_LINES')

      const nextCustomerId = String(payload.customerId ?? item.customerId)
      const requestedPricelistId = payload.selectedPricelistId
        ? String(payload.selectedPricelistId)
        : ''
      const nextPricelistId = catalog.pricelists.some(
        (pricelist) => pricelist.id === requestedPricelistId,
      )
        ? requestedPricelistId
        : ''
      const nextClientTransactionId = String(
        payload.clientTransactionId ?? crypto.randomUUID(),
      )
      const nextIsTempo = Boolean(payload.isTempo)
      const nextDueDate =
        nextIsTempo && payload.dueDate
          ? localDateTimeInput(String(payload.dueDate))
          : ''
      const nextRoundingDirection =
        payload.roundingDirection === 'DOWN' ||
        payload.roundingDirection === 'UP'
          ? payload.roundingDirection
          : 'NONE'
      const nextGlobalDiscount = String(payload.globalDiscount ?? '')
      const nextFulfillmentMode = payload.fulfillmentMode === 'DELIVERY'
        ? 'DELIVERY'
        : 'PICKUP'
      const nextDeliveryScheduledAt = payload.deliveryScheduledAt
        ? String(payload.deliveryScheduledAt).slice(0, 16)
        : ''
      const nextDeliveryFeeAmount = nextFulfillmentMode === 'DELIVERY'
        ? String(payload.deliveryFeeAmount ?? 0)
        : '0'
      const nextDeliveryFeeInvoiceDisplayMode =
        payload.deliveryFeeInvoiceDisplayMode === 'HIDE_BREAKDOWN'
          ? 'HIDE_BREAKDOWN'
          : 'SHOW_SEPARATE'
      const nextDraft: SaleDraft = {
        salesId: item.salesId,
        draftNo: item.draftNo,
        clientTransactionId: nextClientTransactionId,
      transactionAt: item.transactionAt,
      transactionDateSource: item.transactionDateSource,
        orderTimingMode: item.orderTimingMode,
        plannedOrderDate: item.plannedOrderDate,
        operationalStatus: item.operationalStatus,
        masterVersion: item.masterVersion,
        grandTotalBeforeRounding: item.grandTotal,
        roundingAdjustment: 0,
        grandTotalAfterRounding: item.grandTotal,
        deliveryFeeAmount: Number(payload.deliveryFeeAmount ?? 0),
        deliveryFeeInvoiceDisplayMode: nextDeliveryFeeInvoiceDisplayMode,
      }

      const repriced = await saveSaleDraft({
        draft: nextDraft,
        clientTransactionId: nextClientTransactionId,
        cashierSessionId: cashierSession.id,
        customerId: nextCustomerId,
        draftLabel: item.draftLabel ?? '',
        draftNotes: item.draftNotes ?? '',
        selectedPricelistId: nextPricelistId || null,
        lines: rawLines.map((line) => ({
          lineKey: String(line.lineKey ?? line.productUomId),
          productUomId: String(line.productUomId),
          quantity: Number(line.quantity ?? 0),
          ...(line.lineDiscountType
            ? {
                lineDiscountType: line.lineDiscountType as
                  | 'AMOUNT'
                  | 'PERCENT',
                lineDiscountInput: Number(line.lineDiscountInput ?? 0),
              }
            : {}),
          ...(line.overrideUnitPrice !== null &&
          line.overrideUnitPrice !== undefined
            ? { overrideUnitPrice: Number(line.overrideUnitPrice) }
            : {}),
        })),
        globalDiscount: Number(payload.globalDiscount ?? 0),
        roundingDirection: nextRoundingDirection,
        isTempo: nextIsTempo,
        transactionAt: nextIsTempo ? item.transactionAt : null,
        transactionDateIntent: 'PRESERVE',
        dueDate: nextIsTempo && payload.dueDate
          ? String(payload.dueDate)
          : null,
        fulfillmentMode: nextFulfillmentMode,
        deliveryRecipientName: String(payload.deliveryRecipientName ?? ''),
        deliveryRecipientPhone: String(payload.deliveryRecipientPhone ?? ''),
        deliveryAddress: String(payload.deliveryAddress ?? ''),
        deliveryScheduledAt: payload.deliveryScheduledAt
          ? String(payload.deliveryScheduledAt)
          : null,
        deliveryNotes: String(payload.deliveryNotes ?? ''),
        deliveryFeeAmount: Number(nextDeliveryFeeAmount),
        deliveryFeeInvoiceDisplayMode: nextDeliveryFeeInvoiceDisplayMode,
        payments: [],
      })

      setCartQuantityInputs({})
      setCart(nextCart)
      setDraft(repriced)
      setTransactionAt(repriced.transactionAt)
      setTransactionDateIsManual(
        repriced.transactionDateSource === 'CASHIER_SELECTED',
      )
      setClientTransactionId(nextClientTransactionId)
      setCustomerId(nextCustomerId)
      setSelectedPricelistId(nextPricelistId)
      setDraftLabel(item.draftLabel ?? '')
      setDraftNotes(item.draftNotes ?? '')
      setGlobalDiscount(nextGlobalDiscount)
      setRoundingDirection(nextRoundingDirection)
      setIsTempo(nextIsTempo)
      setDueDate(nextDueDate)
      setDueDateIsManual(Boolean(nextDueDate))
      setFulfillmentMode(nextFulfillmentMode)
      setDeliveryRecipientName(String(payload.deliveryRecipientName ?? ''))
      setDeliveryRecipientPhone(String(payload.deliveryRecipientPhone ?? ''))
      setDeliveryAddress(String(payload.deliveryAddress ?? ''))
      setDeliveryScheduledAt(nextDeliveryScheduledAt)
      setDeliveryNotes(String(payload.deliveryNotes ?? ''))
      setDeliveryFeeAmount(nextDeliveryFeeAmount)
      setDeliveryFeeInvoiceDisplayMode(nextDeliveryFeeInvoiceDisplayMode)
      const defaultPayment =
        catalog.paymentMethods.find((method) => method.isDefault) ??
        catalog.paymentMethods[0]
      setPaymentLegs([createPaymentLeg(defaultPayment?.id ?? '')])
      setShortages([])
      setResolvedLines(
        await loadResolvedSaleLines(companyId, item.salesId),
      )
      setDraftPanelOpen(false)
      setNotice(
        `${item.draftNo} dibuka dan harga dihitung ulang. Konfirmasi pembayaran kembali sebelum Post.`,
      )
      await refreshSaleDrafts(cashierSession)
      return true
    } catch (reason) {
      if (!draft || draft.salesId !== item.salesId) {
        await releaseSaleDraftLock(
          item.salesId,
          cashierSession.id,
        ).catch(() => undefined)
      }
      setError(friendlyError(errorMessage(reason)))
      return false
    } finally {
      setBusy(false)
    }
  }

  async function handleStartSalesOrderRevision(
    order: SalesOrderListItem,
    reason: string,
  ) {
    if (!cashierSession) return
    const operationId = crypto.randomUUID()
    const result = await startSalesOrderRevision(
      order.salesId,
      order.masterVersion,
      cashierSession.id,
      operationId,
      reason,
    )
    const replacementSalesId = String(result.replacementSalesId ?? '')
    const rows = await listSaleDrafts(cashierSession.storeId)
    setSaleDrafts(rows)
    const replacement = rows.find(
      (item) => item.salesId === replacementSalesId,
    )
    if (!replacement) throw new Error('SALES_ORDER_REVISION_DRAFT_NOT_VISIBLE')
    setOrderPanelOpen(false)
    const opened = await handleContinueDraft(replacement)
    if (opened) {
      setNotice(
        `Draft revisi ${replacement.draftNo} dibuat dari ${order.orderNo}. ` +
          'Order lama tetap aktif sampai revisi berhasil dikonfirmasi.',
      )
    }
  }

  function handleForceReleaseDraft(item: SaleDraftListItem) {
    if (!cashierSession || !canForceReleaseDraft) return
    openActionDialog({
      title: `Lepas paksa lock ${item.draftNo}?`,
      description:
        `Draft sedang diedit ${item.lockOwnerName ?? 'kasir lain'}. ` +
        'Tindakan ini akan dicatat pada audit.',
      confirmLabel: 'Lepas paksa',
      tone: 'danger',
      requireReason: true,
      reasonLabel: 'Alasan pelepasan',
      reasonPlaceholder: 'Contoh: kasir sebelumnya sudah pulang',
      onConfirm: (reason) => executeForceReleaseDraft(item, reason),
    })
  }

  async function executeForceReleaseDraft(
    item: SaleDraftListItem,
    reason: string,
  ) {
    if (!cashierSession) return
    setBusy(true)
    setError('')
    try {
      await releaseSaleDraftLock(
        item.salesId,
        cashierSession.id,
        true,
        reason,
      )
      await refreshSaleDrafts(cashierSession)
      setNotice(`Lock ${item.draftNo} berhasil dilepas.`)
    } catch (reasonError) {
      setError(friendlyError(errorMessage(reasonError)))
    } finally {
      setBusy(false)
    }
  }

  function handleCancelDraft() {
    if (!draft || !cashierSession) return
    openActionDialog({
      title: `Batalkan ${draft.draftNo || 'Draft ini'}?`,
      description:
        'Draft akan hilang dari daftar aktif, tetapi tetap tersimpan sebagai histori. Stock dan pembayaran tidak berubah.',
      confirmLabel: 'Batalkan Draft',
      tone: 'danger',
      requireReason: true,
      reasonLabel: 'Alasan pembatalan',
      reasonPlaceholder: 'Contoh: pelanggan membatalkan pesanan',
      onConfirm: executeCancelDraft,
    })
  }

  async function executeCancelDraft(reason: string) {
    if (!draft || !cashierSession) return
    setBusy(true)
    setError('')
    try {
      await cancelSaleDraft(
        draft.salesId,
        draft.masterVersion,
        cashierSession.id,
        reason,
      )
      resetSale()
      await refreshSaleDrafts(cashierSession)
      setNotice('Draft dibatalkan dan disimpan sebagai histori.')
    } catch (reasonError) {
      setError(friendlyError(errorMessage(reasonError)))
    } finally {
      setBusy(false)
    }
  }

  function handleNewSale() {
    if (draft && cashierSession) {
      openActionDialog({
        title: 'Mulai transaksi baru?',
        description:
          `${draft.draftNo || 'Draft aktif'} akan ditutup dari editor, ` +
          'tetapi tetap tersimpan dan bisa dilanjutkan dari daftar Draft.',
        confirmLabel: 'Transaksi baru',
        tone: 'primary',
        onConfirm: executeNewSale,
      })
      return
    }
    resetSale()
  }

  async function executeNewSale() {
    if (!draft || !cashierSession) {
      resetSale()
      return
    }
    setBusy(true)
    try {
      await releaseSaleDraftLock(draft.salesId, cashierSession.id)
      await refreshSaleDrafts(cashierSession)
      resetSale()
    } catch (reason) {
      setError(friendlyError(errorMessage(reason)))
    } finally {
      setBusy(false)
    }
  }

  async function handleSaveDraft() {
    if (!isOnline) {
      setError('Mode offline belum dibuka. Sambungkan internet untuk menyimpan Draft.')
      return
    }
    setBusy(true)
    setError('')
    try {
      const saved = await persistDraft(draft)
      setPaymentLegs((current) => {
        if (current.length !== 1 || current[0].amount.trim() !== '') {
          return current
        }
        const method = catalog.paymentMethods.find(
          (item) => item.id === current[0].paymentMethodId,
        )
        const amount = String(saved.grandTotalAfterRounding)
        return [
          {
            ...current[0],
            amount,
            tenderedAmount:
              ['CASH', 'TRANSFER'].includes(method?.methodType ?? '')
                ? amount
                : current[0].tenderedAmount,
          },
        ]
      })
      setNotice(
        `Draft tersimpan. Total akhir ${money(saved.grandTotalAfterRounding)}.`,
      )
    } catch (reason) {
      setError(friendlyError(errorMessage(reason)))
    } finally {
      setBusy(false)
    }
  }

  function updatePaymentLeg(
    clientPaymentKey: string,
    patch: Partial<PaymentLeg>,
  ) {
    setPaymentLegs((current) =>
      current.map((leg) =>
        leg.clientPaymentKey === clientPaymentKey
          ? { ...leg, ...patch }
          : leg,
      ),
    )
  }

  function fillPaymentRemainder(clientPaymentKey: string) {
    if (!draft && !offlinePreview) return
    const activeLeg = paymentLegs.find(
      (leg) => leg.clientPaymentKey === clientPaymentKey,
    )
    const otherTotal = paymentLegs.reduce(
      (total, leg) =>
        leg.clientPaymentKey === clientPaymentKey
          ? total
          : total + Number(leg.amount || 0),
      0,
    )
    const amount = String(
      Math.max(0, paymentDue - otherTotal),
    )
    const method = catalog.paymentMethods.find(
      (item) => item.id === activeLeg?.paymentMethodId,
    )
    updatePaymentLeg(clientPaymentKey, {
      amount,
      ...(['CASH', 'TRANSFER'].includes(method?.methodType ?? '') &&
      (!activeLeg?.tenderedAmount ||
        activeLeg.tenderedAmount === activeLeg.amount)
        ? { tenderedAmount: amount }
        : {}),
    })
  }

  function addPaymentLeg() {
    const used = new Set(paymentLegs.map((leg) => leg.paymentMethodId))
    const nextMethod = catalog.paymentMethods.find(
      (method) =>
        method.methodType !== 'CUSTOMER_BALANCE' && !used.has(method.id),
    )
    if (!nextMethod) return
    setPaymentLegs((current) => [
      ...current,
      createPaymentLeg(nextMethod.id),
    ])
  }

  function removePaymentLeg(clientPaymentKey: string) {
    setPaymentLegs((current) =>
      current.length > 1
        ? current.filter((leg) => leg.clientPaymentKey !== clientPaymentKey)
        : current,
    )
  }

  function estimatePaymentFee(methodId: string, rawAmount: string) {
    const method = catalog.paymentMethods.find((item) => item.id === methodId)
    if (!method?.feeEnabled) return 0
    const amount = Number(rawAmount || 0)
    const percent =
      method.feeType === 'PERCENT' ||
      method.feeType === 'PERCENT_PLUS_FIXED'
        ? amount * method.feePercent / 100
        : 0
    const fixed =
      method.feeType === 'FIXED' ||
      method.feeType === 'PERCENT_PLUS_FIXED'
        ? method.feeFixedAmount
        : 0
    return Math.round((percent + fixed) * 10_000) / 10_000
  }

  function handleQueueOfflineSale() {
    if (!cashierSession || cart.length === 0) return
    if (!ODR_OFFLINE_ORDER_ENABLED) {
      setError(friendlyError('OFFLINE_ORDER_RESERVATION_NOT_AVAILABLE'))
      return
    }
    openActionDialog({
      title: 'Simpan transaksi Offline?',
      description:
        'Transaksi disimpan tetap di perangkat dan memakai cadangan stok sesi ini. Slip Offline bukan invoice final; transaksi wajib disinkronkan saat internet kembali.',
      confirmLabel: 'Simpan Offline',
      tone: 'primary',
      onConfirm: executeQueueOfflineSale,
    })
  }

  async function executeQueueOfflineSale() {
    if (
      !session ||
      !cashierSession ||
      !offlineCache ||
      !activeTerminal ||
      !activeWarehouse
    ) {
      setError(friendlyError('OFFLINE_CATALOG_CACHE_MISSING'))
      return
    }
    setBusy(true)
    setError('')
    setNotice('')
    try {
      if (draft) throw new Error('OFFLINE_EXISTING_DRAFT_REQUIRES_ONLINE')
      if (isTempo) throw new Error('OFFLINE_TEMPO_NOT_ALLOWED')
      if (cart.some((item) => item.overrideUnitPrice !== null)) {
        throw new Error('OFFLINE_PRICE_OVERRIDE_NOT_ALLOWED')
      }
      if (
        fulfillmentMode === 'DELIVERY' &&
        !deliveryRecipientName.trim()
      ) throw new Error('DELIVERY_RECIPIENT_REQUIRED')
      if (fulfillmentMode === 'DELIVERY' && !deliveryFeeInputValid) {
        throw new Error('INVALID_DELIVERY_FEE_AMOUNT')
      }
      const scope = offlineCache.snapshot
      if (
        scope.companyId !== companyId ||
        scope.storeId !== cashierSession.storeId ||
        scope.terminalId !== cashierSession.terminalId ||
        scope.warehouseId !== cashierSession.warehouseId ||
        scope.cashierSessionId !== cashierSession.id ||
        scope.cashierId !== session.user.id
      ) {
        throw new Error('OFFLINE_CATALOG_SCOPE_MISMATCH')
      }
      const offlineLines = cart.map((item) => ({
        lineKey: item.product.productUomId,
        productUomId: item.product.productUomId,
        quantity: item.quantity,
        discountType: item.discountType,
        discountInput: item.discountInput,
      }))
      const preview = priceOfflineCheckout({
        snapshot: scope,
        allowances: offlineAllowances,
        customerId,
        selectedPricelistId,
        lines: offlineLines,
        globalDiscount: Number(globalDiscount || 0),
        roundingDirection,
      })
      const salePayload = buildOfflineSalePayload({
        preview,
        clientTransactionId,
        cashierSessionId: cashierSession.id,
        lines: offlineLines,
        payments: paymentLegs,
        snapshot: scope,
        roundingDirection,
        fulfillmentMode,
        deliveryRecipientName,
        deliveryRecipientPhone,
        deliveryAddress,
        deliveryScheduledAt: deliveryScheduledAt
          ? new Date(deliveryScheduledAt).toISOString()
          : null,
        deliveryNotes,
        deliveryFeeAmount: effectiveDeliveryFee,
        deliveryFeeInvoiceDisplayMode,
      })
      const { queueOfflineSale } = await import('./lib/offline')
      const record = await queueOfflineSale({
        companyId,
        storeId: cashierSession.storeId,
        terminalId: cashierSession.terminalId,
        warehouseId: cashierSession.warehouseId,
        cashierSessionId: cashierSession.id,
        cashierId: session.user.id,
        localMasterVersion: scope.catalogVersion,
        salePayload,
      })
      const methods = new Map(
        scope.paymentMethods.map((method) => [method.id, method.name]),
      )
      setOfflineSlip({
        clientTransactionId: record.clientTransactionId,
        localTransactionAt: record.localTransactionAt,
        preview: {
          ...preview,
          totalBeforeRounding: preview.totalBeforeRounding + effectiveDeliveryFee,
          grandTotal: preview.grandTotal + effectiveDeliveryFee,
        },
        payments: salePayload.payments.map((payment) => ({
          methodName:
            methods.get(payment.paymentMethodId) ?? 'Metode pembayaran',
          amount: payment.amount,
          tenderedAmount: payment.tenderedAmount,
        })),
      })
      await loadOfflineCacheState(cashierSession.id)
      resetSale()
      setNotice(
        'Transaksi tersimpan di antrean perangkat. Sinkronkan saat internet kembali.',
      )
    } catch (reason) {
      setError(friendlyError(errorMessage(reason)))
    } finally {
      setBusy(false)
    }
  }

  async function reconcileOfflineQueueAfterSync() {
    if (!cashierSession || !session || !isOnline) return
    const { refreshOfflineCatalogSnapshot } = await import(
      './lib/offlineCatalog'
    )
    try {
      const cache = await refreshOfflineCatalogSnapshot({
        companyId,
        storeId: cashierSession.storeId,
        terminalId: cashierSession.terminalId,
        warehouseId: cashierSession.warehouseId,
        cashierSessionId: cashierSession.id,
        cashierId: session.user.id,
      })
      await retainCurrentOfflineScope(cache)
      await loadOfflineCacheState(cashierSession.id)
    } catch (reason) {
      const { invalidateOfflineCatalogSnapshot } = await import(
        './lib/offlineCatalog'
      )
      await invalidateOfflineCatalogSnapshot(
        cashierSession.id,
        'OFFLINE_SYNC_RECONCILIATION_FAILED',
      ).catch(() => undefined)
      setOfflineCache(null)
      setOfflineAllowances([])
      setOfflineCacheMessage(
        'Transaksi sudah diproses server, tetapi snapshot gagal direkonsiliasi. Cache diblokir sampai diperbarui.',
      )
      throw reason
    }
  }

  async function handleSyncOfflineSale(clientTransactionId: string) {
    if (!cashierSession || !isOnline) return
    setOfflineCacheBusy(true)
    setOfflineCacheMessage('Memeriksa transaksi Offline...')
    try {
      const { syncOfflineSale } = await import('./lib/offline')
      const stageMessage = {
        CHECKING_STATUS: 'Memeriksa status terakhir di server...',
        SUBMITTING: 'Mengirim transaksi Offline ke server...',
        PROCESSING: 'Membuat invoice dan memperbarui stok...',
        CONFIRMING_STATUS:
          'Respons lambat. Memastikan transaksi tidak diproses dua kali...',
      } as const
      const result = await syncOfflineSale(clientTransactionId, (stage) => {
        setOfflineCacheMessage(stageMessage[stage])
      })
      await loadOfflineCacheState(cashierSession.id)
      setOfflineCacheMessage(
        result.status === 'POSTED'
          ? 'Transaksi Offline sudah menjadi invoice final.'
          : `Status transaksi diperbarui: ${result.status}.`,
      )
      if (result.status === 'POSTED') {
        void reconcileOfflineQueueAfterSync().catch(() => undefined)
      }
    } catch (reason) {
      await loadOfflineCacheState(cashierSession.id).catch(() => undefined)
      setOfflineCacheMessage(friendlyError(errorMessage(reason)))
    } finally {
      setOfflineCacheBusy(false)
    }
  }

  async function handleRefreshOfflineSaleStatus(clientTransactionId: string) {
    if (!cashierSession || !isOnline) return
    setOfflineCacheBusy(true)
    setOfflineCacheMessage('')
    try {
      const { refreshOfflineSaleStatus } = await import('./lib/offline')
      const result = await refreshOfflineSaleStatus(clientTransactionId)
      await loadOfflineCacheState(cashierSession.id)
      setOfflineCacheMessage(`Status server: ${result.status}.`)
    } catch (reason) {
      setOfflineCacheMessage(friendlyError(errorMessage(reason)))
    } finally {
      setOfflineCacheBusy(false)
    }
  }

  async function handleOpenOfflineFinalReceipt(record: OfflineSaleQueueRecord) {
    if (!isOnline) return
    try {
      const acknowledgement = record.acknowledgement
        ? (JSON.parse(record.acknowledgement) as Record<string, unknown>)
        : null
      const salesId = String(
        acknowledgement?.salesId ?? acknowledgement?.saleId ?? '',
      )
      if (!salesId) throw new Error('OFFLINE_FINAL_RECEIPT_NOT_AVAILABLE')
      const finalReceipt = await loadReceipt(companyId, salesId)
      setReceipt(finalReceipt)
      try {
        const [invoice, delivery] = await Promise.all([
          loadSalesInvoiceDocument(salesId),
          loadSalesDeliveryDocument(salesId),
        ])
        setSalesDocuments({ invoice, delivery })
      } catch {
        setSalesDocuments(null)
      }
    } catch (reason) {
      setOfflineCacheMessage(friendlyError(errorMessage(reason)))
    }
  }

  async function handlePostSale() {
    await postSaleWithNegativeReason()
  }

  async function postSaleWithNegativeReason(negativeStockReason = '') {
    if (!isOnline) {
      handleQueueOfflineSale()
      return
    }
    if (!cashierSession || cart.length === 0) return
    if (customerBalanceShortfall > 0) {
      setError(
        `Saldo Customer wajib dipakai seluruhnya. Tambahkan belanja minimal ${money(customerBalanceShortfall)}.`,
      )
      return
    }
    setBusy(true)
    setError('')
    setNotice('')
    setShortages([])
    try {
      const pricedDraft = await persistDraft(draft, [], negativeStockReason)
      let finalDraft = pricedDraft
      if (!isTempo) {
        if (paymentLegs.length === 0) throw new Error('PAYMENT_LEGS_REQUIRED')
        const normalizedPayments = paymentLegs.map((leg) => {
          const method = catalog.paymentMethods.find(
            (item) => item.id === leg.paymentMethodId,
          )
          if (!method) throw new Error('ELIGIBLE_PAYMENT_METHOD_REQUIRED')
          const rawAmount = Number(leg.amount || 0)
          const automaticSinglePayment =
            paymentLegs.length === 1 && !(rawAmount > 0)
          const amount = automaticSinglePayment
            ? pricedDraft.grandTotalAfterRounding
            : rawAmount
          if (!(amount > 0)) throw new Error('PAYMENT_LEG_AMOUNT_REQUIRED')
          const supportsOverpayment = ['CASH', 'TRANSFER'].includes(
            method.methodType,
          )
          const tenderWasFollowingAmount =
            leg.tenderedAmount.trim() === '' || leg.tenderedAmount === leg.amount
          const tenderedAmount =
            supportsOverpayment
              ? automaticSinglePayment && tenderWasFollowingAmount
                ? amount
                : Number(leg.tenderedAmount || amount)
              : amount
          if (tenderedAmount < amount) {
            throw new Error('PAYMENT_TENDER_INSUFFICIENT')
          }
          const overpayment = Math.max(tenderedAmount - amount, 0)
          if (overpayment > 0 && leg.overpaymentDisposition === 'CUSTOMER_BALANCE') {
            if (!catalog.customerBalanceCreditEnabled) {
              throw new Error('CUSTOMER_BALANCE_CREDIT_DISABLED')
            }
            if (!activeCustomer || activeCustomer.isWalkIn) {
              throw new Error('CUSTOMER_BALANCE_ELIGIBLE_CUSTOMER_REQUIRED')
            }
          }
          return {
            clientPaymentKey: leg.clientPaymentKey,
            paymentMethodId: method.id,
            amount,
            tenderedAmount,
            ...(overpayment > 0
              ? { overpaymentDisposition: leg.overpaymentDisposition }
              : {}),
            ...(leg.proofUrl.trim()
              ? { proofUrl: leg.proofUrl.trim() }
              : {}),
          }
        })
        if (
          new Set(normalizedPayments.map((item) => item.paymentMethodId)).size !==
          normalizedPayments.length
        ) {
          throw new Error('DUPLICATE_PAYMENT_METHOD')
        }
        const normalizedTotal = normalizedPayments.reduce(
          (total, item) => total + item.amount,
          0,
        )
        if (
          Math.abs(normalizedTotal - pricedDraft.grandTotalAfterRounding) > 0.0001
        ) {
          throw new Error('PAYMENT_LEG_TOTAL_MISMATCH')
        }
        finalDraft = await persistDraft(
          pricedDraft,
          normalizedPayments,
          negativeStockReason,
        )
      } else {
        finalDraft = await persistDraft(pricedDraft, [], negativeStockReason)
      }

      const confirmation = await confirmSalesOrder(
        finalDraft.salesId,
        finalDraft.masterVersion,
        crypto.randomUUID(),
        negativeStockReason || null,
      )
      const orderNo = finalDraft.draftNo || String(confirmation.salesId ?? '')
      try {
        const [invoice, delivery] = await Promise.all([
          loadSalesInvoiceDocument(finalDraft.salesId),
          loadSalesDeliveryDocument(finalDraft.salesId),
        ])
        setSalesDocuments({ invoice, delivery })
      } catch {
        setSalesDocuments(null)
      }
      setConfirmedOrder({
        orderNo,
        orderRuntimeStatus: String(
          confirmation.orderRuntimeStatus ?? 'RESERVED',
        ),
        plannedOrderDate: finalDraft.plannedOrderDate,
      })
      setNotice(
        `${orderNo} dikonfirmasi. Stok dicadangkan dan menunggu proses gudang.`,
      )
      resetSale()
      await refreshCatalog(cashierSession)
      await refreshSaleDrafts(cashierSession)
      await refreshSalesOrders(cashierSession)
    } catch (reason) {
      const code = errorMessage(reason)
      if (
        !negativeStockReason &&
        code.includes('NEGATIVE_STOCK_REASON_REQUIRED')
      ) {
        setError('')
        openActionDialog({
          title: 'Otorisasi stok minus',
          description:
            'Stok tidak mencukupi, tetapi akun Anda memiliki izin exception online. Jelaskan alasan operasional. Tindakan ini diaudit dan stok masuk berikutnya akan merekonsiliasi biaya FIFO.',
          confirmLabel: 'Post dengan izin',
          tone: 'danger',
          requireReason: true,
          reasonLabel: 'Alasan stok minus',
          reasonPlaceholder:
            'Contoh: barang fisik tersedia, penerimaan supplier belum diposting',
          onConfirm: async (confirmedReason) => {
            await postSaleWithNegativeReason(confirmedReason)
          },
        })
      } else {
        setError(friendlyError(code))
      }
    } finally {
      setBusy(false)
    }
  }

  function resetSale() {
    const walkIn =
      catalog.customers.find((item) => item.isWalkIn) ?? catalog.customers[0]
    const defaultPayment =
      catalog.paymentMethods.find((item) => item.isDefault) ??
      catalog.paymentMethods[0]
    setCart([])
    setCartQuantityInputs({})
    setEditingCartProductUomId('')
    setDraft(null)
    setDraftLabel('')
    setDraftNotes('')
    setResolvedLines([])
    setShortages([])
    setCustomerId(walkIn?.id ?? '')
    setSelectedPricelistId('')
    setPaymentLegs([createPaymentLeg(defaultPayment?.id ?? '')])
    setGlobalDiscount('')
    setIsTempo(false)
    setTransactionAt(new Date().toISOString())
    setTransactionDateIsManual(false)
    setDueDate('')
    setDueDateIsManual(false)
    setRoundingDirection('NONE')
    const automaticDelivery =
      bootstrap?.deliveryDocumentCreationPolicy === 'ALL_POSTED_SALES'
    setFulfillmentMode(automaticDelivery ? 'DELIVERY' : 'PICKUP')
    setDeliveryRecipientName(
      automaticDelivery && walkIn && !walkIn.isWalkIn ? walkIn.name : '',
    )
    setDeliveryRecipientPhone(automaticDelivery ? walkIn?.phone ?? '' : '')
    setDeliveryAddress(automaticDelivery ? walkIn?.address ?? '' : '')
    setDeliveryScheduledAt('')
    setDeliveryNotes('')
    setDeliveryFeeAmount('0')
    setDeliveryFeeInvoiceDisplayMode('SHOW_SEPARATE')
    setDeliveryDetailsOpen(false)
    setProductPickerOpen(false)
    setSearch('')
    setClientTransactionId(crypto.randomUUID())
  }

  async function handlePrintInvoice() {
    if (!salesDocuments?.invoice) return
    try {
      openSalesInvoicePrint(salesDocuments.invoice)
      await recordSalesDocumentPrint(
        'SALES_INVOICE',
        salesDocuments.invoice.invoiceSnapshotId,
      )
    } catch (reason) {
      setError(
        errorMessage(reason) === 'POPUP_BLOCKED'
          ? 'Browser memblokir tab Invoice. Izinkan pop-up lalu coba lagi.'
          : friendlyError(errorMessage(reason)),
      )
    }
  }

  async function handlePrintDelivery() {
    if (!salesDocuments?.delivery) return
    try {
      openSalesDeliveryPrint(salesDocuments.delivery)
      await recordSalesDocumentPrint(
        'SALES_DELIVERY',
        salesDocuments.delivery.deliveryDocumentId,
      )
    } catch (reason) {
      setError(
        errorMessage(reason) === 'POPUP_BLOCKED'
          ? 'Browser memblokir tab Surat Jalan. Izinkan pop-up lalu coba lagi.'
          : friendlyError(errorMessage(reason)),
      )
    }
  }

  async function handlePrint() {
    if (!receipt) return
    try {
      await printer.print({
        invoiceNo: receipt.invoiceNo,
        items: receipt.lines.map((line) => ({
          product: {
            name: `${line.productName} (${line.uomName})`,
            price: line.unitPrice,
          },
          quantity: line.quantity,
          lineTotal: line.lineTotal,
        })),
        subtotal: receipt.subtotal,
        grandTotal: receipt.grandTotal,
        paidAmount: receipt.amountPaid,
        change: receipt.payments.reduce(
          (sum, payment) => sum + payment.changeAmount,
          0,
        ),
        customerBalanceCredit: receipt.payments.reduce(
          (sum, payment) =>
            sum + Number(payment.customerBalanceCreditAmount ?? 0),
          0,
        ),
        customerBalanceUsage: receipt.payments.reduce(
          (sum, payment) =>
            sum + Number(payment.customerBalanceUsageAmount ?? 0),
          0,
        ),
        paymentMethod:
          receipt.payments
            .map((payment) => payment.paymentMethodName)
            .join(' + ') || 'TEMPO',
        date: new Date(receipt.postedAt).toLocaleString('id-ID'),
      })
    } catch (reason) {
      setError(
        errorMessage(reason) === 'POPUP_BLOCKED'
          ? 'Browser memblokir tab struk. Izinkan pop-up untuk MADS POS lalu coba lagi.'
          : friendlyError(errorMessage(reason)),
      )
    }
  }

  async function handlePrintOfflineSlip() {
    if (!offlineSlip) return
    try {
      await printer.print({
        invoiceNo: `OFF-${offlineSlip.clientTransactionId
          .slice(0, 8)
          .toUpperCase()}`,
        documentLabel: 'Slip transaksi Offline',
        warning: 'BELUM TERSINKRON — BUKAN INVOICE FINAL',
        items: offlineSlip.preview.lines.map((line) => ({
          product: {
            name: `${line.productName} (${line.uomName})`,
            price: line.unitPrice,
          },
          quantity: line.quantity,
          lineTotal: line.lineTotal,
        })),
        subtotal: offlineSlip.preview.subtotal,
        grandTotal: offlineSlip.preview.grandTotal,
        paidAmount: offlineSlip.payments.reduce(
          (total, payment) => total + payment.amount,
          0,
        ),
        change: offlineSlip.payments.reduce(
          (total, payment) =>
            total + Math.max(payment.tenderedAmount - payment.amount, 0),
          0,
        ),
        paymentMethod: offlineSlip.payments
          .map((payment) => payment.methodName)
          .join(' + '),
        date: new Date(offlineSlip.localTransactionAt).toLocaleString('id-ID'),
      })
    } catch (reason) {
      setError(
        errorMessage(reason) === 'POPUP_BLOCKED'
          ? 'Browser memblokir tab Slip Offline. Izinkan pop-up lalu coba lagi.'
          : friendlyError(errorMessage(reason)),
      )
    }
  }

  async function handleLogout() {
    setBusy(true)
    setError('')
    try {
      if (draft && cashierSession) {
        await releaseSaleDraftLock(draft.salesId, cashierSession.id)
      }
      if (cashierSession) {
        const { invalidateOfflineCatalogSnapshot } = await import(
          './lib/offlineCatalog'
        )
        const { removeOfflineOperationalScope } = await import(
          './lib/offlineBootstrap'
        )
        await invalidateOfflineCatalogSnapshot(
          cashierSession.id,
          'USER_SIGNED_OUT',
        ).catch(() => undefined)
        await removeOfflineOperationalScope(cashierSession.id).catch(
          () => undefined,
        )
      }
      await signOut()
      setSession(null)
      resetSale()
    } catch (reason) {
      setError(friendlyError(errorMessage(reason)))
    } finally {
      setBusy(false)
    }
  }

  async function handleRefreshOfflineCache() {
    if (
      !session ||
      !cashierSession ||
      !companyId ||
      !activeTerminal ||
      !activeWarehouse
    ) {
      return
    }
    if (!isOnline) {
      setOfflineCacheMessage(
        'Snapshot hanya dapat diperbarui saat terhubung ke server.',
      )
      return
    }
    setOfflineCacheBusy(true)
    setOfflineCacheMessage('')
    try {
      const { refreshOfflineCatalogSnapshot } = await import(
        './lib/offlineCatalog'
      )
      const cache = await refreshOfflineCatalogSnapshot({
        companyId,
        storeId: cashierSession.storeId,
        terminalId: cashierSession.terminalId,
        warehouseId: cashierSession.warehouseId,
        cashierSessionId: cashierSession.id,
        cashierId: session.user.id,
      })
      await retainCurrentOfflineScope(cache)
      await loadOfflineCacheState(cashierSession.id)
      setOfflineCacheMessage(
        'Snapshot dan cadangan stok sudah direkonsiliasi. Checkout Offline hanya aktif bila seluruh item memiliki allowance cukup.',
      )
    } catch (reason) {
      setOfflineCacheMessage(friendlyError(errorMessage(reason)))
    } finally {
      setOfflineCacheBusy(false)
    }
  }

  function handleIssueOfflineAllowance() {
    if (!cashierSession || !offlineProductId || !isOnline) return
    const selectedProduct = offlineCache?.snapshot.productUoms.find(
      (item) => item.productId === offlineProductId,
    )
    openActionDialog({
      title: 'Minta cadangan stok Offline?',
      description:
        `Server akan menghitung jumlah cadangan untuk ${selectedProduct?.name ?? 'produk ini'} ` +
        'berdasarkan stok belum terpakai dan kebijakan Terminal. Stok aktual belum dipotong.',
      confirmLabel: 'Minta cadangan',
      tone: 'primary',
      onConfirm: async () => {
        if (!cashierSession) return
        let mutationApplied = false
        setOfflineCacheBusy(true)
        setOfflineCacheMessage('')
        try {
          const {
            issueOwnOfflineStockAllowance,
            refreshOfflineCatalogSnapshot,
          } = await import('./lib/offlineCatalog')
          const result = await issueOwnOfflineStockAllowance(
            cashierSession.id,
            offlineProductId,
          )
          mutationApplied = true
          await refreshOfflineCatalogSnapshot({
            companyId,
            storeId: cashierSession.storeId,
            terminalId: cashierSession.terminalId,
            warehouseId: cashierSession.warehouseId,
            cashierSessionId: cashierSession.id,
            cashierId: session?.user.id ?? '',
          })
          const reconciled = await loadOfflineCacheState(cashierSession.id)
          if (
            !reconciled.allowances.some(
              (item) => item.allowanceId === result.allowanceId,
            )
          ) {
            throw new Error('OFFLINE_ALLOWANCE_RECONCILIATION_FAILED')
          }
          setOfflineProductId('')
          setOfflineCacheMessage(
            result.replayed
              ? 'Cadangan sudah aktif sebelumnya dan snapshot telah diselaraskan.'
              : 'Cadangan stok berhasil dibuat dan snapshot telah diselaraskan.',
          )
        } catch (reason) {
          if (mutationApplied) {
            const { invalidateOfflineCatalogSnapshot } = await import(
              './lib/offlineCatalog'
            )
            await invalidateOfflineCatalogSnapshot(
              cashierSession.id,
              'ALLOWANCE_ISSUE_RECONCILIATION_FAILED',
            ).catch(() => undefined)
            setOfflineCache(null)
            setOfflineAllowances([])
            setOfflineProductId('')
            setOfflineCacheMessage(
              'Cadangan sudah berubah di server, tetapi snapshot gagal diperbarui. Cache diblokir; sambungkan ke server lalu perbarui snapshot.',
            )
          } else {
            setOfflineCacheMessage(friendlyError(errorMessage(reason)))
          }
        } finally {
          setOfflineCacheBusy(false)
        }
      },
    })
  }

  function handleReleaseOfflineAllowance(
    allowanceId: string,
    productId: string,
    masterVersion: number,
  ) {
    if (!cashierSession || !isOnline) return
    const availability = offlineAllowances.find(
      (item) => item.allowanceId === allowanceId,
    )
    if (!availability || availability.locallyQueuedBaseQty > 0) {
      setOfflineCacheMessage(
        'Cadangan masih dipakai antrean lokal dan belum dapat dilepaskan.',
      )
      return
    }
    const product = offlineCache?.snapshot.productUoms.find(
      (item) => item.productId === productId,
    )
    openActionDialog({
      title: 'Lepaskan cadangan stok?',
      description:
        `Cadangan ${product?.name ?? 'produk ini'} akan dikembalikan ke stok belum dicadangkan. ` +
        'Tindakan ini tidak mengubah stok aktual.',
      confirmLabel: 'Lepaskan cadangan',
      tone: 'danger',
      onConfirm: async () => {
        if (!cashierSession) return
        let mutationApplied = false
        setOfflineCacheBusy(true)
        setOfflineCacheMessage('')
        try {
          const {
            releaseOwnOfflineStockAllowance,
            refreshOfflineCatalogSnapshot,
          } = await import('./lib/offlineCatalog')
          await releaseOwnOfflineStockAllowance(allowanceId, masterVersion)
          mutationApplied = true
          await refreshOfflineCatalogSnapshot({
            companyId,
            storeId: cashierSession.storeId,
            terminalId: cashierSession.terminalId,
            warehouseId: cashierSession.warehouseId,
            cashierSessionId: cashierSession.id,
            cashierId: session?.user.id ?? '',
          })
          const reconciled = await loadOfflineCacheState(cashierSession.id)
          if (
            reconciled.allowances.some(
              (item) => item.allowanceId === allowanceId,
            )
          ) {
            throw new Error('OFFLINE_ALLOWANCE_RECONCILIATION_FAILED')
          }
          setOfflineCacheMessage(
            'Cadangan berhasil dilepaskan dan snapshot telah diselaraskan.',
          )
        } catch (reason) {
          if (mutationApplied) {
            const { invalidateOfflineCatalogSnapshot } = await import(
              './lib/offlineCatalog'
            )
            await invalidateOfflineCatalogSnapshot(
              cashierSession.id,
              'ALLOWANCE_RELEASE_RECONCILIATION_FAILED',
            ).catch(() => undefined)
            setOfflineCache(null)
            setOfflineAllowances([])
            setOfflineProductId('')
            setOfflineCacheMessage(
              'Cadangan sudah dilepaskan di server, tetapi snapshot gagal diperbarui. Cache diblokir; sambungkan ke server lalu perbarui snapshot.',
            )
          } else {
            setOfflineCacheMessage(friendlyError(errorMessage(reason)))
          }
        } finally {
          setOfflineCacheBusy(false)
        }
      },
    })
  }

  if (loading && !session) {
    return <CenteredMessage text="Memuat MADS POS…" />
  }

  if (!session) {
    return (
      <div className="min-h-screen bg-slate-950 text-slate-100 grid place-items-center p-6">
        <form
          onSubmit={handleLogin}
          className="w-full max-w-md rounded-3xl border border-slate-800 bg-slate-900 p-8 shadow-2xl"
        >
          <div className="mb-8">
            <p className="text-xs font-bold uppercase tracking-[0.24em] text-emerald-400">
              MADS POS Online
            </p>
            <h1 className="mt-2 text-3xl font-black">Masuk sebagai Kasir</h1>
            <p className="mt-2 text-sm text-slate-400">
              Gunakan akun Supabase yang memiliki assignment Cashier aktif.
            </p>
          </div>
          <label className="block text-sm font-semibold text-slate-300">
            Email
            <input
              type="email"
              required
              value={email}
              onChange={(event) => setEmail(event.target.value)}
              className="mt-2 w-full rounded-xl border border-slate-700 bg-slate-950 px-4 py-3 outline-none focus:border-emerald-500"
            />
          </label>
          <label className="mt-4 block text-sm font-semibold text-slate-300">
            Password
            <input
              type="password"
              required
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              className="mt-2 w-full rounded-xl border border-slate-700 bg-slate-950 px-4 py-3 outline-none focus:border-emerald-500"
            />
          </label>
          {error && <InlineAlert tone="error" text={error} />}
          <button
            disabled={busy}
            className="mt-6 flex w-full items-center justify-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 font-bold text-slate-950 disabled:opacity-50"
          >
            <LogIn className="h-5 w-5" />
            {busy ? 'Memproses…' : 'Masuk'}
          </button>
        </form>
      </div>
    )
  }

  if (companies.length === 0) {
    return (
      <div className="grid min-h-screen place-items-center bg-slate-950 p-6 text-slate-100">
        <div className="w-full max-w-md rounded-3xl border border-slate-800 bg-slate-900 p-8 text-center shadow-2xl">
          <AlertTriangle className="mx-auto h-10 w-10 text-amber-400" />
          <h1 className="mt-4 text-xl font-black">Tidak memiliki akses perusahaan</h1>
          <p className="mt-2 text-sm leading-6 text-slate-400">
            Akun ini tidak dapat membuka Company mana pun. Hubungi administrator
            untuk mendapatkan akses.
          </p>
          <button
            type="button"
            onClick={() => void handleLogout()}
            className="mt-6 inline-flex min-h-11 items-center justify-center gap-2 rounded-xl bg-emerald-500 px-5 text-sm font-black text-slate-950"
          >
            <LogOut className="h-4 w-4" />
            Keluar
          </button>
        </div>
      </div>
    )
  }

  const editingCartItem = cart.find(
    (item) => item.product.productUomId === editingCartProductUomId,
  )
  const editingResolvedLine = editingCartItem
    ? resolvedLines.find(
        (line) => line.lineKey === editingCartItem.product.productUomId,
      )
    : undefined
  const editingLivePreview = editingCartItem
    ? pricePreviewByProductUom.get(editingCartItem.product.productUomId)
    : undefined
  const editingCanonicalUnitPrice = editingCartItem
    ? editingResolvedLine?.canonicalUnitPrice ??
      editingLivePreview?.unitPrice ??
      editingCartItem.product.fallbackPrice
    : 0
  const editingEffectiveUnitPrice = editingCartItem
    ? editingCartItem.overrideUnitPrice ??
      editingResolvedLine?.unitPrice ??
      editingCanonicalUnitPrice
    : 0
  const editingOverrideApplied = Boolean(
    editingCartItem &&
      (editingCartItem.overrideUnitPrice !== null ||
        editingResolvedLine?.priceOverrideApplied),
  )

  return (
    <div
      className={`pos-shell min-h-screen bg-slate-950 text-slate-100 ${
        cashierSession && workspaceLayout === 'CATALOG'
          ? 'is-catalog-shell'
          : ''
      }`}
    >
      <header className="pos-topbar sticky top-0 z-30 border-b border-slate-800 bg-slate-950/95 px-4 py-3 backdrop-blur">
        <div className="flex w-full flex-wrap items-center gap-3">
          <div className="pos-brand mr-auto">
            <h1 className="text-xl font-black">MADS POS</h1>
            <p className="text-xs text-slate-400">
              {cashierSession
                ? `${cashierSession.code} · ${activeTerminal?.name ?? 'Terminal'}`
                : 'Sesi kasir belum dibuka'}
            </p>
          </div>
          {companies.length > 1 ? (
            <select
              value={companyId}
              disabled={busy || Boolean(cashierSession)}
              onChange={(event) => handleCompanyChange(event.target.value)}
              className="pos-company-select rounded-xl border border-slate-700 bg-slate-900 px-3 py-2 text-sm"
              aria-label="Pilih Company aktif"
            >
              {companies.map((company) => (
                <option key={company.id} value={company.id}>
                  {company.name}
                </option>
              ))}
            </select>
          ) : (
            <span className="pos-single-company-name">
              {activeCompany?.name}
            </span>
          )}
          <div
            className={`pos-network-status flex items-center gap-2 rounded-xl border px-3 py-2 text-sm ${
              isOnline
                ? 'border-emerald-900 bg-emerald-950 text-emerald-300'
                : 'border-rose-900 bg-rose-950 text-rose-300'
            }`}
          >
            {isOnline ? <Wifi className="h-4 w-4" /> : <WifiOff className="h-4 w-4" />}
            {isOnline
              ? 'Online'
              : offlineCache
                ? 'Offline · cache tersedia'
                : 'Offline belum siap'}
          </div>
          {cashierSession && (
            <div
              className="pos-header-layout-switcher"
              aria-label="Pilihan tampilan POS"
            >
              <button
                type="button"
                className={workspaceLayout === 'CATALOG' ? 'is-active' : ''}
                aria-pressed={workspaceLayout === 'CATALOG'}
                title="Gunakan tampilan Katalog"
                onClick={() => setWorkspaceLayout('CATALOG')}
              >
                <Package className="h-4 w-4" />
                <span>Katalog</span>
              </button>
              <button
                type="button"
                className={workspaceLayout === 'COMPACT' ? 'is-active' : ''}
                aria-pressed={workspaceLayout === 'COMPACT'}
                title="Gunakan tampilan Compact"
                onClick={() => setWorkspaceLayout('COMPACT')}
              >
                <ClipboardList className="h-4 w-4" />
                <span>Compact</span>
              </button>
            </div>
          )}
          {cashierSession && terminalFeatureVisible('SALES_RETURN') && (
            <button
              type="button"
              onClick={() => setSalesReturnOpen(true)}
              disabled={!isOnline}
              className="pos-top-action rounded-xl border border-slate-700 bg-slate-900 p-2"
              title={isOnline ? 'Buat Return Penjualan' : 'Return memerlukan koneksi online'}
            >
              <RotateCcw className="h-5 w-5" />
              <span className="pos-action-label">Return</span>
            </button>
          )}
          {cashierSession && catalog.expenseEnabled && terminalFeatureVisible('EXPENSE') && (
            <button
              type="button"
              onClick={() => setExpenseRequestOpen(true)}
              disabled={!isOnline}
              className="pos-top-action rounded-xl border border-slate-700 bg-slate-900 p-2"
              title={isOnline ? 'Ajukan Expense operasional' : 'Expense memerlukan koneksi online'}
            >
              <Banknote className="h-5 w-5" />
              <span className="pos-action-label">Expense</span>
            </button>
          )}
          {cashierSession && terminalFeatureVisible('STOCK_REQUEST') && (
            <button type="button" onClick={() => setStockRequestOpen(true)} disabled={!isOnline} className="pos-top-action rounded-xl border border-slate-700 bg-slate-900 p-2" title={isOnline ? 'Buat Permintaan Stok' : 'Permintaan Stok memerlukan koneksi online'}>
              <ClipboardList className="h-5 w-5" /><span className="pos-action-label">Minta Stok</span>
            </button>
          )}
          {cashierSession && terminalFeatureVisible('GOODS_RECEIPT') && (
            <button type="button" onClick={() => setGoodsReceiptOpen(true)} disabled={!isOnline} className="pos-top-action rounded-xl border border-slate-700 bg-slate-900 p-2" title={isOnline ? 'Terima barang dari Supplier Order' : 'Penerimaan barang memerlukan koneksi online'}>
              <Package className="h-5 w-5" /><span className="pos-action-label">Terima Barang</span>
            </button>
          )}
          {cashierSession && terminalFeatureVisible('PURCHASE_RETURN') && (
            <button type="button" onClick={() => setPurchaseReturnOpen(true)} disabled={!isOnline} className="pos-top-action rounded-xl border border-slate-700 bg-slate-900 p-2" title={isOnline ? 'Buat draft retur barang ke Supplier' : 'Retur Pembelian memerlukan koneksi online'}>
              <PackageMinus className="h-5 w-5" /><span className="pos-action-label">Retur Supplier</span>
            </button>
          )}
          {cashierSession && terminalFeatureVisible('STOCK_OPNAME') && (
            <button type="button" onClick={() => setStockOpnameOpen(true)} disabled={!isOnline} className="pos-top-action rounded-xl border border-slate-700 bg-slate-900 p-2" title={isOnline ? 'Buka blind count Stock Opname' : 'Stock Opname memerlukan koneksi online'}>
              <ClipboardCheck className="h-5 w-5" /><span className="pos-action-label">Opname</span>
            </button>
          )}
          {activeTerminal && terminalFeatureVisible('CASH_DEPOSIT') && (
            <button
              type="button"
              onClick={() => setCashDepositOpen(true)}
              disabled={!isOnline}
              className="pos-top-action rounded-xl border border-slate-700 bg-slate-900 p-2"
              title={isOnline ? 'Buat Setor Kas dari sesi yang sudah ditutup' : 'Setor Kas memerlukan koneksi online'}
            >
              <BanknoteArrowUp className="h-5 w-5" />
              <span className="pos-action-label">Setor Kas</span>
            </button>
          )}
          {cashierSession && terminalFeatureVisible('OFFLINE') && (
            <button
              type="button"
              onClick={() => setOfflinePanelOpen(true)}
              className="pos-top-action pos-offline-menu-trigger rounded-xl border border-slate-700 bg-slate-900 p-2"
              title="Lihat status Offline"
              aria-label="Buka status Offline"
            >
              <span className="pos-offline-menu-icon">
                <Database className="h-5 w-5" />
                <span
                  className={`pos-offline-menu-dot ${
                    offlineCache ? 'is-cached' : 'is-blocked'
                  }`}
                />
              </span>
              <span className="pos-action-label">Offline</span>
            </button>
          )}
          <button
            onClick={async () => {
              setIsPrinterConnected(await printer.connect())
            }}
            className="pos-top-action rounded-xl border border-slate-700 bg-slate-900 p-2"
            title={isPrinterConnected ? 'Printer terhubung' : 'Hubungkan printer'}
          >
            <Printer
              className={`h-5 w-5 ${
                isPrinterConnected ? 'text-emerald-400' : 'text-slate-400'
              }`}
            />
            <span className="pos-action-label">
              {isPrinterConnected ? 'Printer siap' : 'Hubungkan printer'}
            </span>
          </button>
          {cashierSession && (
            <button
              type="button"
              onClick={handleCloseSession}
              disabled={busy}
              className="pos-top-action pos-close-session-trigger rounded-xl p-2"
              title="Tutup sesi kasir"
            >
              <Clock3 className="h-5 w-5" />
              <span className="pos-action-label">Tutup Sesi</span>
            </button>
          )}
          <button
            onClick={handleLogout}
            disabled={busy}
            className="pos-top-action rounded-xl border border-slate-700 bg-slate-900 p-2"
            title="Keluar"
          >
            <LogOut className="h-5 w-5" />
            <span className="pos-action-label">Keluar</span>
          </button>
        </div>
      </header>

      <main className="pos-main p-3 sm:p-4">
        {error && <InlineAlert tone="error" text={error} />}
        {notice && <InlineAlert tone="success" text={notice} />}

        {!cashierSession ? (
          <SessionOpenPanel
            bootstrap={bootstrap}
            terminalId={terminalId}
            warehouseId={warehouseId}
            openingCash={openingCash}
            availableWarehouses={availableWarehouses}
            busy={busy}
            onTerminalChange={setTerminalId}
            onWarehouseChange={setWarehouseId}
            onOpeningCashChange={setOpeningCash}
            onSubmit={handleOpenSession}
          />
        ) : (
          <div
            className={`pos-workspace grid gap-3 ${
              workspaceLayout === 'COMPACT'
                ? 'is-compact-layout'
                : 'is-catalog-layout'
            }`}
          >
            <section className="pos-catalog min-w-0 rounded-2xl border border-slate-800 bg-slate-900/60 p-3 sm:p-4">
              {workspaceLayout === 'COMPACT' ? (
                <>
              <div className="pos-panel-heading">
                <div>
                  <p className="pos-eyebrow">Transaksi aktif</p>
                  <h2>Produk & keranjang</h2>
                </div>
                <span>{cart.length} item dipilih</span>
              </div>
              <div className="pos-product-picker-row">
                <div className="pos-product-picker">
                  <button
                    type="button"
                    className="pos-product-picker-trigger"
                    aria-expanded={productPickerOpen}
                    aria-controls="pos-product-picker-menu"
                    onClick={() => setProductPickerOpen((current) => !current)}
                  >
                    <span className="pos-product-picker-trigger-icon">
                      <Plus className="h-5 w-5" />
                    </span>
                    <span>
                      <strong>Tambah produk</strong>
                      <small>Cari nama, SKU, barcode, atau satuan</small>
                    </span>
                    <ChevronDown
                      className={`h-5 w-5 ${productPickerOpen ? 'is-open' : ''}`}
                    />
                  </button>
                  {productPickerOpen && (
                    <>
                      <button
                        type="button"
                        className="pos-product-picker-backdrop"
                        aria-label="Tutup pilihan produk"
                        onClick={() => setProductPickerOpen(false)}
                      />
                      <div
                        id="pos-product-picker-menu"
                        className="pos-product-picker-menu"
                      >
                        <div className="pos-product-picker-search">
                          <Search className="h-5 w-5" />
                          <input
                            autoFocus
                            value={search}
                            onChange={(event) => setSearch(event.target.value)}
                            placeholder="Ketik nama, SKU, barcode, atau satuan..."
                          />
                        </div>
                        <div className="pos-category-tabs">
                          {categories.map((item) => (
                            <button
                              type="button"
                              key={item}
                              onClick={() => setCategory(item)}
                              className={`whitespace-nowrap rounded-full px-4 py-2 text-sm ${
                                category === item
                                  ? 'bg-emerald-500 font-bold text-slate-950'
                                  : 'border border-slate-700 bg-slate-950 text-slate-300'
                              }`}
                            >
                              {item}
                            </button>
                          ))}
                        </div>
                        <div className="pos-product-picker-results">
                          {filteredProducts.length === 0 ? (
                            <div className="pos-product-picker-empty">
                              <Package className="h-8 w-8" />
                              <p>Produk tidak ditemukan.</p>
                            </div>
                          ) : (
                            filteredProducts.map((product) => {
                              const preview = pricePreviewByProductUom.get(
                                product.productUomId,
                              )
                              return (
                                <button
                                  type="button"
                                  key={product.productUomId}
                                  className="pos-product-picker-option"
                                  onClick={() => {
                                    addToCart(product)
                                    setProductPickerOpen(false)
                                    setSearch('')
                                  }}
                                >
                                  <span className="pos-product-picker-product">
                                    <strong>{product.name}</strong>
                                    <small>
                                      {product.sku} · {product.categoryName} ·{' '}
                                      {product.uomName}
                                    </small>
                                  </span>
                                  <span className="pos-product-picker-meta">
                                    <strong>
                                      {money(preview?.unitPrice ?? product.fallbackPrice)}
                                    </strong>
                                    <small>
                                      {product.availableQuantity === null
                                        ? 'Stok dicek server'
                                        : `Stok ± ${product.availableQuantity} ${product.uomName}`}
                                    </small>
                                  </span>
                                  <Plus className="h-5 w-5" />
                                </button>
                              )
                            })
                          )}
                        </div>
                        {pricePreviewLoading && (
                          <p className="pos-product-picker-status">
                            Memuat harga Pricelist terbaru...
                          </p>
                        )}
                      </div>
                    </>
                  )}
                </div>
                <button
                  type="button"
                  disabled={loading}
                  onClick={() => refreshCatalog(cashierSession)}
                  className="pos-secondary-button flex items-center gap-2 rounded-xl border border-slate-700 bg-slate-950 px-3 py-2.5 text-sm"
                >
                  <RefreshCw className="h-4 w-4" />
                  Stok terbaru
                </button>
              </div>
                </>
              ) : (
                <>
                  <div className="pos-panel-heading">
                    <div>
                      <p className="pos-eyebrow">Katalog</p>
                      <h2>Pilih produk</h2>
                    </div>
                    <span>{filteredProducts.length} item</span>
                  </div>
                  <div className="pos-search-row mb-4 flex flex-wrap items-center gap-3">
                    <div className="relative min-w-[260px] flex-1">
                      <Search className="absolute left-3 top-3 h-5 w-5 text-slate-500" />
                      <input
                        value={search}
                        onChange={(event) => setSearch(event.target.value)}
                        placeholder="Cari nama, SKU, barcode, atau satuan..."
                        className="w-full rounded-xl border border-slate-700 bg-slate-950 py-2.5 pl-10 pr-3 outline-none focus:border-emerald-500"
                      />
                    </div>
                    <button
                      type="button"
                      disabled={loading}
                      onClick={() => refreshCatalog(cashierSession)}
                      className="pos-secondary-button flex items-center gap-2 rounded-xl border border-slate-700 bg-slate-950 px-3 py-2.5 text-sm"
                    >
                      <RefreshCw className="h-4 w-4" />
                      Stok terbaru
                    </button>
                  </div>
                  <div className="pos-category-tabs mb-4 flex gap-2 overflow-x-auto pb-1">
                    {categories.map((item) => (
                      <button
                        type="button"
                        key={item}
                        onClick={() => setCategory(item)}
                        className={`whitespace-nowrap rounded-full px-4 py-2 text-sm ${
                          category === item
                            ? 'bg-emerald-500 font-bold text-slate-950'
                            : 'border border-slate-700 bg-slate-950 text-slate-300'
                        }`}
                      >
                        {item}
                      </button>
                    ))}
                  </div>
                  <div className="pos-product-grid grid gap-2.5">
                    {filteredProducts.length === 0 ? (
                      <div className="pos-product-picker-empty">
                        <Package className="h-10 w-10" />
                        <p>Produk tidak ditemukan.</p>
                      </div>
                    ) : (
                      filteredProducts.map((product) => {
                        const preview = pricePreviewByProductUom.get(
                          product.productUomId,
                        )
                        return (
                          <button
                            type="button"
                            key={product.productUomId}
                            onClick={() => addToCart(product)}
                            className="pos-product-card rounded-2xl border border-slate-800 bg-slate-950 p-3 text-left transition hover:border-emerald-700"
                          >
                            <div className="flex items-start justify-between gap-2">
                              <div>
                                <p className="text-xs text-slate-500">{product.sku}</p>
                                <h3 className="mt-1 font-bold">{product.name}</h3>
                              </div>
                              <span className="pos-add-icon">
                                <Plus className="h-5 w-5 text-emerald-400" />
                              </span>
                            </div>
                            <p className="mt-2 text-xs text-slate-400">
                              {product.categoryName} · {product.uomName}
                            </p>
                            <p className="mt-3 font-black text-emerald-400">
                              {money(preview?.unitPrice ?? product.fallbackPrice)}
                              <span className="ml-1 text-[10px] font-normal text-slate-500">
                                {pricePreviewLoading
                                  ? 'memuat harga'
                                  : preview?.pricelistName ??
                                    (preview ? 'harga server' : 'fallback')}
                              </span>
                            </p>
                            <p className="mt-1 text-xs text-slate-400">
                              {product.availableQuantity === null
                                ? 'Bundle: stok dicek server'
                                : `Tersedia ± ${product.availableQuantity} ${product.uomName}`}
                            </p>
                          </button>
                        )
                      })
                    )}
                  </div>
                </>
              )}
            </section>

            <div className="pos-order-column">
            <section className="pos-cart-panel min-w-0">
              <div className="pos-order-head flex items-center justify-between border-b border-slate-800 pb-3">
                <div>
                  <p className="pos-eyebrow">Pesanan aktif</p>
                  <h2 className="flex items-center gap-2 text-lg font-black">
                    <ShoppingCart className="h-5 w-5 text-emerald-400" />
                    Keranjang
                    <span className="pos-cart-count">{cart.length}</span>
                  </h2>
                </div>
                <div className="flex items-center gap-2">
                  <button
                    onClick={() => {
                      void refreshSalesOrders(cashierSession)
                      setOrderPanelOpen(true)
                    }}
                    className="pos-draft-list-button"
                  >
                    <ClipboardList className="h-4 w-4" />
                    Order <span>{salesOrders.filter((order) => order.orderRuntimeStatus !== 'DELIVERED').length}</span>
                  </button>
                  <button
                    onClick={() => {
                      void refreshSaleDrafts(cashierSession)
                      setDraftPanelOpen(true)
                    }}
                    className="pos-draft-list-button"
                  >
                    <FileText className="h-4 w-4" />
                    Draft <span>{saleDrafts.length}</span>
                  </button>
                  <button
                    onClick={handleNewSale}
                    className="pos-clear-button text-xs text-rose-400"
                  >
                    {draft ? 'Transaksi baru' : 'Kosongkan'}
                  </button>
                </div>
              </div>
              <div
                className={`pos-cart-list overflow-y-auto py-3 ${
                  workspaceLayout === 'CATALOG' ? 'space-y-2.5' : ''
                }`}
              >
                {cart.length === 0 ? (
                  <div className="grid place-items-center py-12 text-center text-slate-500">
                    <Package className="mb-2 h-10 w-10" />
                    <p>Belum ada barang.</p>
                  </div>
                ) : (
                  cart.map((item) => {
                    const resolved = resolvedLines.find(
                      (line) => line.lineKey === item.product.productUomId,
                    )
                    const livePreview = pricePreviewByProductUom.get(
                      item.product.productUomId,
                    )
                    const canonicalUnitPrice = resolved?.canonicalUnitPrice ??
                      livePreview?.unitPrice ?? item.product.fallbackPrice
                    const effectiveUnitPrice = item.overrideUnitPrice ??
                      resolved?.unitPrice ?? canonicalUnitPrice
                    const overrideApplied = item.overrideUnitPrice !== null ||
                      Boolean(resolved?.priceOverrideApplied)
                    if (workspaceLayout === 'CATALOG') {
                      return (
                        <div
                          key={item.product.productUomId}
                          className="pos-cart-item pos-catalog-cart-item rounded-xl border border-slate-800 bg-slate-950 p-3"
                        >
                          <div className="pos-catalog-cart-row">
                            <div className="pos-catalog-cart-product">
                              <p title={item.product.name}>{item.product.name}</p>
                              {(overrideApplied ||
                                (item.discountType &&
                                  item.discountInput > 0)) && (
                                <div className="pos-catalog-cart-notes">
                                  {overrideApplied && <span>Harga diubah</span>}
                                  {item.discountType &&
                                    item.discountInput > 0 && (
                                      <span>
                                        Diskon{' '}
                                        {item.discountType === 'PERCENT'
                                          ? `${item.discountInput}%`
                                          : money(item.discountInput)}
                                      </span>
                                    )}
                                </div>
                              )}
                            </div>
                            <strong className="pos-catalog-cart-quantity">
                              {item.quantity} {item.product.uomName}
                            </strong>
                            <button
                              type="button"
                              onClick={() =>
                                setEditingCartProductUomId(
                                  item.product.productUomId,
                                )
                              }
                              className="pos-cart-edit-button"
                              aria-label={`Edit ${item.product.name}`}
                            >
                              <Pencil className="h-4 w-4" />
                              Edit
                            </button>
                          </div>
                          <div className="pos-catalog-cart-hidden mt-3 flex items-center gap-2">
                            <button
                              onClick={() => adjustCartQuantity(item, -1)}
                              className="pos-cart-icon-button"
                              aria-label={`Kurangi jumlah ${item.product.name}`}
                              title="Kurangi jumlah"
                            >
                              <Minus className="h-4 w-4" />
                            </button>
                            <input
                              type="number"
                              min="0"
                              step={
                                item.product.allowDecimal
                                  ? 10 ** -item.product.decimalPrecision
                                  : 1
                              }
                              value={
                                cartQuantityInputs[
                                  item.product.productUomId
                                ] ?? String(item.quantity)
                              }
                              onChange={(event) =>
                                changeCartQuantityInput(item, event.target.value)
                              }
                              onBlur={() => commitCartQuantityInput(item)}
                              className="w-20 rounded-lg border border-slate-700 bg-slate-900 px-2 py-1.5 text-center"
                            />
                            <button
                              onClick={() => adjustCartQuantity(item, 1)}
                              className="pos-cart-icon-button"
                              aria-label={`Tambah jumlah ${item.product.name}`}
                              title="Tambah jumlah"
                            >
                              <Plus className="h-4 w-4" />
                            </button>
                            <span className="ml-auto font-bold">
                              {money(
                                resolved?.lineTotal ??
                                  effectiveUnitPrice * item.quantity,
                              )}
                            </span>
                          </div>
                          {isOnline &&
                            (activeTerminal?.allowPriceOverride ||
                              item.overrideUnitPrice !== null) && (
                              <div
                                className={`pos-catalog-cart-hidden mt-2 rounded-lg border p-2.5 ${overrideApplied ? 'border-amber-500/50 bg-amber-500/10' : 'border-slate-700 bg-slate-900'}`}
                              >
                                <div className="flex items-center justify-between gap-3">
                                  <label className="text-xs font-bold text-slate-300">
                                    Harga jual / {item.product.uomName}
                                  </label>
                                  {overrideApplied && (
                                    <button
                                      type="button"
                                      onClick={() =>
                                        updateCart(
                                          item.product.productUomId,
                                          { overrideUnitPrice: null },
                                        )
                                      }
                                      className="text-[11px] font-black text-amber-300 hover:text-amber-200"
                                    >
                                      Kembalikan ke Pricelist
                                    </button>
                                  )}
                                </div>
                                <div className="mt-2 grid grid-cols-[minmax(0,1fr)_auto] items-center gap-3">
                                  <CurrencyInput
                                    value={
                                      item.overrideUnitPrice ??
                                      canonicalUnitPrice
                                    }
                                    onValueChange={(value) =>
                                      updateCart(
                                        item.product.productUomId,
                                        {
                                          overrideUnitPrice: Number(value || 0),
                                        },
                                      )
                                    }
                                    disabled={
                                      !activeTerminal?.allowPriceOverride
                                    }
                                    className="w-full rounded-lg border border-slate-700 bg-slate-950 px-2 py-1.5 text-sm font-bold"
                                  />
                                  <span
                                    className={`rounded-full px-2 py-1 text-[10px] font-black uppercase ${overrideApplied ? 'bg-amber-400 text-amber-950' : 'bg-slate-800 text-slate-400'}`}
                                  >
                                    {overrideApplied
                                      ? 'Harga diubah'
                                      : 'Pricelist'}
                                  </span>
                                </div>
                                {overrideApplied && (
                                  <p className="mt-1.5 text-[11px] text-amber-200">
                                    Harga Pricelist semula{' '}
                                    {money(canonicalUnitPrice)}.
                                  </p>
                                )}
                                {!activeTerminal?.allowPriceOverride &&
                                  item.overrideUnitPrice !== null && (
                                    <p className="mt-1.5 text-[11px] font-bold text-rose-300">
                                      Izin Terminal sudah nonaktif. Kembalikan
                                      ke Pricelist sebelum menyimpan atau Post.
                                    </p>
                                  )}
                              </div>
                            )}
                          <div className="pos-catalog-cart-hidden mt-2 grid grid-cols-[1fr_100px] gap-2">
                            <select
                              value={item.discountType}
                              onChange={(event) =>
                                updateCart(item.product.productUomId, {
                                  discountType: event.target.value as
                                    | ''
                                    | 'AMOUNT'
                                    | 'PERCENT',
                                })
                              }
                              className="rounded-lg border border-slate-700 bg-slate-900 px-2 py-1.5 text-xs"
                            >
                              <option value="">Tanpa diskon line</option>
                              <option value="AMOUNT">Diskon nominal</option>
                              <option value="PERCENT">Diskon persen</option>
                            </select>
                            {item.discountType === 'AMOUNT' ? (
                              <CurrencyInput
                                value={item.discountInput}
                                onValueChange={(value) =>
                                  updateCart(item.product.productUomId, {
                                    discountInput: Number(value || 0),
                                  })
                                }
                                className="rounded-lg border border-slate-700 bg-slate-900 px-2 py-1.5 text-xs disabled:opacity-40"
                              />
                            ) : (
                              <input
                                type="number"
                                min="0"
                                disabled={!item.discountType}
                                value={item.discountInput}
                                onChange={(event) =>
                                  updateCart(item.product.productUomId, {
                                    discountInput: Number(event.target.value),
                                  })
                                }
                                className="rounded-lg border border-slate-700 bg-slate-900 px-2 py-1.5 text-xs disabled:opacity-40"
                              />
                            )}
                          </div>
                        </div>
                      )
                    }
                    return (
                      <div
                        key={item.product.productUomId}
                        className="pos-cart-item rounded-xl border border-slate-800 bg-slate-950 p-3"
                      >
                        <div className="pos-cart-item-summary">
                          <div className="min-w-0">
                            <p className="pos-cart-item-name" title={item.product.name}>
                              {item.product.name}
                            </p>
                            <p className="pos-cart-item-quantity">
                              {item.quantity} {item.product.uomName}
                            </p>
                          </div>
                          <strong className="pos-cart-item-total">
                            {money(
                              resolved?.lineTotal ??
                                effectiveUnitPrice * item.quantity,
                            )}
                          </strong>
                        </div>
                        <div className="pos-cart-item-notes">
                          {item.discountType && item.discountInput > 0 && (
                            <span>
                              Diskon{' '}
                              {item.discountType === 'PERCENT'
                                ? `${item.discountInput}%`
                                : money(item.discountInput)}
                            </span>
                          )}
                          {overrideApplied && <span>Harga diubah</span>}
                          {!item.discountType && !overrideApplied && (
                            <span>
                              {money(effectiveUnitPrice)} / {item.product.uomName}
                            </span>
                          )}
                        </div>
                        <button
                          type="button"
                          className="pos-cart-edit-button"
                          onClick={() =>
                            setEditingCartProductUomId(
                              item.product.productUomId,
                            )
                          }
                        >
                          <Pencil className="h-4 w-4" />
                          Edit
                        </button>
                      </div>
                    )
                  })
                )}
              </div>
            </section>

            <aside className="pos-checkout rounded-2xl border border-slate-800 bg-slate-900 p-3 sm:p-4">
              <div className="pos-checkout-heading">
                <div>
                  <p className="pos-eyebrow">Detail transaksi</p>
                  <h2>Pembayaran & penyelesaian</h2>
                </div>
                <span>{draft ? draft.draftNo : 'Transaksi baru'}</span>
              </div>
              <div className="pos-checkout-form space-y-3 border-t border-slate-800 pt-3">
                <div className="pos-draft-meta-grid">
                  <label className="block text-xs font-semibold text-slate-400">
                    Nama Draft (opsional)
                    <input
                      value={draftLabel}
                      maxLength={80}
                      onChange={(event) => setDraftLabel(event.target.value)}
                      placeholder="Contoh: Pesanan meja 4"
                      className="mt-1 w-full px-3 py-2 text-sm"
                    />
                  </label>
                  <label className="block text-xs font-semibold text-slate-400">
                    Catatan Draft (opsional)
                    <input
                      value={draftNotes}
                      maxLength={500}
                      onChange={(event) => setDraftNotes(event.target.value)}
                      placeholder="Catatan untuk kasir berikutnya"
                      className="mt-1 w-full px-3 py-2 text-sm"
                    />
                  </label>
                </div>
                <div className="pos-section-heading">
                  <span>1</span>
                  <div>
                    <strong>Pelanggan & harga</strong>
                    <small>Pricelist mengikuti pelanggan dan dapat diganti.</small>
                  </div>
                </div>
                <div className="block text-xs font-semibold text-slate-400">
                  <span className="pos-customer-field-heading">
                    <span>Customer</span>
                    <button
                      type="button"
                      onClick={() => setQuickCustomerOpen(true)}
                      className="pos-customer-add-button"
                    >
                      <UserPlus className="h-4 w-4" />
                      Customer baru
                    </button>
                  </span>
                  <select
                    aria-label="Customer"
                    value={customerId}
                    onChange={(event) => selectCustomer(event.target.value)}
                    className="mt-1 w-full rounded-lg border border-slate-700 bg-slate-950 px-3 py-2 text-sm text-slate-100"
                  >
                    {catalog.customers.map((customer) => (
                      <option key={customer.id} value={customer.id}>
                        {customer.name}
                        {customer.isWalkIn ? ' · Umum' : ''}
                      </option>
                    ))}
                  </select>
                  {activeCustomer && !activeCustomer.isWalkIn && (
                    <div className="pos-customer-balance-line">
                      <span>Saldo Customer</span>
                      <strong>{money(activeCustomer.currentBalance)}</strong>
                    </div>
                  )}
                </div>
                <label className="block text-xs font-semibold text-slate-400">
                  Pricelist
                  <select
                    value={selectedPricelistId}
                    onChange={(event) => {
                      setSelectedPricelistId(event.target.value)
                      setResolvedLines([])
                    }}
                    className="mt-1 w-full rounded-lg border border-slate-700 bg-slate-950 px-3 py-2 text-sm text-slate-100"
                  >
                    <option value="">
                      Otomatis · {automaticPricelist?.name ?? 'Harga dasar produk'}
                    </option>
                    {eligiblePricelists.map((pricelist) => (
                      <option key={pricelist.id} value={pricelist.id}>
                        {pricelist.name}
                        {pricelist.scope === 'CUSTOMER'
                          ? ' · Khusus customer'
                          : ' · Global'}
                      </option>
                    ))}
                  </select>
                  <span className="mt-1 block text-[11px] font-normal text-slate-500">
                    Default mengikuti Customer. Override hanya berlaku untuk
                    transaksi ini.
                  </span>
                  {pricePreviewError && (
                    <span className="mt-1 block text-[11px] font-semibold text-amber-400">
                      Preview harga belum tersedia: {pricePreviewError}
                    </span>
                  )}
                </label>
                <div className="pos-section-heading">
                  <span>2</span>
                  <div>
                    <strong>Aturan transaksi</strong>
                    <small>Diskon, pembulatan, dan penjualan tempo.</small>
                  </div>
                </div>
                <div className="grid grid-cols-2 gap-2">
                  <label className="text-xs font-semibold text-slate-400">
                    Diskon transaksi
                    <CurrencyInput
                      value={globalDiscount}
                      onValueChange={(value) => {
                        setGlobalDiscount(value)
                        setResolvedLines([])
                      }}
                      className="mt-1 w-full rounded-lg border border-slate-700 bg-slate-950 px-3 py-2 text-sm"
                    />
                  </label>
                  <label className="text-xs font-semibold text-slate-400">
                    Pembulatan Rp100
                    <select
                      value={roundingDirection}
                      onChange={(event) => {
                        setRoundingDirection(
                          event.target.value as 'NONE' | 'DOWN' | 'UP',
                        )
                        setResolvedLines([])
                      }}
                      className="mt-1 w-full rounded-lg border border-slate-700 bg-slate-950 px-2 py-2 text-sm"
                    >
                      <option value="NONE">Tanpa pembulatan</option>
                      <option value="DOWN">Ke bawah</option>
                      <option value="UP">Ke atas</option>
                    </select>
                  </label>
                </div>
                <label className="flex items-center gap-2 rounded-xl border border-slate-800 p-3 text-sm">
                  <input
                    type="checkbox"
                    checked={isTempo}
                    onChange={(event) => toggleTempo(event.target.checked)}
                  />
                  Transaksi TEMPO
                </label>
                <div className="pos-delivery-confirmation">
                  <label className="pos-delivery-toggle">
                    <input
                      type="checkbox"
                      checked={fulfillmentMode === 'DELIVERY'}
                      onChange={(event) =>
                        selectFulfillmentMode(
                          event.target.checked ? 'DELIVERY' : 'PICKUP',
                        )
                      }
                    />
                    <span>
                      <strong>Perlu dikirim</strong>
                      <small>
                        Aktifkan untuk membuat Surat Jalan dan data tujuan kirim.
                      </small>
                    </span>
                  </label>
                  {fulfillmentMode === 'DELIVERY' && (
                    <button
                      type="button"
                      className="pos-delivery-edit-button"
                      onClick={() => setDeliveryDetailsOpen(true)}
                    >
                      <Truck className="h-4 w-4" />
                      <span>
                        <strong>Atur pengiriman</strong>
                        <small>
                          {deliveryRecipientName || 'Penerima belum lengkap'} ·{' '}
                          {money(effectiveDeliveryFee)}
                        </small>
                      </span>
                    </button>
                  )}
                </div>
                <div className="pos-section-heading">
                  <span>3</span>
                  <div>
                    <strong>Pembayaran</strong>
                    <small>Pilih cara pelanggan membayar.</small>
                  </div>
                </div>
                {isTempo ? (
                  <div className="grid gap-2 rounded-xl border border-slate-800 p-3 sm:grid-cols-2">
                    <label className="block text-xs font-semibold text-slate-400">
                      Tanggal transaksi / order
                      <input
                        required
                        type="datetime-local"
                        value={localDateTimeInput(transactionAt)}
                        onChange={(event) => {
                          if (!event.target.value) return
                          const nextTransactionAt = new Date(event.target.value).toISOString()
                          setTransactionAt(nextTransactionAt)
                          setTransactionDateIsManual(true)
                          if (!dueDateIsManual) {
                            setDueDate(suggestedTempoDueDate(
                              nextTransactionAt,
                              activeCustomer?.creditTermDays ?? null,
                            ))
                          }
                        }}
                        className="mt-1 w-full rounded-lg border border-slate-700 bg-slate-950 px-3 py-2 text-sm"
                      />
                      <span className="mt-1 block text-[11px] font-normal text-slate-500">
                        Tanggal lampau memerlukan periode terbuka. Tanggal mendatang
                        disimpan sebagai order terjadwal dan belum memengaruhi Finance.
                      </span>
                    </label>
                    <label className="block text-xs font-semibold text-slate-400">
                      Tanggal jatuh tempo
                      <input
                        required
                        type="datetime-local"
                        min={localDateTimeInput(transactionAt)}
                        value={dueDate}
                        onChange={(event) => {
                          setDueDate(event.target.value)
                          setDueDateIsManual(true)
                        }}
                        className="mt-1 w-full rounded-lg border border-slate-700 bg-slate-950 px-3 py-2 text-sm"
                      />
                      <span className="mt-1 block text-[11px] font-normal text-slate-500">
                        {activeCustomer?.creditTermDays === null ||
                        activeCustomer?.creditTermDays === undefined
                          ? 'Tenor Customer belum diatur; pilih tanggal manual.'
                          : `Saran otomatis dari tenor ${activeCustomer.creditTermDays} hari.`}
                      </span>
                    </label>
                  </div>
                ) : (
                  <div className="pos-payment-area">
                    <p className="pos-payment-guidance">
                      Jika pelanggan memakai lebih dari satu cara bayar,
                      tambahkan cara bayar berikutnya.
                    </p>
                    <div className="pos-payment-leg-list">
                      {paymentLegs.map((leg, index) => {
                        const method = catalog.paymentMethods.find(
                          (item) => item.id === leg.paymentMethodId,
                        )
                        const acceptsTenderedAmount =
                          method?.methodType === 'CASH' ||
                          (isOnline && method?.methodType === 'TRANSFER')
                        const isCustomerBalance =
                          method?.methodType === 'CUSTOMER_BALANCE'
                        const legAmount = Number(leg.amount || 0)
                        const legTendered = Number(
                          leg.tenderedAmount || legAmount,
                        )
                        const legOverpayment = acceptsTenderedAmount
                          ? Math.max(legTendered - legAmount, 0)
                          : 0
                        const canCreditCustomerBalance = Boolean(
                          isOnline &&
                            catalog.customerBalanceCreditEnabled &&
                            activeCustomer &&
                            !activeCustomer.isWalkIn,
                        )
                        const configuredFee = estimatePaymentFee(
                          leg.paymentMethodId,
                          leg.amount,
                        )
                        return (
                          <div
                            key={leg.clientPaymentKey}
                            className="pos-payment-leg-card"
                          >
                            <div className="pos-payment-leg-head">
                              <div className="pos-payment-leg-title">
                                <div>
                                  <strong>Pembayaran {index + 1}</strong>
                                  <small>
                                    {method?.name ?? 'Pilih metode'}
                                  </small>
                                </div>
                              </div>
                              {paymentLegs.length > 1 && !isCustomerBalance && (
                                <button
                                  type="button"
                                  onClick={() =>
                                    removePaymentLeg(leg.clientPaymentKey)
                                  }
                                  aria-label={`Hapus pembayaran ${index + 1}`}
                                  title="Hapus metode pembayaran"
                                >
                                  Hapus
                                </button>
                              )}
                            </div>
                            <div className="pos-payment-leg-grid">
                              <label className="pos-payment-field">
                                <span className="pos-payment-field-label">
                                  Cara bayar
                                </span>
                                <select
                                  value={leg.paymentMethodId}
                                  disabled={isCustomerBalance}
                                  onChange={(event) => {
                                    const paymentMethodId = event.target.value
                                    const nextMethod =
                                      catalog.paymentMethods.find(
                                        (item) => item.id === paymentMethodId,
                                      )
                                    updatePaymentLeg(leg.clientPaymentKey, {
                                      paymentMethodId,
                                      tenderedAmount:
                                        ['CASH', 'TRANSFER'].includes(
                                          nextMethod?.methodType ?? '',
                                        )
                                          ? leg.amount
                                          : '',
                                      proofUrl: '',
                                      overpaymentDisposition: 'RETURNED',
                                    })
                                  }}
                                >
                                  {catalog.paymentMethods
                                    .filter(
                                      (candidate) =>
                                        isCustomerBalance ||
                                        candidate.methodType !==
                                          'CUSTOMER_BALANCE',
                                    )
                                    .map((candidate) => {
                                    const usedByOther = paymentLegs.some(
                                      (other) =>
                                        other.clientPaymentKey !==
                                          leg.clientPaymentKey &&
                                        other.paymentMethodId === candidate.id,
                                    )
                                    return (
                                      <option
                                        key={candidate.id}
                                        value={candidate.id}
                                        disabled={usedByOther}
                                      >
                                        {candidate.name}
                                      </option>
                                    )
                                  })}
                                </select>
                              </label>
                              <div className="pos-payment-field">
                                <div className="pos-payment-field-label">
                                  <label
                                    htmlFor={`payment-amount-${leg.clientPaymentKey}`}
                                  >
                                    Bagian tagihan
                                  </label>
                                  {paymentLegs.length > 1 && (
                                    <button
                                      type="button"
                                      disabled={!draft && !offlinePreview}
                                      onClick={() =>
                                        fillPaymentRemainder(leg.clientPaymentKey)
                                      }
                                    >
                                      Isi sisa
                                    </button>
                                  )}
                                </div>
                                <CurrencyInput
                                  id={`payment-amount-${leg.clientPaymentKey}`}
                                  value={leg.amount}
                                  readOnly={
                                    isCustomerBalance ||
                                    paymentLegs.length === 1
                                  }
                                  onValueChange={(amount) => {
                                    updatePaymentLeg(leg.clientPaymentKey, {
                                      amount,
                                    ...(['CASH', 'TRANSFER'].includes(
                                      method?.methodType ?? '',
                                    ) &&
                                      (!leg.tenderedAmount ||
                                        leg.tenderedAmount === leg.amount)
                                        ? { tenderedAmount: amount }
                                        : {}),
                                    })
                                  }}
                                  placeholder={
                                    paymentLegs.length === 1
                                      ? 'Otomatis mengikuti total final'
                                      : 'Masukkan bagian tagihan'
                                  }
                                />
                                <small className="pos-payment-help">
                                  {isCustomerBalance
                                    ? 'Terisi otomatis dan wajib memakai seluruh saldo.'
                                    : paymentLegs.length === 1
                                    ? 'Terisi otomatis dari total final Cart.'
                                    : 'Bagi total tagihan ke setiap cara bayar.'}
                                </small>
                              </div>
                              {acceptsTenderedAmount && (
                                <label className="pos-payment-field">
                                  <span className="pos-payment-field-label">
                                    {method?.methodType === 'CASH'
                                      ? 'Uang diterima'
                                      : 'Nominal transfer diterima'}
                                  </span>
                                  <CurrencyInput
                                    value={leg.tenderedAmount}
                                    onValueChange={(value) =>
                                      updatePaymentLeg(leg.clientPaymentKey, {
                                        tenderedAmount: value,
                                      })
                                    }
                                    placeholder="Masukkan uang yang diterima"
                                  />
                                  <small className="pos-payment-help">
                                    Boleh lebih besar dari bagian tagihan.
                                    Tujuan selisih dipilih di bawah.
                                  </small>
                                </label>
                              )}
                              {(method?.proofRequired ||
                                method?.methodType !== 'CASH') && (
                                <label className="pos-payment-field">
                                  <span className="pos-payment-field-label">
                                    Link bukti pembayaran{' '}
                                    {method?.proofRequired
                                      ? '(wajib)'
                                      : '(opsional)'}
                                  </span>
                                  <input
                                    type="url"
                                    value={leg.proofUrl}
                                    onChange={(event) =>
                                      updatePaymentLeg(leg.clientPaymentKey, {
                                        proofUrl: event.target.value,
                                      })
                                    }
                                    placeholder="https://..."
                                  />
                                </label>
                              )}
                            </div>
                            {legOverpayment > 0 && (
                              <div className="pos-overpayment-panel">
                                <div className="pos-overpayment-heading">
                                  <strong>Kelebihan {money(legOverpayment)}</strong>
                                  <span>Pilih tujuan kelebihan pembayaran.</span>
                                </div>
                                <div className="pos-overpayment-options">
                                  <button
                                    type="button"
                                    className={
                                      leg.overpaymentDisposition === 'RETURNED'
                                        ? 'is-selected'
                                        : ''
                                    }
                                    onClick={() =>
                                      updatePaymentLeg(leg.clientPaymentKey, {
                                        overpaymentDisposition: 'RETURNED',
                                      })
                                    }
                                  >
                                    <strong>Kembalikan ke Customer</strong>
                                    <small>Dicatat sebagai uang kembalian.</small>
                                  </button>
                                  <button
                                    type="button"
                                    disabled={!canCreditCustomerBalance}
                                    className={
                                      leg.overpaymentDisposition ===
                                      'CUSTOMER_BALANCE'
                                        ? 'is-selected'
                                        : ''
                                    }
                                    onClick={() =>
                                      updatePaymentLeg(leg.clientPaymentKey, {
                                        overpaymentDisposition:
                                          'CUSTOMER_BALANCE',
                                      })
                                    }
                                  >
                                    <strong>Simpan sebagai Saldo</strong>
                                    <small>
                                      {canCreditCustomerBalance
                                        ? `Masuk saldo ${activeCustomer?.name}.`
                                        : activeCustomer?.isWalkIn
                                          ? 'Pilih Customer reguler dahulu.'
                                          : 'Fitur Saldo Customer belum aktif.'}
                                    </small>
                                  </button>
                                </div>
                              </div>
                            )}
                            {method?.feeEnabled && (
                              <p className="pos-payment-fee-note">
                                Perkiraan biaya admin {money(configuredFee)} ·{' '}
                                {method.feeBearer === 'CUSTOMER'
                                  ? 'ditambahkan ke pembayaran Customer'
                                  : 'ditanggung Company'}
                              </p>
                            )}
                          </div>
                        )
                      })}
                    </div>
                    <button
                      type="button"
                      className="pos-add-payment"
                      disabled={
                        paymentLegs.length >= catalog.paymentMethods.length
                      }
                      onClick={addPaymentLeg}
                    >
                      Tambah cara bayar
                    </button>
                    {customerBalanceDue > 0 && (
                      <div
                        className={
                          customerBalanceShortfall > 0
                            ? 'pos-balance-tender is-blocked'
                            : 'pos-balance-tender'
                        }
                      >
                        <strong>
                          Saldo {activeCustomer?.name}: {money(customerBalanceDue)}
                        </strong>
                        <span>
                          {customerBalanceShortfall > 0
                            ? `Tambahkan belanja minimal ${money(customerBalanceShortfall)} agar seluruh saldo dapat dipakai.`
                            : 'Seluruh saldo otomatis dipakai sebelum cara bayar lainnya.'}
                        </span>
                      </div>
                    )}
                    <div className="pos-payment-summary">
                      <div>
                        <span>Total yang harus dibayar</span>
                        <strong>
                          {draft || offlinePreview
                            ? money(paymentDue)
                            : 'Belum dihitung'}
                        </strong>
                      </div>
                      <div>
                        <span>Total bagian tagihan</span>
                        <strong>{money(paymentBaseTotal)}</strong>
                      </div>
                      {returnedChangeTotal > 0 && (
                        <div className="is-change">
                          <span>Dikembalikan ke Customer</span>
                          <strong>{money(returnedChangeTotal)}</strong>
                        </div>
                      )}
                      {customerBalanceCreditTotal > 0 && (
                        <div className="is-credit">
                          <span>Masuk Saldo Customer</span>
                          <strong>{money(customerBalanceCreditTotal)}</strong>
                        </div>
                      )}
                      <div
                        className={
                          (draft || offlinePreview) &&
                          Math.abs(paymentRemaining) > 0.0001
                            ? 'is-warning'
                            : 'is-balanced'
                        }
                      >
                        <span>
                          {paymentRemaining < 0
                            ? 'Kelebihan pembayaran'
                            : 'Kurang bayar'}
                        </span>
                        <strong>{money(Math.abs(paymentRemaining))}</strong>
                      </div>
                      {customerSurchargeEstimate > 0 && (
                        <div>
                          <span>Perkiraan biaya admin pelanggan</span>
                          <strong>{money(customerSurchargeEstimate)}</strong>
                        </div>
                      )}
                    </div>
                  </div>
                )}

                <div className="pos-total-card rounded-xl bg-slate-950 p-3">
                  <div className="flex justify-between text-sm text-slate-400">
                    <span>
                      {pricePreviewLines.length > 0
                        ? 'Subtotal harga Pricelist'
                        : 'Subtotal sementara'}
                    </span>
                    <span>{money(fallbackSubtotal)}</span>
                  </div>
                  <div className="mt-2 flex justify-between text-lg font-black">
                    <span>Total akhir</span>
                    <span className="text-emerald-400">
                      {draft
                        ? money(paymentDue)
                          : offlinePreview
                          ? money(paymentDue)
                          : isOnline
                            ? 'Simpan untuk hitung total'
                            : 'Offline belum siap'}
                    </span>
                  </div>
                  {draft && draft.roundingAdjustment !== 0 && (
                    <p className="mt-1 text-right text-xs text-slate-400">
                      Sebelum {money(draft.grandTotalBeforeRounding)} · Selisih{' '}
                      {money(draft.roundingAdjustment)}
                    </p>
                  )}
                  {!isOnline && !offlinePreview && offlinePreviewError && (
                    <p className="pos-offline-checkout-warning">
                      {offlinePreviewError}
                    </p>
                  )}
                </div>

                <div
                  className={`pos-action-bar grid gap-2 ${
                    draft ? 'grid-cols-3' : 'grid-cols-2'
                  }`}
                >
                  {draft && (
                    <button
                      disabled={busy || !isOnline}
                      onClick={handleCancelDraft}
                      className="pos-cancel-draft-button"
                    >
                      Batalkan Draft
                    </button>
                  )}
                  <button
                    disabled={busy || cart.length === 0 || !isOnline}
                    onClick={handleSaveDraft}
                    className="rounded-xl border border-emerald-700 px-3 py-3 font-bold text-emerald-300 disabled:opacity-40"
                  >
                    {isTempo && isFutureLocalBusinessDate(transactionAt)
                      ? 'Simpan Terjadwal'
                      : 'Simpan Draft'}
                  </button>
                  <button
                    disabled={
                      busy ||
                      !isOnline ||
                      cart.length === 0 ||
                      customerBalanceShortfall > 0
                      || (fulfillmentMode === 'DELIVERY' && !deliveryFeeInputValid)
                    }
                    onClick={() => void handlePostSale()}
                    className="rounded-xl bg-emerald-500 px-3 py-3 font-black text-slate-950 disabled:opacity-40"
                  >
                    {busy
                      ? 'Memproses...'
                      : isOnline
                        ? 'Konfirmasi Order'
                        : 'Offline belum didukung'}
                  </button>
                </div>
              </div>
            </aside>
            </div>
          </div>
        )}

        {closeSessionOpen && cashierSession && (
          <div
            className="pos-action-dialog-overlay fixed inset-0 z-[60] grid place-items-center bg-black/65 p-4"
            onMouseDown={(event) => {
              if (event.currentTarget === event.target && !busy) {
                setCloseSessionOpen(false)
              }
            }}
          >
          <section role="dialog" aria-modal="true" aria-labelledby="close-session-title" className="pos-close-session-dialog w-full max-w-lg rounded-3xl bg-white p-6 text-slate-950 shadow-2xl">
            <Clock3 className="h-5 w-5 text-emerald-400" />
            <div className="mr-auto">
              <p className="text-xs font-black uppercase tracking-wider text-rose-700">Penutupan kasir</p>
              <h2 id="close-session-title" className="mt-1 text-2xl font-black">Tutup Sesi</h2>
              <p className="mt-2 font-bold">{cashierSession.code}</p>
              <p className="text-xs text-slate-400">
                {activeCompany?.name} · {activeTerminal?.storeName} ·{' '}
                {activeWarehouse?.name}
              </p>
            </div>
            <label className="text-xs text-slate-400">
              Kas fisik penutupan
              <CurrencyInput
                value={closingCash}
                onValueChange={setClosingCash}
                autoFocus
                placeholder="0"
                className="ml-2 rounded-lg border border-slate-700 bg-slate-950 px-3 py-2 text-sm text-slate-100"
              />
            </label>
            <p className="pos-close-session-note">
              Pastikan nominal sesuai kas fisik. Sesi yang sudah ditutup tidak
              dapat dipakai untuk transaksi baru.
            </p>
            <footer className="pos-close-session-actions">
              <button type="button" disabled={busy} onClick={() => setCloseSessionOpen(false)} className="rounded-xl border border-slate-300 px-4 py-2 text-sm font-bold text-slate-700">Batal</button>
              <button
                disabled={busy || closingCash === ''}
                onClick={() => void executeCloseSession()}
                className="rounded-xl border border-rose-700 bg-rose-700 px-4 py-2 text-sm font-bold text-white"
              >
                {busy ? 'Menutup...' : 'Konfirmasi Tutup'}
              </button>
            </footer>
          </section>
          </div>
        )}
      </main>

      {editingCartItem && (
        <div
          className="pos-cart-editor-overlay fixed inset-0 z-[65] grid place-items-center bg-black/60 p-4"
          onMouseDown={(event) => {
            if (event.currentTarget === event.target) {
              setEditingCartProductUomId('')
            }
          }}
        >
          <section
            role="dialog"
            aria-modal="true"
            aria-labelledby="pos-cart-editor-title"
            className="pos-cart-editor-dialog"
          >
            <header className="pos-cart-editor-header">
              <div className="min-w-0">
                <p className="pos-eyebrow">Edit produk</p>
                <h2 id="pos-cart-editor-title">{editingCartItem.product.name}</h2>
                <p>{editingCartItem.product.uomName}</p>
              </div>
              <button
                type="button"
                className="pos-cart-editor-close"
                onClick={() => setEditingCartProductUomId('')}
                aria-label="Tutup edit produk"
              >
                <X className="h-5 w-5" />
              </button>
            </header>

            <div className="pos-cart-editor-content">
              <div className="pos-cart-editor-section">
                <label>Jumlah</label>
                <div className="pos-cart-editor-quantity">
                  <button
                    type="button"
                    onClick={() => adjustCartQuantity(editingCartItem, -1)}
                    className="pos-cart-icon-button"
                    aria-label={`Kurangi jumlah ${editingCartItem.product.name}`}
                  >
                    <Minus className="h-4 w-4" />
                  </button>
                  <input
                    type="number"
                    min="0"
                    step={
                      editingCartItem.product.allowDecimal
                        ? 10 ** -editingCartItem.product.decimalPrecision
                        : 1
                    }
                    value={
                      cartQuantityInputs[editingCartItem.product.productUomId] ??
                      String(editingCartItem.quantity)
                    }
                    onChange={(event) =>
                      changeCartQuantityInput(
                        editingCartItem,
                        event.target.value,
                      )
                    }
                    onBlur={() => commitCartQuantityInput(editingCartItem)}
                  />
                  <button
                    type="button"
                    onClick={() => adjustCartQuantity(editingCartItem, 1)}
                    className="pos-cart-icon-button"
                    aria-label={`Tambah jumlah ${editingCartItem.product.name}`}
                  >
                    <Plus className="h-4 w-4" />
                  </button>
                  <strong>
                    {money(
                      editingResolvedLine?.lineTotal ??
                        editingEffectiveUnitPrice * editingCartItem.quantity,
                    )}
                  </strong>
                </div>
              </div>

              {isOnline && (
                activeTerminal?.allowPriceOverride ||
                editingCartItem.overrideUnitPrice !== null
              ) && (
                <div className="pos-cart-editor-section">
                  <div className="pos-cart-editor-label-row">
                    <label>
                      Harga jual / {editingCartItem.product.uomName}
                    </label>
                    {editingOverrideApplied && (
                      <button
                        type="button"
                        onClick={() =>
                          updateCart(editingCartItem.product.productUomId, {
                            overrideUnitPrice: null,
                          })
                        }
                      >
                        Kembalikan ke Pricelist
                      </button>
                    )}
                  </div>
                  <CurrencyInput
                    value={
                      editingCartItem.overrideUnitPrice ??
                      editingCanonicalUnitPrice
                    }
                    onValueChange={(value) =>
                      updateCart(editingCartItem.product.productUomId, {
                        overrideUnitPrice: Number(value || 0),
                      })
                    }
                    disabled={!activeTerminal?.allowPriceOverride}
                  />
                  {editingOverrideApplied && (
                    <p>
                      Harga Pricelist semula {money(editingCanonicalUnitPrice)}.
                    </p>
                  )}
                  {!activeTerminal?.allowPriceOverride &&
                    editingCartItem.overrideUnitPrice !== null && (
                      <p className="is-error">
                        Izin Terminal sudah nonaktif. Kembalikan ke Pricelist
                        sebelum menyimpan atau Post.
                      </p>
                    )}
                </div>
              )}

              <div className="pos-cart-editor-section">
                <label>Diskon produk</label>
                <div className="pos-cart-editor-discount">
                  <select
                    value={editingCartItem.discountType}
                    onChange={(event) =>
                      updateCart(editingCartItem.product.productUomId, {
                        discountType: event.target.value as
                          | ''
                          | 'AMOUNT'
                          | 'PERCENT',
                      })
                    }
                  >
                    <option value="">Tanpa diskon line</option>
                    <option value="AMOUNT">Diskon nominal</option>
                    <option value="PERCENT">Diskon persen</option>
                  </select>
                  {editingCartItem.discountType === 'AMOUNT' ? (
                    <CurrencyInput
                      value={editingCartItem.discountInput}
                      onValueChange={(value) =>
                        updateCart(editingCartItem.product.productUomId, {
                          discountInput: Number(value || 0),
                        })
                      }
                    />
                  ) : (
                    <input
                      type="number"
                      min="0"
                      disabled={!editingCartItem.discountType}
                      value={editingCartItem.discountInput}
                      onChange={(event) =>
                        updateCart(editingCartItem.product.productUomId, {
                          discountInput: Number(event.target.value),
                        })
                      }
                    />
                  )}
                </div>
              </div>
            </div>

            <footer className="pos-cart-editor-footer">
              <button
                type="button"
                className="is-remove"
                onClick={() =>
                  removeCartItem(editingCartItem.product.productUomId)
                }
              >
                <Trash2 className="h-4 w-4" />
                Hapus produk
              </button>
              <button
                type="button"
                className="is-done"
                onClick={() => setEditingCartProductUomId('')}
              >
                Selesai
              </button>
            </footer>
          </section>
        </div>
      )}

      {offlinePanelOpen && cashierSession && terminalFeatureVisible('OFFLINE') && (
        <div
          className="pos-offline-drawer-overlay fixed inset-0 z-50 bg-black/60 p-3 sm:p-6"
          onMouseDown={(event) => {
            if (event.currentTarget === event.target) setOfflinePanelOpen(false)
          }}
        >
          <section
            role="dialog"
            aria-modal="true"
            aria-labelledby="pos-offline-drawer-title"
            className="pos-offline-drawer ml-auto flex h-full w-full max-w-xl flex-col overflow-hidden bg-white shadow-2xl"
          >
            <header className="flex items-start justify-between border-b border-slate-200 px-5 py-4">
              <div>
                <p className="pos-eyebrow">Menu operasional</p>
                <h2
                  id="pos-offline-drawer-title"
                  className="text-xl font-black text-slate-900"
                >
                  Status Offline
                </h2>
                <p className="mt-1 text-sm text-slate-500">
                  Periksa snapshot dan cadangan stok hanya saat diperlukan.
                </p>
              </div>
              <button
                type="button"
                onClick={() => setOfflinePanelOpen(false)}
                className="pos-modal-close"
                aria-label="Tutup status Offline"
              >
                <X className="h-5 w-5" />
              </button>
            </header>
            <div className="flex-1 overflow-y-auto p-4 sm:p-5">
              <OfflineCacheStatusPanel
                isOnline={isOnline}
                cache={offlineCache}
                allowances={offlineAllowances}
                queue={offlineQueue}
                terminalName={activeTerminal?.name ?? 'Terminal tidak dikenali'}
                warehouseName={activeWarehouse?.name ?? 'Gudang tidak dikenali'}
                sessionCode={cashierSession.code}
                busy={offlineCacheBusy}
                message={offlineCacheMessage}
                onRefresh={handleRefreshOfflineCache}
                selectedProductId={offlineProductId}
                onSelectProduct={setOfflineProductId}
                onIssue={handleIssueOfflineAllowance}
                onRelease={handleReleaseOfflineAllowance}
                onSync={handleSyncOfflineSale}
                onRefreshStatus={handleRefreshOfflineSaleStatus}
                onOpenFinalReceipt={handleOpenOfflineFinalReceipt}
              />
            </div>
          </section>
        </div>
      )}

      {quickCustomerOpen && cashierSession && activeCompany && (
        <QuickCustomerModal
          companyId={activeCompany.id}
          companyName={activeCompany.name}
          busy={busy}
          close={() => setQuickCustomerOpen(false)}
          complete={async (newCustomerId) => {
            setBusy(true)
            setError('')
            try {
              await refreshCatalog(cashierSession)
              selectCustomer(newCustomerId)
              setSelectedPricelistId('')
              setResolvedLines([])
              setQuickCustomerOpen(false)
              setNotice('Customer baru dibuat dan langsung dipilih.')
            } catch (reason) {
              setError(friendlyError(errorMessage(reason)))
            } finally {
              setBusy(false)
            }
          }}
        />
      )}

      {salesReturnOpen && cashierSession && activeCompany && terminalFeatureVisible('SALES_RETURN') && (
        <Suspense fallback={<CenteredMessage text="Membuka Return…" />}>
          <SalesReturnModal
            companyId={activeCompany.id}
            cashierSession={cashierSession}
            catalog={catalog}
            close={() => setSalesReturnOpen(false)}
            completed={(message) => {
              setSalesReturnOpen(false)
              setNotice(message)
              setError('')
            }}
          />
        </Suspense>
      )}

      {expenseRequestOpen && cashierSession && session && terminalFeatureVisible('EXPENSE') && (
        <Suspense fallback={<CenteredMessage text="Membuka Expense…" />}>
          <ExpenseRequestModal
            cashierSession={cashierSession}
            catalog={catalog}
            actorId={session.user.id}
            actorName={
              String(
                session.user.user_metadata?.full_name ??
                  session.user.user_metadata?.name ??
                  session.user.email ??
                  'Kasir',
              )
            }
            close={() => setExpenseRequestOpen(false)}
            completed={(message, expectedCashAfter) => {
              setExpenseRequestOpen(false)
              if (expectedCashAfter !== undefined) {
                setCashierSession((current) => current
                  ? { ...current, expectedCash: expectedCashAfter }
                  : current)
              }
              setNotice(message)
              setError('')
            }}
          />
        </Suspense>
      )}

      {cashDepositOpen && activeTerminal && terminalFeatureVisible('CASH_DEPOSIT') && (
        <Suspense fallback={<CenteredMessage text="Membuka Setor Kas…" />}>
          <CashDepositModal
            storeId={activeTerminal.storeId}
            storeName={activeTerminal.storeName}
            close={() => setCashDepositOpen(false)}
            completed={(message) => {
              setCashDepositOpen(false)
              setNotice(message)
              setError('')
            }}
          />
        </Suspense>
      )}

      {stockRequestOpen && cashierSession && activeCompany && terminalFeatureVisible('STOCK_REQUEST') && (
        <Suspense fallback={<CenteredMessage text="Membuka Permintaan Stok…" />}>
          <StockRequestModal companyId={activeCompany.id} cashierSessionId={cashierSession.id} close={() => setStockRequestOpen(false)} completed={(message) => { setStockRequestOpen(false); setNotice(message); setError('') }} />
        </Suspense>
      )}

      {goodsReceiptOpen && cashierSession && activeCompany && terminalFeatureVisible('GOODS_RECEIPT') && (
        <Suspense fallback={<CenteredMessage text="Membuka Penerimaan Barang…" />}>
          <GoodsReceiptModal
            companyId={activeCompany.id}
            cashierSession={cashierSession}
            close={() => setGoodsReceiptOpen(false)}
            completed={(message) => {
              setGoodsReceiptOpen(false)
              setNotice(message)
              setError('')
              void refreshCatalog(cashierSession)
            }}
          />
        </Suspense>
      )}

      {purchaseReturnOpen && cashierSession && activeCompany && terminalFeatureVisible('PURCHASE_RETURN') && (
        <Suspense fallback={<CenteredMessage text="Membuka Retur Pembelian…" />}>
          <PurchaseReturnModal
            companyId={activeCompany.id}
            cashierSession={cashierSession}
            close={() => setPurchaseReturnOpen(false)}
            completed={(message) => {
              setPurchaseReturnOpen(false)
              setNotice(message)
              setError('')
            }}
          />
        </Suspense>
      )}

      {stockOpnameOpen && cashierSession && activeCompany && terminalFeatureVisible('STOCK_OPNAME') && (
        <Suspense fallback={<CenteredMessage text="Membuka Stock Opname..." />}>
          <StockOpnameModal
            companyId={activeCompany.id}
            defaultWarehouseId={cashierSession.warehouseId}
            isOnline={isOnline}
            close={() => setStockOpnameOpen(false)}
            completed={(message) => {
              setStockOpnameOpen(false)
              setNotice(message)
              setError('')
            }}
          />
        </Suspense>
      )}

      {orderPanelOpen && cashierSession && (
        <SalesOrderPanel
          orders={salesOrders.filter((order) => order.orderRuntimeStatus !== 'DELIVERED')}
          customers={catalog.customers}
          loading={loading}
          close={() => setOrderPanelOpen(false)}
          refresh={async () => {
            setLoading(true)
            try {
              await refreshSalesOrders(cashierSession)
            } finally {
              setLoading(false)
            }
          }}
          revise={handleStartSalesOrderRevision}
        />
      )}

      {draftPanelOpen && cashierSession && (
        <div className="pos-draft-overlay fixed inset-0 z-50 bg-black/60 p-3 sm:p-6">
          <section className="pos-draft-panel ml-auto flex h-full w-full max-w-2xl flex-col overflow-hidden bg-white shadow-2xl">
            <header className="flex items-start justify-between border-b px-5 py-4">
              <div>
                <p className="pos-eyebrow">Store aktif</p>
                <h2 className="text-xl font-black">Draft transaksi</h2>
                <p className="mt-1 text-sm text-slate-500">
                  Draft tidak memotong stok dan belum mencatat pembayaran.
                </p>
              </div>
              <button
                onClick={() => setDraftPanelOpen(false)}
                className="pos-modal-close"
                aria-label="Tutup daftar Draft"
              >
                <X className="h-5 w-5" />
              </button>
            </header>
            <div className="flex-1 space-y-3 overflow-y-auto p-4 sm:p-5">
              {saleDrafts.length === 0 ? (
                <div className="grid min-h-60 place-items-center text-center text-slate-500">
                  <div>
                    <FileText className="mx-auto mb-3 h-10 w-10" />
                    <p className="font-bold text-slate-700">Belum ada Draft</p>
                    <p className="mt-1 text-sm">
                      Simpan keranjang untuk melanjutkannya nanti.
                    </p>
                  </div>
                </div>
              ) : (
                saleDrafts.map((item) => {
                  const lockedByMe =
                    item.lockOwnerId === session.user.id &&
                    item.lockSessionId === cashierSession.id
                  const lockedByOther =
                    Boolean(item.lockOwnerId) && !lockedByMe
                  return (
                    <article
                      key={item.salesId}
                      className={`pos-draft-card ${
                        item.isStale ? 'is-stale' : ''
                      }`}
                    >
                      <div className="flex flex-wrap items-start gap-3">
                        <div className="min-w-0 flex-1">
                          <div className="flex flex-wrap items-center gap-2">
                            <strong>{item.draftNo}</strong>
                            {item.draftLabel && (
                              <span className="pos-draft-label">
                                {item.draftLabel}
                              </span>
                            )}
                            {item.isStale && (
                              <span className="pos-draft-stale">Lebih dari 7 hari</span>
                            )}
                            <span className={
                              item.operationalStatus === 'SCHEDULED'
                                ? 'pos-draft-scheduled'
                                : 'pos-draft-active'
                            }>
                              {item.operationalStatus === 'SCHEDULED'
                                ? `Terjadwal ${new Date(`${item.plannedOrderDate}T00:00:00`).toLocaleDateString('id-ID')}`
                                : 'Order aktif'}
                            </span>
                          </div>
                          <p className="mt-1 font-semibold text-slate-800">
                            {item.customerName}
                          </p>
                          <p className="mt-1 text-xs text-slate-500">
                            {item.lineCount} item · {money(item.grandTotal)} ·{' '}
                            diperbarui{' '}
                            {new Date(item.updatedAt).toLocaleString('id-ID')}
                          </p>
                          <p className="mt-1 text-xs text-slate-500">
                            Dibuat oleh {item.createdByName}
                          </p>
                          {item.draftNotes && (
                            <p className="pos-draft-notes">{item.draftNotes}</p>
                          )}
                        </div>
                        <div className="pos-draft-actions">
                          {lockedByOther && !item.lockExpired ? (
                            <>
                              <span className="pos-lock-status">
                                <LockKeyhole className="h-4 w-4" />
                                Diedit {item.lockOwnerName ?? 'kasir lain'}
                              </span>
                              {canForceReleaseDraft && (
                                <button
                                  disabled={busy}
                                  onClick={() => handleForceReleaseDraft(item)}
                                  className="pos-force-release"
                                >
                                  Lepas paksa
                                </button>
                              )}
                            </>
                          ) : (
                            <button
                              disabled={busy}
                              onClick={() => handleContinueDraft(item)}
                              className="pos-continue-draft"
                            >
                              {lockedByOther && item.lockExpired
                                ? 'Ambil alih'
                                : lockedByMe
                                  ? 'Kembali mengedit'
                                  : 'Lanjutkan'}
                            </button>
                          )}
                        </div>
                      </div>
                    </article>
                  )
                })
              )}
            </div>
          </section>
        </div>
      )}

      {deliveryDetailsOpen && fulfillmentMode === 'DELIVERY' && (
        <div className="pos-action-dialog-overlay fixed inset-0 z-[60] grid place-items-center bg-black/65 p-4">
          <section
            role="dialog"
            aria-modal="true"
            aria-labelledby="delivery-details-title"
            className="pos-delivery-dialog w-full max-w-2xl bg-white shadow-2xl"
          >
            <header className="flex items-start justify-between gap-4">
              <div>
                <p className="text-xs font-black uppercase tracking-wider text-emerald-700">
                  Pengiriman transaksi ini
                </p>
                <h2 id="delivery-details-title" className="mt-1 text-xl font-black text-slate-950">
                  Tujuan kirim dan ongkir
                </h2>
                <p className="mt-1 text-sm text-slate-500">
                  Data Customer dipakai sebagai awal dan tetap dapat disesuaikan untuk pengiriman ini.
                </p>
              </div>
              <button
                type="button"
                onClick={() => setDeliveryDetailsOpen(false)}
                className="pos-modal-close"
                aria-label="Tutup pengaturan pengiriman"
              >
                <X className="h-5 w-5" />
              </button>
            </header>
            <div className="pos-delivery-fields mt-6">
              <label>
                <span>Nama penerima</span>
                <input
                  autoFocus
                  value={deliveryRecipientName}
                  onChange={(event) => setDeliveryRecipientName(event.target.value)}
                  placeholder="Nama orang yang menerima"
                  maxLength={200}
                />
              </label>
              <label>
                <span>Nomor telepon (opsional)</span>
                <input
                  value={deliveryRecipientPhone}
                  onChange={(event) => setDeliveryRecipientPhone(event.target.value)}
                  placeholder="Nomor yang dapat dihubungi"
                  maxLength={100}
                />
              </label>
              <label className="is-wide">
                <span>Alamat pengiriman (opsional)</span>
                <textarea
                  value={deliveryAddress}
                  onChange={(event) => setDeliveryAddress(event.target.value)}
                  placeholder="Alamat lengkap tujuan pengiriman"
                  maxLength={1000}
                  rows={3}
                />
              </label>
              <label>
                <span>Rencana kirim (opsional)</span>
                <input
                  type="datetime-local"
                  min={isTempo ? localDateTimeInput(transactionAt) : undefined}
                  value={deliveryScheduledAt}
                  onChange={(event) => setDeliveryScheduledAt(event.target.value)}
                />
              </label>
              <label>
                <span>Ongkir</span>
                <CurrencyInput
                  value={deliveryFeeAmount}
                  onValueChange={setDeliveryFeeAmount}
                  placeholder="0"
                />
              </label>
              <label className="is-wide">
                <span>Catatan pengiriman (opsional)</span>
                <input
                  value={deliveryNotes}
                  onChange={(event) => setDeliveryNotes(event.target.value)}
                  placeholder="Contoh: hubungi sebelum tiba"
                  maxLength={500}
                />
              </label>
            </div>
            <label className="pos-invoice-fee-toggle">
              <input
                type="checkbox"
                checked={deliveryFeeInvoiceDisplayMode === 'SHOW_SEPARATE'}
                onChange={(event) =>
                  setDeliveryFeeInvoiceDisplayMode(
                    event.target.checked ? 'SHOW_SEPARATE' : 'HIDE_BREAKDOWN',
                  )
                }
              />
              <span>
                <strong>Tampilkan rincian ongkir di Invoice</strong>
                <small>
                  Jika dimatikan, total Invoice tetap termasuk ongkir tanpa baris terpisah.
                </small>
              </span>
            </label>
            <div className="mt-6 flex justify-end gap-3">
              <button
                type="button"
                onClick={() => setDeliveryDetailsOpen(false)}
                className="min-h-11 rounded-xl bg-emerald-600 px-5 font-black text-white"
              >
                Simpan pengiriman
              </button>
            </div>
          </section>
        </div>
      )}

      {actionDialog && (
        <div className="pos-action-dialog-overlay fixed inset-0 z-[60] grid place-items-center bg-black/65 p-4">
          <section
            role="dialog"
            aria-modal="true"
            aria-labelledby="pos-action-dialog-title"
            className="pos-action-dialog w-full max-w-md bg-white shadow-2xl"
          >
            <header className="flex items-start justify-between gap-4">
              <div
                className={`pos-action-dialog-icon ${
                  actionDialog.tone === 'danger' ? 'is-danger' : ''
                }`}
              >
                {actionDialog.tone === 'danger' ? (
                  <AlertTriangle className="h-5 w-5" />
                ) : (
                  <FileText className="h-5 w-5" />
                )}
              </div>
              <button
                onClick={() => {
                  setActionDialog(null)
                  setActionDialogReason('')
                }}
                className="pos-modal-close"
                aria-label="Tutup konfirmasi"
              >
                <X className="h-5 w-5" />
              </button>
            </header>
            <h2
              id="pos-action-dialog-title"
              className="mt-4 text-xl font-black text-slate-900"
            >
              {actionDialog.title}
            </h2>
            <p className="mt-2 text-sm leading-6 text-slate-600">
              {actionDialog.description}
            </p>
            {actionDialog.requireReason && (
              <label className="mt-5 block text-sm font-bold text-slate-700">
                {actionDialog.reasonLabel ?? 'Alasan'}
                <textarea
                  autoFocus
                  rows={3}
                  maxLength={500}
                  value={actionDialogReason}
                  onChange={(event) =>
                    setActionDialogReason(event.target.value)
                  }
                  placeholder={actionDialog.reasonPlaceholder}
                  className="mt-2 w-full resize-none px-3 py-2.5"
                />
                <span className="mt-1 block text-right text-xs font-normal text-slate-400">
                  {actionDialogReason.length}/500
                </span>
              </label>
            )}
            <footer className="mt-6 grid grid-cols-2 gap-2">
              <button
                disabled={busy}
                onClick={() => {
                  setActionDialog(null)
                  setActionDialogReason('')
                }}
                className="pos-dialog-secondary"
              >
                Kembali
              </button>
              <button
                disabled={
                  busy ||
                  (actionDialog.requireReason &&
                    !actionDialogReason.trim())
                }
                onClick={confirmActionDialog}
                className={
                  actionDialog.tone === 'danger'
                    ? 'pos-dialog-danger'
                    : 'pos-dialog-primary'
                }
              >
                {busy ? 'Memproses…' : actionDialog.confirmLabel}
              </button>
            </footer>
          </section>
        </div>
      )}

      {shortages.length > 0 && (
        <div className="fixed bottom-4 left-4 z-40 max-w-lg rounded-2xl border border-amber-800 bg-amber-950 p-4 shadow-2xl">
          <h3 className="flex items-center gap-2 font-black text-amber-300">
            <AlertTriangle className="h-5 w-5" />
            Stok kurang — transaksi tetap Draft
          </h3>
          <div className="mt-2 space-y-2 text-sm">
            {shortages.map((item, index) => (
              <p key={`${String(item.productId)}-${index}`}>
                {String(item.productName)}: diminta {String(item.requestedBaseQty)}{' '}
                {String(item.baseUomName)}, tersedia{' '}
                {String(item.availableBaseQty)}.
              </p>
            ))}
          </div>
        </div>
      )}

      {offlineSlip && (
        <div className="fixed inset-0 z-50 grid place-items-center bg-black/75 p-4">
          <section
            role="dialog"
            aria-modal="true"
            aria-labelledby="offline-slip-title"
            className="max-h-[90vh] w-full max-w-lg overflow-y-auto rounded-3xl bg-white p-6 text-slate-950 shadow-2xl"
          >
            <div className="flex items-start justify-between gap-4">
              <div>
                <p className="text-xs font-bold uppercase tracking-widest text-amber-700">
                  Slip transaksi Offline
                </p>
                <h2 id="offline-slip-title" className="mt-1 text-2xl font-black">
                  OFF-{offlineSlip.clientTransactionId.slice(0, 8).toUpperCase()}
                </h2>
                <p className="text-sm text-slate-500">
                  {new Date(offlineSlip.localTransactionAt).toLocaleString(
                    'id-ID',
                  )}
                </p>
              </div>
              <button
                onClick={() => setOfflineSlip(null)}
                className="pos-modal-close"
                aria-label="Tutup Slip Offline"
              >
                <X className="h-5 w-5" />
              </button>
            </div>
            <div className="mt-4 rounded-xl border-2 border-amber-500 bg-amber-50 p-3 text-center text-sm font-black text-amber-900">
              BELUM TERSINKRON — BUKAN INVOICE FINAL
            </div>
            <p className="mt-3 text-sm leading-6 text-slate-600">
              Record tersimpan di perangkat. Jangan hapus data browser dan
              sinkronkan dari menu Offline saat koneksi kembali.
            </p>
            <div className="my-5 space-y-3 border-y border-dashed border-slate-300 py-4">
              {offlineSlip.preview.lines.map((line) => (
                <div key={line.lineKey} className="flex justify-between gap-3">
                  <div>
                    <p className="font-bold">{line.productName}</p>
                    <p className="text-xs text-slate-500">
                      {line.quantity} {line.uomName} × {money(line.unitPrice)}
                    </p>
                  </div>
                  <p className="font-bold">{money(line.lineTotal)}</p>
                </div>
              ))}
            </div>
            <div className="space-y-2 text-sm">
              <div className="flex justify-between">
                <span>Customer</span>
                <strong>{offlineSlip.preview.customerName}</strong>
              </div>
              <div className="flex justify-between">
                <span>Pricelist</span>
                <strong>{offlineSlip.preview.selectedPricelistName}</strong>
              </div>
              <div className="flex justify-between text-xl font-black">
                <span>Total</span>
                <span>{money(offlineSlip.preview.grandTotal)}</span>
              </div>
              {offlineSlip.payments.map((payment, index) => (
                <div
                  key={`${payment.methodName}-${index}`}
                  className="flex justify-between"
                >
                  <span>{payment.methodName}</span>
                  <span>{money(payment.amount)}</span>
                </div>
              ))}
            </div>
            <div className="mt-6 grid grid-cols-2 gap-2">
              <button
                onClick={handlePrintOfflineSlip}
                className="flex items-center justify-center gap-2 rounded-xl border border-slate-300 px-4 py-3 font-bold"
              >
                <Printer className="h-5 w-5" />
                Buka & cetak
              </button>
              <button
                onClick={() => setOfflineSlip(null)}
                className="flex items-center justify-center gap-2 rounded-xl bg-slate-900 px-4 py-3 font-black text-white"
              >
                Kembali ke kasir
              </button>
            </div>
          </section>
        </div>
      )}

      {confirmedOrder && (
        <div className="fixed inset-0 z-50 grid place-items-center bg-black/75 p-4">
          <section className="w-full max-w-lg rounded-3xl bg-white p-6 text-slate-950 shadow-2xl">
            <div className="flex items-start justify-between gap-4">
              <div>
                <p className="text-xs font-black uppercase tracking-widest text-emerald-700">Order dikonfirmasi</p>
                <h2 className="mt-1 text-2xl font-black">{confirmedOrder.orderNo}</h2>
                <p className="mt-1 text-sm text-slate-500">Status {confirmedOrder.orderRuntimeStatus} · Stock menjadi Reserved Out dan belum mengurangi On Hand/FIFO.</p>
              </div>
              <button type="button" onClick={closeConfirmedOrder} className="pos-modal-close" aria-label="Tutup konfirmasi Order"><X className="h-5 w-5"/></button>
            </div>
            {confirmedOrder.plannedOrderDate && <div className="mt-5 rounded-xl border border-blue-200 bg-blue-50 p-4 text-sm text-blue-900"><strong>Order terjadwal:</strong> {new Date(`${confirmedOrder.plannedOrderDate}T00:00:00`).toLocaleDateString('id-ID', { day: '2-digit', month: 'long', year: 'numeric' })}</div>}
            <div className="mt-5 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">Pembayaran non-TEMPO menunggu verifikasi Finance. Stock baru keluar ketika Surat Jalan diproses oleh Inventory.</div>
            <div className="mt-6 grid gap-2 sm:grid-cols-2">
              {salesDocuments?.invoice && <button type="button" onClick={() => void handlePrintInvoice()} className="flex min-h-12 items-center justify-center gap-2 rounded-xl border border-emerald-300 bg-emerald-50 px-4 font-black text-emerald-800"><FileText className="h-5 w-5"/>Invoice A4</button>}
              {salesDocuments?.delivery && <button type="button" onClick={() => void handlePrintDelivery()} className="flex min-h-12 items-center justify-center gap-2 rounded-xl border border-sky-300 bg-sky-50 px-4 font-black text-sky-800"><Truck className="h-5 w-5"/>Surat Jalan</button>}
              <button type="button" onClick={() => { closeConfirmedOrder(); setOrderPanelOpen(true) }} className="flex min-h-12 items-center justify-center gap-2 rounded-xl border border-slate-300 px-4 font-black"><ClipboardList className="h-5 w-5"/>Lihat Order</button>
              <button type="button" onClick={closeConfirmedOrder} className="flex min-h-12 items-center justify-center gap-2 rounded-xl bg-emerald-500 px-4 font-black text-slate-950"><CheckCircle2 className="h-5 w-5"/>Kembali ke kasir</button>
            </div>
          </section>
        </div>
      )}

      {receipt && (
        <div className="fixed inset-0 z-50 grid place-items-center bg-black/75 p-4">
          <div className="max-h-[90vh] w-full max-w-lg overflow-y-auto rounded-3xl bg-white p-6 text-slate-950 shadow-2xl">
            <div className="flex items-start justify-between">
              <div>
                <p className="text-xs font-bold uppercase tracking-widest text-emerald-700">
                  Transaksi Posted
                </p>
                <h2 className="mt-1 text-2xl font-black">{receipt.invoiceNo}</h2>
                <p className="text-sm text-slate-500">
                  {new Date(receipt.postedAt).toLocaleString('id-ID')}
                </p>
              </div>
              <button
                onClick={closeReceipt}
                className="pos-modal-close"
                aria-label="Tutup struk"
                title="Tutup struk"
              >
                <X className="h-5 w-5" />
              </button>
            </div>
            <div className="my-5 space-y-3 border-y border-dashed border-slate-300 py-4">
              {receipt.lines.map((line, index) => (
                <div key={`${line.sku}-${index}`} className="flex justify-between gap-3">
                  <div>
                    <p className="font-bold">{line.productName}</p>
                    <p className="text-xs text-slate-500">
                      {line.quantity} {line.uomName} × {money(line.unitPrice)}
                    </p>
                  </div>
                  <p className="font-bold">{money(line.lineTotal)}</p>
                </div>
              ))}
            </div>
            <div className="space-y-2 text-sm">
              <div className="flex justify-between">
                <span>Total sebelum pembulatan</span>
                <span>{money(receipt.totalBeforeRounding)}</span>
              </div>
              {receipt.roundingAdjustment !== 0 && (
                <div className="flex justify-between">
                  <span>Pembulatan</span>
                  <span>{money(receipt.roundingAdjustment)}</span>
                </div>
              )}
              {Number(receipt.deliveryFeeAmount ?? 0) > 0 && (
                <div className="flex justify-between">
                  <span>Ongkir</span>
                  <span>{money(Number(receipt.deliveryFeeAmount))}</span>
                </div>
              )}
              <div className="flex justify-between text-xl font-black">
                <span>Total akhir</span>
                <span>{money(receipt.grandTotal)}</span>
              </div>
              {receipt.payments.map((payment, index) => (
                <div
                  key={`${payment.paymentMethodName}-${index}`}
                  className="flex justify-between"
                >
                  <span>{payment.paymentMethodName}</span>
                  <span>
                    {money(payment.amount)}
                    {payment.changeAmount > 0
                      ? ` · Kembali ${money(payment.changeAmount)}`
                      : ''}
                    {Number(payment.customerBalanceCreditAmount ?? 0) > 0
                      ? ` · Saldo +${money(Number(payment.customerBalanceCreditAmount))}`
                      : ''}
                    {Number(payment.customerBalanceUsageAmount ?? 0) > 0
                      ? ` · Potongan Saldo -${money(Number(payment.customerBalanceUsageAmount))}`
                      : ''}
                  </span>
                </div>
              ))}
            </div>
            {salesDocuments?.delivery && (
              <div className="mt-4 rounded-xl border border-sky-200 bg-sky-50 p-3 text-sm text-sky-900">
                Surat Jalan <strong>{salesDocuments.delivery.deliveryNo}</strong>{' '}
                siap dengan status {salesDocuments.delivery.status}.
              </div>
            )}
            <div className="mt-6 grid gap-2 sm:grid-cols-2">
              <button
                onClick={handlePrint}
                className="flex items-center justify-center gap-2 rounded-xl border border-slate-300 px-4 py-3 font-bold"
              >
                <Printer className="h-5 w-5" />
                Buka & cetak
              </button>
              {salesDocuments?.invoice && (
                <button
                  onClick={handlePrintInvoice}
                  className="flex items-center justify-center gap-2 rounded-xl border border-emerald-300 bg-emerald-50 px-4 py-3 font-bold text-emerald-800"
                >
                  <FileText className="h-5 w-5" />
                  Invoice A4
                </button>
              )}
              {salesDocuments?.delivery && (
                <button
                  onClick={handlePrintDelivery}
                  className="flex items-center justify-center gap-2 rounded-xl border border-sky-300 bg-sky-50 px-4 py-3 font-bold text-sky-800"
                >
                  <Truck className="h-5 w-5" />
                  Surat Jalan
                </button>
              )}
              <button
                onClick={closeReceipt}
                className="flex items-center justify-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 font-black"
              >
                <CheckCircle2 className="h-5 w-5" />
                Kembali ke kasir
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}

function CenteredMessage({ text }: { text: string }) {
  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 grid place-items-center p-6">
      <div className="text-center">
        <RefreshCw className="mx-auto mb-3 h-8 w-8 animate-spin text-emerald-400" />
        <p>{text}</p>
      </div>
    </div>
  )
}

function formatCacheAge(ageMs: number) {
  const seconds = Math.max(0, Math.floor(ageMs / 1_000))
  if (seconds < 60) return `${seconds} detik lalu`
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes} menit lalu`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours} jam lalu`
  return `${Math.floor(hours / 24)} hari lalu`
}

function OfflineCacheStatusPanel({
  isOnline,
  cache,
  allowances,
  queue,
  terminalName,
  warehouseName,
  sessionCode,
  busy,
  message,
  onRefresh,
  selectedProductId,
  onSelectProduct,
  onIssue,
  onRelease,
  onSync,
  onRefreshStatus,
  onOpenFinalReceipt,
}: {
  isOnline: boolean
  cache: OfflineCatalogReadResult | null
  allowances: OfflineAllowanceAvailability[]
  queue: OfflineSaleQueueRecord[]
  terminalName: string
  warehouseName: string
  sessionCode: string
  busy: boolean
  message: string
  onRefresh: () => void
  selectedProductId: string
  onSelectProduct: (productId: string) => void
  onIssue: () => void
  onRelease: (
    allowanceId: string,
    productId: string,
    masterVersion: number,
  ) => void
  onSync: (clientTransactionId: string) => void
  onRefreshStatus: (clientTransactionId: string) => void
  onOpenFinalReceipt: (record: OfflineSaleQueueRecord) => void
}) {
  const productNames = new Map(
    cache?.snapshot.productUoms.map((item) => [
      item.productId,
      `${item.name} · ${item.uomName}`,
    ]) ?? [],
  )
  const activeAllowanceProductIds = new Set(
    allowances.map((item) => item.productId),
  )
  const issueProducts = Array.from(
    new Map(
      (cache?.snapshot.productUoms ?? [])
        .filter(
          (item) =>
            item.offlineEligible &&
            item.stockBaseQty > 0 &&
            !activeAllowanceProductIds.has(item.productId),
        )
        .map((item) => [
          item.productId,
          {
            id: item.productId,
            name: item.name,
            stockBaseQty: item.stockBaseQty,
            baseUomName:
              cache?.snapshot.productUoms.find(
                (candidate) =>
                  candidate.productId === item.productId &&
                  candidate.factorToBase === 1,
              )?.uomName ?? 'Base UOM',
          },
        ]),
    ).values(),
  ).sort((left, right) => left.name.localeCompare(right.name, 'id'))
  const allowanceSnapshots = new Map(
    cache?.snapshot.allowances.map((item) => [item.id, item]) ?? [],
  )
  return (
    <section className="pos-offline-cache" aria-label="Status cache Offline">
      <div className="pos-offline-cache-heading">
        <div className="pos-offline-cache-icon">
          <Database className="h-5 w-5" />
        </div>
        <div>
          <p className="pos-eyebrow">Kesiapan dan cadangan Offline</p>
          <h2>
            {cache ? 'Snapshot tersimpan di perangkat' : 'Belum ada snapshot'}
          </h2>
        </div>
        <span
          className={`pos-offline-cache-badge ${
            cache ? 'is-cached' : 'is-blocked'
          }`}
        >
          {cache ? 'Cache tersedia' : 'Checkout diblokir'}
        </span>
      </div>

      <div className="pos-offline-cache-grid">
        <div>
          <span>Scope</span>
          <strong>{terminalName}</strong>
          <small>{warehouseName}</small>
        </div>
        <div>
          <span>Sesi</span>
          <strong>{sessionCode}</strong>
          <small>Terikat ke kasir aktif</small>
        </div>
        <div>
          <span>Snapshot terakhir</span>
          <strong>
            {cache
              ? new Date(cache.record.snapshotAt).toLocaleString('id-ID')
              : 'Belum tersedia'}
          </strong>
          <small>
            {cache
              ? formatCacheAge(cache.ageMs)
              : 'Perlu entitlement dan policy Terminal'}
          </small>
        </div>
        <div>
          <span>Allowance lokal</span>
          <strong>{allowances.length} produk</strong>
          <small>
            {cache
              ? 'Sudah dikurangi queue versi snapshot ini'
              : 'Belum dapat dihitung'}
          </small>
        </div>
      </div>

      {cache && (
        <div className="pos-offline-allowance-control">
          <div>
            <span className="pos-offline-control-label">
              Tambah cadangan produk
            </span>
            <p>
              Jumlah ditentukan server dari stok belum dicadangkan dan policy
              Terminal.
            </p>
          </div>
          <select
            value={selectedProductId}
            onChange={(event) => onSelectProduct(event.target.value)}
            disabled={busy || !isOnline || issueProducts.length === 0}
            aria-label="Pilih produk untuk cadangan Offline"
          >
            <option value="">
              {issueProducts.length > 0
                ? 'Pilih produk'
                : 'Semua produk tersedia sudah dicadangkan'}
            </option>
            {issueProducts.map((item) => (
              <option key={item.id} value={item.id}>
                {item.name} · stok {item.stockBaseQty.toLocaleString('id-ID')}{' '}
                {item.baseUomName}
              </option>
            ))}
          </select>
          <button
            type="button"
            disabled={busy || !isOnline || !selectedProductId}
            onClick={onIssue}
            className="pos-primary-button"
          >
            <Plus className="h-4 w-4" />
            Minta cadangan
          </button>
        </div>
      )}

      {allowances.length > 0 && (
        <div className="pos-offline-allowance-list">
          {allowances.map((item) => {
            const snapshot = allowanceSnapshots.get(item.allowanceId)
            const canRelease =
              isOnline &&
              !busy &&
              item.locallyQueuedBaseQty === 0 &&
              Number(snapshot?.consumedBaseQty ?? 0) === 0
            return (
              <div key={item.allowanceId}>
                <span>{productNames.get(item.productId) ?? 'Produk'}</span>
                <strong>
                  {item.locallyAvailableBaseQty.toLocaleString('id-ID')}{' '}
                  tersedia
                </strong>
                <small>
                  Server {item.serverRemainingBaseQty.toLocaleString('id-ID')}
                  {item.locallyQueuedBaseQty > 0
                    ? ` · antrean ${item.locallyQueuedBaseQty.toLocaleString('id-ID')}`
                    : ' · belum dipakai antrean'}
                </small>
                <button
                  type="button"
                  disabled={!canRelease || !snapshot}
                  onClick={() =>
                    snapshot &&
                    onRelease(
                      item.allowanceId,
                      item.productId,
                      snapshot.masterVersion,
                    )
                  }
                >
                  Lepaskan
                </button>
              </div>
            )
          })}
        </div>
      )}

      <div className="pos-offline-queue">
        <div className="pos-offline-queue-heading">
          <div>
            <span className="pos-offline-control-label">
              Antrean transaksi perangkat
            </span>
            <p>
              Record tetap disimpan setelah POSTED sebagai bukti acknowledgement.
            </p>
          </div>
          <strong>{queue.length}</strong>
        </div>
        {queue.length === 0 ? (
          <p className="pos-offline-queue-empty">
            Belum ada transaksi Offline pada sesi ini.
          </p>
        ) : (
          <div className="pos-offline-queue-list">
            {[...queue].reverse().map((record) => {
              const payload = JSON.parse(record.salePayload) as {
                lines?: unknown[]
              }
              const canSync =
                isOnline &&
                !busy &&
                !['POSTED', 'INVALIDATED'].includes(record.status)
              const requiresStatusCheck = [
                'SUBMITTING',
                'SYNCING',
                'NEEDS_CONFIRMATION',
              ].includes(record.status)
              const statusLabel: Record<
                OfflineSaleQueueRecord['status'],
                string
              > = {
                PENDING_SYNC: 'Menunggu sinkronisasi',
                SUBMITTING: 'Memeriksa server',
                QUEUED: 'Siap diproses',
                SYNCING: 'Sedang diproses',
                NEEDS_CONFIRMATION: 'Perlu diperiksa',
                FAILED: 'Gagal — bisa dicoba lagi',
                POSTED: 'Sudah menjadi invoice',
                INVALIDATED: 'Dibatalkan server',
              }
              return (
                <article key={record.clientTransactionId}>
                  <div>
                    <strong>
                      OFF-{record.clientTransactionId.slice(0, 8).toUpperCase()}
                    </strong>
                    <span className={`is-${record.status.toLowerCase()}`}>
                      {statusLabel[record.status]}
                    </span>
                  </div>
                  <p>
                    {payload.lines?.length ?? 0} item ·{' '}
                    {new Date(record.localTransactionAt).toLocaleString('id-ID')}
                  </p>
                  {record.errorCode && (
                    <small>{friendlyError(record.errorCode)}</small>
                  )}
                  <footer>
                    {record.status === 'POSTED' ? (
                      <button
                        type="button"
                        disabled={!isOnline || busy}
                        onClick={() => onOpenFinalReceipt(record)}
                      >
                        Buka invoice final
                      </button>
                    ) : record.status === 'INVALIDATED' ? (
                      <span>Transaksi ini tidak boleh dikirim ulang.</span>
                    ) : requiresStatusCheck ? (
                      <button
                        type="button"
                        disabled={!canSync}
                        onClick={() =>
                          onRefreshStatus(record.clientTransactionId)
                        }
                      >
                        Periksa status
                      </button>
                    ) : (
                      <button
                        type="button"
                        disabled={!canSync}
                        onClick={() => onSync(record.clientTransactionId)}
                      >
                        {record.status === 'FAILED'
                          ? 'Periksa & coba lagi'
                          : 'Sinkronkan'}
                      </button>
                    )}
                  </footer>
                </article>
              )
            })}
          </div>
        )}
      </div>

      <div className="pos-offline-cache-footer">
        <p>
          {message ||
            'Transaksi Offline hanya dapat disimpan bila snapshot dan cadangan stok mencukupi.'}
        </p>
        <button
          type="button"
          disabled={busy || !isOnline}
          onClick={onRefresh}
          className="pos-secondary-button"
        >
          <RefreshCw className={`h-4 w-4 ${busy ? 'animate-spin' : ''}`} />
          {busy ? 'Memeriksa…' : 'Perbarui snapshot'}
        </button>
      </div>
    </section>
  )
}

function QuickCustomerModal({
  companyId,
  companyName,
  busy,
  close,
  complete,
}: {
  companyId: string
  companyName: string
  busy: boolean
  close: () => void
  complete: (customerId: string) => Promise<void>
}) {
  const [form, setForm] = useState({
    name: '',
    type: 'INDIVIDUAL' as 'INDIVIDUAL' | 'BUSINESS',
    phone: '',
    email: '',
    address: '',
  })
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')

  async function submit(event: React.FormEvent) {
    event.preventDefault()
    if (!form.name.trim()) return
    setSaving(true)
    setError('')
    try {
      const created = await quickCreatePosCustomer(form)
      if (created.companyId !== companyId) {
        throw new Error('CUSTOMER_COMPANY_SCOPE_MISMATCH')
      }
      await complete(created.customerId)
    } catch (reason) {
      setError(friendlyError(errorMessage(reason)))
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="pos-action-dialog-overlay fixed inset-0 z-[60] grid place-items-center bg-black/65 p-4">
      <section
        role="dialog"
        aria-modal="true"
        aria-labelledby="pos-quick-customer-title"
        className="pos-action-dialog pos-quick-customer-dialog w-full max-w-lg bg-white shadow-2xl"
      >
        <header className="flex items-start justify-between gap-4">
          <div className="pos-action-dialog-icon">
            <UserPlus className="h-5 w-5" />
          </div>
          <button
            type="button"
            onClick={close}
            className="pos-modal-close"
            aria-label="Tutup form Customer"
          >
            <X className="h-5 w-5" />
          </button>
        </header>
        <h2
          id="pos-quick-customer-title"
          className="mt-4 text-xl font-black text-slate-900"
        >
          Tambah Customer
        </h2>
        <p className="mt-2 text-sm leading-6 text-slate-600">
          Customer hanya dibuat untuk Company aktif: <b>{companyName}</b>.
          Kode Customer dibuat otomatis oleh sistem.
        </p>
        <form onSubmit={submit} className="pos-quick-customer-form mt-5">
          <label>
            <span>Nama Customer</span>
            <input
              autoFocus
              required
              maxLength={200}
              value={form.name}
              onChange={(event) =>
                setForm((current) => ({ ...current, name: event.target.value }))
              }
              placeholder="Contoh: Toko Berkah"
            />
          </label>
          <label>
            <span>Tipe Customer</span>
            <select
              value={form.type}
              onChange={(event) =>
                setForm((current) => ({
                  ...current,
                  type: event.target.value as 'INDIVIDUAL' | 'BUSINESS',
                }))
              }
            >
              <option value="INDIVIDUAL">Perorangan</option>
              <option value="BUSINESS">Bisnis / Toko</option>
            </select>
          </label>
          <label>
            <span>Nomor telepon (opsional)</span>
            <input
              maxLength={100}
              value={form.phone}
              onChange={(event) =>
                setForm((current) => ({ ...current, phone: event.target.value }))
              }
              inputMode="tel"
            />
          </label>
          <label>
            <span>Email (opsional)</span>
            <input
              type="email"
              maxLength={320}
              value={form.email}
              onChange={(event) =>
                setForm((current) => ({ ...current, email: event.target.value }))
              }
            />
          </label>
          <label className="is-wide">
            <span>Alamat (opsional)</span>
            <textarea
              rows={2}
              maxLength={1000}
              value={form.address}
              onChange={(event) =>
                setForm((current) => ({
                  ...current,
                  address: event.target.value,
                }))
              }
            />
          </label>
          {error && (
            <div className="is-wide rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">
              {error}
            </div>
          )}
          <footer className="is-wide mt-2 grid grid-cols-2 gap-2">
            <button
              type="button"
              disabled={saving || busy}
              onClick={close}
              className="pos-dialog-secondary"
            >
              Batal
            </button>
            <button
              type="submit"
              disabled={saving || busy || !form.name.trim()}
              className="pos-dialog-primary"
            >
              {saving || busy ? 'Menyimpan…' : 'Simpan Customer'}
            </button>
          </footer>
        </form>
      </section>
    </div>
  )
}

function InlineAlert({
  tone,
  text,
}: {
  tone: 'error' | 'success'
  text: string
}) {
  return (
    <div
      className={`my-3 flex items-start gap-2 rounded-xl border px-4 py-3 text-sm ${
        tone === 'error'
          ? 'border-rose-900 bg-rose-950 text-rose-200'
          : 'border-emerald-900 bg-emerald-950 text-emerald-200'
      }`}
    >
      {tone === 'error' ? (
        <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
      ) : (
        <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" />
      )}
      <span>{text}</span>
    </div>
  )
}

function SessionOpenPanel({
  bootstrap,
  terminalId,
  warehouseId,
  openingCash,
  availableWarehouses,
  busy,
  onTerminalChange,
  onWarehouseChange,
  onOpeningCashChange,
  onSubmit,
}: {
  bootstrap: BootstrapData | null
  terminalId: string
  warehouseId: string
  openingCash: string
  availableWarehouses: BootstrapData['warehouses']
  busy: boolean
  onTerminalChange: (value: string) => void
  onWarehouseChange: (value: string) => void
  onOpeningCashChange: (value: string) => void
  onSubmit: (event: React.FormEvent) => void
}) {
  return (
    <form
      onSubmit={onSubmit}
      className="pos-session-open mx-auto max-w-2xl rounded-3xl border border-slate-800 bg-slate-900 p-6"
    >
      <div className="flex items-start gap-3">
        <div className="rounded-2xl bg-emerald-500 p-3 text-slate-950">
          <Banknote className="h-6 w-6" />
        </div>
        <div>
          <h2 className="text-2xl font-black">Buka Sesi Kasir</h2>
          <p className="mt-1 text-sm text-slate-400">
            Pilih Terminal dan Gudang penjualan, lalu hitung modal kas fisik.
          </p>
        </div>
      </div>
      <div className="mt-6 grid gap-4 sm:grid-cols-2">
        <label className="text-sm font-semibold text-slate-300">
          Terminal POS
          <div className="relative mt-2">
            <select
              required
              value={terminalId}
              onChange={(event) => onTerminalChange(event.target.value)}
              className="w-full appearance-none rounded-xl border border-slate-700 bg-slate-950 px-4 py-3"
            >
              {(bootstrap?.terminals ?? []).map((terminal) => (
                <option key={terminal.id} value={terminal.id}>
                  {terminal.name} · {terminal.storeName}
                </option>
              ))}
            </select>
            <ChevronDown className="pointer-events-none absolute right-3 top-3.5 h-4 w-4 text-slate-500" />
          </div>
        </label>
        <label className="text-sm font-semibold text-slate-300">
          Gudang penjualan
          <select
            required
            value={warehouseId}
            onChange={(event) => onWarehouseChange(event.target.value)}
            className="mt-2 w-full rounded-xl border border-slate-700 bg-slate-950 px-4 py-3"
          >
            {availableWarehouses.map((warehouse) => (
              <option key={warehouse.id} value={warehouse.id}>
                {warehouse.name}
              </option>
            ))}
          </select>
        </label>
      </div>
      <label className="mt-4 block text-sm font-semibold text-slate-300">
        Modal kas fisik
        <CurrencyInput
          required
          value={openingCash}
          onValueChange={onOpeningCashChange}
          className="mt-2 w-full rounded-xl border border-slate-700 bg-slate-950 px-4 py-3"
        />
      </label>
      {(bootstrap?.terminals.length ?? 0) === 0 && (
        <InlineAlert
          tone="error"
          text="Tidak ada Terminal dengan assignment Cashier aktif untuk user ini."
        />
      )}
      <button
        disabled={
          busy ||
          !terminalId ||
          !warehouseId ||
          (bootstrap?.terminals.length ?? 0) === 0
        }
        className="mt-6 flex w-full items-center justify-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 font-black text-slate-950 disabled:opacity-40"
      >
        <UserRound className="h-5 w-5" />
        {busy ? 'Membuka sesi…' : 'Buka Sesi'}
      </button>
    </form>
  )
}
