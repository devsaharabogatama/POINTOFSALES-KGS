# POS Order Reservation, Dispatch, Procurement, and Finance Plan

**Status:** ACTIVE DELIVERY — ODR-1–ODR-6B STOCK READ MODEL DATABASE-LIVE; ODR-6B.2 INVENTORY DISPATCH UI LOCAL READY, AUTHENTICATED SMOKE PENDING  
**Tanggal keputusan:** 2026-08-28  
**Posisi roadmap:** perubahan arsitektur setelah Scheduled TEMPO Order; wajib
diimplementasikan bertahap sebelum dianggap runtime aktif.  
**Tujuan:** mempertahankan pengalaman kasir seperti checkout POS sekarang,
tetapi memisahkan konfirmasi order, reservasi stok, pengiriman fisik, kebutuhan
Purchasing, dan verifikasi pembayaran Finance.

---

## 1. Keputusan bisnis yang dibekukan

1. Kasir tetap memakai flow POS yang sama: pilih Customer, Product, harga,
   pengiriman, TEMPO/pembayaran, kemudian konfirmasi.
2. Konfirmasi POS menghasilkan **Sales Order final operasional**, bukan Draft
   yang memenuhi daftar kerja kasir dan bukan Sale akuntansi final.
3. Konfirmasi order membuat `Reserved Out` per Product-Warehouse:
   - `On Hand` belum berubah;
   - `Reserved Out` bertambah;
   - `Available to Sell = On Hand - Reserved Out`;
   - POS lain memakai `Available to Sell`, bukan `On Hand`, untuk keputusan jual.
4. Stock/FIFO/Movement final baru berkurang ketika Gudang melakukan tindakan
   eksplisit **Kirim / Dispatch** pada Surat Jalan. Mencetak Surat Jalan tidak
   boleh mengurangi stok.
5. Perubahan order sebelum Dispatch mengubah reservation secara atomik dan
   versioned. Perubahan setelah sebagian/seluruh Dispatch tidak boleh menimpa
   histori; gunakan perubahan sisa line atau Return.
6. Kekurangan berdasarkan reservation dikumpulkan sebagai satu kebutuhan
   Purchasing per sesi kasir. Dokumen canonical awal tetap Stock Request/RO;
   Purchasing yang mengubahnya menjadi Supplier Order/PO.
7. Draft PO boleh disinkronkan dengan perubahan kebutuhan. PO yang sudah
   `CONFIRMED`, dikirim ke Supplier, atau sudah diterima tidak boleh diedit
   otomatis; selisih menjadi request tambahan, pembatalan terkontrol, atau
   amendment yang disetujui Purchasing.
8. Finance memverifikasi pembayaran secara terpisah. Verifikasi pembayaran
   tidak boleh menjadi pemicu pengurangan stok dan tidak boleh menggandakan
   Sale/COGS journal.
9. Future order menjadi Sales Order `SCHEDULED/CONFIRMED`, bukan Draft POS.
   Ketika tanggal bisnis Company tercapai, order tampil pada antrean aktif
   tanpa auto-Post dan tanpa cron mutation.

---

## 2. Model stok

Untuk setiap pasangan Product-Warehouse, sistem wajib dapat merekonsiliasi:

```text
On Hand
- Reserved Out yang masih terbuka
= Available to Sell
```

### Saat POS mengonfirmasi order

- buat reservation immutable/versioned yang menunjuk Sales Order dan line;
- kurangi `Available to Sell` saja;
- jangan membuat Stock Movement, FIFO allocation final, atau Inventory GL;
- reservation harus tenant-, Store-, Warehouse-, Product-, UOM-, dan actor-scoped;
- exact retry tidak boleh membuat reservation ganda.

### Saat order diubah atau dibatalkan sebelum Dispatch

