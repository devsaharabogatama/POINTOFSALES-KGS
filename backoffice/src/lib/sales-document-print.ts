type JsonMap = Record<string, unknown>

function map(value: unknown): JsonMap {
  return value && typeof value === 'object' && !Array.isArray(value) ? value as JsonMap : {}
}

function rows(value: unknown): JsonMap[] {
  return Array.isArray(value) ? value.map(map) : []
}

function escapeHtml(value: unknown) {
  return String(value ?? '').replace(/[&<>'"]/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;',
  })[character] ?? character)
}

function money(value: unknown) {
  return new Intl.NumberFormat('id-ID', { style: 'currency', currency: 'IDR', maximumFractionDigits: 0 })
    .format(Number(value) || 0)
}

function quantity(value: unknown) {
  return new Intl.NumberFormat('id-ID', { maximumFractionDigits: 6 }).format(Number(value) || 0)
}

function dateTime(value: unknown) {
  if (!value) return '-'
  const parsed = new Date(String(value))
  return Number.isNaN(parsed.getTime()) ? String(value) : parsed.toLocaleString('id-ID')
}

function openPrint(title: string, body: string) {
  const html = `<!doctype html><html lang="id"><head><meta charset="utf-8"><title>${escapeHtml(title)}</title><style>
    @page{size:A4;margin:13mm}*{box-sizing:border-box}body{font:12px Arial,sans-serif;color:#172033;margin:0}header{display:flex;justify-content:space-between;gap:24px;border-bottom:2px solid #172033;padding-bottom:14px}h1{font-size:23px;margin:0 0 5px}.muted{color:#64748b}.right{text-align:right}.identity{display:grid;grid-template-columns:1fr 1fr;gap:18px;margin:18px 0}.box{border:1px solid #dbe2ea;border-radius:8px;padding:12px}.box b{display:block;margin-bottom:5px}table{border-collapse:collapse;width:100%;margin-top:14px}th,td{padding:8px;border-bottom:1px solid #dbe2ea;text-align:left}th{background:#f1f5f9;font-size:10px;text-transform:uppercase}.num{text-align:right}.totals{margin:18px 0 0 auto;width:310px}.totals div{display:flex;justify-content:space-between;padding:5px}.grand{font-size:15px;font-weight:700;border-top:2px solid #172033}.signatures{display:grid;grid-template-columns:repeat(3,1fr);gap:25px;margin-top:55px;text-align:center}.signatures div:after{content:'';display:block;border-top:1px solid #172033;margin:55px 12px 0}img.logo{display:block;max-height:60px;max-width:150px;margin-bottom:8px}@media print{button{display:none}}
  </style></head><body>${body}<script>window.addEventListener('load',()=>{setTimeout(()=>window.print(),250)})</script></body></html>`
  const url = URL.createObjectURL(new Blob([html], { type: 'text/html;charset=utf-8' }))
  const printWindow = window.open(url, '_blank')
  if (!printWindow) {
    URL.revokeObjectURL(url)
    throw new Error('Popup diblokir browser. Izinkan popup untuk mencetak dokumen.')
  }
  window.setTimeout(() => URL.revokeObjectURL(url), 60_000)
}

