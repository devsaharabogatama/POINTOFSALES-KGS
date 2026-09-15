# Optional POS Retail and Backoffice Delivered-Quantity Sales Process


## Current 2026-09-16 - recovery release candidate

Supersedes historical NOT READY / pending notes below.
LOCAL READY: six repair migrations and existing UI/API/document-log integration.
DATABASE LIVE: clone idrufihckscppsyclmsu only. No Production SQL/deploy by agent.
12 nonzero rollback behavioral regressions exit0: open/closed sessions, shared
request/two recovered SOs, final PO, actual partial/full dispatch, role/tenant,
retry/stale, Retail/Office Invoice/DP/payment and Purchase regression.
Two live connections verify Recovery Company-lock serialization; retry separately.
Scoped eslint, tsc and Next production build exit0 (compile-only non-access keys).
Atomic installer re-entry/parser proof exit0; full release postflight25 PASS.
No fake Receive/stock reset/historical plan-item-KEEP_ITEM rewrite.
Linked active procurement remains blocked on reverse until ownership transfer.

Production nine orders are NOT claimed restored. CLIENT DEPLOYED,
authenticated HTTP SMOKE PASS and UAT PASS remain manual gates.
[Current report, complete package and installation order](runbooks/OFFICE_PROCUREMENT_RECOVERY_RELEASE_REPORT_2026-09-16.md).
Use its one atomic bundle, NOT historical partial installation instructions.
Changed: six new migrations, release pre/post/installer, representative tests,
cutover route/settings, SalesOrderView/page deep links, SalesDocumentView logs,
impact/spec/root/router/handoff. Recovery is explicit Super Admin action with
current versions, atomic target/link/audit and immutable APPLY_ITEM exact retry.
Next safe step: user Production preflight/fingerprints, atomic install/postflight,
unchanged-data comparison, user push/redeploy without env change, KMS/LSM smoke.
Stop on drift/blocker; no reset, ledger-only insertion or private SQL bypass.


> 2026-09-15 procurement preservation approved: existing active Stock Requests
> are linked to Office SO, not replaced. Actual inventory nine RESERVED sources,
> 27 REQUESTED lines, two SUBMITTED requests, no PO allocation/payment/dispatch.
> User delegates a balanced method targeting stock0; this is not permission to
> reset On Hand or fabricate Receipt/Finance events. Immutable linkage foundation
> 20260915140000 is installed/tested only on rehearsal clone; converter recovery
> and Office lifecycle synchronization remain pending.

> 2026-09-15 latest user decision: already-entered orders must follow the new
> process; internal procurement is not a reason to leave the affected open
> orders behind. Production evidence shows KMS4/LSM5 APPLIED-plan sources
> BLOCKED/KEPT solely by OPEN_PROCUREMENT_MUST_FINISH, all targets null.
> Earlier procurement-only grandfathering is superseded for this case.
> [Impact-first recovery audit](audits/OFFICE_SALES_RETAINED_PROCUREMENT_IMPACT_2026-09-15.md)
> records cancellation/RO/PO side effects and facts required before repair.
> No converter fix or Production recovery is live from this decision yet.

> 2026-09-12 — Step 6/6.1 authenticated read smoke **LOCAL READY**. Script
> login dengan user Development nyata lalu membaca active Company, SO, DO/SJ,
> Invoice, Delivered Not Invoiced, dan katalog export melalui API lokal. Target
> production/staging ditolak dan tidak ada mutation; eksekusi login user masih
> pending.
>
> 2026-09-12 — Accepted-overage ledger invariant dikoreksi: quantity penerimaan
> normal berada pada SO line, sedangkan accepted overage berada hanya pada
> discrepancy line. Invoice menjumlahkan kedua source satu kali masing-masing;
> overage tidak boleh menaikkan regular `accepted_base_qty`.
>
> 2026-09-12 — Step 5/6.1 **LOCAL READY**. Finance closure dimulai dengan
> menyambungkan event COGS accepted overage yang sudah HOLD ke Posting Queue
> existing. Posting merekonsiliasi stock effect/FIFO/Movement dan membuat
> Journal Dr COGS/Cr Inventory Transit tanpa efek Stock, Invoice, atau Payment.
>
> 2026-09-12 — Step 4/6.5C4 **DATABASE LIVE + BEHAVIOR/POSTFLIGHT PASS**. Sesuai keputusan user,
> accepted-overage commercial approval berada pada SO/Sales, sedangkan input
> penerimaan serta resolution fisik berada pada Surat Jalan/Gudang. Projection
> server Gudang tidak membawa harga, diskon, pajak, atau commercial snapshot.

> 2026-09-12 — Step 4/6.5C3 **LOCAL READY**. Resolver atomik menyelesaikan
> Accept/Return Overage dan Wrong Item: reconstruction/return Stock exact,
> correction DO/SJ pada SO asli, Qty To Invoice overage, serta Financial Event
> COGS overage terpisah berstatus HOLD. Shortage mixed case harus diselesaikan
> lebih dahulu; event baru belum diposting ke jurnal pada step ini.

> 2026-09-12 — Step 4/6.5C1 **LOCAL READY**. Actual Overage/Wrong Item akan
> direkonstruksi source→Transit melalui helper private exact-FIFO dengan policy
> minus Warehouse. Accepted-overage memakai Financial Event terpisah dari
> penerimaan awal agar source, actor, waktu, approval, dan laporan HPP jelas.
> Resolver final/status/effect/event belum dibuka pada C1.

> 2026-09-12 — Step 4/6.5B **LOCAL READY**. Resolver Gudang untuk `SHORT`
> menjalankan `BACKORDER`/`ACCEPT_SHORT` atomik. Tanggal Backorder kosong
> otomatis menjadi tanggal Company dan tetap editable. Exact Transit FIFO,
> Reservation, parent/child DO/SJ, Finance HOLD lost/damaged, idempotency, dan
> audit dikunci; Overage/Wrong Item menunggu reconstruction gate berikutnya.

> 2026-09-12 — Step 4/6.5A **LOCAL READY**. Foundation menambahkan exact
> Stock-effect/FIFO/Backorder lineage dan batas approved overage. Accepted
> overage tetap memerlukan Warehouse resolution sesudah approval Sales. Belum
> ada public resolver, Stock mutation, Backorder DO/SJ, Invoice, atau Finance
> effect dari step ini.

> 2026-09-12 — Step 4/6.4 **DATABASE LIVE + USER-CONFIRMED PASS** pada
> isolated Development. Untuk `ACCEPT_OVERAGE`, harga,
> proporsi diskon, dan Tax Rule awal mengikuti baris SO asli. Sales Admin dapat
> menyesuaikan nilai tersebut sebelum approval. Approval hanya mencatat
> keputusan komersial versioned/audited; Stock, FIFO, Reservation, DO, Invoice,
> Payment, dan Finance menunggu Warehouse resolution.

> 2026-09-12 — Discrepancy Step 4/6.3 **DATABASE LIVE + USER-CONFIRMED PASS**
> pada isolated Development. Mixed Customer
> Receipt mengonsumsi hanya accepted qty dari exact Transit FIFO dan langsung
> membukanya sebagai Qty To Invoice. Quantity bermasalah tetap di Transit,
> Reservation, serta discrepancy immutable; DO/SO tetap `IN_TRANSIT` sampai
> resolution. Clean receipt lama tetap memakai kontrak lima argumen.

> 2026-09-11 — Discrepancy Step 4/6.2 **DATABASE LIVE + USER-CONFIRMED
> PASS** pada isolated Development. Keputusan final:
> penerimaan Customer dapat memisahkan qty accepted dan qty bermasalah per line;
> qty accepted langsung menjadi Qty To Invoice walaupun Backorder/discrepancy
> masih terbuka. Tim pengiriman memilih disposition saat serah-terima;
> `ACCEPT_OVERAGE` memerlukan Sales Admin, lost/damaged diselesaikan Admin Gudang
> lalu diteruskan ke Finance queue, dan Backorder memakai SJ baru yang terhubung
> ke SO serta SJ awal. Keputusan komersial shortage (`BACKORDER` atau
> `ACCEPT_SHORT`) dicatat terpisah dari posisi fisiknya (`NOT_LOADED`,
> `RETURNING`, `LOST`, atau `DAMAGED`). Wrong Item menyimpan Product/UOM/qty
> aktual terpisah dari Product/qty yang seharusnya. Foundation belum
> mengaktifkan mutation/UI.

