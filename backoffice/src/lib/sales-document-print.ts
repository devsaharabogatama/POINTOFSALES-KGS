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

function safeFilePart(value: unknown, fallback: string) {
  const normalized = String(value ?? '')
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-zA-Z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 64)
    .toUpperCase()
  return normalized || fallback
}

function documentFileName(customerName: unknown, documentNo: unknown, type: 'INV' | 'SJ') {
  return `${safeFilePart(customerName, 'PELANGGAN-UMUM')}_${safeFilePart(documentNo, type)}.pdf`
}

type PdfDocument = import('jspdf').jsPDF

function pdfMoney(value: unknown) {
  return new Intl.NumberFormat('id-ID', { maximumFractionDigits: 0 })
    .format(Number(value) || 0)
}

function drawPdfHeader(doc: PdfDocument, title: string, number: unknown) {
  doc.setFont('helvetica', 'bold')
  doc.setFontSize(18)
  doc.text(title, 196, 17, { align: 'right' })
  doc.setFontSize(10)
  doc.text(String(number ?? '-'), 196, 24, { align: 'right' })
  doc.setDrawColor(30, 41, 59)
  doc.setLineWidth(0.7)
  doc.line(14, 29, 196, 29)
}

async function drawPdfLogo(doc: PdfDocument, logoUrl: unknown, enabled: boolean) {
  if (!enabled || !logoUrl) return
  try {
    const response = await fetch(String(logoUrl), { cache: 'force-cache' })
    if (!response.ok) return
    const blob = await response.blob()
    const dataUrl = await new Promise<string>((resolve, reject) => {
      const reader = new FileReader()
      reader.onload = () => resolve(String(reader.result))
      reader.onerror = () => reject(reader.error)
      reader.readAsDataURL(blob)
    })
    const image = doc.getImageProperties(dataUrl)
    const scale = Math.min(45 / image.width, 18 / image.height)
    doc.addImage(dataUrl, blob.type.includes('png') ? 'PNG'
      : blob.type.includes('webp') ? 'WEBP' : 'JPEG', 14, 8,
    image.width * scale, image.height * scale)
  } catch {
    // A document remains printable when a historical logo object is unavailable.
  }
}

async function drawPdfStamp(
  doc: PdfDocument, logoUrl: unknown, enabled: boolean, y: number,
) {
  if (!enabled || !logoUrl) return
  try {
    const response = await fetch(String(logoUrl), { cache: 'force-cache' })
    if (!response.ok) return
    const bitmap = await createImageBitmap(await response.blob())
    const scale = Math.min(1, 600 / Math.max(bitmap.width, bitmap.height))
    const canvas = window.document.createElement('canvas')
    canvas.width = Math.max(1, Math.round(bitmap.width * scale))
    canvas.height = Math.max(1, Math.round(bitmap.height * scale))
    const context = canvas.getContext('2d')
    if (!context) {
      bitmap.close()
      return
    }
    context.globalAlpha = 0.56
    context.drawImage(bitmap, 0, 0, canvas.width, canvas.height)
    context.globalCompositeOperation = 'source-in'
    context.fillStyle = '#1d4ed8'
    context.fillRect(0, 0, canvas.width, canvas.height)
    bitmap.close()
    const dataUrl = canvas.toDataURL('image/png')
    const image = doc.getImageProperties(dataUrl)
    const imageScale = Math.min(29 / image.width, 10 / image.height)
    doc.setDrawColor(29, 78, 216)
    doc.setLineWidth(0.55)
    doc.ellipse(36, y + 13, 18, 10)
    doc.setLineWidth(0.25)
    doc.ellipse(36, y + 13, 16.5, 8.5)
    doc.addImage(dataUrl, 'PNG', 36 - image.width * imageScale / 2,
      y + 13 - image.height * imageScale / 2,
      image.width * imageScale, image.height * imageScale,
      undefined, 'FAST', -7)
  } catch {
    // A historical document stays printable if its logo cannot be transformed.
  }
}

