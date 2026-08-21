# Gate Implementasi dan Rollout POS v1

**Status:** APPROVED delivery guardrail  
**Tanggal:** 2026-07-20  
**Pilot awal:** satu Company, satu Store, satu POS Terminal  
**Prinsip:** gate berikut bersifat berurutan. UI dapat diprototipe, tetapi tidak boleh dianggap selesai atau dihubungkan ke data production sebelum dependency gate lulus.

---

## 1. Checklist Wajib pada Setiap Gate

Setiap gate harus memiliki artefak berikut:

1. requirement ID dan source-of-truth yang dituju;
2. migration forward-only yang dapat dijalankan ulang secara aman atau mempunyai precondition jelas;
3. backfill untuk data lama, termasuk row gagal/ambiguous;
4. RLS, GRANT, API, RPC, dan feature-entitlement guard;
5. idempotency/concurrency contract;
6. automated test dan UAT evidence;
7. observability minimum: correlation/source ID, error status, retry policy, tanpa secret/PII berlebihan;
8. deployment runbook, postflight query, rollback teknis, dan rollback operasional.

Rollback tidak selalu berarti `DROP COLUMN`. Untuk migration data berisiko, gunakan expand → backfill → dual-read/compare → cutover → contract. Setelah transaksi baru dibuat, rollback operasional dapat berarti mematikan feature, menghentikan posting, atau kembali ke read-only sambil mempertahankan histori.

---

## 2. G0 — Baseline dan Migration Control

### Deliverable

- tetapkan canonical migration directory dan manifest urutan file;
- snapshot schema staging/production tanpa secret;
- inventarisasi extension, enum, function signature, trigger, policy, grant, index, dan applied migration;
- klasifikasikan standalone SQL lama: migrate, supersede, atau archive;
- buat data-quality query untuk missing/mismatched `company_id`, duplicate business key, negative stock, orphan FK, unbalanced journal.

### Exit criteria

- database kosong dapat dibangun dari nol;
- snapshot staging dapat di-upgrade tanpa kehilangan data;
- applied-state production terverifikasi, tidak diasumsikan dari repo;
- semua SQL berikutnya mempunyai nomor/owner/dependency/rollback note.

### Stop condition

Jangan lanjut G1 jika schema repo dan schema live belum dapat dibandingkan atau ada orphan tenant yang belum diselesaikan.

---

## 3. G1 — Tenant, Security, Role, dan Feature Entitlement

### Deliverable

- canonical Company/Store/POS/Warehouse/User membership model;
- tenant `NOT NULL` dan cross-table consistency constraint;
- tenant-scoped business keys;
- role assignment scope per Company/Store/Warehouse;
- feature registry Company, hanya dimutasi Super Admin;
- active Company context eksplisit dan audit actor;
- SECURITY DEFINER hardening: fixed search path, minimal execute grants, actor check, input tenant validation;
- matrix RLS/API/RPC seluruh tabel/action.

### Test minimum

- setiap role mencoba SELECT/INSERT/UPDATE/DELETE pada Company sendiri dan Company lain;
- forged `company_id`, `store_id`, `warehouse_id`, `user_id` ditolak;
- feature disabled ditolak oleh API/RPC walau request dibuat manual;
- Company Admin tidak dapat menaikkan user menjadi Super Admin atau menyentuh Company lain;
- Super Admin dapat beroperasi lintas Company tetapi setiap mutation membutuhkan target Company eksplisit.

### Exit criteria

- tidak ada tabel tenant-bearing tanpa policy/constraint yang didokumentasikan;
- tidak ada route client yang memakai service-role key;
- negative access test lulus 100%.

---

## 4. G2 — Canonical Master Data dan Import Framework

### Deliverable

- Product Category, Product, UOM, Product UOM/price, Warehouse, Supplier, Customer, Customer Category, Pricelist, Payment Method, Transaction Category, Tax, dan COA minimum;
- stable internal ID + tenant-scoped code/name rules + active/inactive lifecycle;
- master version/update timestamp untuk cache/offline;
- generic export/import job: template/export, mapping, dry-run, row validation, update warning, partial result, history, downloadable error rows;
- Opening Stock dipisahkan dari Product import;
- no auto-create reference saat Product import kecuali mode eksplisit yang belum diaktifkan pada v1.

### Gate aktif Import/Export

- keputusan user 2026-08-11 menambahkan pre-deploy Global Role-Aware Data
  Exchange Center. Satu menu global menggantikan entry point Import/Export
  Inventory hanya setelah feature parity dan authenticated smoke; katalog
  module/type/action wajib server-authoritative dan Finance report hanya
  export. Delivery mengikuti DEX-1 sampai DEX-4 pada
  `GLOBAL_DATA_EXCHANGE_CENTER_SPEC.md`;
- DEX-1 repository audit selesai pada 2026-08-11. Existing path mempunyai
  sepuluh fixed master type, satu guard Owner/Admin yang masih menggabungkan
  Export dan Import, serta dua Finance XLSX tanpa explicit Finance role guard
  di API. Target catalog/action contract dan DEX-2 implementation map dicatat
  pada `audits/DEX1_GLOBAL_DATA_EXCHANGE_ACCESS_CATALOG_AUDIT_2026-08-11.md`;
- DEX-2 local-ready pada 2026-08-11: shared server catalog/action evaluator,
  authenticated global Export Center, role-aware 10 master CSV, serta tujuh
  Finance XLSX memakai canonical report/read path. Scoped lint dan production
  build PASS. Authenticated role/cross-Company/XLSX smoke pada
  `runbooks/DEX2_ROLE_AWARE_EXPORT_CENTER.md` wajib selesai sebelum DEX-3;
- DEX-3 local-ready pada 2026-08-11: tab Import global hanya diberikan oleh
  catalog server kepada Owner/Admin/Super Admin dan memakai ulang sepuluh fixed
  template, staging, preview/validation, guarded partial commit, serta history
  existing. Tidak ada migration atau jalur tulis baru. Authenticated parity,
  negative-role, dan cross-Company smoke pada
  `runbooks/DEX3_GLOBAL_IMPORT_CONSOLIDATION.md` wajib PASS sebelum DEX-4
  memindahkan navigation Inventory lama;
- user menerima UI DEX-3 pada 2026-08-11. DEX-4 local-ready menghapus entry
  point `Inventory > Import & Export` dari sidebar/app launcher dan menjadikan
  Global Data Exchange satu-satunya visible entry. Component, API, job history,
  dan guarded RPC lama tetap dipertahankan untuk compatibility. Post-cutover
  role/cross-Company/CSV/XLSX/import smoke pada
  `runbooks/DEX4_INVENTORY_CUTOVER_AND_DEPLOYMENT_EVIDENCE.md` masih wajib PASS
  sebelum DEX dinyatakan complete;

- empat import sederhana (Product Category, UOM, Warehouse, Supplier) sudah
  mencapai API/UI;
- Phase-35 readiness, Phase-36/37 automatic-code DB/UI, dan Phase-38 code-less
  validator sudah PASS; Phase-39 template/export UI dan smoke user selesai;
- Phase-40 migration, forward fix `20260727100000`, postflight, behavioral
  test, dan Phase-38 regression sudah PASS; Phase-41 template/export/preview
  UI untuk Customer Category, COA, dan Transaction Category sudah lulus
  authenticated smoke;
- Phase-42 grouped Product Import database, forward fix, postflight,
  behavioral test, dan regression sudah PASS. Product dan seluruh Product-UOM
  diproses sebagai satu atomic group melalui guarded Product RPC;
- Phase-43 Backoffice template/export dan preview grouped Product local-ready
  untuk authenticated smoke. Ringkasan dihitung per `product_key`, detail
  memakai nama UOM, dan Opening Stock tetap workflow terpisah;
- Koreksi Product-UOM additive 2026-08-21 local-ready: Template dan Export
  menampilkan UOM existing sebagai `REFERENCE` serta satu baris `INPUT` kosong
  per Product. Reference row tidak masuk staging; validasi mempertahankan
  partial preview agar baris valid tetap dapat di-commit dan baris error dapat
  diunduh. Job nonterminal dapat dibatalkan manual, dan
  upload/pemetaan milik actor yang ditinggalkan 15 menit ditutup otomatis
  setelah permission jenis import diperiksa ulang.
- Phase-44 Product-Supplier migration, 11-check postflight, behavioral test,
  dan regression suite dikonfirmasi PASS. Phase-45 template/export/preview UI
  lint/build dan authenticated smoke PASS; relasi wajib memakai
  Product, Supplier, dan UOM pembelian existing, serta preferred Supplier
  tetap maksimal satu aktif per Product;
- Phase-46 Minimum Stock Produk–Gudang sudah `COMPLETE`. Threshold menjadi
  konfigurasi tenant-scoped terpisah dari `product_stocks`, memakai base UOM,
  bersifat opsional, dan tidak membuat movement, Stock Request, atau Supplier
  Order otomatis;
- live Phase-46 preflight seluruhnya `PASS`/`INFO`: satu Product, tiga Gudang,
  tiga eligible pair, zero balance/movement, zero ambiguity/orphan/job aktif.
  Migration `20260728090000`, 12-check postflight, behavioral test, dan
  regression suite dikonfirmasi aman oleh user;
- Phase-47 Backoffice Minimum Stock guarded API/UI dan fixed CSV
  template/export/preview local-ready. Threshold ditampilkan dalam nama Base
  UOM dan tetap stock-neutral; authenticated smoke menunggu user;
- ekspansi ke seluruh master yang dapat dibuat user memakai kontrak versioned
  pada `MASTER_IMPORT_FIXED_CSV_CONTRACTS.md`;
- sebelum ekspansi schema/job processor, wajib lulus
  `g2_phase35_full_master_import_preflight.sql`;
- Product, Pricelist, dan Payment Method diproses sebagai atomic group;
- kode teknis Category/UOM/Warehouse/Supplier/Customer Category/Pricelist/
  Payment Method/custom Transaction Category dibuat server-side dan tidak
  diminta pada create template; UUID tetap canonical;
- Product SKU, Customer code, COA account code, Tax code, barcode, dan kode
  Product milik Supplier tetap business-facing;
- Company, Staff/password, Opening Stock, transaksi, stock movement, dan journal
  tidak boleh masuk generic master import.

### Test minimum

- typo reference tidak membuat UOM/Gudang/Kategori baru;
- referensi dapat dipilih dengan ID atau code/name yang unambiguous;
- duplicate/multi-match menghasilkan row error;
- satu row gagal tidak membatalkan row valid;
- update existing menyimpan before/after audit;
- import Company A tidak dapat reference master Company B;
- UOM factor, precision, weight, dan price per UOM tervalidasi.

### Exit criteria

- user dapat membuat/edit master via form maupun import dengan hasil yang sama;
- Product dan stock tidak lagi bergantung pada free-text category/UOM/warehouse;
- cache payload master mempunyai version contract.

---

## 5. G3 — Stock Ledger, FIFO, Bundle, Opname, dan Adjustment

**Status 2026-07-28:** `COMPLETE AT G3 CORE BOUNDARY`. Integrated stress dan
regression diteruskan tanpa error; rerun Phase-14 menunjukkan seluruh invariant
core PASS, `SETUP` tetap expected karena fixture di-rollback, serta coverage
G4/G5 tetap `DEFERRED`. Sale/Bundle checkout deduction/Sales Return sekarang
masuk G4; Receipt/Purchase Return tetap G5.

### Deliverable

- satu atomic stock-posting service/RPC untuk semua movement source;
- base-UOM quantity snapshot dan Product-Warehouse balance;
- movement immutable, source unique, actor/time/status tercatat;
- nonnegative final stock dengan row lock/atomic guarded update;
- Opening, Receipt, Transfer, Sale, Return, Bundle, Ketul, Opname, Adjustment event type;
- FIFO receive/consume/return/reversal dan valuation;
- Bundle expansion tanpa nested Bundle;
- Stock Opname blind count dan posting Adjustment tanpa membekukan penjualan;
- stock real, movement/card, valuation, opname report/read model.

### Test minimum

- qty nol/negatif ditolak;
- 20 checkout/transfer concurrent tidak membuat stock negatif atau lost update;
- duplicate source/idempotency tidak menggandakan movement;
- UOM jual dikonversi tepat ke base;
- Bundle mengurangi komponen tepat sekali;
- FIFO multi-batch dan return mengembalikan layer sesuai contract;
- Opname yang overlap dengan sale menghasilkan variance deterministik sesuai timestamp/policy;
- Company/Warehouse mismatch ditolak.

### Exit criteria

- balance dapat direkonstruksi dari movement;
- `product_stocks` sama dengan agregat ledger pada reconciliation query;
- tidak ada jalur mutation stock langsung dari client/table API.

---

## 6. G4 — POS Online/Offline dan Operasional Kasir

**Status aktif 2026-08-05:** Phase 49 Customer Balance foundation dan digest
forward fix dikonfirmasi user seluruhnya PASS. Phase 50 operational Backoffice
UI sekarang local-ready untuk authenticated smoke: lifecycle/liability,
correction request, maker-checker review, dan statement memakai RPC guarded.
Phase 51 live preflight dikonfirmasi seluruh data invariant PASS dengan tiga
gap schema/runtime yang expected `SETUP`. Phase 52 migration, postflight,
behavior, dan regression dikonfirmasi user seluruhnya PASS: kelebihan Payment
`CASH`/`TRANSFER` pada Sale ONLINE
dapat dipilih sebagai append-only Customer Balance credit dalam transaksi
posting yang sama, dengan Payment/receipt snapshot, cache reconciliation,
idempotency, audit, dan Financial Event HOLD.
Foundation mencakup lifecycle
`ACTIVE/WIND_DOWN/DISABLED`, system internal method, append-only ledger,
maker-checker correction, read-only statement, audit/idempotency, dan Financial
Event HOLD. Checkout usage, credit dari overpayment/refund/Ketul, exceptional
settlement, offline Customer Balance, TEMPO, Ketul, bank matching, reversal
source, aging/export, dan jurnal G6 tetap belum dibuka.