- lock order dan balance terkait;
- hitung delta reservation server-side;
- tambah/kurangi reservation dan procurement demand dalam satu transaksi;
- simpan before/after, alasan, actor, session, dan master version;
- cancellation melepaskan reservation yang belum dikirim.

### Saat Surat Jalan di-Dispatch

- lock Sale, Delivery, reservation, stock balance, dan FIFO;
- konsumsi FIFO dan kurangi `On Hand` hanya untuk quantity yang dikirim;
- kurangi reservation dengan quantity identik;
- buat Stock Movement source-linked ke Delivery/Dispatch;
- partial dispatch menyisakan reservation terbuka;
- exact retry mengembalikan hasil sama tanpa efek kedua.

`DELIVERED` adalah bukti penerimaan/logistik setelah Dispatch dan tidak boleh
mengurangi stok untuk kedua kalinya.

---

## 3. Lifecycle canonical

### Sales Order

```text
DRAFT_INPUT
  -> CONFIRMED / SCHEDULED
  -> RESERVED
  -> PARTIALLY_DISPATCHED
  -> DISPATCHED
  -> DELIVERED
```

Cabang yang diizinkan:

- `CONFIRMED/RESERVED -> CANCELED` bila belum ada Dispatch;
- partial Dispatch hanya dapat membatalkan quantity sisa;
- quantity yang sudah Dispatch dikoreksi melalui Sales Return;
- order tanggal mendatang berpindah secara derived dari `SCHEDULED` ke antrean
  aktif pada business date Company, bukan melalui auto posting.

### Surat Jalan

```text
READY -> DISPATCHED -> DELIVERED
```

- Print/download tidak mengubah lifecycle.
- Tombol `Kirim / Dispatch` berada pada Backoffice Inventory dan memerlukan
  capability serta Warehouse scope.
- `DELIVERED` menyimpan waktu, actor, penerima, dan bukti/catatan bila tersedia.

### Payment

```text
CAPTURED / PENDING_VERIFICATION
  -> VERIFIED
  -> SETTLED
```

Rejection atau koreksi harus mempunyai reason dan audit; tidak boleh menghapus
payment snapshot yang berasal dari POS.

---

## 4. Procurement demand per sesi

1. Setiap sesi kasir mempunyai satu demand group canonical per Company/Store/
   source Warehouse.
2. Demand dihitung dari shortage setelah reservation, bukan dari pengurangan
   `On Hand` fiktif.
3. Selama demand belum dialokasikan ke PO final, perubahan order menghitung ulang
   kebutuhan line secara idempotent.
4. Supplier split tetap menjadi keputusan Purchasing.
5. Setelah Supplier Order masih `DRAFT`, sinkronisasi boleh memperbarui quantity
   dengan audit dan optimistic version.
6. Setelah Supplier Order `CONFIRMED/PARTIALLY_RECEIVED/RECEIVED`, sistem tidak
   mengubah line diam-diam:
   - kebutuhan bertambah -> Stock Request delta baru;
   - kebutuhan berkurang -> cancellation/amendment request;
   - Purchasing menerima notice dan memutuskan tindakan Supplier.
7. Penutupan sesi membekukan identitas demand group, tetapi tidak menutup
   rekonsiliasi perubahan Sales Order yang sah.

---

## 5. Finance dan tanggal pengakuan

Finance dipisahkan menjadi dua event ekonomi agar Inventory GL, AR, dan Payment
tidak saling menunggu atau tercatat dua kali.

### Event Dispatch

Pada Dispatch, sistem membuat event final untuk:

- `Dr COGS / Cr Inventory` berdasarkan FIFO aktual;
- penjualan TEMPO: `Dr Customer Receivable / Cr Sales` beserta Tax/ongkir;
- penjualan non-TEMPO yang pembayarannya belum diverifikasi memakai account
  clearing/receivable yang sesuai, bukan dianggap Bank final.