function drawPdfSignatures(doc: PdfDocument, requestedY: number) {
  let y = requestedY
  if (y > 250) {
    doc.addPage()
    y = 25
  }
  const signatures = [
    { label: 'Warehouse', x: 36 }, { label: 'Security', x: 82 },
    { label: 'Driver', x: 128 }, { label: 'Customer', x: 174 },
  ]
  doc.setFont('helvetica', 'normal')
  doc.setFontSize(9)
  for (const signature of signatures) {
    doc.text(signature.label, signature.x, y, { align: 'center' })
    doc.line(signature.x - 17, y + 24, signature.x + 17, y + 24)
  }
  return y
}

type PdfColumn = { text: string; x: number; align?: 'left' | 'right' }

function drawPdfTableHeader(doc: PdfDocument, y: number, labels: PdfColumn[]) {
  doc.setFillColor(241, 245, 249)
  doc.rect(14, y - 5, 182, 8, 'F')
  doc.setFont('helvetica', 'bold')
  doc.setFontSize(8)
  for (const label of labels) doc.text(label.text, label.x, y, { align: label.align ?? 'left' })
}

function ensurePdfPage(doc: PdfDocument, y: number, redraw: (nextY: number) => void) {
  if (y <= 275) return y
  doc.addPage()
  redraw(17)
  return 27
}

export async function downloadSalesInvoicePdf(
  document: JsonMap,
  customerFileName?: string,
  showLogo = true,
  showStamp = false,
) {
  const { jsPDF } = await import('jspdf')
  const doc = new jsPDF({ unit: 'mm', format: 'a4', compress: true })
  const snapshot = map(document.snapshot)
  const branding = map(snapshot.branding)
  const store = map(snapshot.store)
  const customer = map(snapshot.customer)
  const totals = map(snapshot.totals)
  const invoiceNo = document.invoiceNo ?? snapshot.invoiceNo ?? 'INV'
  const lines = rows(snapshot.lines)
  const payments = rows(snapshot.payments)
  drawPdfHeader(doc, 'INVOICE', invoiceNo)
  await drawPdfLogo(doc, branding.logoPublicUrl, showLogo)
  doc.setFont('helvetica', 'normal')
  doc.setFontSize(9)
  doc.text(`Customer: ${String(customer.name ?? customerFileName ?? 'Pelanggan Umum')}`, 14, 38)
  doc.text(`Toko: ${String(store.name ?? '-')}`, 14, 44)
  doc.text(`Tanggal: ${dateTime(snapshot.transactionAt)}`, 14, 50)
  const columns: PdfColumn[] = [
    { text: 'PRODUK', x: 16 }, { text: 'UOM', x: 94 },
    { text: 'QTY', x: 124, align: 'right' }, { text: 'HARGA', x: 159, align: 'right' },
    { text: 'TOTAL', x: 194, align: 'right' },
  ]
  drawPdfTableHeader(doc, 61, columns)
  let y = 70
  for (const line of lines) {
    y = ensurePdfPage(doc, y, (nextY) => drawPdfTableHeader(doc, nextY, columns))
    doc.setFont('helvetica', 'normal')
    doc.setFontSize(8.5)
    const name = doc.splitTextToSize(String(line.productName ?? '-'), 72) as string[]
    doc.text(name, 16, y)
    doc.text(String(line.uomName ?? '-'), 94, y)
    doc.text(quantity(line.quantity), 124, y, { align: 'right' })
    doc.text(pdfMoney(line.unitPrice), 159, y, { align: 'right' })
    doc.text(pdfMoney(line.lineTotal), 194, y, { align: 'right' })
    y += Math.max(7, name.length * 4.5)
    doc.setDrawColor(226, 232, 240)
    doc.line(14, y - 3, 196, y - 3)
  }
  y = ensurePdfPage(doc, y + 4, () => undefined)
  const totalRows: Array<[string, unknown]> = [
    ['Subtotal', totals.subtotal],
    ['Diskon', Number(totals.itemDiscount ?? 0) + Number(totals.orderDiscount ?? 0)],
  ]
  if (Number(totals.deliveryFee ?? 0) > 0 && totals.deliveryFeeInvoiceDisplayMode !== 'HIDE_BREAKDOWN') totalRows.push(['Ongkir', totals.deliveryFee])
  for (const payment of payments) totalRows.push([String(payment.methodName ?? 'Pembayaran'), payment.amount])
  totalRows.push(['TOTAL AKHIR', totals.grandTotal])
  for (const [label, value] of totalRows) {
    doc.setFont('helvetica', label === 'TOTAL AKHIR' ? 'bold' : 'normal')
    doc.text(label, 142, y)
    doc.text(pdfMoney(value), 194, y, { align: 'right' })
    y += 6
  }
  const signatureY = drawPdfSignatures(doc, y + 14)
  await drawPdfStamp(doc, branding.logoPublicUrl, showStamp, signatureY)
  doc.save(documentFileName(customerFileName ?? customer.name, invoiceNo, 'INV'))
}

