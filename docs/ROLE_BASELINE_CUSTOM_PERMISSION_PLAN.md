# Role Baseline dan Custom Permission Plan

**Status:** APPROVED PLAN — DOCUMENTATION ONLY  
**Tanggal keputusan:** 2026-08-12  
**Gate:** ACP-0 sebelum PRD-1 full role/multi-Company regression  
**Runtime saat ini:** ACP foundation aktif; sembilan Inventory key,
`contacts.customers`, dan `contacts.suppliers` user-confirmed ENFORCED.
ACP-5C `purchase.supplier_orders` dan ACP-5D `purchase.purchase_returns`
database, postflight, behavior, dan regression sudah user-confirmed PASS serta
runtime database ENFORCED; authenticated preset/two-Company smoke masih
pending. ACP-5E `sales.sales_documents` dan ACP-5F `sales.pricelists` database,
postflight, behavior, dan regression sudah user-confirmed PASS serta runtime
database ENFORCED. ACP-5G `sales.bundles` database, postflight, behavior, dan
regression sudah user-confirmed PASS serta runtime database ENFORCED. Live
ACP-5H database, postflight, behavior, dan regression sudah user-confirmed PASS;
seluruh ACP-5 sekarang database-live ENFORCED. ACP-6A Expense juga sudah
user-confirmed database-live ENFORCED. ACP-6B Cash Deposit database, behavior,
dan regression juga user-confirmed PASS; authenticated smoke ditunda ke closing
UAT. ACP-6C Deposit Variance database, postflight, behavior, dan regression
user-confirmed PASS; smoke ditunda ke closing UAT. ACP-6D Customer Balance
dibuka hanya sebagai SELECT-only preflight. Finance key setelahnya tetap
SHADOW.

## 1. Outcome yang Disetujui

KGS POS tetap memakai role Company yang sudah ada sebagai baseline sekaligus
batas maksimum akses. Pada detail satu user di Company aktif, Company Admin ke
atas dapat menambahkan pembatasan opsional per submodul. Pembatasan ini dibuat
untuk kasus seperti Warehouse Admin yang boleh melihat Stock Real dan membuat
Transfer, tetapi tidak boleh melihat report atau mem-posting Adjustment.

Custom permission **tidak pernah** menaikkan hak di atas role. Jika tidak ada
override, perilaku user harus sama persis dengan runtime sebelum fitur ini
dibangun. Karena itu rollout tidak melakukan backfill satu row per user.

Keputusan ini mengambil pola UX aplikasi ERP per-user sebagai referensi, tetapi
tidak menyalin mesin access group/model/record-rule generik. Source referensi:

- <https://www.odoo.com/documentation/14.0/applications/general/users/manage_users.html>;
- <https://www.odoo.com/documentation/14.0/applications/general/users/access_rights.html>;
- <https://www.odoo.com/documentation/14.0/developer/tutorials/restrict_data_access.html>.

## 2. Kontrak Authority

Effective access untuk sebuah aksi harus memenuhi seluruh kondisi berikut:

```text
membership Company aktif
AND feature/entitlement Company aktif
AND role baseline mengizinkan aksi
AND custom restriction tidak menurunkan aksi tersebut
AND Store/Warehouse/Terminal scope cocok
AND status/lifecycle workflow mengizinkan aksi
```

Aturan precedence wajib:

1. feature `OFF` selalu menang;
2. membership tidak aktif selalu menolak;
3. role baseline adalah batas maksimum;
4. custom permission hanya boleh mempertahankan atau mengurangi baseline;
5. Store/Warehouse/Terminal assignment tetap mempersempit record scope;
6. workflow maker-checker, immutable history, dan final-state guard tetap menang;
7. key/aksi yang tidak dikenal harus `DENY`, bukan fallback allow;
8. menyembunyikan menu bukan authorization—direct URL, API, RPC, dan write path
   tetap harus ditolak server-side.

