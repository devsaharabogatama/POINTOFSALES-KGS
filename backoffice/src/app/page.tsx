'use client'

import { useCallback, useEffect, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  ArrowLeft,
  ArrowRightLeft,
  BadgePercent,
  BanknoteArrowUp,
  BellRing,
  Boxes,
  Building2,
  ChevronDown,
  ChevronRight,
  CircleAlert,
  ClipboardCheck,
  ClipboardPenLine,
  ContactRound,
  CreditCard,
  DollarSign,
  FileSpreadsheet,
  House,
  Landmark,
  LayoutDashboard,
  Loader2,
  LogOut,
  Menu,
  PackageSearch,
  PackagePlus,
  PackageMinus,
  ScrollText,
  ShoppingCart,
  RotateCcw,
  ShieldCheck,
  Settings2,
  Store,
  Tags,
  Truck,
  UserPlus,
  Users,
  WalletCards,
  X,
} from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { MasterDataView } from '@/components/MasterDataView'
import { CanonicalProductsView } from '@/components/CanonicalProductsView'
import { SupplierMasterView } from '@/components/SupplierMasterView'
import { CustomerMasterView } from '@/components/CustomerMasterView'
import { PricelistMasterView } from '@/components/PricelistMasterView'
import { PaymentMethodMasterView } from '@/components/PaymentMethodMasterView'
import { FinanceMasterView } from '@/components/FinanceMasterView'
import { TaxMasterView } from '@/components/TaxMasterView'
import { ModuleSettingsView } from '@/components/ModuleSettingsView'
import { MasterImportView } from '@/components/MasterImportView'
import { MinimumStockView } from '@/components/MinimumStockView'
import { OpeningStockView } from '@/components/OpeningStockView'
import { StockRealView } from '@/components/StockRealView'
import { StockMovementView } from '@/components/StockMovementView'
import { StockTransferView } from '@/components/StockTransferView'
import { StockAdjustmentView } from '@/components/StockAdjustmentView'
import { StockOpnameView } from '@/components/StockOpnameView'
import { BundleMasterView } from '@/components/BundleMasterView'
import { SalesReturnApprovalView } from '@/components/SalesReturnApprovalView'
import { ExpenseApprovalView } from '@/components/ExpenseApprovalView'
import { CashDepositApprovalView } from '@/components/CashDepositApprovalView'
import { DepositVarianceResolutionView } from '@/components/DepositVarianceResolutionView'
import { CustomerBalanceView } from '@/components/CustomerBalanceView'
import { SupplierOrderView } from '@/components/SupplierOrderView'
import { PurchaseReturnApprovalView } from '@/components/PurchaseReturnApprovalView'
import { useEscapeClose } from '@/lib/use-escape-close'

type View = 'dashboard' | 'masters' | 'master-imports' | 'products' | 'bundles' | 'sales-returns' | 'expense-approvals' | 'cash-deposits' | 'deposit-variances' | 'customer-balances' | 'stock-real' | 'stock-movements' | 'stock-transfers' | 'stock-adjustments' | 'stock-opnames' | 'opening-stock' | 'minimum-stock' | 'suppliers' | 'supplier-orders' | 'purchase-returns' | 'customers' | 'pricelists' | 'payment-methods' | 'finance-masters' | 'tax-rules' | 'finance' | 'staff' | 'companies' | 'module-settings'

type CompanyContext = {
  id: string
  company_code: string
  company_name: string
  status: string
  roleCode: string
  isDefault: boolean
}

type UserContext = {
  profile: { id: string; name: string; email: string; role: string }
  isSuperAdmin: boolean
  activeCompanyId: string | null
  companies: CompanyContext[]
}

type ProductStockRow = {
  stock_qty: number | string
  warehouses: { code: string; name: string } | null
}

type ProductRow = {
  id: string
  sku: string
  name: string
  category: string | null
  price: number | string
  cogs: number | string
  uom: string
  base_uom?: { name: string } | null
  weight_per_uom_kg?: number | string
  product_stocks: ProductStockRow[] | null
}

type Product = {
  id: string
  sku: string
  name: string
  category: string
  price: number
  cogs: number
  uom: string
  weightPerUomKg: number
  stock: number
  locations: string
}

type StaffMembershipRow = {
  user_id: string
  role_code: string
  status: string
  profiles: { name: string; email: string } | null
}

type Staff = {
  id: string
  name: string
  email: string
  role: string
  status: string
}

type StoreOption = { id: string; store_code: string; store_name: string }
type JournalEntry = { id: string; journalNo: string; date: string; account: string; debit: number; credit: number; note: string }

type NavigationItem = {
  id: View
  label: string
  icon: typeof LayoutDashboard
  roles?: string[]
  superOnly?: boolean
}

const INVENTORY_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER', 'WAREHOUSE_ADMIN']
const STOCK_REAL_ROLES = [...INVENTORY_ROLES, 'FINANCE', 'ACCOUNTING']
const STOCK_TRANSFER_OPERATOR_ROLES = [
  'COMPANY_OWNER',
  'COMPANY_ADMIN',
  'WAREHOUSE_ADMIN',
]
const STOCK_ADJUSTMENT_OPERATOR_ROLES = [
  'COMPANY_OWNER',
  'COMPANY_ADMIN',
  'STORE_MANAGER',
]
const OPENING_STOCK_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER', 'FINANCE', 'ACCOUNTING']
const SUPPLIER_ROLES = [...INVENTORY_ROLES, 'FINANCE', 'ACCOUNTING']
const PURCHASE_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER']
const SALES_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER', 'FINANCE', 'ACCOUNTING']
const SALES_RETURN_APPROVER_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER']
const EXPENSE_REVIEW_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER', 'FINANCE', 'ACCOUNTING']
const EXPENSE_APPROVER_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER', 'FINANCE']
const FINANCE_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'FINANCE', 'ACCOUNTING']
const CASH_DEPOSIT_APPROVER_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN', 'FINANCE']
const OWNER_ROLES = ['COMPANY_OWNER', 'COMPANY_ADMIN']

