'use client'

import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Session } from '@supabase/supabase-js'
import {
  BarChart3,
  Boxes,
  Building2,
  ChevronDown,
  CircleAlert,
  ContactRound,
  DollarSign,
  FileUp,
  LayoutDashboard,
  Loader2,
  LogOut,
  Menu,
  PackagePlus,
  Search,
  ShieldCheck,
  Store,
  Truck,
  UserPlus,
  Users,
  Weight,
  X,
} from 'lucide-react'
import { supabase } from '@/lib/supabase'

type View = 'dashboard' | 'products' | 'customers' | 'finance' | 'staff' | 'companies'

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
type Customer = { id: string; code: string; name: string; phone: string; balance: number }
type JournalEntry = { id: string; journalNo: string; date: string; account: string; debit: number; credit: number; note: string }

const navigation: { id: View; label: string; icon: typeof LayoutDashboard; superOnly?: boolean }[] = [
  { id: 'dashboard', label: 'Ringkasan', icon: LayoutDashboard },
  { id: 'products', label: 'Produk & Stok', icon: Boxes },
  { id: 'customers', label: 'Pelanggan', icon: ContactRound },
  { id: 'finance', label: 'Keuangan', icon: DollarSign },
  { id: 'staff', label: 'Tim & Akses', icon: Users },
  { id: 'companies', label: 'Perusahaan', icon: Building2, superOnly: true },
]

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
  const [activeView, setActiveView] = useState<View>('dashboard')
  const [mobileNav, setMobileNav] = useState(false)
  const [products, setProducts] = useState<Product[]>([])
  const [staff, setStaff] = useState<Staff[]>([])
  const [stores, setStores] = useState<StoreOption[]>([])
  const [customers, setCustomers] = useState<Customer[]>([])
  const [journal, setJournal] = useState<JournalEntry[]>([])
  const [loadingData, setLoadingData] = useState(false)
  const [notice, setNotice] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [showImport, setShowImport] = useState(false)
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
    setContext(payload)

    const storageKey = `kgs-active-company:${activeSession.user.id}`
    const savedCompany = localStorage.getItem(storageKey)
    const selected =
      payload.companies.find((company) => company.id === savedCompany) ??
      payload.companies.find((company) => company.isDefault) ??
      payload.companies[0]
    setActiveCompanyId(selected?.id ?? '')
  }, [])

  useEffect(() => {
    if (!session) return
    // eslint-disable-next-line react-hooks/set-state-in-effect -- account context follows the authenticated session
    void loadContext(session).catch((error: unknown) => {
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
        .select('id, sku, name, category, price, cogs, uom, weight_per_uom_kg, product_stocks!product_stocks_product_id_fkey(stock_qty, warehouses!product_stocks_warehouse_id_fkey(code, name))')
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
          uom: product.uom,
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
        { data: customerRows, error: customerError },
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
            .from('customers')
            .select('id, code, name, phone, current_balance')
            .eq('company_id', activeCompanyId)
            .order('name'),
          supabase
            .from('journal_entries')
            .select('id, journal_no, transaction_date, coa_code, coa_name, debit, kredit, note')
            .eq('company_id', activeCompanyId)
            .order('transaction_date', { ascending: false })
            .limit(100),
        ])
      if (staffError) throw staffError
      if (storeError) throw storeError
      if (customerError) throw customerError
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
      setCustomers(
        ((customerRows ?? []) as { id: string; code: string; name: string; phone: string | null; current_balance: number | string }[]).map((customer) => ({
          id: customer.id,
          code: customer.code,
          name: customer.name,
          phone: customer.phone ?? '-',
          balance: Number(customer.current_balance) || 0,
        })),
      )
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

  const filteredProducts = useMemo(() => {
    const query = search.trim().toLowerCase()
    if (!query) return products
    return products.filter((product) =>
      [product.sku, product.name, product.category].some((value) => value.toLowerCase().includes(query)),
    )
  }, [products, search])

  function changeCompany(companyId: string) {
    if (!session) return
    localStorage.setItem(`kgs-active-company:${session.user.id}`, companyId)
    setActiveCompanyId(companyId)
    setSearch('')
    setActiveView('dashboard')
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

  return (
    <div className="min-h-screen bg-[#f6f7f9] text-slate-900">
      <Sidebar
        view={activeView}
        setView={setActiveView}
        isSuperAdmin={context.isSuperAdmin}
        mobileOpen={mobileNav}
        closeMobile={() => setMobileNav(false)}
      />

      <div className="lg:pl-64">
        <header className="sticky top-0 z-30 flex h-20 items-center gap-4 border-b border-slate-200/80 bg-white/95 px-4 backdrop-blur md:px-8">
          <button onClick={() => setMobileNav(true)} className="rounded-xl border border-slate-200 p-2.5 lg:hidden" aria-label="Buka navigasi">
            <Menu className="h-5 w-5" />
          </button>

          <div className="min-w-0 flex-1">
            <p className="text-xs font-semibold uppercase tracking-[0.16em] text-emerald-600">Workspace aktif</p>
            <div className="relative mt-1 inline-flex max-w-full items-center">
              <Building2 className="pointer-events-none absolute left-3 h-4 w-4 text-slate-400" />
              <select
                value={activeCompanyId}
                onChange={(event) => changeCompany(event.target.value)}
                className="max-w-full appearance-none rounded-xl border border-slate-200 bg-slate-50 py-2 pl-9 pr-9 text-sm font-bold text-slate-800 outline-none transition focus:border-emerald-500"
              >
                {context.companies.map((company) => (
                  <option key={company.id} value={company.id}>{company.company_name} ({company.company_code})</option>
                ))}
              </select>
              <ChevronDown className="pointer-events-none absolute right-3 h-4 w-4 text-slate-400" />
            </div>
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
          {notice && (
            <div className="mb-6 flex items-start gap-3 rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">
              <CircleAlert className="mt-0.5 h-5 w-5 shrink-0" />
              <span className="flex-1">{notice}</span>
              <button onClick={() => setNotice(null)} aria-label="Tutup"><X className="h-4 w-4" /></button>
            </div>
          )}

          {activeView === 'dashboard' && (
            <Dashboard
              company={activeCompany}
              products={products}
              staff={staff}
              loading={loadingData}
              goProducts={() => setActiveView('products')}
              openImport={() => setShowImport(true)}
              canManage={Boolean(canManage)}
            />
          )}

          {activeView === 'products' && (
            <ProductsView
              products={filteredProducts}
              totalProducts={products.length}
              search={search}
              setSearch={setSearch}
              openImport={() => setShowImport(true)}
              loading={loadingData}
              canManage={Boolean(canManage)}
            />
          )}

          {activeView === 'staff' && (
            <StaffView staff={staff} canManage={Boolean(canManage)} openCreate={() => setShowStaff(true)} />
          )}

          {activeView === 'customers' && <CustomersView customers={customers} />}

          {activeView === 'finance' && <FinanceView journal={journal} />}

          {activeView === 'companies' && context.isSuperAdmin && (
            <CompaniesView companies={context.companies} openCreate={() => setShowTenant(true)} />
          )}
        </main>
      </div>

      {showImport && (
        <ImportModal
          session={session}
          company={activeCompany}
          close={() => setShowImport(false)}
          complete={async (message) => {
            setShowImport(false)
            setNotice(message)
            await loadTenantData()
          }}
        />
      )}

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

function Sidebar({ view, setView, isSuperAdmin, mobileOpen, closeMobile }: { view: View; setView: (view: View) => void; isSuperAdmin: boolean; mobileOpen: boolean; closeMobile: () => void }) {
  return (
    <>
      {mobileOpen && <button onClick={closeMobile} className="fixed inset-0 z-40 bg-slate-950/40 lg:hidden" aria-label="Tutup navigasi" />}
      <aside className={`fixed inset-y-0 left-0 z-50 w-64 border-r border-slate-800 bg-slate-950 text-white transition-transform lg:translate-x-0 ${mobileOpen ? 'translate-x-0' : '-translate-x-full'}`}>
        <div className="flex h-20 items-center justify-between px-6">
          <div className="flex items-center gap-3 font-black tracking-tight">
            <span className="grid h-10 w-10 place-items-center rounded-xl bg-emerald-500"><Store className="h-5 w-5" /></span>
            KGS POS
          </div>
          <button onClick={closeMobile} className="lg:hidden" aria-label="Tutup"><X className="h-5 w-5" /></button>
        </div>
        <nav className="px-3 py-5">
          <p className="px-3 text-[10px] font-bold uppercase tracking-[.18em] text-slate-600">Operasional</p>
          <div className="mt-3 space-y-1">
            {navigation.filter((item) => !item.superOnly || isSuperAdmin).map((item) => {
              const Icon = item.icon
              const active = view === item.id
              return (
                <button key={item.id} onClick={() => { setView(item.id); closeMobile() }} className={`flex w-full items-center gap-3 rounded-xl px-3 py-3 text-sm font-semibold transition ${active ? 'bg-emerald-500 text-white shadow-lg shadow-emerald-500/15' : 'text-slate-400 hover:bg-white/5 hover:text-white'}`}>
                  <Icon className="h-4 w-4" />{item.label}
                </button>
              )
            })}
          </div>
        </nav>
        <div className="absolute inset-x-3 bottom-4 rounded-2xl border border-white/5 bg-white/[.03] p-4">
          <div className="flex items-center gap-2 text-xs font-bold text-emerald-300"><ShieldCheck className="h-4 w-4" /> Tenant protection</div>
          <p className="mt-2 text-[11px] leading-5 text-slate-500">Company context diverifikasi kembali oleh RLS dan backend.</p>
        </div>
      </aside>
    </>
  )
}

function PageTitle({ eyebrow, title, description, action }: { eyebrow: string; title: string; description: string; action?: React.ReactNode }) {
  return <div className="mb-7 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between"><div><p className="text-xs font-bold uppercase tracking-[.16em] text-emerald-600">{eyebrow}</p><h1 className="mt-2 text-2xl font-black tracking-tight text-slate-950 md:text-3xl">{title}</h1><p className="mt-2 text-sm text-slate-500">{description}</p></div>{action}</div>
}

function Dashboard({ company, products, staff, loading, goProducts, openImport, canManage }: { company: CompanyContext; products: Product[]; staff: Staff[]; loading: boolean; goProducts: () => void; openImport: () => void; canManage: boolean }) {
  const totalStock = products.reduce((sum, product) => sum + product.stock, 0)
  const inventoryValue = products.reduce((sum, product) => sum + product.stock * product.cogs, 0)
  const totalWeight = products.reduce((sum, product) => sum + product.stock * product.weightPerUomKg, 0)
  const stats = [
    { label: 'Produk aktif', value: products.length.toLocaleString('id-ID'), icon: Boxes, color: 'text-blue-600 bg-blue-50' },
    { label: 'Total unit stok', value: totalStock.toLocaleString('id-ID'), icon: PackagePlus, color: 'text-emerald-600 bg-emerald-50' },
    { label: 'Nilai persediaan', value: rupiah(inventoryValue), icon: BarChart3, color: 'text-violet-600 bg-violet-50' },
    { label: 'Estimasi berat stok', value: `${totalWeight.toLocaleString('id-ID', { maximumFractionDigits: 2 })} kg`, icon: Weight, color: 'text-amber-600 bg-amber-50' },
  ]
  return <><PageTitle eyebrow={company.company_code} title={`Halo, ${company.company_name}`} description="Ringkasan operasional berdasarkan company yang sedang aktif." action={canManage ? <button onClick={openImport} className="inline-flex items-center justify-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 text-sm font-bold text-white hover:bg-emerald-600"><FileUp className="h-4 w-4" />Impor produk</button> : undefined} />
    <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">{stats.map((stat) => <div key={stat.label} className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"><div className={`grid h-10 w-10 place-items-center rounded-xl ${stat.color}`}><stat.icon className="h-5 w-5" /></div><p className="mt-5 text-xs font-semibold text-slate-500">{stat.label}</p><p className="mt-1 text-xl font-black text-slate-950">{loading ? '—' : stat.value}</p></div>)}</div>
    <div className="mt-6 grid gap-6 xl:grid-cols-[1.4fr_.6fr]"><div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"><div className="flex items-center justify-between"><div><h2 className="font-bold">Produk dengan stok terendah</h2><p className="mt-1 text-xs text-slate-500">Prioritaskan pembelian dan pemindahan stok.</p></div><button onClick={goProducts} className="text-xs font-bold text-emerald-600">Lihat semua</button></div><div className="mt-5 space-y-3">{products.slice().sort((a,b) => a.stock-b.stock).slice(0,5).map((product) => <div key={product.id} className="flex items-center gap-3 rounded-xl bg-slate-50 p-3"><div className="grid h-10 w-10 place-items-center rounded-xl bg-white text-slate-500"><Boxes className="h-4 w-4" /></div><div className="min-w-0 flex-1"><p className="truncate text-sm font-bold">{product.name}</p><p className="text-xs text-slate-500">{product.sku} · {product.locations || 'Belum ada lokasi'}</p></div><p className={`text-sm font-black ${product.stock <= 5 ? 'text-rose-600' : 'text-slate-800'}`}>{product.stock} {product.uom}</p></div>)}{!products.length && <Empty label="Belum ada produk. Mulai dari impor template CSV." />}</div></div>
    <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"><h2 className="font-bold">Akses tim</h2><p className="mt-1 text-xs text-slate-500">{staff.length} pengguna terhubung ke company ini.</p><div className="mt-5 space-y-3">{staff.slice(0,5).map((member) => <div key={member.id} className="flex items-center gap-3"><div className="grid h-9 w-9 place-items-center rounded-full bg-slate-100 text-xs font-black text-slate-600">{member.name.slice(0,2).toUpperCase()}</div><div className="min-w-0"><p className="truncate text-sm font-bold">{member.name}</p><p className="truncate text-xs text-slate-500">{roleLabels[member.role] ?? member.role}</p></div></div>)}</div></div></div></>
}

function ProductsView({ products, totalProducts, search, setSearch, openImport, loading, canManage }: { products: Product[]; totalProducts: number; search: string; setSearch: (value: string) => void; openImport: () => void; loading: boolean; canManage: boolean }) {
  return <><PageTitle eyebrow="Inventory" title="Produk & stok" description={`${totalProducts} produk pada company aktif. Berat dihitung untuk setiap satu UOM produk.`} action={canManage ? <button onClick={openImport} className="inline-flex items-center justify-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 text-sm font-bold text-white"><FileUp className="h-4 w-4" />Impor CSV</button> : undefined} />
    <div className="rounded-2xl border border-slate-200 bg-white shadow-sm"><div className="flex items-center gap-3 border-b border-slate-100 p-4"><Search className="h-4 w-4 text-slate-400" /><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Cari SKU, produk, atau kategori..." className="w-full bg-transparent text-sm outline-none" /></div><div className="overflow-x-auto"><table className="w-full min-w-[880px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500"><tr><th className="px-5 py-4">Produk</th><th className="px-5 py-4">Kategori</th><th className="px-5 py-4 text-right">Harga</th><th className="px-5 py-4 text-right">Stok</th><th className="px-5 py-4 text-right">Berat / UOM</th><th className="px-5 py-4">Lokasi</th></tr></thead><tbody className="divide-y divide-slate-100">{products.map((product) => <tr key={product.id} className="hover:bg-slate-50/70"><td className="px-5 py-4"><p className="font-bold text-slate-900">{product.name}</p><p className="mt-1 text-xs font-medium text-slate-400">{product.sku}</p></td><td className="px-5 py-4 text-slate-600">{product.category}</td><td className="px-5 py-4 text-right font-semibold">{rupiah(product.price)}</td><td className="px-5 py-4 text-right font-black">{product.stock.toLocaleString('id-ID')} {product.uom}</td><td className="px-5 py-4 text-right"><span className="inline-flex items-center gap-1.5 rounded-lg bg-amber-50 px-2.5 py-1.5 font-bold text-amber-700"><Weight className="h-3.5 w-3.5" />{product.weightPerUomKg.toLocaleString('id-ID')} kg</span></td><td className="px-5 py-4 text-slate-600">{product.locations || '-'}</td></tr>)}</tbody></table>{loading && <div className="p-10 text-center text-sm text-slate-500">Memuat produk...</div>}{!loading && !products.length && <Empty label="Produk tidak ditemukan." />}</div></div></>
}

function StaffView({ staff, canManage, openCreate }: { staff: Staff[]; canManage: boolean; openCreate: () => void }) {
  return <><PageTitle eyebrow="Access control" title="Tim & akses" description="Kelola pengguna hanya pada company yang sedang aktif." action={canManage ? <button onClick={openCreate} className="inline-flex items-center justify-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 text-sm font-bold text-white"><UserPlus className="h-4 w-4" />Tambah anggota</button> : undefined} /><div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">{staff.map((member) => <div key={member.id} className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"><div className="flex items-start gap-4"><div className="grid h-12 w-12 place-items-center rounded-2xl bg-slate-100 font-black text-slate-600">{member.name.slice(0,2).toUpperCase()}</div><div className="min-w-0"><p className="truncate font-bold text-slate-950">{member.name}</p><p className="truncate text-sm text-slate-500">{member.email}</p><span className="mt-3 inline-flex rounded-full bg-emerald-50 px-2.5 py-1 text-[11px] font-bold text-emerald-700">{roleLabels[member.role] ?? member.role}</span></div></div></div>)}{!staff.length && <div className="md:col-span-2 xl:col-span-3"><Empty label="Belum ada anggota yang dapat ditampilkan." /></div>}</div></>
}

function CompaniesView({ companies, openCreate }: { companies: CompanyContext[]; openCreate: () => void }) {
  return <><PageTitle eyebrow="Platform control" title="Perusahaan" description="Daftar seluruh tenant aktif yang dapat dikelola super admin." action={<button onClick={openCreate} className="inline-flex items-center justify-center gap-2 rounded-xl bg-emerald-500 px-4 py-3 text-sm font-bold text-white"><Building2 className="h-4 w-4" />Perusahaan baru</button>} /><div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">{companies.map((company) => <div key={company.id} className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"><div className="flex items-center gap-4"><div className="grid h-12 w-12 place-items-center rounded-2xl bg-blue-50 text-blue-600"><Building2 className="h-5 w-5" /></div><div><p className="font-bold">{company.company_name}</p><p className="mt-1 text-xs font-semibold text-slate-400">{company.company_code}</p></div></div><div className="mt-5 flex items-center justify-between border-t border-slate-100 pt-4 text-xs"><span className="text-slate-500">Status tenant</span><span className="rounded-full bg-emerald-50 px-2.5 py-1 font-bold text-emerald-700">{company.status}</span></div></div>)}</div></>
}

