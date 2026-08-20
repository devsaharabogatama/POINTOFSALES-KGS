import type {
  SalesDeliveryDocument,
  SalesInvoiceDocument,
} from './pos'

type JsonObject = Record<string, unknown>

function objectValue(value: unknown): JsonObject {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? value as JsonObject
    : {}
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

function openPrintDocument(title: string, body: string) {
  const html = `<!doctype html><html lang="id"><head><meta charset="utf-8" />
    <meta name="viewport" content="width=device-width,initial-scale=1" />
    <title>${escapeHtml(title)}</title><style>
    *{box-sizing:border-box}body{margin:0;background:#e5e7eb;color:#17211f;font-family:Arial,sans-serif}
    main{width:min(210mm,100%);min-height:297mm;margin:0 auto;background:white;padding:16mm}
    header{display:flex;align-items:flex-start;justify-content:space-between;gap:24px;border-bottom:3px solid #0f766e;padding-bottom:18px}
    .brand{display:flex;align-items:center;gap:14px}.logo{width:56px;height:56px;object-fit:contain}.muted{color:#64748b}.right{text-align:right}
    h1{margin:0;font-size:26px}h2{margin:4px 0 0;font-size:18px}.meta{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin:22px 0}
    .card{border:1px solid #cbd5e1;border-radius:10px;padding:14px}.card strong{display:block;margin-bottom:6px}
    table{width:100%;border-collapse:collapse;margin-top:18px;font-size:13px}th{background:#f1f5f9;text-align:left}th,td{padding:10px;border-bottom:1px solid #e2e8f0}.number{text-align:right}
    .totals{width:min(390px,100%);margin:20px 0 0 auto}.row{display:flex;justify-content:space-between;gap:16px;padding:6px 0}.grand{border-top:2px solid #0f766e;margin-top:6px;padding-top:10px;font-size:18px}
    .bank{margin-top:20px;max-width:390px;background:#f5f3ff}
    footer{margin-top:36px;border-top:1px solid #cbd5e1;padding-top:14px;font-size:12px;color:#64748b}.signatures{display:grid;grid-template-columns:1fr 1fr;gap:80px;margin-top:70px;text-align:center}.signature{border-top:1px solid #475569;padding-top:8px}
    .actions{position:fixed;right:20px;bottom:20px}button{border:0;border-radius:10px;background:#0f766e;color:white;padding:12px 18px;font-weight:700;cursor:pointer}
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

function documentHeader(snapshot: JsonObject, label: string, number: string) {
  const company = objectValue(snapshot.company)
  const branding = objectValue(snapshot.branding)
  const store = objectValue(snapshot.store)
  const logo = text(branding.logoPublicUrl, '')
  return `<header><div class="brand">${logo ? `<img class="logo" src="${escapeHtml(logo)}" alt="Logo" />` : ''}<div><h1>${escapeHtml(company.legalName ?? company.name)}</h1><div class="muted">${escapeHtml(store.name)} · ${escapeHtml(store.address)}</div></div></div><div class="right"><h2>${escapeHtml(label)}</h2><strong>${escapeHtml(number)}</strong></div></header>`
}

export function openSalesInvoicePrint(document: SalesInvoiceDocument) {
  const snapshot = objectValue(document.snapshot)
  const customer = objectValue(snapshot.customer)
  const totals = objectValue(snapshot.totals)
  const company = objectValue(snapshot.company)
  const branding = objectValue(snapshot.branding)
  const lines = arrayValue(snapshot.lines)
  const payments = arrayValue(snapshot.payments)
  const showDeliveryFee =
    numberValue(totals.deliveryFee) > 0 &&
    totals.deliveryFeeInvoiceDisplayMode !== 'HIDE_BREAKDOWN'
  const rows = lines.map((line, index) => `<tr><td>${index + 1}</td><td><strong>${escapeHtml(line.productName)}</strong><div class="muted">${escapeHtml(line.sku)}</div></td><td>${quantity(line.quantity)} ${escapeHtml(line.uomName)}</td><td class="number">${rupiah(line.unitPrice)}</td><td class="number">${rupiah(line.discount)}</td><td class="number">${rupiah(line.taxAmount)}</td><td class="number"><strong>${rupiah(line.lineTotal)}</strong></td></tr>`).join('')
  const paymentRows = payments.map((payment) => `<div class="row"><span>${escapeHtml(payment.methodName)}</span><strong>${rupiah(payment.amount)}</strong></div>`).join('')
  const bank = branding.showBankAccountOnInvoice === true && company.bankName && company.bankAccountNumber && company.bankAccountHolder
    ? `<div class="card bank"><strong>Rekening pembayaran</strong>${escapeHtml(company.bankName)} · ${escapeHtml(company.bankAccountNumber)}<br/><span class="muted">a.n. ${escapeHtml(company.bankAccountHolder)}</span></div>` : ''
  openPrintDocument(`Invoice ${document.invoiceNo}`, `${documentHeader(snapshot, 'SALES INVOICE', document.invoiceNo)}
    <div class="meta"><div class="card"><strong>Ditagihkan kepada</strong>${escapeHtml(customer.name ?? 'Walk-In Customer')}<br/><span class="muted">${escapeHtml(customer.phone)}<br/>${escapeHtml(customer.address)}</span></div><div class="card"><strong>Informasi transaksi</strong>Tanggal: ${escapeHtml(dateTime(snapshot.postedAt))}<br/>Kasir: ${escapeHtml(objectValue(snapshot.cashier).name)}<br/>Terminal: ${escapeHtml(objectValue(snapshot.terminal).name)}</div></div>
    <table><thead><tr><th>No</th><th>Produk</th><th>Jumlah</th><th class="number">Harga</th><th class="number">Diskon</th><th class="number">Pajak</th><th class="number">Total</th></tr></thead><tbody>${rows}</tbody></table>
    <div class="totals"><div class="row"><span>Subtotal</span><strong>${rupiah(totals.subtotal)}</strong></div><div class="row"><span>Diskon</span><strong>${rupiah(numberValue(totals.itemDiscount) + numberValue(totals.orderDiscount))}</strong></div>${showDeliveryFee ? `<div class="row"><span>Ongkir</span><strong>${rupiah(totals.deliveryFee)}</strong></div>` : ''}<div class="row"><span>Pembulatan</span><strong>${rupiah(totals.roundingAdjustment)}</strong></div><div class="row grand"><span>Total akhir</span><strong>${rupiah(totals.grandTotal)}</strong></div>${paymentRows}</div>
    ${bank}<footer>Dokumen ini dihasilkan dari transaksi POSTED. Nomor internal sistem tidak ditampilkan.</footer>`)
}

export function openSalesDeliveryPrint(document: SalesDeliveryDocument) {
  const snapshot = objectValue(document.snapshot)
  const recipient = objectValue(snapshot.recipient)
  const lines = arrayValue(snapshot.lines)
  const rows = lines.map((line, index) => `<tr><td>${index + 1}</td><td><strong>${escapeHtml(line.productName)}</strong><div class="muted">${escapeHtml(line.sku)}</div></td><td class="number">${quantity(line.quantity)} ${escapeHtml(line.uomName)}</td></tr>`).join('')
  openPrintDocument(`Surat Jalan ${document.deliveryNo}`, `${documentHeader(snapshot, 'SURAT JALAN', document.deliveryNo)}
    <div class="meta"><div class="card"><strong>Penerima</strong>${escapeHtml(recipient.name)} · ${escapeHtml(recipient.phone)}<br/><span class="muted">${escapeHtml(recipient.address)}</span></div><div class="card"><strong>Pengiriman</strong>Invoice: ${escapeHtml(snapshot.invoiceNo)}<br/>Rencana: ${escapeHtml(dateTime(snapshot.scheduledAt))}<br/>Status: ${escapeHtml(document.status)}</div></div>
    <table><thead><tr><th>No</th><th>Barang</th><th class="number">Jumlah dikirim</th></tr></thead><tbody>${rows}</tbody></table>
    ${snapshot.notes ? `<div class="card" style="margin-top:20px"><strong>Catatan pengiriman</strong>${escapeHtml(snapshot.notes)}</div>` : ''}
    <div class="signatures"><div class="signature">Petugas pengirim</div><div class="signature">Penerima</div></div>
    <footer>Surat Jalan tidak membuat pergerakan stok atau jurnal tambahan. Stok mengikuti transaksi Sale POSTED.</footer>`)
}