const navigation: NavigationItem[] = [
  { id: 'dashboard', label: 'Aplikasi', icon: LayoutDashboard },
  { id: 'masters', label: 'Master Inventory', icon: Truck, roles: INVENTORY_ROLES },
  { id: 'master-imports', label: 'Import & Export', icon: FileSpreadsheet, roles: OWNER_ROLES },
  { id: 'products', label: 'Produk & UOM', icon: Boxes, roles: INVENTORY_ROLES },
  { id: 'stock-real', label: 'Stock Real', icon: PackageSearch, roles: STOCK_REAL_ROLES },
  { id: 'stock-movements', label: 'Kartu Stok', icon: ScrollText, roles: STOCK_REAL_ROLES },
  { id: 'stock-transfers', label: 'Transfer Stok', icon: ArrowRightLeft, roles: STOCK_REAL_ROLES },
  { id: 'stock-adjustments', label: 'Penyesuaian Stok', icon: ClipboardPenLine, roles: STOCK_REAL_ROLES },
  { id: 'stock-opnames', label: 'Stock Opname', icon: ClipboardCheck, roles: STOCK_REAL_ROLES },
  { id: 'opening-stock', label: 'Stok Awal', icon: PackagePlus, roles: OPENING_STOCK_ROLES },
  { id: 'minimum-stock', label: 'Minimum Stock', icon: BellRing, roles: INVENTORY_ROLES },
  { id: 'customers', label: 'Pelanggan', icon: ContactRound, roles: SALES_ROLES },
  { id: 'suppliers', label: 'Supplier', icon: PackageSearch, roles: SUPPLIER_ROLES },
  { id: 'supplier-orders', label: 'Supplier Order', icon: ShoppingCart, roles: PURCHASE_ROLES },
  { id: 'purchase-returns', label: 'Retur Pembelian', icon: PackageMinus, roles: PURCHASE_ROLES },
  { id: 'staff', label: 'User & Akses', icon: Users, roles: OWNER_ROLES },
  { id: 'pricelists', label: 'Pricelist', icon: Tags, roles: SALES_ROLES },
  { id: 'bundles', label: 'Bundle', icon: Boxes, roles: SALES_ROLES },
  { id: 'sales-returns', label: 'Approval Return', icon: RotateCcw, roles: SALES_RETURN_APPROVER_ROLES },
  { id: 'expense-approvals', label: 'Expense', icon: DollarSign, roles: EXPENSE_REVIEW_ROLES },
  { id: 'cash-deposits', label: 'Setor Kas', icon: BanknoteArrowUp, roles: FINANCE_ROLES },
  { id: 'deposit-variances', label: 'Selisih Setoran', icon: CircleAlert, roles: FINANCE_ROLES },
  { id: 'customer-balances', label: 'Saldo Customer', icon: WalletCards, roles: FINANCE_ROLES },
  { id: 'payment-methods', label: 'Metode Pembayaran', icon: CreditCard, roles: FINANCE_ROLES },
  { id: 'tax-rules', label: 'Aturan Pajak', icon: BadgePercent, roles: FINANCE_ROLES },
  { id: 'finance-masters', label: 'Kategori & COA', icon: Landmark, roles: FINANCE_ROLES },
  { id: 'finance', label: 'Jurnal Keuangan', icon: DollarSign, roles: FINANCE_ROLES },
  { id: 'companies', label: 'Perusahaan', icon: Building2, superOnly: true },
  { id: 'module-settings', label: 'Pengaturan Modul', icon: Settings2, roles: ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER'] },
]

const appModules: {
  id: string; name: string; description: string; icon: typeof Boxes
  color: string; views: View[]
}[] = [
  { id: 'inventory', name: 'Inventory', description: 'Stock Real, Kartu Stok, Transfer, Penyesuaian, dan review Stock Opname; Product, gudang, stok awal, minimum stok, serta alat import master.', icon: Boxes, color: 'bg-blue-600', views: ['stock-real', 'stock-movements', 'stock-transfers', 'stock-adjustments', 'stock-opnames', 'products', 'opening-stock', 'minimum-stock', 'masters', 'master-imports'] },
  { id: 'contacts', name: 'Kontak', description: 'Data pelanggan, supplier, serta user Company.', icon: ContactRound, color: 'bg-cyan-600', views: ['customers', 'suppliers', 'staff'] },
  { id: 'purchase', name: 'Purchase', description: 'Permintaan stok, Supplier Order, penerimaan, dan approval Retur Pembelian.', icon: ShoppingCart, color: 'bg-amber-600', views: ['supplier-orders', 'purchase-returns'] },
  { id: 'sales', name: 'Sales', description: 'Pricelist, Bundle, dan approval Return Penjualan.', icon: Tags, color: 'bg-emerald-600', views: ['pricelists', 'bundles', 'sales-returns'] },
  { id: 'finance', name: 'Finance', description: 'Approval Expense, Setor Kas, selisih, Saldo Customer, metode pembayaran, pajak, kategori transaksi, COA, dan jurnal.', icon: Landmark, color: 'bg-violet-600', views: ['expense-approvals', 'cash-deposits', 'deposit-variances', 'customer-balances', 'payment-methods', 'tax-rules', 'finance-masters', 'finance'] },
  { id: 'platform', name: 'Platform', description: 'Company dan entitlement modul.', icon: Settings2, color: 'bg-slate-800', views: ['companies', 'module-settings'] },
]

function visibleNavigation(isSuperAdmin: boolean, roleCode: string) {
  return navigation.filter((item) =>
    (!item.superOnly || isSuperAdmin) &&
    (!item.roles || isSuperAdmin || item.roles.includes(roleCode)),
  )
}

const roleLabels: Record<string, string> = {
  SUPER_ADMIN: 'Platform Super Admin',
  COMPANY_OWNER: 'Pemilik Perusahaan',
  COMPANY_ADMIN: 'Admin Perusahaan',
  STORE_MANAGER: 'Manajer Toko',
  WAREHOUSE_ADMIN: 'Admin Gudang',
  FINANCE: 'Finance',
  ACCOUNTING: 'Accounting',
  CASHIER: 'Kasir',
}

function rupiah(value: number) {
  return new Intl.NumberFormat('id-ID', {
    style: 'currency',
    currency: 'IDR',
    maximumFractionDigits: 0,
  }).format(value)
}

function authHeaders(session: Session) {
  return { Authorization: `Bearer ${session.access_token}` }
}

function messageFromError(error: unknown, fallback: string) {
  if (error instanceof Error) return error.message
  if (
    typeof error === 'object' &&
    error !== null &&
    'message' in error &&
    typeof error.message === 'string'
  ) {
    return error.message
  }
  return fallback
}

export default function Home() {
  const [session, setSession] = useState<Session | null>(null)
  const [checkingSession, setCheckingSession] = useState(true)
  const [context, setContext] = useState<UserContext | null>(null)
  const [activeCompanyId, setActiveCompanyId] = useState('')
  const [switchingCompany, setSwitchingCompany] = useState(false)
  const [activeView, setActiveView] = useState<View>('dashboard')
  const [viewHistory, setViewHistory] = useState<View[]>([])
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const [products, setProducts] = useState<Product[]>([])
  const [staff, setStaff] = useState<Staff[]>([])
  const [stores, setStores] = useState<StoreOption[]>([])
  const [journal, setJournal] = useState<JournalEntry[]>([])
  const [loadingData, setLoadingData] = useState(false)
  const [notice, setNotice] = useState<string | null>(null)
  const [showStaff, setShowStaff] = useState(false)
  const [showTenant, setShowTenant] = useState(false)

  useEffect(() => {
    void supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
      setCheckingSession(false)
    })
    const { data } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      setSession(nextSession)
      if (!nextSession) {
        setContext(null)
        setActiveCompanyId('')
      }
      setCheckingSession(false)
    })
    return () => data.subscription.unsubscribe()
  }, [])

  const loadContext = useCallback(async (activeSession: Session) => {
    const response = await fetch('/api/me/context', { headers: authHeaders(activeSession) })
    const payload = (await response.json()) as UserContext & { error?: string }
    if (!response.ok) throw new Error(payload.error ?? 'Gagal memuat konteks akun')

    const storageKey = `kgs-active-company:${activeSession.user.id}`
    const savedCompany = localStorage.getItem(storageKey)
    const selected =
      payload.companies.find((company) => company.id === payload.activeCompanyId) ??
      payload.companies.find((company) => company.id === savedCompany) ??
      payload.companies.find((company) => company.isDefault) ??
      payload.companies[0]
    const selectedId = selected?.id ?? ''
    if (selectedId && selectedId !== payload.activeCompanyId) {
      const selectResponse = await fetch('/api/me/active-company', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...authHeaders(activeSession) },
        body: JSON.stringify({ companyId: selectedId, source: 'BACKOFFICE_INIT' }),
      })
      const selectPayload = (await selectResponse.json()) as { error?: string }
      if (!selectResponse.ok) {
        throw new Error(selectPayload.error ?? 'Gagal menyimpan konteks perusahaan')
      }
    }

    if (selectedId) localStorage.setItem(storageKey, selectedId)
    setContext({ ...payload, activeCompanyId: selectedId || null })
    setActiveCompanyId(selectedId)
  }, [])

  useEffect(() => {
    if (!session) return
    // eslint-disable-next-line react-hooks/set-state-in-effect -- account context follows the authenticated session
    void loadContext(session).catch(async (error: unknown) => {
      const code = error instanceof Error ? error.message : ''
      if (code === 'INVALID_SESSION') {
        await supabase.auth.signOut({ scope: 'local' })
        setSession(null)
        setContext(null)
        setActiveCompanyId('')
        setNotice('Sesi login sudah kedaluwarsa. Silakan masuk kembali.')
        return
      }
      setNotice(messageFromError(error, 'Gagal memuat akun'))
    })
  }, [session, loadContext])

  const loadTenantData = useCallback(async () => {
    if (!session || !activeCompanyId) return
    setLoadingData(true)
    setNotice(null)
    try {
      const initialProductQuery = await supabase
        .from('products')
        .select('id, sku, name, category, price, cogs, uom, weight_per_uom_kg, base_uom:uoms!fk_products_company_uom(name), product_stocks!product_stocks_product_id_fkey(stock_qty, warehouses!product_stocks_warehouse_id_fkey(code, name))')
        .eq('company_id', activeCompanyId)
        .eq('is_active', true)
        .order('name')
      let productData = initialProductQuery.data
      let productError = initialProductQuery.error

      // Lets the UI remain readable before migration 002 is applied.
      if (productError?.message.includes('weight_per_uom_kg')) {
        const fallbackProductQuery = await supabase
          .from('products')
          .select('id, sku, name, category, price, cogs, uom, product_stocks!product_stocks_product_id_fkey(stock_qty, warehouses!product_stocks_warehouse_id_fkey(code, name))')
          .eq('company_id', activeCompanyId)
          .eq('is_active', true)
          .order('name')
        productData = fallbackProductQuery.data as typeof productData
        productError = fallbackProductQuery.error
      }
      if (productError) throw productError

      const rows = (productData ?? []) as unknown as ProductRow[]
      setProducts(
        rows.map((product) => ({
          id: product.id,
          sku: product.sku,
          name: product.name,
          category: product.category ?? 'Tanpa kategori',
          price: Number(product.price) || 0,
          cogs: Number(product.cogs) || 0,
          uom: product.base_uom?.name ?? product.uom,
          weightPerUomKg: Number(product.weight_per_uom_kg) || 0,
          stock: (product.product_stocks ?? []).reduce(
            (total, item) => total + (Number(item.stock_qty) || 0),
            0,
          ),
          locations: (product.product_stocks ?? [])
            .map((item) => item.warehouses?.code)
            .filter(Boolean)
            .join(', '),
        })),
      )

      const [
        { data: membershipRows, error: staffError },
        { data: storeRows, error: storeError },
        { data: journalRows, error: journalError },
      ] =
        await Promise.all([
          supabase
            .from('company_memberships')
            .select('user_id, role_code, status, profiles(name, email)')
            .eq('company_id', activeCompanyId)
            .order('created_at'),
          supabase
            .from('stores')
            .select('id, store_code, store_name')
            .eq('company_id', activeCompanyId)
            .eq('status', 'ACTIVE')
            .order('store_name'),
          supabase
            .from('journal_entries')
            .select('id, journal_no, transaction_date, coa_code, coa_name, debit, kredit, note')
            .eq('company_id', activeCompanyId)
            .order('transaction_date', { ascending: false })
            .limit(100),
        ])
      if (staffError) throw staffError
      if (storeError) throw storeError
      if (journalError) throw journalError

      setStaff(
        ((membershipRows ?? []) as unknown as StaffMembershipRow[]).map((membership) => ({
          id: membership.user_id,
          name: membership.profiles?.name ?? 'Pengguna',
          email: membership.profiles?.email ?? '-',
          role: membership.role_code,
          status: membership.status,
        })),
      )
      setStores((storeRows ?? []) as StoreOption[])
      setJournal(
        ((journalRows ?? []) as { id: string; journal_no: string; transaction_date: string; coa_code: string; coa_name: string; debit: number | string; kredit: number | string; note: string | null }[]).map((entry) => ({
          id: entry.id,
          journalNo: entry.journal_no,
          date: entry.transaction_date,
          account: `${entry.coa_code} · ${entry.coa_name}`,
          debit: Number(entry.debit) || 0,
          credit: Number(entry.kredit) || 0,
          note: entry.note ?? '-',
        })),
      )
    } catch (error) {
      setNotice(messageFromError(error, 'Gagal memuat data perusahaan'))
    } finally {
      setLoadingData(false)
    }
  }, [activeCompanyId, session])

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- data loading is synchronized to active tenant context
    void loadTenantData()
  }, [loadTenantData])

  const activeCompany = context?.companies.find((company) => company.id === activeCompanyId)
  const canManage = context?.isSuperAdmin || ['COMPANY_OWNER', 'COMPANY_ADMIN'].includes(activeCompany?.roleCode ?? '')
  const canPrepareOpeningStock =
    context?.isSuperAdmin ||
    OPENING_STOCK_ROLES.includes(activeCompany?.roleCode ?? '')
  const canOperateStockTransfer =
    context?.isSuperAdmin ||
    STOCK_TRANSFER_OPERATOR_ROLES.includes(activeCompany?.roleCode ?? '')
  const canOperateStockAdjustment =
    context?.isSuperAdmin ||
    STOCK_ADJUSTMENT_OPERATOR_ROLES.includes(activeCompany?.roleCode ?? '')
  const canReviewStockOpname =
    context?.isSuperAdmin ||
    STOCK_ADJUSTMENT_OPERATOR_ROLES.includes(activeCompany?.roleCode ?? '')
  const canManageMaster =
    context?.isSuperAdmin ||
    ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER', 'WAREHOUSE_ADMIN'].includes(
      activeCompany?.roleCode ?? '',
    )
  const canManageSupplier =
    context?.isSuperAdmin ||
    ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER', 'FINANCE', 'ACCOUNTING'].includes(
      activeCompany?.roleCode ?? '',
    )
  const canManageProductSupplier =
    context?.isSuperAdmin ||
    ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER', 'WAREHOUSE_ADMIN'].includes(
      activeCompany?.roleCode ?? '',
    )
  const canOperateSupplierOrder =
    context?.isSuperAdmin ||
    PURCHASE_ROLES.includes(activeCompany?.roleCode ?? '')
  const canManageCustomerIdentity =
    context?.isSuperAdmin ||
    ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER'].includes(activeCompany?.roleCode ?? '')
  const canManageCustomerCredit =
    context?.isSuperAdmin ||
    ['COMPANY_OWNER', 'COMPANY_ADMIN', 'FINANCE', 'ACCOUNTING'].includes(
      activeCompany?.roleCode ?? '',
    )
  const canManagePricelist =
    context?.isSuperAdmin ||
    ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER'].includes(activeCompany?.roleCode ?? '')
  const canApproveSalesReturn =
    context?.isSuperAdmin ||
    SALES_RETURN_APPROVER_ROLES.includes(activeCompany?.roleCode ?? '')
  const canApproveExpense =
    context?.isSuperAdmin ||
    EXPENSE_APPROVER_ROLES.includes(activeCompany?.roleCode ?? '')
  const canApproveCashDeposit =
    context?.isSuperAdmin ||
    CASH_DEPOSIT_APPROVER_ROLES.includes(activeCompany?.roleCode ?? '')
  const canManageDepositVariance =
    context?.isSuperAdmin ||
    ['COMPANY_OWNER', 'COMPANY_ADMIN', 'FINANCE'].includes(
      activeCompany?.roleCode ?? '',
    )
  const canReviewDepositVariance =
    context?.isSuperAdmin ||
    ['COMPANY_OWNER', 'COMPANY_ADMIN'].includes(activeCompany?.roleCode ?? '')
  const canCancelExpenseAdministrative =
    context?.isSuperAdmin ||
    ['COMPANY_OWNER', 'COMPANY_ADMIN', 'STORE_MANAGER'].includes(
      activeCompany?.roleCode ?? '',
    )
  const canDisburseExpenseNonCash =
    context?.isSuperAdmin ||
    ['COMPANY_OWNER', 'COMPANY_ADMIN', 'FINANCE'].includes(
      activeCompany?.roleCode ?? '',
    )
  const canManagePaymentMethod =
    context?.isSuperAdmin ||
    ['COMPANY_OWNER', 'COMPANY_ADMIN', 'FINANCE', 'ACCOUNTING'].includes(
      activeCompany?.roleCode ?? '',
    )
  const canManageFinanceMaster =
    context?.isSuperAdmin ||
    ['COMPANY_OWNER', 'COMPANY_ADMIN', 'FINANCE', 'ACCOUNTING'].includes(
      activeCompany?.roleCode ?? '',
    )

  const navigateTo = useCallback((nextView: View) => {
    if (nextView === activeView) return
    setViewHistory((current) => [...current, activeView].slice(-20))
    setActiveView(nextView)
  }, [activeView])

  const goBack = useCallback(() => {
    const previousView = viewHistory.at(-1) ?? 'dashboard'
    setViewHistory((current) => current.slice(0, -1))
    setActiveView(previousView)
  }, [viewHistory])

  const goHome = useCallback(() => {
    setViewHistory([])
    setActiveView('dashboard')
  }, [])

  async function changeCompany(companyId: string) {
    if (!session || companyId === activeCompanyId || switchingCompany) return
    setSwitchingCompany(true)
    setNotice(null)
    try {
      const response = await fetch('/api/me/active-company', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', ...authHeaders(session) },
        body: JSON.stringify({ companyId, source: 'BACKOFFICE_SELECTOR' }),
      })
      const payload = (await response.json()) as { activeCompanyId?: string; error?: string }
      if (!response.ok || payload.activeCompanyId !== companyId) {
        throw new Error(payload.error ?? 'Gagal mengganti perusahaan aktif')
      }

      localStorage.setItem(`kgs-active-company:${session.user.id}`, companyId)
      setContext((current) => current ? { ...current, activeCompanyId: companyId } : current)
      setActiveCompanyId(companyId)
      goHome()
    } catch (error) {
      setNotice(messageFromError(error, 'Gagal mengganti perusahaan aktif'))
    } finally {
      setSwitchingCompany(false)
    }
  }

  async function logout() {
    await supabase.auth.signOut()
    setSession(null)
    setContext(null)
    setActiveCompanyId('')
  }

  if (checkingSession) return <FullScreenLoader label="Menyiapkan backoffice" />
  if (!session) return <LoginScreen />

  if (!context) {
    return <FullScreenLoader label="Memuat akses perusahaan" notice={notice} />
  }

  if (!activeCompany) {
    return (
      <div className="min-h-screen bg-slate-50 grid place-items-center p-6">
        <div className="max-w-md rounded-3xl border border-slate-200 bg-white p-8 text-center shadow-sm">
          <CircleAlert className="mx-auto h-10 w-10 text-amber-500" />
          <h1 className="mt-4 text-xl font-bold text-slate-950">Belum ada akses perusahaan</h1>
          <p className="mt-2 text-sm leading-6 text-slate-500">
            Akun ini belum memiliki membership aktif. Minta platform admin atau pemilik perusahaan menambahkan akses.
          </p>
          <button onClick={logout} className="mt-6 rounded-xl bg-slate-950 px-5 py-2.5 text-sm font-semibold text-white">
            Keluar
          </button>
        </div>
      </div>
    )
  }

  const availableNavigation = visibleNavigation(
    context.isSuperAdmin,
    activeCompany.roleCode,
  )

  return (
    <div className="min-h-screen bg-[#f6f7f9] text-slate-900">
      <Sidebar
        view={activeView}
        navigate={navigateTo}
        goHome={goHome}
        items={availableNavigation}
        open={sidebarOpen}
        close={() => setSidebarOpen(false)}
      />

      <div>
        <header className="sticky top-0 z-30 flex h-20 items-center gap-4 border-b border-slate-200/80 bg-white/95 px-4 backdrop-blur md:px-8">
          <button onClick={() => setSidebarOpen((current) => !current)} className="rounded-xl border border-slate-200 p-2.5" aria-label={sidebarOpen ? 'Tutup fast link' : 'Buka fast link'} aria-expanded={sidebarOpen}>
            <Menu className="h-5 w-5" />
          </button>

          <div className="min-w-0 flex-1">
            <p className="text-xs font-semibold uppercase tracking-[0.16em] text-emerald-600">Workspace aktif</p>
            {context.companies.length > 1 ? (
              <div className="relative mt-1 inline-flex max-w-full items-center">
                <Building2 className="pointer-events-none absolute left-3 h-4 w-4 text-slate-400" />
                <select
                  value={activeCompanyId}
                  onChange={(event) => void changeCompany(event.target.value)}
                  disabled={switchingCompany}
                  className="max-w-full appearance-none rounded-xl border border-slate-200 bg-slate-50 py-2 pl-9 pr-9 text-sm font-bold text-slate-800 outline-none transition focus:border-emerald-500"
                >
                  {context.companies.map((company) => (
                    <option key={company.id} value={company.id}>{company.company_name} ({company.company_code})</option>
                  ))}
                </select>
                <ChevronDown className="pointer-events-none absolute right-3 h-4 w-4 text-slate-400" />
              </div>
            ) : (
              <p className="mt-1 truncate text-sm font-bold text-slate-800">
                {activeCompany.company_name}
              </p>
            )}
          </div>

          <div className="hidden text-right sm:block">
            <p className="text-sm font-bold text-slate-900">{context.profile.name}</p>
            <p className="text-xs text-slate-500">{roleLabels[activeCompany.roleCode] ?? activeCompany.roleCode}</p>
          </div>
          <button onClick={logout} className="rounded-xl border border-slate-200 p-2.5 text-slate-500 transition hover:border-rose-200 hover:bg-rose-50 hover:text-rose-600" aria-label="Keluar">
            <LogOut className="h-5 w-5" />
          </button>
        </header>

        <main className="p-4 md:p-8">
          {activeView !== 'dashboard' && (
            <WorkspaceNavigation
              view={activeView}
              canGoBack={viewHistory.length > 0}
              goBack={goBack}
              goHome={goHome}
              navigate={navigateTo}
            />
          )}

          {notice && (
            <div className="mb-6 flex items-start gap-3 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">
              <CircleAlert className="mt-0.5 h-5 w-5 shrink-0" />
              <span className="flex-1">{notice}</span>
              <button onClick={() => setNotice(null)} aria-label="Tutup"><X className="h-4 w-4" /></button>
            </div>
          )}

          {activeView === 'dashboard' && (
            <AppLauncher
              company={activeCompany}
              profileName={context.profile.name}
              items={availableNavigation}
              products={products}
              loading={loadingData}
              openView={navigateTo}
            />
          )}

          {activeView === 'products' && (
            <CanonicalProductsView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canManage={Boolean(canManageMaster)}
              notify={setNotice}
              onChanged={loadTenantData}
            />
          )}

          {activeView === 'bundles' && (
            <BundleMasterView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canManage={Boolean(canManageMaster)}
              notify={setNotice}
            />
          )}

          {activeView === 'sales-returns' && (
            <SalesReturnApprovalView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canApprove={Boolean(canApproveSalesReturn)}
              notify={setNotice}
            />
          )}

          {activeView === 'expense-approvals' && (
            <ExpenseApprovalView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canApprove={Boolean(canApproveExpense)}
              canCancelAdministrative={Boolean(canCancelExpenseAdministrative)}
              canDisburseNonCash={Boolean(canDisburseExpenseNonCash)}
              notify={setNotice}
            />
          )}

          {activeView === 'cash-deposits' && (
            <CashDepositApprovalView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canApprove={Boolean(canApproveCashDeposit)}
              notify={setNotice}
            />
          )}

          {activeView === 'deposit-variances' && (
            <DepositVarianceResolutionView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canManage={Boolean(canManageDepositVariance)}
              canReview={Boolean(canReviewDepositVariance)}
              notify={setNotice}
            />
          )}

          {activeView === 'customer-balances' && (
            <CustomerBalanceView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canRequest={Boolean(canManageDepositVariance)}
              canReview={Boolean(canManageDepositVariance)}
              notify={setNotice}
            />
          )}

          {activeView === 'stock-real' && (
            <StockRealView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
            />
          )}

          {activeView === 'stock-movements' && (
            <StockMovementView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
            />
          )}

          {activeView === 'stock-transfers' && (
            <StockTransferView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canOperate={Boolean(canOperateStockTransfer)}
              notify={setNotice}
            />
          )}

          {activeView === 'stock-adjustments' && (
            <StockAdjustmentView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canOperate={Boolean(canOperateStockAdjustment)}
              notify={setNotice}
            />
          )}

          {activeView === 'stock-opnames' && (
            <StockOpnameView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canReview={Boolean(canReviewStockOpname)}
              notify={setNotice}
            />
          )}

          {activeView === 'masters' && (
            <MasterDataView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              stores={stores}
              canManage={Boolean(canManageMaster)}
              notify={setNotice}
            />
          )}

          {activeView === 'minimum-stock' && (
            <MinimumStockView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canManage={Boolean(canManageMaster)}
              notify={setNotice}
            />
          )}

          {activeView === 'opening-stock' && (
            <OpeningStockView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canPrepare={Boolean(canPrepareOpeningStock)}
              canPost={Boolean(canManage)}
              notify={setNotice}
            />
          )}

          {activeView === 'master-imports' && canManage && (
            <MasterImportView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              notify={setNotice}
            />
          )}

          {activeView === 'suppliers' && (
            <SupplierMasterView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canManageSupplier={Boolean(canManageSupplier)}
              canManageRelation={Boolean(canManageProductSupplier)}
              notify={setNotice}
            />
          )}

          {activeView === 'supplier-orders' && (
            <SupplierOrderView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canOperate={Boolean(canOperateSupplierOrder)}
              notify={setNotice}
            />
          )}

          {activeView === 'purchase-returns' && (
            <PurchaseReturnApprovalView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canApprove={Boolean(canOperateSupplierOrder)}
              notify={setNotice}
            />
          )}

          {activeView === 'staff' && (
            <StaffView staff={staff} canManage={Boolean(canManage)} openCreate={() => setShowStaff(true)} />
          )}

          {activeView === 'customers' && (
            <CustomerMasterView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canManageIdentity={Boolean(canManageCustomerIdentity)}
              canManageCredit={Boolean(canManageCustomerCredit)}
              notify={setNotice}
            />
          )}

          {activeView === 'pricelists' && (
            <PricelistMasterView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canManage={Boolean(canManagePricelist)}
              notify={setNotice}
            />
          )}

          {activeView === 'payment-methods' && (
            <PaymentMethodMasterView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canManage={Boolean(canManagePaymentMethod)}
              notify={setNotice}
            />
          )}

          {activeView === 'finance-masters' && (
            <FinanceMasterView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canManage={Boolean(canManageFinanceMaster)}
              notify={setNotice}
            />
          )}

          {activeView === 'tax-rules' && (
            <TaxMasterView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              canManage={Boolean(canManageFinanceMaster)}
              notify={setNotice}
            />
          )}

          {activeView === 'finance' && <FinanceView journal={journal} />}

          {activeView === 'companies' && context.isSuperAdmin && (
            <CompaniesView companies={context.companies} openCreate={() => setShowTenant(true)} />
          )}

          {activeView === 'module-settings' && (
            <ModuleSettingsView
              key={activeCompanyId}
              session={session}
              companyId={activeCompanyId}
              companyName={activeCompany.company_name}
              isSuperAdmin={context.isSuperAdmin}
              notify={setNotice}
            />
          )}
        </main>
      </div>

      {showStaff && (
        <StaffModal
          session={session}
          company={activeCompany}
          stores={stores}
          close={() => setShowStaff(false)}
          complete={async () => {
            setShowStaff(false)
            setNotice('Anggota tim berhasil dibuat.')
            await loadTenantData()
          }}
        />
      )}

      {showTenant && context.isSuperAdmin && (
        <TenantModal
          session={session}
          close={() => setShowTenant(false)}
          complete={async () => {
            setShowTenant(false)
            setNotice('Perusahaan dan akun owner berhasil dibuat.')
            await loadContext(session)
          }}
        />
      )}
    </div>
  )
}