function CustomersView({ customers }: { customers: Customer[] }) {
  const totalBalance = customers.reduce((sum, customer) => sum + customer.balance, 0)
  return <><PageTitle eyebrow="Customer" title="Pelanggan" description={`${customers.length} pelanggan pada company aktif · total saldo ${rupiah(totalBalance)}.`} /><div className="rounded-2xl border border-slate-200 bg-white shadow-sm"><div className="overflow-x-auto"><table className="w-full min-w-[680px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500"><tr><th className="px-5 py-4">Kode</th><th className="px-5 py-4">Nama</th><th className="px-5 py-4">Telepon</th><th className="px-5 py-4 text-right">Saldo</th></tr></thead><tbody className="divide-y divide-slate-100">{customers.map((customer) => <tr key={customer.id}><td className="px-5 py-4 font-semibold text-slate-500">{customer.code}</td><td className="px-5 py-4 font-bold">{customer.name}</td><td className="px-5 py-4 text-slate-600">{customer.phone}</td><td className="px-5 py-4 text-right font-black text-emerald-700">{rupiah(customer.balance)}</td></tr>)}</tbody></table>{!customers.length && <Empty label="Belum ada pelanggan pada company ini." />}</div></div></>
}

function FinanceView({ journal }: { journal: JournalEntry[] }) {
  const debit = journal.reduce((sum, entry) => sum + entry.debit, 0)
  const credit = journal.reduce((sum, entry) => sum + entry.credit, 0)
  return <><PageTitle eyebrow="Finance" title="Jurnal umum" description="Entri jurnal terbaru yang lolos akses accounting company aktif." /><div className="mb-5 grid gap-4 sm:grid-cols-2"><div className="rounded-2xl border border-slate-200 bg-white p-5"><p className="text-xs font-semibold text-slate-500">Total debit terlihat</p><p className="mt-2 text-xl font-black">{rupiah(debit)}</p></div><div className="rounded-2xl border border-slate-200 bg-white p-5"><p className="text-xs font-semibold text-slate-500">Total kredit terlihat</p><p className="mt-2 text-xl font-black">{rupiah(credit)}</p></div></div><div className="rounded-2xl border border-slate-200 bg-white shadow-sm"><div className="overflow-x-auto"><table className="w-full min-w-[900px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wider text-slate-500"><tr><th className="px-5 py-4">Jurnal</th><th className="px-5 py-4">Akun</th><th className="px-5 py-4">Catatan</th><th className="px-5 py-4 text-right">Debit</th><th className="px-5 py-4 text-right">Kredit</th></tr></thead><tbody className="divide-y divide-slate-100">{journal.map((entry) => <tr key={entry.id}><td className="px-5 py-4"><p className="font-bold">{entry.journalNo}</p><p className="mt-1 text-xs text-slate-400">{new Date(entry.date).toLocaleDateString('id-ID')}</p></td><td className="px-5 py-4 text-slate-600">{entry.account}</td><td className="max-w-xs truncate px-5 py-4 text-slate-500">{entry.note}</td><td className="px-5 py-4 text-right font-semibold">{entry.debit ? rupiah(entry.debit) : '-'}</td><td className="px-5 py-4 text-right font-semibold">{entry.credit ? rupiah(entry.credit) : '-'}</td></tr>)}</tbody></table>{!journal.length && <Empty label="Belum ada jurnal yang dapat ditampilkan." />}</div></div></>
}