export function printSalesInvoiceDocument(document: JsonMap) {
  const snapshot = map(document.snapshot)
  const company = map(snapshot.company)
  const branding = map(snapshot.branding)
  const store = map(snapshot.store)
  const customer = map(snapshot.customer)
  const totals = map(snapshot.totals)
  const invoiceNo = document.invoiceNo ?? snapshot.invoiceNo ?? 'Invoice'
  const lines = rows(snapshot.lines)
  const payments = rows(snapshot.payments)
  const deliveryFee = Number(totals.deliveryFee ?? 0)
  const deliveryFeeHtml = deliveryFee > 0 &&
    totals.deliveryFeeInvoiceDisplayMode !== 'HIDE_BREAKDOWN'
    ? `<div><span>Ongkir</span><strong>${money(deliveryFee)}</strong></div>`
    : ''
  const logo = branding.logoPublicUrl
    ? `<img class="logo" src="${escapeHtml(branding.logoPublicUrl)}" alt="Logo perusahaan">` : ''
  const lineHtml = lines.map((line, index) => `<tr><td>${index + 1}</td><td><b>${escapeHtml(line.productName)}</b><div class="muted">${escapeHtml(line.sku)}</div></td><td>${escapeHtml(line.uomName)}</td><td class="num">${quantity(line.quantity)}</td><td class="num">${money(line.unitPrice)}</td><td class="num">${money(line.discount)}</td><td class="num">${money(line.lineTotal)}</td></tr>`).join('')
  const paymentHtml = payments.map((payment) => `<div><span>${escapeHtml(payment.methodName)}</span><strong>${money(payment.amount)}</strong></div>`).join('')
  openPrint(String(invoiceNo), `<header><div>${logo}<h1>${escapeHtml(company.name ?? company.legalName)}</h1><div class="muted">${escapeHtml(company.taxId)}</div></div><div class="right"><h1>INVOICE</h1><b>${escapeHtml(invoiceNo)}</b><div>${dateTime(snapshot.transactionAt)}</div></div></header><section class="identity"><div class="box"><b>Ditagihkan kepada</b>${escapeHtml(customer.name ?? 'Walk-In Customer')}<br>${escapeHtml(customer.phone)}<br>${escapeHtml(customer.address)}</div><div class="box"><b>Lokasi transaksi</b>${escapeHtml(store.name)}<br>${escapeHtml(store.address)}<br><span class="muted">Kasir: ${escapeHtml(map(snapshot.cashier).name)}</span></div></section><table><thead><tr><th>No</th><th>Produk</th><th>UOM</th><th class="num">Qty</th><th class="num">Harga</th><th class="num">Diskon</th><th class="num">Total</th></tr></thead><tbody>${lineHtml}</tbody></table><section class="totals"><div><span>Subtotal</span><strong>${money(totals.subtotal)}</strong></div><div><span>Diskon</span><strong>${money(Number(totals.itemDiscount ?? 0) + Number(totals.orderDiscount ?? 0))}</strong></div>${deliveryFeeHtml}${paymentHtml}<div class="grand"><span>Total akhir</span><span>${money(totals.grandTotal)}</span></div></section>`)
}

export function printSalesDeliveryDocument(document: JsonMap) {
  const snapshot = map(document.snapshot)
  const company = map(snapshot.company)
  const branding = map(snapshot.branding)
  const store = map(snapshot.store)
  const recipient = map(snapshot.recipient)
  const deliveryNo = document.deliveryNo ?? 'Surat Jalan'
  const lines = rows(document.lines)
  const logo = branding.logoPublicUrl
    ? `<img class="logo" src="${escapeHtml(branding.logoPublicUrl)}" alt="Logo perusahaan">` : ''
  const lineHtml = lines.map((line, index) => `<tr><td>${index + 1}</td><td><b>${escapeHtml(line.productName)}</b><div class="muted">${escapeHtml(line.sku)}</div></td><td>${escapeHtml(line.uomName)}</td><td class="num">${quantity(line.quantity)}</td></tr>`).join('')
  openPrint(String(deliveryNo), `<header><div>${logo}<h1>${escapeHtml(company.name ?? company.legalName)}</h1><div>${escapeHtml(store.name)}</div></div><div class="right"><h1>SURAT JALAN</h1><b>${escapeHtml(deliveryNo)}</b><div>${dateTime(snapshot.scheduledAt)}</div></div></header><section class="identity"><div class="box"><b>Penerima</b>${escapeHtml(recipient.name)}<br>${escapeHtml(recipient.phone)}</div><div class="box"><b>Alamat pengiriman</b>${escapeHtml(recipient.address)}<br>${escapeHtml(snapshot.notes)}</div></section><table><thead><tr><th>No</th><th>Produk</th><th>UOM</th><th class="num">Qty</th></tr></thead><tbody>${lineHtml}</tbody></table><section class="signatures"><div>Disiapkan</div><div>Pengirim</div><div>Penerima</div></section>`)
}
