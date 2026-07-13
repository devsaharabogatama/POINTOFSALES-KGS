import { useState, useMemo } from 'react'
import { 
  Search, 
  ShoppingCart, 
  Wifi, 
  WifiOff, 
  Trash2, 
  Plus, 
  Minus, 
  Package, 
  User, 
  Clock, 
  CreditCard,
  Banknote,
  QrCode,
  Layers,
  Sparkles,
  Printer
} from 'lucide-react'
import { printer } from './lib/printer'

interface Product {
  id: string;
  sku: string;
  name: string;
  price: number;
  category: string;
  stock: number;
  uom: string;
}

interface CartItem {
  product: Product;
  quantity: number;
}

const MOCK_PRODUCTS: Product[] = [
  { id: '1', sku: 'SEM-PAD-50', name: 'Semen Padang 50kg', price: 72000, category: 'Bahan Bangunan', stock: 120, uom: 'sak' },
  { id: '2', sku: 'BES-BET-10', name: 'Besi Beton 10mm SNI', price: 85000, category: 'Bahan Bangunan', stock: 85, uom: 'batang' },
  { id: '3', sku: 'CAT-AV-WHT', name: 'Avitex Putih 5kg', price: 145000, category: 'Cat & Pewarna', stock: 40, uom: 'pail' },
  { id: '4', sku: 'PAKU-3INCH', name: 'Paku Kayu 3 Inch', price: 20000, category: 'Alat & Perkakas', stock: 50, uom: 'kg' },
  { id: '5', sku: 'KAYU-MER-4M', name: 'Kayu Meranti 4x6x4m', price: 45000, category: 'Bahan Bangunan', stock: 200, uom: 'batang' },
  { id: '6', sku: 'SEL-GRD-4IN', name: 'Selang Green Elastic 4"', price: 15000, category: 'Alat & Perkakas', stock: 65, uom: 'meter' },
  { id: '7', sku: 'CAT-EXP-BLK', name: 'No Drop Hitam 4kg', price: 215000, category: 'Cat & Pewarna', stock: 18, uom: 'pail' },
  { id: '8', sku: 'TANG-KR-8IN', name: 'Tang Kombinasi Kenmaster 8"', price: 38000, category: 'Alat & Perkakas', stock: 25, uom: 'pcs' },
];

const CATEGORIES = ['Semua', 'Bahan Bangunan', 'Cat & Pewarna', 'Alat & Perkakas'];