> 2026-09-11 — Payment Collection Step 1/3 **DATABASE LIVE + USER-CONFIRMED
> BEHAVIOR/POSTFLIGHT PASS**; Step 2/3 **DATABASE LIVE + USER-CONFIRMED PASS**;
> Step 3/3 **LOCAL READY**. Step 2 menambahkan
> status bayar, sisa tagihan, riwayat Penerimaan Customer, dan Register Payment
> atomik pada detail Invoice existing. Manual rollout Step 2 dan authenticated
> smoke masih menunggu. Step 3 menyatukan kedua source ke Penerimaan Customer,
> AR Aging per installment, Customer Statement, dan export existing. Lihat
> `docs/runbooks/BACKOFFICE_SALES_AR_REPORTING_INTEGRATION_ROLLOUT.md`.
>
> 2026-09-11 — Payment Collection Step 1/3 **BASE DATABASE LIVE; MAPPING
> FORWARD-FIX LOCAL READY**. Typed allocation
> Invoice Backoffice memakai header Customer Receipt canonical, mendukung
> pembayaran partial/berulang, satu jurnal Kas/Bank ke AR, dan status installment
> derived dari receipt `POSTED`. Client, AR report union, production, dan staging
> belum disentuh. Lihat
> `docs/runbooks/BACKOFFICE_SALES_PAYMENT_COLLECTION_ROLLOUT.md`.
> Forward-fix `20260911161000` menutup gap provisioning Finance yang terbukti
> pada isolated Development: fallback `CUSTOMER_RECEIVABLE` dan `BANK` belum
> tersedia walaupun akun sistemnya ada. Migration Payment Collection yang sudah
> applied tidak diedit.

**Status:** STEP 1E-B1 DELIVERY-FEE PARITY LOCAL READY / FEATURE OFF  
**Decision date:** 2026-09-08  
**Scope:** future optional Backoffice Sales entitlement per Company. This note
records the approved optional flow. Database changes remain restricted to the
isolated Development project until explicit production deployment approval.

Execution wajib mengikuti
`runbooks/BACKOFFICE_SALES_SAFE_DEVELOPMENT_PLAN.md`. Process identity and
isolated Quotation/SO persistence foundations are database live only on
isolated Development. Runtime dan client vertical slice sudah tersedia lokal;
commercial postflight, rollback behavior, authenticated smoke, POS regression,
dan UAT masih pending.

Commercial parity follow-up menambahkan role formal `SALES`/`SALES_ADMIN`,
canonical Pricelist/price/tax, manual price override, discount, rounding, serta
UI pengaturan stok minus pada Warehouse. Perubahan hanya live di isolated
Development. Lihat
`runbooks/BACKOFFICE_SALES_COMMERCIAL_PARITY_ROLLOUT.md`.

## 1. Product decision

Platform menyediakan dua business process yang hidup berdampingan:

1. `RETAIL_CONFIRM_INVOICE` wajib untuk source `POS` dan mempertahankan flow
   aktif tanpa perubahan. Confirm Order membuat Reservation, Invoice, dan Surat
   Jalan; Dispatch menyelesaikan Stock/FIFO dan Finance sesuai ODR existing.
2. `BACKOFFICE_DELIVERED_QTY_INVOICE` tersedia untuk source
   `BACKOFFICE_SALES` hanya ketika entitlement Company diaktifkan Super Admin.
   Flow-nya adalah Quotation -> Sales Order -> Delivery Order -> delivered
   quantity -> satu atau beberapa Invoice.

Setting Company adalah feature enablement, bukan switch global yang mengubah
transaksi POS. Pada Company yang mengaktifkan flow baru, POS tetap retail dan
Backoffice Sales mendapat flow baru secara bersamaan.

Process mode dan source channel wajib disnapshot pada Quotation/Sales Order.
Perubahan setting kemudian tidak boleh mengubah histori atau Order aktif.

## 2. Target flow Backoffice

```text
Sales membuat Quotation
  -> Pro-Forma opsional (dokumen komersial; tidak membuat AR/Revenue)
  -> DRAFT (status SENT hanya dibaca untuk compatibility data legacy)
  -> Confirm menjadi Sales Order
  -> Down Payment Invoice opsional dapat dibuat dan diposting sebelum Delivery
  -> Reserved Out + Delivery Order READY
  -> Picking dan quantity aktual
  -> Dispatch ke Stock Transit / IN_TRANSIT
  -> Admin Gudang mencatat Customer menerima / DO DONE
  -> Stock sale-out + FIFO/COGS final
  -> quantity netto diterima menjadi Qty To Invoice
  -> Sales membuat 0..N Draft Invoice
  -> Finance/Post authority memfinalkan Invoice dan AR/Revenue
  -> satu atau beberapa Payment dapat dialokasikan ke Invoice
```

Quotation dan Confirm SO tidak membuat nomor atau snapshot Invoice final.
Print/download Surat Jalan tidak membuat Stock atau Finance effect. DO selesai
menambah Qty To Invoice; pembuatan Draft Invoice dilakukan eksplisit dari SO
agar beberapa DO dapat digabung dalam satu Invoice SO yang sama.

Sebelum modul Logistics tersedia, Admin Gudang mengoperasikan
`READY -> IN_TRANSIT/DISPATCHED -> DELIVERED/DONE`. Konfirmasi `DELIVERED`
menyatakan Customer menerima. Tanda tangan SJ existing tetap terpisah; digital
proof dari aplikasi Logistics adalah future scope.

## 3. Stock, reservation, dan transit

Reservation tidak mengurangi On Hand:

```text
Available = On Hand - Reserved Out
Forecasted = On Hand + Incoming - Reserved Out
```

Perpindahan Gudang -> Transit mengurangi On Hand Gudang dan menambah On Hand
Transit tanpa mengurangi inventory total Company. Barang Transit tidak tersedia
untuk Order lain. Customer menerima mengurangi Transit sebagai sale-out final
dan menjadi authority Qty Delivered serta FIFO/COGS.

Movement tidak boleh ditimpa. Dispatch, correction, Return Gudang, dan final
acceptance memakai movement delta/reversal dengan source, actor, timestamp,
version, reason, dan idempotency key.

## 4. Partial delivery, discrepancy, dan Backorder

Flow harus mendukung secara audited:

- kurang kirim: Backorder atau `ACCEPT_SHORT`;
- kelebihan: `ACCEPT_OVERAGE` setelah harga disetujui atau `RETURN_OVERAGE`;
- `ACCEPT_OVERAGE` yang disetujui menjadi sumber line Invoice terpisah dari
  line SO asli, memakai quantity dan commercial snapshot approval sendiri,
  serta diberi catatan operasional "Kelebihan barang" agar tracing jelas;
- salah barang: `REPLACE_WRONG_ITEM` dan Return Gudang untuk barang salah;
- rusak/hilang: exception Transit, bukan otomatis Sales Return;
- `RETURN_TO_WAREHOUSE`: Transit kembali menjadi On Hand hanya setelah
  penerimaan Return diposting;
- perubahan komersial setelah Dispatch memakai shipment amendment/movement
  delta, bukan replacement Order yang menghapus jejak fisik.

Backorder membuat DO/SJ tambahan yang semuanya menunjuk SO yang sama. Versi SJ
lama yang sudah dicetak harus dapat ditandai `SUPERSEDED`.

## 5. Quantity invoiceable dan multiple Invoice

Tindakan `Customer menerima` pada suatu DO harus transactional dan exact-retry
safe:

1. lock SO, DO/version, Transit allocation, dan master snapshot;
2. validasi quantity dan disposition discrepancy;
3. konsumsi Transit FIFO/batch menjadi sale-out;
4. buat immutable Stock Movement dan Finance cost source;
5. tambah cumulative accepted quantity pada SO line;
6. hitung ulang Qty To Invoice;
7. tandai DO `DELIVERED/DONE` tanpa otomatis menutup SO bila masih ada
   Backorder, discrepancy, atau quantity belum ditagihkan.

