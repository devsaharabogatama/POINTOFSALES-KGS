type SalesReturnPrintDocument = {
  returnNo: string
  sourceInvoiceNo: string
  customerName: string
  storeName: string
  postedAt: string | null
  postedBy: string
  notes: string | null
  refundBeforeRounding: number | string
  roundingAdjustment: number | string
  refundTotal: number | string
}

type SalesReturnPrintLine = {
  productSku: string
  productName: string
  uomName: string
  quantity: number | string
  condition: string
  refundAmount: number | string
}

type SalesReturnPrintRefund = {
  methodName: string
  methodType: string
  amount: number | string
  transferDestination: string | null
  transferReference: string | null
  proofUrl: string | null
}

export type SalesReturnPrintInput = {
  document: SalesReturnPrintDocument
  lines: SalesReturnPrintLine[]
  refunds: SalesReturnPrintRefund[]
}

function escapeHtml(value: unknown) {
  return String(value ?? '').replace(/[&<>'"]/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;',
  })[character] ?? character)
}

function rupiah(value: number | string) {
  return new Intl.NumberFormat('id-ID', {
    style: 'currency', currency: 'IDR', maximumFractionDigits: 0,
  }).format(Number(value) || 0)
}

function quantity(value: number | string) {
  return new Intl.NumberFormat('id-ID', { maximumFractionDigits: 6 })
    .format(Number(value) || 0)
}

function dateTime(value: string | null) {
  return value ? new Date(value).toLocaleString('id-ID') : '-'
}

export function salesReturnNoteHtml(input: SalesReturnPrintInput) {
  const { document, lines, refunds } = input
  const lineRows = lines.map((line) => `<tr>
    <td><b>${escapeHtml(line.productName)}</b><small>${escapeHtml(line.productSku)}</small></td>
    <td>${escapeHtml(line.condition)}</td>
    <td class="number">${escapeHtml(quantity(line.quantity))} ${escapeHtml(line.uomName)}</td>
    <td class="number">${escapeHtml(rupiah(line.refundAmount))}</td>
  </tr>`).join('')
  const refundRows = refunds.map((refund) => {
    const transferMetadata = [
      refund.transferDestination
        ? `Tujuan: ${escapeHtml(refund.transferDestination)}` : '',
      refund.transferReference
        ? `Referensi: ${escapeHtml(refund.transferReference)}` : '',
    ].filter(Boolean).join(' · ')
    const transferDetails = refund.methodType === 'TRANSFER'
      ? `<small>${transferMetadata || 'Detail transfer tidak dicatat'}</small>`
      : '<small>Tunai · tidak memerlukan tujuan transfer</small>'
    const proof = refund.methodType === 'TRANSFER' && refund.proofUrl
      ? `<small>Bukti: ${escapeHtml(refund.proofUrl)}</small>` : ''
    return `<div class="refund-row"><div><b>${escapeHtml(refund.methodName)}</b>${transferDetails}${proof}</div><strong>${escapeHtml(rupiah(refund.amount))}</strong></div>`
  }).join('')

  return `<!doctype html><html lang="id"><head><meta charset="utf-8"><title>${escapeHtml(document.returnNo)}</title><style>
    @page{size:A4;margin:13mm}*{box-sizing:border-box}body{font:12px Arial,sans-serif;color:#172033;margin:0}header{display:flex;justify-content:space-between;gap:24px;border-bottom:2px solid #172033;padding-bottom:14px}h1{font-size:23px;margin:0 0 5px}.muted{color:#64748b}.right{text-align:right}.identity{display:grid;grid-template-columns:1fr 1fr;gap:18px;margin:18px 0}.box{border:1px solid #dbe2ea;border-radius:8px;padding:12px}.box b{display:block;margin-bottom:5px}table{border-collapse:collapse;width:100%;margin-top:14px}th,td{padding:8px;border-bottom:1px solid #dbe2ea;text-align:left}th{background:#f1f5f9;font-size:10px;text-transform:uppercase}.number{text-align:right}small{display:block;color:#64748b;margin-top:3px}.refunds{margin-top:18px;border:1px solid #dbe2ea;border-radius:8px;padding:12px}.refund-row{display:flex;justify-content:space-between;gap:24px;padding:8px 0;border-bottom:1px solid #e2e8f0}.refund-row:last-child{border-bottom:0}.totals{margin:18px 0 0 auto;width:310px}.totals div{display:flex;justify-content:space-between;padding:5px}.grand{font-size:15px;font-weight:700;border-top:2px solid #172033}.notes{margin-top:18px;border:1px solid #dbe2ea;border-radius:8px;padding:12px}.status{display:inline-block;border-radius:999px;background:#dcfce7;color:#166534;padding:5px 9px;font-size:10px;font-weight:700}.actions{margin-top:24px;text-align:right}.actions button{border:0;border-radius:8px;background:#059669;color:white;padding:10px 16px;font-weight:700}@media print{.actions{display:none}}
  </style></head><body>
    <header><div><p class="muted">NOTA RETURN PENJUALAN</p><h1>${escapeHtml(document.returnNo)}</h1><span class="status">SUDAH DIPOSTING</span></div><div class="right"><b>${escapeHtml(document.storeName)}</b><p class="muted">${escapeHtml(dateTime(document.postedAt))}</p></div></header>
    <section class="identity"><div class="box"><b>Customer</b>${escapeHtml(document.customerName)}</div><div class="box"><b>Invoice asal</b>${escapeHtml(document.sourceInvoiceNo)}</div></section>
    <table><thead><tr><th>Barang</th><th>Kondisi</th><th class="number">Jumlah</th><th class="number">Refund</th></tr></thead><tbody>${lineRows}</tbody></table>
    <section class="refunds"><b>Metode refund aktual</b>${refundRows}</section>
    <section class="totals"><div><span>Sebelum pembulatan</span><b>${escapeHtml(rupiah(document.refundBeforeRounding))}</b></div><div><span>Penyesuaian</span><b>${escapeHtml(rupiah(document.roundingAdjustment))}</b></div><div class="grand"><span>Total refund</span><b>${escapeHtml(rupiah(document.refundTotal))}</b></div></section>
    ${document.notes ? `<section class="notes"><b>Catatan</b><p>${escapeHtml(document.notes)}</p></section>` : ''}
    <p class="muted">Diposting oleh ${escapeHtml(document.postedBy)}. Nota ini memakai snapshot Return final dan tidak mengubah transaksi.</p>
    <div class="actions"><button type="button" onclick="window.print()">Cetak Nota Return</button></div>
    <script>window.addEventListener('load',()=>setTimeout(()=>window.print(),250))</script>
  </body></html>`
}

export function printSalesReturnNote(input: SalesReturnPrintInput) {
  const html = salesReturnNoteHtml(input)
  const url = URL.createObjectURL(new Blob([html], {
    type: 'text/html;charset=utf-8',
  }))
  const printWindow = window.open(url, '_blank')
  if (!printWindow) {
    URL.revokeObjectURL(url)
    throw new Error('Popup diblokir browser. Izinkan popup untuk mencetak Nota Return.')
  }
  window.setTimeout(() => URL.revokeObjectURL(url), 60_000)
}