export default function App() {
  const [isOnline, setIsOnline] = useState(true)
  const [isPrinterConnected, setIsPrinterConnected] = useState(false)
  const [searchQuery, setSearchQuery] = useState('')

  const handleConnectPrinter = async () => {
    const success = await printer.connect()
    setIsPrinterConnected(success)
  }
  const [selectedCategory, setSelectedCategory] = useState('Semua')
  const [cart, setCart] = useState<CartItem[]>([])
  const [paymentMethod, setPaymentMethod] = useState<'Cash' | 'Transfer' | 'QRIS' | 'Tempo'>('Cash')
  const [paidAmount, setPaidAmount] = useState<string>('')
  const [showReceipt, setShowReceipt] = useState(false)
  const [receiptData, setReceiptData] = useState<{
    invoiceNo: string;
    items: CartItem[];
    subtotal: number;
    grandTotal: number;
    paidAmount: number;
    change: number;
    paymentMethod: string;
    date: string;
  } | null>(null)

  // Filter products based on search and category
  const filteredProducts = useMemo(() => {
    return MOCK_PRODUCTS.filter(product => {
      const matchesSearch = product.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
                            product.sku.toLowerCase().includes(searchQuery.toLowerCase());
      const matchesCategory = selectedCategory === 'Semua' || product.category === selectedCategory;
      return matchesSearch && matchesCategory;
    });
  }, [searchQuery, selectedCategory]);

  const addToCart = (product: Product) => {
    setCart(prev => {
      const existing = prev.find(item => item.product.id === product.id);
      if (existing) {
        if (existing.quantity >= product.stock) return prev; // Limit to stock
        return prev.map(item => 
          item.product.id === product.id ? { ...item, quantity: item.quantity + 1 } : item
        );
      }
      return [...prev, { product, quantity: 1 }];
    });
  };

  const updateQuantity = (productId: string, delta: number) => {
    setCart(prev => prev.map(item => {
      if (item.product.id === productId) {
        const newQty = item.quantity + delta;
        if (newQty <= 0) return null;
        if (newQty > item.product.stock) return item; // Limit to stock
        return { ...item, quantity: newQty };
      }
      return item;
    }).filter(Boolean) as CartItem[]);
  };

  const removeFromCart = (productId: string) => {
    setCart(prev => prev.filter(item => item.product.id !== productId));
  };

  const subtotal = useMemo(() => {
    return cart.reduce((sum, item) => sum + (item.product.price * item.quantity), 0);
  }, [cart]);

  const grandTotal = subtotal; // Simpler for mock POS

  const changeAmount = useMemo(() => {
    const paid = parseFloat(paidAmount) || 0;
    return Math.max(0, paid - grandTotal);
  }, [paidAmount, grandTotal]);

  const handleCheckout = () => {
    if (cart.length === 0) return;
    const paid = paymentMethod === 'Tempo' ? 0 : (parseFloat(paidAmount) || grandTotal);
    
    const invoiceNo = `SO-${Math.floor(10000 + Math.random() * 90000)}`;
    setReceiptData({
      invoiceNo,
      items: [...cart],
      subtotal,
      grandTotal,
      paidAmount: paid,
      change: paymentMethod === 'Cash' ? Math.max(0, paid - grandTotal) : 0,
      paymentMethod,
      date: new Date().toLocaleString('id-ID'),
    });
    setShowReceipt(true);
  };

  const resetSale = () => {
    setCart([]);
    setPaidAmount('');
    setShowReceipt(false);
    setReceiptData(null);
  };

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 flex flex-col font-sans selection:bg-indigo-500 selection:text-white">
      {/* HEADER */}
      <header className="border-b border-slate-800 bg-slate-900/80 backdrop-blur-md sticky top-0 z-40 px-6 py-4 flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="h-10 w-10 rounded-xl bg-gradient-to-tr from-indigo-500 to-purple-600 flex items-center justify-center shadow-lg shadow-indigo-500/20">
            <Sparkles className="h-5 w-5 text-white animate-pulse" />
          </div>
          <div>
            <h1 className="text-xl font-bold tracking-tight text-white flex items-center gap-2">
              KGS KASIR <span className="text-xs px-2 py-0.5 rounded-full bg-indigo-500/10 text-indigo-400 font-semibold border border-indigo-500/20">Mini-ERP</span>
            </h1>
            <p className="text-xs text-slate-400">Terminal Kasir Pasar Tradisional</p>
          </div>
        </div>

        <div className="flex items-center gap-4">
          {/* Printer Connection Button */}
          <button 
            onClick={handleConnectPrinter}
            className={`flex items-center gap-2 px-3 py-1.5 rounded-lg border text-sm font-medium transition-all ${
              isPrinterConnected 
                ? 'bg-indigo-500/10 text-indigo-400 border-indigo-500/20' 
                : 'bg-slate-800 text-slate-400 border-slate-700 hover:bg-slate-750 hover:text-white'
            }`}
          >
            <Printer className="h-4 w-4" />
            <span>{isPrinterConnected ? 'Printer Terhubung' : 'Hubungkan Printer'}</span>
          </button>

          {/* Connection Status Button */}
          <button 
            onClick={() => setIsOnline(!isOnline)}
            className={`flex items-center gap-2 px-3 py-1.5 rounded-lg border text-sm font-medium transition-all ${
              isOnline 
                ? 'bg-emerald-500/10 text-emerald-400 border-emerald-500/20 hover:bg-emerald-500/20' 
                : 'bg-rose-500/10 text-rose-400 border-rose-500/20 hover:bg-rose-500/20'
            }`}
          >
            {isOnline ? (
              <>
                <Wifi className="h-4 w-4" />
                <span>Mode Online</span>
              </>
            ) : (
              <>
                <WifiOff className="h-4 w-4" />
                <span>Mode Offline (Local Cache)</span>
              </>
            )}
          </button>

          <div className="flex items-center gap-3 pl-4 border-l border-slate-800 text-sm text-slate-400">
            <Clock className="h-4 w-4" />
            <span>Sesi: SES-20260713</span>
            <div className="h-8 w-8 rounded-full bg-slate-800 flex items-center justify-center border border-slate-700">
              <User className="h-4 w-4 text-slate-300" />
            </div>
          </div>
        </div>
      </header>

      {/* MAIN CONTAINER */}
      <main className="flex-1 flex overflow-hidden">
        {/* LEFT COLUMN: PRODUCTS & SEARCH */}
        <section className="flex-1 flex flex-col p-6 overflow-y-auto">
          {/* Search and Categories */}
          <div className="mb-6 flex flex-col gap-4">
            <div className="relative">
              <Search className="absolute left-4 top-1/2 -translate-y-1/2 h-5 w-5 text-slate-500" />
              <input 
                type="text" 
                placeholder="Cari barang berdasarkan nama atau SKU..."
                value={searchQuery}
                onChange={e => setSearchQuery(e.target.value)}
                className="w-full bg-slate-900 border border-slate-800 rounded-xl py-3 pl-12 pr-4 text-slate-100 placeholder-slate-500 focus:outline-none focus:border-indigo-500 focus:ring-2 focus:ring-indigo-500/20 transition-all"
              />
            </div>

            {/* Categories */}
            <div className="flex items-center gap-2 overflow-x-auto pb-2">
              {CATEGORIES.map(category => (
                <button
                  key={category}
                  onClick={() => setSelectedCategory(category)}
                  className={`px-4 py-2 rounded-lg text-sm font-medium whitespace-nowrap transition-all ${
                    selectedCategory === category
                      ? 'bg-indigo-600 text-white shadow-lg shadow-indigo-600/20'
                      : 'bg-slate-900 text-slate-400 border border-slate-800 hover:bg-slate-800 hover:text-slate-200'
                  }`}
                >
                  {category}
                </button>
              ))}
            </div>
          </div>

          {/* Product Grid */}
          <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 xl:grid-cols-4 gap-4 flex-1">
            {filteredProducts.map(product => {
              const inCart = cart.find(item => item.product.id === product.id);
              const isOutOfStock = product.stock <= 0;
              return (
                <div 
                  key={product.id}
                  onClick={() => !isOutOfStock && addToCart(product)}
                  className={`group relative bg-slate-900 border border-slate-800 rounded-2xl p-4 flex flex-col justify-between cursor-pointer transition-all hover:border-slate-700 hover:bg-slate-900/60 ${
                    inCart ? 'ring-2 ring-indigo-500/50 border-transparent' : ''
                  } ${isOutOfStock ? 'opacity-50 cursor-not-allowed' : ''}`}
                >
                  <div>
                    {/* SKU & Stock tag */}
                    <div className="flex justify-between items-center mb-3">
                      <span className="text-[10px] font-mono bg-slate-800 text-slate-400 px-2 py-0.5 rounded border border-slate-700">
                        {product.sku}
                      </span>
                      <span className={`text-xs px-2 py-0.5 rounded-full font-medium ${
                        isOutOfStock 
                          ? 'bg-rose-500/10 text-rose-400 border border-rose-500/20' 
                          : product.stock < 20 
                          ? 'bg-amber-500/10 text-amber-400 border border-amber-500/20'
                          : 'bg-slate-800 text-slate-300'
                      }`}>
                        Stok: {product.stock} {product.uom}
                      </span>
                    </div>

                    <h3 className="font-semibold text-slate-100 text-sm mb-1 group-hover:text-white transition-colors line-clamp-2">
                      {product.name}
                    </h3>
                    <p className="text-xs text-slate-500 mb-4">{product.category}</p>
                  </div>

                  <div className="flex items-center justify-between mt-auto">
                    <span className="text-base font-bold text-indigo-400">
                      Rp {product.price.toLocaleString('id-ID')}
                    </span>
                    <button 
                      disabled={isOutOfStock}
                      className={`h-8 w-8 rounded-lg flex items-center justify-center transition-all ${
                        inCart 
                          ? 'bg-indigo-600 text-white' 
                          : 'bg-slate-800 text-slate-400 group-hover:bg-indigo-600 group-hover:text-white'
                      }`}
                    >
                      <Plus className="h-4 w-4" />
                    </button>
                  </div>

                  {inCart && (
                    <div className="absolute top-2 right-2 bg-indigo-500 text-white text-[10px] font-bold h-5 w-5 rounded-full flex items-center justify-center shadow-lg">
                      {inCart.quantity}
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        </section>

        {/* RIGHT COLUMN: SHOPPING CART */}
        <section className="w-96 border-l border-slate-800 bg-slate-900/40 backdrop-blur-md flex flex-col justify-between">
          <div className="p-6 flex-1 flex flex-col overflow-hidden">
            <div className="flex items-center justify-between pb-4 border-b border-slate-800 mb-4">
              <h2 className="text-lg font-bold text-white flex items-center gap-2">
                <ShoppingCart className="h-5 w-5 text-indigo-500" />
                Keranjang
              </h2>
              {cart.length > 0 && (
                <button 
                  onClick={() => setCart([])}
                  className="text-xs text-rose-400 hover:text-rose-300 font-medium flex items-center gap-1 transition-colors"
                >
                  <Trash2 className="h-3 w-3" />
                  Kosongkan
                </button>
              )}
            </div>

            {/* Cart Items */}
            <div className="flex-1 overflow-y-auto space-y-4 pr-1">
              {cart.length === 0 ? (
                <div className="h-full flex flex-col items-center justify-center text-slate-500 gap-3">
                  <Package className="h-12 w-12 text-slate-700" />
                  <p className="text-sm">Keranjang kosong</p>
                </div>
              ) : (
                cart.map(item => (
                  <div key={item.product.id} className="bg-slate-900/80 border border-slate-850 p-3 rounded-xl flex gap-3 justify-between">
                    <div className="flex-1 min-w-0">
                      <h4 className="text-sm font-medium text-slate-200 truncate">{item.product.name}</h4>
                      <span className="text-xs text-slate-500">Rp {item.product.price.toLocaleString('id-ID')}</span>
                      <div className="text-xs font-bold text-indigo-400 mt-1">
                        Rp {(item.product.price * item.quantity).toLocaleString('id-ID')}
                      </div>
                    </div>

                    <div className="flex flex-col justify-between items-end gap-2">
                      <button 
                        onClick={() => removeFromCart(item.product.id)}
                        className="text-slate-650 hover:text-rose-400 transition-colors p-1"
                      >
                        <Trash2 className="h-3.5 w-3.5" />
                      </button>

                      <div className="flex items-center bg-slate-950 border border-slate-800 rounded-lg p-1">
                        <button 
                          onClick={() => updateQuantity(item.product.id, -1)}
                          className="h-6 w-6 text-slate-400 hover:text-white hover:bg-slate-900 rounded flex items-center justify-center transition-all"
                        >
                          <Minus className="h-3.5 w-3.5" />
                        </button>
                        <span className="px-3 text-xs font-mono font-bold text-slate-200">
                          {item.quantity}
                        </span>
                        <button 
                          onClick={() => updateQuantity(item.product.id, 1)}
                          className="h-6 w-6 text-slate-400 hover:text-white hover:bg-slate-900 rounded flex items-center justify-center transition-all"
                        >
                          <Plus className="h-3.5 w-3.5" />
                        </button>
                      </div>
                    </div>
                  </div>
                ))
              )}
            </div>
          </div>

          {/* PAYMENT METHODS & TOTAL */}
          <div className="p-6 bg-slate-900/90 border-t border-slate-800 space-y-4">
            <div className="space-y-2">
              <div className="flex justify-between text-sm text-slate-400">
                <span>Subtotal</span>
                <span>Rp {subtotal.toLocaleString('id-ID')}</span>
              </div>
              <div className="flex justify-between text-base font-bold text-white pt-2 border-t border-slate-850">
                <span>Grand Total</span>
                <span className="text-indigo-400">Rp {grandTotal.toLocaleString('id-ID')}</span>
              </div>
            </div>

            {/* Payment Selector */}
            <div className="space-y-2 pt-2">
              <label className="text-xs font-semibold text-slate-400">Metode Pembayaran</label>
              <div className="grid grid-cols-2 gap-2">
                {[
                  { id: 'Cash', label: 'Tunai', icon: Banknote },
                  { id: 'Transfer', label: 'Transfer', icon: CreditCard },
                  { id: 'QRIS', label: 'QRIS', icon: QrCode },
                  { id: 'Tempo', label: 'Tempo', icon: Layers },
                ].map(method => {
                  const Icon = method.icon;
                  return (
                    <button
                      key={method.id}
                      onClick={() => {
                        setPaymentMethod(method.id as any);
                        if (method.id === 'Tempo') setPaidAmount('0');
                        else setPaidAmount('');
                      }}
                      className={`flex items-center gap-2 p-2.5 rounded-lg border text-left text-xs font-medium transition-all ${
                        paymentMethod === method.id
                          ? 'bg-indigo-600/10 text-indigo-400 border-indigo-500/50'
                          : 'bg-slate-950 text-slate-450 border-slate-850 hover:bg-slate-900'
                      }`}
                    >
                      <Icon className="h-4 w-4 shrink-0" />
                      <span>{method.label}</span>
                    </button>
                  );
                })}
              </div>
            </div>

            {/* Paid Amount Input */}
            {paymentMethod !== 'Tempo' && (
              <div className="space-y-1">
                <div className="flex justify-between items-center">
                  <label className="text-xs font-semibold text-slate-400">Jumlah Uang Diterima</label>
                  {grandTotal > 0 && (
                    <button 
                      onClick={() => setPaidAmount(grandTotal.toString())}
                      className="text-[10px] text-indigo-400 hover:text-indigo-300 font-semibold"
                    >
                      Uang Pas
                    </button>
                  )}
                </div>
                <div className="relative">
                  <span className="absolute left-3 top-1/2 -translate-y-1/2 text-xs font-bold text-slate-550">Rp</span>
                  <input 
                    type="number"
                    placeholder="0"
                    value={paidAmount}
                    onChange={e => setPaidAmount(e.target.value)}
                    className="w-full bg-slate-950 border border-slate-850 rounded-lg py-2.5 pl-9 pr-4 text-sm font-mono text-slate-100 focus:outline-none focus:border-indigo-500"
                  />
                </div>
                {parseFloat(paidAmount) > 0 && (
                  <div className="flex justify-between text-xs text-emerald-400 pt-1">
                    <span>Kembalian</span>
                    <span>Rp {changeAmount.toLocaleString('id-ID')}</span>
                  </div>
                )}
              </div>
            )}

            <button
              onClick={handleCheckout}
              disabled={cart.length === 0}
              className={`w-full py-3.5 rounded-xl font-semibold text-sm flex items-center justify-center gap-2 transition-all ${
                cart.length === 0
                  ? 'bg-slate-850 text-slate-500 cursor-not-allowed border border-slate-800'
                  : 'bg-indigo-600 hover:bg-indigo-500 text-white shadow-lg shadow-indigo-600/25 hover:shadow-indigo-500/35 hover:-translate-y-0.5'
              }`}
            >
              Bayar Sekarang
            </button>
          </div>
        </section>
      </main>

      {/* RECEIPT MODAL */}
      {showReceipt && receiptData && (
        <div className="fixed inset-0 z-50 bg-slate-950/80 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-slate-900 border border-slate-800 rounded-2xl max-w-sm w-full p-6 shadow-2xl relative">
            <h3 className="text-lg font-bold text-white mb-2 text-center">Transaksi Sukses!</h3>
            <p className="text-xs text-center text-slate-405 mb-4">
              {isOnline ? 'Data tersinkronisasi ke server cloud.' : 'Data tersimpan lokal (Offline).'}
            </p>

            <div className="bg-slate-950 p-4 rounded-xl border border-slate-850 space-y-4 text-xs font-mono text-slate-300">
              <div className="text-center pb-2 border-b border-dashed border-slate-800">
                <div className="font-bold text-sm text-slate-200">KGS MINI-ERP</div>
                <div>Pasar Raya Padang</div>
              </div>

              <div className="space-y-1">
                <div className="flex justify-between">
                  <span>No Invoice:</span>
                  <span className="font-bold text-slate-200">{receiptData.invoiceNo}</span>
                </div>
                <div className="flex justify-between">
                  <span>Tanggal:</span>
                  <span>{receiptData.date}</span>
                </div>
                <div className="flex justify-between">
                  <span>Kasir:</span>
                  <span>KGS Cashier</span>
                </div>
              </div>

              <div className="border-t border-dashed border-slate-800 pt-2 space-y-1">
                {receiptData.items.map(item => (
                  <div key={item.product.id} className="flex justify-between">
                    <span>{item.product.name} ({item.quantity}x)</span>
                    <span>Rp {(item.product.price * item.quantity).toLocaleString('id-ID')}</span>
                  </div>
                ))}
              </div>

              <div className="border-t border-dashed border-slate-800 pt-2 space-y-1">
                <div className="flex justify-between">
                  <span>Subtotal:</span>
                  <span>Rp {receiptData.subtotal.toLocaleString('id-ID')}</span>
                </div>
                <div className="flex justify-between font-bold text-slate-200">
                  <span>Grand Total:</span>
                  <span>Rp {receiptData.grandTotal.toLocaleString('id-ID')}</span>
                </div>
                <div className="flex justify-between">
                  <span>Metode:</span>
                  <span>{receiptData.paymentMethod}</span>
                </div>
                <div className="flex justify-between">
                  <span>Bayar:</span>
                  <span>Rp {receiptData.paidAmount.toLocaleString('id-ID')}</span>
                </div>
                {receiptData.paymentMethod === 'Cash' && (
                  <div className="flex justify-between text-emerald-400">
                    <span>Kembali:</span>
                    <span>Rp {receiptData.change.toLocaleString('id-ID')}</span>
                  </div>
                )}
              </div>
            </div>

            <div className="mt-6 flex gap-3">
              <button 
                onClick={resetSale}
                className="flex-1 py-2.5 rounded-lg border border-slate-800 hover:bg-slate-800 text-xs font-semibold text-slate-300 transition-colors"
              >
                Tutup
              </button>
              <button 
                onClick={async () => {
                  if (receiptData) {
                    await printer.print(receiptData);
                  }
                  resetSale();
                }}
                className="flex-1 py-2.5 rounded-lg bg-indigo-650 hover:bg-indigo-500 text-xs font-semibold text-white transition-colors"
              >
                Cetak Struk
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