Phase 53 diterima user dan membuka pilihan POS `Kembalikan` atau `Simpan sebagai
saldo` hanya untuk selisih Cash/Transfer online serta Customer reguler eligible.
Phase 54 sekarang menyiapkan audit SELECT-only pemakaian saldo lama sebagai
tender: seluruh saldo wajib habis, saldo lebih besar dari grand total wajib
memblokir checkout, dan lifecycle `WIND_DOWN` tetap mengizinkan debit lama.
Live Phase-54 kemudian dikonfirmasi user aman: tiga gap runtime/source/snapshot
tepat `SETUP`, seluruh invariant data/dependency PASS, dan direct browser writes
tetap false. User sekaligus membuka scope STK-006 untuk permission Stock minus
POS. Phase 55 dikonfirmasi user seluruhnya PASS; runtime Stock minus tetap
default OFF. Phase 56 database dan behavioral gate kemudian dikonfirmasi PASS,
sedangkan Phase 57 menghubungkan full-balance tender ONLINE ke PWA tanpa
melemahkan Offline/direct-write boundary. Phase 58 menyiapkan fondasi STK-006:
entitlement, policy Company, opt-in Gudang sale-source, permission per user,
audit, serta kontrak authorization/allocation/replenishment. Phase ini belum
mengubah canonical Sale; `STOCK_SHORTAGE` tetap fail-closed sampai runtime
allocation dan reconciliation pada phase berikutnya dibuka.
User kemudian mengonfirmasi migration, postflight, behavioral test, dan
regression Phase 58 seluruhnya PASS. Phase 59 kembali ke SELECT-only preflight
untuk membuktikan baseline konfigurasi, cost basis, Movement constraint,
Stock–FIFO–Movement reconciliation, online Sale execution path, Offline/import
boundary, dan dependency replenishment sebelum runtime mutation dibuat.
Live Phase-59 kemudian diterima tanpa `BLOCKER`/`REVIEW`: tiga runtime gap tepat
`SETUP`, G5/G6 tepat `DEFERRED`, konfigurasi tetap nol, dan seluruh baseline
reconciliation PASS. Phase 60 menyiapkan runtime online non-Bundle yang tetap
default OFF: authorization/limit/reason server-side, HPP provisional,
controlled negative Movement, outstanding allocation, serta automatic FIFO
replenishment reconciliation. User mengonfirmasi seluruh rollout/fix/regression
Phase 60 sukses. Phase 61 menghubungkan guarded configuration ke Backoffice dan
reason/retry UX ke PWA: Super Admin tetap mengelola entitlement, Owner/Admin
mengelola policy Company, opt-in Gudang, serta izin user, sedangkan Kasir hanya
mendapat modal alasan setelah server menyatakan izin tersedia. Default tetap
OFF, online non-Bundle saja; authenticated smoke menjadi gate aktif.
Refund-to-balance, Offline Customer Balance, Ketul, dan exceptional
settlement tetap gate terpisah. Histori Cash change tidak dibackfill dan tetap
dianggap sudah dikembalikan.

Riwayat G4: Phase 13 retained Offline Sale queue foundation pernah mencapai
`LOCAL-READY`. User mengonfirmasi migration, corrected postflight, behavioral,
seluruh regression, dan reconciliation Phase-12 PASS. User mengonfirmasi migration Phase-4,
17-check postflight, behavioral test, dan regression clear. PWA production
entrypoint sekarang memakai login/context, Cashier Session, real Product-UOM,
canonical Draft/Post, server pricing, shortage Draft, Split Payment, dan
receipt snapshot. Checkout offline diblokir eksplisit; Return, Expense,
Deposit, Customer Balance, dan
Ketul tetap belum dibuka.

Smoke pertama menemukan predicate Session/PWA masih exact-Cashier dan belum
mengikuti inheritance Super Admin serta Company Owner/Admin yang sudah
disetujui. Forward fix `20260729080000` dan UI provisioning Cashier dengan Toko
wajib sudah local-ready; rollout manual dan smoke ulang menjadi gate aktif.
Smoke Store Manager kemudian membuktikan Store role tersebut belum ikut
predicate POS walaupun matrix mengizinkan checkout. Forward fix
`20260729090000` membatasi Store Manager hanya pada Store assignment aktifnya.

User mengonfirmasi Terminal/Gudang sudah terbaca. Phase 5 kemudian menutup
empat UX gap sebelum roadmap dilanjutkan: layout tablet-first, receipt fallback
ke tab cetak, reset transaksi segera setelah POSTED, dan pilihan Pricelist
Cashier. Forward migration `20260729100000` menjaga mode AUTO assignment
Customer serta membatasi override pada Global eligible atau Pricelist khusus
Customer terpilih. User kemudian mengonfirmasi rollout dan authenticated tablet
smoke clear. Phase 6 dimulai dari diagnostic SELECT-only untuk side-effect-free
Draft, cross-session same-Store access, lifecycle metadata, stale age,
single-editor heartbeat lock, takeover/force release, cancel, audit, guarded
RPC, dan direct-write boundary. Split payment tetap belum dibuka.

Live Phase-6 preflight diterima bersih: dependency dan seluruh Draft
side-effect/identity/snapshot invariant `PASS`, direct browser write seluruhnya
`false`, zero existing Draft, sedangkan 11 kolom, lima routine, same-Store
visibility, dan audit action tepat berstatus `SETUP`. Foundation
`20260729120000` sudah lolos rollout manual dengan nomor/metadata Draft, guarded
same-Store list, heartbeat lock lima menit, confirmed stale takeover,
Manager/Admin force release, cancel, audit, serta public Save/Post wrapper yang
menutup bypass ke private core. PWA sekarang menyediakan daftar Draft per Store,
resume dengan server repricing dan payment reconfirm, heartbeat, takeover,
Manager/Admin force release, serta cancel historis. Lint/build lokal PASS;
authenticated tablet smoke menjadi gate aktif. Split payment belum dibuka.

User kemudian menerima Draft UI dan custom modal sebagai good. Phase 8 dimulai
dengan diagnostic SELECT-only untuk array payment server, fee per leg,
minimal dua metode eligible per Store, histori total/snapshot/tender, duplicate
method, payment-leg idempotency identity, serta browser write boundary. Belum
ada schema, checkout, stock, event, atau receipt mutation.

Live preflight Phase 8 bersih: tiga dependency dan server multi-leg/per-leg fee
`PASS`, satu Store memiliki minimal dua metode dari tipe berbeda, satu posted
Sale/payment konsisten, browser write tertutup, dan belum ada histori split.
Satu-satunya expected `SETUP` adalah `client_payment_key`. Forward migration
`20260729150000` menambah stable per-leg UUID, compatibility normalization,
duplicate key/metode guard, unique persisted identity, serta receipt
traceability tanpa mengubah calculation. User mengonfirmasi rollout, postflight,
behavior, dan regression sukses. PWA kini mendukung pembagian exact-total ke
beberapa metode, per-leg Cash/proof, stable retry key, serta fee estimate yang
tetap server-authoritative. Setelah user meminta lanjut sesuai rundown, gate
berpindah ke SELECT-only audit lock/idempotency, single final effect,
Payment–Movement–FIFO reconciliation, nonnegative stock, dan fixture dua Kasir
sebelum true concurrent double-post. Offline queue tetap belum dibuka.

Live Phase-10 preflight kemudian seluruhnya `PASS`: fixture mempunyai dua user
efektif, Terminal, Payment, serta stok/FIFO; public wrapper mengunci Sale;
private core mengunci stok, memakai FIFO, dan mengembalikan replay idempotent;
seluruh identity, Payment, Movement, FIFO, balance, dan single-final-effect
reconciliation bersih. Harness staging-only
`pwa/scripts/g4-phase10-concurrent-post.mjs` local-ready untuk mengirim hingga
20 Post bersamaan pada satu Draft disposable dengan satu idempotency key.
Harness kemudian dijalankan pada Draft disposable dengan stok cukup. Dua puluh
request bersamaan menghasilkan tepat satu Sale `POSTED`, satu Movement, satu
Payment, satu POST audit, dan satu `SALE_POSTED` Financial Event `HOLD`;
request lain menerima replay idempotent. Gate online concurrency dinyatakan
`COMPLETE`.

Phase 11 sekarang dimulai dengan diagnostic SELECT-only untuk entitlement
`offline_pos_enabled`, Terminal/Session/Gudang penjualan, Payment yang boleh
digunakan offline, Stock–Movement–FIFO reconciliation, identity Sale, direct
browser write boundary, serta schema policy/allowance/submission yang masih
expected `SETUP`. PWA dan endpoint sync tetap tertutup sampai server-side
reservation dan queue contract lulus rollout serta behavioral test.

Live Phase-11 preflight diterima bersih: seluruh dependency, identity,
Session/Terminal/Gudang, Payment, stock, movement, FIFO, dan browser boundary
`PASS`; entitlement offline masih disabled; satu Terminal/operator/Gudang dan
Cash/elektronik siap; dua positive stock/FIFO pair konsisten. Lima tabel
canonical tepat berstatus `SETUP`. Migration `20260729180000` sekarang
local-ready untuk default Company 20%, override Store, eligibility Terminal,
reservation Session/Product/Base UOM, stock/session guards, release/force
revoke audit, dan server-only submission envelope. Ingest/sync serta PWA
offline tetap tertutup.

User kemudian mengonfirmasi migration Phase-11, seluruh postflight, corrected
behavioral test, dan regression sukses. Profile fixture correction hanya
mengubah rollback-safe test, bukan migration/data. Offline Allowance foundation
sekarang `COMPLETE`; entitlement dan endpoint sync tetap tertutup. Phase 12
dimulai dari audit SELECT-only untuk submission identity/hash/version,
allowance consumption link, snapshot Sale/Payment, price variance, payment
exception, atomic sync/idempotency routine, acknowledgement, Finance readiness,
dan stock reconciliation.

Live Phase-12 preflight diterima bersih: seluruh dependency, allowance,
Session-close guard, Payment readiness, online Sale runtime, stock/FIFO/Movement
reconciliation, dan browser boundary `PASS`; entitlement offline tetap mati.
Expected `SETUP` terbatas pada tiga tabel, sembilan snapshot column, tiga RPC,
serta system event Payment exception. Migration `20260729210000` sekarang
local-ready: client/server hash dan version immutable, harga offline dihormati
dengan variance non-accounting, allowance dikonsumsi atomic bersama canonical
Draft/Post, Payment elektronik masuk verification exception, retry menghasilkan
satu acknowledgement, dan failure tidak meninggalkan final effect. Queue/API/UI
PWA dan aktivasi entitlement tetap gate berikutnya setelah rollout/regression.

User kemudian menutup seluruh rollout/regression Phase-12. Phase-13 memulai
integrasi dari boundary lokal paling aman: Dexie v3 menyimpan payload
`PENDING_SYNC`, hash canonical JSONB, client transaction ID, posting key,
submission status, error, dan acknowledgement tanpa menghapus histori setelah
sync. Adapter hanya memanggil tiga RPC canonical Phase-12 secara berurutan dan
mempertahankan key yang sama pada retry/network failure. Queue ini belum
terhubung ke Keranjang, belum menerbitkan allowance, dan tidak membuka
entitlement/UI checkout offline.

Live Phase-14 preflight diterima bersih: dependency, Product-UOM, Pricelist,
Tax, Payment, submission, entitlement, dan browser boundary sesuai kontrak.
Snapshot RPC dan Terminal policy tepat berstatus `SETUP`; entitlement tetap
disabled dan Terminal tidak diprovision otomatis.

Migration `20260730010000` local-ready untuk guarded authoritative snapshot
per open Session/eligible Terminal. Payload mencakup Product-UOM/base price,
eligible Pricelist/rules, Sales Tax metadata, Payment Method, stock Gudang,
dan active allowance pada satu timestamp. Keranjang PWA dan checkout Offline
tetap tertutup sampai rollout, regression, cache expiry/invalidation, serta
authenticated smoke selesai.

User kemudian mengonfirmasi migration, postflight, corrected behavior,
Phase-12/11/4/G1 regression, dan closing Phase-14 postflight seluruhnya PASS.
Dexie v4 retained cache Phase-15 sekarang local-ready: exact scope validation,
canonical hash integrity, caller-defined freshness, explicit invalidation,
serta queue-aware local allowance reconciliation aktif pada library PWA.
Checkout Offline, Terminal eligibility, dan entitlement tetap belum dibuka.

Phase-16 read-only PWA UI local-ready: tombol `Offline` pada header membuka
drawer connection state,
exact Terminal/Gudang/Session, snapshot timestamp/age, serta queue-adjusted
allowance per Product tanpa memenuhi workspace. Feature/policy error tetap
lokal pada drawer; close/logout
melakukan retained invalidation. Offline library di-lazy-load setelah Session
agar startup POS tidak menanggung Dexie chunk. Lint/build PASS; authenticated
closed-entitlement smoke masih menunggu user dan checkout tetap diblokir.

Phase-17 Backoffice policy UI local-ready: Super Admin tetap menguasai
entitlement, sedangkan Pemilik/Admin Perusahaan mengatur default Company dan
seluruh Toko/Terminal; Store Manager dibatasi ke Toko assignment. Mutation
policy memakai guarded RPC, optimistic version, lock, dan audit yang sudah ada.
Belum ada issue/release/revoke allowance dari UI, dan checkout Offline tetap
tertutup sampai Phase-16/17 smoke serta allowance UAT lulus.

Phase-18 POS Customer quick-create selesai atas permintaan eksplisit user.
RPC create-only tidak menerima `company_id`: active Company dan open Cashier
Session menentukan tenant secara server-side. Customer baru hanya berisi
identitas dasar, kode otomatis, kategori aktif Company, zero credit/balance,
tanpa parent/Pricelist, serta audit. Direct Customer table write browser tetap
tertutup. PWA dan Backoffice hanya menampilkan selector Company bagi user yang
memiliki lebih dari satu Company. Migration, postflight, dan behavioral test
telah dikonfirmasi sukses; visual authenticated smoke dapat diulang bila perlu.

User kemudian mengonfirmasi migration, postflight, dan behavioral test
Phase-18 seluruhnya sukses. Database contract berstatus `COMPLETE`; migration
`20260730040000` tidak boleh dijalankan ulang. Roadmap kembali ke guarded
operasional Offline allowance tanpa membuka checkout Offline.

