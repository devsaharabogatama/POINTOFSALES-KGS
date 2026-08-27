import type { SalesDeliveryDocument, SalesInvoiceDocument } from './pos'

type JsonObject = Record<string, unknown>

function objectValue(value: unknown): JsonObject {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? value as JsonObject : {}
}

function arrayValue(value: unknown): JsonObject[] {
  return Array.isArray(value) ? value.map(objectValue) : []
}

function text(value: unknown, fallback = '-') {
  const resolved = value === null || value === undefined ? '' : String(value)
  return resolved.trim() || fallback
}

function numberValue(value: unknown) {
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : 0
}

function escapeHtml(value: unknown) {
  return text(value, '').replace(/[&<>"']/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;',
  })[character] ?? character)
}

function rupiah(value: unknown) {
  return new Intl.NumberFormat('id-ID', {
    style: 'currency', currency: 'IDR', maximumFractionDigits: 0,
  }).format(numberValue(value))
}

function quantity(value: unknown) {
  return new Intl.NumberFormat('id-ID', { maximumFractionDigits: 6 })
    .format(numberValue(value))
}

function dateTime(value: unknown) {
  const date = new Date(text(value, ''))
  return Number.isNaN(date.getTime()) ? '-' : date.toLocaleString('id-ID')
}

function invoiceDate(snapshot: JsonObject) {
  const branding = objectValue(snapshot.branding)
  const company = objectValue(snapshot.company)
  const source = branding.invoiceDateDisplayMode === 'POSTED_DATE'
    ? snapshot.postedAt : snapshot.transactionAt
  const date = new Date(text(source, ''))
  if (Number.isNaN(date.getTime())) return '-'
  const options: Intl.DateTimeFormatOptions = {
    day: '2-digit', month: '2-digit', year: 'numeric',
    timeZone: typeof company.timezone === 'string' ? company.timezone : undefined,
  }
  try {
    return new Intl.DateTimeFormat('id-ID', options).format(date)
  } catch {
    delete options.timeZone
    return new Intl.DateTimeFormat('id-ID', options).format(date)
  }
}

function openPrintDocument(title: string, body: string) {
  const html = `<!doctype html><html lang="id"><head><meta charset="utf-8" />
    <meta name="viewport" content="width=device-width,initial-scale=1" />
    <title>${escapeHtml(title)}</title><style>
    *{box-sizing:border-box}body{margin:0;background:#e5e7eb;color:#172033;font:12px Arial,sans-serif}
    main{width:min(210mm,100%);min-height:297mm;margin:0 auto;background:white;padding:13mm}
    header{display:flex;align-items:flex-start;justify-content:space-between;gap:24px;border-bottom:2px solid #172033;padding-bottom:14px}
    .brand{display:flex;align-items:center;gap:14px}.logo{display:block;max-height:60px;max-width:150px;object-fit:contain}.muted{color:#64748b}.right{text-align:right}
    h1{margin:0 0 5px;font-size:23px}.meta{display:grid;grid-template-columns:1fr 1fr;gap:18px;margin:18px 0}
    .card{border:1px solid #dbe2ea;border-radius:8px;padding:12px}.card strong{display:block;margin-bottom:5px}
    table{width:100%;border-collapse:collapse;margin-top:14px}th{background:#f1f5f9;text-align:left;font-size:10px;text-transform:uppercase}th,td{padding:8px;border-bottom:1px solid #dbe2ea}.number{text-align:right}
    .totals{width:310px;margin:18px 0 0 auto}.row{display:flex;justify-content:space-between;gap:16px;padding:5px}.grand{border-top:2px solid #172033;font-size:15px;font-weight:700}
    .bank{margin-top:18px;max-width:390px;background:#f5f3ff}.signatures{display:grid;gap:20px;margin-top:55px;text-align:center}.signature{position:relative;min-height:75px}.signature:after{content:'';display:block;border-top:1px solid #172033;margin:55px 8px 0}.invoice-stamp{position:relative;min-height:75px;margin-top:24px}.stamp{position:absolute;left:50%;top:18px;width:82px;height:46px;transform:translateX(-50%) rotate(-7deg);border:3px double #1d4ed8;border-radius:50%;display:flex;align-items:center;justify-content:center;opacity:.58}.stamp img{max-width:66px;max-height:32px;filter:grayscale(1) sepia(1) saturate(7) hue-rotate(180deg)}
    footer{margin-top:36px;border-top:1px solid #cbd5e1;padding-top:14px;font-size:12px;color:#64748b}.actions{position:fixed;right:20px;bottom:20px}button{border:0;border-radius:10px;background:#0f766e;color:white;padding:12px 18px;font-weight:700;cursor:pointer}
    @media(max-width:700px){main{padding:20px}.meta{grid-template-columns:1fr}header{flex-direction:column}.right{text-align:left}}
    @media print{@page{size:A4;margin:0}body{background:white}main{width:210mm;min-height:297mm}.actions{display:none}}
    </style></head><body><main>${body}</main><div class="actions"><button onclick="window.print()">Cetak dokumen</button></div></body></html>`
  const url = URL.createObjectURL(new Blob([html], { type: 'text/html;charset=utf-8' }))
  const opened = window.open(url, '_blank')
  if (!opened) {
    URL.revokeObjectURL(url)
    throw new Error('POPUP_BLOCKED')
  }
  window.setTimeout(() => URL.revokeObjectURL(url), 60_000)
}