Rumus minimum per SO line:

```text
Qty Netto Delivered = Qty Accepted - Qty Return sebelum Invoice
Qty To Invoice = Qty Netto Delivered - Qty pada Invoice Draft/Posted aktif
```

Satu SO boleh mempunyai `0..N` Invoice. Satu Invoice dapat mengambil quantity
dari satu atau beberapa DO milik SO yang sama. Fase pertama tidak menggabungkan
beberapa SO ke satu Invoice.

Server wajib menolak:

- Invoice quantity nol, negatif, atau melebihi Qty To Invoice;
- cross-SO, cross-Company, atau UOM snapshot yang tidak cocok;
- exact idempotency key dengan payload berbeda;
- stale version atau concurrent allocation atas saldo yang sama.

Draft Invoice memegang allocation agar dua user tidak menagihkan saldo yang
sama. Cancel Draft melepaskannya. Invoice Posted immutable; koreksi memakai
Credit Note/Sales Return append-only. SO berstatus `FULLY_INVOICED` hanya ketika
tidak ada Backorder/discrepancy terbuka dan seluruh Qty Netto Delivered sudah
ditagihkan atau ditutup melalui disposition komersial yang diaudit.

## 6. Invoice read model dan tampilan

Setiap line Invoice menampilkan:

- Qty Order;
- Qty Delivered kumulatif;
- Qty Invoice ini;
- Qty yang sudah di-invoice sebelumnya;
- Qty To Invoice tersisa;
- UOM, harga, discount, tax, dan total.

Header menampilkan SO asal, DO sumber, tanggal Order, tanggal Invoice, due date,
urutan Invoice pada SO, dan payment status. Quantity dengan UOM berbeda tidak
boleh dijumlahkan sebagai satu angka header tanpa base-UOM conversion snapshot.

SO menampilkan Qty Order, Reserved, Delivered, Returned, Net Delivered,
Invoiced, To Invoice, dan Backorder per line serta link ke Quotation, seluruh
DO/SJ, Invoice, Return, dan audit activity.

## 7. Finance boundary

- Down Payment Invoice setelah SO Confirm dapat diposting sebelum Customer
  menerima; jurnal memakai Customer Advance Liability dan bukan Revenue barang.
- Pro-Forma tidak membuat AR, Revenue, Payment, atau jurnal.
- Stock/Inventory/COGS mengikuti business date DO selesai/Customer menerima.
- Revenue, tax, dan AR mengikuti posting Invoice; Dispatch/DO tidak boleh
  mencatat Revenue yang sama.
- Jeda antara DO selesai dan Invoice terlihat sebagai `Delivered Not Invoiced`.
- Invoice date mengikuti tanggal penerbitan/posting; Order, planned delivery,
  Dispatch, dan acceptance tetap dimension terpisah.
- Payment Term disalin dari SO ke setiap Invoice. Untuk installment, schedule
  due date dihitung eksplisit dari tanggal Invoice seperti Odoo; revisi,
  Dispatch, dan acceptance tidak boleh mengubah schedule Invoice yang Posted.
- SO lama tanpa Payment Term tetap memakai `due_date` absolut existing untuk
  compatibility dan tidak dibackfill diam-diam.
- Verifikasi Payment asynchronous tidak memblokir operasional pengiriman.
- Journal existing tidak ditulis ulang; koreksi memakai Return, Credit Note,
  atau adjustment append-only.
- Ongkir berada pada header SO. Regular Invoice pertama otomatis mengambil
  seluruh sisa ongkir, tetapi Finance dapat mengedit pembagiannya sebelum
  posting selama aggregate Draft/Posted tidak melebihi ongkir SO. Cancel Draft
  melepaskan alokasi; DP tidak membawa ongkir. Saat posting, ongkir masuk ke
  account function canonical `DELIVERY_FEE_REVENUE`, terpisah dari pendapatan
  produk.

Perbedaan dokumen wajib dipertahankan:

- Pro-forma adalah dokumen komersial non-posted, bukan AR/Revenue.
- Multiple Invoice membagi Qty To Invoice satu SO menjadi beberapa tagihan.
- Cicilan adalah beberapa Payment allocation terhadap satu Invoice dan tidak
  menambah quantity Invoice.

## 8. Inventory read model minimum

Inventory Product/Warehouse menampilkan:

- `On Hand`: quantity fisik pada lokasi Gudang;
- `Reserved Out`: On Hand yang dialokasikan ke SO/DO terbuka;
- `Available`: `On Hand - Reserved Out`;
- `Incoming`: Receipt/produksi confirmed yang belum diterima;
- `Forecasted`: `On Hand + Incoming - Reserved Out`;
- nilai FIFO dan movement terakhir;
- detail Reserved Out ke Company, SO, Customer, DO, scheduled date, quantity,
  dan status.

Read model wajib tenant-scoped dan memakai base-UOM snapshot.

## 9. Compatibility dan impact map

Implementasi bukan UI-only. Schema current mewajibkan
`sales_delivery_documents.invoice_snapshot_id NOT NULL`, sedangkan Confirm ODR
current membuat Reservation, Invoice/SJ, procurement demand, dan payment capture
dalam satu composition.

Direct impact:

- Company entitlement dan immutable process-mode/source snapshot;
- Backoffice Quotation/SO UI, API, RPC, dan tables;
- DO/Transit/Backorder/discrepancy;
- Qty Delivered/Invoiced/To Invoice ledger dan multiple Invoice;
- Inventory read model dan reservation lineage;
- Invoice list/detail/print/export;
- Finance Delivered Not Invoiced, COGS, Revenue/AR, Payment, dan Credit Note.

Regression boundary:

- POS Confirm/List/Revision/Cancel/Print tidak berubah;
- historical Invoice, SJ, Order, Stock Movement, FIFO, Event, dan Journal tidak
  ditulis ulang;
- Sales Return, Customer Statement, collection, Purchasing shortage, Offline,
  multi-Company, role denial, retry, dan stale version tetap kompatibel.

Mode retail wajib tetap default dan regression-tested. Mode baru tidak boleh
aktif pada production Company sebelum migration, postflight, behavioral test,
authenticated smoke, dan UAT lulus.

## 10. Delivery plan

1. discovery/preflight current call chain dan data compatibility — source audit
   dan SQL read-only local-ready; database execution belum dilakukan;
2. Company entitlement + immutable source/process-mode foundation — migration,
   postflight, dan transactional test local-ready; database belum dijalankan;
3. Backoffice Quotation dan SO tanpa Stock/Finance final effect;
4. reservation/read model Inventory dan allocation detail;
5. DO partial delivery, Transit, acceptance, Backorder, dan discrepancy;
6. Qty Delivered/Invoiced/To Invoice ledger dan multiple Draft Invoice;
7. Invoice list/detail/print/export dengan quantity lineage;
8. Finance Delivered Not Invoiced, COGS, Revenue/AR, Advance, Payment,
   Credit Note, dan controlled posting;
9. role, tenant, audit, idempotency, concurrency, stale-version, dan retry;
10. historical compatibility, rollout per Company, POS regression, smoke, dan
    UAT sebelum enablement.

## 11. Keputusan yang masih terbuka

1. Detail account-function dan materiality threshold Finance untuk final
   lost/damaged; actor operasional sudah diputuskan Admin Gudang dan hasilnya
   masuk Finance queue.
2. Batas nominal/quantity approval `ACCEPT_OVERAGE`; seluruh
   `ACCEPT_OVERAGE` tetap wajib Sales Admin sampai threshold tersendiri disetujui.
3. Apakah flow boleh dioverride per Order. Default aman: tidak; POS selalu
   retail dan Backoffice selalu delivered-quantity saat entitlement aktif.
4. Penomoran SJ Backorder/pengganti dan aturan `SUPERSEDED` dokumen tercetak.
5. Apakah satu Invoice boleh menggabungkan beberapa SO Customer yang sama.
   Default fase pertama: tidak.

## 12. Local-first implementation boundary

Pengembangan wajib dimulai secara lokal dan tidak boleh memakai database aktif
sebagai development environment.

Boundary fase lokal:

- bootstrap Supabase lokal terisolasi; repository saat keputusan ini belum
  mempunyai `supabase/config.toml`;
- gunakan schema/migration chain repository dan data dummy atau fixture yang
  tidak mengandung data/secret production;
- environment Backoffice lokal menunjuk ke Supabase lokal, bukan URL/key
  project aktif;
- feature `backoffice_delivered_qty_sales_enabled` default `OFF` pada seluruh
  Company fixture;
- POS regression dijalankan pada environment lokal yang sama, tetapi source POS
  tetap memakai `RETAIL_CONFIRM_INVOICE`;
- migration baru tidak dijalankan ke Supabase aktif, tidak ada deployment, dan
  tidak ada perubahan setting Company production selama fase ini;
- setiap gate harus dibedakan menjadi `LOCAL READY`, `LOCAL DATABASE PASS`,
  `CLIENT LOCAL SMOKE PASS`, dan `LOCAL UAT PASS`;
- baru setelah local UAT disetujui user, dibuat paket production rollout berisi
  preflight read-only, guarded migration, postflight, behavioral test,
  authenticated smoke, enablement satu Company pilot, dan rollback/forward-fix.

Local database harus dapat dibuang dan dibuat ulang. Test mutation memakai data
fixture sendiri serta exact retry, stale version, concurrency, multi-Company,
role denial, partial/full DO, multiple Invoice, Return, dan Finance
reconciliation. Snapshot production tidak boleh diperlukan untuk membuat fitur
berjalan; bila compatibility membutuhkan bentuk data nyata, gunakan hasil
diagnostic aggregate atau fixture yang sudah disanitasi.

Dokumen ini hanya mengunci arah desain; bukan bukti implementasi.

## 13. Phase 0 evidence (2026-09-08)

Audit source membuktikan Invoice snapshot dan Delivery document masih unik per
Sale, Delivery wajib menunjuk Invoice snapshot, dan Sales header masih
memerlukan Cashier Session. POS confirm current tetap membuat dokumen retail
dan wajib dipertahankan. Diagnostic dan interpretasi ada di
`runbooks/BACKOFFICE_DELIVERED_SALES_PHASE0_PREFLIGHT.md`; belum ada feature
Company atau runtime baru yang aktif.

## 14. Phase 1 local artifact (2026-09-08)

Migration `20260908100000` menambahkan catalog feature default OFF dan snapshot
immutable `sales_origin`/`sales_process_mode`. Semua Sale existing tetap
`POS + RETAIL_CONFIRM_INVOICE`. Migration sengaja belum melepas unique Invoice
atau Delivery agar consumer retail tidak berubah sebelum lineage one-to-many
siap. Runbook: `runbooks/BACKOFFICE_SALES_PROCESS_FOUNDATION_ROLLOUT.md`.

Development update:

- isolated Supabase Development telah dibangun dari migration chain repository
  sampai `20260908100000` dan postflight foundation PASS;
- feature tetap OFF dan tidak ada Sale Backoffice/POS fixture;
- audit trigger membuktikan `sales_headers` tetap terikat lifecycle POS
  (payment normalization, fulfillment snapshot, dan finalization). Phase
  Quotation/SO memakai relation Backoffice terisolasi agar Confirm Quotation
  tidak memicu Invoice, SJ, Stock, Payment, atau Finance existing;
- integrasi ke Reservation/DO dilakukan pada gate sesudah Quotation/SO runtime,
  bukan melalui pemanggilan RPC Confirm POS.

## 15. Phase 2 persistence foundation evidence (2026-09-08)

Migration `20260908110000` telah diterapkan hanya ke isolated Development dan
menambah `backoffice_sales_orders`, `backoffice_sales_order_lines`,
`backoffice_sales_order_operations`, serta `backoffice_sales_order_audit`.
Postflight aktual membuktikan 4 relation RLS, browser privilege 0, 2 immutable
history trigger, feature enabled Company 0, dan 0 row pada foundation maupun
Stock/Delivery/Invoice/Finance. Ini adalah schema/zero-effect evidence; belum
menjadi behavioral atau UAT evidence. Runtime berikutnya wajib tetap tidak
memanggil lifecycle POS dan tidak membuat efek fulfillment/finance.

## 16. Phase 2 guarded runtime evidence (2026-09-08)

Migration `20260908120000` menambah runtime terautentikasi untuk workspace,
list/detail, Save Draft, Send Quotation, Confirm SO, dan Cancel. Permission
`sales.backoffice_orders` ENFORCED tetapi membutuhkan feature Company, sehingga
default OFF menutup seluruh capability. Mutation memakai operation UUID,
SHA-256 request hash, advisory transaction lock, exact retry, optimistic
`master_version`, snapshot harga canonical server, dan audit immutable.

Behavioral rollback-only membuktikan Draft, retry exact, payload conflict,
stale version, Send, Confirm, Cancel, audit coverage, serta tidak ada perubahan
jumlah Reservation, Delivery, Invoice, Stock Movement, atau Financial Event.
Forward-fix `20260908121000` diperlukan karena `pgcrypto` berada di schema
`extensions`; dua hash call kini schema-qualified tanpa membuka search path.
Feature tetap OFF dan tidak ada runtime business row yang dipertahankan.

## 17. Revision and fulfillment-status foundation (2026-09-09)

2026-09-16 clone update:15142000 supplies the pre-dispatch delta described below.
Same SO/Reservation/initial DO IDs/numbers; canonical mutable line recomposition,
immutable full before/after history, atomic negative-stock opt-out rollback,
retry/stale and cancellation verified. Actual partial/full dispatch denies ordinary
revision/cancel. Authorized UI Edit/Cancel now includes PREPARING with no active
invoice; server validates untouched dependencies. Production/client rollout and
authenticated smoke are not yet performed. Historical APPLIED/KEPT recovery and
remaining linked-procurement matrix remain separate pending gates.

Historical diagnosis before15142000:

2026-09-15 actual-clone audit: automatic Confirm sets PREPARING and creates READY
DO, but the active core Save/Cancel guards still accept confirmed edits only at
CONFIRMED fulfillment. Save deletes/recreates lines while Reservation/DO FKs
protect those identities. Procurement-preserving recovery phase2 behavior fails
at this real public revision boundary; no guard bypass is authorized. Transactional
pre-dispatch Reservation/DO delta and full behavior verification are required
before recovery release; same-number revision remains the approved target.

Keputusan operasional terbaru menghapus aksi UI `Tandai Terkirim` yang ambigu.
Quotation `DRAFT` dikonfirmasi dan berpindah ke tab Sales Order. Record legacy
`SENT` tetap dapat dibaca dan dikonfirmasi agar compatibility tidak rusak.

Sales Order sebelum fulfillment dapat direvisi pada record dan nomor yang sama.
Revisi wajib alasan, menaikkan `master_version`, dan menyimpan aktor/waktu/alasan
pada audit immutable. Setelah proses gudang dimulai, revisi fail-closed sampai
delta Reservation/DO tersedia. Setelah status `Selesai` (Customer sudah
menerima), perubahan bisnis hanya melalui Retur.

Migration `20260909142000` dan `20260909143000` sudah live hanya pada isolated
Development. Client list memisahkan Quotation/SO, menampilkan status, serta
memfilter berdasarkan status dan basis tanggal Order/Rencana Kirim/Jatuh Tempo.
Manual postflight, rollback behavior, authenticated smoke, dan UAT masih
pending. Confirm tetap belum membuat Reservation/DO/Invoice/Stock/Finance.

## 18. Reservation and multi-Delivery lineage foundation (2026-09-09)

Migration `20260909145000` sudah live hanya pada isolated Development dan
membuat relation Reservation serta Delivery Order khusus Backoffice. Relation
ini tidak memakai `sales_headers`, `sales_details`, atau
`sales_delivery_documents` retail sehingga kewajiban Invoice-before-SJ pada POS
tidak dilemahkan.