function LoginScreen() {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')

  async function submit(event: React.FormEvent) {
    event.preventDefault()
    setLoading(true)
    setError('')
    const result = await supabase.auth.signInWithPassword({ email, password })
    if (result.error) setError(result.error.message)
    setLoading(false)
  }

  return (
    <div className="min-h-screen bg-[#f4f6f8] p-4 lg:grid lg:grid-cols-[1.05fr_.95fr] lg:p-0">
      <div className="hidden bg-slate-950 p-14 text-white lg:flex lg:flex-col lg:justify-between">
        <div className="flex items-center gap-3 text-lg font-black tracking-tight">
          <span className="grid h-10 w-10 place-items-center rounded-xl bg-emerald-500"><Store className="h-5 w-5" /></span>
          KGS POS
        </div>
        <div className="max-w-xl">
          <span className="inline-flex items-center gap-2 rounded-full border border-white/10 bg-white/5 px-3 py-1.5 text-xs font-semibold text-emerald-300">
            <ShieldCheck className="h-4 w-4" /> Multi-company workspace
          </span>
          <h1 className="mt-6 text-5xl font-black leading-[1.08] tracking-tight">Operasional toko yang rapi, dari satu tempat.</h1>
          <p className="mt-5 max-w-lg text-base leading-7 text-slate-400">Pantau produk, stok, tim, dan aktivitas perusahaan dengan konteks tenant yang aman dan mudah dipindah.</p>
        </div>
        <p className="text-xs text-slate-600">KGS Mini ERP · Backoffice</p>
      </div>

      <div className="flex min-h-[calc(100vh-2rem)] items-center justify-center lg:min-h-screen">
        <form onSubmit={submit} className="w-full max-w-md rounded-3xl border border-slate-200 bg-white p-7 shadow-sm sm:p-10">
          <div className="mb-8 lg:hidden">
            <span className="grid h-11 w-11 place-items-center rounded-2xl bg-emerald-500 text-white"><Store className="h-5 w-5" /></span>
          </div>
          <p className="text-sm font-semibold text-emerald-600">Selamat datang kembali</p>
          <h2 className="mt-2 text-3xl font-black tracking-tight text-slate-950">Masuk ke backoffice</h2>
          <p className="mt-2 text-sm leading-6 text-slate-500">Gunakan akun yang telah dibuat oleh platform admin atau pemilik perusahaan.</p>

          {error && <div className="mt-5 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">{error}</div>}
          <label className="mt-7 block text-sm font-semibold text-slate-700">Email</label>
          <input value={email} onChange={(event) => setEmail(event.target.value)} type="email" required placeholder="nama@perusahaan.com" className="mt-2 w-full rounded-xl border border-slate-200 px-4 py-3 text-sm outline-none transition focus:border-emerald-500 focus:ring-4 focus:ring-emerald-500/10" />
          <label className="mt-5 block text-sm font-semibold text-slate-700">Password</label>
          <input value={password} onChange={(event) => setPassword(event.target.value)} type="password" required className="mt-2 w-full rounded-xl border border-slate-200 px-4 py-3 text-sm outline-none transition focus:border-emerald-500 focus:ring-4 focus:ring-emerald-500/10" />
          <button disabled={loading} className="mt-7 flex w-full items-center justify-center gap-2 rounded-xl bg-emerald-500 px-4 py-3.5 text-sm font-bold text-white transition hover:bg-emerald-600 disabled:opacity-60">
            {loading && <Loader2 className="h-4 w-4 animate-spin" />}{loading ? 'Memeriksa akun...' : 'Masuk'}
          </button>
          <p className="mt-5 text-center text-xs leading-5 text-slate-400">Pendaftaran publik dinonaktifkan untuk menjaga keamanan data perusahaan.</p>
        </form>
      </div>
    </div>
  )
}