async function buildSalesDeliveryPdf(
  document: JsonMap,
  customerFileName?: string,
  showLogo = true,
  showStamp = false,
) {
  const { jsPDF } = await import('jspdf')
  const doc = new jsPDF({ unit: 'mm', format: 'a4', compress: true })
  const snapshot = map(document.snapshot)
  const branding = map(snapshot.branding)
  const store = map(snapshot.store)
  const recipient = map(snapshot.recipient)
  const deliveryNo = document.deliveryNo ?? 'SJ'
  const lines = rows(document.lines)
  drawPdfHeader(doc, 'SURAT JALAN', deliveryNo)
  await drawPdfLogo(doc, branding.logoPublicUrl, showLogo)
  doc.setFont('helvetica', 'normal')
  doc.setFontSize(9)
  doc.text(`Customer: ${String(customerFileName ?? recipient.name ?? 'Pelanggan Umum')}`, 14, 38)
  doc.text(`Penerima: ${String(recipient.name ?? '-')}`, 14, 44)
  doc.text(`Telepon: ${String(recipient.phone ?? '-')}`, 14, 50)
  const address = doc.splitTextToSize(`Alamat: ${String(recipient.address ?? '-')}`, 180) as string[]
  doc.text(address, 14, 56)
  doc.text(`Toko: ${String(store.name ?? '-')}`, 14, 56 + address.length * 4.5)
  const tableY = 67 + address.length * 4.5
  const columns: PdfColumn[] = [
    { text: 'PRODUK', x: 16 }, { text: 'SKU', x: 108 },
    { text: 'UOM', x: 152 }, { text: 'QTY', x: 194, align: 'right' },
  ]
  drawPdfTableHeader(doc, tableY, columns)
  let y = tableY + 9
  for (const line of lines) {
    y = ensurePdfPage(doc, y, (nextY) => drawPdfTableHeader(doc, nextY, columns))
    doc.setFont('helvetica', 'normal')
    doc.setFontSize(8.5)
    const name = doc.splitTextToSize(String(line.productName ?? '-'), 86) as string[]
    doc.text(name, 16, y)
    doc.text(String(line.sku ?? '-'), 108, y)
    doc.text(String(line.uomName ?? '-'), 152, y)
    doc.text(quantity(line.quantity), 194, y, { align: 'right' })
    y += Math.max(7, name.length * 4.5)
    doc.setDrawColor(226, 232, 240)
    doc.line(14, y - 3, 196, y - 3)
  }
  const signatureY = drawPdfSignatures(doc, y + 15)
  await drawPdfStamp(doc, branding.logoPublicUrl, showStamp, signatureY)
  return {
    doc,
    fileName: documentFileName(customerFileName ?? recipient.name, deliveryNo, 'SJ'),
  }
}

