import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  AlertTriangle,
  Banknote,
  CheckCircle2,
  ChevronDown,
  Clock3,
  FileText,
  LockKeyhole,
  LogIn,
  LogOut,
  Minus,
  Package,
  Plus,
  Printer,
  RefreshCw,
  Search,
  ShoppingCart,
  Trash2,
  UserRound,
  Wifi,
  WifiOff,
  X,
} from 'lucide-react'
import { printer } from './lib/printer'
import { supabase, supabaseConfigurationError } from './lib/supabase'
import './App.css'
import {
  acquireSaleDraftLock,
  cancelSaleDraft,
  closeCashierSession,
  getCurrentSession,
  heartbeatSaleDraftLock,
  listSaleDrafts,
  loadBootstrap,
  loadCatalog,
  loadCompanies,
  loadReceipt,
  loadResolvedSaleLines,
  openCashierSession,
  postSale,
  releaseSaleDraftLock,
  saveSaleDraft,
  setActiveCompany,
  signIn,
  signOut,
  type BootstrapData,
  type CashierSession,
  type CatalogData,
  type CompanyOption,
  type ProductOption,
  type ResolvedSaleLine,
  type SaleDraft,
  type SaleDraftListItem,
  type SaleReceipt,
} from './lib/pos'

type CartItem = {
  product: ProductOption
  quantity: number
  discountType: '' | 'AMOUNT' | 'PERCENT'
  discountInput: number
}