Phase-19 Offline Allowance operations Backoffice sekarang local-ready tanpa
migration baru. Route authenticated membaca Session `OPEN`, Product-stock,
allowance, dan nama referensi dalam active Company sesuai RLS. Issue, release,
dan force-revoke hanya meneruskan ke RPC canonical Phase-11; jumlah, role,
Store, Terminal, stock reservation, optimistic version, queue blocker, alasan,
invalidation, dan audit tetap server-authoritative. Entitlement nonaktif
menonaktifkan issuance tetapi tidak menghalangi penyelesaian allowance lama.
ESLint dan production build PASS; authenticated role/UAT menunggu user.
Checkout Offline dan Keranjang→queue tetap tertutup.

Phase-20 Cashier Offline Allowance PWA sekarang local-ready tanpa migration
baru. Cashier dapat meminta allowance hanya untuk Session miliknya dan
melepaskan allowance sendiri yang belum consumed/queued. Client tidak
menentukan quantity; seluruh feature/policy/Terminal/stock/Base-UOM/precision
serta optimistic version tetap server-authoritative. Setelah mutation, snapshot
direfresh dan hasilnya direkonsiliasi; cache lama di-invalidasi bila mutation
server berhasil tetapi refresh gagal. PWA lint dan production build PASS;
authenticated tablet UAT menunggu user. Checkout Offline, Slip Offline, dan
Keranjang→queue tetap tertutup.

Phase-21 dimulai sebagai SELECT-only readiness preflight untuk gate
Keranjang→retained Offline queue. Audit memeriksa dependency Phase-11/12/14,
enam guarded RPC dan grant, direct-write boundary, disposable Company–Terminal–
Session scope, allowance/Base-UOM/Product/Payment readiness, nonterminal queue,
idempotency identity, posted final coverage, session-close guard, serta
Stock–Movement–FIFO reconciliation. Preflight tidak mengaktifkan entitlement,
tidak membuat Sale, dan belum mengubah PWA checkout.

User kemudian mengirim hasil Phase-21: seluruh dependency, RPC/grant,
direct-write boundary, Product/Payment/allowance reference, submission identity
dan final coverage, Session close guard, serta Stock–Movement–FIFO
reconciliation `PASS`. `offline_checkout_uat_scope=SETUP` tepat karena
entitlement, Terminal policy, allowance, dan disposable open Session belum
diaktifkan.

Phase-22 PWA sekarang `LOCAL-READY`: koneksi yang terputus setelah Session dan
snapshot tersedia mengubah action menjadi `Simpan Offline`. Client
mereproduksi resolver Pricelist canonical dari snapshot, menghitung discount
dan rounding, mengagregasi allowance pada Base UOM, memvalidasi Payment exact
total, lalu menyimpan retained payload/hash/version/idempotency. Local commit
mereset Cart dan menghasilkan Slip Offline ber-watermark bukan invoice final.
Drawer menampilkan retry/status/acknowledgement dan membuka invoice final hanya
setelah `POSTED`. Bundle, TEMPO, cache/scope invalid, allowance kurang, direct
table write, dan cold-start tanpa network tetap tertutup.

Follow-up UAT 2026-07-31 memperjelas tender dan bootstrap tanpa mengubah
kontrak server: satu Payment Method otomatis mengikuti grand total final,
sedangkan kelebihan Cash hanya diinput sebagai `Uang diterima` dan direkam
sebagai kembalian. Split Payment tetap membagi exact-total per metode.
Snapshot Offline pertama sekarang dicoba otomatis ketika Session online
terbuka; allowance per Product tetap wajib diminta eksplisit karena merupakan
reservasi stock server. Customer Balance tidak dibuka dari follow-up ini.

User mengonfirmasi follow-up Phase-22 aman. Gate aktif berpindah ke Phase-23
readiness: audit `SELECT`-only atas retained identity, idempotent submit,
controlled retry, status recovery, final-effect coverage, serta rekonsiliasi
Stock–Movement–FIFO. Cold-start PWA belum diaktifkan; exact scope, cached auth
identity, snapshot, queue, dan status-first reconnect baru boleh dibuka setelah
preflight tidak menghasilkan `BLOCKER`.

User mengirim hasil Phase-23 preflight: seluruh dependency, RPC/grant,
identity/lifecycle/idempotency, retry/status recovery, final-effect coverage,
stale sync, dan Stock–Movement–FIFO `PASS`; UAT scope juga `PASS`.
`pwa_cold_start_retained_contract=SETUP` adalah expected implementation gap.

Phase-23 PWA sekarang `LOCAL-READY`. Dexie v5 menyimpan operational scope hanya
setelah snapshot authoritative berhasil. Cold-start memerlukan cached Supabase
Session dengan Cashier identity yang sama dan exact Company–Store–Terminal–
Gudang–Session snapshot. Katalog, Customer, Pricelist, Payment, allowance, dan
queue dipulihkan dari cache yang lolos integrity check. Reconnect menetapkan
active Company terlebih dahulu dan membaca status server sebelum retry.
`SYNCING/NEEDS_CONFIRMATION` tidak diproses otomatis; `FAILED` memerlukan aksi
Kasir. Logout dan close Session menghapus scope serta menginvalidasi snapshot.
Tidak ada schema/grant server atau deferred module yang dibuka.

Phase-24 menutup controlled Offline disconnect/reconnect stress. User
mengonfirmasi baseline Session/Cash/allowance dan seluruh identity/final-effect,
allowance consumption, Stock–Movement–FIFO `PASS`; pemutusan jaringan terkontrol
dipulihkan status-first dan sync selesai melalui UI tanpa duplicate effect.
Closing Phase-24/23/12 seluruhnya PASS. Offline core dinyatakan `COMPLETE` pada
boundary ini. Gate berikutnya kembali ke transaksi online G4 melalui
SELECT-only Sales Return readiness audit; Return mutation/UI, Finance posting,
TEMPO, Expense, Deposit, dan Purchasing belum dibuka.

Phase-25 Sales Return readiness preflight sekarang `READY FOR MANUAL
PREFLIGHT`. Audit tetap SELECT-only dan memeriksa source Sale `POSTED`, snapshot
line/pricing/Tax/UOM/Payment/receipt, Bundle dan FIFO allocation, terminal state
Offline, Gudang STORE/DAMAGED, refund method, Finance catalog, expected Return
schema/RPC, serta browser direct-write boundary. Expected schema/routine
`SETUP` belum membuka implementasi; setiap source `BLOCKER` harus diselesaikan
sebelum migration atau UI Return dibuat.

User mengirim hasil Phase-25: seluruh dependency, header/line/Payment snapshot,
payment total, Bundle/FIFO source, Offline terminal state, warehouse, Finance
catalog, dan direct-write boundary `PASS`; inventory berisi 6 Sale/6 line/6
Payment leg/7 FIFO allocation. Schema dan empat routine Return berstatus
expected `SETUP`. Phase-26 foundation sekarang `READY FOR MANUAL DATABASE
ROLLOUT`: source-bound Draft/Post/Cancel, default approval `REQUIRED`, cumulative
quantity guard, exact refund Cash/Transfer, condition-based FIFO restoration,
Cash Session integration, immutable audit, idempotency, dan Financial Event
`HOLD`. UI, approval `OPTIONAL`, Customer Balance, dan Finance posting tetap
tertutup.

User kemudian mengonfirmasi migration dan seluruh postflight Phase-26 `PASS`.
Schema/RPC server sudah live, tetapi fase belum `COMPLETE` sampai behavioral
test rollback-safe dan regression G4 Phase-10, G3 Phase-14, serta G1 Security
Closure lulus. UI Return tetap tertutup selama gate tersebut.

Behavioral test pertama berhenti rollback-safe pada legacy
`product_batches_transfer_lineage_check`: Return batch perlu menunjuk original
FIFO `source_batch_id`, tetapi constraint G3 hanya menerima source bersama
Transfer line. Forward fix `20260803020000` mengganti shape menjadi mutually
exclusive ordinary/Transfer/Return lineage tanpa melemahkan FIFO source. Fix
postflight dan behavioral rerun wajib PASS sebelum regression.

User mengonfirmasi lineage forward fix, postflight fix, dan behavioral rerun
seluruhnya sukses. Phase-26 database behavior kini PASS. Closure masih menunggu
regression G4 Phase-10 online checkout, G3 Phase-14 inventory reconciliation,
dan G1 Security Closure; UI Return belum boleh dibuka sebelum ketiganya bersih.

User kemudian mengonfirmasi regression G4 Phase-10 dan G1 Security Closure
sukses. Rerun G3 Phase-14 menunjukkan seluruh invariant stok/FIFO/Movement
`PASS`; `SETUP` hanya fixture stress yang memang rollback dan cross-gate tetap
`DEFERRED` sesuai desain. Phase-27 membuka PWA **Draft Return** online: invoice
posted Store aktif, qty tersisa, kondisi stok, Gudang Rusak, refund Cash/
Transfer, dan total otomatis dari snapshot asal. Posting tetap `REQUIRED` oleh
Store Manager/Company Admin dan belum dibuka di PWA.

User kemudian mengonfirmasi Draft Return berhasil dibuat dari PWA. Phase-28
membuka Backoffice `Sales > Approval Return` untuk Company Owner/Admin dan
Store Manager: list/detail tanpa UUID, guarded post/cancel, optimistic version,
idempotency, alasan pembatalan, serta custom confirmation. Posting tetap
memerlukan Cashier Session pelaksana `OPEN`; Finance Event tetap `HOLD` dan
jurnal G6 tidak dibuka. Backoffice lint dan production build PASS; authenticated
role/effect smoke menunggu user.

User mengonfirmasi Backoffice berhasil memposting Draft Return. Phase-28 ditutup
`COMPLETE` pada boundary approval `REQUIRED`. Durasi posting yang terasa lambat
dicatat untuk profiling terukur, tetapi tidak ada error atau efek ganda yang
dilaporkan. Phase-29 beralih sesuai urutan G4 ke preflight SELECT-only Expense
dan arus kas non-penjualan: legacy Cash Advance, Session/drawer, metode Cash/
Transfer, kategori/akun Finance, entitlement, privilege, serta canonical schema
gap. Expense mutation/UI, Deposit, jurnal, dan G5 tetap tertutup.

User mengirim hasil Phase-29 tanpa `BLOCKER`: dependency, tenant/value legacy,
Store Cash/Transfer, kategori/akun, dan privilege seluruhnya `PASS`; legacy
Cash Advance kosong, satu trigger legacy masih aktif, entitlement belum ada,
dan sembilan tabel canonical tepat berstatus `SETUP`. Phase-30 membuka fondasi
database kategori/kebijakan serta `DRAFT -> SUBMITTED -> APPROVED/REJECTED/
CANCELED`. Entitlement tetap default off dan request/approval harus cash-neutral;
disbursement, settlement, return, Cash In, offline Expense, Deposit, dan jurnal
tetap tertutup sampai gate berikutnya.

User kemudian mengonfirmasi migration, postflight, behavioral test, dan
regression Phase-30 seluruhnya `PASS`. Phase-31 membuka UI PWA untuk pengajuan
Expense online pada Session aktif: kategori/metode eligible, nominal,
responsible party, deskripsi, target settlement, dan external evidence link.
Client memakai idempotent Draft lalu guarded Submit; status `SUBMITTED` berarti
menunggu approval dan auto-`APPROVED` tetap belum mencairkan dana. Entitlement
off menyembunyikan entry point dan retained offline catalog tidak membuka
Expense. Disbursement, settlement/return, Cash In, Offline Expense, Deposit,
drawer mutation, serta jurnal G6 tetap tertutup.

User mengonfirmasi pengajuan Expense Phase-31 berhasil. Phase-32 membuka
Backoffice `Finance > Approval Expense`: reviewer melihat nomor/kategori/Store/
responsible party/metode/bukti dan nilai lifecycle, lalu memakai guarded
`review_expense_request` atau `cancel_expense_request`. Store Manager,
Company Owner/Admin, Finance, dan Super Admin mengikuti authority server;
Accounting hanya read-only. Approve/reject/cancel memakai optimistic version,
alasan wajib untuk reject/cancel, custom confirmation, dan tidak membuat
disbursement, drawer effect, Stock Movement, atau jurnal.

User kemudian mengonfirmasi approval Expense Phase-32 berhasil setelah approve
tidak lagi meminta alasan. Phase-33 berpindah ke preflight SELECT-only pencairan
Cash/Transfer: audit Expense `APPROVED`, metode dan Store scope, Cashier Session
`OPEN`, category/account readiness, approval/payment snapshot, Financial Event,
Cash Drawer Movement, expected-cash calculator, direct-write boundary, serta
reconciliation event append-only. Pada fase preflight ini belum ada uang yang
dicairkan dan settlement, return, Cash In, Offline Expense, Deposit, serta
jurnal G6 tetap tertutup.

Output live Phase-33 diterima tanpa `BLOCKER`: dependency, approved-document
shape, metode/Store/Session, category/account, privilege, dan seluruh existing
reconciliation `PASS`; dua Expense approved (satu Cash dan satu non-Cash) siap
menjadi fixture manual. Empat runtime yang belum tersedia tepat berstatus
`SETUP`. Phase-34 menambahkan guarded initial disbursement sebesar nilai
approved, snapshot approval/payment/account, single Cash Drawer `OUT`, non-Cash
drawer isolation, expected-cash integration, idempotency, audit, dan Financial
Event `HOLD`. Migration tidak mencairkan dokumen existing secara otomatis dan
UI, settlement, return, Cash In, Offline Expense, Deposit, serta jurnal G6 tetap
tertutup sampai gate sesudah database regression.

User kemudian mengonfirmasi migration Phase-34, postflight, behavioral test,
regression, dan closing check seluruhnya aman. Phase-35 membuka operational UI
tanpa schema baru: satu menu Expense PWA memiliki tab pengajuan dan pencairan
Cash approved melalui Session aktif, sedangkan Finance Backoffice hanya
mengonfirmasi Transfer/non-Cash. Amount/method tetap server-authoritative,
retry memakai stable idempotency key, bukti HTTPS mengikuti Payment Method,
dan Backoffice route menolak Cash. Settlement, return, additional
disbursement, Cash In, Offline Expense, Deposit, serta jurnal G6 tetap tertutup
sampai authenticated smoke dan closing postflight lulus.

