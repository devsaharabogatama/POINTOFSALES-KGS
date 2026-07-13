"use client"

import { useState, useEffect } from 'react'
import { 
  TrendingUp, 
  DollarSign, 
  ArrowUpRight, 
  ArrowDownRight, 
  Layers, 
  Database, 
  ListTodo, 
  AlertTriangle, 
  Search, 
  Filter, 
  ChevronRight, 
  PlusCircle, 
  CheckCircle2, 
  XCircle, 
  AlertCircle,
  FileText,
  RefreshCw,
  ArrowLeftRight,
  HandCoins,
  Warehouse,
  Printer,
  Upload,
  Download,
  Calendar,
  ClipboardList
} from 'lucide-react'
import { supabase } from '../lib/supabase'

// Fallback Mock data for Dashboard
const STATS = [
  { name: 'Total Penjualan', value: 'Rp 45.280.000', change: '+12.5%', type: 'up', note: 'Hari ini' },
  { name: 'Total Pengeluaran (CA)', value: 'Rp 2.450.000', change: '-4.2%', type: 'down', note: 'Bulan ini' },
  { name: 'Saldo Kas & Bank', value: 'Rp 42.830.000', change: '+8.3%', type: 'up', note: 'Ter-rekonsiliasi' },
  { name: 'Peringatan Stok Rendah', value: '3 Item', change: 'Segera PO', type: 'warn', note: 'Batas minimal < 20' },
]

const MOCK_STOCKS = [
  { id: '1', sku: 'SEM-PAD-50', name: 'Semen Padang 50kg', category: 'Bahan Bangunan', stockKGS: 120, stockGDS: 350, minStock: 50, uom: 'sak' },
  { id: '2', sku: 'BES-BET-10', name: 'Besi Beton 10mm SNI', category: 'Bahan Bangunan', stockKGS: 85, stockGDS: 180, minStock: 30, uom: 'batang' },
  { id: '3', sku: 'CAT-AV-WHT', name: 'Avitex Putih 5kg', category: 'Cat & Pewarna', stockKGS: 40, stockGDS: 15, minStock: 20, uom: 'pail' },
  { id: '4', sku: 'PAKU-3INCH', name: 'Paku Kayu 3 Inch', category: 'Alat & Perkakas', stockKGS: 15, stockGDS: 0, minStock: 20, uom: 'kg' }, // LOW STOCK
  { id: '5', sku: 'KAYU-MER-4M', name: 'Kayu Meranti 4x6x4m', category: 'Bahan Bangunan', stockKGS: 200, stockGDS: 500, minStock: 100, uom: 'batang' },
  { id: '6', sku: 'SEL-GRD-4IN', name: 'Selang Green Elastic 4"', category: 'Alat & Perkakas', stockKGS: 65, stockGDS: 20, minStock: 15, uom: 'meter' },
  { id: '7', sku: 'CAT-EXP-BLK', name: 'No Drop Hitam 4kg', category: 'Cat & Pewarna', stockKGS: 18, stockGDS: 0, minStock: 20, uom: 'pail' }, // LOW STOCK
  { id: '8', sku: 'TANG-KR-8IN', name: 'Tang Kombinasi Kenmaster 8"', category: 'Alat & Perkakas', stockKGS: 12, stockGDS: 5, minStock: 20, uom: 'pcs' }, // LOW STOCK
]

const MOCK_MOVEMENTS = [
  { id: 'm1', date: '13/07/2026 10:45', sku: 'SEM-PAD-50', name: 'Semen Padang 50kg', wh: 'KGS Toko', change: -2, type: 'SALE', ref: 'SO-00750' },
  { id: 'm2', date: '13/07/2026 10:45', sku: 'BES-BET-10', name: 'Besi Beton 10mm SNI', wh: 'KGS Toko', change: -1, type: 'SALE', ref: 'SO-00750' },
  { id: 'm3', date: '13/07/2026 09:15', sku: 'SEM-PAD-50', name: 'Semen Padang 50kg', wh: 'GDS Gudang', change: 200, type: 'PURCHASE', ref: 'PO-00123' },
  { id: 'm4', date: '13/07/2026 09:20', sku: 'SEM-PAD-50', name: 'Semen Padang 50kg', wh: 'GDS Gudang', change: -50, type: 'TRANSFER_OUT', ref: 'TF-901' },
  { id: 'm5', date: '13/07/2026 09:20', sku: 'SEM-PAD-50', name: 'Semen Padang 50kg', wh: 'KGS Toko', change: 50, type: 'TRANSFER_IN', ref: 'TF-901' },
  { id: 'm6', date: '12/07/2026 16:30', sku: 'PAKU-3INCH', name: 'Paku Kayu 3 Inch', wh: 'KGS Toko', change: -3, type: 'ADJUSTMENT', ref: 'Koreksi Rusak' },
]

const MOCK_OPNAMES = [
  { id: 'op1', no: 'OPN-20260710-001', wh: 'KGS Toko', date: '10/07/2026', notes: 'Opname Mingguan', status: 'APPROVED', auditor: 'Hendra' },
  { id: 'op2', no: 'OPN-20260713-001', wh: 'GDS Gudang', date: '13/07/2026', notes: 'Audit Semesteran', status: 'DRAFT', auditor: 'Manager Andi' },
]

const MOCK_EVENTS = [
  { id: 'EVT-001', code: 'EVT-20260713-000001', type: 'SALE_POSTED', source: 'sales_headers', rootSales: 'SO-00750', date: '13/07/2026 10:45', amount: 150000, status: 'DONE', error: null },
  { id: 'EVT-002', code: 'EVT-20260713-000002', type: 'PAYMENT_RECEIVED', source: 'sales_payments', rootSales: 'SO-00750', date: '13/07/2026 10:45', amount: 150000, status: 'DONE', error: null },
  { id: 'EVT-003', code: 'EVT-20260713-000003', type: 'EXPENSE_POSTED', source: 'cash_advances', rootSales: '-', date: '13/07/2026 09:30', amount: 45000, status: 'DONE', error: null },
  { id: 'EVT-004', code: 'EVT-20260713-000004', type: 'SALE_POSTED', source: 'sales_headers', rootSales: 'SO-00751', date: '13/07/2026 10:48', amount: 215000, status: 'READY', error: null },
  { id: 'EVT-005', code: 'EVT-20260713-000005', type: 'SALE_VOIDED', source: 'sales_headers', rootSales: 'SO-00742', date: '12/07/2026 17:15', amount: 85000, status: 'ERROR', error: 'Balance mismatch: Debits (85000) != Credits (0)' },
]

const MOCK_JOURNAL = [
  { id: '1', jnlNo: 'JNL-20260713-0001', eventCode: 'EVT-20260713-000001', coa: '1101-01', coaName: 'Kas Kasir KGS', debit: 150000, kredit: 0, note: 'Penjualan SO-00750' },
  { id: '2', jnlNo: 'JNL-20260713-0001', eventCode: 'EVT-20260713-000001', coa: '4101-01', coaName: 'Pendapatan Penjualan', debit: 0, kredit: 150000, note: 'Penjualan SO-00750' },
  { id: '3', jnlNo: 'JNL-20260713-0002', eventCode: 'EVT-20260713-000001', coa: '5101-01', coaName: 'Harga Pokok Penjualan (HPP)', debit: 90000, kredit: 0, note: 'COGS Penjualan SO-00750' },
  { id: '4', jnlNo: 'JNL-20260713-0002', eventCode: 'EVT-20260713-000001', coa: '1301-01', coaName: 'Persediaan Barang Dagang', debit: 0, kredit: 90000, note: 'COGS Penjualan SO-00750' },
  { id: '5', jnlNo: 'JNL-20260713-0003', eventCode: 'EVT-20260713-000003', coa: '6101-02', coaName: 'Beban Uang Makan', debit: 45000, kredit: 0, note: 'Beban CA Makan Siang Kasir' },
  { id: '6', jnlNo: 'JNL-20260713-0003', eventCode: 'EVT-20260713-000003', coa: '1101-01', coaName: 'Kas Kasir KGS', debit: 0, kredit: 45000, note: 'Beban CA Makan Siang Kasir' },
]

const MOCK_CUSTOMERS = [
  { id: 'c1', code: 'CUST-001', name: 'Toko Jaya Mandiri', email: 'jaya@mandiri.com', phone: '08123456789', balance: 500000 },
  { id: 'c2', code: 'CUST-002', name: 'Bapak Ahmad', email: 'ahmad@gmail.com', phone: '08234567890', balance: 150000 },
  { id: 'c3', code: 'CUST-003', name: 'Kontraktor Sentosa', email: 'sentosa@sentosa.com', phone: '08345678901', balance: 0 },
]

const MOCK_PRICELISTS = [
  { id: 'pl1', customerName: 'Toko Jaya Mandiri', productName: 'Semen Padang 50kg', price: 68000 },
  { id: 'pl2', customerName: 'Toko Jaya Mandiri', productName: 'Besi Beton 10mm SNI', price: 82000 },
  { id: 'pl3', customerName: 'Bapak Ahmad', productName: 'Avitex Putih 5kg', price: 38000 },
]


