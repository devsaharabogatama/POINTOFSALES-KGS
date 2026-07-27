# Active Development Handoff — KGS POS

**Status dokumen:** ACTIVE — wajib diperbarui setiap agent
**Terakhir diperbarui:** 2026-07-27
**Workspace:** `C:\Users\sbi_l\OneDrive\Documents\POINT OF SALES`

Dokumen ini adalah catatan operasional tunggal untuk meneruskan pekerjaan ketika
agent berganti atau context/limit habis. Dokumen ini tidak menggantikan
spesifikasi bisnis; ia menunjuk source of truth dan mencatat posisi implementasi
terakhir.

## 1. Protokol Wajib Agent

Sebelum bekerja:

1. baca root `AGENTS.md` dan `backoffice/AGENTS.md` bila menyentuh Next.js;
2. baca dokumen ini sampai selesai;
3. baca source of truth yang dirujuk pada bagian fase aktif;
4. periksa dirty worktree dan jangan menimpa perubahan user/agent lain;
5. lanjutkan dari manual gate terakhir—jangan menjalankan ulang migration yang
   sudah dikonfirmasi applied.

Sebelum handoff/final response, agent wajib memperbarui:

- tanggal dan fase aktif;
- outcome yang benar-benar selesai;
- file yang dibuat/diubah dalam turn tersebut;
- evidence lint/build/postflight/test/smoke;
- manual action yang masih harus dilakukan user;
- blocker/error persis bila ada;
- satu `Next Safe Step` yang tidak memperluas scope diam-diam.

Status yang digunakan:

- `PLANNED`: belum ada implementasi;
- `LOCAL READY`: file selesai dan pemeriksaan lokal lulus;
- `READY FOR MANUAL PREFLIGHT`: menunggu hasil SELECT-only dari user;
- `READY FOR MANUAL DATABASE ROLLOUT`: menunggu migration/postflight/test user;
- `READY FOR SMOKE TEST`: database selesai, menunggu verifikasi UI/runtime;
- `COMPLETE`: seluruh gate yang disyaratkan fase tersebut dikonfirmasi.

## 2. Posisi Implementasi Saat Ini

### G1 — Tenant/Security Closure

`COMPLETE`

- migration canonical G1 sampai `20260721150000` applied;
- security closure audit dan behavioral test lulus;
- active Company, tenant FK, RLS, role, Finance, transaction, dan inventory
  browser boundary sudah ditutup.

### G2 — Canonical Master Data

| Fase | Status | Evidence utama |
|---|---|---|
| Product Category/UOM/Warehouse foundation | COMPLETE | `20260721180000`, postflight/test dan smoke user |
| Atomic Product + Product-UOM | COMPLETE | `20260721210000`, postflight/test dan Product UI smoke |
| Supplier + Product-Supplier foundation | COMPLETE | `20260721230000`, postflight/test dan Supplier UI smoke |
| Supplier API/UI | COMPLETE | lint/build dan user menyatakan urusan Supplier aman |
| Customer preflight | COMPLETE | zero Customer/balance/duplicate; satu Walk-In backfill diperlukan |
| Customer foundation | COMPLETE | `20260722010000`; migration sukses, 13/13 postflight PASS, behavioral test PASS |
| Customer API/UI | COMPLETE | API guarded, dua tab, lint/build PASS, dan menu Customer sudah dibuka user tanpa schema-cache error |
| Customer grouping + UX consistency | DATABASE COMPLETE; UX FOLLOW-UP | DB preflight/migration/postflight/test PASS; grouping panel bekerja, dropdown induk langsung di modal Edit masih wajib dibuat |
| Pricelist preflight | COMPLETE | Dependency, Sales/Product-UOM/Customer invariant PASS; satu expected Global default backfill |
| Pricelist foundation | COMPLETE | user mengonfirmasi migration, 12 postflight, dan behavioral test seluruhnya PASS |
| Pricelist default guard | COMPLETE | user mengonfirmasi migration, 6 postflight, dan behavioral test seluruhnya PASS |
| Pricelist API/UI | COMPLETE | guarded API + Backoffice UI; harga akhir direct-entry, tier discount per UOM; lint/build dan user smoke PASS |
| Reusable Customer Pricelist correction | COMPLETE | user mengonfirmasi migration, 12/12 postflight, behavioral test, dan Customer assignment smoke aman |
| Payment Method foundation | COMPLETE | user mengonfirmasi fixed migration, 13/13 postflight, dan behavioral test PASS |
| Payment Method API/UI | COMPLETE | guarded route, validation, list/form, role-aware navigation, Escape modal, lint/build PASS, dan user smoke aman |
| Transaction Category + minimum COA preflight | COMPLETE | live result: dependency/invariant PASS, zero Expense/Event/Journal history, satu expected Company COA backfill |
| Transaction Category + minimum COA foundation | APPLIED; RUNTIME SAFE | missing-table state diselesaikan user; menu dapat dimuat, exact 14-row/test output tidak ditranskrip ulang |
| Finance Master API/UI | COMPLETE AT CURRENT BOUNDARY | guarded Category/rule API, versioned mapping UI, COA read-only, Escape modal; lint/build dan user smoke PASS |
| Required default Transaction Categories | COMPLETE | corrected 11-row postflight dan phase-18 behavioral test PASS |
| Finance history trigger branch fix | COMPLETE | migration `20260722210000`, 5-row postflight, regression test, dan phase-18 rerun seluruhnya PASS |
| Guarded COA + Company fallback | COMPLETE | User mengonfirmasi migration, 8 postflight, behavioral test, dan UI smoke all good |
| Tax Sales/Purchase preflight | COMPLETE | User mengonfirmasi seluruh hasil hanya PASS/INFO; tidak ada blocker/review |
| Tax Sales/Purchase foundation | COMPLETE | User mengonfirmasi migration, 14-check postflight, behavioral test, dan compatibility smoke all pass |
| Tax Master API/UI | COMPLETE AT MASTER BOUNDARY | User menyatakan aman; guarded versioning dan entitlement-aware UI tersedia; resolver disabled |
| Module Settings API/UI | COMPLETE AT ENTITLEMENT BOUNDARY | User menyatakan good; Super Admin Company toggle tersedia melalui audited RPC |
| Role-aware App Launcher + fast-link sidebar | COMPLETE AT CURRENT ROLE BOUNDARY | User menyatakan layout/sidebar/grouping sudah oke; granular permission tetap deferred |
| Product/Category Tax assignment preflight | COMPLETE | User result: seluruh invariant PASS; no Rule/assignment, entitlement disabled, one Product/Category |
| Guarded Product/Category Tax assignment | COMPLETE | User confirmed migration, postflight, dan behavioral test all pass |
| Tax assignment API/UI | COMPLETE | User menyatakan seluruh UI aman; Category default dan Product inheritance/override memakai nama Tax Rule |
| App shell Home navigation | LOCAL READY | Brand ikon hijau + KGS POS kembali ke launcher tanpa reload dan menutup fast link; lint/build PASS, authenticated click smoke menunggu user |
| Tax resolver/snapshot preflight | COMPLETE | User result: seluruh invariant PASS; no Rule/history; two enabled scopes resolve no tax; checkout untouched |
| Private Tax resolver/calculator | COMPLETE | User confirmed migration, postflight, dan behavioral test all pass; transaction cutover tetap disabled |
| Master Import/Export preflight | COMPLETE | Live result clean; expected legacy REVIEW only; identities/canonical Product-UOM/history safe |
| Master Import staging foundation | COMPLETE | User mengonfirmasi migration, 11-check postflight, dan behavioral test seluruhnya PASS; commit/stock disabled |
| Master Import identity validator | COMPLETE | User mengonfirmasi migration, 8-check postflight, dan behavioral test seluruhnya PASS; commit disabled |
| Master Import business validator | COMPLETE | User mengonfirmasi migration, 7-check postflight, dan behavioral test seluruhnya PASS |
| Master Import partial commit | COMPLETE | User mengonfirmasi migration `20260723190000`, 9-check postflight, dan behavioral test seluruhnya PASS |
| Master Import API/UI | READY FOR SMOKE TEST | Guarded API, CSV mapping, preview, exact UPDATE confirmation, partial result, history, error download, template/export; lint/build PASS |
| Full Master Import/Export expansion | PREFLIGHT COMPLETE; DESIGN FOLLOW-UP | User mengirim 15 hasil: seluruh invariant PASS/INFO, zero missing table/RPC, zero ambiguity/invalid reference, zero nonterminal job |
| Automatic hidden master code | COMPLETE | User mengonfirmasi DB all PASS dan melanjutkan setelah Phase-37 Backoffice name-only smoke; form/list/API tidak meminta kode teknis |
| Code-less simple master import | COMPLETE | User mengonfirmasi Phase-38 migration, 7-check postflight, dan behavioral test all good |
| Code-less Import UI cutover | COMPLETE | Template create/export/preview empat master tanpa kode teknis; Gudang memakai referensi Toko user-facing; user mengonfirmasi smoke aman |
| Remaining simple master import DB | COMPLETE | Main migration, UUID forward fix, 4-check postflight, Phase-40 behavior, dan Phase-38 regression dikonfirmasi PASS |
| Remaining simple master import UI | LOCAL READY; SMOKE PENDING | Template/export/mapping/preview tiga tipe baru selesai; lint/build PASS |