Super Admin lintas Company tetap menggunakan Company context ketika mengubah
permission user. Tidak boleh ada override global tanpa `company_id`.

## 3. Preset Sederhana untuk User

UI v1 hanya menampilkan empat preset. Preset diterjemahkan menjadi capability
server, bukan menjadi boolean menu semata.

| Preset | Makna | Capability maksimum yang tersisa |
|---|---|---|
| `IKUTI_ROLE` | Tidak ada pembatasan tambahan | Seluruh capability baseline role |
| `LIHAT_SAJA` | Boleh membuka list/detail/report | `VIEW`, tanpa create/edit/review/post/export/import |
| `OPERASIONAL` | Boleh melihat serta membuat/mengubah Draft yang memang diizinkan role | `VIEW`, `CREATE_DRAFT`, `EDIT_DRAFT`; tidak memberi approve/post/reversal |
| `TANPA_AKSES` | Submodul disembunyikan dan direct access ditolak | Tidak ada capability |

`OPERASIONAL` tidak otomatis memberi semua mutation. Sebuah submodul hanya
mendapat aksi yang terdaftar pada catalog dan sudah dimiliki baseline role.
Misalnya role yang tidak boleh membuat Transfer tidak memperoleh hak tersebut
walaupun override payload mencoba mengirim `OPERASIONAL`.

Untuk v1, hak `APPROVE`, `POST`, `CANCEL_FINAL`, `REVERSE`, `CLOSE_PERIOD`,
`MANAGE_ACCESS`, dan `MANAGE_ENTITLEMENT` hanya dapat dipertahankan melalui
`IKUTI_ROLE`; preset lain menurunkannya. Tidak ada custom preset yang dapat
menambahkan hak sensitif itu.

## 4. Governance Pengelola Akses

Hierarchy pengelola custom permission:

- Super Admin: dapat mengelola membership semua Company setelah memilih Company;
- Company Owner: dapat mengelola Company Admin dan role di bawahnya pada Company
  sendiri, tetapi tidak mengubah akses dirinya sendiri;
- Company Admin: dapat mengelola role di bawah Company Admin pada Company
  sendiri, tetapi tidak dirinya sendiri, Owner, Super Admin, atau Company Admin
  lain;
- role lain: tidak dapat mengelola custom permission.

Guard tambahan:

- tidak boleh menurunkan akses diri sendiri sehingga Company kehilangan
  pengelola terakhir;
- tidak boleh menonaktifkan/membatasi Company Owner aktif terakhir;
- mutation memakai optimistic `master_version`, actor dari session, active
  Company server-side, immutable before/after audit, dan exact-retry behavior;
- normal save tidak meminta alasan. Alasan wajib hanya untuk aksi keamanan yang
  memang didefinisikan sebagai revoke/deactivation sensitif dan memiliki field
  UI yang terlihat;
- daftar email global tidak pernah dikirim ke browser. Pemilihan akun existing
  tetap melalui user yang sudah terlihat dalam scope atau exact-email guarded
  assignment;
- feature entitlement tetap hanya Super Admin. Custom permission tidak dapat
  menyalakan modul;
- pengelolaan custom permission sendiri adalah protected capability dan tidak
  dapat didelegasikan melalui custom override.

## 5. Catalog Awal dan Boundary

Catalog memakai stable permission key terpisah dari label UI. Rename label atau
icon tidak boleh mengubah identity permission.

### Inventory — pilot pertama

- `inventory.master_data`
- `inventory.products`
- `inventory.stock_real`
- `inventory.stock_movements`
- `inventory.stock_transfers`
- `inventory.stock_adjustments`
- `inventory.stock_opnames`
- `inventory.opening_stock`
- `inventory.minimum_stock`

### Contacts, Purchase, dan Sales

- `contacts.customers`
- `contacts.suppliers`
- `contacts.staff_access` — protected management boundary;
- `purchase.supplier_orders`
- `purchase.purchase_returns`
- `sales.sales_documents`
- `sales.pricelists`
- `sales.bundles`
- `sales.sales_returns`