Tanggal jurnal ekonomi memakai business date Dispatch. Tanggal order/rencana
tetap dimension/snapshot untuk sorting dan laporan komersial, bukan dipaksakan
ke periode lama yang mungkin sudah ditutup.

### Event verifikasi pembayaran

Setelah Finance mengonfirmasi:

- `Dr Cash/Bank / Cr Customer Receivable atau Payment Clearing`;
- payment proof, method, settlement account, verifier, dan waktu disnapshot;
- exact retry tidak membuat receipt/journal kedua;
- TEMPO tanpa pembayaran tetap menjadi AR sampai Customer Receipt terposting.

### Pembayaran sebelum Dispatch

Pembayaran customer sebelum barang dikirim adalah Customer Advance/Payment
Clearing, bukan revenue. Saat Dispatch, advance dialokasikan ke invoice/Sale
tanpa menggandakan kas atau pendapatan.

Cash drawer/session movement tetap merupakan bukti operasional POS. Journal
Cash/Bank final mengikuti proses verifikasi/settlement yang disetujui dan harus
direkonsiliasi dengan sesi serta Setor Kas.

---

## 6. Batas perubahan order

| Kondisi | Boleh diubah langsung? | Efek |
|---|---:|---|
| Belum Dispatch, PO belum dibuat | Ya | Reservation dan demand sesi dihitung ulang |
| Belum Dispatch, PO masih Draft | Ya | Reservation, demand, dan Draft PO tersinkron dengan audit |
| Belum Dispatch, PO sudah Confirmed | Terbatas | Buat delta/amendment; jangan ubah PO final diam-diam |
| Partial Dispatch | Hanya quantity sisa | Quantity terkirim immutable |
| Full Dispatch/Delivered | Tidak | Gunakan Return/credit workflow |
| Payment Verified | Tidak mengubah order ekonomi | Koreksi melalui reversal/receipt correction |

---

## 7. Otoritas minimum

- Cashier: membuat/mengubah order sebelum Dispatch pada sesi dan Store sendiri.
- Store Manager: review/cancel order Store sesuai batas lifecycle.
- Warehouse Admin: melihat reservation Warehouse, menyiapkan dan Dispatch SJ.
- Purchasing: mengelola request, supplier split, Draft/Confirmed PO, amendment.
- Finance: verifikasi/reject payment, Customer Receipt, posting exception.
- Company Owner/Admin: policy dan exception yang eksplisit; tidak boleh membuka
  cross-tenant atau mengubah final history langsung.

Role/custom permission hanya dapat mempersempit kewenangan. Client-supplied
purpose, status, quantity, price, stock, account, atau payment state tidak pernah
menjadi sumber kebenaran.

---

## 8. Rencana implementasi enam fase

### ODR-1 — Live audit dan contract freeze

- inventaris current Sale/Post, Delivery, Stock, FIFO, shortage per sesi,
  Payment, AR, journal, Return, Offline, dan permission;
- keputusan migrasi historical Draft/Scheduled/Posted;
- preflight SELECT-only, state machine, failure code, dan migration manifest;
- belum ada mutation/schema/UI.

Local artifact sudah tersedia:

- `supabase/diagnostics/odr_phase1_order_reservation_dispatch_preflight.sql`;
- `docs/ODR1_LIVE_CONTRACT_AUDIT.md`;
- `docs/runbooks/ODR1_ORDER_RESERVATION_DISPATCH_PREFLIGHT.md`.

ODR-1 baru selesai setelah preflight live tidak menghasilkan `BLOCKER` dan
inventory hasilnya direview. `REVIEW` menunjukkan collision arsitektur existing
yang memang dipindahkan pada fase berikutnya; `SETUP` menunjukkan runtime ODR
belum dipasang.

### ODR-2 — Sales Order dan reservation foundation

- additive order/reservation schema, audit, optimistic version, tenant guard;
- atomic confirm/edit/cancel/reprice/reservation delta;
- `Available to Sell` server-derived;
- existing scheduled TEMPO compatibility dan controlled conversion;
- belum mengubah Stock/FIFO/Finance final.