function Sidebar({ view, navigate, goHome, items, open, close }: {
  view: View
  navigate: (view: View) => void
  goHome: () => void
  items: NavigationItem[]
  open: boolean
  close: () => void
}) {
  return (
    <>
      {open && <button onClick={close} className="fixed inset-0 z-40 bg-slate-950/40 lg:hidden" aria-label="Tutup fast link" />}
      <aside aria-hidden={!open} className={`fixed inset-y-0 left-0 z-50 flex h-dvh w-72 flex-col border-r border-slate-800 bg-slate-950 text-white shadow-2xl shadow-slate-950/30 transition-transform duration-200 ${open ? 'translate-x-0' : '-translate-x-full'}`}>
        <div className="flex h-20 shrink-0 items-center justify-between border-b border-white/5 px-6">
          <button
            type="button"
            onClick={() => { goHome(); close() }}
            className="flex items-center gap-3 rounded-xl text-left font-black tracking-tight outline-none transition hover:text-emerald-300 focus-visible:ring-2 focus-visible:ring-emerald-400 focus-visible:ring-offset-2 focus-visible:ring-offset-slate-950"
            aria-label="Kembali ke halaman awal"
            title="Kembali ke halaman awal"
          >
            <span className="grid h-10 w-10 place-items-center rounded-xl bg-emerald-500"><Store className="h-5 w-5" /></span>
            KGS POS
          </button>
          <button onClick={close} className="rounded-lg p-2 text-slate-400 hover:bg-white/5 hover:text-white" aria-label="Tutup fast link"><X className="h-5 w-5" /></button>
        </div>
        <nav className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-3 py-5">
          <p className="px-3 text-[10px] font-bold uppercase tracking-[.18em] text-slate-500">Fast link</p>
          <div className="mt-3 space-y-1">
            {items.map((item) => {
              const Icon = item.icon
              const active = view === item.id
              return (
                <button key={item.id} onClick={() => { if (item.id === 'dashboard') goHome(); else navigate(item.id); close() }} className={`flex w-full items-center gap-3 rounded-xl px-3 py-3 text-sm font-semibold transition ${active ? 'bg-emerald-500 text-white shadow-lg shadow-emerald-500/15' : 'text-slate-400 hover:bg-white/5 hover:text-white'}`}>
                  <Icon className="h-4 w-4" />{item.label}
                </button>
              )
            })}
          </div>
        </nav>
        <div className="m-3 shrink-0 rounded-2xl border border-white/5 bg-white/[.03] p-4">
          <div className="flex items-center gap-2 text-xs font-bold text-emerald-300"><ShieldCheck className="h-4 w-4" /> Tenant protection</div>
          <p className="mt-2 text-[11px] leading-5 text-slate-500">Fast link hanya menampilkan menu sesuai role. API dan RLS tetap menjadi pengaman utama.</p>
        </div>
      </aside>
    </>
  )
}