function ImportModal({ session, company, close, complete }: { session: Session; company: CompanyContext; close: () => void; complete: (message: string) => Promise<void> }) {
  const [file, setFile] = useState<File | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState('')
  async function submit(event: React.FormEvent) { event.preventDefault(); if (!file) return; setLoading(true); setError(''); try { const response = await fetch('/api/products/import', { method: 'POST', headers: { 'Content-Type': 'application/json', ...authHeaders(session) }, body: JSON.stringify({ csvText: await file.text(), companyId: company.id }) }); const payload = (await response.json()) as { error?: string; result?: { processed?: number } }; if (!response.ok) throw new Error(payload.error ?? 'Import gagal'); await complete(`${payload.result?.processed ?? 'Semua'} baris produk berhasil diimpor.`) } catch (caught) { setError(caught instanceof Error ? caught.message : 'Import gagal') } finally { setLoading(false) } }
  return <Modal title="Impor produk & stok awal" description={`Data akan masuk ke ${company.company_name}. Import ulang dengan stok berbeda akan ditolak agar stok tidak terduplikasi.`} close={close}><a href="/import_template.csv" download className="mb-5 flex items-center justify-between rounded-xl border border-emerald-200 bg-emerald-50 p-4 text-sm font-bold text-emerald-700"><span>Unduh template dengan berat / UOM</span><FileUp className="h-4 w-4" /></a><form onSubmit={submit}><input type="file" accept=".csv,text/csv" required onChange={(event) => setFile(event.target.files?.[0] ?? null)} className="w-full rounded-xl border border-dashed border-slate-300 bg-slate-50 p-5 text-sm" />{error && <FormError message={error} />}<ModalActions close={close} loading={loading} submit="Mulai impor" /></form></Modal>
}