Satu SO mempunyai maksimal satu Reservation aktif dan dapat mempunyai beberapa
DO. DO pertama berjenis `INITIAL` dan dimulai pada status `READY`. Satu-satunya
DO tambahan adalah `BACKORDER` dan wajib menunjuk parent DO. Kekurangan,
kelebihan, atau salah barang yang ditemukan sebelum Customer menerima dicatat
sebagai discrepancy/revisi pada DO yang sama, bukan membuat DO `CORRECTION`.
Setelah DO selesai/diterima, perubahan wajib melalui Retur. Foundation menyimpan
planned/shipped/received quantity secara terpisah tetapi mutation discrepancy,
Retur, dan Invoice belum diaktifkan oleh runtime.

Foundation postflight dan rollback behavior PASS berdasarkan eksekusi manual
user. Migration `20260909147000` kemudian mengaktifkan Confirm baru agar secara
atomik membuat full Reservation dan satu DO `INITIAL/READY`. Shortage Reservation
hanya diizinkan ketika Warehouse opt-in; On Hand/FIFO/Movement/Invoice/Payment/
Finance tetap zero-effect pada Confirm. Runtime postflight dan behavioral PASS
berdasarkan eksekusi manual user. Gate berikutnya menambahkan Inventory
read model gabungan dan allocation detail melalui migration `20260909148000`.
Migration sudah live hanya pada isolated Development; postflight dan behavior
PASS berdasarkan eksekusi manual user. Authenticated smoke dan UAT masih
pending.

## 19. Inventory visibility untuk Delivery Backoffice (2026-09-09)

Gate `20260909149000` menambahkan read model tenant-scoped agar DO
`INITIAL/BACKORDER` hasil Backoffice dapat dilihat bersama Surat Jalan POS pada
workspace Inventory. Source dokumen dibedakan eksplisit; UI menampilkan nomor
SO, Customer, Gudang, jadwal, status, serta planned/shipped/received quantity.

Gate ini sengaja read-only. Checkbox bulk, Dispatch, penerimaan Customer, print
audit, discrepancy, dan Backorder untuk source Backoffice tetap dikunci. Tidak
ada mutasi On Hand, Reserved, Transit, FIFO, Invoice, Payment, Financial Event,
atau Journal. Mutation baru boleh dibuka setelah kontrak Gudang -> Transit ->
penerimaan Customer dan seluruh disposition discrepancy mempunyai evidence
server-side, retry/idempotency, serta behavioral test yang representatif.

Migration sudah live hanya pada isolated Development
`fkywtxucmyjvpwdiqpix`; targeted lint dan full Next build PASS. Manual
postflight, rollback-only behavior, authenticated UI smoke, dan UAT masih
pending. Production/staging tidak disentuh.

## 20. Dispatch Gudang ke Transit (2026-09-09)

Gate Transit usage `20260909150000` telah lulus postflight dan rollback
behavior manual pada isolated Development. Gate berikutnya
`20260909151000` local-ready membuka partial/full Dispatch saja. Runtime
membuat Stock Transfer source-linked dan memakai core canonical untuk
memindahkan FIFO batch serta saldo Gudang ke Transit
`SALES_DELIVERY_OUTBOUND`.

Reserve boleh shortage, tetapi Dispatch aktual harus mempunyai stok
fisik/FIFO; sisa tetap berada pada Reservation/DO. Penerimaan Customer,
sale-out final, Qty To Invoice, Invoice, Payment, dan Finance tetap belum
aktif. Remote dry-run memastikan hanya migration 151000 yang akan diterapkan
ke isolated Development; apply menunggu preflight manual.

### 20.1 Revisi approved 2026-09-11 — shortage Dispatch mengikuti Warehouse

Ketentuan lama bahwa Dispatch selalu wajib mempunyai stok fisik penuh diganti
untuk flow Backoffice: bila `warehouses.allow_negative_stock=true`, DO boleh
dipindahkan ke Transit outbound dengan FIFO provisional dan allocation shortage
khusus Backoffice. Jika flag `false`, penolakan `INSUFFICIENT_STOCK` tetap
berlaku. Customer Receipt boleh selesai sebelum replenishment; incoming batch
kemudian menutup shortage, merevaluasi batch Transit yang tersisa, dan memasok
variance COGS untuk quantity yang sudah keluar. Transfer gudang biasa tidak
mendapat exception ini.

PO shortage kelak harus mengikuti sumber SO/DO per hari. Runtime Dispatch hanya
menyimpan lineage untuk kebutuhan itu; pembuatan/sinkronisasi PO tetap scope
Purchasing terpisah agar supplier split dan status PO tidak diasumsikan.

## 20. Transit dipisahkan per Gudang dan tujuan operasi (2026-09-09)

Transit bukan satu Warehouse global Company. Satu Transit aktif terikat pada
satu Gudang operasional dan satu penggunaan: Pengiriman Customer, Transfer
antar Gudang, atau Retur Customer. Untuk Transfer A ke B, barang menunggu pada
Transit Transfer milik A sampai B mengonfirmasi. Retur menuju A menunggu pada
Transit Retur Customer milik A sampai Gudang A mengonfirmasi.

Gate foundation `20260909150000` menyediakan pemetaan tersebut pada Master
Gudang, uniqueness server-side, audit, dan lazy resolver. Transit lama tidak
diubah atau dipilih secara acak. Resolver baru akan dipanggil pertama kali oleh
runtime operasi terkait; pada gate foundation belum ada efek Stock/FIFO/
Movement/Delivery/Finance.

Migration foundation sudah live hanya pada isolated Development
`fkywtxucmyjvpwdiqpix`; lint dan full build PASS. Manual postflight,
rollback-only behavior, authenticated UI smoke, dan UAT masih pending.

## 21. Customer receipt dan Finance cost posting (2026-09-10)

Foundation quantity `20260909152000`, mapping Finance `20260909153000`, dan
clean receipt runtime `20260909154000` sudah live hanya pada isolated
Development; postflight dan rollback behavior ketiganya PASS menurut eksekusi
manual user. Receipt penuh mengonsumsi exact batch Transit milik DO, menambah
Accepted/Qty To Invoice, lalu membuat Event `BACKOFFICE_CUSTOMER_RECEIPT` HOLD.

Gate `20260909155000` sudah live pada isolated Development dan postflight serta
corrected behavioral rerun PASS. Gate memproses Event melalui Finance
canonical menjadi Dr COGS dan Cr Inventory Asset sesuai actual FIFO cost.
Tanggal penerimaan menjadi original event date; closed-period adjustment
mengikuti period fallback canonical. Dispatcher Event lain, Stock, receipt,
Invoice, Revenue/Tax/AR, dan Payment tidak diubah. Database migration,
behavioral rollback, authenticated queue smoke, serta UAT gate ini masih
pending dan hanya boleh dijalankan pada isolated Development.

## 22. Odoo-style Invoice, DP, Pro-Forma, dan installment foundation (2026-09-10)

Keputusan terbaru membedakan dokumen secara tegas: Pro-Forma adalah snapshot
komersial non-akuntansi; DP adalah Invoice tersendiri setelah SO Confirm dan
boleh sebelum pengiriman; Regular Invoice hanya mengambil `Qty To Invoice`
setelah Customer receipt; Payment Terms membentuk beberapa schedule pada satu
Invoice; setiap pembayaran kelak menghasilkan receipt, bukan Pro-Forma baru.

Migration `20260909156000` local-ready menyiapkan sembilan relation tenant-
scoped untuk Payment Term, Pro-Forma, Regular/DP Invoice, quantity hold, DP
deduction, receivable schedule, serta audit. Gate zero-backfill dan belum
menyediakan runtime/UI atau Finance effect. Production/staging tidak disentuh.
Runbook: `runbooks/BACKOFFICE_SALES_INVOICE_ACCOUNTING_FOUNDATION_ROLLOUT.md`.

## 23. Draft Regular/DP Invoice runtime (2026-09-10)

Keputusan DP dikunci: mode persentase menghitung nilai dari DPP Sales Order,
kemudian pajak mengikuti proporsi yang sama. Harga Regular Draft tetap dapat
diedit sebelum posting, tetapi pemisahan DPP/pajak dihitung server dari tax
snapshot canonical SO. Regular Draft hanya memegang Qty To Invoice yang sudah
diterima Customer; cancel melepaskan hold dan mempertahankan audit.

