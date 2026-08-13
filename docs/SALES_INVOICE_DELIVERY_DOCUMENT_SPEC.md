# Sales Invoice dan Surat Jalan Canonical

**Status:** APPROVED CONTRACT — SLD-1; SLD-2 foundation READY FOR MANUAL DATABASE ROLLOUT  
**Tanggal:** 2026-08-11  
**Scope:** dokumen cetak dari Sale POS v1; bukan e-Faktur dan bukan Logistics
advanced

## 1. Tujuan dan Source of Truth

Dokumen penjualan harus dapat dibaca manusia, tenant-scoped, dapat dicetak
ulang, dan tetap merepresentasikan keadaan saat transaksi final. Kontrak ini
tidak membuat transaksi komersial kedua:

- `sales_headers` berstatus `POSTED` tetap menjadi satu-satunya source of truth
  untuk nilai Sales Invoice;
- nomor Sales Invoice tetap memakai `sales_headers.invoice_no` existing;
- Surat Jalan hanya merupakan dokumen pemenuhan untuk Sale dengan
  `fulfillment_mode = 'DELIVERY'`;
- penerbitan, print, reprint, dispatch, atau delivered tidak membuat Stock
  Movement, Payment, AR, Tax, atau Financial Event tambahan;
- koreksi nilai/barang tetap melalui Sales Return atau mekanisme koreksi yang
  sudah canonical, bukan edit/delete dokumen final.

## 2. Sales Invoice

### 2.1 Identitas dan lifecycle

- Identitas internal tetap UUID dan tidak ditampilkan sebagai nomor dokumen.
- Identitas manusia adalah `invoice_no` existing, unik per Company.
- Satu Sale POSTED mempunyai tepat satu snapshot Sales Invoice versi final.
- Sale DRAFT/CANCELED tidak boleh mempunyai Sales Invoice final.
- Reprint membaca snapshot yang sama; reprint tidak membuat versi transaksi
  baru dan tidak mengubah total.
- Sales Return menyimpan referensi `source_sales_id` dan
  `source_invoice_no_snapshot`; Invoice asal tidak dimutasi.

### 2.2 Snapshot minimum

Snapshot final wajib menyimpan nilai, bukan hanya UUID:

- Company: nama tampilan, legal name bila ada, tax ID bila ada, timezone,
  currency, versi/checksum/path logo opsional;
- Store dan sumber stock: nama Store, alamat Store, nama Warehouse;
- transaksi: invoice number, Sale ID internal, tanggal transaksi/posting,
  channel `ONLINE`/`OFFLINE`, cashier dan terminal display name;
- Customer: nama, kode manusia, telepon, alamat, dan identitas induk bila ada;
- tempo: flag TEMPO dan due date;
- line komersial: SKU, nama Product, nama UOM, quantity UOM, conversion factor,
  base quantity, unit price, discount, tax code/name/rate/mode, tax amount, dan
  line total;
- Payment: nama/type metode, amount, fee, surcharge, tender, change, serta
  reference/proof yang memang boleh dicetak;
- total: subtotal, item/order discount, tax, rounding, grand total, paid,
  receivable, Customer Balance usage/credit bila ada.

Bundle dicetak sebagai line komersial yang dibeli Customer. Komponen Bundle
tetap berada pada allocation/stock evidence dan tidak menggantikan line Invoice.

### 2.3 Backfill historis

Sale POSTED existing tidak boleh diberi kesan memiliki snapshot identitas
historis yang sebelumnya tidak pernah disimpan. Pada SLD-2:

- angka dan line memakai snapshot transaksi existing;
- identitas master yang belum tersimpan ditangkap sekali saat cutover;
- snapshot diberi provenance `LEGACY_CUTOVER`, `captured_at`, dan versi kontrak;
- data yang memang tidak tersedia ditampilkan kosong/label legacy, bukan
  direkonstruksi secara spekulatif;
- setelah dibuat, snapshot immutable.

## 3. Surat Jalan