function WorkspaceNavigation({ view, canGoBack, goBack, goHome, navigate }: {
  view: View
  canGoBack: boolean
  goBack: () => void
  goHome: () => void
  navigate: (view: View) => void
}) {
  const page = navigation.find((item) => item.id === view)
  const appModule = appModules.find((item) => item.views.includes(view))
  const moduleLanding = appModule?.views[0]

  return (
    <div className="mb-6 flex min-w-0 items-center gap-3">
      <button
        type="button"
        onClick={goBack}
        className="inline-flex h-10 shrink-0 items-center gap-2 rounded-xl border border-slate-200 bg-white px-3 text-sm font-bold text-slate-700 shadow-sm transition hover:border-emerald-200 hover:bg-emerald-50 hover:text-emerald-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500 disabled:cursor-not-allowed disabled:opacity-45"
        aria-label={canGoBack ? 'Kembali ke halaman sebelumnya' : 'Kembali ke halaman aplikasi'}
        title={canGoBack ? 'Kembali ke halaman sebelumnya' : 'Kembali ke halaman aplikasi'}
      >
        <ArrowLeft className="h-4 w-4" />
        <span className="hidden sm:inline">Kembali</span>
      </button>

      <nav
        aria-label="Lokasi halaman"
        className="flex min-w-0 flex-1 items-center gap-1.5 overflow-x-auto rounded-xl border border-slate-200 bg-white px-3 py-2.5 text-sm shadow-sm"
      >
        <button
          type="button"
          onClick={goHome}
          className="inline-flex shrink-0 items-center gap-1.5 font-semibold text-slate-500 transition hover:text-emerald-700"
        >
          <House className="h-4 w-4" />
          <span>Beranda</span>
        </button>
        {appModule && moduleLanding && (
          <>
            <ChevronRight className="h-4 w-4 shrink-0 text-slate-300" />
            <button
              type="button"
              onClick={() => navigate(moduleLanding)}
              disabled={moduleLanding === view}
              className="shrink-0 font-semibold text-slate-500 transition hover:text-emerald-700 disabled:cursor-default disabled:text-slate-500"
            >
              {appModule.name}
            </button>
          </>
        )}
        <ChevronRight className="h-4 w-4 shrink-0 text-slate-300" />
        <span className="truncate font-bold text-slate-900" aria-current="page">
          {page?.label ?? view}
        </span>
      </nav>
    </div>
  )
}