User kemudian mengonfirmasi kedua jalur Phase-35 aman. Phase-36 kembali ke
boundary SELECT-only untuk mengaudit actual Expense, return, outstanding,
additional disbursement, Cash In readiness, append-only event totals,
Financial Event/Drawer coverage, category account, aging, dan gap schema/RPC.
Fase ini belum membuat mutation settlement; seluruh `BLOCKER` harus nol
sebelum foundation berikutnya boleh dibuka.

User kemudian mengonfirmasi migration, postflight, behavioral test, dan seluruh
regression Phase-37 aman. Phase-38 membuka operational UI tanpa schema baru:
POS mengajukan biaya aktual, menerima pengembalian Cash pada Session aktif,
serta membuat request dana tambahan; Backoffice mereview biaya aktual dan
menerima pengembalian non-Cash. Biaya aktual tetap cash-neutral sebelum review,
return Cash memperbarui expected cash, return non-Cash tidak menyentuh drawer,
dan additional disbursement tetap request-only. Offline Expense, Deposit,
eksekusi dana tambahan, serta jurnal final G6 tetap tertutup.

User melanjutkan setelah Phase-38 tanpa melaporkan error, sehingga operational
UI ditutup `COMPLETE`. Phase-39 tetap menyelesaikan POS-007 sebelum berpindah
ke Deposit: diagnostic SELECT-only mengaudit request dana tambahan, lifecycle
approval/reject/disburse yang belum tersedia, zero cash effect request-only,
tenant/payment/document integrity, kesiapan Session Cash, enum event, dan
direct-write boundary. Tidak ada approval atau pencairan pada preflight ini.

User mengirim output Phase-39 tanpa blocker: dependency, tenant/reference,
request-only zero effect, payment/document/Session readiness, dan direct-write
boundary seluruhnya `PASS`; histori request masih nol. Enam lifecycle column,
dua guarded RPC, dan event tambahan tepat berstatus `SETUP`. Phase-40 membuka
foundation review/reject serta pencairan additional Expense: approval tetap
cash-neutral, Cash wajib Session `OPEN` dan satu drawer `OUT`, non-Cash hanya
Finance/Admin tanpa drawer, retry exact-idempotent, audit immutable, dan
Financial Event `HOLD`. UI, Offline Expense, correction/reversal, Deposit, dan
jurnal G6 tetap tertutup sampai rollout/regression Phase-40 lulus.

User kemudian mengonfirmasi corrected behavior, seluruh regression, dan
closing postflight Phase-40 berhasil. Phase-41 membuka UI operasional tanpa
schema baru: Backoffice mereview request tambahan dan membayar non-Cash;
POS hanya mencairkan Cash approved melalui Session aktif. Nominal/metode tetap
server-authoritative, approval cash-neutral, exact retry tetap idempotent, dan
channel Cash/non-Cash dipisahkan. Deposit, Offline Expense,
correction/reversal, Purchasing G5, serta jurnal final G6 tetap tertutup.

User melanjutkan setelah Phase-41 local delivery tanpa melaporkan blocker.
Phase-42 berpindah sesuai POS-008 ke preflight Setor Kas multi-sesi. Diagnostic
ini hanya SELECT-only: mengaudit legacy `bank_deposits`, Session `CLOSED`,
actual closing cash, duplicate allocation, event/trigger compatibility,
Transaction Category/account function, direct-write boundary, dan gap schema/
RPC canonical. Deposit mutation/UI, variance resolution, bank reconciliation,
serta jurnal final G6 belum dibuka.

User mengonfirmasi seluruh hasil Phase-42 aman. Phase-43 membuka foundation
server Setor Kas: Draft dapat menggabungkan beberapa Session `CLOSED`, expected
server-authoritative memperhitungkan saldo sesi berikutnya, Submit mengunci
Session, Reject/Cancel melepas lock, dan Approve memfinalkan seluruh Session.
Nominal aktual tetap boleh kurang/lebih; variance membuka exception kontrol dan
Financial Event `HOLD`, tidak langsung menjadi biaya/pendapatan atau jurnal.
UI, bank matching, variance resolution, Offline Deposit, correction/reversal,
dan posting final G6 tetap tertutup sampai rollout/regression Phase-43 lulus.

User mengonfirmasi migration, postflight, behavioral test, regression, dan
closing verification Phase-43 seluruhnya PASS. Phase-44 membuka UI operasional
tanpa schema baru: Kasir membuat dan Submit Setor Kas dari satu atau beberapa
Session `CLOSED`, sedangkan Finance/Owner/Admin mereview detail per sesi dan
Approve/Reject melalui guarded RPC. Accounting tetap read-only. Expected cash,
Session lock, optimistic version, idempotency, variance exception, audit, dan
Financial Event `HOLD` tetap server-authoritative. Bank matching, variance
resolution, Offline Deposit, correction/reversal, serta jurnal final G6 masih
tertutup.

User mengonfirmasi approval Setor Kas Phase-44 berhasil setelah optional reason
parser diperbaiki. Phase-45 tetap pada POS-008 dan hanya membuka diagnostic
SELECT-only penyelesaian variance: source/amount/type coverage, lifecycle,
responsible party, allocation reconciliation, account mapping, maker-checker,
runtime/event gap, dan browser boundary. Belum ada resolution, refund,
write-off, source correction, bank matching, atau jurnal yang dapat dijalankan.

User mengirim output live Phase-45 dengan seluruh dependency, source, amount,
lifecycle, account catalog, privilege, dan reconciliation `PASS`; satu Setor
Kas approved matched tidak membuka exception, sehingga history exception dan
allocation tetap nol. Phase-46 membuka foundation server: penetapan responsible
party internal, partial append-only allocation, guarded refund/recovery,
maker-checker untuk write-off/beban/pendapatan/source correction, exact retry,
immutable audit, serta Financial Event `HOLD`. UI resolution, bank matching,
reversal/replacement source aktual, Offline Deposit, dan jurnal final G6 tetap
tertutup sampai rollout/regression Phase-46 lulus.

User kemudian mengonfirmasi seluruh rollout, postflight, behavioral test, dan
regression Phase-46 aman. Phase-47 membuka UI operasional Backoffice tanpa
schema baru: Finance dapat menetapkan responsible party dan mencatat partial
resolution, Owner/Admin lain mereview keputusan loss/income/source, Accounting
read-only, dan seluruh mutation tetap melalui guarded RPC. Bank matching,
reversal/replacement source aktual, Offline Expense/Deposit, serta posting
jurnal G6 tetap tertutup. Gate aktifnya adalah authenticated role/maker-checker
smoke sesuai runbook Phase-47.

User mengonfirmasi Phase-47 aman. Phase-48 tidak langsung membuka payment
Customer Balance: diagnostic mengaudit feature state, legacy
`customers.current_balance`, histori tender, system Payment Method, kategori dan
account function, direct-write boundary, serta membuktikan canonical Sale masih
fail-closed. Hasil live preflight menjadi gate sebelum ledger append-only dan
correction maker-checker dirancang.

Output live Phase-36 kemudian diterima bersih: seluruh data/lifecycle/event/
drawer/account/session invariant `PASS`, direct browser write tertutup, history
settlement/return nol, dan lima gap runtime tepat `SETUP`. Phase-37 menambahkan
workflow actual request/review, immutable approved settlement dan return,
Cash return sebagai Cash In + drawer `IN`, outstanding lifecycle, serta
additional disbursement request-only. Request tambahan belum dapat mencairkan
uang; UI, Offline Expense, correction, Deposit, dan G6 tetap tertutup sampai
database rollout/regression selesai.

### Deliverable

- production PWA shell: auth, active Company/Store/Terminal, Cashier Session, master sync, cart, Draft/Hold/Pending list;
- server price resolver: Product fallback, Global Pricelist/tier, Customer Pricelist, manual discount, Tax, rounding kelipatan 100;
- atomic checkout menggunakan stock ledger, payment validator, Customer Balance, TEMPO, receipt snapshot, dan Financial Event contract;
- shortage menjadi Draft tanpa stock/journal effect;
- offline queue dengan allowance, client transaction ID, idempotency key, retry/error state, acknowledgement, master version, dan conflict UX;
- Payment Method/split/evidence URL;
- Expense, close session, Deposit multi-session, Excel session flow;
- notification/action links untuk RO pending, low stock, payment/approval, dan sync error;
- Ketul hanya setelah core checkout/stock stabil dan feature enabled.

### Test minimum

- price/HPP/total/status tampering dari client ditolak atau dihitung ulang;
- payment sum, change, rounding, tax, discount, Customer Balance, TEMPO konsisten;
- retry online/offline 10 kali menghasilkan satu sale/movement/event;
- jaringan putus pada setiap tahap sync dapat dipulihkan tanpa kehilangan local record;
- stale catalog/stock menghasilkan resolvable conflict, bukan silent overwrite;
- receipt/reprint menggunakan snapshot transaksi, bukan master terbaru;
- feature disabled tidak muncul dan API menolak;
- cash/session/deposit/expense flow merekonsiliasi expected vs actual.

### Exit criteria

- tidak ada `MOCK_PRODUCTS` atau mock checkout pada production entrypoint;
- transaksi pilot dapat ditelusuri dari local client ID hingga sale, movement, payment, event, dan receipt;
- offline UAT lulus pada koneksi diputus/nyambung berulang.

---

## 7. G5 — Purchasing Dasar

**Status aktif 2026-08-06:** Phase 2 Stock Request + Supplier Order database
telah dikonfirmasi user seluruhnya PASS, Phase 3 UI diterima, dan Phase 4
Goods Receipt preflight seluruhnya PASS. Request hanya
mencatat kebutuhan Kasir; pemilihan Supplier serta konfirmasi Order dibatasi ke
Store Manager/Company Admin/Super Admin. Order workspace menampilkan hanya sisa
baris/quantity yang belum dialokasikan ke order aktif sehingga satu Request aman
dibagi ke beberapa Supplier. Phase 5 Goods Receipt foundation dan forward-fix
telah dikonfirmasi user seluruhnya PASS. Phase 6 PWA telah diterima user: Kasir dapat
memilih order Store aktif, menyimpan/resume/cancel Draft, mencatat partial/over
serta kondisi baik/rusak/ditolak, lalu Post atomic. Phase 7 aktif sebagai
preflight SELECT-only Purchase Return dan telah dikonfirmasi user seluruhnya
PASS. Phase 8 foundation telah dikonfirmasi user seluruhnya PASS. Phase 9
operational UI sekarang ready for authenticated smoke: Kasir membuat Draft dari
Goods Receipt/FIFO asal di POS; Manager/Admin mereview dan memposting secara
terpisah di Backoffice. Pengurangan batch FIFO sumber, Stock/Movement, AP
adjustment append-only, dan Event `HOLD` tetap hanya terjadi saat Post. Supplier
Invoice/matching/payment dan Journal final tetap belum dibuka.

Penyesuaian user 2026-08-06: UOM Purchase Return tidak wajib sama dengan UOM
pembelian atau Receipt. Forward-fix Phase 9 mengizinkan seluruh Product-UOM
aktif (contoh Dus → beberapa Ketul), tetap memakai conversion snapshot langsung
ke base, precision UOM, serta batas source allocation/FIFO. Setelah fix dan
regression diterapkan dan Phase 10 Supplier Invoice preflight telah diterima
user tanpa blocker; satu `supplier_invoice_matching_scope = BACKFILL` adalah
scope AP provisional existing yang expected. Phase 11 matching foundation telah
dilanjutkan sampai Supplier Payment Phase 14 dan dilaporkan user PASS. Optional
tolerance tetap keputusan per Company: tanpa policy selisih nilai fleksibel,
tetapi quantity Receipt dan variance snapshot tetap wajib. Forward fix
`20260810160000` serta regression menjadi corrective gate sebelum G6. Journal
G6 tetap belum dibuka.

### Deliverable

- Request Order dari POS/Sales;
- Store Manager membuat/group Supplier Order per Supplier dan menentukan qty final;
- Goods Receipt partial/lebih dengan accepted/rejected/damaged dan source document;
- stock/FIFO hanya dari qty accepted;
- Return Supplier partial/full;
- Supplier invoice, provisional AP/valuation, real price adjustment, tolerance/matching;
- supplier bank info dapat disalin Finance saat payment;
- status history dan notification pending.

### Test minimum

- partial receipt berulang tidak melebihi state order tanpa warning/policy;
- product/warehouse/supplier Company mismatch ditolak;
- duplicate receipt tidak menggandakan stock/FIFO/AP;
- rejected/damaged tidak masuk sellable stock;
- Return mengurangi stock dan menghasilkan debit-note/AP effect sesuai source;
- price invoice berbeda dari receipt menghasilkan variance, bukan rewrite layer tanpa audit.

### Exit criteria

- setiap stock masuk dapat dilacak ke receipt;
- AP provisional dan invoice real dapat direkonsiliasi;
- flow confirm-purchase lama telah dimigrasikan atau dinonaktifkan dengan aman.

---

## 8. G6 — Finance Core, Posting, Reconciliation, dan Report

### Deliverable

- COA hierarchy/configuration, account function, Transaction Category mapping version;
- canonical Financial Event yang immutable/idempotent;
- journal posting balanced, source-linked, approval-aware, reversible, period-locked;
- Cash/Bank, AR/TEMPO/collection, Customer Balance liability, AP/purchase/payment, Expense, Deposit variance, Tax, Stock/HPP, Bundle allocation, Ketul, Debit/Credit Note;
- reconciliation per account/source;
- report minimum dan pending/draft/hold analysis;
- external evidence URL visible pada Finance flow;
- dead-letter/retry workspace untuk event gagal.

### Test minimum

- setiap event fixture menghasilkan debit=credit;
- missing/ambiguous mapping masuk error queue, bukan jurnal setengah;
- duplicate event tidak menggandakan journal;
- posted period menolak mutation dan hanya menerima reversal pada period terbuka;
- subledger AR/AP/Customer Balance sama dengan control account;
- stock valuation ledger sama dengan inventory account setelah reconciliation;
- Finance dapat override konfigurasi yang diizinkan dan audit before/after tersimpan;
- report dapat drill down ke source document.