export async function createSalesDeliveryPdfFile(
  document: JsonMap,
  customerFileName?: string,
  showLogo = true,
  showStamp = false,
) {
  const { doc, fileName } = await buildSalesDeliveryPdf(
    document, customerFileName, showLogo, showStamp,
  )
  return { fileName, data: new Uint8Array(doc.output('arraybuffer')) }
}

export async function downloadSalesDeliveryPdf(
  document: JsonMap,
  customerFileName?: string,
  showLogo = true,
  showStamp = false,
) {
  const { doc, fileName } = await buildSalesDeliveryPdf(
    document, customerFileName, showLogo, showStamp,
  )
  doc.save(fileName)
}

function openPrint(title: string, body: string) {
  const html = `<!doctype html><html lang="id"><head><meta charset="utf-8"><title>${escapeHtml(title)}</title><style>
    @page{size:A4;margin:13mm}*{box-sizing:border-box}body{font:12px Arial,sans-serif;color:#172033;margin:0}header{display:flex;justify-content:space-between;gap:24px;border-bottom:2px solid #172033;padding-bottom:14px}h1{font-size:23px;margin:0 0 5px}.muted{color:#64748b}.right{text-align:right}.identity{display:grid;grid-template-columns:1fr 1fr;gap:18px;margin:18px 0}.box{border:1px solid #dbe2ea;border-radius:8px;padding:12px}.box b{display:block;margin-bottom:5px}table{border-collapse:collapse;width:100%;margin-top:14px}th,td{padding:8px;border-bottom:1px solid #dbe2ea;text-align:left}th{background:#f1f5f9;font-size:10px;text-transform:uppercase}.num{text-align:right}.totals{margin:18px 0 0 auto;width:310px}.totals div{display:flex;justify-content:space-between;padding:5px}.grand{font-size:15px;font-weight:700;border-top:2px solid #172033}.signatures{display:grid;grid-template-columns:repeat(4,1fr);gap:20px;margin-top:55px;text-align:center}.signature{position:relative;min-height:75px}.signature:after{content:'';display:block;border-top:1px solid #172033;margin:55px 8px 0}.stamp{position:absolute;left:50%;top:18px;width:82px;height:46px;transform:translateX(-50%) rotate(-7deg);border:3px double #1d4ed8;border-radius:50%;display:flex;align-items:center;justify-content:center;opacity:.58}.stamp img{max-width:66px;max-height:32px;filter:grayscale(1) sepia(1) saturate(7) hue-rotate(180deg)}img.logo{display:block;max-height:60px;max-width:150px;margin-bottom:8px}@media print{button{display:none}}
  </style></head><body>${body}<script>window.addEventListener('load',()=>{setTimeout(()=>window.print(),250)})</script></body></html>`
  const url = URL.createObjectURL(new Blob([html], { type: 'text/html;charset=utf-8' }))
  const printWindow = window.open(url, '_blank')
  if (!printWindow) {
    URL.revokeObjectURL(url)
    throw new Error('Popup diblokir browser. Izinkan popup untuk mencetak dokumen.')
  }
  window.setTimeout(() => URL.revokeObjectURL(url), 60_000)
}