### 3.1 Kapan dibuat

- Default checkout adalah `PICKUP` dan tidak membuat Surat Jalan.
- `DELIVERY` wajib mempunyai penerima, telepon, alamat, dan sedikitnya satu
  line sebelum Sale dapat POSTED.
- Customer Walk-In boleh DELIVERY apabila data penerima eksplisit diisi.
- Surat Jalan dibuat atomically bersama POST Sale online maupun replay offline.
  Kegagalan pembuatan dokumen menyebabkan posting Sale fail-closed.
- Retry dengan posting key yang sama mengembalikan dokumen sama, tidak membuat
  nomor atau row kedua.

### 3.2 Nomor manusia dan uniqueness

Format canonical: `SJ/YYYY/MM/NNNNNN`, misalnya `SJ/2026/08/000001`.

- sequence dialokasikan server-side per Company dan bulan;
- unik `(company_id, delivery_no)`;
- satu Sale hanya dapat mempunyai satu Surat Jalan canonical;
- UUID tetap internal dan tidak ditampilkan sebagai nomor utama.

### 3.3 Snapshot dan lifecycle

Snapshot minimum:

- Company branding dan identitas versi final;
- Sale/Invoice number, Store, Warehouse, tanggal dibuat dan rencana kirim;
- Customer dan penerima, telepon, alamat, catatan;
- line komersial: SKU, Product name, quantity, UOM name;
- area tanda tangan/tanda terima tanpa nilai harga.

Status bisnis minimal:

1. `READY` — otomatis dibuat bersama Sale POSTED;
2. `DISPATCHED` — barang diserahkan untuk pengiriman;
3. `DELIVERED` — penerima mengonfirmasi penerimaan;
4. `CANCELED` — koreksi administratif sebelum dispatch, wajib alasan dan audit.

Print/reprint adalah audit action, bukan status. Transisi mundur dilarang.
Cancel tidak membatalkan Sale atau mengembalikan stock; koreksi barang tetap
melalui Sales Return.

## 4. Atomicity, Security, dan Audit

- Browser tidak mendapat `INSERT/UPDATE/DELETE` langsung pada snapshot,
  delivery document, line, counter, atau audit.
- Create/read/status/reprint melalui guarded RPC/API yang memvalidasi active
  Company, membership/role, Store scope, source Sale, version, dan status.
- Mutasi status menggunakan optimistic `master_version` dan audit before/after.
- nomor Invoice/Surat Jalan dan idempotency key dialokasikan server-side.
- seluruh FK operasional memakai pasangan Company + ID untuk mencegah
  cross-tenant reference.
- satu transaksi database meliputi POST Sale dan pembuatan snapshot/delivery.
- mutation SLD tidak menulis `stock_movements`, `sales_payments`,
  `financial_events`, atau journal baru.

## 5. Online, Offline, Return, dan Retention

- payload Draft/offline versi lama tanpa field fulfillment dianggap `PICKUP`
  agar backward-compatible;
- payload DELIVERY offline wajib membawa snapshot penerima/alamat; server tetap
  memvalidasi ulang pada sync;
- Invoice memakai nilai resolved server saat sync, bukan nilai cache mentah;
- Return dapat menampilkan nomor Invoice/Surat Jalan asal, tetapi tidak mengubah
  snapshot dokumen asal;
- snapshot final dan audit disimpan selama Sale history dipertahankan;
- object logo versi yang direferensikan snapshot final wajib dipertahankan.
  Replace/remove branding hanya boleh menghapus object yang belum direferensikan
  dokumen final. Ini adalah blocker implementasi cleanup yang wajib ditutup pada
  SLD-2.

## 6. Batas SLD-1 dan Acceptance SLD-2

SLD-1 hanya menghasilkan contract, diagnostic SELECT-only, dan runbook. SLD-2
baru boleh membuat migration setelah seluruh `BLOCKER` preflight bernilai nol.

Audit execution path existing:

- `pwa/src/lib/pos.ts::loadReceipt` membaca `sales_headers.receipt_snapshot`
  tenant-scoped;
- `pwa/src/lib/printer.ts` membuka browser fallback memakai `window.open` pada
  tab baru dan memanggil print dialog, sehingga tidak melakukan download paksa;
- template existing masih struk thermal dan memuat label Company/Store/Cashier
  hard-coded. Template ini bukan Sales Invoice formal dan tidak boleh dijadikan
  sumber snapshot identitas;
- SLD-3 harus mempertahankan struk existing untuk kasir sambil menambah template
  Invoice A4/print dan Surat Jalan dari snapshot canonical.

SLD-2 wajib membuktikan:

1. Pickup POST menghasilkan satu Invoice snapshot dan nol Surat Jalan;
2. Delivery POST menghasilkan satu Invoice dan satu Surat Jalan;
3. retry/concurrent POST menghasilkan identitas yang sama;
4. online dan offline replay memakai contract sama;
5. Bundle, split payment, TEMPO, Customer Balance, dan Walk-In valid;
6. Return tetap menunjuk Invoice asal;
7. cross-Company read/write ditolak;
8. direct browser write ditolak;
9. print/reprint tidak mengubah Stock/Payment/Finance;
10. logo/no-logo serta referenced-logo retention PASS.

## 7. Di Luar Scope

- e-Faktur, nomor seri pajak pemerintah, tanda tangan digital tersertifikasi;
- route optimization, fleet, kurir, GPS, ongkir marketplace, proof of delivery
  advanced;
- inter-Company automatic Sales/Purchase document pairing;
- perubahan FIFO/HPP atau logistics advanced.

## 8. Revisi Approved 2026-08-11 — Final Checkout dan Ongkir

Pilihan delivery dipindahkan dari cart utama ke confirmation step sebelum
payment/POST. Customer terpilih menjadi default recipient, phone, dan address;
Walk-In tetap wajib diisi eksplisit. Ongkir opsional menjadi nilai
server-authoritative yang ikut grand total, payment/AR/Customer Balance,
offline replay, Invoice snapshot, Financial Event, dan jurnal pendapatan ongkir.

Opsi menampilkan ongkir pada Invoice hanya mengatur breakdown Customer. Total
final dan pencatatan internal tetap sama. Biaya kurir aktual tetap Expense
terpisah. Implementasi dibagi SLD-R1 sampai SLD-R4 pada
`SLD_DELIVERY_FEE_REVISION_PLAN.md`; UAT SLD-3 lama ditahan sampai revisi ini
selesai. Tax dan refund ongkir wajib dikunci pada R1, bukan diasumsikan UI.

SLD-R1 live output diterima tanpa blocker. R2 local implementation menambah
fee hanya untuk DELIVERY, memasukkannya satu kali ke total server, dan
menyimpan breakdown internal pada receipt/Invoice/Event. Account function dan
Company fallback mapping pendapatan ongkir tersedia; posting jurnal Sale tetap
controlled HOLD sampai resolver/rule G6 Sale dibuka secara eksplisit.

## 9. Revisi Approved 2026-08-13 — Ownership UI Surat Jalan

Dokumen canonical tetap merupakan fulfillment evidence dari Sale `POSTED`,
tetapi workspace operasional Backoffice dipisahkan:

- `Sales → Invoice Penjualan` hanya membaca/cetak snapshot Invoice dan export
  komersial;
- `Inventory → Surat Jalan` membaca data quantity-only, mencetak, dispatch,
  delivered, dan cancel administratif;
- POS tetap dapat mencetak keduanya setelah Sale final melalui authority sesi
  kasirnya sendiri;
- permission `inventory.delivery_documents` tidak memberikan akses terhadap
  harga, Payment, Customer Balance, Invoice payload, Stock ledger, atau Finance;
- pemisahan menu/authority tidak memindahkan tabel, membuat Stock Movement,
  atau mengubah histori/nomor dokumen existing.