Gate `20260909157000` hanya membuka Draft lifecycle. Posting Invoice,
Revenue/Tax/AR, Payment, aplikasi DP final, dan Pro-Forma runtime tetap gate
berikutnya. POS retail, Stock, FIFO, receipt COGS, dan Finance Event existing
tidak diubah. Runbook:
`runbooks/BACKOFFICE_SALES_INVOICE_DRAFT_RUNTIME_ROLLOUT.md`.

## 24. Invoice multi-tax dan closed-period policy (2026-09-10)

DP tetap terlihat sebagai satu total bagi user, tetapi backend wajib menyimpan
pembagian proporsional per tax rule, rule version, tarif, dan tax account.
Regular Invoice memakai kelompok dari line snapshot-nya. Total tax breakdown
wajib sama dengan `invoice.tax_total`; snapshot yang sudah final tidak boleh
diubah. Jika periode yang menaungi `invoice_date` tertutup, posting Invoice
harus ditolak dan user memilih tanggal valid atau membuka kembali periode.
Accounting date tidak boleh digeser otomatis. Gate `20260909159000` hanya
menyiapkan breakdown ini; Event/Journal tetap belum aktif.

## 25. Regular/DP Invoice Finance mapping (2026-09-10)

Regular Invoice dan DP Invoice memakai dua system event serta Transaction
Category terpisah agar formula dan audit tidak ambigu. Regular mengakui AR,
Revenue, sisa Output Tax, serta debit Customer Advance untuk DP yang diterapkan.
DP mengakui AR, Customer Advance Liability, dan Output Tax proporsional.

Gate `20260909160000` hanya menyediakan mapping canonical dan approved posting
definition. Akun direuse dari mapping Finance nyata per Company dan migration
fail-closed bila missing/ambigu. Output Tax per tax group tetap mengikuti exact
`tax_account_id` snapshot `159000`; generic OUTPUT_TAX mapping tidak boleh
menghapus split tersebut. Runtime Post Invoice, final DP application, Event,
Journal, Payment, Stock/FIFO, POS, dan UI belum dibuka.

## 26. Regular/DP Invoice posting runtime (2026-09-10)

Referensi Odoo dikunci pada level dokumen: Down Payment dibuat sebagai Invoice
tersendiri, lalu menjadi baris pengurang pada Regular/final Invoice. Pajaknya
mengikuti proporsi pajak Sales Order. Sistem tidak boleh menghasilkan nilai
Invoice final negatif. Dalam MADS, DP `POSTED` tertua di-auto-fill, tetapi user
masih boleh mengubah penerapannya selama Regular Invoice berstatus Draft.

Gate `20260909161000` membuat Invoice posting dan Finance effect dalam satu
transaction. DP mem-post Dr AR, Cr Customer Advance basis, dan Cr Output Tax per
akun. Regular Invoice mem-post Dr AR net, Dr Customer Advance basis yang
dipakai, Dr Output Tax DP yang dikurangkan, Cr Sales Revenue, dan Cr Output Tax
Invoice saat ini. Quantity hold hanya menjadi invoiced quantity ketika Regular
Invoice berhasil diposting. Closed period, stale version, mapping ambigu,
lineage pajak invalid, dan Journal tidak seimbang menggagalkan seluruh operasi.

Payment bukan Pro-Forma baru. Gate Payment berikutnya akan mencatat setiap
penerimaan sebagai receipt/allocation terhadap satu Invoice: tiga kali bayar
berarti satu Invoice dengan tiga entry histori pembayaran, beserta total
dibayar dan sisa tagihan.

## 27. Execution tracker setelah Invoice posting (2026-09-10)

**CURRENT STEP 1/6 — Payment/Customer Receipt Backoffice; cutover memakai
effective timestamp dan compatibility settlement lintas source.**

Tracker penyelesaian scope Backoffice Sales sampai Finance:

1. **CURRENT:** Payment/Customer Receipt Backoffice — partial/multiple payment,
   allocation, outstanding, installment, DP settlement, dan histori;
2. Invoice Backoffice UI — Draft/Post, DP/Regular, schedule, lineage SO/DO, dan
   histori pembayaran;
3. dokumen Invoice — Qty Order/Diterima/Ditagih pada detail, print/PDF/export;
4. discrepancy — short/over/wrong item, Backorder, pre-Invoice Return, dan
   Return setelah selesai;
5. Finance closure — AR/Advance/Tax/Revenue/COGS/payment/queue reconciliation;
6. hardening/rollout — role, tenant, retry, concurrency, POS regression,
   authenticated smoke, UAT, production compatibility, dan feature enablement.

Audit source pada awal Step 1 membuktikan receipt existing belum source-neutral:
`customer_receipt_allocations.sales_id` mempunyai FK langsung ke
`sales_headers`, reader hanya mengambil `sales_invoice_snapshots`, dan posting
core merekonsiliasi total hanya dari allocation POS tersebut. Karena itu
Invoice Backoffice tidak boleh disisipkan ke kolom `sales_id` atau dipalsukan
sebagai Sale POS.

Pilihan impact:

- satu receipt mencampur Invoice POS dan Backoffice menjaga satu bukti
  pembayaran nyata dan satu Journal, tetapi membutuhkan perubahan pada legacy
  reader/save/post/reconciliation, lock dua source, union Customer Statement,
  serta regression POS yang lebih besar;
- receipt Backoffice sepenuhnya terpisah mengisolasi POS, tetapi menggandakan
  nomor/header/payment posting, memecah statement Customer, dan memaksa satu
  transfer nyata dipecah menjadi dua dokumen jika membayar dua source;
- Keputusan "mode tidak boleh diganti sampai seluruh piutang lama lunas"
  ditolak karena membuat cutover praktis tidak mungkin pada bisnis yang terus
  menerima Order. Batas yang benar adalah satu mode untuk **pembuatan transaksi
  baru** per Company pada satu waktu, dengan `effective_at` dan audit.
- Order/Invoice lama mempertahankan immutable `process_mode/source` snapshot dan
  boleh diselesaikan, dibayar, diretur, atau direkonsiliasi melalui runtime
  asalnya. Penyelesaian histori tersebut bukan pembukaan transaksi baru dengan
  mode lama.
- Karena piutang lama dan Invoice baru dapat overlap setelah cutover, Customer
  Receipt canonical harus dapat merekonsiliasi keduanya. Header receipt dan
  Finance Event tetap satu; allocation POS dan Backoffice memakai FK terpisah,
  sementara total receipt boleh mencakup kedua source milik Customer/Company
  yang sama. RPC POS existing tetap kompatibel dan tidak diberi akses membuat
  Order mode Backoffice.

### 27.1 Impact audit cutover Retail ke Backoffice

Audit implementasi lokal menemukan boundary berikut:

- feature `backoffice_delivered_qty_sales_enabled` saat ini adalah entitlement
  additive. Guard hanya mewajibkan feature aktif untuk dokumen Backoffice;
  runtime pembuatan Sale POS belum ditolak ketika feature tersebut aktif. Jadi
  implementasi saat ini **belum merupakan switch eksklusif** dan tidak boleh
  dipakai sebagai cutover production;
- dokumen Retail mempunyai snapshot immutable `sales_origin='POS'` dan
  `sales_process_mode='RETAIL_CONFIRM_INVOICE'`; dokumen Backoffice tersimpan
  pada aggregate terpisah dengan mode
  `BACKOFFICE_DELIVERED_QTY_INVOICE`. Snapshot dokumen lama tidak boleh diubah
  ketika Company berganti mode;
- Reservation Retail tersimpan di `sales_stock_reservations`/
  `sales_stock_reservation_lines`, sedangkan Reservation Backoffice tersimpan
  di `backoffice_sales_reservations`/
  `backoffice_sales_reservation_lines`. Stock Overview canonical sudah
  menjumlah kedua sumber. Cutover tidak boleh memindahkan, mengganti source,
  atau menghapus Reservation lama;
- procurement demand dan PO yang sudah lahir dari Order Retail tetap dimiliki
  pipeline Retail sampai selesai atau dibatalkan melalui runtime asalnya.
  Company mode terbaru tidak boleh dipakai untuk memilih cancel/release/
  fulfillment dokumen historis;