Preflight SELECT-only sudah local-ready di
`supabase/diagnostics/odr_phase2_sales_order_reservation_preflight.sql`.
Migration/runtime tetap menunggu hasil live tanpa `BLOCKER` serta review setiap
scope `BACKFILL`.

### ODR-3 — Delivery Dispatch stock runtime

- Surat Jalan quantity/line reservation linkage;
- guarded partial/full Dispatch;
- atomic On Hand/FIFO/Movement/reservation consumption;
- Delivered proof tanpa stock effect kedua;
- Return compatibility dan reconciliation.

### ODR-4 — Procurement demand and PO synchronization

- satu demand group per sesi;
- update delta akibat edit/cancel order;
- sync hanya ke Draft PO;
- confirmed-PO amendment/delta workflow dan Purchasing notice;
- session close/reopen/exact retry/concurrency tests.

Preflight SELECT-only tersedia di
`supabase/diagnostics/odr_phase4_procurement_demand_preflight.sql` dengan
runbook `docs/runbooks/ODR4_PROCUREMENT_DEMAND_PREFLIGHT.md`. Preflight ulang
dikonfirmasi bersih; additive foundation `20260828150000` mengikuti
`docs/runbooks/ODR4A_PROCUREMENT_DEMAND_FOUNDATION.md`. ODR-4A dan runtime
demand per sesi `20260828160000` kemudian dikonfirmasi PASS. Proyeksi Stock
Request per sesi `20260828170000` kemudian dikonfirmasi PASS. Draft/final PO
tetap tidak dimutasi. Preflight SELECT-only sinkronisasi Draft PO tersedia di
`supabase/diagnostics/odr_phase4d_draft_po_sync_preflight.sql` dengan runbook
`docs/runbooks/ODR4D_DRAFT_PO_SYNC_PREFLIGHT.md` dan telah dikonfirmasi tanpa
blocker. Foundation notice delta/amendment `20260828180000` berstatus
PASS. Runtime managed-request reconciliation `20260828190000` telah
dikonfirmasi PASS. Eligible single-Draft-PO sync `20260828200000` telah
dikonfirmasi PASS; hanya delta positif ke satu line yang sepenuhnya
allocation-backed dan valid secara UOM yang dapat dimutasi. PO
final/ambigu/manual tetap notice. Preflight SELECT-only ODR-5 tersedia untuk
memetakan Dispatch, payment intent, partial Dispatch, periode, mapping akun,
serta boundary jurnal historis sebelum schema atau runtime Finance baru dibuat.

### ODR-5 — Finance dispatch and payment verification

- Dispatch Sale/COGS/Inventory/AR event;
- payment pending/verified/settled serta customer advance;
- clearing, Cash/Bank, Customer Receipt, Deposit, period, reversal;
- journal balance, FIFO-GL, AR, cash-session reconciliation;
- controlled then automatic posting smoke.

Preflight live telah dikonfirmasi tanpa blocker: belum ada Order/Dispatch ODR
live, queue Finance aktif nol, periode siap, source intent valid, dan histori
40 jurnal/21 event Sale tetap immutable. Foundation additive zero-backfill
`20260828210000` berstatus **LOCAL READY**. Foundation ini hanya menambah source
Dispatch, antrean verifikasi Payment, event catalog, fungsi akun uang muka,
audit append-only, RLS, dan browser closure. Ia belum membuat Financial Event,
Journal, mapping COA, posting runtime, atau UI. Rollout manual mengikuti
`docs/runbooks/ODR5A_FINANCE_SOURCE_FOUNDATION.md`.

Closing postflight ODR-5A kemudian dikonfirmasi seluruhnya PASS dan tetap
zero-backfill. Gate berikutnya adalah preflight SELECT-only ODR-5B di
`supabase/diagnostics/odr_phase5b_finance_mapping_runtime_preflight.sql` untuk
menentukan mapping akun per Company, category/rule, dispatcher, dan controlled
queue secara deterministic sebelum runtime dibuat.