function StaffModal({ session, company, stores, close, complete }: { session: Session; company: CompanyContext; stores: StoreOption[]; close: () => void; complete: () => Promise<void> }) {
  const [form, setForm] = useState({ name: '', email: '', password: '', role_code: 'CASHIER', store_id: 'NONE' }); const [loading, setLoading] = useState(false); const [error, setError] = useState('')
  async function submit(event: React.FormEvent) { event.preventDefault(); setLoading(true); setError(''); try { const response = await fetch('/api/staff/create', { method: 'POST', headers: { 'Content-Type': 'application/json', ...authHeaders(session) }, body: JSON.stringify({ ...form, company_id: company.id }) }); const payload = (await response.json()) as { error?: string }; if (!response.ok) throw new Error(payload.error ?? 'Gagal membuat anggota'); await complete() } catch (caught) { setError(caught instanceof Error ? caught.message : 'Gagal membuat anggota') } finally { setLoading(false) } }
  return <Modal title="Tambah anggota tim" description={`Akun hanya akan mendapat akses ke ${company.company_name}.`} close={close}><form onSubmit={submit} className="space-y-4"><Field label="Nama"><input required value={form.name} onChange={(e) => setForm({...form,name:e.target.value})} className="input" /></Field><Field label="Email"><input required type="email" value={form.email} onChange={(e) => setForm({...form,email:e.target.value})} className="input" /></Field><Field label="Password sementara"><input required minLength={8} type="password" value={form.password} onChange={(e) => setForm({...form,password:e.target.value})} className="input" /></Field><div className="grid gap-4 sm:grid-cols-2"><Field label="Role"><select value={form.role_code} onChange={(e) => setForm({...form,role_code:e.target.value})} className="input">{['CASHIER','STORE_MANAGER','WAREHOUSE_ADMIN','FINANCE','ACCOUNTING','COMPANY_ADMIN'].map((role) => <option key={role} value={role}>{roleLabels[role]}</option>)}</select></Field><Field label="Toko"><select value={form.store_id} onChange={(e) => setForm({...form,store_id:e.target.value})} className="input"><option value="NONE">Semua / tidak spesifik</option>{stores.map((store) => <option key={store.id} value={store.id}>{store.store_name}</option>)}</select></Field></div>{error && <FormError message={error} />}<ModalActions close={close} loading={loading} submit="Buat akun" /></form></Modal>
}

function TenantModal({ session, close, complete }: { session: Session; close: () => void; complete: () => Promise<void> }) {
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