Catatan UX aktif:

- label UOM operasional memakai `name` (`Ketul`, `Dus`), bukan kode internal
  (`UOM-02`, `UOM-03`);
- kode tetap disimpan sebagai identifier master;
- Product menyimpan stok pada Base UOM; kemasan memakai faktor langsung ke base;
- kemasan terbesar otomatis menjadi acuan berat/rekomendasi UOM pembelian.

## 3. Fase Aktif

**G2 Phase 41 — remaining simple master Import/Export UI**

User mengonfirmasi Phase-40 main migration, UUID forward fix, postflight,
behavioral test, dan Phase-38 compatibility regression seluruhnya PASS pada
2026-07-27. Database tujuh simple master dinyatakan `COMPLETE`.

Preflight tiga master sederhana berikutnya bersih: seluruh invariant `PASS`,
tidak ada job nonterminal, duplicate, blank identity, hierarchy issue, atau
invalid System Event. Guarded RPC lengkap. Inventory live berisi 1 Customer
Category sistem, 36 COA sistem tanpa histori jurnal, 26 required Transaction
Category, dan 1 custom Transaction Category.

Forward migration `20260727090000` sudah applied. Constraint job diperluas
secara additive; public create/validate/commit signature tidak berubah. Empat
import existing didelegasikan ke implementation Phase 38/33 yang dipindahkan
ke private. Tiga tipe baru memakai validator sendiri dan commit melalui guarded
master RPC existing. Kategori Customer sistem, COA sistem, dan required
Transaction Category menjadi export-only. COA tetap menampilkan
`account_code` sebagai identitas bisnis.

Behavioral test pertama berhenti pada preview parent COA dengan PostgreSQL
`42883 function min(uuid) does not exist`. Root cause hanya satu aggregate UUID
pada validator. Karena migration utama sudah applied, file tersebut tidak
diedit. Forward migration `20260727100000` menggantinya dengan
`min(id::text)::uuid`; public signature, schema, data, grant, dan flow bisnis
tidak berubah.

Phase-41 Backoffice menambahkan Kategori Pelanggan, Chart of Account, dan
Kategori Transaksi ke tipe Import & Export. Template create tidak menampilkan
kode teknis Customer/Transaction Category; COA tetap memakai kode akun bisnis.
Export memuat `internal_id` untuk update. System-owned rows tetap tampil sebagai
referensi export namun validator menolak mutasinya. Local lint dan production
build PASS; authenticated smoke user masih menunggu.

Prompt handoff siap-copas tersedia pada
`docs/AGENT_CONTINUATION_COPY_PASTE_PROMPT.md`. Prompt tersebut selalu
memerintahkan agent membaca living handoff ini sehingga tidak menjadi basi
setelah fase berganti.

Phase-35 live preflight selesai bersih pada 2026-07-24: seluruh check hanya
`PASS`/`INFO`; 22 tabel dan 12 guarded RPC tersedia; tidak ada duplicate,
ambiguous reference, invalid grouped master, atau nonterminal import job.

User meminta perubahan identitas sebelum migration ekspansi ditulis: Product
dan Customer tetap memiliki kode bisnis user-facing, sedangkan master lain
sebisa mungkin tidak meminta user mengetik kode teknis. UUID existing tetap
menjadi identitas sistem canonical. Kode otomatis harus dibuat server-side,
tenant-scoped, concurrency-safe, dan tidak boleh memakai `MAX(code)+1`.
Keputusan pengecualian kode yang memang bermakna bisnis sudah ditutup user:
Product SKU, Customer code, COA account
code, Tax code, barcode, dan Supplier-owned Product code tetap user-facing.
Delapan master lain menerima kode otomatis server-side untuk row baru; existing
code tidak ditulis ulang. Phase-36 preflight dibuat untuk memeriksa target
column, unique normalized name, prefix inventory, snapshot dependency, dan
nonterminal import job sebelum allocator migration ditulis.

User mengirim hasil Phase-36 bersih: lima invariant `PASS`; 41 legacy code
dipertahankan; tidak ada generated-format row, duplicate name, blank identity,
atau nonterminal import job. Migration applied `20260724010000` menyediakan
atomic counter per Company/entity, reservation untuk explicit code milik import
lama, immutable guard delapan tabel, dan lima overload RPC tanpa parameter
kode. User mengonfirmasi migration, 11-check postflight, dan behavioral test
seluruhnya PASS.