function PageTitle({ eyebrow, title, description, action }: { eyebrow: string; title: string; description: string; action?: React.ReactNode }) {
  return <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between"><div><p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">{eyebrow}</p><h1 className="mt-2 text-2xl font-black tracking-tight text-slate-950 md:text-3xl">{title}</h1><p className="mt-2 text-sm text-slate-500">{description}</p></div>{action}</div>
}

function AppLauncher({ company, profileName, items, products, loading, openView }: {
  company: CompanyContext
  profileName: string
  items: NavigationItem[]
  products: Product[]
  loading: boolean
  openView: (view: View) => void
}) {
  const totalStock = products.reduce((sum, product) => sum + product.stock, 0)
  const inventoryValue = products.reduce((sum, product) => sum + product.stock * product.cogs, 0)
  const itemByView = new Map(items.map((item) => [item.id, item]))
  const modules = appModules.map((module) => ({
    ...module,
    links: module.views.map((view) => itemByView.get(view)).filter(Boolean) as NavigationItem[],
  })).filter((module) => module.links.length > 0)
  return <>
    <div className="mb-8 rounded-3xl bg-slate-950 p-6 text-white shadow-xl shadow-slate-950/10 md:p-8"><p className="text-xs font-bold uppercase tracking-[.18em] text-emerald-400">{company.company_code} · Workspace aplikasi</p><h1 className="mt-3 text-3xl font-black tracking-tight md:text-4xl">Halo, {profileName}</h1><p className="mt-3 max-w-2xl text-sm leading-6 text-slate-400">Pilih modul yang ingin dibuka. Hanya aplikasi yang tersedia untuk role <b className="text-slate-200">{roleLabels[company.roleCode] ?? company.roleCode}</b> yang ditampilkan.</p></div>
    <div className="mb-5 flex items-end justify-between gap-4"><div><h2 className="text-xl font-black text-slate-950">Aplikasi Anda</h2><p className="mt-1 text-sm text-slate-500">Modul dikelompokkan berdasarkan pekerjaan, seperti app launcher ERP.</p></div></div>
    {modules.length > 0 ? <div className="grid gap-5 md:grid-cols-2 xl:grid-cols-3">{modules.map((module) => { const ModuleIcon = module.icon; return <article key={module.id} className="group overflow-hidden rounded-3xl border border-slate-200 bg-white shadow-sm transition hover:-translate-y-0.5 hover:shadow-lg"><button onClick={() => openView(module.links[0].id)} className="w-full p-6 text-left"><div className="flex items-start gap-4"><div className={`grid h-14 w-14 shrink-0 place-items-center rounded-2xl text-white shadow-lg ${module.color}`}><ModuleIcon className="h-6 w-6" /></div><div className="min-w-0 flex-1"><div className="flex items-center gap-2"><h3 className="text-lg font-black text-slate-950">{module.name}</h3><ChevronRight className="ml-auto h-5 w-5 text-slate-300 transition group-hover:translate-x-1 group-hover:text-emerald-500" /></div><p className="mt-1 text-sm leading-6 text-slate-500">{module.description}</p></div></div></button><div className="flex flex-wrap gap-2 border-t border-slate-100 bg-slate-50/70 px-6 py-4">{module.links.map((link) => { const LinkIcon = link.icon; return <button key={link.id} onClick={() => openView(link.id)} className="inline-flex items-center gap-1.5 rounded-lg bg-white px-2.5 py-2 text-xs font-bold text-slate-600 shadow-sm ring-1 ring-slate-200 hover:text-emerald-600"><LinkIcon className="h-3.5 w-3.5" />{link.label}</button> })}</div></article>})}</div> : <div className="rounded-3xl border border-dashed border-slate-300 bg-white p-12 text-center"><ShieldCheck className="mx-auto h-8 w-8 text-slate-300" /><h3 className="mt-4 font-bold text-slate-700">Belum ada aplikasi Backoffice untuk role ini</h3><p className="mt-2 text-sm text-slate-500">Hubungi Company Admin bila akses kerja perlu ditambahkan.</p></div>}
    {items.some((item) => item.id === 'products') && <div className="mt-8 grid gap-4 sm:grid-cols-3"><MiniStat label="Produk aktif" value={loading ? '—' : products.length.toLocaleString('id-ID')} /><MiniStat label="Total unit stok" value={loading ? '—' : totalStock.toLocaleString('id-ID')} /><MiniStat label="Nilai persediaan" value={loading ? '—' : rupiah(inventoryValue)} /></div>}
  </>
}