- semua Reservation baru wajib menghitung satu shared availability:
  On Hand dikurangi seluruh Reservation Retail dan Backoffice yang masih open.
  Override stock minus tetap berasal dari konfigurasi Warehouse;
- switch aman memerlukan mode history berisi `effective_at`, actor, reason,
  version/audit; guard server-side untuk creation baru; document-source routing
  untuk mutation lama; lock/idempotency; serta preview cutover read-only yang
  menghitung POS Draft, confirmed/scheduled Order, Reservation, procurement
  demand/PO, offline submission, Cashier Session, Payment, dan Return terbuka;
- mode change tidak boleh melakukan stock movement, Finance posting, backfill,
  atau penggantian FK. Rollback mode dilakukan sebagai event effective baru,
  bukan mengubah identitas dokumen yang telah dibuat.

Risiko regression utama jika kontrak tersebut belum dibuat adalah dua flow
menerima transaksi baru bersamaan, Reservation lama hilang dari availability,
double reservation, replay offline melewati batas cutover, atau cancel/release
memanggil runtime dari mode Company terbaru alih-alih source dokumen.

Cutover tidak boleh mensyaratkan seluruh POS Draft nol. Existing flow memang
menyimpan Order mendatang dan replacement Revision sebagai dokumen Draft
(`DRAFT_INPUT`/`SCHEDULED`) sampai tanggal/konfirmasi yang sah. Seluruh dokumen
Retail yang sudah mempunyai server-side identity sebelum `effective_at` menjadi
grandfathered pipeline: tetap boleh diedit/dikonfirmasi/diselesaikan memakai
runtime Retail dan immutable lineage-nya. Sesudah `effective_at`, yang ditolak
hanya pembuatan root Sale Retail baru; pembuatan/modifikasi dokumen lanjutan
harus dibuktikan berasal dari dokumen grandfathered, bukan disamarkan sebagai
Sale baru.

Offline transaction yang baru berada di perangkat dan belum tercatat di server
pada saat cutover tidak dapat dianggap grandfathered hanya dari jam perangkat.
Server-side offline submission yang sudah diterima sebelum cutover dapat
diteruskan sesuai source snapshot; submission terlambat memerlukan policy
review/fail-closed agar waktu client tidak dipakai untuk melewati mode gate.

Keputusan user: sesudah cutover, Revision baru atas Order source lama yang belum
final tetap diperbolehkan sebagai kelanjutan lineage source, bukan root Sale
baru. Revision tersebut harus ikut conversion pair bila dipilih untuk pindah.

## 28. Cross-process cutover foundation (2026-09-10)

User menyetujui selective conversion dua arah. Revision baru atas Order source
yang belum final tetap merupakan kelanjutan lineage lama dan dapat masuk
conversion pair; ia bukan root Sale baru. Dokumen final tidak dikonversi.

Gate `20260909162000` berstatus **DATABASE LIVE** pada isolated Development;
user mengonfirmasi postflight dan behavioral test PASS.
Foundation menambah:

- `company_sales_process_settings` default Retail untuk Company existing dan
  Company baru, tanpa dikonsumsi runtime creation saat ini;
- immutable `company_sales_process_mode_history`;
- cutover plan, candidate item, dan immutable audit;
- pure classifier: `CONVERT`, `KEEP_SOURCE`, atau `BLOCKED`, beserta requirement
  formal Invoice cancellation, Revision-pair conversion, dan procurement
  lineage transfer.

Foundation tidak menyediakan apply/switch RPC dan tidak menyentuh dokumen
existing. Gate berikutnya baru membangun preview nyata serta mengunci mapping
Retail/Office berdasarkan status Invoice, Payment, Dispatch, Stock/FIFO,
Finance, Revision, Reservation, dan procurement/PO.

## 29. Actual-data cutover preview runtime (2026-09-10)

Gate `20260909163000` berstatus **DATABASE LIVE; BEHAVIOR/POSTFLIGHT PASS** pada
isolated Supabase Development. RPC Super Admin membaca Company aktif serta seluruh
dokumen source yang belum final, lalu mengembalikan keputusan `CONVERT`,
`BLOCKED`, atau `KEEP_SOURCE` beserta fakta dan requirement-nya.

Preview memakai sumber aktual: pending Revision diperlakukan sebagai satu pair;
Reservation dan procurement/PO tidak dilepas; Dispatch, final Stock effect,
payment history, dan Finance event `POSTED` menjadi blocker sesuai kontrak.
Mode Office dan entitlement tetap dua hal terpisah. Tidak ada plan yang
dipersist, Company switch, atau mutation dokumen pada gate ini.

## 30. Persistent cutover preview plan (2026-09-10)

Gate `20260910110000` berstatus **DATABASE LIVE + POSTFLIGHT/BEHAVIOR PASS**
pada isolated Development.
Hasil preview aktual disimpan sebagai plan `PREVIEWED`; Company settings version
disimpan pada header dan source document version disimpan per candidate item.
Create dilindungi Super Admin boundary, active Company, advisory lock,
operation-id/request-hash idempotency, dan one-open-plan guard.

Gate ini hanya menulis plan, item, audit `CREATE_PLAN`, serta migration ledger.
Ia tidak mengubah mode, entitlement, dokumen, Reservation, procurement/PO,
Stock/FIFO, Invoice, Payment, Finance, atau Offline. `effective_at` hanya
direkam. Refresh/cancel plan serta apply/conversion/switch belum dibuka.
User mengonfirmasi sembilan postflight check PASS dan runtime plan/item/audit
masih nol.
Behavioral rollback exact version/idempotency/open-plan boundary juga
dikonfirmasi PASS oleh user.

## 31. Cutover plan refresh/cancel (2026-09-10)

Keputusan user: refresh tidak boleh mengubah target mode, effective time, atau
reason. Perubahan parameter mewajibkan cancel plan lama lalu create plan baru.
Cancel tidak menghapus plan/item/audit.

Gate `20260910120000` berstatus **DATABASE LIVE + POSTFLIGHT/BEHAVIOR PASS** pada
isolated Development. Ia menambah optimistic plan
version serta refresh/cancel RPC dengan Super Admin boundary, Company lock,
exact retry, stale version guard, dan immutable audit response. Refresh hanya
mengganti candidate snapshot/item sebelum apply; cancel menyimpan seluruh
histori. Apply/conversion/switch dan semua efek operasional tetap tertutup.

## 32. Keputusan boundary Apply dan blocker mapping Step 1D (2026-09-10)

User menetapkan bahwa item `BLOCKED` tidak menggagalkan switch. Item tersebut
tetap grandfathered dan diselesaikan melalui source flow. Apply hanya manual
oleh Platform Super Admin pada/setelah `effective_at`; tidak ada scheduler.
Revalidasi plan/settings/source version, conversion seluruh item `CONVERT`,
penandaan `BLOCKED`/`KEEP_SOURCE`, mode history, dan update Company mode harus
berada dalam satu transaksi. Kegagalan satu conversion membatalkan seluruh
Apply dan tidak boleh meninggalkan mode setengah berubah.

Audit schema menemukan dua mapping yang memerlukan keputusan eksplisit sebelum
converter dibuat:

- Retail menyimpan pending Revision sebagai source Order aktif dan replacement
  Draft terpisah, sedangkan Backoffice merevisi SO bernomor sama secara in-place;
- Retail Sale wajib memiliki Cashier Session, Store, dan POS Terminal, sedangkan
  SO Backoffice tidak membawa Cashier Session/POS Terminal.

Tidak boleh membuat target dengan mengarang status Revision atau identitas POS.

Keputusan lanjutan user untuk Step 1D:

- pending Revision Retail menjadi `BLOCKED` dan tetap diselesaikan pada source
  flow sampai Draft revisi dikonfirmasi atau dibatalkan; pasangan source dan
  replacement tidak dikonversi;
- target Retail hasil Office-to-Retail memakai origin sistem
  `BACKOFFICE_CUTOVER`, bukan Cashier Session/POS Terminal buatan;
- hanya origin tersebut yang boleh mempunyai `session_id`, `pos_id`, dan
  `created_session_id` kosong. Sale normal origin `POS` tetap wajib membawa
  ketiganya;