Cutover Backoffice lokal selesai: direct-table create Category/UOM/Warehouse
memakai allocator trigger; Supplier, Customer Category, Pricelist, Payment
Method, dan Transaction Category memakai overload RPC tanpa kode. Form, list,
search, serta dropdown terkait menampilkan nama. Product SKU, Customer code,
COA, Tax, barcode, dan kode Product Supplier tetap user-facing.

User melanjutkan setelah smoke Phase 37, sehingga gate UI automatic-code
dinyatakan aman. Phase 38 lokal memindahkan dependency CSV empat master dari
kolom kode: public validator sekarang menyiapkan stable technical code
server-side sebelum menjalankan private validator Phase 31. Mapping/CSV lama
yang memiliki kode tetap memakai lifecycle/version lama.

Phase 38 juga memperbaiki compatibility validator Gudang: kontrak lama
`^[A-Z]{1,5}$` tetap diterima, dan format allocator baru `WH-000001` kini valid.
Commit Phase 33, partial success, confirmation, optimistic version, audit,
Product/stock exclusion, dan signature API public tidak diubah.

User mengonfirmasi seluruh Phase-38 database gate aman. Phase 39 Backoffice
lokal kini menghapus kode dari template create, export, preview, diff, dan
error download. `internal_id` hanya ada pada export update dan baru ditampilkan
di mapping bila user sengaja memilih mode ID. Gudang memakai `store_name`;
export menulis label `Nama Toko (KODE)`, lalu API menyelesaikan label/nama
unik/kode ke Toko aktif tenant yang sama. Missing/ambiguous reference menjadi
row error dan tidak membuat Toko baru. Lint dan production build PASS.

User meminta Import/Export untuk seluruh item yang dapat dibuat user, bukan
hanya Product Category/UOM/Warehouse/Supplier. Kontrak fixed CSV sudah
ditetapkan untuk Product group, Product-Supplier, Customer Category, Customer,
Pricelist group, Payment Method group, Tax Rule, COA, Transaction Category,
Transaction Account Rule, dan Company Account Fallback.

Referensi template memakai nama/kode bisnis, bukan UUID. Missing/ambiguous
reference menjadi preview error dan tidak boleh auto-create. Product,
Pricelist, serta Payment Method wajib atomic per group. Company, Staff/password,
entitlement, Opening Stock, transaksi, movement, dan journal tetap memakai
workflow khusus dan tidak masuk generic master CSV.

Reusable Customer Pricelist `20260722100000` sudah applied. User mengonfirmasi
migration, 12/12 postflight, behavioral test, dan smoke Customer assignment
aman. Resolver harga serta checkout tetap belum dicutover.

Payment Method preflight diterima bersih dan foundation canonical
`20260722120000` sudah applied. Percobaan pertama rollback pada pending deferred
trigger; ordering diperbaiki, lalu user mengonfirmasi rerun migration, 13/13
postflight, dan behavioral test seluruhnya PASS.

Keputusan terbaru:

- header Pricelist `CUSTOMER` reusable dan tidak dimiliki satu Customer;
- banyak Customer boleh menunjuk Pricelist yang sama;
- dropdown Pricelist dipindahkan ke menu/form Customer;
- satu Customer menunjuk maksimal satu Pricelist khusus; `NULL` memakai Global;
- Walk-In tidak boleh diberi Pricelist khusus;
- migration applied tidak diedit dan checkout/resolver tetap deferred.

Implementasi lokal sudah tersedia: legacy `customer_id` dipertahankan sebagai
kolom kompatibilitas tetapi wajib `NULL`; assignment canonical berada pada
`customers.default_pricelist_id`. Form Pricelist tidak lagi meminta Customer,
sedangkan form Customer menyediakan pilihan Harga Umum atau satu Pricelist
Customer aktif. Satu Pricelist Customer dapat dipakai banyak Customer.

Boundary Payment Method aktif:

- default `Tunai` diprovision per Company aktif;
- master mendukung Store scope, settlement route, proof mode, dan configured
  fee percent/fixed/gabungan;
- Customer Balance/Ketul Offset tidak dapat dibuat lewat generic RPC;
- `sales_payments.payment_method` legacy tetap aktif dan snapshot canonical
  masih nullable;
- foundation menyimpan satu configured fee pada master; effective-dated
  store-specific fee override dan ambiguity resolver tetap wajib dibangun pada
  G4 sebelum checkout cutover;
- checkout, split-payment resolver, offline, settlement, reconciliation, dan
  Finance posting tetap deferred.

Guarded API/UI lokal sekarang tersedia pada menu `Metode Pembayaran`. Form
memakai nama user-facing, mengisi account-function internal otomatis, mendukung
Store scope/proof/settlement/current fee/default/lifecycle, dan dapat ditutup
dengan Escape. Authorization tetap ditegakkan RPC, bukan hanya UI.

User sudah mengonfirmasi smoke menu Metode Pembayaran aman. Phase 15 ditutup
`COMPLETE`. Fase aktif berikutnya mengaudit Transaction Category bersama minimum
COA karena versioned category mapping wajib menunjuk Account ID. Audit ini tidak
mengaktifkan worker/jurnal production dan tidak membuka G6 enforcement.

Live phase-16 preflight diterima bersih: tidak ada Expense, Financial Event,
Journal, blank identity, collision, invalid line, atau unbalanced group. Tiga
Payment Method membawa dua Account Function berbeda dan seluruh function tidak
blank. Satu Company aktif membutuhkan expected minimum COA provisioning.

Foundation lokal menyediakan 37 Account Function, 26 System Event, 36 akun
template per Company, Transaction Category, versioned/effective mapping,
explicit Company fallback storage, posting-exception queue, audit, dan nullable
Event/Journal snapshot. Browser direct write tetap ditutup; guarded RPC hanya
untuk Category dan rule. Worker/resolver/posting masih disabled.

User terakhir menyatakan seluruh menu existing aman tanpa notification error.
Output exact 14-row postflight dan notice behavioral test tidak disalin ulang
pada chat, sehingga handoff tidak boleh mengarang evidence tersebut. Backoffice
lokal kini memiliki menu `Kategori & COA`: Category create/edit dan versioned
mapping memakai guarded RPC; COA masih read-only. Label memakai nama bisnis,
modal dapat ditutup dengan Escape, dan worker/resolver/posting tetap disabled.

Living application README sudah dibuat pada root `README.md`. Root `AGENTS.md`
mewajibkan setiap perubahan material ikut memperbarui README tersebut selain
handoff ini.

File utama phase 17:

- `backoffice/src/lib/finance-master.ts`;
- `backoffice/src/app/api/master/finance-masters/route.ts`;
- `backoffice/src/app/api/master/finance-masters/[id]/route.ts`;
- `backoffice/src/components/FinanceMasterView.tsx`;
- integrasi menu pada `backoffice/src/app/page.tsx`;
- `docs/runbooks/G2_PHASE17_FINANCE_MASTER_API_UI_ROLLOUT.md`;
- root `README.md`, `AGENTS.md`, dan router `docs/README.md`.