### G6 Corrective Active Roadmap

Draft Phase 2–11 tanggal 20260807/20260810 ditolak dan tidak boleh dijalankan.
Urutan authoritative berada di `docs/G6_FINANCE_CORRECTIVE_RECOVERY_PLAN.md`:

1. **Corrective Phase 1 (COMPLETE, user verified):** live-state SELECT-only preflight dan
   privilege-only quarantine `20260810170000` untuk routine rejected/legacy
   yang masih executable browser. Tidak ada Finance business row yang diubah.
2. **Corrective Phase 2 (COMPLETE, user verified):** live-state object preflight,
   tenant-safe period/journal/immutability foundation `20260810180000`,
   postflight, dan behavioral test seluruhnya PASS tanpa mengubah arti
   `journal_entries` legacy atau memproses event HOLD.
3. **Corrective Phase 3 (COMPLETE, user verified):** live preflight
   menetapkan 34 required mapping dan 52 historical event-function row sebagai
   explicit backfill. Resolver memilih satu akun system-owned kanonis, atau
   sole explicit fallback bila akun sistem tidak ada; tipe akun kompatibel saja
   tidak pernah cukup. Duplicate system-owned COA hasil import dikoreksi lebih
   dahulu oleh `20260810185000` menjadi Company-owned tanpa mengubah identitas
   atau histori; migration/postflight/behavior dan closing preflight telah
   dikonfirmasi user sukses. Migration `20260810190000` menambah guarded
   versioned/effective/approved rule-set, dan tidak memproses event HOLD.
   Migration, postflight, dan corrected rollback-safe behavioral test telah
   dikonfirmasi user PASS.
4. **Corrective Phase 4 (COMPLETE, user verified):** preflight dikonfirmasi user
   aman. Migration `20260810200000` membatasi atomic single-event posting pada
   source-validated `STOCK_OPENING`, approved expression/account rule,
   Accounting Period, exact idempotency, balanced canonical journal, exception,
   dan browser boundary. Event existing tidak diproses migration; event lain
   tetap HOLD sampai resolver dan controlled queue phase berikutnya. Migration,
   postflight, dan rollback-safe behavioral test dikonfirmasi user PASS.
5. **Corrective Phase 5 (database complete, live run pending):** live preflight menemukan satu
   supported `STOCK_OPENING` dan 25 event dari sembilan contract deferred,
   dengan seluruh source/rule/period/tenant/privilege guard PASS. Migration
   `20260810210000` menambah controlled preview/approval/process queue satu
   active Company, immutable snapshot/audit, dan per-event exception isolation.
   Migration tidak membuat queue atau memproses historical HOLD. User
   mengonfirmasi migration, postflight, dan behavior seluruhnya sukses; satu
   historical live run tetap menunggu controlled approval setelah closing
   review.
6. **Corrective Phase 6A (complete, user verified) dan Phase 6B (active
   preflight):** SELECT-only
   audit dikonfirmasi tanpa blocker/review. FIFO Rp84,71 juta versus Inventory
   GL nol adalah controlled backfill karena satu supported `STOCK_OPENING`
   masih HOLD. Migration `20260810220000` membuka hanya Trial Balance dan
   General Ledger dari canonical journal POSTED, dengan tenant/role/timezone,
   version metadata, filter, drill-down, pagination, dan immutable history.
   P&L, Neraca, reconciliation mutation, cache/export worker, live HOLD
   processing, dan 25 unsupported event tetap tertutup. User mengonfirmasi
   migration/postflight/behavior Phase 6A seluruhnya PASS. Phase 6B sekarang
   mengaudit ulang source/rule/period, active queue, exception, report runtime,
   serta baseline FIFO–Inventory GL sebelum satu live STOCK_OPENING boleh masuk
   preview/approve/process terkontrol. Output user bebas blocker/review: satu
   event Rp450.000 siap, queue awal kosong, dan 25 event lain tetap deferred.
   Controlled maintenance operation serta closing postflight sekarang
   dikonfirmasi user seluruhnya PASS: satu event/jurnal POSTED Rp450.000,
   queue final bersih, dan report fixture tersedia. Full FIFO–GL reconciliation
   tidak boleh dinyatakan selesai dari event ini saja. Phase 6C kemudian
   membuka P&L, Neraca, pending analysis, dan reconciliation summary.
   Migration `20260810230000`, postflight, dan rollback-safe behavior telah
   dikonfirmasi user seluruhnya PASS. Historical subledger reconciliation
   sengaja ditolak, current-only diberi label, dan tidak ada adjustment/event
   processing otomatis.
7. **Corrective Phase 7A (complete; user verified):** SELECT-only preflight,
   migration `20260811090000`, postflight, dan rollback-safe behavior telah
   dikonfirmasi PASS. Guarded reversal hanya menerima jurnal `MANUAL` dan
   `OPENING_BALANCE` pada period terbuka/reopened. Jurnal
   `AUTOMATIC`/`PRIOR_PERIOD_ADJUSTMENT` tidak boleh dibalik GL-only dan wajib
   mengikuti Return, Adjustment, atau source reversal/replacement resmi.
8. **Corrective Phase 7B (database user-verified; active UI smoke):** Backoffice Finance
   Operations sudah memakai canonical journals, periods, controlled queue,
   POSTED reports, pending analysis, dan current-only reconciliation. UX
   forward fix menambah server-owned `JUR/JRB/PST/EXC/REC`, Buku Besar seluruh
   akun yang expandable, Journal Entries document-centric, dan XLSX bulanan.
   Local lint/build/XLSX smoke PASS; migration `20260811100000`, postflight,
   dan behavior dikonfirmasi user sukses. Authenticated
   cross-role/cross-Company UI/XLSX smoke masih wajib.
   Queue tetap hanya `STOCK_OPENING`; endpoint service-role worker lama
   fail-closed, 25 HOLD dan FIFO–GL tetap deferred sampai contract berikutnya
   resmi dibuka.

9. **Corrective Phase 8 (database-live; user verified):** exact source contract,
   account snapshot, atomic posting runtime, controlled queue, rollback behavior,
   live reconciliation, dan final historical closure telah PASS untuk Sale,
   Sales Return, Goods Receipt, Supplier Invoice, Supplier Payment, Stock Gain,
   Expense Disbursement, Cash Deposit, serta Cash Variance. Final inventory:
   31 POSTED Event/Journals, 92 Journal lines, satu exact-zero no-effect Event,
   `HOLD=0`, active queue/exception nol, dan FIFO-Inventory GL KGS sama tepat
   Rp89.485.000. Gate aktif kembali ke PRD-1 authenticated Preview UAT; posting
   masa depan tetap harus melalui source-verified runtime dan guarded queue.

Finance posting tetap tertutup sampai phase terkait selesai manual rollout,
postflight, behavior, regression, dan authenticated smoke. Tidak ada phase yang
`COMPLETE` hanya karena file lokal tersedia.

**Deferred setelah pilot/Vercel:** inter-Company Sales/Purchase dapat dirancang
untuk membuat pasangan dokumen otomatis antar Company. Scope future wajib
maker-checker kedua tenant, source/number terpisah, UOM/price/tax snapshot,
Finance elimination/reconciliation, dan tidak boleh membuka akses data silang.

### Exit criteria

- seluruh mapping wajib untuk feature pilot lengkap;
- trial balance seimbang dan tidak ada orphan event/journal;
- close/reopen/reversal UAT lulus;
- hard-coded COA worker lama tidak lagi menjadi execution path aktif.

---

## 8.5 Pre-Deploy UX, Branding, dan Sales Document Insertion

Keputusan user 2026-08-11 menyisipkan pekerjaan berikut setelah DEX-4 dan
sebelum full E2E/Vercel Preview. Source of truth berada di
`PREDEPLOY_MODULAR_HOME_BRANDING_SALES_DOCUMENT_PLAN.md`.

1. **UXD-1 — Navigation authority audit:** petakan module/submodule terhadap
   effective role, Company, entitlement, operational scope, API, dan RLS.
2. **UXD-2 — Two-level launcher:** Home hanya card modul authorized; klik modul
   membuka landing card submodul; hero sapaan/statistik dihapus.
3. **BRD-1 — Company branding:** upload/replace/remove logo opsional,
   tenant-scoped, audited, file-safe, dan memiliki fallback tanpa logo.
4. **SLD-1 — Sales document preflight:** audit Sale/Customer/Store/Return/
   Offline/print snapshot dan tutup blocker sebelum schema.
5. **SLD-2 — Canonical Sales document foundation:** Sales Invoice printable
   bersumber dari Sale POSTED dan Surat Jalan hanya untuk delivery intent;
   idempotent serta tanpa Stock/Finance effect kedua.
6. **SLD-3 — POS/Backoffice/print UI:** toggle `Perlu dikirim`, recipient dan
   alamat snapshot, daftar/reprint/status, template logo/no-logo.
7. **PRD-1 — Closing regression:** full tenant/role/DEX/Sale/Return/Stock/FIFO/
   Finance/document/Storage/environment regression sebelum Vercel Preview.
8. **BRD-2 — Company profile dan rekening:** detail administratif/kontak,
   tiga field rekening opsional all-or-none, autofill rekening Supplier pada
   Draft Pembayaran, serta toggle rekening Invoice default OFF. Invoice baru
   menyimpan snapshot immutable; Surat Jalan dan histori lama tidak diubah.
9. **POX-1 — Selected Supplier Order export:** daftar Purchase menyediakan
   checkbox per PO dan pilih-semua hasil filter. Export menghasilkan satu XLSX
   tiga-sheet hanya dari maksimal 100 PO terpilih; server memvalidasi active
   Company, capability `purchase.supplier_orders EXPORT`, UUID, duplikasi, dan
   kepemilikan setiap dokumen. Endpoint/RPC export seluruh PO lama tetap ada
   hanya untuk compatibility client lama.

Status 2026-08-11: UXD-1 COMPLETE. Audit menetapkan registry client belum
memadai sebagai authority launcher, memisahkan `canView` dari capability aksi,
memindahkan ownership Faktur/Pembayaran Supplier ke Finance, dan memastikan 97
Route Handler memiliki auth/context atau retirement guard. UXD-2 adalah next
safe step; BRD-1 belum dibuka.

UXD-2 sekarang LOCAL READY: clean Home, module landing, catalog server berbasis
active Company/role/feature, Company reset, dan client fail-safe telah lint,
TypeScript, serta production build PASS. Authenticated role/feature/
multi-Company smoke masih manual; BRD-1 belum dibuka sampai smoke tersebut PASS.

Arahan user berikutnya menggabungkan pembuatan akun/matrix role UXD-2 ke closing
PRD-1. BRD-1 preflight sudah user-reported ALL PASS. Migration database/storage,
postflight, dan rollback-safe behavior dua Company sekarang siap manual rollout;
server upload API/UI tetap menunggu database gate PASS.

Atas arahan user, PRD-1 wajib memakai sedikitnya dua Company dan memastikan
isolasi tidak hanya pada launcher: list/detail, mutation, Stock, Sale, Finance,
global Data Exchange, branding, dan document snapshot. Switch active Company
wajib membersihkan state/cache; ID/path Company lain dan direct route/RPC harus
ditolak server-side.

BRD-1 database/postflight/behavior telah user-reported ALL PASS. BRD-2 upload
runtime dan UI sekarang LOCAL READY: Route Handler mengambil active Company
server-side, bytes divalidasi terhadap magic signature/MIME/extension/2 MiB,
SHA-256 dan versioned path dibuat server, Storage memakai service-role hanya di
modul `server-only`, metadata tetap melalui guarded RPC, dan replace/remove
membersihkan object secara best effort. Authenticated wrong-file, stale-tab,
role denial, dan switch dua Company tetap manual gate sebelum SLD-1.

Header menampilkan resolved Company logo sebagai tombol Home dan Fast Link
memiliki search. Input search hanya memfilter item dari
`/api/me/navigation-catalog`; dilarang memakai static fallback/all-menu
registry. Menu yang tidak diberikan untuk role/Company aktif harus tetap tidak
muncul di Home, module landing, sidebar, dan hasil pencarian, sementara direct
route/API tetap ditolak oleh server authority.

SLD-1 sekarang LOCAL READY sebagai contract dan preflight SELECT-only. Contract
canonical berada di `SALES_INVOICE_DELIVERY_DOCUMENT_SPEC.md`: Invoice adalah
view/snapshot immutable dari Sale POSTED dan nomor existing; Surat Jalan hanya
untuk `DELIVERY`, bernomor manusia `SJ/YYYY/MM/NNNNNN`, idempotent, tenant-safe,
dan tidak mempunyai Stock/Finance effect kedua. Jalankan runbook
`runbooks/SLD1_SALES_DOCUMENT_PREFLIGHT.md`; SLD-2 tetap tertutup sampai semua
row `BLOCKER` nol. Multi-role dan dua-Company full matrix tetap digabungkan pada
PRD-1 sesuai arahan user.

User kemudian mengirim output live SLD-1 tanpa `BLOCKER`. Tiga Customer dan
satu Store berstatus `REVIEW`, sembilan Sale POSTED berstatus `BACKFILL`, serta
schema dan branding retention berstatus `SETUP`; semuanya merupakan scope yang
disetujui, bukan penyimpangan transaksi. SLD-2 sekarang READY FOR MANUAL
DATABASE ROLLOUT melalui
`runbooks/SLD2_SALES_DOCUMENT_FOUNDATION_ROLLOUT.md`. Implementasi memakai
deferred finalization agar snapshot menangkap state final online/offline,
`LEGACY_CUTOVER` untuk existing Sale, delivery-only Surat Jalan, immutable
audit, dan reference-aware logo retention. User kemudian melaporkan migration,
postflight, serta behavioral seluruhnya PASS; SLD-2 menjadi database-applied.

SLD-3 sekarang LOCAL READY. POS mempertahankan fulfillment Pickup/Delivery pada
draft online/offline dan menawarkan Invoice/SJ final di success flow tanpa
retry Sale. Backoffice memiliki authorized list/detail, A4 new-tab print, dan
guarded lifecycle Surat Jalan tanpa menampilkan UUID. PWA serta Backoffice lint
dan production build PASS. Authenticated UAT pada
`runbooks/SLD3_POS_BACKOFFICE_PRINT_UI.md` tetap wajib sebelum fase COMPLETE
dan sebelum PRD-1 dimulai.