- preview/plan lama harus dibatalkan dan dibuat ulang setelah classifier baru,
  sehingga keputusan `CONVERT_REVISION_PAIR` tidak ikut masuk ke Apply.

Fondasi lokal migration `20260910130000` menerapkan constraint/trigger dan
classifier tersebut. Apply atomik, conversion dokumen, dan mode switch tetap
belum dibuka sampai gate ini dijalankan serta lulus di isolated Development.

## 33. Backoffice SO activity log seperti Odoo (2026-09-10)

Revisi Backoffice tetap dilakukan pada SO dan nomor dokumen yang sama. Audit
immutable existing menjadi satu-satunya sumber histori; UI menampilkannya pada
timeline “Log aktivitas” terpisah di bawah dokumen dengan aksi, actor, waktu,
dan alasan. Histori tidak lagi dicampur ke tab Informasi Lainnya. Scope ini
hanya presentation layer dan tidak mengubah lifecycle maupun downstream effect.

## 34. Cutover lineage link dan activity log lintas dokumen (2026-09-10)

Keputusan user untuk converter berikutnya:

- source yang benar-benar berhasil dikonversi ditutup sebagai `CANCELED`
  khusus cutover; source tidak boleh ditutup pada preview atau sebelum target
  berhasil dibuat;
- log pada source wajib menampilkan jenis dan **nomor dokumen pengganti yang
  dapat dibaca user** serta link untuk membuka target. UUID internal tidak boleh
  menjadi label UI;
- relasi canonical source-target tetap memakai
  `sales_process_cutover_items.target_document_id/type/no` dan immutable
  `sales_process_cutover_audit`. UI membaca relasi tersebut sebagai event
  cutover pada histori source; tidak membuat salinan event hanya demi tampilan;
- open procurement/PO dan Office quotation non-TEMPO bertanggal mendatang tetap
  `BLOCKED`/grandfathered sesuai keputusan sebelumnya, bukan dipaksa mapping;
- histori aktivitas harus tersedia secara konsisten pada seluruh dokumen MADS,
  bukan hanya SO.

Audit repository menemukan 58 tabel audit/history canonical lintas Sales,
Purchase, Inventory, Payment, Finance, master, dan konfigurasi. Karena format
dan boundary-nya berbeda, implementasi yang aman adalah satu **normalized read
contract** dan satu komponen UI activity log yang dapat dipakai ulang. Sumber
tulis tetap audit/ledger canonical masing-masing modul; tidak dibuat satu tabel
audit generik yang menduplikasi event atau menggantikan Finance/Stock ledger.

Kontrak baca minimum: Company, jenis/id/nomor dokumen, aksi, actor, waktu,
alasan, ringkasan perubahan yang aman, serta optional linked-document
type/id/number/route. Detail before/after yang sensitif wajib difilter menurut
permission server-side. Dokumen yang belum memiliki coverage audit tidak boleh
memperoleh histori sintetis; coverage append-only modulnya harus dilengkapi
lebih dahulu.

User kemudian mengonfirmasi cakupan global: activity log berlaku pada seluruh
record bisnis MADS seperti pola Chatter Odoo, termasuk dokumen transaksi,
master data, dan konfigurasi. Tujuannya adalah tracing perubahan/aktivitas,
bukan merekam setiap read atau halaman yang dibuka.

Event minimum yang dicakup adalah create, edit field yang dipilih, perubahan
status, submit/approval/reject, cancel, post, import, tindakan sistem, alasan,
actor, timestamp, dan lineage/link ke dokumen terkait. Komunikasi/chat,
attachment, follower, serta scheduled activity bukan bagian dari keputusan ini
dan tetap deferred sampai diminta eksplisit. Keputusan ini tidak menghalangi
Step 1E untuk lebih dahulu menyimpan dan menampilkan lineage source-target
cutover.

## 35. Otoritas nilai saat cutover dan gap parity (2026-09-10)

User menetapkan cutover hanya mengganti execution flow. Harga, Pricelist,
discount, tax, tempo/payment term, tanggal Order/kirim, rounding, dan total
target wajib preserve persis dari source. Resolver target tidak berjalan saat
conversion; resolver baru boleh berjalan bila user mengedit target setelah
cutover.

Audit schema Step 1E-B menemukan dua gap konkret yang tidak boleh dipetakan
diam-diam:

- Retail memiliki `delivery_fee_amount` dan invoice display mode, sedangkan SO
  Backoffice belum mempunyai field ongkir ekuivalen;
- Backoffice mendukung payment-term snapshot/schedule bertahap, sedangkan
  Retail hanya mempunyai satu `due_date`.

Converter belum ditulis sampai diputuskan apakah source dengan dua bentuk data
tersebut menjadi `BLOCKED`/grandfathered atau parity target dibangun lebih dulu.

## 36. Converter dua arah dan adopsi sesi Retail (2026-09-11)

Parity ongkir dan batas satu absolute due date sudah ditutup. User kemudian
mengonfirmasi Step 4B Retail-to-Backoffice, Step 4C Backoffice-to-Retail beserta
operation/audit forward-fix, dan Step 4D Retail real-session adoption seluruhnya
PASS pada isolated Development.

Backoffice-to-Retail selalu menghasilkan Draft yang wajib dikonfirmasi ulang;
future TEMPO menjadi Scheduled Draft. Draft hasil cutover dibuka tanpa repricing,
lalu hanya dapat diambil sesi POS OPEN dengan Company, Store, dan Warehouse yang
sama. Resolver Retail baru berjalan ketika isi transaksi benar-benar diedit.

## 37. Atomic Apply dan mode-authoritative root creation (2026-09-11)

Step 4E local-ready menerapkan keputusan Apply yang sudah dikunci:

- revalidasi plan/settings/live preview/source version dan semua conversion
  berada dalam satu transaksi dengan Company mode switch;
- item `BLOCKED`/`KEEP_SOURCE` menjadi `KEPT`, tetap grandfathered, dan tidak
  menggagalkan switch;
- root Sale/Quotation baru hanya boleh masuk melalui mode Company aktif;
- Offline envelope baru ditolak sebelum queue bila Retail tidak aktif;
- Revision Retail atas Order grandfathered tetap diperbolehkan sebagai lineage
  source, melalui wrapper internal yang masih menjalankan seluruh guard canonical;
- source lama tidak diganti `sales_process_mode`-nya dan tetap memakai runtime
  asal sampai final;
- mode switch sendiri tidak membuat Stock Movement, FIFO, Payment, Invoice,
  Finance Event, atau Journal.

Step 4E database sudah terpasang pada isolated Development dan corrected
behavioral dikonfirmasi PASS user; postflight final belum dikonfirmasi
terpisah. Step 4F menambahkan UI Platform Super Admin lokal untuk
preview/create/refresh/cancel/apply melalui RPC canonical. Authenticated smoke,
deployment, UAT, production, dan staging belum dilakukan.

## 38. Step 5A/6 — Invoice client activation (2026-09-11)

Setelah Customer Receipt menyelesaikan SO, Sales memperoleh tombol `Buat
Invoice`. Form mengambil Qty diterima yang belum dialokasikan, tetapi Qty,
harga, diskon, pajak, ongkir, tanggal Invoice, jatuh tempo, dan catatan masih
dapat diedit selama Draft. Satu SO dapat mempunyai beberapa Invoice; alokasi
Draft menahan Qty agar concurrent Draft lain tidak melebihi sisa.

Penerbitan tetap tindakan eksplisit dan hanya role/custom permission Finance
berkapabilitas `POST` yang dapat melakukannya. Nomor final, AR schedule,
Financial Event dan Journal dibuat oleh runtime canonical saat posting. Tombol
Print/Download baru tersedia pada Invoice `POSTED`; final Invoice immutable dan
koreksinya tetap melalui Retur/Credit Note.

Status Step 5A/6 sekarang `LOCAL READY`: UI/API/migration/gate sudah ditulis,
lint/build PASS, tetapi SQL, authenticated smoke, dan UAT isolated Development
belum dijalankan. Step 5B/6 berikutnya baru boleh dimulai setelah gate Step 5A
PASS; scope-nya adalah integrasi histori/payment visibility dan closing E2E,
bukan perubahan POS Retail.