User kemudian mengonfirmasi missing-table state sudah aman dan meminta kategori
transaksi wajib agar non-Finance dapat belajar serta menjelaskannya. Phase 18
menyediakan 26 kategori bawaan per Company. Nama/kode/keterangan dapat
disesuaikan, tetapi event, status aktif, dan keberadaannya dilindungi. Custom
category seperti Listrik/Bensin/ATK tetap didukung. Provisioning tidak membuat
Account Rule, fallback, Financial Event, atau Journal.

Live phase-18 preflight diterima `PASS`: dependency phase 16 ada, seluruh 26
System Event tersedia, tidak ada collision kode/nama, dan satu kategori existing
tidak menghalangi rollout. Satu Company aktif akan menerima tepat 26 row bawaan.
Migration kemudian applied dan seluruh data invariant sebenarnya PASS. Run
postflight pertama menunjukkan dua false-negative karena expected count trigger
dan routine tertukar: live menemukan 2 trigger dan 3 routine, tepat sesuai DDL.
Diagnostic diperbaiki; migration tidak perlu dan tidak boleh dijalankan ulang.
Behavioral test berikutnya menemukan bug lama phase 16: shared history trigger
membaca `NEW.account_type` pada record Category. Forward migration phase 19
memisahkan akses field setelah cabang `TG_TABLE_NAME`. File baru mencakup
migration, 5-check postflight, regression test, dan rollout runbook; tidak ada
business data atau Finance posting yang diubah.
User mengonfirmasi phase-19 migration, seluruh 5 postflight, regression test,
dan rerun phase-18 test PASS. Required categories dan trigger fix ditutup.
Next audit hanya SELECT-only untuk mengukur COA hierarchy, history lock,
compatible account candidate, serta required function yang belum memiliki
Transaction Rule/explicit Company fallback.

Live phase-20 preflight sudah diterima tanpa `BLOCKER`. Satu override saldo
normal adalah akun kontra yang valid. Sebanyak 33 category-function pada 24
kategori belum mempunyai rule/fallback dan harus diselesaikan eksplisit; sistem
tidak melakukan auto-mapping ke akun tebakan. Implementasi lokal menyediakan
guarded hierarchical COA RPC, explicit versioned Company fallback, audit,
concurrency serialization, postflight/test, API, serta tab UI Daftar Akun dan
Fallback Company. Label UI memakai nama fungsi/akun, warning contra balance
ditampilkan, dan Escape menutup modal. Finance resolver/posting tetap off.

File utama phase 20:

- `supabase/migrations/20260722230000_g2_phase20_guarded_coa_fallback.sql`;
- `supabase/diagnostics/g2_phase20_guarded_coa_fallback_postflight.sql`;
- `supabase/tests/g2_phase20_guarded_coa_fallback_tests.sql`;
- `backoffice/src/lib/finance-master.ts`;
- `backoffice/src/app/api/master/finance-masters/route.ts`;
- `backoffice/src/app/api/master/finance-masters/accounts/[id]/route.ts`;
- `backoffice/src/components/FinanceMasterView.tsx`;
- `docs/runbooks/G2_PHASE20_GUARDED_COA_FALLBACK_ROLLOUT.md`.

User kemudian mengonfirmasi seluruh phase-20 rollout dan UI smoke `all good`.
Phase 20 ditutup `COMPLETE`. Fase berikutnya adalah Tax master karena masih
merupakan deliverable G2 dan menjadi dependency Product/Category, Sales,
Purchase, serta Finance. Preflight phase 21 hanya mengaudit dua entitlement
independen, akun INPUT/OUTPUT TAX, histori transaksi, assignment nullable, dan
snapshot gap. Tidak ada entitlement, Tax Rule, kalkulasi, checkout, atau journal
yang diaktifkan.

File phase-21 saat ini:

- `supabase/diagnostics/g2_phase21_tax_master_preflight.sql`;
- `docs/runbooks/G2_PHASE21_TAX_MASTER_PREFLIGHT.md`.

User mengonfirmasi phase-21 hanya menghasilkan `PASS` dan `INFO`. Tidak ada
blocker, review, atau histori yang membutuhkan keputusan bisnis. Foundation
phase 22 lokal menyediakan identitas Tax stabil, configuration version
effective-dated, entitlement guard per scope, nullable Product/Category
assignment, nullable Sales/Purchase snapshot, audit, RLS, dan guarded RPC.
Tidak ada entitlement/rate default yang diprovision dan tidak ada kalkulasi,
resolver, checkout, Supplier Invoice Tax, return/reversal, atau journal.

File utama phase 22:

- `supabase/migrations/20260723010000_g2_phase22_tax_master_foundation.sql`;
- `supabase/diagnostics/g2_phase22_tax_master_foundation_postflight.sql`;
- `supabase/tests/g2_phase22_tax_master_foundation_tests.sql`;
- `docs/runbooks/G2_PHASE22_TAX_MASTER_FOUNDATION_ROLLOUT.md`;
- update manifest, root README, router, dan handoff.

File utama phase 18:

- `supabase/diagnostics/g2_phase18_required_transaction_categories_preflight.sql`;
- `supabase/migrations/20260722180000_g2_phase18_required_transaction_categories.sql`;
- `supabase/diagnostics/g2_phase18_required_transaction_categories_postflight.sql`;
- `supabase/tests/g2_phase18_required_transaction_categories_tests.sql`;
- `docs/FINANCE_TRANSACTION_CATEGORY_USER_GUIDE.md`;
- `docs/runbooks/G2_PHASE18_REQUIRED_TRANSACTION_CATEGORIES_ROLLOUT.md`;
- update API/UI Finance Master, manifest, README, spec decision log, dan router.

## 4. Source of Truth per Development

### Aturan umum dan urutan gate

- `docs/POS_V1_MVP_REQUIREMENT_INDEX.md`
- `docs/POS_V1_IMPLEMENTATION_GATES.md`
- `docs/AI_AGENT_CONTINUATION_PLAYBOOK.md`
- `docs/PRE_BUILD_IMPLEMENTATION_GAP_AUDIT_2026-07-20.md`

### G2 Master Data

- Product/Category/Warehouse/Supplier:
  `docs/PRODUCT_STOCK_MASTERDATA_SPEC.md`
- UOM/weight/valuation: `docs/UOM_WEIGHT_VALUATION_SPEC.md`
- Customer/Walk-In/credit boundary:
  `docs/SALES_CUSTOMER_MASTERDATA_SPEC.md`
- Pricelist: `docs/SALES_PRICELIST_NOTES.md`
- Payment Method: `docs/PAYMENT_METHOD_MASTERDATA_SPEC.md`
- Transaction Category: `docs/TRANSACTION_CATEGORY_ACCOUNT_MAPPING_SPEC.md`
- Tax: `docs/TAX_ENGINE_SPEC.md`
- COA minimum: `docs/FINANCE_CORE_ACCOUNTING_SPEC.md`
- import framework: G2 section pada implementation gates dan gap `B-04`.