export function printSalesInvoiceDocument(
  document: JsonMap, showLogo = true, showStamp = false,
) {
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
  const logo = showLogo && branding.logoPublicUrl
    ? `<img class="logo" src="${escapeHtml(branding.logoPublicUrl)}" alt="Logo perusahaan">` : ''
  const stamp = showStamp && branding.logoPublicUrl
    ? `<span class="stamp"><img src="${escapeHtml(branding.logoPublicUrl)}" alt="Stempel perusahaan"></span>` : ''
  const lineHtml = lines.map((line, index) => `<tr><td>${index + 1}</td><td><b>${escapeHtml(line.productName)}</b><div class="muted">${escapeHtml(line.sku)}</div></td><td>${escapeHtml(line.uomName)}</td><td class="num">${quantity(line.quantity)}</td><td class="num">${money(line.unitPrice)}</td><td class="num">${money(line.discount)}</td><td class="num">${money(line.lineTotal)}</td></tr>`).join('')
  const paymentHtml = payments.map((payment) => `<div><span>${escapeHtml(payment.methodName)}</span><strong>${money(payment.amount)}</strong></div>`).join('')
  openPrint(String(invoiceNo), `<header><div>${logo}<div class="muted">${escapeHtml(company.taxId)}</div></div><div class="right"><h1>INVOICE</h1><b>${escapeHtml(invoiceNo)}</b><div>${dateTime(snapshot.transactionAt)}</div></div></header><section class="identity"><div class="box"><b>Ditagihkan kepada</b>${escapeHtml(customer.name ?? 'Walk-In Customer')}<br>${escapeHtml(customer.phone)}<br>${escapeHtml(customer.address)}</div><div class="box"><b>Lokasi transaksi</b>${escapeHtml(store.name)}<br>${escapeHtml(store.address)}<br><span class="muted">Kasir: ${escapeHtml(map(snapshot.cashier).name)}</span></div></section><table><thead><tr><th>No</th><th>Produk</th><th>UOM</th><th class="num">Qty</th><th class="num">Harga</th><th class="num">Diskon</th><th class="num">Total</th></tr></thead><tbody>${lineHtml}</tbody></table><section class="totals"><div><span>Subtotal</span><strong>${money(totals.subtotal)}</strong></div><div><span>Diskon</span><strong>${money(Number(totals.itemDiscount ?? 0) + Number(totals.orderDiscount ?? 0))}</strong></div>${deliveryFeeHtml}${paymentHtml}<div class="grand"><span>Total akhir</span><span>${money(totals.grandTotal)}</span></div></section><section class="signatures"><div class="signature">Warehouse${stamp}</div><div class="signature">Security</div><div class="signature">Driver</div><div class="signature">Customer</div></section>`)
}

export function printSalesDeliveryDocument(
  document: JsonMap, showLogo = true, showStamp = false,
) {
  const snapshot = map(document.snapshot)
  const branding = map(snapshot.branding)
  const store = map(snapshot.store)
  const recipient = map(snapshot.recipient)
  const deliveryNo = document.deliveryNo ?? 'Surat Jalan'
  const lines = rows(document.lines)
  const logo = showLogo && branding.logoPublicUrl
    ? `<img class="logo" src="${escapeHtml(branding.logoPublicUrl)}" alt="Logo perusahaan">` : ''
  const stamp = showStamp && branding.logoPublicUrl
    ? `<span class="stamp"><img src="${escapeHtml(branding.logoPublicUrl)}" alt="Stempel perusahaan"></span>` : ''
  const lineHtml = lines.map((line, index) => `<tr><td>${index + 1}</td><td><b>${escapeHtml(line.productName)}</b><div class="muted">${escapeHtml(line.sku)}</div></td><td>${escapeHtml(line.uomName)}</td><td class="num">${quantity(line.quantity)}</td></tr>`).join('')
  openPrint(String(deliveryNo), `<header><div>${logo}<div>${escapeHtml(store.name)}</div></div><div class="right"><h1>SURAT JALAN</h1><b>${escapeHtml(deliveryNo)}</b><div>${dateTime(snapshot.scheduledAt)}</div></div></header><section class="identity"><div class="box"><b>Penerima</b>${escapeHtml(recipient.name)}<br>${escapeHtml(recipient.phone)}</div><div class="box"><b>Alamat pengiriman</b>${escapeHtml(recipient.address)}<br>${escapeHtml(snapshot.notes)}</div></section><table><thead><tr><th>No</th><th>Produk</th><th>UOM</th><th class="num">Qty</th></tr></thead><tbody>${lineHtml}</tbody></table><section class="signatures"><div class="signature">Warehouse${stamp}</div><div class="signature">Security</div><div class="signature">Driver</div><div class="signature">Customer</div></section>`)
}