function MiniStat({ label, value }: { label: string; value: string }) { return <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"><p className="text-xs font-semibold text-slate-500">{label}</p><p className="mt-2 text-xl font-black text-slate-950">{value}</p></div> }

function StaffView({ staff, canManage, openCreate }: { staff: Staff[]; canManage: boolean; openCreate: () => void }) {
  return <><PageTitle eyebrow="Access control" title="Tim & akses" description="Kelola pengguna hanya pada company yang sedang aktif." action={canManage ? <button onClick={openCreate} className="inline-flex items-center justify-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 text-sm font-bold text-white"><UserPlus className="h-4 w-4" />Tambah anggota</button> : undefined} /><div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">{staff.map((member) => <div key={member.id} className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"><div className="flex items-start gap-4"><div className="grid h-12 w-12 place-items-center rounded-2xl bg-slate-100 font-black text-slate-600">{member.name.slice(0,2).toUpperCase()}</div><div className="min-w-0"><p className="truncate font-bold text-slate-950">{member.name}</p><p className="truncate text-sm text-slate-500">{member.email}</p><span className="mt-3 inline-flex rounded-full bg-emerald-50 px-2.5 py-1 text-[11px] font-bold text-emerald-700">{roleLabels[member.role] ?? member.role}</span></div></div></div>)}{!staff.length && <div className="md:col-span-2 xl:col-span-3"><Empty label="Belum ada anggota yang dapat ditampilkan." /></div>}</div></>
}

function CompaniesView({ companies, openCreate }: { companies: CompanyContext[]; openCreate: () => void }) {
  return <><PageTitle eyebrow="Platform control" title="Perusahaan" description="Daftar seluruh tenant aktif yang dapat dikelola super admin." action={<button onClick={openCreate} className="inline-flex items-center justify-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 text-sm font-bold text-white"><Building2 className="h-4 w-4" />Perusahaan baru</button>} /><div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">{companies.map((company) => <div key={company.id} className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"><div className="flex items-center gap-4"><div className="grid h-12 w-12 place-items-center rounded-2xl bg-blue-50 text-blue-600"><Building2 className="h-5 w-5" /></div><div><p className="font-bold">{company.company_name}</p><p className="mt-1 text-xs font-semibold text-slate-400">{company.company_code}</p></div></div><div className="mt-5 flex items-center justify-between border-t border-slate-100 pt-4 text-xs"><span className="text-slate-500">Status tenant</span><span className="rounded-full bg-emerald-50 px-2.5 py-1 font-bold text-emerald-700">{company.status}</span></div></div>)}</div></>
}

function FinanceView({ journal }: { journal: JournalEntry[] }) {
  const debit = journal.reduce((sum, entry) => sum + entry.debit, 0)
  const credit = journal.reduce((sum, entry) => sum + entry.credit, 0)
  return <><PageTitle eyebrow="Finance" title="Jurnal umum" description="Entri jurnal terbaru yang lolos akses accounting company aktif." /><div className="mb-5 grid gap-4 sm:grid-cols-2"><div className="rounded-2xl border border-slate-200 bg-white p-5"><p className="text-xs font-semibold text-slate-500">Total debit terlihat</p><p className="mt-2 text-xl font-black">{rupiah(debit)}</p></div><div className="rounded-2xl border border-slate-200 bg-white p-5"><p className="text-xs font-semibold text-slate-500">Total kredit terlihat</p><p className="mt-2 text-xl font-black">{rupiah(credit)}</p></div></div><div className="rounded-2xl border border-slate-200 bg-white shadow-sm"><div className="overflow-x-auto"><table className="w-full min-w-[900px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500"><tr><th className="px-5 py-4">Jurnal</th><th className="px-5 py-4">Akun</th><th className="px-5 py-4">Catatan</th><th className="px-5 py-4 text-right">Debit</th><th className="px-5 py-4 text-right">Kredit</th></tr></thead><tbody className="divide-y divide-slate-100">{journal.map((entry) => <tr key={entry.id}><td className="px-5 py-4"><p className="font-bold">{entry.journalNo}</p><p className="mt-1 text-xs text-slate-400">{new Date(entry.date).toLocaleDateString('id-ID')}</p></td><td className="px-5 py-4 text-slate-600">{entry.account}</td><td className="max-w-xs truncate px-5 py-4 text-slate-500">{entry.note}</td><td className="px-5 py-4 text-right font-semibold">{entry.debit ? rupiah(entry.debit) : '-'}</td><td className="px-5 py-4 text-right font-semibold">{entry.credit ? rupiah(entry.credit) : '-'}</td></tr>)}</tbody></table>{!journal.length && <Empty label="Belum ada jurnal yang dapat ditampilkan." />}</div></div></>
}