### G3 Stock Ledger

- `docs/PRODUCT_STOCK_MASTERDATA_SPEC.md`
- `docs/UOM_WEIGHT_VALUATION_SPEC.md`
- G3 section `docs/POS_V1_IMPLEMENTATION_GATES.md`
- gap `B-02` dan Inventory matrix pada pre-build audit.

Jangan masuk G4/G5 sebelum atomic stock ledger, FIFO, idempotency, nonnegative
concurrency, dan source document contract G3 stabil.

### G4 POS/Checkout/Offline

- `docs/POS_DEVELOPMENT_NOTES.md`
- Product/UOM/stock spec
- Payment Method, Tax, Pricelist, Customer, Expense, Deposit, dan evidence-link
  specs yang dirujuk requirement index.

### G5 Purchasing

- `docs/PRODUCT_STOCK_MASTERDATA_SPEC.md` bagian 9.4;
- `docs/POS_DEVELOPMENT_NOTES.md` bagian Stock Request/Goods Receipt;
- `docs/PURCHASE_MATCHING_TOLERANCE_SPEC.md`;
- `docs/DEBIT_CREDIT_NOTE_SPEC.md` untuk Return Supplier.

Flow wajib: `Stock Request → Supplier Order → Goods Receipt → Supplier Invoice → Payment`.
Supplier Order tidak membuat stock/AP; hanya Goods Receipt posted yang dapat
membentuk stock/FIFO/AP provisional.

### G6 Finance

- `docs/FINANCE_INTEGRATION_NOTES.md`
- `docs/FINANCE_CORE_ACCOUNTING_SPEC.md`
- `docs/FINANCE_REPORTING_AND_CUTOFF_SPEC.md`
- Transaction Category, Tax, matching, note, collection, Expense, Deposit specs.

## 5. Manual Gate Terakhir

Database Phase 40 tidak perlu dijalankan ulang. Manual gate sekarang adalah
authenticated Backoffice smoke Phase 41:

1. restart Backoffice dan buka **Import & Export** sebagai Owner/Admin;
2. cek template dan export Kategori Pelanggan, Chart of Account, dan Kategori
   Transaksi;
3. preview/commit satu row custom tiap tipe;
4. untuk COA child, letakkan parent pada baris sebelumnya;
5. uji update memakai `internal_id` dari export;
6. pastikan system-owned row ditolak di preview tanpa menggagalkan row custom;
7. ulangi satu smoke salah satu dari empat tipe lama.

Detail expected ada di
`docs/runbooks/G2_PHASE41_REMAINING_SIMPLE_MASTER_IMPORT_UI.md`.

File Pricelist yang sudah ditutup:

- `backoffice/src/lib/pricelist-master.ts`;
- `backoffice/src/app/api/master/pricelists/route.ts`;
- `backoffice/src/app/api/master/pricelists/[id]/route.ts`;
- `backoffice/src/components/PricelistMasterView.tsx`;
- integrasi menu pada `backoffice/src/app/page.tsx`;
- `docs/runbooks/G2_PHASE13_PRICELIST_API_UI_ROLLOUT.md`.

Evidence: Backoffice lint PASS, production build PASS, dan authenticated user
smoke diterima. API menggabungkan header/assignment/rule dari query terpisah
sehingga tidak bergantung pada nested PostgREST relationship.

Review final menemukan exact-one default Global belum sepenuhnya enforced.
Forward-only gate berikut sudah applied dan dikonfirmasi PASS:

- `supabase/migrations/20260722080000_g2_phase13_pricelist_default_guard.sql`;
- `supabase/diagnostics/g2_phase13_pricelist_default_guard_postflight.sql`;
- `supabase/tests/g2_phase13_pricelist_default_guard_tests.sql`;
- `docs/runbooks/G2_PHASE13_PRICELIST_DEFAULT_GUARD_ROLLOUT.md`.

Checksum migration `f4ce694...`; 6 postflight dan behavioral test PASS.
Forward fix memungkinkan perpindahan default secara atomic dan mengaudit
default lama. UX terbaru memakai harga akhir langsung: harga normal Rp5.000
menjadi Rp4.000 diisi `4000`; potongan per UOM hanya untuk tier Global.

## 6. Next Safe Step

Tunggu authenticated smoke Phase 41. Setelah aman, tandai UI tujuh simple
master `COMPLETE`. Jangan memulai grouped Product/Pricelist/Payment Method
sebelum UI simple-master tersebut ditutup.

Jangan mengubah migration Phase 30–33 yang sudah applied; explicit-code CSV
lama tetap compatibility surface selama transisi.
Opening Stock tetap menunggu G3 dan Product Brand menunggu canonical master.
Permission granular per-user/submodule tetap follow-up access-control terpisah.
Jangan mengaktifkan resolver, checkout calculation, journal, e-Faktur, atau
official tax reporting.

UX follow-up wajib Customer: tambahkan dropdown `Customer induk` langsung pada
modal Edit Customer. Saat ini grouping tersedia pada panel terpisah dan tombol
baru aktif setelah minimal dua Customer non-sistem tersedia.

## 7. Update Log