Closing UAT tersebut kemudian ditahan oleh approved revision user. Delivery
dipilih pada final checkout sebelum payment/POST, memakai default Customer, dan
ongkir opsional harus direkonsiliasi server-side ke payment/AR/Customer Balance,
offline replay, Invoice, event, serta jurnal pendapatan ongkir. Implementasi
wajib berurutan SLD-R1 contract/preflight, R2 foundation, R3 UI, dan R4 closing
regression menurut `SLD_DELIVERY_FEE_REVISION_PLAN.md`. User kemudian
mengonfirmasi SLD-R4 migration, postflight, behavioral, dan regression sukses
pada 2026-08-12. PRD-1 sekarang dibuka melalui SELECT-only diagnostic
`supabase/diagnostics/prd_phase1_predeploy_closing_preflight.sql`; provision
Company kedua dan akun role dilakukan hanya setelah output diagnostic ditinjau.
Output live kemudian diterima tanpa `BLOCKER`. Gate aktif berpindah ke manual
canonical provisioning satu Company kedua, role matrix, Kasir per tenant, dan
satu regular multi-Company identity. Postflight SELECT-only berada di
`supabase/diagnostics/prd_phase2_uat_identity_tenant_postflight.sql`; kredensial
tidak boleh disimpan pada SQL, Markdown, log, atau repository.

Company kedua kemudian user-provisioned dan gate dua Company PASS. Karena UI
lama belum dapat menempelkan akun existing, PRD phase 3 menambahkan guarded
Super-Admin-only exact-email assignment dengan role per Company, optional Store,
immutable audit, exact retry, dan tanpa browser global user directory. Manual
rollout wajib mengikuti `runbooks/PRD1_EXISTING_USER_MULTI_COMPANY_ROLLOUT.md`
sebelum regular multi-Company selector identity dapat dinyatakan PASS.

Keputusan user 2026-08-12 kemudian menyisipkan ACP-0—ACP-7 sebelum full PRD-1
closing. Role existing tetap baseline sekaligus batas maksimum; custom access
bersifat opsional dan restriction-only per Company/submodul. Tidak adanya
override harus mempertahankan behavior sekarang. Fase dipecah menjadi contract,
read-only fingerprint, shadow foundation, consolidated User detail, Inventory
pilot, Contacts/Purchase/Sales, Finance/Data/Platform, lalu security closure.
Source of truth berada di `ROLE_BASELINE_CUSTOM_PERMISSION_PLAN.md`. Gate aktif
ACP-1 live output kemudian diterima tanpa `BLOCKER`: membership/context/tenant,
178 company-scoped RLS relations, protected direct-write boundary, and canonical
helpers all PASS. Five authenticated writable company tables remain documented
`REVIEW`; custom schema and incomplete UAT roles remain expected `SETUP`.
ACP-2 migration telah berada di live database dan rollback-only behavioral test
dikonfirmasi PASS oleh user. ACP-3 sekarang local-ready: card Tim & Akses dapat
dibuka menjadi detail user, membership Company/Store ditampilkan tenant-safe,
Super Admin dapat menambahkan target UUID yang sama ke Company lain tanpa input
email ulang, dan resolver ACP-2 ditampilkan sebagai preview `SHADOW`. UI ini
tidak memakai preview sebagai authorization dan belum menyediakan editor preset.
Next manual gate adalah authenticated two-Company smoke serta ACP-2 postflight +
ACP-1 regression sebelum ACP-4 Inventory enforcement dibuka.

ACP-4 kini mempunyai preflight SELECT-only
`acp_phase4_inventory_pilot_preflight.sql` dan runbook interpretasi. Diagnostic
mengaudit sembilan Inventory key, dependency ACP-2, tenant override, protected
Stock/FIFO/Movement direct-write, simple-master browser write, tiga belas nama
routine canonical, absence/presence permission hook, serta dokumen nonfinal.
Tidak ada key yang diubah dari `SHADOW`; output live wajib direview sebelum
migration enforcement atau editor preset Inventory dibuat.

SLD-R1 sekarang READY TO RUN sebagai diagnostic satu statement SELECT-only.
Ia mengaudit dependency, total/payment/receivable, snapshot Invoice/SJ, offline
nonterminal queue, candidate akun Revenue, catalog/rule Finance, Tax decision,
Return decision, serta zero-value legacy scope. `SETUP`, `BACKFILL`, dan
documented `REVIEW` adalah expected; setiap `BLOCKER` harus nol sebelum R2.

User kemudian mengirim output SLD-R1 tanpa `BLOCKER`: reconciliation,
dependency, runtime routine, Invoice/SJ, offline queue, dan Revenue candidate
seluruhnya aman; `REVIEW` Tax/Return serta zero legacy `BACKFILL` diterima
sesuai keputusan approved. SLD-R2 sekarang local-ready melalui migration
`20260811140000`: fee Delivery retry-safe ditambahkan setelah Product rounding,
ikut total/payment/receivable, tersnapshot pada receipt/Invoice/Event, dan
mempunyai Company mapping `DELIVERY_FEE_REVENUE`. Historical snapshot/Event
tetap immutable. Actual Sale journal tetap controlled `HOLD` sampai G6 membuka
resolver/rule Sale secara eksplisit; ini bukan alasan memproses 25 HOLD lama.
User kemudian mengonfirmasi migration foundation, forward fix, postflight, dan
behavioral R2 seluruhnya sukses. SLD-R2 menjadi database-applied. SLD-R3 kini
local-ready: checkout hanya menampilkan checkbox ringkas `Perlu dikirim`, detail
tujuan/ongkir berada di modal custom yang Escape-close, Customer menjadi nilai
awal, Draft restore dan Offline payload menyimpan fee/display mode, payment
memakai total yang sama, Invoice menghormati `SHOW_SEPARATE`/`HIDE_BREAKDOWN`,
dan Surat Jalan tetap quantity-only. PWA dan Backoffice lint/build PASS;
authenticated online/offline print smoke masih wajib sebelum R3 ditutup.

Upload internal tetap dilarang untuk bukti transaksi. Hanya Company logo yang
dibuka sebagai exception branding eksplisit. Sales Invoice bukan e-Faktur dan
Supplier Invoice Purchase tidak berubah. Logistics advanced tetap deferred.

---

## 9. Pilot, Cutover, dan Rollback

### ACP-4A Inventory simple-master correction

Live ACP-4 preflight found direct authenticated mutation on UOM, Warehouse,
Store, and POS Terminal. Before Inventory permission enforcement can start,
ACP-4A must pass: UOM/Warehouse mutations use guarded audited RPCs; browser
table mutation on all four relations is absent; Store/Terminal remain read-only
until an approved provisioning/CRUD scope exists; and the nine Inventory
permission keys remain `SHADOW`. Runbook:
`runbooks/ACP4A_GUARDED_INVENTORY_MASTER_BOUNDARY.md`.

### ACP-4B first enforced key

Live ACP-4B preflight confirmed the remaining blocker was authenticated
column-level Product Category identity write. The approved correction enforces
exactly `inventory.master_data`: Category/UOM/Warehouse/Category-Tax mutation
requires effective `MANAGE`, consolidated page read requires `VIEW`, navigation
uses the same effective resolver, and the grouped user-detail editor exposes
the four restriction presets. `LIHAT_SAJA` and `OPERASIONAL` are read-only for
this VIEW/MANAGE master key; `TANPA_AKSES` removes navigation and rejects API;
`IKUTI_ROLE` preserves the ACP-1 role baseline. All other Inventory keys remain
SHADOW until their complete workflow boundaries pass. Runbook:
`runbooks/ACP4B_INVENTORY_MASTER_ENFORCEMENT_ROLLOUT.md`.

### ACP-4C Product permission enforcement

ACP-4C is local-ready after a live preflight with no blocker. It enforces
exactly `inventory.products`: full Product management read needs `VIEW`,
Product/UOM/Tax mutation needs `MANAGE`, and Product Data Exchange/import stages
need the applicable `VIEW`/`EXPORT`/`IMPORT`. Cross-module Product references
are not authorized by a client purpose flag: Stock, Pricelist, Bundle, Supplier,
and Purchase use a separate reference endpoint requiring effective VIEW on at
least one approved consumer key. Bundle remains `sales.bundles` and
Product-Supplier authority is unchanged. Remaining Inventory keys stay SHADOW.
Runbook: `runbooks/ACP4C_PRODUCT_PERMISSION_ENFORCEMENT_ROLLOUT.md`.

User mengonfirmasi migration, postflight, behavior, dan closing diagnostic
ACP-4C seluruhnya PASS/INFO. Gate aktif berpindah ke ACP-4D SELECT-only untuk
`inventory.stock_real` dan `inventory.stock_movements`. Audit ini wajib
memisahkan composite Stock Real/valuasi FIFO dari immutable Movement ledger,
menutup export/direct-route bypass, dan mempertahankan on-hand reference yang
memang dibutuhkan workflow berwenang. Tidak ada key baru yang di-enforce sampai
output live direview. Runbook:
`runbooks/ACP4D_STOCK_READ_MODELS_PREFLIGHT.md`.

Live ACP-4D preflight kemudian diterima tanpa blocker: seluruh tenant,
Stock-Movement-FIFO, RLS, direct-write, dan duplicate invariant PASS. Dua REVIEW
dan satu SETUP menjadi implementation target. Slice lokal menambah guarded
Stock Real composite RPC dan Kartu Stok RPC terpisah, menghitung FIFO value dan
Movement terakhir di server, menutup navigation/API/export melalui effective
capability, mempertahankan raw on-hand read yang RLS-scoped untuk consumer
operasional, serta menyediakan CSV tanpa UUID sumber. Manual rollout dan
authenticated two-Company/preset smoke mengikuti
`runbooks/ACP4D_STOCK_READ_MODEL_ENFORCEMENT_ROLLOUT.md`.

User mengonfirmasi seluruh migration/postflight/behavior/closing ACP-4D hanya
berisi PASS/INFO. ACP-4D dianggap live; authenticated preset/two-Company smoke
tetap dikumpulkan pada closure. Gate berikutnya adalah ACP-4E SELECT-only untuk
`inventory.stock_transfers`. Audit wajib memisahkan VIEW dari
CREATE/EDIT/POST/CANCEL, mengganti direct browser table read dengan composed
read boundary, menyediakan narrow Gudang/Product reference tanpa mewajibkan
Master Inventory, dan mempertahankan atomic FIFO relocation, paired Movement,
idempotency, tenant isolation, serta role baseline. Runbook:
`runbooks/ACP4E_STOCK_TRANSFER_PERMISSION_PREFLIGHT.md`.

Live ACP-4E preflight kemudian diterima tanpa blocker: lifecycle, paired
Movement, FIFO/Stock reconciliation, tenant override, mutation signatures, dan
direct-write boundary seluruhnya PASS. Slice lokal memindahkan browser dari
empat tabel Transfer ke composed RPC yang juga menyediakan narrow Product dan
Gudang reference, menjaga Save/Create/Edit/Post/Cancel dengan capability
terpisah, dan menutup direct authenticated table SELECT setelah active consumer
dipindahkan. Core atomic FIFO relocation, Movement pair, idempotency, serta role
baseline tidak berubah. Manual rollout mengikuti
`runbooks/ACP4E_STOCK_TRANSFER_PERMISSION_ENFORCEMENT_ROLLOUT.md`.

User kemudian mengonfirmasi seluruh ACP-4E migration/postflight/behavior dan
closing diagnostic hanya PASS/INFO. Transfer Stok dianggap live ENFORCED;
authenticated preset/two-Company smoke tetap closure evidence. Gate berikutnya
adalah ACP-4F SELECT-only untuk `inventory.stock_adjustments`. Audit wajib
menjaga capability VIEW/Create/Edit/Post/Cancel, composed read/reference,
FIFO/Movement/Finance invariant, serta jalur internal Stock Opname yang membuat
Adjustment canonical tanpa menjadikannya permission bypass. Runbook:
`runbooks/ACP4F_STOCK_ADJUSTMENT_PERMISSION_PREFLIGHT.md`.

Live ACP-4F preflight diterima tanpa blocker. Tiga REVIEW dan dua SETUP menjadi
target implementasi: composed Adjustment read/reference, capability
Create/Edit/Post/Cancel, direct table-read closure, serta trusted private core
untuk panggilan Stock Opname. Slice lokal juga menyediakan narrow compatibility
read bagi halaman Opname sehingga penutupan tabel Adjustment tidak merusak
consumer aktif. Atomic FIFO, Movement, Finance event, idempotency, dan role
baseline tidak diubah. Manual rollout mengikuti
`runbooks/ACP4F_STOCK_ADJUSTMENT_PERMISSION_ENFORCEMENT_ROLLOUT.md`.

User kemudian mengonfirmasi migration, postflight, behavior, regression G3,
dan closing generic ACP-4F hanya PASS/INFO. Penyesuaian Stok dianggap live
ENFORCED; enam dari sembilan key Inventory sekarang enforced. Gate berikutnya
adalah ACP-4G SELECT-only untuk `inventory.stock_opnames`. Audit wajib
memisahkan Backoffice VIEW/REVIEW/POST dari channel blind count Kasir,
mempertahankan Store/Gudang scope, recount/supersede, idempotency, dan trusted
private Adjustment core, serta menutup direct browser read hanya setelah
composed consumer siap. Opening Stock dan Minimum Stock tetap di luar fase.
Runbook: `runbooks/ACP4G_STOCK_OPNAME_PERMISSION_PREFLIGHT.md`.

Live ACP-4G preflight diterima tanpa blocker. Tiga REVIEW dan dua SETUP menjadi
target implementasi: composed Backoffice read, pemisahan report dari blind
count, capability Review/Post/Cancel, narrow Gudang/actor/Adjustment proof, dan
direct table-read closure. Implementasi lokal mempertahankan Store/Gudang
ceiling existing untuk Kasir, membuat custom restriction hanya dapat
mengurangi akses, serta tetap memakai trusted Adjustment core ACP-4F. Manual
rollout mengikuti
`runbooks/ACP4G_STOCK_OPNAME_PERMISSION_ENFORCEMENT_ROLLOUT.md`. Opening Stock
dan Minimum Stock tetap `SHADOW` sampai slice masing-masing dibuka.