### Finance, Data Exchange, dan Platform

- `finance.expenses`
- `finance.cash_deposits`
- `finance.deposit_variances`
- `finance.customer_balances`
- `finance.supplier_invoices`
- `finance.supplier_payments`
- `finance.payment_methods`
- `finance.tax_rules`
- `finance.master_data`
- `finance.journals_reports`
- `data.exchange`
- `platform.company_branding`
- `platform.module_settings` — operational config only;
- `platform.companies` — Super Admin only dan tidak custom-delegatable.

Catalog final wajib dibentuk dari route/navigation/API/RPC inventory aktual,
bukan hanya daftar di atas. `Master Inventory` dan `Jurnal Keuangan` mempunyai
beberapa tab/aksi internal; audit ACP-1 menentukan apakah satu permission key
cukup atau perlu split sebelum enforcement.

Protected operations berikut tidak boleh dibuka oleh override:

- enable/disable entitlement Company;
- direct Stock/FIFO/Movement mutation;
- direct Payment/Event/Journal mutation;
- posting/reversal/period close di luar workflow canonical;
- Company creation/cross-Company assignment di luar hierarchy;
- service-role operation, secret, atau global Auth user directory.

## 6. Model Data yang Direncanakan

Nama final tetap menunggu schema preflight ACP-1. Bentuk logis minimum:

1. `access_permission_catalog`
   - system-owned stable key, module, label, supported capabilities/presets,
     protected flag, active/version metadata;
2. `user_company_permission_overrides`
   - `company_id`, `user_id`, permission key, restriction preset,
     `master_version`, actor/timestamp;
3. `user_company_permission_audit`
   - append-only action, actor, target user, Company, before/after state,
     correlation/idempotency identity.

Tidak ada row override berarti `IKUTI_ROLE`. Catalog seed idempotent; applied
migration tidak diedit. Foreign key dan uniqueness harus tenant-safe. Browser
tidak memperoleh direct write pada ketiga table.

Resolver canonical direncanakan menghasilkan:

```text
resolve_user_permission(company, actor, permission_key)
  -> baseline capabilities
  -> restriction preset
  -> effective capabilities
  -> denial reason / scope metadata
```

Navigation catalog, Route Handler, dan guarded RPC memakai resolver yang sama
atau helper dengan contract identik. Client tidak menghitung authority sendiri.

## 7. Urutan Delapan Fase

### ACP-0 — Contract dan roadmap lock

**Scope:** dokumen ini, requirement/index/router/gate/handoff. Tidak ada schema,
API, atau UI.

**Exit:** keputusan, precedence, preset, governance, phase order, rollback, dan
out-of-scope tidak ambigu.

### ACP-1 — Read-only access inventory dan compatibility fingerprint

**Status 2026-08-12:** LOCAL READY; live diagnostic output pending. Artifact:
`supabase/diagnostics/acp_phase1_access_compatibility_preflight.sql`,
`ACP1_ACCESS_ACTION_BASELINE_MATRIX.md`, dan
`runbooks/ACP1_ACCESS_COMPATIBILITY_PREFLIGHT.md`.

**Artifact:** diagnostic SELECT-only, access-route inventory, dan runbook audit.

Pekerjaan:

- fingerprint membership/role/Store/Warehouse/Terminal dan duplicate/orphan;
- petakan seluruh card, direct route, Route Handler, RPC, RLS, dan mutation;
- petakan aksi tiap submodul: view, draft create/edit, review, post, export,
  import, config;
- temukan akses yang hanya disembunyikan client atau role check yang tidak
  konsisten;
- rekam baseline hasil untuk setiap role agar regression dapat membuktikan
  absent override tidak mengubah behavior;
- inventory protected operations serta browser write boundary.

**Exit:** `BLOCKER` nol atau corrective plan eksplisit; catalog v1 dan baseline
matrix dibekukan sebelum schema dibuat.