Preflight awal ODR-5B menemukan seluruh lima Company membutuhkan akun Customer
Advance baru, tanpa collision kode `2190`. Empat Company juga tidak memiliki
system-owned COA/fallback untuk tiga fungsi inti dan satu fungsi conditional;
sebelum membuat akun duplikat, audit lanjutan SELECT-only memeriksa account ID
yang sudah sah pada ACTIVE transaction rule sebagai sumber mapping reusable.

Audit reusable terkoreksi kemudian membuktikan seluruh fungsi inti/conditional
memiliki satu sumber account deterministic. Hanya akun Customer Advance pada
lima Company yang perlu dibuat. Foundation mapping `20260828220000` berstatus
**LOCAL READY**: provision akun `2190`, dua category ODR, exact Account Function
rules, dan approved versioned posting definitions. Ia tidak membuat Event atau
Journal dan belum memasang source-capture/dispatcher. Rollout manual mengikuti
`docs/runbooks/ODR5B_FINANCE_MAPPING_FOUNDATION.md`; gate setelah PASS adalah
runtime ODR-5C dalam controlled mode.

Closing postflight setelah behavioral ODR-5B kemudian dikonfirmasi seluruhnya
PASS: lima akun advance, sepuluh category/rule set, 85 exact mapping, dan zero
ODR Event/Journal effect. ODR-5C dimulai dengan preflight SELECT-only untuk
memastikan tidak ada operasi Dispatch lama tanpa source Finance, snapshot dan
Movement lengkap, accounting period siap, serta proportional partial-Dispatch
contract dapat dipasang tanpa backfill ambigu.

Preflight ODR-5C kemudian dikonfirmasi tanpa blocker. Runtime
`20260828230000` berstatus **LOCAL READY**: core Dispatch stock dipertahankan di
balik wrapper atomik, lalu satu source immutable dan satu event
`SALE_DISPATCHED` dibuat per operasi. Nilai Product/Tax partial dialokasikan
berdasarkan rasio reservation; ongkir, surcharge, rounding, dan residual hanya
ditutup pada Dispatch final. Controlled dispatcher tersedia, sedangkan mode
automatic ditolak server sampai ODR-5D. Rollout dan smoke mengikuti
`docs/runbooks/ODR5C_DISPATCH_FINANCE_RUNTIME.md`.

Closing postflight ODR-5C kemudian dikonfirmasi seluruhnya PASS: wrapper
atomik, controlled dispatcher, source/event/cost reconciliation, privilege
boundary, dan automatic-mode guard valid; runtime ODR masih nol dan 40 jurnal
historis tetap utuh. Gate aktif pindah ke preflight SELECT-only ODR-5D di
`supabase/diagnostics/odr_phase5d_payment_verification_runtime_preflight.sql`.
Audit ini memeriksa payment intent Order, Payment Method/proof, total
non-TEMPO/TEMPO, exact mapping/rule, Advance sebelum Dispatch, settlement
Clearing/AR sesudah Dispatch, dan hubungan Cash dengan sesi Kasir. Belum ada
runtime, mutation, Event, Journal, ataupun UI Payment verification pada tahap
preflight ini.

### ODR-6 — POS/Backoffice cutover and E2E closure

- POS tetap satu flow kasir; Draft hanya input belum dikonfirmasi;
- daftar Order aktif/terjadwal terpisah dari Draft;
- Inventory reservation/Dispatch workspace;
- Purchasing delta/amendment UX;
- Finance verification queue;
- online/offline, negative stock, two-Company, role, retry, Return, report,
  deployment, rollback, dan manual UAT.

Setiap fase wajib mempunyai preflight, migration bila perlu, postflight,
behavioral/regression, rollback/forward-fix note, dan authenticated smoke.