function stampMarkup(branding: JsonObject) {
  return branding.showStampOnDocuments === true && branding.logoPublicUrl
    ? `<span class="stamp"><img src="${escapeHtml(branding.logoPublicUrl)}" alt="Stempel perusahaan"/></span>` : ''
}

export function openSalesInvoicePrint(document: SalesInvoiceDocument) {
  const snapshot = objectValue(document.snapshot)
  const customer = objectValue(snapshot.customer)
  const totals = objectValue(snapshot.totals)
  const company = objectValue(snapshot.company)
  const branding = objectValue(snapshot.branding)
  const store = objectValue(snapshot.store)
  const lines = arrayValue(snapshot.lines)
  const payments = arrayValue(snapshot.payments)
  const showDeliveryFee = numberValue(totals.deliveryFee) > 0 &&
    totals.deliveryFeeInvoiceDisplayMode !== 'HIDE_BREAKDOWN'
  const logo = branding.showLogoOnDocuments !== false && branding.logoPublicUrl
    ? `<img class="logo" src="${escapeHtml(branding.logoPublicUrl)}" alt="Logo perusahaan"/>` : ''
  const stamp = stampMarkup(branding)
  const lineRows = lines.map((line, index) => `<tr><td>${index + 1}</td><td><strong>${escapeHtml(line.productName)}</strong><div class="muted">${escapeHtml(line.sku)}</div></td><td>${escapeHtml(line.uomName)}</td><td class="number">${quantity(line.quantity)}</td><td class="number">${rupiah(line.unitPrice)}</td><td class="number">${rupiah(line.discount)}</td><td class="number"><strong>${rupiah(line.lineTotal)}</strong></td></tr>`).join('')
  const paymentRows = payments.map((payment) => `<div class="row"><span>${escapeHtml(payment.methodName)}</span><strong>${rupiah(payment.amount)}</strong></div>`).join('')
  const bank = branding.showBankAccountOnInvoice === true && company.bankName && company.bankAccountNumber && company.bankAccountHolder
    ? `<div class="card bank"><strong>Rekening pembayaran</strong>${escapeHtml(company.bankName)} · ${escapeHtml(company.bankAccountNumber)}<br/><span class="muted">a.n. ${escapeHtml(company.bankAccountHolder)}</span></div>` : ''
  openPrintDocument(`Invoice ${document.invoiceNo}`, `<header><div>${logo}<div class="muted">${escapeHtml(company.taxId)}</div></div><div class="right"><h1>INVOICE</h1><b>${escapeHtml(document.invoiceNo)}</b><div>${escapeHtml(invoiceDate(snapshot))}</div></div></header>
    <section class="meta"><div class="card"><strong>Ditagihkan kepada</strong>${escapeHtml(customer.name ?? 'Walk-In Customer')}<br/>${escapeHtml(customer.phone)}<br/>${escapeHtml(customer.address)}</div><div class="card"><strong>Lokasi transaksi</strong>${escapeHtml(store.name)}<br/>${escapeHtml(store.address)}</div></section>
    <table><thead><tr><th>No</th><th>Produk</th><th>UOM</th><th class="number">Qty</th><th class="number">Harga</th><th class="number">Diskon</th><th class="number">Total</th></tr></thead><tbody>${lineRows}</tbody></table>
    <section class="totals"><div class="row"><span>Subtotal</span><strong>${rupiah(totals.subtotal)}</strong></div><div class="row"><span>Diskon</span><strong>${rupiah(numberValue(totals.itemDiscount) + numberValue(totals.orderDiscount))}</strong></div>${showDeliveryFee ? `<div class="row"><span>Ongkir</span><strong>${rupiah(totals.deliveryFee)}</strong></div>` : ''}${paymentRows}<div class="row grand"><span>Total akhir</span><strong>${rupiah(totals.grandTotal)}</strong></div></section>
    ${bank}${stamp ? `<section class="invoice-stamp">${stamp}</section>` : ''}`)
}