### ACP-2 — Database foundation dalam shadow mode

**Status 2026-08-12:** LOCAL READY; manual migration/postflight/behavior pending.
Migration `20260812120000` seeds 32 stable keys, stores only restrictions,
protects target hierarchy/last Owner, and returns `enforced=false`. No existing
navigation/API/RPC/RLS consumes the resolver in this phase.

**Artifact:** additive migration, resolver, guarded save/reset/list RPC,
postflight, rollback-safe behavioral test, runbook.

Pekerjaan:

- buat catalog, override, audit, indexes, RLS/revoke, version/idempotency guard;
- seed catalog tanpa membuat override user;
- resolver menghitung baseline + override tetapi belum memengaruhi production
  route/navigation;
- shadow comparison mencatat aggregate mismatch tanpa PII/secret dan tanpa
  mengubah allow/deny existing;
- negative test cross-Company, self/equal/higher management, privilege
  escalation payload, stale version, retry, direct writes.

**Exit:** schema PASS, role parity shadow PASS, runtime user belum berubah.

### ACP-3 — Detail User dan multi-Company management consolidation

**Artifact:** klik row/card user membuka modal/detail user, membership Company,
role per Company, Store assignment, dan resolved permission preview.

Pekerjaan:

- daftar user tetap tenant-scoped;
- Super Admin dapat menambah Company pada akun existing dari detail yang sama;
- Company switch di modal tidak membocorkan data Company lain;
- tampilkan baseline role, effective preview, serta keterangan bahwa override
  belum aktif untuk batch yang belum cutover;
- custom confirmation, Escape close, loading/error/version conflict state;
- jangan meminta user mengetik ulang email bila akun sudah berada di daftar
  authorized.

**Exit:** multi-Company assignment existing tetap kompatibel, hierarchy denial
dan two-Company UI smoke PASS. Belum ada enforcement baru.

### ACP-4 — Inventory pilot cutover

**Artifact:** editor preset Inventory dan enforcement end-to-end untuk seluruh
Inventory keys yang sudah dibekukan ACP-1.

Urutan internal per key:

1. navigation/list/detail read;
2. draft mutation;
3. review/post/cancel workflow;
4. export/import bila relevan;
5. direct URL/API/RPC negative test.

Aktivasi dilakukan satu batch migration/config version, bukan setengah route.
Jika satu key belum lengkap, key tersebut tetap role-only dan UI diberi label
`Mengikuti role — belum custom`.

**Exit:** Warehouse/Admin/Manager matrix, Store/Warehouse isolation, stock final
invariant, absent-override parity, all four preset, direct bypass, switch Company,
cache refresh, lint/build, dan authenticated smoke PASS.

### ACP-5 — Contacts, Purchase, dan Sales cutover

Pekerjaan:

- cutover Contacts terlebih dahulu; `staff_access` tetap protected;
- cutover Purchase tanpa mengubah Supplier Order/Receipt/Return workflow;
- cutover Sales tanpa mengubah price/tax/payment/Return/Delivery authority;
- DEX visibility untuk master terkait mengikuti effective capability, tetapi
  generic import tetap tidak menyentuh transaction/final history;
- jalankan online/offline POS regression agar pembatasan Backoffice tidak
  mengubah Cashier execution path yang disetujui.

**Exit:** three-module role/custom matrix, two-Company, direct route/RPC,
Sale/Purchase no-double-effect, and DEX parity PASS.

### ACP-6 — Finance, Data Exchange, dan Platform cutover

Pekerjaan:

- Finance dipotong per page/action dengan `VIEW_ONLY`/`OPERASIONAL` tidak pernah
  memberi approve/post/reversal/close;
- report/export hanya muncul bila user memiliki effective view/export;
- `platform.companies`, entitlement, permission admin, queue/reversal/period
  protected boundary diuji eksplisit;