---

## 9. Compatibility dan cutover

- Sale Posted historis, Stock Movement, FIFO, Payment, Financial Event, Journal,
  Invoice, dan Surat Jalan tidak dibackfill ulang atau dihapus.
- Scheduled TEMPO Draft yang baru saja diaktifkan tetap berjalan sampai ODR-2
  menyediakan konversi controlled; jangan menghapus migration/runtime existing.
- Offline Sale tidak memakai reservation baru sebelum contract replay dan
  allowance dibuktikan parity; fail closed selama fase awal.
- Negative Stock tetap exception online default OFF. Reservation tidak boleh
  dipakai untuk menyamarkan On Hand/FIFO negatif tanpa authorization.
- Invoice/SJ snapshot final tetap immutable dan reprint-stable.
- Feature baru harus dapat dinyalakan per Company setelah UAT; default rollout
  ke Company existing tetap OFF sampai reconciliation lulus.

### ODR-5D runtime rollout status

Preflight live ODR-5D telah dikonfirmasi tanpa blocker. Runtime
`20260828240000` local-ready untuk menangkap payment intent immutable saat
Order dikonfirmasi, mencatat Cash tepat sekali, menjalankan verify/reject
maker-checker, dan membuat satu Event `SALE_PAYMENT_VERIFIED` `HOLD` untuk
controlled posting. Internal-liability tender tetap memakai ledger existing.
Automatic posting serta aplikasi pre-dispatch Customer Advance pada Dispatch
tetap ditutup sampai ODR-5E; Dispatch terkait diblok agar tidak ada jurnal
settlement yang salah selama boundary rollout.

Closing postflight ODR-5D kemudian dikonfirmasi seluruhnya PASS dan runtime
tetap nol. ODR-5E `20260828250000` local-ready untuk mengganti guard sementara
dengan one-time settlement rebalance atomik. Payment surcharge berasal dari
snapshot Order, verified pre-dispatch payment mendebit Customer Advance pada
Dispatch, lalu residual masuk Clearing atau Piutang. Partial Dispatch menunda
fixed surcharge sampai final Dispatch. Automatic posting tetap ditutup sampai
ODR-5F authenticated reconciliation.

Closing postflight ODR-5E kemudian dikonfirmasi seluruhnya `PASS`: rebalance
Dispatch/Advance, event/source, surcharge final, audit, private boundary, dan
urutan posting Advance sebelum Dispatch valid; runtime ODR tetap nol. ODR-5F
`20260828260000` sekarang **LOCAL READY**. Closure ini menyamakan hasil
controlled queue dan automatic trigger, menormalkan `NO_FINANCIAL_EFFECT`, dan
tetap menolak Dispatch yang memakai Advance sebelum event pembayarannya
`POSTED`. Migration tidak mengubah policy Company existing dari `CONTROLLED`;
switch `AUTOMATIC` baru tersedia sebagai pilihan Owner/Admin setelah rollout
dan closing postflight PASS. ODR-6 belum dibuka.

Closing postflight ODR-5F kemudian dikonfirmasi seluruhnya `PASS`: enam
migration Finance lengkap, controlled/automatic dispatcher parity valid,
exception/queue kosong, protected private boundary tertutup, dan source/Event/
Journal/Advance reconciliation bersih. ODR-6 dimulai melalui preflight
SELECT-only `odr_phase6_ui_e2e_cutover_preflight.sql`. Audit ini tidak mengubah
runtime; ia membuktikan kesiapan sembilan RPC canonical serta memetakan empat
consumer browser yang harus dipindahkan sebelum legacy paths dapat dikarantina.