User kemudian mengonfirmasi migration, postflight, behavior, regression G3 dan
ACP-4F, serta closing ACP-4G seluruhnya PASS/INFO. Stock Opname dianggap live
ENFORCED; tujuh dari sembilan key Inventory sekarang enforced. Gate berikutnya
adalah ACP-4H SELECT-only untuk `inventory.opening_stock`. Audit wajib menjaga
keputusan approved Store Manager/Finance menyiapkan Draft dan Owner/Admin
Posting, memisahkan composed document proof dari seluruh ledger Movement,
menjaga no-prior-Movement, zero-cost reason, idempotency, tenant, serta atomic
Stock–Movement–FIFO/Finance evidence. Minimum Stock tetap di luar fase.
Runbook: `runbooks/ACP4H_OPENING_STOCK_PERMISSION_PREFLIGHT.md`.

User mengonfirmasi preflight ACP-4H tanpa `BLOCKER`; no-prior-Movement,
lifecycle, tenant, posted evidence, serta Stock–Movement–FIFO reconciliation
seluruhnya PASS. REVIEW/SETUP yang tersisa menjadi target enforcement:
Company Owner/Admin dapat Post, Finance dan Store Manager hanya menyiapkan
Draft (Store Manager dibatasi Gudang Store assignment), Accounting report-only,
dan seluruh browser read dipotong ke satu composed RPC. Implementasi lokal,
postflight, behavior, G3 regression, serta authenticated smoke mengikuti
`runbooks/ACP4H_OPENING_STOCK_PERMISSION_ENFORCEMENT_ROLLOUT.md`. Minimum Stock
tetap `SHADOW` dan tidak dibuka oleh fase ini.

User kemudian mengonfirmasi seluruh langkah rollout ACP-4H PASS setelah fixture
behavior menetapkan active Company context untuk setiap pergantian actor.
Stok Awal dianggap live ENFORCED; delapan dari sembilan key Inventory sekarang
enforced. Gate berikutnya adalah ACP-4I SELECT-only untuk
`inventory.minimum_stock`. Audit mencakup composed read beserta reference
Product/Base-UOM/Gudang dan saldo sempit, capability mutation/import/export,
threshold precision, audit/tenant, nonterminal import, serta keputusan scope
Store Manager. Minimum Stock tetap `SHADOW` sampai output preflight direview.
Runbook: `runbooks/ACP4I_MINIMUM_STOCK_PERMISSION_PREFLIGHT.md`.

Live ACP-4I preflight diterima tanpa `BLOCKER`. Data, threshold/Base-UOM,
tenant, audit, direct-write, dependency, dan nonterminal import seluruhnya
PASS. Tiga REVIEW dan tiga SETUP menjadi target implementasi: composed read
mandiri, pemutusan direct table/read dependency, capability-aware mutation dan
import/export, serta Store Manager hanya pada Gudang Store assignment aktif;
Warehouse Admin tetap Company-wide. Implementasi lokal mengikuti
`runbooks/ACP4I_MINIMUM_STOCK_PERMISSION_ENFORCEMENT_ROLLOUT.md`. Notice tetap
non-blocking dan tidak membuat Stock Request atau Supplier Order otomatis.

User kemudian mengonfirmasi seluruh rollout ACP-4I sukses. Minimum Stock adalah
key Inventory kesembilan yang live ENFORCED; authenticated preset/two-Company
smoke tetap closure evidence. ACP-5 dibuka bertahap dan tidak sekaligus:
ACP-5A adalah SELECT-only preflight `contacts.customers`. Gate ini mengaudit
Customer/Category/parent/Pricelist management, POS quick-create, Customer
Balance Finance, shared Sales references, Data Exchange, tenant/hierarchy,
direct browser boundary, serta capability hook. Tidak ada runtime Customer yang
diubah sebelum output preflight direview.

Live ACP-5A preflight diterima tanpa `BLOCKER`. Customer identity/category,
parent/Pricelist, tenant, Walk-In, balance cache, direct-write, dan existing
mutation contract seluruhnya PASS. REVIEW/SETUP yang ditemukan ditutup secara
lokal melalui satu composed management RPC, capability-aware Customer dan
Category writer, explicit Customer Category Import, direct table-read closure,
serta reference RPC terpisah untuk POS, Sales Document/Return, dan Finance
Customer Balance. `contacts.customers` belum dianggap live ENFORCED sampai
migration, postflight, behavior, regression, dan authenticated smoke pada
`runbooks/ACP5A_CUSTOMER_PERMISSION_ENFORCEMENT_ROLLOUT.md` selesai.

User kemudian mengonfirmasi seluruh rollout ACP-5A sukses dan seluruh hasil
PASS. `contacts.customers` dianggap live ENFORCED; POS quick-create,
Customer Balance/credit, dan Sales reference tetap memakai authority terpisah.
Gate aktif berpindah ke ACP-5B SELECT-only untuk `contacts.suppliers`.
Preflight ini mengaudit Supplier dan Product-Supplier sebagai satu management
boundary, rekening referensi, normalized identity/preferred Supplier,
Product-UOM pembelian, dua fixed import type, direct browser access, serta
consumer Purchase Order/Return, Product, Supplier Invoice/AP/Payment, dan Data
Exchange. Tidak ada enforcement Supplier/Purchase/Finance sebelum output
`runbooks/ACP5B_SUPPLIER_PERMISSION_PREFLIGHT.md` direview tanpa blocker.

Live ACP-5B preflight diterima tanpa `BLOCKER`. Supplier/Product-Supplier,
tenant, normalized identity, preferred relation, Product-UOM pembelian,
operational document reference, direct-write boundary, dan nonterminal import
seluruhnya PASS. REVIEW/SETUP menjadi target satu cutover lokal: composed
Contacts workspace, guarded Manage/Import/Export, direct table-read closure,
serta reference RPC terpisah untuk Supplier Order, Purchase Return, Goods
Receipt Kasir, POS Purchase Return, Supplier Invoice, dan Supplier Payment.
Backoffice/PWA telah dipindahkan dari direct Supplier read. Manual rollout,
regression, dan two-Company/preset smoke mengikuti
`runbooks/ACP5B_SUPPLIER_PERMISSION_ENFORCEMENT_ROLLOUT.md`. Purchase, Sales,
dan Finance permission key lain tetap `SHADOW` sampai preflight masing-masing.

User kemudian mengonfirmasi seluruh SQL ACP-5B sukses. `contacts.suppliers`
dianggap live ENFORCED dengan Supplier/Product-Supplier, import/export,
Purchase/Finance reference, serta PWA Goods Receipt/Purchase Return tetap pada
authority terpisah. Gate aktif berpindah ke ACP-5C SELECT-only untuk
`purchase.supplier_orders`. Preflight mengaudit workspace Backoffice, Stock
Request open-session Cashier, Goods Receipt consumer, allocation/lifecycle,
zero-effect Supplier Order, tenant, direct browser access, dan capability hook.
Tidak ada runtime Purchase yang diubah sebelum seluruh output
`runbooks/ACP5C_SUPPLIER_ORDER_PERMISSION_PREFLIGHT.md` direview tanpa blocker.

User kemudian mengonfirmasi seluruh output ACP-5C preflight PASS/INFO dengan
REVIEW/SETUP sesuai rancangan. Paket enforcement local-ready memisahkan composed
Backoffice Supplier Order workspace dari narrow Stock Request dan Goods Receipt
Cashier consumer, menambahkan capability hook pada aksi Order/manager, menutup
direct browser read setelah cutover application, serta mempertahankan Purchase
Return dan Supplier reference pada authority independen. Runtime belum boleh
ditulis sebagai ENFORCED sebelum migration, postflight, behavior, regression,
dan authenticated two-Company/preset smoke pada runbook ACP-5C lulus.

User kemudian mengonfirmasi migration, postflight, behavior, seluruh regression,
dan closing ACP-5C sukses. `purchase.supplier_orders` dianggap database-live
ENFORCED; authenticated preset/two-Company smoke tetap dicatat sebagai closing
UAT. Gate berikutnya dibuka hanya sebagai ACP-5D SELECT-only preflight untuk
`purchase.purchase_returns`: Backoffice Review/Post, Cashier open-session
Draft/Edit, mixed cancel, Return-scoped source Receipt/FIFO/AP, direct browser
read, final-effect/idempotency, dan tenant isolation. Tidak ada Return runtime,
grant, schema, atau data yang diubah oleh preflight.

User mengonfirmasi seluruh ACP-5D preflight tanpa blocker. Paket enforcement
local-ready memisahkan composed Backoffice `VIEW` dari PWA open-session source,
menjaga Review/Post/Cancel Final dengan capability efektif, mempertahankan
Cashier Draft/Edit dan cancel miliknya, serta baru mencabut direct SELECT setelah
consumer aktif dipindahkan. G5 atomic Return core tetap private dan kompatibel.
Runtime belum boleh ditulis ENFORCED sebelum migration, postflight, behavior,
G5/ACP regression, dan authenticated preset/two-Company smoke lulus.

User kemudian mengonfirmasi seluruh migration, postflight, behavior, dan
regression ACP-5D PASS. `purchase.purchase_returns` dianggap database-live
ENFORCED; authenticated preset/two-Company smoke tetap closing UAT. Gate aktif
berpindah hanya ke ACP-5E SELECT-only preflight `sales.sales_documents` untuk
Backoffice list/detail/print/export dan Delivery lifecycle. POS checkout,
Sales Return, shared Sale tables, Stock, Payment, dan Finance tetap memakai
authority terpisah serta tidak diubah oleh preflight.

Live ACP-5E preflight diterima tanpa `BLOCKER`; migration, postflight, behavior,
dan regression berikutnya user-confirmed PASS. `sales.sales_documents` kini
database-live ENFORCED. Authenticated preset/two-Company smoke tetap closing
UAT. Gate aktif berpindah ke ACP-5F SELECT-only preflight
`sales.pricelists`; Customer assignment, POS online/offline resolver, Sale
snapshot, dan direct-read cutover wajib tetap memakai authority terpisah sampai
preflight dinilai bersih dan enforcement khusus disetujui.

Live ACP-5F preflight kemudian diterima tanpa `BLOCKER`/`BACKFILL`. Catalog,
default Global, reusable Customer assignment, Store scope, Product-UOM rule,
Sale snapshot, direct-write, tenant override, dan server resolver seluruhnya
PASS. Paket local-ready memisahkan composed Backoffice `VIEW`, mutation
`MANAGE`, export `EXPORT`, open-session POS reference, serta existing Offline
snapshot. Overload mutation legacy juga dikarantina dari browser. Runtime tetap
SHADOW sampai seluruh urutan migration/postflight/behavior/regression/smoke pada
runbook ACP-5F selesai.

User kemudian mengonfirmasi migration, postflight, behavior, dan seluruh
regression ACP-5F PASS. `sales.pricelists` sekarang database-live ENFORCED;
authenticated preset/two-Company smoke tetap closing UAT. Gate aktif berpindah
hanya ke ACP-5G SELECT-only preflight `sales.bundles`. Boundary yang harus
dipertahankan: Bundle Product + sales UOM + komposisi disimpan atomik, Product
STOCK tetap milik `inventory.products`, Bundle tidak mempunyai stok/FIFO fisik,
POS melakukan server-side component expansion dengan session authority sendiri,
dan Sales Return memakai immutable allocation tanpa memperoleh Bundle MANAGE.

Live ACP-5G preflight kemudian diterima tanpa `BLOCKER`/`BACKFILL`. Paket
enforcement local-ready membuat composed Bundle management/reference read,
menjaga atomic save dan availability melalui capability efektif, menutup hanya
dua dedicated Bundle table read, serta memperbaiki UI agar tombol kelola
mengikuti `sales.bundles`—bukan Minimum Stock. Runtime Bundle masih SHADOW
sampai migration, postflight, behavior, regression Bundle/POS/Return/Product/
Pricelist, dan authenticated two-Company smoke pada runbook lulus.

User kemudian mengonfirmasi seluruh ACP-5G rollout dan regression PASS.
`sales.bundles` sekarang database-live ENFORCED; authenticated preset/two-
Company smoke tetap closing UAT. Gate aktif berpindah hanya ke ACP-5H
SELECT-only preflight `sales.sales_returns`. Cashier source/Draft, Backoffice
final Post/Cancel, refund, original FIFO restoration, Bundle allocation,
delivery-fee decision, dan Finance HOLD wajib tetap dipisahkan.

Live ACP-5H preflight kemudian diterima tanpa `BLOCKER`/`BACKFILL`. Paket
enforcement local-ready memisahkan composed Backoffice `VIEW`, final `POST` dan
Draft `CANCEL_FINAL` dari PWA source/Draft yang tetap open-session scoped.
Direct read lima tabel khusus Return ditutup hanya setelah kedua consumer
dicabut. Lifecycle tidak ditambah status Review, original FIFO/Bundle/refund/
ongkir dipertahankan, dan event Finance tetap `HOLD`. Runtime tetap SHADOW
sampai migration, postflight, behavior, regression, dan smoke runbook lulus.

User kemudian mengonfirmasi seluruh ACP-5H migration, postflight, behavior, dan
regression PASS. `sales.sales_returns` sekarang database-live ENFORCED dan
ACP-5 ditutup; authenticated preset/two-Company/PWA smoke tetap closing UAT.
Gate aktif berpindah ke ACP-6A SELECT-only `finance.expenses`. Expense harus
dipotong terpisah antara Backoffice effective capability dan PWA open-session;
Cash drawer, maker-checker, append-only settlement/return/additional, serta
Finance HOLD tidak boleh berubah.

