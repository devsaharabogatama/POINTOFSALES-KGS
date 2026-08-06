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
scope AP provisional existing yang expected. Phase 11 matching foundation
sekarang local-ready untuk rollout manual. Supplier Payment, valuation final,
dan Journal G6 tetap belum dibuka.

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

### Exit criteria

- seluruh mapping wajib untuk feature pilot lengkap;
- trial balance seimbang dan tidak ada orphan event/journal;
- close/reopen/reversal UAT lulus;
- hard-coded COA worker lama tidak lagi menjadi execution path aktif.

---

## 9. Pilot, Cutover, dan Rollback

### Deployment timing

Kondisi project saat G1 adalah **runtime lokal + GitHub untuk versioning + Supabase**. Belum ada Vercel project dan tidak perlu membuat deployment hanya untuk menyelesaikan migration gate.

Urutan deployment yang disetujui:

1. **G1 berjalan:** Backoffice/PWA tetap lokal. Push GitHub dipakai untuk versioning/review, bukan tanda siap deploy.
2. **Setelah G2 lulus:** buat Vercel project dan environment **Preview** untuk Backoffice serta PWA. Konfigurasi environment variable, Supabase Auth redirect/allowlist, domain preview, dan server-only secret. Preview hanya memakai test/UAT data dan belum menerima transaksi operasional.
3. **Setelah G3 dan G4 lulus lokal:** gunakan Preview untuk internal end-to-end UAT Product/Stock/Session/Checkout, pengukuran network/function/egress, serta retry/concurrency. Feature optional tetap disabled kecuali UAT-nya sendiri sudah lulus.
4. **Setelah G5 dan G6 serta seluruh cutover checklist lulus:** buat deployment **Production pilot** untuk satu Company, satu Store, dan satu POS Terminal.
5. **Setelah pilot reconciliation stabil:** perluas Store/Terminal bertahap. Jangan menganggap GitHub push, Vercel build PASS, atau Preview URL sebagai production approval.

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

Sprint implementasi pertama sebaiknya hanya mencakup:

1. G0 migration manifest dan live-state audit;
2. G1 tenant constraint/RLS/feature entitlement;
3. desain canonical master schema G2 beserta import dry-run contract;
4. test harness tenant + RPC concurrency yang akan dipakai semua gate.

Jangan mulai dari mempercantik halaman Produk atau menambah menu POS. Kedua UI tersebut baru aman disambungkan setelah contract G1–G3 stabil.