type PaymentLeg = {
  clientPaymentKey: string
  paymentMethodId: string
  amount: string
  tenderedAmount: string
  proofUrl: string
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

const EMPTY_CATALOG: CatalogData = {
  products: [],
  customers: [],
  pricelists: [],
  paymentMethods: [],
}

function money(value: number) {
  return `Rp ${Math.round(value).toLocaleString('id-ID')}`
}

function createPaymentLeg(paymentMethodId = ''): PaymentLeg {
  return {
    clientPaymentKey: crypto.randomUUID(),
    paymentMethodId,
    amount: '',
    tenderedAmount: '',
    proofUrl: '',
  }
}

function errorMessage(error: unknown) {
  if (error && typeof error === 'object' && 'message' in error) {
    return String(error.message)
  }
  return 'Terjadi kesalahan yang tidak dikenali.'
}

function friendlyError(code: string) {
  const labels: Record<string, string> = {
    ACTIVE_CASHIER_ASSIGNMENT_REQUIRED:
      'User ini belum memiliki assignment Cashier aktif pada Store.',
    ACTIVE_POS_TERMINAL_NOT_FOUND: 'Terminal POS tidak aktif atau tidak tersedia.',
    ACTIVE_SALES_WAREHOUSE_NOT_FOUND:
      'Gudang penjualan tidak aktif atau tidak sesuai Store.',
    CASHIER_SESSION_ALREADY_OPEN:
      'User sudah mempunyai sesi terbuka. Muat ulang untuk melanjutkannya.',
    OPEN_CASHIER_SESSION_REQUIRED: 'Buka sesi kasir sebelum membuat transaksi.',
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
  const [dueDate, setDueDate] = useState('')
  const [roundingDirection, setRoundingDirection] = useState<
    'NONE' | 'DOWN' | 'UP'
  >('NONE')
  const [globalDiscount, setGlobalDiscount] = useState('')
  const [cart, setCart] = useState<CartItem[]>([])
  const [draft, setDraft] = useState<SaleDraft | null>(null)
  const [draftLabel, setDraftLabel] = useState('')
  const [draftNotes, setDraftNotes] = useState('')
  const [saleDrafts, setSaleDrafts] = useState<SaleDraftListItem[]>([])
  const [draftPanelOpen, setDraftPanelOpen] = useState(false)
  const [clientTransactionId, setClientTransactionId] = useState<string>(() =>
    crypto.randomUUID(),
  )
  const [resolvedLines, setResolvedLines] = useState<ResolvedSaleLine[]>([])
  const [receipt, setReceipt] = useState<SaleReceipt | null>(null)
  const [shortages, setShortages] = useState<Array<Record<string, unknown>>>([])
  const [search, setSearch] = useState('')
  const [category, setCategory] = useState('Semua')
  const [isOnline, setIsOnline] = useState(navigator.onLine)
  const [isPrinterConnected, setIsPrinterConnected] = useState(false)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState('')
  const [error, setError] = useState('')
  const [actionDialog, setActionDialog] = useState<ActionDialog | null>(null)
  const [actionDialogReason, setActionDialogReason] = useState('')

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
  const activeWarehouse = bootstrap?.warehouses.find(
    (item) => item.id === (cashierSession?.warehouseId || warehouseId),
  )
  const activeCustomer = catalog.customers.find(
    (item) => item.id === customerId,
  )
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
        product.barcode?.toLowerCase() === query
      return matchesCategory && matchesQuery
    })
  }, [catalog.products, category, search])

  const fallbackSubtotal = useMemo(
    () =>
      cart.reduce(
        (total, item) =>
          total + item.product.fallbackPrice * item.quantity,
        0,
      ),
    [cart],
  )
  const paymentDue = draft?.grandTotalAfterRounding ?? 0
  const paymentBaseTotal = paymentLegs.reduce(
    (total, leg) => total + Number(leg.amount || 0),
    0,
  )
  const paymentRemaining = paymentDue - paymentBaseTotal
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
        if (current) await refreshCompanies(current)
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
      }
    })
    const online = () => setIsOnline(true)
    const offline = () => setIsOnline(false)
    window.addEventListener('online', online)
    window.addEventListener('offline', offline)
    return () => {
      mounted = false
      data.subscription.unsubscribe()
      window.removeEventListener('online', online)
      window.removeEventListener('offline', offline)
    }
  }, [refreshCompanies])

  useEffect(() => {
    if (!session || !companyId || !activeCompany) return
    setLoading(true)
    refreshBootstrap(companyId, session.user.id, activeCompany.roleCode)
      .catch((reason) => setError(friendlyError(errorMessage(reason))))
      .finally(() => setLoading(false))
  }, [activeCompany, companyId, refreshBootstrap, session])

  useEffect(() => {
    if (!cashierSession?.storeId) return
    setLoading(true)
    Promise.all([
      refreshCatalog(cashierSession),
      refreshSaleDrafts(cashierSession),
    ])
      .catch((reason) => setError(friendlyError(errorMessage(reason))))
      .finally(() => setLoading(false))
  }, [cashierSession, refreshCatalog, refreshSaleDrafts])

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
    const handler = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return
      if (actionDialog) {
        setActionDialog(null)
        setActionDialogReason('')
      } else if (receipt) setReceipt(null)
      else if (draftPanelOpen) setDraftPanelOpen(false)
      else if (error) setError('')
      else if (notice) setNotice('')
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [actionDialog, draftPanelOpen, error, notice, receipt])

  function openActionDialog(dialog: ActionDialog) {
    setActionDialogReason('')
    setActionDialog(dialog)
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
    openActionDialog({
      title: 'Tutup sesi kasir?',
      description:
        'Sistem akan menyimpan snapshot stok penutupan dan menghitung selisih kas fisik.',
      confirmLabel: 'Tutup sesi',
      tone: 'danger',
      onConfirm: executeCloseSession,
    })
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
      setNotice(
        `Sesi ditutup. Expected ${money(Number(result.expectedCash ?? 0))}, ` +
          `selisih ${money(Number(result.difference ?? 0))}.`,
      )
      resetSale()
      setSaleDrafts([])
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
    }> = [],
  ) {
    if (!cashierSession || !customerId || cart.length === 0) {
      throw new Error('SESSION_CUSTOMER_AND_CART_REQUIRED')
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
      dueDate: isTempo && dueDate ? new Date(dueDate).toISOString() : null,
      payments,
    })
    setDraft(saved)
    setResolvedLines(await loadResolvedSaleLines(companyId, saved.salesId))
    await refreshSaleDrafts(cashierSession)
    return saved
  }

  async function handleContinueDraft(item: SaleDraftListItem) {
    if (!cashierSession || !session) return
    const lockedByOther =
      Boolean(item.lockOwnerId) &&
      (item.lockOwnerId !== session.user.id ||
        item.lockSessionId !== cashierSession.id)
    if (lockedByOther && !item.lockExpired) {
      setError(
        `Draft sedang diedit ${item.lockOwnerName ?? 'kasir lain'}.`,
      )
      return
    }
    if (lockedByOther && item.lockExpired) {
      openActionDialog({
        title: `Ambil alih ${item.draftNo}?`,
        description:
          `Lock milik ${item.lockOwnerName ?? 'kasir lain'} sudah kedaluwarsa. ` +
          'Pengambilalihan akan dicatat pada audit.',
        confirmLabel: 'Ambil alih Draft',
        tone: 'primary',
        onConfirm: () => executeContinueDraft(item, true),
      })
      return
    }
    await executeContinueDraft(item, false)
  }

  async function executeContinueDraft(
    item: SaleDraftListItem,
    confirmTakeover: boolean,
  ) {
    if (!cashierSession) return
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
          ? String(payload.dueDate).slice(0, 16)
          : ''
      const nextRoundingDirection =
        payload.roundingDirection === 'DOWN' ||
        payload.roundingDirection === 'UP'
          ? payload.roundingDirection
          : 'NONE'
      const nextGlobalDiscount = String(payload.globalDiscount ?? '')
      const nextDraft: SaleDraft = {
        salesId: item.salesId,
        draftNo: item.draftNo,
        clientTransactionId: nextClientTransactionId,
        masterVersion: item.masterVersion,
        grandTotalBeforeRounding: item.grandTotal,
        roundingAdjustment: 0,
        grandTotalAfterRounding: item.grandTotal,
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
        })),
        globalDiscount: Number(payload.globalDiscount ?? 0),
        roundingDirection: nextRoundingDirection,
        isTempo: nextIsTempo,
        dueDate: nextIsTempo && payload.dueDate
          ? String(payload.dueDate)
          : null,
        payments: [],
      })

      setCart(nextCart)
      setDraft(repriced)
      setClientTransactionId(nextClientTransactionId)
      setCustomerId(nextCustomerId)
      setSelectedPricelistId(nextPricelistId)
      setDraftLabel(item.draftLabel ?? '')
      setDraftNotes(item.draftNotes ?? '')
      setGlobalDiscount(nextGlobalDiscount)
      setRoundingDirection(nextRoundingDirection)
      setIsTempo(nextIsTempo)
      setDueDate(nextDueDate)
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
    } catch (reason) {
      if (!draft || draft.salesId !== item.salesId) {
        await releaseSaleDraftLock(
          item.salesId,
          cashierSession.id,
        ).catch(() => undefined)
      }
      setError(friendlyError(errorMessage(reason)))
    } finally {
      setBusy(false)
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
              method?.methodType === 'CASH'
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
    if (!draft) return
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
      Math.max(0, draft.grandTotalAfterRounding - otherTotal),
    )
    const method = catalog.paymentMethods.find(
      (item) => item.id === activeLeg?.paymentMethodId,
    )
    updatePaymentLeg(clientPaymentKey, {
      amount,
      ...(method?.methodType === 'CASH' &&
      (!activeLeg?.tenderedAmount ||
        activeLeg.tenderedAmount === activeLeg.amount)
        ? { tenderedAmount: amount }
        : {}),
    })
  }

  function addPaymentLeg() {
    const used = new Set(paymentLegs.map((leg) => leg.paymentMethodId))
    const nextMethod = catalog.paymentMethods.find(
      (method) => !used.has(method.id),
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

  async function handlePostSale() {
    if (!isOnline) {
      setError('Checkout offline belum dibuka. Transaksi tidak diposting.')
      return
    }
    if (!cashierSession || cart.length === 0) return
    setBusy(true)
    setError('')
    setNotice('')
    setShortages([])
    try {
      const pricedDraft = await persistDraft(draft)
      let finalDraft = pricedDraft
      if (!isTempo) {
        if (paymentLegs.length === 0) throw new Error('PAYMENT_LEGS_REQUIRED')
        const normalizedPayments = paymentLegs.map((leg) => {
          const method = catalog.paymentMethods.find(
            (item) => item.id === leg.paymentMethodId,
          )
          if (!method) throw new Error('ELIGIBLE_PAYMENT_METHOD_REQUIRED')
          const amount =
            paymentLegs.length === 1 && leg.amount.trim() === ''
              ? pricedDraft.grandTotalAfterRounding
              : Number(leg.amount || 0)
          if (!(amount > 0)) throw new Error('PAYMENT_LEG_AMOUNT_REQUIRED')
          const tenderedAmount =
            method.methodType === 'CASH'
              ? Number(leg.tenderedAmount || amount)
              : amount
          if (tenderedAmount < amount) {
            throw new Error('PAYMENT_TENDER_INSUFFICIENT')
          }
          return {
            clientPaymentKey: leg.clientPaymentKey,
            paymentMethodId: method.id,
            amount,
            tenderedAmount,
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
        finalDraft = await persistDraft(pricedDraft, normalizedPayments)
      } else {
        finalDraft = await persistDraft(pricedDraft)
      }

      const postResult = await postSale(
        finalDraft.salesId,
        finalDraft.masterVersion,
        crypto.randomUUID(),
      )
      if (postResult.documentStatus === 'DRAFT') {
        const nextDraft = {
          ...finalDraft,
          masterVersion: Number(postResult.masterVersion),
        }
        setDraft(nextDraft)
        setShortages(
          Array.isArray(postResult.shortages)
            ? (postResult.shortages as Array<Record<string, unknown>>)
            : [],
        )
        setError(
          'Stok belum cukup. Transaksi tetap Draft dan tidak membuat payment, movement, atau event final.',
        )
        return
      }
      const finalReceipt = await loadReceipt(companyId, finalDraft.salesId)
      setReceipt(finalReceipt)
      setNotice('Penjualan berhasil diposting oleh server.')
      resetSale()
      await refreshCatalog(cashierSession)
      await refreshSaleDrafts(cashierSession)
    } catch (reason) {
      setError(friendlyError(errorMessage(reason)))
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
    setDueDate('')
    setRoundingDirection('NONE')
    setClientTransactionId(crypto.randomUUID())
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
        paymentMethod:
          receipt.payments
            .map((payment) => payment.paymentMethodName)
            .join(' + ') || 'TEMPO',
        date: new Date(receipt.postedAt).toLocaleString('id-ID'),
      })
    } catch (reason) {
      setError(
        errorMessage(reason) === 'POPUP_BLOCKED'
          ? 'Browser memblokir tab struk. Izinkan pop-up untuk KGS POS lalu coba lagi.'
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
      await signOut()
      setSession(null)
      resetSale()
    } catch (reason) {
      setError(friendlyError(errorMessage(reason)))
    } finally {
      setBusy(false)
    }
  }

  if (loading && !session) {
    return <CenteredMessage text="Memuat KGS POS…" />
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
              KGS POS Online
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
      <CenteredMessage text="Akun ini belum memiliki akses ke Company aktif." />
    )
  }

  return (
    <div className="pos-shell min-h-screen bg-slate-950 text-slate-100">
      <header className="pos-topbar sticky top-0 z-30 border-b border-slate-800 bg-slate-950/95 px-4 py-3 backdrop-blur">
        <div className="flex w-full flex-wrap items-center gap-3">
          <div className="pos-brand mr-auto">
            <h1 className="text-xl font-black">KGS POS</h1>
            <p className="text-xs text-slate-400">
              {cashierSession
                ? `${cashierSession.code} · ${activeTerminal?.name ?? 'Terminal'}`
                : 'Sesi kasir belum dibuka'}
            </p>
          </div>
          <select
            value={companyId}
            disabled={busy || Boolean(cashierSession)}
            onChange={(event) => handleCompanyChange(event.target.value)}
            className="pos-company-select rounded-xl border border-slate-700 bg-slate-900 px-3 py-2 text-sm"
          >
            {companies.map((company) => (
              <option key={company.id} value={company.id}>
                {company.name}
              </option>
            ))}
          </select>
          <div
            className={`pos-network-status flex items-center gap-2 rounded-xl border px-3 py-2 text-sm ${
              isOnline
                ? 'border-emerald-900 bg-emerald-950 text-emerald-300'
                : 'border-rose-900 bg-rose-950 text-rose-300'
            }`}
          >
            {isOnline ? <Wifi className="h-4 w-4" /> : <WifiOff className="h-4 w-4" />}
            {isOnline ? 'Online' : 'Offline diblokir'}
          </div>
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
          <div className="pos-workspace grid gap-3">
            <section className="pos-catalog min-w-0 rounded-2xl border border-slate-800 bg-slate-900/60 p-3 sm:p-4">
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
                    placeholder="Cari nama, SKU, barcode, atau satuan…"
                    className="w-full rounded-xl border border-slate-700 bg-slate-950 py-2.5 pl-10 pr-3 outline-none focus:border-emerald-500"
                  />
                </div>
                <button
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
                {filteredProducts.map((product) => (
                  <button
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
                      {money(product.fallbackPrice)}
                      <span className="ml-1 text-[10px] font-normal text-slate-500">
                        fallback
                      </span>
                    </p>
                    <p className="mt-1 text-xs text-slate-400">
                      {product.availableQuantity === null
                        ? 'Bundle: stok dicek server'
                        : `Tersedia ± ${product.availableQuantity} ${product.uomName}`}
                    </p>
                  </button>
                ))}
              </div>
            </section>

            <aside className="pos-checkout rounded-2xl border border-slate-800 bg-slate-900 p-3 sm:p-4">
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
              <div className="pos-cart-list space-y-2.5 overflow-y-auto py-3">
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
                    return (
                      <div
                        key={item.product.productUomId}
                        className="pos-cart-item rounded-xl border border-slate-800 bg-slate-950 p-3"
                      >
                        <div className="flex items-start justify-between gap-2">
                          <div>
                            <p className="font-bold">{item.product.name}</p>
                            <p className="text-xs text-slate-400">
                              {item.product.uomName} ·{' '}
                              {resolved
                                ? `${money(resolved.unitPrice)} hasil server`
                                : `${money(item.product.fallbackPrice)} fallback`}
                            </p>
                          </div>
                          <button
                            onClick={() =>
                              updateCart(item.product.productUomId, {
                                quantity: 0,
                              })
                            }
                            className="pos-cart-icon-button is-remove"
                            aria-label={`Hapus ${item.product.name} dari keranjang`}
                            title="Hapus dari keranjang"
                          >
                            <Trash2 className="h-4 w-4" />
                          </button>
                        </div>
                        <div className="mt-3 flex items-center gap-2">
                          <button
                            onClick={() =>
                              updateCart(item.product.productUomId, {
                                quantity: item.quantity - 1,
                              })
                            }
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
                            value={item.quantity}
                            onChange={(event) =>
                              updateCart(item.product.productUomId, {
                                quantity: Number(event.target.value),
                              })
                            }
                            className="w-20 rounded-lg border border-slate-700 bg-slate-900 px-2 py-1.5 text-center"
                          />
                          <button
                            onClick={() =>
                              updateCart(item.product.productUomId, {
                                quantity: item.quantity + 1,
                              })
                            }
                            className="pos-cart-icon-button"
                            aria-label={`Tambah jumlah ${item.product.name}`}
                            title="Tambah jumlah"
                          >
                            <Plus className="h-4 w-4" />
                          </button>
                          <span className="ml-auto font-bold">
                            {money(
                              resolved?.lineTotal ??
                                item.product.fallbackPrice * item.quantity,
                            )}
                          </span>
                        </div>
                        <div className="mt-2 grid grid-cols-[1fr_100px] gap-2">
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
                        </div>
                      </div>
                    )
                  })
                )}
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
                <label className="block text-xs font-semibold text-slate-400">
                  Customer
                  <select
                    value={customerId}
                    onChange={(event) => {
                      setCustomerId(event.target.value)
                      setSelectedPricelistId('')
                      setResolvedLines([])
                    }}
                    className="mt-1 w-full rounded-lg border border-slate-700 bg-slate-950 px-3 py-2 text-sm text-slate-100"
                  >
                    {catalog.customers.map((customer) => (
                      <option key={customer.id} value={customer.id}>
                        {customer.name}
                        {customer.isWalkIn ? ' · Umum' : ''}
                      </option>
                    ))}
                  </select>
                </label>
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
                    <input
                      type="number"
                      min="0"
                      value={globalDiscount}
                      onChange={(event) => {
                        setGlobalDiscount(event.target.value)
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
                    onChange={(event) => setIsTempo(event.target.checked)}
                  />
                  Transaksi TEMPO
                </label>
                <div className="pos-section-heading">
                  <span>3</span>
                  <div>
                    <strong>Pembayaran</strong>
                    <small>Pilih cara pelanggan membayar.</small>
                  </div>
                </div>
                {isTempo ? (
                  <label className="block text-xs font-semibold text-slate-400">
                    Jatuh tempo
                    <input
                      type="datetime-local"
                      value={dueDate}
                      onChange={(event) => setDueDate(event.target.value)}
                      className="mt-1 w-full rounded-lg border border-slate-700 bg-slate-950 px-3 py-2 text-sm"
                    />
                  </label>
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
                              {paymentLegs.length > 1 && (
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
                                  onChange={(event) =>
                                    updatePaymentLeg(leg.clientPaymentKey, {
                                      paymentMethodId: event.target.value,
                                      tenderedAmount: '',
                                      proofUrl: '',
                                    })
                                  }
                                >
                                  {catalog.paymentMethods.map((candidate) => {
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
                                    Jumlah yang dibayar
                                  </label>
                                  <button
                                    type="button"
                                    disabled={!draft}
                                    onClick={() =>
                                      fillPaymentRemainder(leg.clientPaymentKey)
                                    }
                                  >
                                    Gunakan sisa tagihan
                                  </button>
                                </div>
                                <input
                                  id={`payment-amount-${leg.clientPaymentKey}`}
                                  type="number"
                                  min="0"
                                  value={leg.amount}
                                  onChange={(event) => {
                                    const amount = event.target.value
                                    updatePaymentLeg(leg.clientPaymentKey, {
                                      amount,
                                      ...(method?.methodType === 'CASH' &&
                                      (!leg.tenderedAmount ||
                                        leg.tenderedAmount === leg.amount)
                                        ? { tenderedAmount: amount }
                                        : {}),
                                    })
                                  }}
                                  placeholder={
                                    paymentLegs.length === 1
                                      ? 'Masukkan jumlah pembayaran'
                                      : 'Masukkan jumlah'
                                  }
                                />
                              </div>
                              {method?.methodType === 'CASH' && (
                                <label className="pos-payment-field">
                                  <span className="pos-payment-field-label">
                                    Uang tunai dari pelanggan
                                  </span>
                                  <input
                                    type="number"
                                    min="0"
                                    value={leg.tenderedAmount}
                                    onChange={(event) =>
                                      updatePaymentLeg(leg.clientPaymentKey, {
                                        tenderedAmount: event.target.value,
                                      })
                                    }
                                    placeholder="Masukkan uang yang diterima"
                                  />
                                  <small className="pos-payment-help">
                                    Kembalian dihitung otomatis.
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
                    <div className="pos-payment-summary">
                      <div>
                        <span>Total yang harus dibayar</span>
                        <strong>
                          {draft ? money(paymentDue) : 'Belum dihitung'}
                        </strong>
                      </div>
                      <div>
                        <span>Total pembayaran</span>
                        <strong>{money(paymentBaseTotal)}</strong>
                      </div>
                      <div
                        className={
                          draft && Math.abs(paymentRemaining) > 0.0001
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
                    <span>Subtotal sementara</span>
                    <span>{money(fallbackSubtotal)}</span>
                  </div>
                  <div className="mt-2 flex justify-between text-lg font-black">
                    <span>Total akhir</span>
                    <span className="text-emerald-400">
                      {draft
                        ? money(draft.grandTotalAfterRounding)
                        : 'Simpan untuk hitung total'}
                    </span>
                  </div>
                  {draft && draft.roundingAdjustment !== 0 && (
                    <p className="mt-1 text-right text-xs text-slate-400">
                      Sebelum {money(draft.grandTotalBeforeRounding)} · Selisih{' '}
                      {money(draft.roundingAdjustment)}
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
                    Simpan Draft
                  </button>
                  <button
                    disabled={busy || cart.length === 0 || !isOnline}
                    onClick={handlePostSale}
                    className="rounded-xl bg-emerald-500 px-3 py-3 font-black text-slate-950 disabled:opacity-40"
                  >
                    {busy ? 'Memproses…' : 'Konfirmasi & Post'}
                  </button>
                </div>
              </div>
            </aside>
          </div>
        )}

        {cashierSession && (
          <section className="pos-session-strip mt-4 flex flex-wrap items-center gap-3 rounded-2xl border border-slate-800 bg-slate-900 p-4">
            <Clock3 className="h-5 w-5 text-emerald-400" />
            <div className="mr-auto">
              <p className="font-bold">{cashierSession.code}</p>
              <p className="text-xs text-slate-400">
                {activeCompany?.name} · {activeTerminal?.storeName} ·{' '}
                {activeWarehouse?.name}
              </p>
            </div>
            <label className="text-xs text-slate-400">
              Kas fisik penutupan
              <input
                type="number"
                min="0"
                value={closingCash}
                onChange={(event) => setClosingCash(event.target.value)}
                className="ml-2 rounded-lg border border-slate-700 bg-slate-950 px-3 py-2 text-sm text-slate-100"
              />
            </label>
            <button
              disabled={busy}
              onClick={handleCloseSession}
              className="rounded-xl border border-rose-800 px-4 py-2 text-sm font-bold text-rose-300"
            >
              Tutup Sesi
            </button>
          </section>
        )}
      </main>

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
                onClick={() => setReceipt(null)}
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
              <div className="flex justify-between text-xl font-black">
                <span>Total akhir</span>
                <span>{money(receipt.grandTotal)}</span>
              </div>
              {receipt.payments.map((payment, index) => (
                <div key={`${payment.paymentMethodName}-${index}`} className="flex justify-between">
                  <span>{payment.paymentMethodName}</span>
                  <span>
                    {money(payment.amount)}
                    {payment.changeAmount > 0
                      ? ` · Kembali ${money(payment.changeAmount)}`
                      : ''}
                  </span>
                </div>
              ))}
            </div>
            <div className="mt-6 grid grid-cols-2 gap-2">
              <button
                onClick={handlePrint}
                className="flex items-center justify-center gap-2 rounded-xl border border-slate-300 px-4 py-3 font-bold"
              >
                <Printer className="h-5 w-5" />
                Buka & cetak
              </button>
              <button
                onClick={() => setReceipt(null)}
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
        <input
          type="number"
          min="0"
          required
          value={openingCash}
          onChange={(event) => onOpeningCashChange(event.target.value)}
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