export function openSalesDeliveryPrint(document: SalesDeliveryDocument) {
  const snapshot = objectValue(document.snapshot)
  const branding = objectValue(snapshot.branding)
  const store = objectValue(snapshot.store)
  const recipient = objectValue(snapshot.recipient)
  const lines = arrayValue(snapshot.lines)
  const logo = branding.showLogoOnDocuments !== false && branding.logoPublicUrl
    ? `<img class="logo" src="${escapeHtml(branding.logoPublicUrl)}" alt="Logo"/>` : ''
  const lineRows = lines.map((line, index) => `<tr><td>${index + 1}</td><td><strong>${escapeHtml(line.productName)}</strong><div class="muted">${escapeHtml(line.sku)}</div></td><td class="number">${quantity(line.quantity)} ${escapeHtml(line.uomName)}</td></tr>`).join('')
  const labels = branding.deliverySignatureTemplate === 'STORE'
    ? ['Kasir', 'Ekspedisi', 'Customer']
    : ['Warehouse', 'Security', 'Driver', 'Customer']
  const stamp = stampMarkup(branding)
  const signatures = labels.map((label, index) => `<div class="signature">${escapeHtml(label)}${index === 0 ? stamp : ''}</div>`).join('')
  openPrintDocument(`Surat Jalan ${document.deliveryNo}`, `<header><div class="brand">${logo}<div><strong>${escapeHtml(store.name)}</strong><div class="muted">${escapeHtml(store.address)}</div></div></div><div class="right"><h1>SURAT JALAN</h1><strong>${escapeHtml(document.deliveryNo)}</strong></div></header>
    <section class="meta"><div class="card"><strong>Penerima</strong>${escapeHtml(recipient.name)}${text(recipient.phone, '') ? ` · ${escapeHtml(recipient.phone)}` : ''}<br/><span class="muted">${escapeHtml(text(recipient.address))}</span></div><div class="card"><strong>Pengiriman</strong>Invoice: ${escapeHtml(snapshot.invoiceNo)}<br/>Rencana: ${escapeHtml(dateTime(snapshot.scheduledAt))}<br/>Status: ${escapeHtml(document.status)}</div></section>
    <table><thead><tr><th>No</th><th>Barang</th><th class="number">Jumlah dikirim</th></tr></thead><tbody>${lineRows}</tbody></table>
    ${snapshot.notes ? `<div class="card" style="margin-top:20px"><strong>Catatan pengiriman</strong>${escapeHtml(snapshot.notes)}</div>` : ''}
    <section class="signatures" style="grid-template-columns:repeat(${labels.length},1fr)">${signatures}</section>
    <footer>Surat Jalan tidak membuat pergerakan stok atau jurnal tambahan. Stok mengikuti transaksi Sale POSTED.</footer>`)
}