export default function Home() {
  const [activeTab, setActiveTab] = useState<'overview' | 'stock' | 'customer' | 'events' | 'journal' | 'finance'>('overview')
  const [stockSubTab, setStockSubTab] = useState<'levels' | 'movements' | 'opname' | 'orders'>('levels')
  const [customerSubTab, setCustomerSubTab] = useState<'list' | 'pricelist'>('list')
  const [searchQuery, setSearchQuery] = useState('')
  const [isSupabaseConnected, setIsSupabaseConnected] = useState(false)
  const [isProcessingWorker, setIsProcessingWorker] = useState(false)
  const [workerResult, setWorkerResult] = useState<string | null>(null)

  // Real Database and Mock Fallback States
  const [stocks, setStocks] = useState<any[]>(MOCK_STOCKS)
  const [movements, setMovements] = useState<any[]>(MOCK_MOVEMENTS)
  const [opnames, setOpnames] = useState<any[]>(MOCK_OPNAMES)
  const [events, setEvents] = useState<any[]>(MOCK_EVENTS)
  const [journal, setJournal] = useState<any[]>(MOCK_JOURNAL)
  const [purchaseOrders, setPurchaseOrders] = useState<any[]>([])
  
  const [customers, setCustomers] = useState<any[]>(MOCK_CUSTOMERS)
  const [pricelists, setPricelists] = useState<any[]>(MOCK_PRICELISTS)

  // Modals state
  const [showTransferModal, setShowTransferModal] = useState(false)
  const [showExpenseModal, setShowExpenseModal] = useState(false)
  const [showDepositModal, setShowDepositModal] = useState(false)
  const [showImportModal, setShowImportModal] = useState(false)
  const [showAdjustmentModal, setShowAdjustmentModal] = useState(false)
  const [showOpnameModal, setShowOpnameModal] = useState(false)

  const [showCustomerModal, setShowCustomerModal] = useState(false)
  const [showPricelistModal, setShowPricelistModal] = useState(false)
  const [showTopupModal, setShowTopupModal] = useState(false)

  // Form states
  const [transferForm, setTransferForm] = useState({
    productId: '',
    srcWh: 'GDS',
    destWh: 'KGS',
    qty: ''
  })
  const [expenseForm, setExpenseForm] = useState({
    category: 'Bensin',
    description: '',
    amount: '',
    paymentMethod: 'Cash'
  })
  const [depositForm, setDepositForm] = useState({
    amount: '',
    bankAccountInfo: 'BCA KGS 7890123'
  })
  const [adjustmentForm, setAdjustmentForm] = useState({
    productId: '',
    warehouseCode: 'GDS',
    qty: '',
    cogs: '',
    reason: 'Rusak'
  })
  const [customerForm, setCustomerForm] = useState({
    code: '',
    name: '',
    email: '',
    phone: '',
    balance: '0'
  })
  const [pricelistForm, setPricelistForm] = useState({
    customerId: '',
    productId: '',
    price: ''
  })
  const [topupForm, setTopupForm] = useState({
    customerId: '',
    amount: ''
  })

  const [opnameForm, setOpnameForm] = useState({
    warehouseCode: 'GDS',
    notes: '',
    items: MOCK_STOCKS.map(s => ({
      productId: s.id,
      sku: s.sku,
      name: s.name,
      systemQty: s.stockGDS,
      physicalQty: s.stockGDS.toString()
    }))
  })

  // Import CSV files handler
  const [importingFile, setImportingFile] = useState<File | null>(null)
  const [isImporting, setIsImporting] = useState(false)
  const [importResult, setImportResult] = useState<string | null>(null)

  // Function to load all data dynamically from Supabase
  const loadDataFromSupabase = async () => {
    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL
    if (!supabaseUrl || supabaseUrl.includes('your-project-id')) return
    
    try {
      // 1. Fetch products joined with stocks
      const { data: prodData, error: prodErr } = await supabase
        .from('products')
        .select(`
          id, sku, name, category, price, cogs, uom,
          product_stocks (
            stock_qty,
            warehouses (
              code
            )
          )
        `)
      
      if (!prodErr && prodData && prodData.length > 0) {
        const mappedStocks = prodData.map((p: any) => {
          let stockKGS = 0
          let stockGDS = 0
          if (p.product_stocks) {
            p.product_stocks.forEach((st: any) => {
              if (st.warehouses?.code === 'KGS') stockKGS = parseFloat(st.stock_qty) || 0
              if (st.warehouses?.code === 'GDS') stockGDS = parseFloat(st.stock_qty) || 0
            })
          }
          return {
            id: p.id,
            sku: p.sku,
            name: p.name,
            category: p.category || 'Umum',
            stockKGS,
            stockGDS,
            minStock: 20,
            uom: p.uom || 'pcs'
          }
        })
        setStocks(mappedStocks)
      }

      // 2. Fetch Movements
      const { data: movData, error: movErr } = await supabase
        .from('stock_movements')
        .select(`
          id, qty_change, movement_type, reference_table, reference_id, created_at,
          products (sku, name),
          warehouses (code)
        `)
        .order('created_at', { ascending: false })
      
      if (!movErr && movData) {
        const mappedMovements = movData.map((m: any) => ({
          id: m.id,
          sku: m.products?.sku || '-',
          name: m.products?.name || '-',
          wh: m.warehouses?.code === 'GDS' ? 'GDS Gudang' : 'KGS Toko',
          qty: parseFloat(m.qty_change),
          type: m.movement_type,
          ref: `${m.reference_table} (${m.reference_id.substring(0, 5)}...)`,
          date: new Date(m.created_at).toLocaleString('id-ID')
        }))
        setMovements(mappedMovements)
      }

      // 3. Fetch Opnames
      const { data: opnData, error: opnErr } = await supabase
        .from('stock_opnames')
        .select(`
          id, opname_no, created_at, notes, status,
          warehouses (code),
          profiles (name)
        `)
        .order('created_at', { ascending: false })
      
      if (!opnErr && opnData) {
        const mappedOpnames = opnData.map((o: any) => ({
          id: o.id,
          no: o.opname_no,
          wh: o.warehouses?.code === 'GDS' ? 'GDS Gudang' : 'KGS Toko',
          date: new Date(o.created_at).toLocaleDateString('id-ID'),
          notes: o.notes || '',
          status: o.status,
          auditor: o.profiles?.name || 'System'
        }))
        setOpnames(mappedOpnames)
      }

      // 4. Fetch Purchase Orders (PO)
      const { data: poData, error: poErr } = await supabase
        .from('purchases_headers')
        .select(`
          id, purchase_no, supplier_name, transaction_date, grand_total, status,
          warehouses (code)
        `)
        .order('created_at', { ascending: false })
      
      if (!poErr && poData) {
        const mappedPOs = poData.map((po: any) => ({
          id: po.id,
          purchase_no: po.purchase_no,
          supplier_name: po.supplier_name,
          transaction_date: po.transaction_date,
          grand_total: po.grand_total,
          status: po.status,
          warehouse_name: po.warehouses?.code === 'GDS' ? 'GDS Gudang' : 'KGS Toko'
        }))
        setPurchaseOrders(mappedPOs)
      }

      // 5. Fetch Events
      const { data: evtData, error: evtErr } = await supabase
        .from('financial_events')
        .select('*')
        .order('event_date', { ascending: false })
      
      if (!evtErr && evtData) {
        const mappedEvents = evtData.map((e: any) => ({
          id: e.id,
          code: e.event_code,
          type: e.event_type,
          source: e.source_table,
          rootSales: e.root_sales_id || '-',
          date: new Date(e.event_date).toLocaleString('id-ID'),
          amount: parseFloat(e.amounts?.sales_net_amount || e.amounts?.amount || 0),
          status: e.status,
          error: e.error_message
        }))
        setEvents(mappedEvents)
      }

      // 6. Fetch Journal Entries
      const { data: jnlData, error: jnlErr } = await supabase
        .from('journal_entries')
        .select('*')
        .order('transaction_date', { ascending: false })
      
      if (!jnlErr && jnlData) {
        const mappedJournal = jnlData.map((j: any) => ({
          id: j.id,
          jnlNo: j.journal_no,
          eventCode: j.entry_group_id,
          coa: j.coa_code,
          coaName: j.coa_name,
          debit: parseFloat(j.debit),
          kredit: parseFloat(j.kredit),
          note: j.note
        }))
        setJournal(mappedJournal)
      }

      // 7. Fetch Customers
      const { data: custData, error: custErr } = await supabase
        .from('customers')
        .select('*')
        .order('name', { ascending: true })
      
      if (!custErr && custData && custData.length > 0) {
        const mappedCustomers = custData.map((c: any) => ({
          id: c.id,
          code: c.code,
          name: c.name,
          email: c.email || '-',
          phone: c.phone || '-',
          balance: parseFloat(c.balance) || 0
        }))
        setCustomers(mappedCustomers)
      }

      // 8. Fetch Customer Pricelists
      const { data: plData, error: plErr } = await supabase
        .from('customer_pricelists')
        .select(`
          id, custom_price,
          customers (name),
          products (name)
        `)
      
      if (!plErr && plData && plData.length > 0) {
        const mappedPricelists = plData.map((pl: any) => ({
          id: pl.id,
          customerName: pl.customers?.name || '-',
          productName: pl.products?.name || '-',
          price: parseFloat(pl.custom_price) || 0
        }))
        setPricelists(mappedPricelists)
      }

    } catch (err) {
      console.error('Error loading data from Supabase:', err)
    }
  }

  // Handle Confirm Purchase (PO)
  const handleConfirmPurchase = async (purchaseId: string) => {
    if (!isSupabaseConnected) return
    try {
      const { data: userData } = await supabase.auth.getUser()
      const userId = userData?.user?.id || 'd290f1ee-6c54-4b01-90e6-d701748f0851'

      const { error } = await supabase.rpc('confirm_purchase_order', {
        p_purchase_id: purchaseId,
        p_user_id: userId
      })

      if (error) throw error
      alert('Order pembelian (PO) berhasil dikonfirmasi! Stok gudang dan batch FIFO telah terbuat.')
      loadDataFromSupabase()
    } catch (err: any) {
      alert(`Gagal konfirmasi PO: ${err.message}`)
    }
  }

  // Check if supabase variables are actually set
  useEffect(() => {
    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL
    if (supabaseUrl && !supabaseUrl.includes('your-project-id')) {
      setIsSupabaseConnected(true)
    }
  }, [])

  // Auto-refresh when tab changes
  useEffect(() => {
    if (isSupabaseConnected) {
      loadDataFromSupabase()
    }
  }, [isSupabaseConnected, activeTab, stockSubTab])

  // Get current active company id helper
  const getMyCompanyId = async () => {
    const { data: userData } = await supabase.auth.getUser()
    if (!userData?.user?.id) return 'd290f1ee-6c54-4b01-90e6-d701748f0851'
    const { data: members } = await supabase
      .from('company_memberships')
      .select('company_id')
      .eq('user_id', userData.user.id)
      .eq('status', 'ACTIVE')
      .limit(1)
    return members?.[0]?.company_id || 'd290f1ee-6c54-4b01-90e6-d701748f0851'
  }

  // Handle CRUD Customer submit
  const handleCustomerSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!customerForm.code || !customerForm.name) return
    
    if (isSupabaseConnected) {
      try {
        const companyId = await getMyCompanyId()
        const { error } = await supabase.from('customers').insert({
          code: customerForm.code,
          name: customerForm.name,
          email: customerForm.email || null,
          phone: customerForm.phone || null,
          balance: parseFloat(customerForm.balance) || 0,
          company_id: companyId
        })

        if (error) throw error
        alert('Pelanggan baru berhasil ditambahkan!')
        setShowCustomerModal(false)
        setCustomerForm({ code: '', name: '', email: '', phone: '', balance: '0' })
        loadDataFromSupabase()
      } catch (err: any) {
        alert(`Gagal menambah pelanggan: ${err.message}`)
      }
    } else {
      const newCust = {
        id: 'mock-c-' + Date.now(),
        code: customerForm.code,
        name: customerForm.name,
        email: customerForm.email || '-',
        phone: customerForm.phone || '-',
        balance: parseFloat(customerForm.balance) || 0
      }
      setCustomers([...customers, newCust])
      setShowCustomerModal(false)
      setCustomerForm({ code: '', name: '', email: '', phone: '', balance: '0' })
    }
  }

  // Handle topup customer balance
  const handleTopupSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!topupForm.customerId || !topupForm.amount) return

    const topupVal = parseFloat(topupForm.amount)
    if (isSupabaseConnected) {
      try {
        const { data: currentCust } = await supabase.from('customers').select('balance').eq('id', topupForm.customerId).single()
        const newBalance = (parseFloat(currentCust?.balance) || 0) + topupVal

        const { error } = await supabase.from('customers').update({
          balance: newBalance
        }).eq('id', topupForm.customerId)

        if (error) throw error
        alert('Top up saldo deposit pelanggan berhasil!')
        setShowTopupModal(false)
        setTopupForm({ customerId: '', amount: '' })
        loadDataFromSupabase()
      } catch (err: any) {
        alert(`Gagal top up: ${err.message}`)
      }
    } else {
      setCustomers(customers.map(c => c.id === topupForm.customerId ? { ...c, balance: c.balance + topupVal } : c))
      setShowTopupModal(false)
      setTopupForm({ customerId: '', amount: '' })
    }
  }

  // Handle Pricelist Custom submit
  const handlePricelistSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!pricelistForm.customerId || !pricelistForm.productId || !pricelistForm.price) return

    if (isSupabaseConnected) {
      try {
        const companyId = await getMyCompanyId()
        const { error } = await supabase.from('customer_pricelists').insert({
          customer_id: pricelistForm.customerId,
          product_id: pricelistForm.productId,
          custom_price: parseFloat(pricelistForm.price),
          company_id: companyId
        })

        if (error) throw error
        alert('Harga khusus pelanggan berhasil disimpan!')
        setShowPricelistModal(false)
        setPricelistForm({ customerId: '', productId: '', price: '' })
        loadDataFromSupabase()
      } catch (err: any) {
        alert(`Gagal menyimpan harga khusus: ${err.message}`)
      }
    } else {
      const targetCust = customers.find(c => c.id === pricelistForm.customerId)
      const targetProd = stocks.find(s => s.id === pricelistForm.productId)
      const newPl = {
        id: 'mock-pl-' + Date.now(),
        customerName: targetCust?.name || 'Pelanggan',
        productName: targetProd?.name || 'Produk',
        price: parseFloat(pricelistForm.price)
      }
      setPricelists([...pricelists, newPl])
      setShowPricelistModal(false)
      setPricelistForm({ customerId: '', productId: '', price: '' })
    }
  }

  // Trigger Queue Worker calling backend Next.js API
  const handleTriggerWorker = async () => {
    setIsProcessingWorker(true)
    setWorkerResult(null)
    try {
      const response = await fetch('/api/worker/process-queue', { method: 'POST' })
      const result = await response.json()
      if (response.ok) {
        setWorkerResult(`Worker Sukses: Memproses ${result.processed} event. Error: ${result.errors}`)
      } else {
        setWorkerResult(`Worker Gagal: ${result.error}`)
      }
    } catch (err: any) {
      setWorkerResult(`Worker Error: ${err.message}`)
    } finally {
      setIsProcessingWorker(false)
    }
  }

  // Handle Stock Transfer submit
  const handleStockTransferSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!transferForm.productId || !transferForm.qty) return
    
    if (isSupabaseConnected) {
      try {
        const { data: srcData } = await supabase.from('warehouses').select('id').eq('code', transferForm.srcWh).single()
        const { data: destData } = await supabase.from('warehouses').select('id').eq('code', transferForm.destWh).single()
        
        if (!srcData || !destData) throw new Error('Warehouse not found')

        const { error } = await supabase.rpc('transfer_product_stock', {
          p_product_id: transferForm.productId,
          p_src_warehouse_id: srcData.id,
          p_dest_warehouse_id: destData.id,
          p_qty: parseFloat(transferForm.qty)
        })

        if (error) throw error
        alert('Pemindahan stok berhasil disimpan ke Supabase Cloud!')
        setShowTransferModal(false)
        setTransferForm({ productId: '', srcWh: 'GDS', destWh: 'KGS', qty: '' })
      } catch (err: any) {
        alert(`Error pemindahan stok: ${err.message}`)
      }
    } else {
      alert(`[Demo Mode] Pemindahan stok berhasil! ${transferForm.qty} unit dipindah dari Gudang ${transferForm.srcWh} ke Toko ${transferForm.destWh}.`)
      setShowTransferModal(false)
      setTransferForm({ productId: '', srcWh: 'GDS', destWh: 'KGS', qty: '' })
    }
  }

  // Handle Stock Adjustment submit
  const handleAdjustmentSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!adjustmentForm.productId || !adjustmentForm.qty || !adjustmentForm.cogs) return

    if (isSupabaseConnected) {
      try {
        const { data: wh } = await supabase.from('warehouses').select('id').eq('code', adjustmentForm.warehouseCode).single()
        if (!wh) throw new Error('Warehouse not found')

        const { error } = await supabase.from('stock_adjustments').insert({
          adjustment_no: `ADJ-${Date.now().toString().slice(-6)}`,
          product_id: adjustmentForm.productId,
          warehouse_id: wh.id,
          qty_adjusted: parseFloat(adjustmentForm.qty),
          cogs_unit: parseFloat(adjustmentForm.cogs),
          reason: adjustmentForm.reason
        })

        if (error) throw error
        alert('Penyesuaian stok berhasil disimpan!')
        setShowAdjustmentModal(false)
        setAdjustmentForm({ productId: '', warehouseCode: 'GDS', qty: '', cogs: '', reason: 'Rusak' })
      } catch (err: any) {
        alert(`Error penyesuaian stok: ${err.message}`)
      }
    } else {
      alert(`[Demo Mode] Penyesuaian stok berhasil! Kuantitas disesuaikan ${adjustmentForm.qty} unit dengan estimasi HPP Rp ${Number(adjustmentForm.cogs).toLocaleString('id-ID')}.`)
      setShowAdjustmentModal(false)
      setAdjustmentForm({ productId: '', warehouseCode: 'GDS', qty: '', cogs: '', reason: 'Rusak' })
    }
  }

  // Handle Stock Opname submit
  const handleOpnameSubmit = async (e: React.FormEvent) => {
    e.preventDefault()

    if (isSupabaseConnected) {
      try {
        const { data: wh } = await supabase.from('warehouses').select('id').eq('code', opnameForm.warehouseCode).single()
        if (!wh) throw new Error('Warehouse not found')

        // 1. Create Stock Opname Header
        const { data: opname, error: opnErr } = await supabase.from('stock_opnames').insert({
          opname_no: `OPN-${Date.now().toString().slice(-6)}`,
          warehouse_id: wh.id,
          notes: opnameForm.notes,
          status: 'APPROVED' // For simplify demo
        }).select('id').single()

        if (opnErr) throw opnErr

        // 2. Insert details and let DB process adjustment
        for (const item of opnameForm.items) {
          const physical = parseFloat(item.physicalQty) || 0
          const diff = item.systemQty - physical
          
          await supabase.from('stock_opname_details').insert({
            opname_id: opname.id,
            product_id: item.productId,
            system_qty: item.systemQty,
            physical_qty: physical,
            difference: diff
          })
        }

        alert('Audit Stock Opname berhasil disimpan dan stok otomatis disesuaikan!')
        setShowOpnameModal(false)
      } catch (err: any) {
        alert(`Error Opname: ${err.message}`)
      }
    } else {
      alert(`[Demo Mode] Stock Opname disahkan! Stok fisik diselaraskan ke sistem untuk Gudang ${opnameForm.warehouseCode}.`)
      setShowOpnameModal(false)
    }
  }

  // Handle Import CSV file submit
  const handleCSVImport = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!importingFile) return
    setIsImporting(true)
    setImportResult(null)

    const reader = new FileReader()
    reader.onload = async (event) => {
      const csvText = event.target?.result as string
      try {
        const response = await fetch('/api/products/import', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ csvText })
        })
        const result = await response.json()
        if (response.ok) {
          setImportResult(`Impor Sukses: Berhasil memasukkan ${result.successCount} item. Gagal: ${result.failureCount}`)
        } else {
          setImportResult(`Impor Gagal: ${result.error}`)
        }
      } catch (err: any) {
        setImportResult(`Error: ${err.message}`)
      } finally {
        setIsImporting(false)
      }
    }
    reader.readAsText(importingFile)
  }

  // Helper change source warehouse and adjust default quantities in opname
  const handleOpnameWarehouseChange = (whCode: string) => {
    setOpnameForm({
      ...opnameForm,
      warehouseCode: whCode,
      items: MOCK_STOCKS.map(s => {
        const systemQty = whCode === 'GDS' ? s.stockGDS : s.stockKGS
        return {
          productId: s.id,
          sku: s.sku,
          name: s.name,
          systemQty,
          physicalQty: systemQty.toString()
        }
      })
    })
  }

  const handleOpnameQtyChange = (idx: number, val: string) => {
    const updated = [...opnameForm.items]
    updated[idx].physicalQty = val
    setOpnameForm({ ...opnameForm, items: updated })
  }

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 flex flex-col font-sans">
      {/* HEADER */}
      <header className="border-b border-slate-800 bg-slate-900/60 backdrop-blur-md sticky top-0 z-40 px-8 py-5 flex items-center justify-between">
        <div>
          <h1 className="text-xl font-bold tracking-tight text-white flex items-center gap-2">
            KGS BACKOFFICE <span className="text-xs px-2 py-0.5 rounded-full bg-indigo-500/10 text-indigo-400 font-semibold border border-indigo-500/20">Dashboard</span>
          </h1>
          <p className="text-xs text-slate-400">Panel Manajemen Staf, Stok, dan Jurnal Finansial</p>
        </div>

        <div className="flex items-center gap-4">
          {/* Quick Actions */}
          <div className="flex gap-2">
            <button 
              onClick={() => setShowTransferModal(true)}
              className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-slate-900 border border-slate-800 hover:bg-slate-850 hover:text-white text-xs font-semibold transition-all text-indigo-400"
            >
              <ArrowLeftRight className="h-3.5 w-3.5" />
              Transfer Stok
            </button>
            <button 
              onClick={() => setShowAdjustmentModal(true)}
              className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-slate-900 border border-slate-800 hover:bg-slate-850 hover:text-white text-xs font-semibold transition-all text-amber-400"
            >
              <AlertTriangle className="h-3.5 w-3.5" />
              Koreksi / Adjust Stok
            </button>
            <button 
              onClick={() => {
                handleOpnameWarehouseChange('GDS');
                setShowOpnameModal(true);
              }}
              className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-slate-900 border border-slate-800 hover:bg-slate-850 hover:text-white text-xs font-semibold transition-all text-purple-400"
            >
              <ClipboardList className="h-3.5 w-3.5" />
              Stock Opname
            </button>
          </div>

          <div className={`text-sm rounded-lg px-4 py-2 border font-medium ${
            isSupabaseConnected 
              ? 'bg-emerald-500/10 text-emerald-400 border-emerald-500/20' 
              : 'bg-indigo-500/10 text-indigo-400 border-indigo-500/20'
          }`}>
            Koneksi Database: <span className="font-bold">{isSupabaseConnected ? 'Tersambung (Cloud)' : 'Mode Demo (Lokal)'}</span>
          </div>
        </div>
      </header>

      {/* SUB-HEADER / NAVIGATION TABS */}
      <div className="bg-slate-900/30 border-b border-slate-800/80 px-8 py-3 flex items-center gap-4 overflow-x-auto">
        {[
          { id: 'overview', label: 'Ringkasan', icon: TrendingUp },
          { id: 'stock', label: 'Kelola Stok', icon: Database },
          { id: 'events', label: 'Event Finansial (Ledger)', icon: ListTodo },
          { id: 'journal', label: 'Jurnal Umum (Double-Entry)', icon: FileText },
          { id: 'finance', label: 'Laporan Keuangan', icon: DollarSign },
        ].map(tab => {
          const Icon = tab.icon
          return (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id as any)}
              className={`flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium whitespace-nowrap transition-all ${
                activeTab === tab.id
                  ? 'bg-indigo-600 text-white shadow-lg shadow-indigo-600/15'
                  : 'text-slate-400 hover:text-slate-200 hover:bg-slate-900/60'
              }`}
            >
              <Icon className="h-4 w-4" />
              {tab.label}
            </button>
          )
        })}
      </div>

      {/* DASHBOARD CONTENT */}
      <main className="flex-1 p-8 overflow-y-auto space-y-8">
        
        {/* TAB 1: OVERVIEW */}
        {activeTab === 'overview' && (
          <div className="space-y-8">
            {/* Stats Grid */}
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
              {STATS.map(stat => (
                <div key={stat.name} className="bg-slate-900 border border-slate-800 rounded-2xl p-6 relative overflow-hidden">
                  <span className="text-xs font-semibold text-slate-450 uppercase tracking-wider">{stat.name}</span>
                  <div className="text-2xl font-bold text-white mt-2">{stat.value}</div>
                  
                  <div className="flex items-center gap-1.5 mt-3 text-xs">
                    {stat.type === 'up' && (
                      <span className="text-emerald-400 font-semibold flex items-center">
                        <ArrowUpRight className="h-3.5 w-3.5" /> {stat.change}
                      </span>
                    )}
                    {stat.type === 'down' && (
                      <span className="text-rose-400 font-semibold flex items-center">
                        <ArrowDownRight className="h-3.5 w-3.5" /> {stat.change}
                      </span>
                    )}
                    {stat.type === 'warn' && (
                      <span className="text-amber-400 font-semibold flex items-center gap-1">
                        <AlertTriangle className="h-3.5 w-3.5" /> {stat.change}
                      </span>
                    )}
                    <span className="text-slate-500">vs. {stat.note}</span>
                  </div>
                </div>
              ))}
            </div>

            {/* Quick Insights */}
            <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
              {/* Warehouse Stock summary */}
              <div className="bg-slate-900 border border-slate-800 rounded-2xl p-6">
                <h3 className="text-base font-bold text-white mb-4 flex items-center gap-2">
                  <Database className="h-5 w-5 text-indigo-400" />
                  Peta Stok Gudang Utama
                </h3>
                <div className="space-y-4">
                  <div className="flex justify-between items-center text-sm border-b border-slate-800 pb-2">
                    <span className="text-slate-400">Lokasi Warehouse</span>
                    <span className="font-semibold text-slate-200">Jumlah SKU</span>
                  </div>
                  <div className="flex justify-between items-center text-sm">
                    <span>KGS Toko (Pasar Raya)</span>
                    <span className="font-bold text-indigo-400">8 Barang Aktif</span>
                  </div>
                  <div className="flex justify-between items-center text-sm">
                    <span>GDS Gudang Utama</span>
                    <span className="font-bold text-purple-400">7 Barang Aktif</span>
                  </div>
                </div>
              </div>

              {/* Accounting status */}
              <div className="bg-slate-900 border border-slate-800 rounded-2xl p-6">
                <h3 className="text-base font-bold text-white mb-4 flex items-center gap-2">
                  <Layers className="h-5 w-5 text-indigo-400" />
                  Status Rekonsiliasi Pembukuan
                </h3>
                <div className="space-y-4">
                  <div className="flex justify-between items-center text-sm">
                    <span className="text-slate-400">Event Ledger Status</span>
                    <span className="px-2.5 py-0.5 rounded-full bg-emerald-500/10 text-emerald-400 border border-emerald-500/20 text-xs font-semibold">MATCH (100%)</span>
                  </div>
                  <div className="flex justify-between items-center text-sm">
                    <span className="text-slate-400">Persediaan Akuntansi</span>
                    <span className="font-bold text-slate-200">Rp 120.450.000</span>
                  </div>
                  <div className="flex justify-between items-center text-sm">
                    <span className="text-slate-400">HPP Terakumulasi</span>
                    <span className="font-bold text-slate-200">Rp 28.180.000</span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        )}

        {/* TAB 2: STOCKS */}
        {activeTab === 'stock' && (
          <div className="space-y-6">
            {/* Stock subnavigation */}
            <div className="flex justify-between items-center bg-slate-900/40 border border-slate-800 rounded-xl p-2 max-w-xl">
              <button
                onClick={() => setStockSubTab('levels')}
                className={`flex-1 py-1.5 text-xs font-semibold rounded-lg transition-all ${
                  stockSubTab === 'levels' ? 'bg-indigo-600 text-white shadow-md' : 'text-slate-400 hover:text-slate-200'
                }`}
              >
                Katalog & Level Stok
              </button>
              <button
                onClick={() => setStockSubTab('movements')}
                className={`flex-1 py-1.5 text-xs font-semibold rounded-lg transition-all ${
                  stockSubTab === 'movements' ? 'bg-indigo-600 text-white shadow-md' : 'text-slate-400 hover:text-slate-200'
                }`}
              >
                Kartu Pergerakan Stok
              </button>
              <button
                onClick={() => setStockSubTab('opname')}
                className={`flex-1 py-1.5 text-xs font-semibold rounded-lg transition-all ${
                  stockSubTab === 'opname' ? 'bg-indigo-600 text-white shadow-md' : 'text-slate-400 hover:text-slate-200'
                }`}
              >
                Laporan Stock Opname
              </button>
              <button
                onClick={() => setStockSubTab('orders')}
                className={`flex-1 py-1.5 text-xs font-semibold rounded-lg transition-all ${
                  stockSubTab === 'orders' ? 'bg-indigo-600 text-white shadow-md' : 'text-slate-400 hover:text-slate-200'
                }`}
              >
                Konfirmasi Order (PO)
              </button>
            </div>

            {/* SUBTAB 2.1: STOCKS LEVELS */}
            {stockSubTab === 'levels' && (
              <div className="bg-slate-900 border border-slate-800 rounded-2xl p-6">
                <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-6">
                  <div>
                    <h3 className="text-base font-bold text-white">Manajemen Stok Multi-Warehouse</h3>
                    <p className="text-xs text-slate-450 mt-1">Status stok aktual antara Toko KGS (Kasir) dan Gudang Penyimpanan GDS</p>
                  </div>

                  <div className="flex gap-2">
                    {/* CSV Import Button */}
                    <button
                      onClick={() => setShowImportModal(true)}
                      className="flex items-center gap-1.5 px-3.5 py-2 rounded-lg bg-indigo-600 hover:bg-indigo-500 text-xs font-bold text-white transition-all shadow-md shadow-indigo-600/10"
                    >
                      <Upload className="h-4 w-4" />
                      Impor CSV Produk
                    </button>
                  </div>
                </div>

                {/* Search Bar */}
                <div className="relative mb-6">
                  <Search className="absolute left-3.5 top-1/2 -translate-y-1/2 h-4 w-4 text-slate-500" />
                  <input
                    type="text"
                    placeholder="Cari SKU atau nama barang..."
                    value={searchQuery}
                    onChange={e => setSearchQuery(e.target.value)}
                    className="w-full bg-slate-950 border border-slate-850 rounded-xl py-2.5 pl-10 pr-4 text-sm text-slate-100 placeholder-slate-500 focus:outline-none focus:border-indigo-500"
                  />
                </div>

                <div className="overflow-x-auto">
                  <table className="w-full text-left text-sm text-slate-300">
                    <thead className="bg-slate-950 text-slate-400 font-semibold border-b border-slate-800">
                      <tr>
                        <th className="p-4">SKU</th>
                        <th className="p-4">Nama Barang</th>
                        <th className="p-4">Kategori</th>
                        <th className="p-4 text-right">Stok Toko KGS</th>
                        <th className="p-4 text-right">Stok Gudang GDS</th>
                        <th className="p-4 text-right">Total Stok</th>
                        <th className="p-4 text-center">Status</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-850">
                      {MOCK_STOCKS.filter(stock => 
                        stock.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
                        stock.sku.toLowerCase().includes(searchQuery.toLowerCase())
                      ).map(stock => {
                        const totalStock = stock.stockKGS + stock.stockGDS
                        const isLow = totalStock < stock.minStock
                        return (
                          <tr key={stock.id} className="hover:bg-slate-900/60 transition-colors">
                            <td className="p-4 font-mono text-xs">{stock.sku}</td>
                            <td className="p-4 font-medium text-white">{stock.name}</td>
                            <td className="p-4 text-slate-450">{stock.category}</td>
                            <td className="p-4 text-right font-mono">{stock.stockKGS} {stock.uom}</td>
                            <td className="p-4 text-right font-mono">{stock.stockGDS} {stock.uom}</td>
                            <td className="p-4 text-right font-mono font-bold text-indigo-400">{totalStock} {stock.uom}</td>
                            <td className="p-4 text-center">
                              {isLow ? (
                                <span className="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full bg-rose-500/10 text-rose-400 border border-rose-500/20 text-xs font-medium">
                                  Stok Rendah
                                </span>
                              ) : (
                                <span className="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full bg-emerald-500/10 text-emerald-400 border border-emerald-500/20 text-xs font-medium">
                                  Cukup
                                </span>
                              )}
                            </td>
                          </tr>
                        )
                      })}
                    </tbody>
                  </table>
                </div>
              </div>
            )}

            {/* SUBTAB 2.2: STOCKS MOVEMENTS (KARTU STOK) */}
            {stockSubTab === 'movements' && (
              <div className="bg-slate-900 border border-slate-800 rounded-2xl p-6 space-y-6">
                <div>
                  <h3 className="text-base font-bold text-white">Laporan Histori Kartu Stok (Stock Card)</h3>
                  <p className="text-xs text-slate-450 mt-1">Laporan terperinci mengenai setiap mutasi masuk dan keluar barang berdasarkan penjualan POS, pembelian, maupun adjustment.</p>
                </div>

                <div className="overflow-x-auto">
                  <table className="w-full text-left text-sm text-slate-300">
                    <thead className="bg-slate-950 text-slate-400 font-semibold border-b border-slate-800">
                      <tr>
                        <th className="p-4">Tanggal</th>
                        <th className="p-4">SKU</th>
                        <th className="p-4">Nama Produk</th>
                        <th className="p-4">Gudang</th>
                        <th className="p-4 text-right">Mutasi (Qty)</th>
                        <th className="p-4">Tipe Mutasi</th>
                        <th className="p-4">No Referensi</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-850 font-mono text-xs">
                      {MOCK_MOVEMENTS.map(mov => (
                        <tr key={mov.id} className="hover:bg-slate-900/60 transition-colors">
                          <td className="p-4 text-slate-450">{mov.date}</td>
                          <td className="p-4 text-slate-205">{mov.sku}</td>
                          <td className="p-4 text-white font-sans">{mov.name}</td>
                          <td className="p-4 text-slate-300 font-sans">{mov.wh}</td>
                          <td className={`p-4 text-right font-bold ${mov.change > 0 ? 'text-emerald-450' : 'text-rose-400'}`}>
                            {mov.change > 0 ? `+${mov.change}` : mov.change}
                          </td>
                          <td className="p-4">
                            <span className={`inline-flex px-2 py-0.5 rounded text-[10px] font-bold ${
                              mov.type === 'SALE' ? 'bg-indigo-500/10 text-indigo-400 border border-indigo-500/20' :
                              mov.type === 'PURCHASE' ? 'bg-emerald-500/10 text-emerald-400 border border-emerald-500/20' :
                              mov.type === 'TRANSFER_IN' || mov.type === 'TRANSFER_OUT' ? 'bg-purple-500/10 text-purple-400 border border-purple-500/20' :
                              'bg-amber-500/10 text-amber-400 border border-amber-500/20'
                            }`}>
                              {mov.type}
                            </span>
                          </td>
                          <td className="p-4 text-slate-450">{mov.ref}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            )}

            {/* SUBTAB 2.3: STOCK OPNAME REPORTS */}
            {stockSubTab === 'opname' && (
              <div className="bg-slate-900 border border-slate-800 rounded-2xl p-6 space-y-6">
                <div>
                  <h3 className="text-base font-bold text-white">Histori Laporan Stock Opname (SO)</h3>
                  <p className="text-xs text-slate-450 mt-1">Daftar rekonsiliasi audit hitung fisik persediaan barang secara periodik.</p>
                </div>

                <div className="overflow-x-auto">
                  <table className="w-full text-left text-sm text-slate-300">
                    <thead className="bg-slate-950 text-slate-400 font-semibold border-b border-slate-800">
                      <tr>
                        <th className="p-4">No Opname</th>
                        <th className="p-4">Gudang</th>
                        <th className="p-4">Tanggal Audit</th>
                        <th className="p-4">Keterangan</th>
                        <th className="p-4">Auditor</th>
                        <th className="p-4 text-center">Status</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-850">
                      {MOCK_OPNAMES.map(opn => (
                        <tr key={opn.id} className="hover:bg-slate-900/60 transition-colors">
                          <td className="p-4 font-mono text-xs text-indigo-400 font-bold">{opn.no}</td>
                          <td className="p-4 font-medium text-slate-200">{opn.wh}</td>
                          <td className="p-4 text-xs text-slate-450 font-mono">{opn.date}</td>
                          <td className="p-4 text-slate-300">{opn.notes}</td>
                          <td className="p-4 text-slate-300">{opn.auditor}</td>
                          <td className="p-4 text-center">
                            {opn.status === 'APPROVED' ? (
                              <span className="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full bg-emerald-500/10 text-emerald-400 border border-emerald-500/20 text-xs font-semibold">
                                APPROVED
                              </span>
                            ) : (
                              <span className="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full bg-slate-800 text-slate-400 border border-slate-700 text-xs font-semibold">
                                DRAFT
                              </span>
                            )}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            )}

            {/* SUBTAB 2.4: PURCHASE ORDERS (PO) CONFIRMATION */}
            {stockSubTab === 'orders' && (
              <div className="bg-slate-900 border border-slate-800 rounded-2xl p-6 space-y-6">
                <div>
                  <h3 className="text-base font-bold text-white">Konfirmasi Penerimaan Stok (Purchase Orders)</h3>
                  <p className="text-xs text-slate-450 mt-1">Daftar order stock/pembelian barang dari kasir yang memerlukan konfirmasi penerimaan fisik untuk masuk ke gudang (batch FIFO).</p>
                </div>

                <div className="overflow-x-auto">
                  <table className="w-full text-left text-sm text-slate-300">
                    <thead className="bg-slate-950 text-slate-400 font-semibold border-b border-slate-800">
                      <tr>
                        <th className="p-4">No PO / Purchase</th>
                        <th className="p-4">Supplier</th>
                        <th className="p-4">Tanggal Order</th>
                        <th className="p-4">Gudang Tujuan</th>
                        <th className="p-4 text-right">Total Nilai</th>
                        <th className="p-4 text-center">Status</th>
                        <th className="p-4 text-center">Aksi</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-850">
                      {purchaseOrders.length === 0 ? (
                        <tr>
                          <td colSpan={7} className="p-8 text-center text-slate-500 text-xs">
                            Tidak ada order pembelian (PO) terdaftar.
                          </td>
                        </tr>
                      ) : (
                        purchaseOrders.map(po => (
                          <tr key={po.id} className="hover:bg-slate-900/60 transition-colors">
                            <td className="p-4 font-mono text-xs text-indigo-400 font-bold">{po.purchase_no}</td>
                            <td className="p-4 font-medium text-slate-200">{po.supplier_name}</td>
                            <td className="p-4 text-xs text-slate-450 font-mono">
                              {new Date(po.transaction_date).toLocaleDateString('id-ID', {
                                day: 'numeric',
                                month: 'short',
                                year: 'numeric',
                                hour: '2-digit',
                                minute: '2-digit'
                              })}
                            </td>
                            <td className="p-4 text-slate-300">{po.warehouse_name || 'Gudang'}</td>
                            <td className="p-4 text-right font-mono text-slate-100 font-bold">
                              Rp {Number(po.grand_total).toLocaleString('id-ID')}
                            </td>
                            <td className="p-4 text-center">
                              {po.status === 'CONFIRMED' ? (
                                <span className="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full bg-emerald-500/10 text-emerald-400 border border-emerald-500/20 text-xs font-semibold">
                                  DITERIMA
                                </span>
                              ) : (
                                <span className="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full bg-amber-500/10 text-amber-400 border border-amber-500/20 text-xs font-semibold">
                                  PENDING
                                </span>
                              )}
                            </td>
                            <td className="p-4 text-center">
                              {po.status === 'PENDING' ? (
                                <button
                                  onClick={() => handleConfirmPurchase(po.id)}
                                  className="px-3 py-1 rounded bg-indigo-650 hover:bg-indigo-500 text-white text-xs font-semibold transition-colors"
                                >
                                  Konfirmasi Terima
                                </button>
                              ) : (
                                <span className="text-slate-500 text-xs">-</span>
                              )}
                            </td>
                          </tr>
                        ))
                      )}
                    </tbody>
                  </table>
                </div>
              </div>
            )}
          </div>
        )}

        {/* TAB: CUSTOMERS & PRICELISTS */}
        {activeTab === 'customer' && (
          <div className="space-y-6">
            {/* Customer subnavigation */}
            <div className="flex justify-between items-center bg-slate-900/40 border border-slate-800 rounded-xl p-2 max-w-md">
              <button
                onClick={() => setCustomerSubTab('list')}
                className={`flex-1 py-1.5 text-xs font-semibold rounded-lg transition-all ${
                  customerSubTab === 'list' ? 'bg-indigo-600 text-white shadow-md' : 'text-slate-400 hover:text-slate-200'
                }`}
              >
                Daftar Pelanggan
              </button>
              <button
                onClick={() => setCustomerSubTab('pricelist')}
                className={`flex-1 py-1.5 text-xs font-semibold rounded-lg transition-all ${
                  customerSubTab === 'pricelist' ? 'bg-indigo-600 text-white shadow-md' : 'text-slate-400 hover:text-slate-200'
                }`}
              >
                Pricelist Khusus
              </button>
            </div>

            {/* SUBTAB: CUSTOMER LIST */}
            {customerSubTab === 'list' && (
              <div className="bg-slate-900 border border-slate-800 rounded-2xl p-6 space-y-6">
                <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
                  <div>
                    <h3 className="text-base font-bold text-white">Manajemen Database Pelanggan</h3>
                    <p className="text-xs text-slate-450 mt-1">Kelola data pelanggan KGS, riwayat balance deposit, dan info kontak.</p>
                  </div>

                  <div className="flex gap-2">
                    <button
                      onClick={() => setShowCustomerModal(true)}
                      className="flex items-center gap-1.5 px-3.5 py-2 rounded-lg bg-indigo-650 hover:bg-indigo-500 text-xs font-bold text-white transition-all shadow-md"
                    >
                      <PlusCircle className="h-4 w-4" />
                      Tambah Pelanggan
                    </button>
                    <button
                      onClick={() => setShowTopupModal(true)}
                      className="flex items-center gap-1.5 px-3.5 py-2 rounded-lg bg-slate-800 hover:bg-slate-750 text-xs font-bold text-slate-200 border border-slate-750 transition-all shadow-md"
                    >
                      <HandCoins className="h-4 w-4" />
                      Top Up Saldo
                    </button>
                  </div>
                </div>

                <div className="overflow-x-auto">
                  <table className="w-full text-left text-sm text-slate-300">
                    <thead className="bg-slate-950 text-slate-400 font-semibold border-b border-slate-800">
                      <tr>
                        <th className="p-4">Kode</th>
                        <th className="p-4">Nama Pelanggan</th>
                        <th className="p-4">Email</th>
                        <th className="p-4">Telepon</th>
                        <th className="p-4 text-right">Saldo Deposit</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-850">
                      {customers.map(cust => (
                        <tr key={cust.id} className="hover:bg-slate-900/60 transition-colors">
                          <td className="p-4 font-mono text-xs text-slate-400">{cust.code}</td>
                          <td className="p-4 font-medium text-slate-200">{cust.name}</td>
                          <td className="p-4 text-xs text-slate-450">{cust.email}</td>
                          <td className="p-4 text-xs text-slate-450">{cust.phone}</td>
                          <td className="p-4 text-right font-mono text-emerald-400 font-bold">
                            Rp {cust.balance.toLocaleString('id-ID')}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            )}

            {/* SUBTAB: CUSTOM PRICELIST */}
            {customerSubTab === 'pricelist' && (
              <div className="bg-slate-900 border border-slate-800 rounded-2xl p-6 space-y-6">
                <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
                  <div>
                    <h3 className="text-base font-bold text-white">Daftar Harga Kustom (Pricelist)</h3>
                    <p className="text-xs text-slate-450 mt-1">Daftar harga jual khusus yang diatur per pelanggan untuk produk tertentu.</p>
                  </div>

                  <div>
                    <button
                      onClick={() => setShowPricelistModal(true)}
                      className="flex items-center gap-1.5 px-3.5 py-2 rounded-lg bg-indigo-655 hover:bg-indigo-500 text-xs font-bold text-white transition-all shadow-md"
                    >
                      <PlusCircle className="h-4 w-4" />
                      Set Harga Khusus
                    </button>
                  </div>
                </div>

                <div className="overflow-x-auto">
                  <table className="w-full text-left text-sm text-slate-300">
                    <thead className="bg-slate-950 text-slate-400 font-semibold border-b border-slate-800">
                      <tr>
                        <th className="p-4">Nama Pelanggan</th>
                        <th className="p-4">Nama Produk</th>
                        <th className="p-4 text-right">Harga Khusus</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-850">
                      {pricelists.length === 0 ? (
                        <tr>
                          <td colSpan={3} className="p-8 text-center text-slate-500 text-xs">
                            Belum ada harga khusus yang diatur.
                          </td>
                        </tr>
                      ) : (
                        pricelists.map(pl => (
                          <tr key={pl.id} className="hover:bg-slate-900/60 transition-colors">
                            <td className="p-4 font-medium text-slate-200">{pl.customerName}</td>
                            <td className="p-4 text-slate-300">{pl.productName}</td>
                            <td className="p-4 text-right font-mono text-indigo-400 font-bold">
                              Rp {pl.price.toLocaleString('id-ID')}
                            </td>
                          </tr>
                        ))
                      )}
                    </tbody>
                  </table>
                </div>
              </div>
            )}
          </div>
        )}

        {/* TAB 3: FINANCIAL EVENTS (LEDGER) */}
        {activeTab === 'events' && (
          <div className="bg-slate-900 border border-slate-800 rounded-2xl p-6 space-y-6">
            <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
              <div>
                <h3 className="text-base font-bold text-white">Event Queue Ledger (financial_events)</h3>
                <p className="text-xs text-slate-450 mt-1">Antrean event transaksi dari POS offline/online untuk diproses oleh background worker menjadi Double-Entry Journal.</p>
              </div>

              {/* Trigger Worker Button */}
              <button
                onClick={handleTriggerWorker}
                disabled={isProcessingWorker}
                className="flex items-center gap-2 px-4 py-2.5 rounded-lg bg-indigo-650 hover:bg-indigo-500 disabled:bg-slate-800 disabled:text-slate-500 font-semibold text-xs text-white transition-all shadow-md shadow-indigo-600/25"
              >
                <RefreshCw className={`h-4 w-4 ${isProcessingWorker ? 'animate-spin' : ''}`} />
                {isProcessingWorker ? 'Memproses Event...' : 'Picu Antrean Worker'}
              </button>
            </div>

            {workerResult && (
              <div className="p-4 rounded-xl border border-indigo-500/20 bg-indigo-500/5 text-xs text-indigo-300 font-mono flex items-center gap-2">
                <AlertCircle className="h-4 w-4" />
                <span>{workerResult}</span>
              </div>
            )}

            <div className="overflow-x-auto">
              <table className="w-full text-left text-sm text-slate-300">
                <thead className="bg-slate-950 text-slate-400 font-semibold border-b border-slate-800">
                  <tr>
                    <th className="p-4">Kode Event</th>
                    <th className="p-4">Tipe Event</th>
                    <th className="p-4">Sumber ID</th>
                    <th className="p-4">Tanggal Event</th>
                    <th className="p-4 text-right">Nilai Event</th>
                    <th className="p-4 text-center">Status</th>
                    <th className="p-4">Pesan Error / Log</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-850">
                  {MOCK_EVENTS.map(event => (
                    <tr key={event.id} className="hover:bg-slate-900/60 transition-colors">
                      <td className="p-4 font-mono text-xs text-indigo-400 font-bold">{event.code}</td>
                      <td className="p-4 font-mono text-xs">{event.type}</td>
                      <td className="p-4 font-mono text-xs text-slate-450">{event.source} ({event.rootSales})</td>
                      <td className="p-4 text-xs text-slate-450">{event.date}</td>
                      <td className="p-4 text-right font-mono">Rp {event.amount.toLocaleString('id-ID')}</td>
                      <td className="p-4 text-center">
                        {event.status === 'DONE' && (
                          <span className="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full bg-emerald-500/10 text-emerald-400 border border-emerald-500/20 text-xs font-semibold">
                            <CheckCircle2 className="h-3.5 w-3.5" /> DONE
                          </span>
                        )}
                        {event.status === 'READY' && (
                          <span className="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full bg-indigo-500/10 text-indigo-400 border border-indigo-500/20 text-xs font-semibold animate-pulse">
                            READY
                          </span>
                        )}
                        {event.status === 'ERROR' && (
                          <span className="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full bg-rose-500/10 text-rose-400 border border-rose-500/20 text-xs font-semibold">
                            <XCircle className="h-3.5 w-3.5" /> ERROR
                          </span>
                        )}
                      </td>
                      <td className="p-4 text-xs text-rose-400/90 font-mono max-w-xs truncate">
                        {event.error || '-'}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}

        {/* TAB 4: GENERAL LEDGER (JOURNAL ENTRIES) */}
        {activeTab === 'journal' && (
          <div className="bg-slate-900 border border-slate-800 rounded-2xl p-6">
            <div className="flex items-center justify-between mb-6">
              <div>
                <h3 className="text-base font-bold text-white">Jurnal Umum (Double-Entry Ledger)</h3>
                <p className="text-xs text-slate-450 mt-1">Daftar baris jurnal yang dihasilkan secara otomatis dari event ledger menggunakan prinsip Debit = Kredit.</p>
              </div>

              <div className="bg-slate-950 px-4 py-2 rounded-lg border border-slate-800 flex items-center gap-2">
                <CheckCircle2 className="h-4 w-4 text-emerald-400" />
                <span className="text-xs text-slate-300 font-semibold">Balance Check: <span className="text-emerald-400">OK (Selisih Rp 0)</span></span>
              </div>
            </div>

            <div className="overflow-x-auto">
              <table className="w-full text-left text-sm text-slate-300">
                <thead className="bg-slate-950 text-slate-400 font-semibold border-b border-slate-800">
                  <tr>
                    <th className="p-4">No Jurnal</th>
                    <th className="p-4">Ref Event</th>
                    <th className="p-4">Kode COA</th>
                    <th className="p-4">Nama Akun (COA)</th>
                    <th className="p-4 text-right">Debit</th>
                    <th className="p-4 text-right">Kredit</th>
                    <th className="p-4">Keterangan / Memo</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-850 font-mono text-xs">
                  {MOCK_JOURNAL.map(jnl => (
                    <tr key={jnl.id} className="hover:bg-slate-900/60 transition-colors">
                      <td className="p-4 text-slate-300">{jnl.jnlNo}</td>
                      <td className="p-4 text-slate-450">{jnl.eventCode}</td>
                      <td className="p-4 text-indigo-400 font-bold">{jnl.coa}</td>
                      <td className="p-4 text-slate-200">{jnl.coaName}</td>
                      <td className="p-4 text-right text-emerald-400">
                        {jnl.debit > 0 ? `Rp ${jnl.debit.toLocaleString('id-ID')}` : '-'}
                      </td>
                      <td className="p-4 text-right text-purple-400">
                        {jnl.kredit > 0 ? `Rp ${jnl.kredit.toLocaleString('id-ID')}` : '-'}
                      </td>
                      <td className="p-4 text-slate-450">{jnl.note}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}

        {/* TAB 5: FINANCIAL REPORTS (LABA RUGI / NERACA) */}
        {activeTab === 'finance' && (
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
            {/* Laporan Laba Rugi */}
            <div className="bg-slate-900 border border-slate-800 rounded-2xl p-6">
              <div className="flex justify-between items-center mb-6">
                <div>
                  <h3 className="text-base font-bold text-white flex items-center gap-2">
                    <FileText className="h-5 w-5 text-indigo-400" />
                    Laporan Laba / Rugi (P&L)
                  </h3>
                  <p className="text-xs text-slate-400 mt-1">Periode: Berjalan 13 Juli 2026</p>
                </div>
                <button className="p-2 rounded-lg bg-slate-950 border border-slate-800 hover:bg-slate-900 text-slate-400 hover:text-white transition-colors">
                  <Printer className="h-4 w-4" />
                </button>
              </div>

              <div className="space-y-4">
                <div className="flex justify-between text-sm font-semibold border-b border-slate-800 pb-2">
                  <span className="text-slate-200">Keterangan</span>
                  <span className="text-slate-200">Jumlah</span>
                </div>

                {/* Pendapatan */}
                <div className="space-y-1">
                  <div className="flex justify-between text-sm">
                    <span className="font-semibold text-slate-300">Pendapatan Penjualan</span>
                    <span className="font-mono text-emerald-400">Rp 45.280.000</span>
                  </div>
                  <div className="flex justify-between text-xs text-slate-550 pl-4">
                    <span>Penjualan Barang Dagang (4101-01)</span>
                    <span className="font-mono">Rp 45.280.000</span>
                  </div>
                </div>

                {/* Harga Pokok Penjualan (HPP) */}
                <div className="space-y-1">
                  <div className="flex justify-between text-sm">
                    <span className="font-semibold text-slate-300">Harga Pokok Penjualan (HPP)</span>
                    <span className="font-mono text-purple-400">(Rp 28.180.000)</span>
                  </div>
                  <div className="flex justify-between text-xs text-slate-550 pl-4">
                    <span>HPP Unit Terjual (5101-01)</span>
                    <span className="font-mono">Rp 28.180.000</span>
                  </div>
                </div>

                {/* Laba Kotor */}
                <div className="flex justify-between text-sm font-bold border-t border-slate-800 pt-2 text-indigo-400">
                  <span>LABA KOTOR</span>
                  <span className="font-mono">Rp 17.100.000</span>
                </div>

                {/* Beban Operasional */}
                <div className="space-y-1 pt-2">
                  <div className="flex justify-between text-sm">
                    <span className="font-semibold text-slate-300">Beban-Beban Operasional</span>
                    <span className="font-mono text-rose-400">(Rp 2.450.000)</span>
                  </div>
                  <div className="flex justify-between text-xs text-slate-550 pl-4">
                    <span>Beban Uang Makan Staf (6101-02)</span>
                    <span className="font-mono">Rp 950.000</span>
                  </div>
                  <div className="flex justify-between text-xs text-slate-550 pl-4">
                    <span>Beban Bensin Operasional (6101-01)</span>
                    <span className="font-mono">Rp 1.500.000</span>
                  </div>
                </div>

                {/* Laba Bersih */}
                <div className="flex justify-between text-base font-extrabold border-t-2 border-double border-slate-800 pt-4 text-emerald-400 bg-emerald-500/5 p-3 rounded-xl border border-emerald-500/10">
                  <span>LABA BERSIH OPERASIONAL</span>
                  <span className="font-mono">Rp 14.650.000</span>
                </div>
              </div>
            </div>

            {/* Neraca Keuangan */}
            <div className="bg-slate-900 border border-slate-800 rounded-2xl p-6">
              <div className="flex justify-between items-center mb-6">
                <div>
                  <h3 className="text-base font-bold text-white flex items-center gap-2">
                    <Layers className="h-5 w-5 text-indigo-400" />
                    Laporan Neraca Ringkas
                  </h3>
                  <p className="text-xs text-slate-400 mt-1">Periode: Per 13 Juli 2026</p>
                </div>
                <button className="p-2 rounded-lg bg-slate-950 border border-slate-800 hover:bg-slate-900 text-slate-400 hover:text-white transition-colors">
                  <Printer className="h-4 w-4" />
                </button>
              </div>

              <div className="grid grid-cols-2 gap-6 text-xs font-mono text-slate-300 font-semibold">
                {/* AKTIVA (ASSETS) */}
                <div className="space-y-4">
                  <h4 className="font-bold text-sm text-indigo-400 border-b border-slate-800 pb-2">AKTIVA / ASSET</h4>
                  
                  {/* Kas & Setara */}
                  <div className="space-y-1">
                    <span className="font-bold text-slate-200">Kas & Bank</span>
                    <div className="flex justify-between text-[11px] pl-2">
                      <span>Kas Kasir KGS</span>
                      <span>Rp 12.830.000</span>
                    </div>
                    <div className="flex justify-between text-[11px] pl-2">
                      <span>Bank BCA Mandiri</span>
                      <span>Rp 30.000.000</span>
                    </div>
                  </div>

                  {/* Persediaan */}
                  <div className="space-y-1">
                    <span className="font-bold text-slate-200">Persediaan</span>
                    <div className="flex justify-between text-[11px] pl-2">
                      <span>Persediaan Barang</span>
                      <span>Rp 120.450.000</span>
                    </div>
                  </div>

                  {/* Piutang */}
                  <div className="space-y-1">
                    <span className="font-bold text-slate-200">Piutang Dagang</span>
                    <div className="flex justify-between text-[11px] pl-2">
                      <span>Piutang POS (Tempo)</span>
                      <span>Rp 8.500.000</span>
                    </div>
                  </div>

                  <div className="flex justify-between text-xs font-bold text-white border-t border-slate-800 pt-2">
                    <span>TOTAL AKTIVA</span>
                    <span className="text-emerald-400">Rp 171.780.000</span>
                  </div>
                </div>

                {/* PASIVA (LIABILITIES & EQUITIES) */}
                <div className="space-y-4">
                  <h4 className="font-bold text-sm text-purple-400 border-b border-slate-800 pb-2">PASIVA / PASIF</h4>
                  
                  {/* Kewajiban */}
                  <div className="space-y-1">
                    <span className="font-bold text-slate-200">Kewajiban Jangka Pendek</span>
                    <div className="flex justify-between text-[11px] pl-2">
                      <span>Titipan Deposito Pelanggan</span>
                      <span>Rp 3.500.000</span>
                    </div>
                  </div>

                  {/* Ekuitas */}
                  <div className="space-y-1">
                    <span className="font-bold text-slate-200">Ekuitas / Modal</span>
                    <div className="flex justify-between text-[11px] pl-2">
                      <span>Modal Pemilik</span>
                      <span>Rp 153.630.000</span>
                    </div>
                    <div className="flex justify-between text-[11px] pl-2">
                      <span>Laba Ditahan</span>
                      <span>Rp 14.650.000</span>
                    </div>
                  </div>

                  <div className="flex justify-between text-xs font-bold text-white border-t border-slate-800 pt-2">
                    <span>TOTAL PASIVA</span>
                    <span className="text-purple-400">Rp 171.780.000</span>
                  </div>
                </div>
              </div>

              {/* Balance Check indicator */}
              <div className="mt-6 p-3 rounded-xl bg-emerald-500/5 border border-emerald-500/10 flex justify-between items-center text-xs text-emerald-400">
                <span className="font-semibold flex items-center gap-1.5"><CheckCircle2 className="h-4 w-4" /> Neraca Seimbang</span>
                <span className="font-mono">Selisih: Rp 0</span>
              </div>
            </div>
          </div>
        )}
      </main>

      {/* MODAL 1: STOCK TRANSFER */}
      {showTransferModal && (
        <div className="fixed inset-0 z-50 bg-slate-950/80 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-slate-900 border border-slate-800 rounded-2xl max-w-md w-full p-6 shadow-2xl relative">
            <h3 className="text-lg font-bold text-white mb-2 flex items-center gap-2">
              <ArrowLeftRight className="h-5 w-5 text-indigo-400" />
              Form Pemindahan Stok (Stock Transfer)
            </h3>
            <p className="text-xs text-slate-450 mb-6">Pindahkan barang antar lokasi Toko KGS dan Gudang Utama GDS.</p>

            <form onSubmit={handleStockTransferSubmit} className="space-y-4 text-sm text-slate-200">
              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-400">Pilih Produk</label>
                <select
                  value={transferForm.productId}
                  onChange={e => setTransferForm({ ...transferForm, productId: e.target.value })}
                  className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-200 focus:outline-none focus:border-indigo-500"
                  required
                >
                  <option value="">-- Pilih Barang --</option>
                  {MOCK_STOCKS.map(item => (
                    <option key={item.id} value={item.id}>{item.sku} - {item.name}</option>
                  ))}
                </select>
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-400">Dari Gudang</label>
                  <select
                    value={transferForm.srcWh}
                    onChange={e => setTransferForm({ ...transferForm, srcWh: e.target.value })}
                    className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-200 focus:outline-none"
                  >
                    <option value="GDS">GDS (Gudang Utama)</option>
                    <option value="KGS">KGS (Toko Kasir)</option>
                  </select>
                </div>

                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-400">Ke Gudang</label>
                  <select
                    value={transferForm.destWh}
                    onChange={e => setTransferForm({ ...transferForm, destWh: e.target.value })}
                    className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-200 focus:outline-none"
                  >
                    <option value="KGS">KGS (Toko Kasir)</option>
                    <option value="GDS">GDS (Gudang Utama)</option>
                  </select>
                </div>
              </div>

              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-400">Jumlah Transfer</label>
                <input
                  type="number"
                  placeholder="0"
                  value={transferForm.qty}
                  onChange={e => setTransferForm({ ...transferForm, qty: e.target.value })}
                  className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-100 font-mono placeholder-slate-600 focus:outline-none focus:border-indigo-500"
                  required
                  min="1"
                />
              </div>

              <div className="mt-6 flex gap-3 pt-2">
                <button
                  type="button"
                  onClick={() => setShowTransferModal(false)}
                  className="flex-1 py-2.5 rounded-lg border border-slate-800 hover:bg-slate-800 text-xs font-semibold text-slate-300 transition-colors"
                >
                  Batal
                </button>
                <button
                  type="submit"
                  className="flex-1 py-2.5 rounded-lg bg-indigo-650 hover:bg-indigo-500 text-xs font-semibold text-white transition-colors"
                >
                  Eksekusi Transfer
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* MODAL 2: IMPORT CSV */}
      {showImportModal && (
        <div className="fixed inset-0 z-50 bg-slate-950/80 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-slate-900 border border-slate-800 rounded-2xl max-w-md w-full p-6 shadow-2xl relative">
            <h3 className="text-lg font-bold text-white mb-2 flex items-center gap-2">
              <Upload className="h-5 w-5 text-indigo-400" />
              Impor Master Produk & Stok
            </h3>
            <p className="text-xs text-slate-450 mb-6">
              Mempersiapkan inisiasi awal produk secara massal menggunakan format CSV standar.
            </p>

            <div className="mb-6 bg-slate-950 p-4 rounded-xl border border-slate-850 flex items-center justify-between text-xs">
              <div>
                <div className="font-bold text-slate-200">Unduh Template CSV</div>
                <div className="text-slate-500 mt-0.5">Berisi header standar bahasa Inggris</div>
              </div>
              <a
                href="/import_template.csv"
                download
                className="flex items-center gap-1 px-3 py-1.5 rounded-lg bg-indigo-600/10 text-indigo-400 border border-indigo-500/20 hover:bg-indigo-500/25 transition-all text-[11px] font-semibold"
              >
                <Download className="h-3.5 w-3.5" />
                Template.csv
              </a>
            </div>

            <form onSubmit={handleCSVImport} className="space-y-4 text-sm text-slate-200">
              <div className="space-y-2">
                <label className="text-xs font-semibold text-slate-400">Pilih Berkas CSV</label>
                <input
                  type="file"
                  accept=".csv"
                  onChange={e => setImportingFile(e.target.files ? e.target.files[0] : null)}
                  className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2 text-xs text-slate-400"
                  required
                />
              </div>

              {importResult && (
                <div className="p-3 rounded-lg bg-indigo-500/5 border border-indigo-500/20 text-xs font-mono text-indigo-300">
                  {importResult}
                </div>
              )}

              <div className="mt-6 flex gap-3 pt-2">
                <button
                  type="button"
                  onClick={() => {
                    setShowImportModal(false);
                    setImportResult(null);
                    setImportingFile(null);
                  }}
                  className="flex-1 py-2.5 rounded-lg border border-slate-800 hover:bg-slate-800 text-xs font-semibold text-slate-300 transition-colors"
                >
                  Tutup
                </button>
                <button
                  type="submit"
                  disabled={isImporting || !importingFile}
                  className="flex-1 py-2.5 rounded-lg bg-indigo-650 hover:bg-indigo-500 disabled:bg-slate-800 disabled:text-slate-550 text-xs font-semibold text-white transition-colors"
                >
                  {isImporting ? 'Mengimpor...' : 'Mulai Impor'}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* MODAL 3: MANUAL ADJUSTMENT */}
      {showAdjustmentModal && (
        <div className="fixed inset-0 z-50 bg-slate-950/80 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-slate-900 border border-slate-800 rounded-2xl max-w-md w-full p-6 shadow-2xl relative">
            <h3 className="text-lg font-bold text-white mb-2 flex items-center gap-2">
              <AlertTriangle className="h-5 w-5 text-amber-400" />
              Form Penyesuaian Stok (Adjustment)
            </h3>
            <p className="text-xs text-slate-450 mb-6">Mengkoreksi stok fisik barang akibat rusak, hilang, atau selisih audit.</p>

            <form onSubmit={handleAdjustmentSubmit} className="space-y-4 text-sm text-slate-200">
              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-400">Pilih Produk</label>
                <select
                  value={adjustmentForm.productId}
                  onChange={e => setAdjustmentForm({ ...adjustmentForm, productId: e.target.value })}
                  className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-200 focus:outline-none"
                  required
                >
                  <option value="">-- Pilih Barang --</option>
                  {MOCK_STOCKS.map(item => (
                    <option key={item.id} value={item.id}>{item.sku} - {item.name}</option>
                  ))}
                </select>
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-400">Gudang</label>
                  <select
                    value={adjustmentForm.warehouseCode}
                    onChange={e => setAdjustmentForm({ ...adjustmentForm, warehouseCode: e.target.value })}
                    className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-200 focus:outline-none"
                  >
                    <option value="GDS">GDS (Gudang Utama)</option>
                    <option value="KGS">KGS (Toko Kasir)</option>
                  </select>
                </div>

                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-400">Kuantitas Penyesuaian</label>
                  <input
                    type="number"
                    placeholder="Contoh: -5 (hilang), +10 (audit)"
                    value={adjustmentForm.qty}
                    onChange={e => setAdjustmentForm({ ...adjustmentForm, qty: e.target.value })}
                    className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-100 placeholder-slate-650 focus:outline-none"
                    required
                  />
                </div>
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-400">Estimasi HPP (COGS Unit)</label>
                  <input
                    type="number"
                    placeholder="0"
                    value={adjustmentForm.cogs}
                    onChange={e => setAdjustmentForm({ ...adjustmentForm, cogs: e.target.value })}
                    className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-100 placeholder-slate-650 focus:outline-none"
                    required
                  />
                </div>

                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-400">Alasan Penyesuaian</label>
                  <select
                    value={adjustmentForm.reason}
                    onChange={e => setAdjustmentForm({ ...adjustmentForm, reason: e.target.value })}
                    className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-200 focus:outline-none"
                  >
                    <option value="Rusak">Barang Rusak</option>
                    <option value="Hilang">Barang Hilang / Susut</option>
                    <option value="Selisih Opname">Koreksi Opname Fisik</option>
                    <option value="Temuan">Temuan Persediaan</option>
                  </select>
                </div>
              </div>

              <div className="mt-6 flex gap-3 pt-2">
                <button
                  type="button"
                  onClick={() => setShowAdjustmentModal(false)}
                  className="flex-1 py-2.5 rounded-lg border border-slate-800 hover:bg-slate-800 text-xs font-semibold text-slate-300 transition-colors"
                >
                  Batal
                </button>
                <button
                  type="submit"
                  className="flex-1 py-2.5 rounded-lg bg-amber-600 hover:bg-amber-500 text-xs font-semibold text-white transition-colors"
                >
                  Terapkan Koreksi
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* MODAL 4: STOCK OPNAME (HITUNG FISIK) */}
      {showOpnameModal && (
        <div className="fixed inset-0 z-50 bg-slate-950/80 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-slate-900 border border-slate-800 rounded-2xl max-w-2xl w-full p-6 shadow-2xl relative max-h-[85vh] flex flex-col justify-between">
            <div>
              <h3 className="text-lg font-bold text-white mb-2 flex items-center gap-2">
                <ClipboardList className="h-5 w-5 text-purple-400" />
                Audit Stock Opname Fisik
              </h3>
              <p className="text-xs text-slate-450 mb-6">Mencocokkan jumlah stok fisik di gudang dengan catatan sistem.</p>
            </div>

            <form onSubmit={handleOpnameSubmit} className="space-y-4 text-sm text-slate-200 flex-1 overflow-hidden flex flex-col justify-between">
              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-400">Pilih Lokasi Gudang Audit</label>
                  <select
                    value={opnameForm.warehouseCode}
                    onChange={e => handleOpnameWarehouseChange(e.target.value)}
                    className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-200 focus:outline-none"
                    required
                  >
                    <option value="GDS">GDS (Gudang Utama)</option>
                    <option value="KGS">KGS (Toko Kasir)</option>
                  </select>
                </div>

                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-400">Catatan Opname</label>
                  <input
                    type="text"
                    placeholder="Opname Akhir Pekan..."
                    value={opnameForm.notes}
                    onChange={e => setOpnameForm({ ...opnameForm, notes: e.target.value })}
                    className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-100 placeholder-slate-600 focus:outline-none"
                  />
                </div>
              </div>

              {/* Opname Items Count Grid */}
              <div className="flex-1 overflow-y-auto space-y-3 pr-1 my-4 max-h-60 border-t border-b border-slate-850 py-3">
                <div className="grid grid-cols-12 text-xs text-slate-450 font-semibold px-2">
                  <span className="col-span-3">SKU</span>
                  <span className="col-span-5">Nama Barang</span>
                  <span className="col-span-2 text-right">Stok Sistem</span>
                  <span className="col-span-2 text-right">Fisik Rill</span>
                </div>

                {opnameForm.items.map((item, idx) => (
                  <div key={item.productId} className="grid grid-cols-12 items-center bg-slate-950 p-2.5 rounded-lg border border-slate-850 text-xs">
                    <span className="col-span-3 font-mono text-slate-400">{item.sku}</span>
                    <span className="col-span-5 font-semibold text-white truncate pr-2">{item.name}</span>
                    <span className="col-span-2 text-right font-mono text-slate-300">{item.systemQty}</span>
                    <input
                      type="number"
                      value={item.physicalQty}
                      onChange={e => handleOpnameQtyChange(idx, e.target.value)}
                      className="col-span-2 text-right bg-slate-900 border border-slate-800 rounded px-2 py-1 text-white font-mono focus:outline-none focus:border-indigo-500"
                      required
                    />
                  </div>
                ))}
              </div>

              <div className="mt-4 flex gap-3 pt-2">
                <button
                  type="button"
                  onClick={() => setShowOpnameModal(false)}
                  className="flex-1 py-2.5 rounded-lg border border-slate-800 hover:bg-slate-800 text-xs font-semibold text-slate-300 transition-colors"
                >
                  Batal
                </button>
                <button
                  type="submit"
                  className="flex-1 py-2.5 rounded-lg bg-purple-650 hover:bg-purple-500 text-xs font-semibold text-white transition-colors"
                >
                  Sahkan & Sesuaikan Stok
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* MODAL 5: CASH ADVANCE BEBAN */}
      {showExpenseModal && (
        <div className="fixed inset-0 z-50 bg-slate-950/80 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-slate-900 border border-slate-800 rounded-2xl max-w-md w-full p-6 shadow-2xl relative">
            <h3 className="text-lg font-bold text-white mb-2 flex items-center gap-2">
              <HandCoins className="h-5 w-5 text-rose-450" />
              Catat Pengeluaran Beban (Cash Advance)
            </h3>
            <p className="text-xs text-slate-450 mb-6">Mencatat beban kasir operasional dan diautoposting ke jurnal umum.</p>

            <form onSubmit={() => setShowExpenseModal(false)} className="space-y-4 text-sm text-slate-200">
              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-400">Kategori Beban</label>
                <select
                  value={expenseForm.category}
                  onChange={e => setExpenseForm({ ...expenseForm, category: e.target.value })}
                  className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-200 focus:outline-none focus:border-indigo-500"
                  required
                >
                  <option value="Bensin">Bensin Operasional</option>
                  <option value="Uang Makan">Uang Makan Staf</option>
                  <option value="Perkakas Toko">Pembelian Perkakas Toko</option>
                  <option value="Lainnya">Lainnya</option>
                </select>
              </div>

              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-400">Nominal Pengeluaran</label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-xs font-bold text-slate-550">Rp</span>
                  <input
                    type="number"
                    placeholder="0"
                    value={expenseForm.amount}
                    onChange={e => setExpenseForm({ ...expenseForm, amount: e.target.value })}
                    className="w-full bg-slate-950 border border-slate-800 rounded-lg py-2.5 pl-9 pr-4 text-sm font-mono text-slate-100 placeholder-slate-650 focus:outline-none"
                    required
                  />
                </div>
              </div>

              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-400">Metode Pengeluaran</label>
                <select
                  value={expenseForm.paymentMethod}
                  onChange={e => setExpenseForm({ ...expenseForm, paymentMethod: e.target.value })}
                  className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-200 focus:outline-none"
                >
                  <option value="Cash">Cash (Kas Kasir KGS)</option>
                  <option value="Transfer">Transfer (Bank BCA Mandiri)</option>
                </select>
              </div>

              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-400">Keterangan / Memo</label>
                <textarea
                  placeholder="Contoh: Beli bensin motor operasional toko..."
                  value={expenseForm.description}
                  onChange={e => setExpenseForm({ ...expenseForm, description: e.target.value })}
                  className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-100 placeholder-slate-660 focus:outline-none focus:border-indigo-500 h-20"
                  required
                />
              </div>

              <div className="mt-6 flex gap-3 pt-2">
                <button
                  type="button"
                  onClick={() => setShowExpenseModal(false)}
                  className="flex-1 py-2.5 rounded-lg border border-slate-800 hover:bg-slate-800 text-xs font-semibold text-slate-300 transition-colors"
                >
                  Batal
                </button>
                <button
                  type="submit"
                  className="flex-1 py-2.5 rounded-lg bg-rose-650 hover:bg-rose-500 text-xs font-semibold text-white transition-colors"
                >
                  Simpan & Setujui
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* MODAL 6: SETOR TUNAI BANK */}
      {showDepositModal && (
        <div className="fixed inset-0 z-50 bg-slate-950/80 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-slate-900 border border-slate-800 rounded-2xl max-w-md w-full p-6 shadow-2xl relative">
            <h3 className="text-lg font-bold text-white mb-2 flex items-center gap-2">
              <Warehouse className="h-5 w-5 text-emerald-450" />
              Pencatatan Setoran Kas Ke Bank
            </h3>
            <p className="text-xs text-slate-450 mb-6">Mencatat penyetoran fisik uang tunai dari kasir ke rekening bank bisnis.</p>

            <form onSubmit={() => setShowDepositModal(false)} className="space-y-4 text-sm text-slate-200">
              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-400">Nominal Setoran</label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-xs font-bold text-slate-550">Rp</span>
                  <input
                    type="number"
                    placeholder="0"
                    value={depositForm.amount}
                    onChange={e => setDepositForm({ ...depositForm, amount: e.target.value })}
                    className="w-full bg-slate-950 border border-slate-800 rounded-lg py-2.5 pl-9 pr-4 text-sm font-mono text-slate-100 placeholder-slate-650 focus:outline-none"
                    required
                  />
                </div>
              </div>

              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-400">Informasi Bank Penerima</label>
                <input
                  type="text"
                  placeholder="Contoh: BCA KGS 7890123"
                  value={depositForm.bankAccountInfo}
                  onChange={e => setDepositForm({ ...depositForm, bankAccountInfo: e.target.value })}
                  className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-100 placeholder-slate-600 focus:outline-none focus:border-indigo-500"
                  required
                />
              </div>

              <div className="mt-6 flex gap-3 pt-2">
                <button
                  type="button"
                  onClick={() => setShowDepositModal(false)}
                  className="flex-1 py-2.5 rounded-lg border border-slate-800 hover:bg-slate-800 text-xs font-semibold text-slate-300 transition-colors"
                >
                  Batal
                </button>
                <button
                  type="submit"
                  className="flex-1 py-2.5 rounded-lg bg-emerald-650 hover:bg-emerald-500 text-xs font-semibold text-white transition-colors"
                >
                  Catat Setoran
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* MODAL 7: ADD CUSTOMER */}
      {showCustomerModal && (
        <div className="fixed inset-0 z-50 bg-slate-950/80 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-slate-900 border border-slate-800 rounded-2xl max-w-md w-full p-6 shadow-2xl relative">
            <h3 className="text-lg font-bold text-white mb-2 flex items-center gap-2">
              <PlusCircle className="h-5 w-5 text-indigo-400" />
              Tambah Pelanggan Baru
            </h3>
            <p className="text-xs text-slate-450 mb-6">Mendaftarkan pelanggan baru ke database KGS.</p>

            <form onSubmit={handleCustomerSubmit} className="space-y-4 text-sm text-slate-200">
              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-400">Kode Pelanggan</label>
                <input
                  type="text"
                  placeholder="Contoh: CUST-010"
                  value={customerForm.code}
                  onChange={e => setCustomerForm({ ...customerForm, code: e.target.value })}
                  className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-100 placeholder-slate-600 focus:outline-none"
                  required
                />
              </div>

              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-400">Nama Pelanggan</label>
                <input
                  type="text"
                  placeholder="Contoh: Budi Santoso"
                  value={customerForm.name}
                  onChange={e => setCustomerForm({ ...customerForm, name: e.target.value })}
                  className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-100 placeholder-slate-600 focus:outline-none"
                  required
                />
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-400">Email (Opsional)</label>
                  <input
                    type="email"
                    placeholder="budi@email.com"
                    value={customerForm.email}
                    onChange={e => setCustomerForm({ ...customerForm, email: e.target.value })}
                    className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-100 placeholder-slate-600 focus:outline-none"
                  />
                </div>

                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-400">No Telepon (Opsional)</label>
                  <input
                    type="text"
                    placeholder="0812xxxx"
                    value={customerForm.phone}
                    onChange={e => setCustomerForm({ ...customerForm, phone: e.target.value })}
                    className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-100 placeholder-slate-600 focus:outline-none"
                  />
                </div>
              </div>

              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-400">Saldo Deposit Awal</label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-xs font-bold text-slate-550">Rp</span>
                  <input
                    type="number"
                    placeholder="0"
                    value={customerForm.balance}
                    onChange={e => setCustomerForm({ ...customerForm, balance: e.target.value })}
                    className="w-full bg-slate-950 border border-slate-800 rounded-lg py-2.5 pl-9 pr-4 text-sm font-mono text-slate-100 focus:outline-none"
                  />
                </div>
              </div>

              <div className="mt-6 flex gap-3 pt-2">
                <button
                  type="button"
                  onClick={() => setShowCustomerModal(false)}
                  className="flex-1 py-2.5 rounded-lg border border-slate-800 hover:bg-slate-800 text-xs font-semibold text-slate-300 transition-colors"
                >
                  Batal
                </button>
                <button
                  type="submit"
                  className="flex-1 py-2.5 rounded-lg bg-indigo-650 hover:bg-indigo-500 text-xs font-semibold text-white transition-colors"
                >
                  Simpan Pelanggan
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* MODAL 8: TOPUP BALANCE */}
      {showTopupModal && (
        <div className="fixed inset-0 z-50 bg-slate-950/80 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-slate-900 border border-slate-800 rounded-2xl max-w-md w-full p-6 shadow-2xl relative">
            <h3 className="text-lg font-bold text-white mb-2 flex items-center gap-2">
              <HandCoins className="h-5 w-5 text-emerald-450" />
              Top Up Deposit Pelanggan
            </h3>
            <p className="text-xs text-slate-450 mb-6">Menambah saldo titipan/deposit pelanggan untuk mempermudah transaksi kasir.</p>

            <form onSubmit={handleTopupSubmit} className="space-y-4 text-sm text-slate-200">
              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-400">Pilih Pelanggan</label>
                <select
                  value={topupForm.customerId}
                  onChange={e => setTopupForm({ ...topupForm, customerId: e.target.value })}
                  className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-200 focus:outline-none"
                  required
                >
                  <option value="">-- Pilih Pelanggan --</option>
                  {customers.map(c => (
                    <option key={c.id} value={c.id}>{c.code} - {c.name}</option>
                  ))}
                </select>
              </div>

              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-400">Nominal Top Up</label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-xs font-bold text-slate-550">Rp</span>
                  <input
                    type="number"
                    placeholder="0"
                    value={topupForm.amount}
                    onChange={e => setTopupForm({ ...topupForm, amount: e.target.value })}
                    className="w-full bg-slate-950 border border-slate-800 rounded-lg py-2.5 pl-9 pr-4 text-sm font-mono text-slate-100 focus:outline-none"
                    required
                  />
                </div>
              </div>

              <div className="mt-6 flex gap-3 pt-2">
                <button
                  type="button"
                  onClick={() => setShowTopupModal(false)}
                  className="flex-1 py-2.5 rounded-lg border border-slate-800 hover:bg-slate-800 text-xs font-semibold text-slate-300 transition-colors"
                >
                  Batal
                </button>
                <button
                  type="submit"
                  className="flex-1 py-2.5 rounded-lg bg-emerald-650 hover:bg-emerald-500 text-xs font-semibold text-white transition-colors"
                >
                  Proses Top Up
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* MODAL 9: SET PRICELIST CUSTOM */}
      {showPricelistModal && (
        <div className="fixed inset-0 z-50 bg-slate-950/80 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-slate-900 border border-slate-800 rounded-2xl max-w-md w-full p-6 shadow-2xl relative">
            <h3 className="text-lg font-bold text-white mb-2 flex items-center gap-2">
              <PlusCircle className="h-5 w-5 text-indigo-400" />
              Set Harga Khusus Pelanggan
            </h3>
            <p className="text-xs text-slate-450 mb-6">Mengatur harga jual khusus produk tertentu untuk satu pelanggan khusus.</p>

            <form onSubmit={handlePricelistSubmit} className="space-y-4 text-sm text-slate-200">
              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-400">Pilih Pelanggan</label>
                <select
                  value={pricelistForm.customerId}
                  onChange={e => setPricelistForm({ ...pricelistForm, customerId: e.target.value })}
                  className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-200 focus:outline-none"
                  required
                >
                  <option value="">-- Pilih Pelanggan --</option>
                  {customers.map(c => (
                    <option key={c.id} value={c.id}>{c.code} - {c.name}</option>
                  ))}
                </select>
              </div>

              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-400">Pilih Produk</label>
                <select
                  value={pricelistForm.productId}
                  onChange={e => setPricelistForm({ ...pricelistForm, productId: e.target.value })}
                  className="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-slate-200 focus:outline-none"
                  required
                >
                  <option value="">-- Pilih Produk --</option>
                  {stocks.map(s => (
                    <option key={s.id} value={s.id}>{s.sku} - {s.name}</option>
                  ))}
                </select>
              </div>

              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-400">Harga Jual Khusus</label>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-xs font-bold text-slate-550">Rp</span>
                  <input
                    type="number"
                    placeholder="0"
                    value={pricelistForm.price}
                    onChange={e => setPricelistForm({ ...pricelistForm, price: e.target.value })}
                    className="w-full bg-slate-950 border border-slate-800 rounded-lg py-2.5 pl-9 pr-4 text-sm font-mono text-slate-100 focus:outline-none"
                    required
                  />
                </div>
              </div>

              <div className="mt-6 flex gap-3 pt-2">
                <button
                  type="button"
                  onClick={() => setShowPricelistModal(false)}
                  className="flex-1 py-2.5 rounded-lg border border-slate-800 hover:bg-slate-800 text-xs font-semibold text-slate-300 transition-colors"
                >
                  Batal
                </button>
                <button
                  type="submit"
                  className="flex-1 py-2.5 rounded-lg bg-indigo-650 hover:bg-indigo-500 text-xs font-semibold text-white transition-colors"
                >
                  Simpan Harga Khusus
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  )
}