| Tanggal | Agent/Turn | Perubahan | Evidence | Next gate |
|---|---|---|---|---|
| 2026-07-21 | Codex — G2 Supplier/Customer handoff | Supplier API/UI complete; label UOM memakai nama; Customer preflight clean; dokumen handoff dibuat | Backoffice lint/build PASS; live Customer preflight dari user | Customer foundation manual DB rollout |
| 2026-07-21 | Codex — G2 Customer foundation | Migration `20260722010000`, postflight, behavioral test, manifest, dan rollout runbook dibuat | Checksum manifest cocok; 13 postflight checks; `current_balance` bukan parameter RPC; `git diff --check` bersih; manual Supabase gate belum dijalankan | Jalankan migration → 13 PASS postflight → behavioral test |
| 2026-07-21 | Codex — G2 Customer API/UI | Database gate ditandai complete; API Customer/Category guarded dan UI dua tab dibuat; saldo read-only, Walk-In immutable | User: migration + 13 postflight + behavioral test PASS; Backoffice lint dan production build PASS | Restart Backoffice dan jalankan smoke fase 9 |
| 2026-07-21 | Codex — G2 Customer grouping/UX | Nama UOM user-facing, Escape modal, Customer parent satu tingkat, uniqueness UOM/Warehouse, pre/postflight/test/runbook | Backoffice lint/build PASS; migration checksum recorded; manual DB gate belum dijalankan | Jalankan dan kirim hasil preflight fase 10 |
| 2026-07-21 | Codex — G2 phase 10 preflight result | Preflight ditandai PASS; schema-cache error dikonfirmasi sebagai state sebelum FK migration | User menyatakan seluruh preflight PASS | Jalankan migration `20260722040000` → postflight → behavioral test |
| 2026-07-21 | Codex — G2 phase 10 self-embed fix | Nested PostgREST Customer self-join dihapus; grouping memakai `parent_customer_id` dari list tenant yang sama | User: migration/postflight/test PASS; Backoffice lint/build PASS | Restart dan ulang smoke menu Pelanggan |
| 2026-07-21 | Codex — G2 phase 11 Pricelist preflight | Customer menu smoke dinyatakan baik; empty-state grouping diperjelas; Pricelist SELECT-only preflight/runbook dibuat | Phase-10 DB gates PASS; Customer menu opens; Backoffice lint/build PASS; no Pricelist mutation | Jalankan dan kirim seluruh hasil Pricelist preflight |
| 2026-07-21 | Codex — G2 phase 12 Pricelist foundation | Global/Customer Pricelist, Store assignment, exact Product-UOM rule, immutable rule history, audit, guarded RPC, RLS, default Global backfill, dan nullable Sales pricing snapshot disiapkan | User phase-11 preflight: no blocker dan zero Sales history; checksum `e4ff626...`; 12 postflight checks; `git diff --check` clean; DB execution pending | Migration → 12 PASS postflight → behavioral test → compatibility smoke |
| 2026-07-21 | Codex — G2 phase 13 Pricelist API/UI | Database gate ditutup; guarded API, validation, menu/list/form Pricelist, Store scope, Customer scope, Global tier, dan nama UOM user-facing dibuat | User: migration + 12 postflight + behavioral test PASS; Backoffice lint/build PASS | Restart Backoffice dan jalankan smoke phase 13 |
| 2026-07-21 | Codex — G2 phase 13 default invariant review | Review menemukan default terakhir masih dapat dinonaktifkan; forward guard, atomic default handover + audit, postflight, dan test disiapkan tanpa mengedit migration applied | Phase-12 DB PASS; Phase-13 UI lint/build PASS; forward SQL execution pending | Jalankan `20260722080000` → 6 PASS → behavioral test → UI smoke |
| 2026-07-21 | Codex — G2 phase 13 direct final price UX | Default guard ditutup; form Pricelist diubah agar harga biasa diisi sebagai harga akhir, sementara potongan per UOM hanya tersedia pada quantity tier Global | User: forward migration + 6 postflight + test PASS; Backoffice lint/build PASS | Restart Backoffice dan smoke create/edit Pricelist |
| 2026-07-21 | Codex — G2 phase 14 Payment Method preflight | Pricelist UI smoke ditutup COMPLETE; SELECT-only Payment Method audit dan runbook dibuat tanpa mengubah checkout | User menyatakan Pricelist oke; SQL/docs only; local syntax/diff verification | Jalankan dan kirim seluruh hasil Payment Method preflight |
| 2026-07-22 | Codex — reusable Customer Pricelist correction | Payment preflight diterima bersih; keputusan Pricelist diubah menjadi reusable dan assignment dipindahkan ke Customer; preflight forward-fix dibuat | Payment: no blocker/history, satu expected default backfill; SQL correction masih SELECT-only | Jalankan dan kirim hasil reusable Customer Pricelist preflight |
| 2026-07-22 | Codex — reusable Customer Pricelist implementation | Preflight reusable PASS; forward migration, postflight, behavioral test, guarded RPC, API, dan dropdown Pricelist pada form Customer dibuat; Customer picker di Pricelist dihapus | Preflight live seluruh invariant PASS; lint PASS; production build PASS; `git diff --check` bersih; checksum migration cocok manifest | Migration `20260722100000` → 12 PASS → behavioral test → Customer/Pricelist smoke |
| 2026-07-22 | Codex — G2 phase 14 Payment Method foundation | Reusable Pricelist gate ditutup COMPLETE; Payment Method master, Store assignment, fee validation, default Tunai, audit/versioning, history/default guards, nullable payment snapshot, RLS/RPC, postflight/test/runbook dibuat | User: reusable Pricelist all pass; Payment preflight zero history/no blocker; migration checksum manifest cocok; 13 postflight checks; local static verification | Migration `20260722120000` → 13 PASS → behavioral test → compatibility smoke |
| 2026-07-22 | Codex — G2 phase 14 pending-trigger fix | Rollout pertama gagal dan rollback pada PostgreSQL `55006` karena default backfill meninggalkan deferred trigger event sebelum `ALTER TABLE ... ENABLE RLS`; migration mem-flush constraint event sebelum DDL berikutnya | Root cause cocok dengan urutan SQL; migration tetap unapplied karena satu transaction; checksum baru `5015d6c...`; `git diff --check` bersih | Rerun seluruh migration terbaru → 13 PASS → behavioral test |
| 2026-07-22 | Codex — G2 phase 15 Payment Method API/UI | Fixed DB gate ditutup COMPLETE; guarded GET/POST/PATCH, server validation, menu/list/form user-facing, Store scope, settlement, proof, fee, default, dan Escape modal dibuat tanpa checkout cutover | User: migration + 13 postflight + behavioral test PASS; Backoffice lint/build PASS | Restart dan smoke menu Metode Pembayaran sesuai runbook fase 15 |
| 2026-07-22 | Codex — G2 phase 16 Finance master preflight | Payment Method UI smoke ditutup COMPLETE; SELECT-only Transaction Category + minimum COA readiness audit dan runbook dibuat tanpa mengaktifkan Finance posting | User menyatakan Payment Method aman; 18 aggregate checks; mutation statement scan 0; `git diff --check` bersih | Jalankan dan kirim seluruh hasil phase-16 preflight |
| 2026-07-22 | Codex — G2 phase 16 Finance master foundation | Preflight live bersih; registry, minimum tenant COA, Category/versioned rule, fallback storage, exception queue, audit, nullable snapshots, RLS/RPC, postflight/test/runbook dibuat | 37 functions; 26 events; 36 COA template; 14 postflight checks; checksum `6b4f39b...`; manual DB execution pending | Migration → 14 PASS → behavioral test → compatibility smoke |
| 2026-07-22 | Codex — G2 phase 17 Finance master UI + living README | Root README dan maintenance rule dibuat; guarded Finance API/UI serta menu Kategori & COA ditambahkan; COA read-only dan posting tetap disabled | User: existing menu compatibility smoke aman; Backoffice lint PASS; production build PASS; route Finance master terdeteksi | Restart dan authenticated smoke menu Kategori & COA |
| 2026-07-22 | Codex — G2 phase 18 required Transaction Categories | 26 default categories, future-Company provisioning, immutable event/active/delete guard, pre/postflight/test, learning UI, user guide, runbook, manifest, dan living README dibuat | Live preflight PASS: one Company/26 backfill, one existing category, zero collision/missing event; lint/build PASS | Migration `20260722180000` → 11 PASS → behavioral test → UI smoke |
| 2026-07-22 | Codex — phase 18 postflight expected-count fix | Menukar expected count diagnostic ke nilai DDL yang benar: 2 trigger dan 3 private routine; migration/data tidak diubah | User result membuktikan actual `trigger_rows=2`, `routine_rows=3`; sembilan invariant lain PASS | Rerun postflight terbaru, lalu behavioral test |
| 2026-07-22 | Codex — phase 19 Finance history trigger fix | Root cause PostgreSQL 42703 diperbaiki lewat forward migration dengan table-first branch; postflight/regression test/runbook/manifest dibuat | Phase-18 fixture rollback; error stack membuktikan `NEW.account_type` dibaca pada Category record; checksum `5a713c7...`; static checks clean | Migration `20260722210000` → 5 PASS → phase-19 test → rerun phase-18 test |
| 2026-07-22 | Codex — G2 phase 20 COA/fallback preflight | Phase 18/19 ditutup COMPLETE; SELECT-only audit COA identity/hierarchy/history, compatible candidate, rule/fallback integrity, unresolved required function, RPC state, dan privilege dibuat | User: phase-19 migration + 5 postflight + regression + phase-18 rerun all PASS; diagnostic mutation scan pending | Jalankan dan kirim seluruh hasil phase-20 preflight |
| 2026-07-22 | Codex — G2 phase 20 guarded COA/fallback | Preflight diterima; guarded hierarchical COA, versioned Company fallback, audit/concurrency guard, postflight/test, API/UI, docs, dan manifest dibuat | Live: no blocker, 36 accounts, one valid contra review, 33 explicit resolution backfills; Backoffice lint/build PASS; DB execution pending | Migration `20260722230000` → 8 PASS → behavioral test → UI smoke |
| 2026-07-22 | Codex — G2 phase 21 Tax preflight | Phase 20 ditutup COMPLETE; SELECT-only audit entitlement independen, Tax COA, Product/Category assignment, history, snapshots, dan privileges dibuat | User: phase-20 full rollout/UI smoke all good; Tax diagnostic mutation scan local | Jalankan dan kirim seluruh hasil phase-21 preflight |
| 2026-07-22 | Codex — G2 phase 22 Tax foundation | Preflight Tax ditutup; effective-dated Tax master, entitlement/account/scope guard, nullable assignments/snapshots, audit/RLS/RPC, 14 postflight, test, runbook, dan manifest dibuat | User: phase-21 PASS/INFO only; static transaction/checksum/diff verification; DB execution pending | Migration `20260723010000` → 14 PASS → behavioral test → compatibility smoke |
| 2026-07-22 | Codex — G2 phase 23 Tax Master API/UI | Phase-22 DB gate ditutup COMPLETE; guarded GET/POST/PATCH, server validation, entitlement-aware list/form, effective versioning, akun user-facing, dan Escape modal dibuat | User: phase-22 all pass; Backoffice lint/build PASS; Tax routes terdeteksi | Restart dan smoke menu Aturan Pajak; assignment Product/Category tetap deferred |
| 2026-07-22 | Codex — G2 phase 24 Module Settings API/UI | Super Admin-only Settings per active Company dibuat dari katalog feature existing; toggle via audited `set_company_feature`, config existing dipertahankan, confirmation/Escape tersedia | Backoffice lint/build PASS; dynamic Settings API route terdeteksi; no schema migration | Combined smoke Settings + Aturan Pajak, lalu guarded Product/Category Tax assignment |
| 2026-07-22 | Codex — G2 phase 25 role-aware app shell | Dashboard diganti module launcher; Inventory/Sales/Finance/Team/Platform mengelompokkan submodule sesuai role; sidebar menjadi floating fast link, collapsible, scrollable, dan tidak mendorong content | Backoffice lint/build PASS; browser automation lokal tidak tersedia, authenticated visual smoke pending user | Smoke shell lintas ukuran/role; lanjut Tax assignment; granular user permission tetap fase terpisah |
| 2026-07-22 | Codex — phase 25 Contacts regrouping | Supplier dipindahkan keluar Inventory; Pelanggan, Supplier, dan User & Akses disatukan dalam Kontak; User & Akses tetap Company Admin/Owner/Super Admin only; Sales menjadi Sales & Pricing | UI-only regrouping; canonical API/RLS role boundary tidak diperluas | Rerun lint/build dan smoke launcher |
| 2026-07-22 | Codex — phase 25 Sales/Finance regrouping | Sales difokuskan pada Pricelist dan future Promo/Bundling; Metode Pembayaran serta Aturan Pajak dipindahkan ke Finance bersama Kategori/COA/Jurnal | UI-only regrouping; tidak membuat placeholder atau membuka deferred module | Rerun lint/build dan smoke launcher |
| 2026-07-22 | Codex — G2 phase 26 Tax assignment preflight | Shell/Settings/Tax Master ditutup pada boundary saat ini; SELECT-only audit entitlement, current Tax version, Category/Product assignment, redundant override, RPC state, dan direct write dibuat | SQL aggregate-only; no schema/data mutation; manual Supabase result pending | Jalankan preflight dan kirim seluruh hasil |
| 2026-07-22 | Codex — G2 phase 26 guarded Tax assignment | Preflight live ditutup PASS; effective-version/entitlement trigger diperkuat, Category/Product optimistic assignment RPC, audit, Category column write closure, dan atomic Product-UOM-Tax overload dibuat | Migration checksum manifest cocok; postflight/test/static checks local ready; manual DB execution pending | Migration `20260723040000` → all-PASS postflight → behavioral test |
| 2026-07-22 | Codex — G2 phase 27 Tax assignment API/UI | Phase-26 DB ditutup all pass; endpoint Tax options, guarded Category assignment, Category default UI, Product inheritance/override atomic, entitlement visibility, dan user-facing Tax names dibuat | Backoffice lint PASS; production build PASS; dynamic routes terdeteksi; browser visual automation tidak tersambung pada sesi ini | Restart dan authenticated smoke sesuai runbook phase 27 |
| 2026-07-22 | Codex — Home brand + G2 phase 28 preflight | User menutup Tax assignment smoke sebagai aman; brand KGS POS dijadikan tombol Home; SELECT-only audit resolver/snapshot dibuat tanpa mengaktifkan kalkulasi | Backoffice lint PASS; production build PASS; forbidden SQL mutation 0; `git diff --check` bersih; browser session tidak tersambung; manual Supabase result pending | Smoke brand Home, lalu jalankan phase-28 preflight dan kirim seluruh hasil |
| 2026-07-22 | Codex — G2 phase 28 private Tax resolver/calculator | Live preflight ditutup bersih; private effective-dated resolver dan deterministic IDR PER_LINE/PER_DOCUMENT calculator dibuat tanpa transaction cutover | User preflight: all invariant PASS, zero history/rule, checkout untouched; migration/postflight/test static verification local | Migration `20260723070000` → 7 PASS → behavioral test |
| 2026-07-22 | Codex — G2 phase 29 Import preflight | Phase-28 DB gate ditutup all pass; SELECT-only audit import legacy, ambiguity master, Product-UOM group, protected history, dan Opening Stock eligibility dibuat | User: phase-28 migration/postflight/test all pass; diagnostic aggregate-only, no stock/master mutation | Jalankan phase-29 preflight dan kirim seluruh hasil |
| 2026-07-22 | Codex — G2 phase 30 Import staging foundation | Preflight live bersih selain expected legacy REVIEW; tenant-scoped idempotent job/row/event staging, guarded upload/mapping RPC, RLS, audit, dan legacy quarantine dibuat | Live: zero duplicate/history, canonical Product-UOM PASS, 3 Opening-eligible pair; checksum/11-check/test static local | Migration `20260723100000` → 11 PASS → behavioral test |
| 2026-07-22 | Codex — G2 phase 31 Import identity validator | Phase-30 user rollout ditutup all PASS; validator dry-run tenant-safe untuk Category/UOM/Warehouse/Supplier, diff/warning, duplicate-file, partial row error, retry, postflight/test/runbook dibuat | Checksum manifest, 8 postflight checks, behavioral test static local; manual Supabase pending | Migration `20260723130000` → 8 PASS → behavioral test |
| 2026-07-22 | Codex — G2 phase 32 Import business validator | Phase-31 user rollout ditutup all PASS; forward trigger memperkaya preview UOM/Gudang/Supplier/Kategori sesuai manual CRUD tanpa commit | Checksum manifest, 7 postflight checks, four-master rollback test static local; manual Supabase pending | Migration `20260723160000` → 7 PASS → behavioral test |
| 2026-07-22 | Codex — G2 phase 33 Import partial commit | Phase-32 user rollout ditutup all PASS; guarded commit empat master memakai update confirmation, matched version, partial row subtransaction, audit, terminal retry, dan Product/stock exclusion | User mengonfirmasi migration, 9-check postflight, dan behavioral test seluruhnya PASS | Phase 34 API/UI |
| 2026-07-22 | Codex — G2 phase 34 Import API/UI | Owner/Admin API dan UI CSV untuk Category/UOM/Warehouse/Supplier: template/export, mapping, preview, exact update confirmation, partial result, error download, dan history | Backoffice lint PASS; production build PASS; tiga route terdeteksi; browser visual session tidak tersambung | Restart dan authenticated smoke sesuai runbook Phase 34 |
| 2026-07-23 | Codex — G2 phase 35 full Import/Export preflight | Inventaris seluruh master user-creatable, kontrak CSV fixed/versioned, dependency order, atomic groups, dan SELECT-only readiness audit | Static SQL safety review; dokumentasi contract/runbook/handoff diperbarui; manual Supabase result menunggu | Jalankan Phase-35 preflight dan kirim output lengkap |
| 2026-07-24 | Codex — Phase-35 live result + automatic-code design | Preflight ditutup bersih; UUID dikonfirmasi tetap canonical; user meminta kode teknis selain Product/Customer dihasilkan sistem | User output: seluruh 15 check PASS/INFO, 22 tabel, 12 RPC, zero ambiguity/invalid/nonterminal job | Tutup pengecualian COA/Tax business code lalu buat allocator additive |
| 2026-07-24 | Codex — Phase-36 automatic code preflight | Keputusan hybrid disetujui; delapan target master, prefix, immutable/new-row-only rule, fixed create/update CSV, diagnostic, runbook, README, gate, dan handoff diperbarui | Diagnostic SELECT-only; local static verification pending; manual Supabase result pending | Jalankan Phase-36 preflight dan kirim output lengkap |
| 2026-07-24 | Codex — Phase-36 automatic code foundation | Live preflight ditutup; private atomic counter/reservation, eight-table immutable trigger, five guarded overload, postflight/test/runbook/manifest dibuat tanpa UI cutover | User preflight: all PASS/INFO, 41 legacy preserved, zero job; migration checksum recorded; static verification local | Migration `20260724010000` → 11 PASS → behavioral test |
| 2026-07-24 | Codex — Phase-37 automatic code UI cutover | Database Phase 36 ditutup all PASS; delapan form/list/search dipindahkan ke nama dan API code-less; pengecualian kode bisnis tetap terlihat | User: Phase-36 migration/postflight/test all PASS; Backoffice lint/build PASS; CSV explicit-code lama sengaja dipertahankan | Restart dan authenticated smoke Phase 37, lalu full-import expansion |
| 2026-07-24 | Codex — Phase-38 code-less simple master import | Phase-37 smoke ditutup; public validator wrapper menyiapkan stable server code untuk empat master tanpa mengubah Phase 31/33 applied; validator Gudang menerima `WH-000001`; postflight/test/runbook/manifest dibuat | SQL transaction/delimiter checks dan `git diff --check` PASS; checksum `840a1a50...`; manual Supabase belum dijalankan | Migration `20260724040000` → 7 PASS → behavioral test |
| 2026-07-24 | Codex — Phase-39 code-less Import UI | Phase-38 DB ditutup all good; template create/export/preview empat master menyembunyikan kode; Warehouse Store reference memakai label/nama/kode user-facing dan server tenant resolution | User: Phase-38 all good; Backoffice lint PASS; production build PASS; dynamic Import routes terdeteksi | Restart dan authenticated smoke Phase 39 |
| 2026-07-27 | Codex — Phase-40 simple master import preflight + copy-paste handoff | Phase-39 smoke ditutup COMPLETE; prompt agent pengganti dan SELECT-only audit Customer Category/COA/Transaction Category dibuat | User menyatakan seluruh smoke aman; Phase-40 SQL/docs static verification lokal | Jalankan Phase-40 preflight dan kirim output lengkap |
| 2026-07-27 | Codex — Phase-40 remaining simple master import database gate | Preflight ditutup bersih; additive job type, validator, guarded partial commit, system-row protection, postflight/test/runbook/manifest dibuat | User preflight seluruh invariant PASS; SQL delimiter/parenthesis/diff checks local; Supabase rollout pending | Migration `20260727090000` → 10 PASS → behavioral test → Phase-38 regression |
| 2026-07-27 | Codex — Phase-40 COA UUID aggregate forward fix | Applied migration dipertahankan immutable; unsupported `min(uuid)` diganti secara forward-only menjadi `min(id::text)::uuid` | User error PostgreSQL 42883 tepat pada parent lookup; forward migration/postflight static-ready | Migration `20260727100000` → 4 PASS → rerun Phase-40 test → Phase-38 regression |
| 2026-07-27 | Codex — Phase-41 remaining simple master Import UI | Customer Category, COA, dan Transaction Category ditambahkan ke template/export/mapping/preview; system rows dijelaskan export-only | User menutup Phase-40 DB all success; Backoffice lint/build PASS | Authenticated smoke sesuai runbook Phase 41 |
| 2026-07-27 | Codex — Phase-40 forward-fix diagnostic correction | Postflight diubah dari full function-definition pattern menjadi direct `pg_proc.prosrc` inspection tanpa menjalankan validator | User reached step 2 and reported relation `v_parent_id`; forward migration treated applied | Rerun latest 4-check postflight only, then both behavioral tests |