Live ACP-6A preflight kemudian diterima tanpa `BLOCKER`/`BACKFILL`. Paket
enforcement `20260813060000` local-ready memisahkan composed Backoffice
`VIEW/MANAGE/APPROVE/POST/CANCEL_FINAL` dari PWA Cashier yang tetap dibatasi
Company, Store, open Session, payment type, dan custom restriction. Sembilan
tabel khusus Expense ditutup dari direct browser read setelah consumer aktif
berpindah ke RPC; `cash_drawer_movements` dan `cash_in_documents` tetap shared
untuk workflow kas lain. Finance event tetap HOLD dan tidak ada Journal baru.
Runtime live tetap SHADOW sampai migration, postflight, behavior, regression,
dan authenticated Backoffice/PWA smoke lulus.

User kemudian mengonfirmasi ACP-6A migration, postflight, behavior, dan smoke
sukses. `finance.expenses` sekarang database-live ENFORCED; seluruh 13 guarded
mutation core tertutup, direct Expense reads ditutup, Cashier channel tetap
Store/open-session scoped, shared drawer relation dipertahankan, dan Finance
events tetap HOLD. Gate aktif berpindah hanya ke ACP-6B SELECT-only preflight
`finance.cash_deposits`; tidak ada runtime Setor Kas/Variance/Journal yang
diubah sebelum output live dinilai.

Live ACP-6B preflight kemudian diterima tanpa `BLOCKER`/`BACKFILL`. Paket
enforcement `20260813070000` local-ready: Backoffice memakai composed
`finance.cash_deposits VIEW`, approve/reject memakai effective capability,
sedangkan Draft/Submit/Cancel Kasir tetap dibatasi existing CLOSED-session,
Store, actor, dan custom restriction. Empat tabel khusus Setor Kas ditutup dari
direct browser read setelah Backoffice dan Deposit Variance dipindahkan ke RPC
terpisah. Deposit Variance tidak mewarisi authority Setor Kas; Financial Event
tetap `HOLD` dan tidak ada Journal yang diproses. Runtime live tetap SHADOW
sampai migration, postflight, behavior, regressions Phase-43/46, dan smoke
Backoffice/PWA lulus.

User kemudian mengonfirmasi ACP-6B migration, postflight, behavior, dan kedua
regression sukses; authenticated Backoffice/PWA/preset smoke ditunda secara
eksplisit untuk closing UAT gabungan. `finance.cash_deposits` dianggap
database-live ENFORCED, tetapi status smoke tetap `PENDING`, bukan PASS.
Gate aktif berpindah hanya ke ACP-6C SELECT-only
`finance.deposit_variances`. Preflight tidak boleh mengubah exception,
allocation, request, Setor Kas, Financial Event HOLD, atau Journal.

Live ACP-6C preflight diterima tanpa `BLOCKER`/`BACKFILL`; satu exception
historis telah `RESOLVED` dan rantai request/allocation/audit/event HOLD
rekonsiliasi. Paket enforcement `20260813080000` local-ready: composed
Backoffice `VIEW`, `MANAGE` untuk investigation dan pengajuan resolusi,
`APPROVE/REVIEW` untuk maker-checker Owner/Admin, serta private trusted cores.
Empat tabel dedicated ditutup dari direct browser read setelah API berpindah ke
RPC. Linked Cash Deposit hanya snapshot sempit, event tetap HOLD, dan tidak ada
Journal yang diproses. Runtime live tetap SHADOW sampai rollout manual lulus.

User kemudian mengonfirmasi ACP-6C migration, postflight, behavior, dan
regression seluruhnya PASS. Runtime database sekarang ENFORCED; authenticated
smoke tetap `PENDING` dan digabung pada closing UAT.

Gate aktif berikutnya hanya ACP-6D SELECT-only
`finance.customer_balances`. Audit wajib mempertahankan ledger immutable,
cache-to-ledger reconciliation, correction maker-checker, policy/feature
lifecycle, tenant boundary, serta authority terpisah untuk POS overpayment dan
balance tender. ACP-6D tidak boleh mengubah saldo, request, Payment, Financial
Event HOLD, Journal, grant, RLS, atau RPC sebelum output live dinilai.

Live ACP-6D preflight diterima tanpa `BLOCKER`/`BACKFILL`; seluruh lifecycle,
ledger/cache, source, tenant, maker-checker, dan mutation boundary PASS.
Migration `20260813090000` local-ready dengan composed Backoffice read,
guarded statement/correction/review/export, private proven G4 cores, serta
direct read closure. POS overpayment credit dan Customer Balance tender tidak
diubah dan tetap memakai Sale/open-session authority sendiri. Manual rollout,
postflight, behavior, regressions Phase-49/52/56, dan postflight ulang wajib
lulus; smoke ditunda ke closing UAT gabungan.

User kemudian mengonfirmasi forward-fix `20260813100000`, postflight,
behavior, regression Phase-49, Phase-52, Phase-56, dan postflight ulang
seluruhnya PASS. ACP-6D sekarang database-live `ENFORCED`; authenticated smoke
tetap digabung pada closing UAT.

Gate aktif berikutnya adalah ACP-6E Supplier Invoice preflight SELECT-only.
Audit harus mempertahankan optional tolerance sebagai kebijakan tambahan,
maker-validator separation, immutable validated invoice/AP evidence, tenant
isolation, Supplier Payment sebagai consumer terpisah, serta Financial Event
yang tetap `HOLD`. ACP-6E tidak boleh membuat Journal atau mengubah runtime
sebelum output preflight live dinilai.

Live ACP-6E preflight kemudian diterima tanpa `BLOCKER`/`BACKFILL`; schema,
routine, lifecycle, matching/allocation, tolerance, tenant, event coverage, dan
browser mutation boundary seluruhnya PASS. Migration `20260813110000`
local-ready dengan composed Invoice read, guarded Draft/Edit/Post,
`APPROVE` untuk kebijakan tolerance, export bulanan, referensi payable sempit
untuk Supplier Payment, referensi linked Invoice sempit untuk Purchase Return,
dan direct read closure. Event Supplier Invoice tetap `HOLD`; Journal tidak
diproses. Rollout manual, postflight, behavior, regression G5 Phase-11/14,
optional-tolerance postflight, dan postflight ACP-6E ulang wajib lulus.

User kemudian mengonfirmasi seluruh ACP-6E database rollout dan regression
PASS. Gate aktif berikutnya adalah ACP-6F Supplier Payment preflight
SELECT-only. Audit harus mempertahankan DRAFT/VALIDATED/CANCELED, idempotent
validation, Draft-only cancellation, immutable AP allocation/effect, narrow
Supplier/payable-Invoice/source-account references, tenant isolation, dan
Financial Event HOLD. ACP-6F tidak boleh membuat status review baru, membuka
final cancellation/reversal, memproses Journal, atau mengubah Payment Method.

Live ACP-6F preflight kemudian diterima tanpa `BLOCKER`/`BACKFILL`; seluruh
lifecycle, allocation/AP balance, tenant, audit, source-account, event, dan
browser mutation invariant PASS. Migration `20260813120000` local-ready dengan
composed read, Draft/Edit/Post, eligible source-account validation, Draft-only
cancel, export bulanan, dan direct-table closure. Rollout dan regressions harus
lulus; dua Payment Event tetap HOLD dan Journal tidak diproses.

User kemudian mengonfirmasi ACP-6F postflight seluruhnya PASS setelah behavior
dan regression sukses. Gate aktif berikutnya adalah ACP-6G Payment Method
preflight SELECT-only. Audit wajib mempertahankan exact-one active default per
Company, Store/period eligibility, fee/proof/route/Account Function contract,
system-owned Customer Balance/Ketul Offset, immutable Sales snapshot, tenant
dan audit, serta pemisahan Backoffice authority dari POS online/offline dan
Expense. Supplier Payment `CASH/BANK_TRANSFER/CHEQUE` tetap kontrak ACP-6F dan
tidak boleh diubah implisit. ACP-6G belum mengubah runtime sampai output live
tanpa blocker/backfill dinilai.

Live ACP-6G preflight kemudian diterima tanpa `BLOCKER`; empat metode lama
memerlukan audit backfill terukur. Migration `20260813130000` local-ready:
composed Backoffice VIEW, guarded ordinary-method MANAGE, CSV EXPORT,
open-session POS reference, Expense POST reference, truthful actor-null
`BACKFILL`, immutable audit, dan penutupan tiga direct reads. Import tetap
tertutup, metode sistem tetap module-owned, Supplier Payment enum tidak
digabung, dan tidak ada Financial Event/Journal yang diproses. Manual rollout,
postflight, behavior, regressions G2 Phase-14/36, G4 Phase-8, serta ACP-6A
wajib lulus sebelum gate bergerak.

User kemudian mengonfirmasi behavior, seluruh regression yang telah
diselaraskan dengan ACP execution chain, dan closing ACP-6G postflight
seluruhnya PASS. `finance.payment_methods` sekarang database-live `ENFORCED`;
authenticated role/preset/two-Company smoke tetap menjadi ACP-7 closing UAT.
Gate aktif berpindah ke ACP-7 security closure, dimulai dengan diagnostic
SELECT-only `acp_phase7_security_closure_preflight.sql`. ACP-7 tidak membuka
modul bisnis atau migration baru sebelum output live dinilai.

Sebelum authenticated matrix, user meminta koreksi lifecycle akses
multi-Company: detail user harus memilih Company secara eksplisit, role/Store
dan override harus jelas tenant targetnya, serta akses Company harus dapat
dicabut secara guarded. Migration additive `20260813140000` dan Backoffice
cutover local-ready dengan last-owner/hierarchy guard, immutable assignment dan
permission audit, context repair, serta compatibility wrapper. Gate ACP-7 tetap
pending sampai migration, postflight, behavior, dan two-Company revoke smoke
user-confirmed PASS.

User kemudian mengonfirmasi migration ledger, seluruh postflight, dan behavior
Company access lifecycle PASS. Database gate `20260813140000` ditutup; hanya
authenticated two-Company UI smoke yang masih pending sebelum ACP-7 matrix.

Revisi langsung user 2026-08-13 memisahkan workspace dokumen: Invoice tetap
Sales, sedangkan Surat Jalan menjadi operasi Inventory tanpa mengubah source
Sale atau efek transaksi. Implementasi additive local-ready pada migration
`20260813150000` menambah permission `inventory.delivery_documents`, composed
quantity-only read, guarded print/lifecycle, dan memisahkan UI/API. POS tetap
memakai posted-Sale session authority. Manual rollout, postflight, behavior,
ACP-7/PRD-1 rerun, dan authenticated role smoke wajib lulus sebelum closure.

### Deployment timing

Kondisi project saat G1 adalah **runtime lokal + GitHub untuk versioning + Supabase**. Belum ada Vercel project dan tidak perlu membuat deployment hanya untuk menyelesaikan migration gate.

Urutan deployment yang disetujui:

1. **G1 berjalan:** Backoffice/PWA tetap lokal. Push GitHub dipakai untuk versioning/review, bukan tanda siap deploy.
2. **Setelah G2 lulus:** buat Vercel project dan environment **Preview** untuk Backoffice serta PWA. Konfigurasi environment variable, Supabase Auth redirect/allowlist, domain preview, dan server-only secret. Preview hanya memakai test/UAT data dan belum menerima transaksi operasional.
3. **Setelah G3 dan G4 lulus lokal:** gunakan Preview untuk internal end-to-end UAT Product/Stock/Session/Checkout, pengukuran network/function/egress, serta retry/concurrency. Feature optional tetap disabled kecuali UAT-nya sendiri sudah lulus.
4. **Setelah G5 dan G6 serta seluruh cutover checklist lulus:** buat deployment **Production pilot** untuk satu Company, satu Store, dan satu POS Terminal.
5. **Setelah pilot reconciliation stabil:** perluas Store/Terminal bertahap. Jangan menganggap GitHub push, Vercel build PASS, atau Preview URL sebagai production approval.

DEX-4 navigation cutover sudah local-ready dan closing authenticated matrix
masih manual. Sesudah itu, UXD-1/2, BRD-1, SLD-1/2/3, dan PRD-1 di atas wajib
diselesaikan sebelum Vercel Preview dipakai untuk full internal UAT. Production
pilot tetap menunggu seluruh server permission, Finance, DEX, branding,
Sales document, E2E, reconciliation, dan environment cutover evidence.

Auto-deploy Production dari branch kerja tidak boleh diaktifkan. Production harus memakai protected branch/tag atau approval manual dan selalu merujuk migration manifest + rollout evidence yang sesuai.

### Pilot scope

- satu Company;
- satu Store;
- satu POS Terminal;
- user terbatas: Super Admin, Company Admin, Store Manager, Finance, satu-dua Cashier;
- master dan opening stock telah direview dua orang;
- Ketul/Customer Balance/Tax hanya dinyalakan bila UAT fiturnya lulus.

### Cutover checklist

1. freeze input master lama selama window singkat;
2. backup/snapshot dan catat row count/checksum;
3. jalankan migration + backfill + postflight;
4. import master, review error, lalu Opening Stock;
5. lakukan controlled sale Cash, Transfer, TEMPO, Return, Expense, Deposit, Receipt;
6. cocokkan stock movement, session cash, AR/AP, event, journal, dan reports;
7. buka pilot dengan monitoring error queue dan daily reconciliation.

### Rollback trigger

- cross-tenant visibility/mutation;
- stock negatif/lost movement;
- duplicate sale/payment/journal akibat retry;
- jurnal tidak balance;
- offline queue kehilangan transaksi;
- discrepancy material yang tidak dapat ditelusuri ke source.

### Rollback action

- matikan feature/checkout mutation dan pertahankan read-only;
- hentikan worker Finance jika sumber event bermasalah;
- jangan hapus transaksi pilot;
- export source/event/movement/journal untuk reconciliation;
- gunakan compensating reversal/adjustment setelah penyebab disetujui;
- restore hanya jika runbook membuktikan tidak menghilangkan transaksi sah setelah snapshot.

---

## 10. Urutan Kerja Pertama
1. G0 migration manifest dan live-state audit;
2. G1 tenant constraint/RLS/feature entitlement;
3. desain canonical master schema G2 beserta import dry-run contract;
4. test harness tenant + RPC concurrency yang akan dipakai semua gate.

Jangan mulai dari mempercantik halaman Produk atau menambah menu POS. Kedua UI tersebut baru aman disambungkan setelah contract G1–G3 stabil.