- Data Exchange catalog memakai effective permission server, bukan static menu;
- Finance HOLD, queue scope, period, maker-checker, immutable journal, dan
  reconciliation tidak berubah.

**Exit:** Finance/Accounting/Owner/Admin matrix, XLSX/CSV access, protected-action
escalation rejection, two-Company journal isolation, and report parity PASS.

### ACP-7 — Security closure dan kembali ke pre-deploy

Pekerjaan:

- full role × preset × submodule × Company matrix;
- user biasa multi-Company dengan override berbeda pada Company A/B;
- Home/module landing/Fast Link/search/direct URL/API/RPC parity;
- feature OFF, inactive membership, scope mismatch, stale token/cache, tab lama,
  revoke saat session aktif, optimistic conflict, exact retry, audit;
- performance query count/latency dan resolver cache invalidation;
- Backoffice/PWA build, auth/RLS regression, DEX, Stock, Sale, Purchase, Finance;
- rollback drill ke role-only dengan data override tetap dapat dipertahankan
  nonaktif untuk forward recovery.

**Exit:** seluruh gate PASS dan PRD-1 full E2E/Vercel Preview checklist dapat
dilanjutkan. ACP completion tidak otomatis berarti Vercel deployment dilakukan.

## 8. Compatibility, Rollout, dan Rollback

Compatibility rules:

- no override = exact current role behavior;
- catalog item baru default role-only sampai seluruh enforcement path selesai;
- setiap batch mempunyai cutover version; UI hanya memakai effective permission
  bila server menyatakan key tersebut `ENFORCED`;
- legacy role helper dipertahankan selama dual-read/shadow comparison;
- tidak ada mass update membership atau permission row.

Rollback:

- ACP-2 dapat mematikan resolver enforcement dan kembali role-only tanpa drop;
- ACP-4—ACP-6 dapat rollback per batch key ke role-only;
- audit/override history tidak dihapus;
- migration destructive/drop hanya boleh dibahas setelah PRD closure, bukan
  bagian rollout ini;
- bila navigation dan API tidak sinkron, fail closed pada key enforced dan
  rollback batch—jangan membuat client bypass.

## 9. Test Matrix Minimum

1. setiap role tanpa override menghasilkan hasil baseline yang sama;
2. empat preset tidak pernah memperluas baseline;
3. crafted payload `OPERASIONAL` pada aksi di luar role ditolak;
4. menu tersembunyi, direct URL, Route Handler, RPC, dan direct table mutation
   memberi denial konsisten;
5. feature OFF menolak walaupun role/override mengizinkan;
6. Company A/B dapat memiliki override berbeda untuk user yang sama;
7. Store/Warehouse/Terminal scope tidak melebar;
8. Company Admin tidak mengubah diri/equal/higher; Owner tidak mengubah diri;
9. last-owner/admin safety guard bekerja;
10. stale version ditolak, exact retry tidak menggandakan audit;
11. Company switch/logout/revoke membersihkan effective-permission cache;
12. Stock/Finance/final document invariants tidak berubah;
13. report/export/import mengikuti effective permission;
14. resolver tidak membuat N+1 query pada Home/sidebar/list API.

## 10. Explicit Out of Scope

Tidak dibangun pada rangkaian ini:

- custom role builder bebas;
- group inheritance seperti Odoo;
- CRUD permission per table/model;
- field-level permission;
- user-authored record-rule/domain expression;
- arbitrary approval workflow designer;
- cross-Company shared data;
- employee/payroll access;
- pengaktifan deferred Assets, Manufacture, Logistics advanced, atau inter-
  Company automatic Sales/Purchase.

Jika kebutuhan tersebut muncul, buat requirement dan preflight baru setelah
Vercel pilot; jangan menyelipkannya ke ACP.

## 11. Next Safe Step