Preflight ODR-6 kemudian dikonfirmasi tanpa blocker. ODR-6A sekarang
**LOCAL READY; MANUAL DATABASE ROLLOUT DAN AUTHENTICATED SMOKE PENDING**. PWA
online mengonfirmasi Order melalui `confirm_pos_sales_order`, memisahkan Order
aktif/terjadwal dari Draft, dan menutup checkout Offline baru sampai replay
reservation tersedia. Migration `20260828270000` menolak cancel Order selama
Payment masih `PENDING`/`VERIFIED`; Finance harus menyelesaikan Payment dahulu.
Inventory Dispatch, Purchasing demand/amendment, dan Finance verification UI
tetap menjadi ODR-6B/6C setelah closing ODR-6A PASS.

Smoke pertama mengungkap identitas Invoice `DRAFT-*` ikut tersalin ke snapshot
`ORDER_CONFIRM`. ODR-6A belum boleh ditutup. Forward-fix `20260828280000`
mempertahankan Sale sebagai dokumen operasional nonfinal/zero-effect, tetapi
mengalokasikan nomor `INV-*` atomik setelah Reservation dan sebelum Invoice/SJ
immutable dibuat. Snapshot baru yang terdampak direpair terbatas dan diaudit;
final history, Stock, FIFO, Payment, Event, serta Journal tidak berubah.

ODR-6B.1 membuka read-model Inventory secara sempit setelah ditemukan bahwa UI
Stock Real masih hard-coded `Reserved: Belum aktif`. Migration `20260829090000`
menyatukan pair Product/Warehouse dari saldo dan Reservation aktif, menghitung
remaining Reserved Out serta Available to Sell server-side, dan tetap menjaga
table Reservation browser-closed. Atomic Dispatch/Received UI tetap gate
ODR-6B berikutnya dan belum dinyatakan selesai dari read model ini.

ODR-6B.2 Inventory Dispatch UI telah melewati closing postflight tanpa
pelanggaran. ODR-6C.1 Purchasing Demand UI sekarang local-ready: composed
workspace menampilkan shortage per sesi, managed Stock Request, dan amendment,
sementara allocation Draft maupun final mengurangi quantity yang masih boleh
dibuatkan PO. PO final tetap immutable dan authenticated smoke masih menunggu.

---

## 10. Definition of done

Fitur baru hanya dapat disebut selesai jika:

1. satu order retry/concurrent menghasilkan satu reservation dan satu final
   Dispatch effect;
2. `On Hand - Reserved Out = Available to Sell` untuk seluruh pair;
3. Dispatch quantity sama dengan reservation release, Movement, dan FIFO;
4. perubahan order menghasilkan demand/PO delta yang dapat ditelusuri;
5. confirmed PO tidak pernah berubah otomatis tanpa amendment;
6. Dispatch journal balance dan Inventory GL sama dengan FIFO;
7. Payment verified sama dengan receipt/clearing/AR settlement;
8. Return mengoreksi quantity, FIFO, revenue/AR, dan payment tanpa mengubah
   source history;
9. role, Warehouse, Store, Company, direct URL/API/RPC, and RLS isolation PASS;
10. authenticated E2E serta rollback rehearsal PASS sebelum Company production
    mengaktifkan policy baru.

---

## 11. Decision log

| Tanggal | Keputusan | Status |
|---|---|---|
| 2026-08-28 | POS confirmation membuat Sales Order + Reserved Out; On Hand/FIFO berkurang saat SJ Dispatch | APPROVED |
| 2026-08-28 | Order aktif/terjadwal tidak memenuhi Draft POS | APPROVED |
| 2026-08-28 | Kekurangan dihimpun per sesi dan perubahan menyinkronkan demand/Draft PO | APPROVED |
| 2026-08-28 | Confirmed PO immutable; perubahan memakai delta/amendment | APPROVED |
| 2026-08-28 | Dispatch mencatat ekonomi Sale/Inventory; Finance verification mencatat settlement Payment | APPROVED |
| 2026-08-28 | Implementasi dibagi enam fase dan belum dimulai saat dokumen ini dibuat | APPROVED |