function StaffModal({ session, company, stores, close, complete }: { session: Session; company: CompanyContext; stores: StoreOption[]; close: () => void; complete: () => Promise<void> }) {
  useEscapeClose(close)
  const [form, setForm] = useState({ name: '', email: '', password: '', role_code: 'CASHIER', store_id: stores[0]?.id ?? 'NONE' }); const [loading, setLoading] = useState(false); const [error, setError] = useState('')
  async function submit(event: React.FormEvent) { event.preventDefault(); setLoading(true); setError(''); try { const response = await fetch('/api/staff/create', { method: 'POST', headers: { 'Content-Type': 'application/json', ...authHeaders(session) }, body: JSON.stringify({ ...form, company_id: company.id }) }); const payload = (await response.json()) as { error?: string }; if (!response.ok) throw new Error(payload.error ?? 'Gagal membuat anggota'); await complete() } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal membuat anggota') } finally { setLoading(false) } }
  return <Modal title="Tambah anggota tim" description={`Akun hanya akan mendapat akses ke ${company.company_name}. Kasir wajib ditugaskan ke satu Toko agar Terminal POS tersedia.`} close={close}><form onSubmit={submit} className="space-y-4"><Field label="Nama"><input required value={form.name} onChange={(e) => setForm({...form,name:e.target.value})} className="input" /></Field><Field label="Email"><input required type="email" value={form.email} onChange={(e) => setForm({...form,email:e.target.value})} className="input" /></Field><Field label="Password sementara"><input required minLength={8} type="password" value={form.password} onChange={(e) => setForm({...form,password:e.target.value})} className="input" /></Field><div className="grid gap-4 sm:grid-cols-2"><Field label="Role"><select value={form.role_code} onChange={(e) => { const role = e.target.value; setForm({...form,role_code:role,store_id:role === 'CASHIER' && form.store_id === 'NONE' ? stores[0]?.id ?? 'NONE' : form.store_id}) }} className="input">{['CASHIER','STORE_MANAGER','WAREHOUSE_ADMIN','FINANCE','ACCOUNTING','COMPANY_ADMIN'].map((role) => <option key={role} value={role}>{roleLabels[role]}</option>)}</select></Field><Field label={form.role_code === 'CASHIER' ? 'Toko assignment Kasir (wajib)' : 'Toko'}><select required={form.role_code === 'CASHIER'} value={form.store_id} onChange={(e) => setForm({...form,store_id:e.target.value})} className="input"><option value="NONE" disabled={form.role_code === 'CASHIER'}>Semua / tidak spesifik</option>{stores.map((store) => <option key={store.id} value={store.id}>{store.store_name}</option>)}</select></Field></div>{form.role_code === 'CASHIER' && stores.length === 0 && <FormError message="Buat atau aktifkan Toko terlebih dahulu sebelum membuat akun Kasir." />}{error && <FormError message={error} />}<ModalActions close={close} loading={loading || (form.role_code === 'CASHIER' && stores.length === 0)} submit="Buat akun" /></form></Modal>
}

function TenantModal({ session, close, complete }: { session: Session; close: () => void; complete: () => Promise<void> }) {
  useEscapeClose(close)
  const [form, setForm] = useState({ company_name: '', company_code: '', name: '', email: '', password: '' }); const [loading, setLoading] = useState(false); const [error, setError] = useState('')
  async function submit(event: React.FormEvent) { event.preventDefault(); setLoading(true); setError(''); try { const response = await fetch('/api/tenant/register', { method: 'POST', headers: { 'Content-Type': 'application/json', ...authHeaders(session) }, body: JSON.stringify(form) }); const payload = (await response.json()) as { error?: string }; if (!response.ok) throw new Error(payload.error ?? 'Gagal membuat perusahaan'); await complete() } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal membuat perusahaan') } finally { setLoading(false) } }
  return <Modal title="Perusahaan baru" description="Sistem sekaligus membuat toko utama, gudang default, dan akun company owner." close={close}><form onSubmit={submit} className="space-y-4"><div className="grid gap-4 sm:grid-cols-2"><Field label="Nama perusahaan"><input required value={form.company_name} onChange={(e) => setForm({...form,company_name:e.target.value})} className="input" /></Field><Field label="Kode"><input required value={form.company_code} onChange={(e) => setForm({...form,company_code:e.target.value.toUpperCase()})} className="input uppercase" /></Field></div><Field label="Nama owner"><input required value={form.name} onChange={(e) => setForm({...form,name:e.target.value})} className="input" /></Field><Field label="Email owner"><input required type="email" value={form.email} onChange={(e) => setForm({...form,email:e.target.value})} className="input" /></Field><Field label="Password sementara"><input required minLength={8} type="password" value={form.password} onChange={(e) => setForm({...form,password:e.target.value})} className="input" /></Field>{error && <FormError message={error} />}<ModalActions close={close} loading={loading} submit="Buat perusahaan" /></form></Modal>
}

function Modal({ title, description, close, children }: { title: string; description: string; close: () => void; children: React.ReactNode }) { return <div className="fixed inset-0 z-[70] grid place-items-center bg-slate-950/45 p-4 backdrop-blur-sm"><div className="max-h-[92vh] w-full max-w-xl overflow-y-auto rounded-3xl bg-white p-6 shadow-2xl sm:p-8"><div className="flex items-start justify-between gap-4"><div><h2 className="text-xl font-black text-slate-950">{title}</h2><p className="mt-2 text-sm leading-6 text-slate-500">{description}</p></div><button onClick={close} className="rounded-xl bg-slate-100 p-2 text-slate-500"><X className="h-4 w-4" /></button></div><div className="mt-7">{children}</div></div></div> }
function Field({ label, children }: { label: string; children: React.ReactNode }) { return <label className="block text-sm font-semibold text-slate-700">{label}<span className="mt-2 block">{children}</span></label> }
function FormError({ message }: { message: string }) { return <div className="mt-4 rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm text-rose-700">{message}</div> }
function ModalActions({ close, loading, submit }: { close: () => void; loading: boolean; submit: string }) { return <div className="mt-7 flex justify-end gap-3 border-t border-slate-100 pt-5"><button type="button" onClick={close} className="rounded-xl border border-slate-200 px-4 py-2.5 text-sm font-bold text-slate-600">Batal</button><button disabled={loading} className="inline-flex items-center gap-2 rounded-xl bg-emerald-500 px-5 py-2.5 text-sm font-bold text-white disabled:opacity-60">{loading && <Loader2 className="h-4 w-4 animate-spin" />}{submit}</button></div> }
function Empty({ label }: { label: string }) { return <div className="p-10 text-center text-sm text-slate-400">{label}</div> }
function FullScreenLoader({ label, notice }: { label: string; notice?: string | null }) { return <div className="min-h-screen bg-slate-50 grid place-items-center"><div className="text-center"><Loader2 className="mx-auto h-8 w-8 animate-spin text-emerald-500" /><p className="mt-4 text-sm font-semibold text-slate-600">{label}</p>{notice && <p className="mt-2 text-xs text-rose-600">{notice}</p>}</div></div> }