ACP-2 foundation tersedia; ACP-4B sampai ACP-4I, ACP-5A sampai ACP-5H, serta
ACP-6A sampai ACP-6D telah user-confirmed database/behavior/regression PASS.
Compatibility `WIND_DOWN` Customer Balance juga telah lulus Phase-49/52/56;
authority Sale/open-session tetap terpisah. Smoke Finance ditunda secara
eksplisit ke closing UAT dan tetap `PENDING`.

ACP-6E Supplier Invoice preflight diterima tanpa `BLOCKER`/`BACKFILL`.
Enforcement `20260813110000` local-ready: composed read, Draft/Edit/Post,
tolerance melalui `APPROVE`, export, referensi sempit Supplier Payment/Purchase
Return, serta direct read closure. Financial Event tetap `HOLD` dan Journal
tidak dibuka. Next safe step adalah rollout migration, postflight, behavior,
regression G5 Phase-11/14, optional-tolerance postflight, lalu postflight ACP-6E
ulang. Smoke tetap closing UAT gabungan.

User kemudian mengonfirmasi seluruh ACP-6E rollout dan regression PASS;
`finance.supplier_invoices` database-live `ENFORCED`. Gate aktif berpindah ke
ACP-6F Supplier Payment SELECT-only. Preflight wajib menilai composed VIEW,
Draft/Edit/Post, Draft-only cancellation, payable-Invoice dan Supplier
reference terpisah, source cash/bank account server validation, allocation/AP
reconciliation, tenant/audit/idempotency, optional export, dan Finance HOLD.
Tidak boleh membuat review state baru, membatalkan VALIDATED payment, membuka
Payment Method/Finance master authority, atau memproses Journal dari ACP-6F.

Live ACP-6F preflight diterima tanpa `BLOCKER`/`BACKFILL`. Enforcement
`20260813120000` local-ready dengan composed read, guarded Draft/Edit/Post,
eligible cash/bank source-account validation, Draft-only cancel, export
bulanan, direct-table closure, dan private proven G5 cores. Payment Event tetap
`HOLD`; rollout, postflight, behavior, G5 Phase-14 dan ACP-6E regressions wajib
lulus sebelum gate berpindah ke Payment Method.

User kemudian mengonfirmasi ACP-6F postflight seluruhnya PASS setelah behavior
dan regression sukses. `finance.supplier_payments` database-live `ENFORCED`;
smoke tetap closing UAT. Gate aktif berpindah ke ACP-6G Payment Method
SELECT-only. Preflight wajib menilai composed Backoffice VIEW, ordinary method
MANAGE, Store assignment, exact-one-default, period/route/fee/Account Function,
system-owned Customer Balance/Ketul Offset, Sales snapshot, POS online/offline
dan Expense consumer authority terpisah, tenant/audit/direct browser boundary,
serta explicit EXPORT/IMPORT decision. Supplier Payment enum ACP-6F tidak boleh
diganti atau disatukan diam-diam oleh gate ini. Migration ACP-6G belum boleh
dibuat sebelum seluruh output live dinilai.

Live ACP-6G preflight diterima tanpa `BLOCKER`; empat Payment Method lama
masuk audit backfill. Enforcement `20260813130000` local-ready dengan composed
VIEW/EXPORT, guarded MANAGE, POS open-session reference, Expense POST
reference, actor-null `BACKFILL`, audit immutable, dan direct-table closure.
Import tetap tidak dibuka dan system-owned method tidak dapat dimutasi melalui
generic master. Rollout/regression/smoke belum menandai fase database-live.

User kemudian mengonfirmasi rollout ACP-6G sampai closing postflight seluruhnya
PASS. Seluruh permission key ACP-4B—ACP-6G yang dibuka sekarang database-live
`ENFORCED`. ACP-7 menjadi gate aktif: SQL preflight lebih dulu, lalu satu
authenticated role × preset × submodule × Company matrix, regression/build,
dan rollback drill. Smoke tertunda dari setiap fase tidak dianggap hilang;
seluruhnya dikonsolidasikan pada matrix ACP-7.
