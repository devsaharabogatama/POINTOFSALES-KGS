# Active Development Handoff — KGS POS

**Status dokumen:** ACTIVE — wajib diperbarui setiap agent
**Terakhir diperbarui:** 2026-08-06
**Workspace:** `C:\Users\sbi_l\OneDrive\Documents\POINT OF SALES`

Dokumen ini adalah catatan operasional tunggal untuk meneruskan pekerjaan ketika
agent berganti atau context/limit habis. Dokumen ini tidak menggantikan
spesifikasi bisnis; ia menunjuk source of truth dan mencatat posisi implementasi
terakhir.

## Update Terbaru — G5 Phase 11 Supplier Invoice Matching Foundation

`READY FOR MANUAL DATABASE ROLLOUT` (2026-08-06).

- User mengonfirmasi Phase 10 preflight aman; satu
  `supplier_invoice_matching_scope = BACKFILL` adalah AP provisional existing
  yang memang menjadi allocation scope, bukan blocker.
- Migration local-ready:
  `20260806100000_g5_phase11_supplier_invoice_matching_foundation.sql`.
- Contract: Draft/HOLD/VALIDATED/CANCELED, exact Receipt/AP allocation
  many-to-many, row lock, optimistic version, idempotent validation, tolerance
  dan Purchase Tax snapshot, residual AP reconciliation, last purchase price,
  immutable audit, serta Financial Event `HOLD_UNTIL_G6`.
- Supplier Invoice tetap zero-effect terhadap Stock/FIFO/Movement. Supplier
  Payment, final valuation adjustment, Debit/Credit Note resolution, dan jurnal
  G6 belum dibuka.
- Integrasi penting: trigger AP provisional sekarang menjaga identity/nilai
  Receipt immutable tetapi mengizinkan status `OPEN -> MATCHED/REVERSED`.
  Purchase Return terhadap provisional yang baru terinvoice sebagian diblokir
  fail-closed sampai split AP Provisional/Supplier Credit tersedia.
- Local evidence: 10 PL/pgSQL routine dollar-tag seimbang, satu transaction,
  parenthesis migration/postflight/test seimbang, `git diff --check` scoped
  PASS, checksum migration
  `1d4703ff836d5ea55de9a203211a77d7fa05ece825d4d45a8768aadf6e357162`.
- Manual gate dan regression wajib mengikuti
  `docs/runbooks/G5_PHASE11_SUPPLIER_INVOICE_MATCHING_FOUNDATION_ROLLOUT.md`.
- Next safe step setelah seluruh database gate PASS: Backoffice Finance
  Supplier Invoice matching UI. Jangan membuka Supplier Payment/G6 lebih awal.

## Update Sebelumnya — G5 Phase 9 Purchase Return UI

`READY FOR AUTHENTICATED SMOKE TEST` (2026-08-06).

- User mengonfirmasi migration/postflight/behavior Phase 8 seluruhnya PASS.
- POS sekarang mempunyai `Retur Supplier`: hanya Session OPEN, memilih Goods
  Receipt POSTED + Gudang/FIFO asal, lalu menyimpan Draft approval.
- Backoffice mempunyai `Purchase > Retur Pembelian`: detail user-facing,
  approve tanpa alasan, reject/cancel dengan alasan, dan Post terpisah.
- Mutation tetap melalui empat RPC Phase 8; browser tidak mendapat direct write.
- Evidence lokal: PWA lint/build PASS; Backoffice lint/build PASS; Next build
  mendeteksi route list/review/post/cancel.
- Manual gate: jalankan smoke pada
  `docs/runbooks/G5_PHASE9_PURCHASE_RETURN_OPERATIONAL_UI.md`.
- Next Safe Step setelah smoke lulus: lanjutkan preflight Supplier Invoice/AP
  matching sesuai G5. Jangan membuka jurnal final G6 lebih awal.

### Penyesuaian UOM dan gate berikut (2026-08-06)

- Root cause: RPC Phase 8 dan loader PWA hanya menerima Product-UOM dengan
  `purchase_allowed=true`; ini salah untuk kasus Receipt 1 Dus, retur 3 Ketul.
- Forward-fix local-ready:
  `20260806080000_g5_phase9_purchase_return_uom_fix.sql` beserta postflight.
- Regression Phase 8 diperbarui agar Receipt memakai Box factor 10 dengan
  `purchase_allowed=true`, sedangkan Return memakai Piece factor 1 dengan
  `purchase_allowed=false`.
- PWA dropdown sekarang memuat semua Product-UOM aktif; backend tetap memeriksa
  Product yang sama, UOM aktif, precision, conversion ke base, dan FIFO source.
- Phase 10 Supplier Invoice preflight SELECT-only local-ready. The 2026-08-06
  correction removes the invalid legacy `purchases_headers.status` reference;
  financial backfill scope now uses only verified `grand_total`/`paid_amount`.
  Urutan manual
  wajib mengikuti `docs/runbooks/G5_PHASE10_SUPPLIER_INVOICE_PREFLIGHT.md`.
- Status: `READY FOR MANUAL DATABASE ROLLOUT`. Jangan menjalankan Phase 10
  preflight sebelum ledger `20260806080000` PASS.

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
| App shell Home/Back/breadcrumb navigation | READY FOR SMOKE TEST | Brand kembali ke launcher; seluruh view non-dashboard mendapat Back berbasis history aplikasi dan breadcrumb Beranda/Modul/Halaman; lint/build PASS, authenticated click smoke menunggu user |
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
| Remaining simple master import UI | COMPLETE | Template/export/mapping/preview tiga tipe baru; lint/build dan authenticated smoke user PASS |
| Grouped Product Import preflight | COMPLETE | User mengonfirmasi seluruh live preflight PASS |
| Grouped Product Import database | COMPLETE | `20260727130000` + forward fix `20260727140000`; postflight, behavior, dan Phase-40/38 regression seluruhnya PASS |
| Grouped Product Import UI | READY FOR SMOKE TEST | Template/export `product_v1`, grouped preview per Product, nama UOM user-facing; lint/build PASS |
| Product-Supplier Import preflight | COMPLETE | User mengonfirmasi seluruh blocker live PASS; satu relation existing valid dan tidak ada job nonterminal |
| Product-Supplier Import database | COMPLETE | User mengonfirmasi migration `20260727160000`, 11-check postflight, behavioral test, dan regression seluruhnya PASS |
| Product-Supplier Import UI | COMPLETE | Fixed template/export, preview nama tanpa UUID, preferred-switch guidance; lint/build dan user smoke PASS |
| Minimum Stock Produk–Gudang preflight | COMPLETE | Live output seluruhnya PASS/INFO; 1 Product, 3 Gudang, 3 eligible pair, zero balance/movement/ambiguity/orphan/job aktif |
| Minimum Stock Produk–Gudang database | COMPLETE | User mengonfirmasi rollout aman dan melanjutkan; `20260728090000`, 12-check postflight, behavior + Phase-44/42/40/38 regression ditutup |
| Minimum Stock API/UI + fixed Import/Export | READY FOR SMOKE TEST | Guarded list/create/update route, Inventory page, Base-UOM label/precision UX, fixed template/export/preview; lint/build PASS |
| G3 Opening Stock preflight | COMPLETE | User mengirim seluruh hasil: 13 invariant PASS; 3 eligible pair; zero balance/movement/batch; expected enum/schema absent |
| G3 Opening Stock database | COMPLETE | User mengonfirmasi migration `20260728120000`, postflight, behavioral test, dan regression seluruhnya sukses |
| G3 Opening Stock API/UI | READY FOR SMOKE TEST | Guarded Draft/Posting, stok aktual total/per Gudang, serta indikator Minimum Stock local-ready; Backoffice lint/build PASS |
| G3 Stock Real API/UI | READY FOR SMOKE TEST | Halaman read-only sesuai spec: On Hand/Available per Product–Gudang, Reserved explicit deferred, FIFO valuation, last movement, serta minimum filter; lint/build PASS |
| G3 Stock Movement preflight | COMPLETE | User mengirim seluruh invariant PASS; satu Opening movement/pair/source, saldo cocok, browser direct write false; expected 8 column dan 5 enum gap |
| G3 canonical Stock Movement database | COMPLETE | User mengonfirmasi migration `20260728150000`, postflight, behavior, dan regression seluruhnya all good |
| G3 Stock Movement / Kartu Stok API/UI | COMPLETE | Read-only tenant-scoped ledger, nama bisnis tanpa UUID, Base-UOM/balance snapshot, source/actor aman, filter; lint/build dan user smoke PASS |
| G3 Stock Transfer preflight | COMPLETE | Live result seluruh blocker PASS; expected legacy RPC REVIEW; zero Transfer history; satu saldo sumber positif dan tiga Gudang aktif |
| G3 canonical Stock Transfer database | COMPLETE | User mengonfirmasi `20260728180000`, seluruh 15 postflight, behavior, dan Phase-4/1/46/G1 regression sukses |
| G3 Stock Transfer API/UI | COMPLETE | Guarded create/edit/post/cancel, saldo/FIFO proof, role-aware menu, nomor Transfer di Kartu Stok, dan authenticated user smoke PASS |
| G3 Stock Adjustment preflight | COMPLETE | User mengirim seluruh blocker PASS; zero legacy Adjustment/backfill, 2 positive FIFO layers/pairs, Finance dan Base UOM siap |
| G3 canonical Stock Adjustment database | COMPLETE | User mengonfirmasi migration `20260728210000`, 16-check postflight, rollback-safe behavior, dan regression seluruhnya sukses |
| G3 Stock Adjustment API/UI | COMPLETE | Guarded Draft/Edit/Post/Cancel, final physical quantity UX, reason arah selisih, gain cost override, FIFO/value proof, Kartu Stok source; lint/build dan user smoke PASS |
| G3 Stock Opname preflight | COMPLETE | User mengirim seluruh invariant PASS; legacy session/detail kosong, zero overlap/backfill/link error, balance/FIFO dan canonical Adjustment siap |
| G3 canonical Stock Opname database | COMPLETE | User mengonfirmasi migration `20260728230000`, 14-check postflight, rollback-safe behavior, serta regression seluruhnya sukses |
| G3 Stock Opname Backoffice API/UI | COMPLETE | Tenant-scoped report/review, attempt timeline, Adjustment proof, guarded recount/post/cancel, role-aware menu, Escape modal, dan user continuation smoke accepted |
| G3 Bundle foundation preflight | COMPLETE | User mengirim seluruh invariant PASS; zero Bundle/component/backfill/physical stock dan schema/RPC gap sesuai expected |
| G3 canonical Bundle foundation database | COMPLETE | User mengonfirmasi migration `20260729010000`, postflight, behavior, dan regression seluruhnya all good |
| G3 Bundle master API/UI | COMPLETE | Guarded create/edit dan availability, Sales UI dengan nama Product/UOM, harga final, derived weight, pemisahan Product stok; lint/build dan continuation smoke accepted |
| G3 inventory-core exit/stress preflight | COMPLETE | User mengirim seluruh core invariant PASS; `SETUP` hanya fixture stress, `DEFERRED` G4/G5 expected, dan live inventory tetap konsisten |
| G3 integrated inventory-core stress behavior | COMPLETE AT CORE BOUNDARY | User melanjutkan tanpa error dan Phase-14 rerun tetap seluruh core PASS; rollback menjelaskan fixture live tetap `SETUP` |
| G4 POS checkout readiness preflight | COMPLETE | User output: seluruh dependency/config/data PASS; blocker tepat pada legacy client-authoritative checkout, missing price resolver, dan missing canonical runtime |
| G4 canonical Cashier Session database | COMPLETE | User mengonfirmasi migration, 13-check postflight, behavioral test, dan regression seluruhnya sukses; checkout tetap tertutup |
| G4 Atomic Sale runtime preflight | COMPLETE | User output sesuai baseline: seluruh data/invariant PASS, dua blocker hanya checkout legacy, empat setup tepat pada runtime canonical |
| G4 Atomic Sale runtime database | COMPLETE | User mengonfirmasi migration, 17-check postflight, behavioral test, dan regression clear |
| G4 POS online integration | COMPLETE AT ONLINE SINGLE-PAYMENT BOUNDARY | User mengonfirmasi rollout dan PWA smoke clear; POS dua panel, reset POSTED, receipt print-tab, serta guarded Customer Pricelist AUTO/override aktif |
| G4 Sale Draft list/edit-lock | DATABASE FOUNDATION READY; MANUAL DB GATE PENDING | Live preflight bersih; nomor/metadata Draft, same-Store list, five-minute heartbeat lock, confirmed takeover, force release, cancel, audit, dan guarded Save/Post local-ready |
| G4 Payment-Leg identity | COMPLETE | User mengonfirmasi migration `20260729150000`, postflight, corrected behavior, dan regression sukses |
| G4 Split Payment PWA UI | READY FOR AUTHENTICATED TABLET SMOKE | Multi-leg exact-total UI, stable retry key, per-leg Cash/proof, server fee estimate, duplicate-method prevention; PWA lint/build PASS |
| G4 Online Checkout stress preflight | COMPLETE | User mengirim seluruh check PASS/INFO; fixture dua-user siap, lock/FIFO/idempotency core PASS, dan seluruh final-effect reconciliation bersih |
| G4 true-concurrent Post stress | COMPLETE | Setelah stok ditambah, 20-response concurrency assertions, POSTED state, posting key, Movement, Payment, audit, dan identity lolos; service read-only membuktikan tepat satu `SALE_POSTED` Event HOLD |
| G4 Offline Stock Allowance preflight | COMPLETE | User mengirim seluruh dependency/invariant PASS, expected lima-table SETUP, entitlement disabled, satu Terminal/operator/Gudang dan Cash/elektronik siap, dua positive stock/FIFO pair konsisten |
| G4 Offline Stock Allowance foundation | COMPLETE | User mengonfirmasi migration, seluruh postflight, corrected behavior, dan regression sukses; policy/reservation/stock/session/history guard aktif, ingest/sync/PWA offline tetap tertutup |
| G4 Offline submission/sync preflight | COMPLETE | User mengirim seluruh dependency/invariant PASS; tiga table, sembilan snapshot column, tiga RPC, dan Payment exception event tepat berstatus expected SETUP |
| G4 canonical Offline Sale Sync database | COMPLETE | Migration `20260729210000`, corrected postflight, behavioral, lima regression, dan reconciliation penutup dikonfirmasi seluruhnya PASS oleh user |
| G4 retained Offline PWA queue foundation | LOCAL-READY | Dexie v3 retained queue, canonical JSONB hash, stable submit/process/status retry, acknowledgement retention, dan Phase-22 Cart integration selesai; entitlement tetap disabled sampai UAT |
| G4 authoritative Offline catalog cache preflight | COMPLETE | User output: dependency dan seluruh invariant PASS; RPC serta Terminal policy tepat `SETUP`; entitlement disabled; Pricelist/Tax/Payment/Product-UOM inventory siap |
| G4 authoritative Offline catalog snapshot database | COMPLETE | Migration, postflight, corrected behavior, Phase-12/11/4/G1 regression, dan closing postflight dikonfirmasi seluruhnya PASS; zero Terminal policy tetap expected `SETUP` |
| G4 retained Offline PWA catalog cache | LOCAL-READY | Dexie v4 snapshot, exact scope/hash/freshness/invalidation, queue-aware allowance reconciliation, dan Phase-22 Cart pricing/validation selesai; lint/build PASS |
| G4 read-only Offline status/cache PWA UI | READY FOR AUTHENTICATED CLOSED-ENTITLEMENT SMOKE | Tombol header membuka drawer koneksi/scope/snapshot age/allowance; workspace tetap lega, lazy cache chunk selesai, checkout tetap diblokir; browser smoke agent tidak tersedia |
| G4 guarded Offline policy Backoffice UI | READY FOR AUTHENTICATED ROLE SMOKE | Default Company, override Toko, eligibility Terminal, audited RPC, custom confirmation/Escape, dan role-aware menu selesai; entitlement tetap Super Admin-only dan checkout tertutup |
| G4 Offline Allowance operations Backoffice UI | READY FOR AUTHENTICATED ROLE UAT | Session–Product list dan guarded issue/release/force-revoke tersedia tanpa direct write; lint/build PASS |
| G4 Cashier Offline Allowance PWA UI | READY FOR AUTHENTICATED TABLET UAT | Cashier issue/release sesi sendiri, server/local/queued quantity, authoritative refresh, serta fail-closed cache invalidation; lint/build PASS |
| G4 Offline checkout queue readiness preflight | COMPLETE | User output seluruh invariant PASS; expected UAT scope SETUP karena entitlement/Terminal/allowance/open Session belum diaktifkan |
| G4 Offline checkout retained queue PWA UI | READY FOR AUTHENTICATED TABLET UAT | Snapshot Pricelist pricing, Base-UOM allowance, exact Payment, retained local commit, Slip Offline watermark, retry/status/final invoice; lint/build PASS |
| G4 Offline cold-start/conflict recovery preflight | COMPLETE | User output seluruh kontrak server, recovery, final-effect, scope UAT, dan Stock–Movement–FIFO PASS; client contract expected SETUP |
| G4 Offline cold-start/recovery PWA | READY FOR AUTHENTICATED TABLET UAT | Dexie v5 exact operational scope, cached-auth match, snapshot/catalog/queue restore, status-first reconnect, time-bounded submit/process/status, nonblocking post-success reconciliation, dan controlled manual retry; lint/build PASS |
| G4 Offline disconnect/reconnect stress | COMPLETE | User mengonfirmasi controlled disconnect, recovery/status-first, sync UI, serta seluruh Phase-24/23/12 closing diagnostics PASS; Offline core ditutup pada boundary ini |
| G4 Sales Return database foundation | COMPLETE | Phase-26 migration/fix/postflight/behavior serta G4 Phase-10, G3 Phase-14, dan G1 regression dikonfirmasi PASS; `SETUP` G3 hanya fixture stress rollback |
| G4 Sales Return PWA Draft UI | COMPLETE AT DRAFT BOUNDARY | Online invoice search, qty/kondisi, Gudang Rusak, refund Cash/Transfer otomatis; PWA lint/build PASS dan user berhasil membuat Draft Return |
| G4 Sales Return Backoffice approval UI | COMPLETE AT REQUIRED-APPROVAL BOUNDARY | Sales list/detail dan guarded post berhasil diuji user; cancel tersedia; optimistic version/idempotency, role/store guard, dan Finance HOLD tetap aktif |
| G4 Expense/Cash Flow preflight | COMPLETE | User output: dependency/value/tenant/payment/category/account/privilege PASS; zero legacy rows; one expected legacy trigger REVIEW; nine canonical tables SETUP |
| G4 Expense request/approval foundation | COMPLETE | User mengonfirmasi migration, postflight, rollback-safe behavior, dan regression seluruhnya PASS; feature default off dan request/approval cash-neutral |
| G4 Expense request PWA UI | COMPLETE AT REQUEST BOUNDARY | User berhasil membuat dan mengajukan Expense; online-only, guarded/idempotent, dan tetap cash-neutral |
| G4 Expense approval Backoffice UI | COMPLETE AT CASH-NEUTRAL APPROVAL BOUNDARY | User mengonfirmasi approval berhasil setelah approve-reason bugfix; guarded review/cancel, optimistic version, role/store boundary, dan zero cash-effect tetap berlaku |
| G4 Expense disbursement preflight | COMPLETE | Live output: expected four runtime SETUP; dependency, two approved Expense, payment/Store/Session, category/account, privilege, dan seluruh reconciliation PASS |
| G4 Expense disbursement foundation | COMPLETE | User mengonfirmasi migration, postflight, behavioral test, regression, dan closing check seluruhnya aman |
| G4 Expense disbursement operational UI | COMPLETE | User mengonfirmasi jalur Cash PWA dan non-Cash Backoffice aman; RPC guarded, expected-cash, drawer isolation, role/channel boundary, dan idempotency tetap berlaku |
| G4 Expense settlement preflight | COMPLETE | User output: lima expected runtime SETUP; dependency, totals, lifecycle, account/session, Finance/drawer coverage, dan privilege seluruhnya PASS; zero settlement/return history |
| G4 Expense settlement foundation | COMPLETE | User mengonfirmasi migration, postflight, behavioral test, dan seluruh regression aman |
| G4 Expense settlement operational UI | COMPLETE | User melanjutkan tanpa error; POS actual/return Cash/request tambahan dan Backoffice review actual/return non-Cash diterima |
| G4 Additional Expense disbursement preflight | COMPLETE | User output: seluruh dependency, request-only zero-effect, tenant/reference, payment/document/Session, duplicate-open, dan direct-write invariant PASS; enam column, dua RPC, dan event tepat SETUP |
| G4 Additional Expense disbursement foundation | COMPLETE | User mengonfirmasi migration, postflight, corrected behavioral test, seluruh regression, dan closing postflight sukses; guarded approve/reject, Cash/non-Cash execution, exact idempotency, single linked disbursement, drawer isolation, audit, dan Finance HOLD aktif |
| G4 Additional Expense operational UI | ACCEPTED AT CURRENT BOUNDARY | User melanjutkan setelah local delivery tanpa blocker; Backoffice review/non-Cash payment dan POS approved-Cash execution tersedia melalui RPC guarded; lint/build kedua aplikasi PASS |
| G4 Cash Deposit multi-Session foundation | COMPLETE | User mengonfirmasi migration, postflight, behavior, regression, dan closing verification Phase-43 seluruhnya PASS |
| G4 Cash Deposit operational UI | COMPLETE AT APPROVAL BOUNDARY | User mengonfirmasi approval berhasil setelah approve-reason bugfix; create/submit/review server-authoritative dan bank matching/resolution/offline/G6 tetap tertutup |
| G4 Deposit variance resolution preflight | COMPLETE | User mengirim seluruh dependency/data/account/privilege invariant PASS; expected schema/RPC/event gap hanya SETUP; exception/allocation live nol |
| G4 Deposit variance resolution foundation | COMPLETE | User mengonfirmasi seluruh migration/postflight/behavior/regression aman; partial allocation, maker-checker, audit, exact retry, dan Financial Event HOLD aktif |
| G4 Deposit variance operational UI | COMPLETE | Finance list/detail/assign/partial resolution, Owner/Admin maker-checker, Accounting read-only, Escape, lint/build, dan authenticated user smoke aman |
| G4 Customer Balance readiness preflight | COMPLETE | User melaporkan tidak ada blocker/error; hanya provisioning metode internal per Company berstatus BACKFILL; legacy balance/payment tetap bersih |
| G4 Customer Balance ledger/correction foundation | COMPLETE | User mengonfirmasi base, digest forward fix, postflight, corrected behavior, regression, dan closing checks seluruhnya sukses |
| G4 Customer Balance operational UI | LOCAL-READY | Backoffice liability, request/review maker-checker, dan statement melalui guarded RPC; lint/build PASS dan menunggu authenticated smoke |
| G4 Customer Balance Sale credit preflight | COMPLETE | User mengirim seluruh dependency/data/account/tenant/privilege invariant PASS; tiga gap schema/runtime tepat berstatus SETUP; histori non-Cash overpayment nol dan Cash change lama tetap returned |
| G4 Customer Balance Sale credit foundation | COMPLETE | User mengonfirmasi migration, postflight, behavior, regression, dan closing checks seluruhnya PASS; atomic ONLINE credit serta compatibility returned aktif |
| G4 POS overpayment disposition UI | ACCEPTED | User menyatakan aman untuk lanjut; Cash/Transfer online menerima nominal aktual dan pilihan kembalian atau saldo; Walk-In/feature/offline fail-closed; receipt/print menampilkan saldo |
| G4 Customer Balance tender preflight | COMPLETE | User output: tiga expected SETUP, seluruh dependency/data/lifecycle/account/category/history invariant PASS, direct browser writes false, dan live positive balance nol |
| G4 POS negative-stock permission preflight | COMPLETE | User mengonfirmasi seluruh Phase-55 preflight PASS; runtime tetap OFF dan foundation menunggu setelah Customer Balance tender |
| G4 Customer Balance tender foundation | COMPLETE | User mengonfirmasi corrected postflight seluruhnya PASS dan behavioral test Phase-56 PASS |
| G4 Customer Balance tender POS UI | ACCEPTED AT CURRENT BOUNDARY | User meminta lanjut sesuai rundown setelah database Phase-56 serta PWA lint/build PASS; authenticated tender smoke dapat digabung pada E2E berikutnya |
| G4 POS Negative Stock policy foundation | COMPLETE | User mengonfirmasi migration, postflight, behavior, regression, dan closing checks Phase-58 seluruhnya PASS; default OFF dan canonical Sale tetap `STOCK_SHORTAGE` |
| G4 POS Negative Stock runtime preflight | COMPLETE | User output: tiga expected `SETUP`, satu G5/G6 `DEFERRED`, seluruh dependency/config/data/reconciliation/boundary PASS, zero history/config aktif |
| G4 POS Negative Stock online runtime | PHASE 60 COMPLETE; PHASE 61 UI LOCAL-READY | User mengonfirmasi responsibility fix/postflight/behavior/regression PASS; Backoffice guarded config dan PWA reason/retry siap authenticated smoke |
| G5 Purchasing foundation preflight | COMPLETE | User mengonfirmasi seluruh Phase-1 preflight PASS |
| G5 Stock Request + Supplier Order foundation | COMPLETE | User mengonfirmasi migration, postflight, dan behavioral test Phase 2 seluruhnya sukses; Stock/FIFO/AP/Finance tetap zero-effect |
| G5 Stock Request + Supplier Order operational UI | ACCEPTED; REMAINING-LINE UX LOCAL-VERIFIED | User menerima flow; baris penuh yang sudah dialokasikan order aktif hilang dan partial hanya menampilkan sisa; lint/TypeScript PASS |
| G5 Goods Receipt readiness preflight | COMPLETE | User mengonfirmasi seluruh hasil Phase 4 PASS |
| G5 Goods Receipt foundation | COMPLETE | User mengonfirmasi forward-fix, postflight, behavioral test, dan seluruh hasil sukses |
| G5 Goods Receipt PWA | ACCEPTED | Online order list, Draft/resume/cancel, partial/over warning, kondisi baik/rusak/ditolak, dan guarded Post tersedia; lint/build PASS dan user mengonfirmasi proses receive aman |
| G5 Purchase Return readiness preflight | COMPLETE | User mengonfirmasi seluruh output Phase 7 PASS |
| G5 Purchase Return foundation | LOCAL-READY; LIVE ROLLOUT PENDING | Cashier Draft, manager review/Post, exact Goods Receipt FIFO consumption, Stock/Movement, append-only AP adjustment, Event HOLD, idempotency, audit, dan direct-write closure |
| G5 Supplier Invoice matching foundation | LOCAL-READY; LIVE ROLLOUT PENDING | Exact Receipt/AP allocation, tolerance/Purchase Tax snapshot, AP residual, last purchase price, immutable audit, idempotent validation, partial-Return guard, dan Finance HOLD tanpa Stock effect |

Catatan UX aktif:

- label UOM operasional memakai `name` (`Ketul`, `Dus`), bukan kode internal
  (`UOM-02`, `UOM-03`);
- kode tetap disimpan sebagai identifier master;
- Product menyimpan stok pada Base UOM; kemasan memakai faktor langsung ke base;
- kemasan terbesar otomatis menjadi acuan berat/rekomendasi UOM pembelian.

## 3. Fase Aktif

**G5 Phase 8 — Purchase Return database rollout**

User mengonfirmasi migration `20260806010000`, postflight, dan behavioral test
seluruhnya sukses. Kasir dengan sesi OPEN dapat
membuat/submit Stock Request, sedangkan Supplier Order hanya dapat dibuat dan
dikonfirmasi Store Manager/Company Admin/Super Admin. Order menyimpan snapshot
Product/UOM/harga estimasi serta allocation ke Request; confirm/cancel memakai
row lock, optimistic version, idempotency key, immutable final history, dan
audit tenant-scoped.

Boundary fase sengaja ketat: Request/Order tidak menulis `product_stocks`,
`product_batches`, `stock_movements`, AP, `financial_events`, atau Journal.
Warehouse Admin/Cashier tidak dapat memilih Supplier atau confirm Order. Legacy
`confirm_purchase_order(UUID,UUID)` dicabut dari browser bila masih ada.

File aktif:

- `supabase/migrations/20260806010000_g5_phase2_stock_request_supplier_order_foundation.sql`;
- `supabase/diagnostics/g5_phase2_stock_request_supplier_order_postflight.sql`;
- `supabase/tests/g5_phase2_stock_request_supplier_order_tests.sql`;
- `docs/runbooks/G5_PHASE2_STOCK_REQUEST_SUPPLIER_ORDER_ROLLOUT.md`.

Local evidence: struktur transaction/dollar-tag seimbang, targeted final-effect
scan bersih, scoped `git diff --check` PASS, dan checksum migration
`a33117dcd91edd2535068548b3f0699ab8883a8d821421586ff4ca3303ad15f5`.
Supabase CLI lint tidak dapat dijalankan lokal karena CLI mencoba menulis
telemetry di luar workspace; live syntax/behavior tetap manual gate.

Phase 3 menambahkan tombol `Minta Stok` pada PWA, pilihan Product dan nama UOM
pembelian, tanggal kebutuhan, submit atomic, serta riwayat Request. Backoffice
mendapat launcher/menu `Purchase > Supplier Order`, daftar Request aktif,
Supplier/Gudang tujuan, suggested price dari Product-Supplier lalu Product-UOM,
Draft dan Confirm. ID/kode teknis tidak ditampilkan. Supplier yang belum
terhubung tetap boleh dipilih dengan warning; relasi tidak dibuat diam-diam.

Local evidence: PWA oxlint dan production build PASS; Backoffice ESLint dan
Next production build PASS (route Purchase terdeteksi). Authenticated smoke
belum dilakukan user. Goods Receipt/Stock/FIFO/AP tetap belum boleh dibuka
sebelum smoke Request → Order ini lolos.

Penyesuaian terakhir: allocation dari order berstatus `CONFIRMED`,
`PARTIALLY_RECEIVED`, atau `RECEIVED` dikurangi dari setiap Request line.
Baris dengan sisa nol tidak lagi ditawarkan; partial allocation hanya menawarkan
quantity sisa. Order `DRAFT/CANCELED` tidak mengurangi sisa. Backoffice ESLint
dan TypeScript `--noEmit` PASS.

User mengonfirmasi seluruh Phase-4 preflight PASS. Phase 5 sekarang local-ready:
`20260806040000_g5_phase5_goods_receipt_foundation.sql` menambah Draft/Post/Cancel
Goods Receipt dari Supplier Order, receipt parsial dan over, alokasi kondisi
GOOD/DAMAGED/REJECTED, FIFO intake dan Purchase Movement atomic, AP provisional,
Financial Event `HOLD_UNTIL_G6`, optimistic version, exact idempotency, audit,
RLS, serta direct-browser-write closure. Barang rejected tidak menambah stok/AP;
barang damaged diarahkan ke Gudang tipe DAMAGED. UI Goods Receipt belum dibuka.

Manual gate berikutnya: migration → postflight → behavioral test → postflight.
Runbook: `docs/runbooks/G5_PHASE5_GOODS_RECEIPT_FOUNDATION_ROLLOUT.md`.

File Phase 5: migration `20260806040000`, postflight
`g5_phase5_goods_receipt_postflight.sql`, behavioral test
`g5_phase5_goods_receipt_foundation_tests.sql`, dan runbook di atas. Local
evidence: delimiter/parenthesis seimbang, migration checksum
`5cf3db710105eebf12a056831380fdb34b596ecb413f9886ff6bd8c6b5e223f6`,
serta scoped `git diff --check` PASS. Tidak tersedia database lokal untuk
mengeksekusi PL/pgSQL; rollout SQL Editor dan hasil user masih manual gate.
Next safe step setelah seluruh hasil PASS adalah UI PWA Goods Receipt, bukan
Supplier Invoice/Purchase Return/Finance G6.

Behavioral run pertama gagal saat insert receipt line karena trigger history
foundation memakai satu ekspresi `CASE` yang membuat PostgreSQL mencoba
meresolve `NEW.receipt_line_id` pada record `goods_receipt_lines`. Forward fix
`20260806050000_g5_phase5_goods_receipt_history_trigger_fix.sql` menggantinya
dengan cabang `IF/ELSIF` table-specific dan return NEW/OLD yang eksplisit.
Migration foundation yang sudah applied tidak diedit. User harus menjalankan
forward fix, postflight terkoreksi (ledger mengharuskan dua version), behavioral
test, lalu postflight ulang.

Postflight versi ringkas pertama kemudian menghasilkan PostgreSQL `42601
syntax error at end of input` pada SQL Editor. File
`g5_phase5_goods_receipt_postflight.sql` sudah ditulis ulang penuh menjadi satu
CTE `checks` yang eksplisit (267 baris), ditutup satu final SELECT; local check
menunjukkan 102/102 parenthesis, quote genap, dan `git diff --check` PASS.
Gunakan isi file terbaru secara utuh, bukan query lama yang masih terbuka di tab
SQL Editor.

User kemudian mengonfirmasi forward-fix, postflight yang ditulis ulang, serta
behavioral test seluruhnya sukses. Phase 5 database dinyatakan COMPLETE.
Phase 6 menghubungkan PWA online ke tiga RPC canonical: tombol `Terima Barang`
memuat order `CONFIRMED/PARTIALLY_RECEIVED` pada Store sesi, hanya memakai nama
bisnis, menyimpan/resume/cancel Draft, mencatat partial/over, serta membuka field
baik/rusak/ditolak secara opsional. Post menutup modal dan refresh katalog stok.
PWA oxlint dan production build PASS; chunk modal terpisah sekitar 14.44 kB.
Browser in-app tidak berhasil tersambung sebelum membuka localhost, jadi tidak
ada authenticated UI effect yang dijalankan agent. Manual smoke mengikuti
`docs/runbooks/G5_PHASE6_GOODS_RECEIPT_PWA_SMOKE.md`. User kemudian
mengonfirmasi proses receive aman sehingga Phase 6 dinyatakan ACCEPTED. Phase 7
menyiapkan preflight SELECT-only Purchase Return; Supplier Invoice/matching,
payment Supplier, dan jurnal final Finance tetap menunggu urutan roadmap G5/G6.

User mengonfirmasi seluruh output Phase 7 PASS. Phase 8 sekarang local-ready:
migration `20260806070000` menambah dokumen/line Return, exact source allocation
dan Goods Receipt FIFO batch, review wajib sebelum Post, optimistic version,
exact idempotency, immutable final history, Movement `PURCHASE_RETURN`, AP
adjustment append-only, Financial Event `HOLD_UNTIL_G6`, RLS, dan browser
direct-write closure. Approve tidak membutuhkan alasan; reject/cancel wajib
alasan. Source AP `OPEN` memakai route `AP_PROVISIONAL`, sedangkan source yang
sudah matched/reversed dicatat `SUPPLIER_CREDIT_PENDING` tanpa menulis ulang
invoice/history lama. Local evidence: migration 287/287 parenthesis, 14
dollar-tags, satu transaction COMMIT, checksum
`ee1f70903bf45a9d9dcfc4035675f07b9b6b45aa5315f314c9c2c1307e1b22ba`,
dan scoped `git diff --check` PASS. Live migration/postflight/behavior belum
dijalankan. Runbook:
`docs/runbooks/G5_PHASE8_PURCHASE_RETURN_FOUNDATION_ROLLOUT.md`.

Behavioral run pertama berhenti sebelum menguji Return karena fixture membuat
Supplier Order langsung `CONFIRMED` lalu memasukkan line; canonical history
guard benar menolak line pada Order final. Test dikoreksi mengikuti lifecycle
produksi `DRAFT → insert line → CONFIRMED`. Migration tidak berubah dan tidak
perlu diulang; rerun hanya behavioral test terbaru lalu closing postflight.

Migration sudah berhasil dijalankan user. Postflight awal gagal sebelum
menghasilkan row dengan PostgreSQL `42P01 relation "public" does not exist` pada
dynamic table-name privilege lookup. Diagnostic telah dikoreksi memakai
`pg_namespace` + `pg_class.oid` untuk existence, trigger, RLS, dan privilege;
tidak ada migration/data/business-flow yang diubah. Rerun hanya postflight
terkoreksi, lalu behavioral test bila seluruh hasilnya aman.

User melaporkan error yang sama setelah koreksi pertama. Postflight kemudian
ditulis ulang penuh: seluruh `to_regclass`, `to_regprocedure`, dynamic qualified
name, dan signature-text privilege lookup dibuang. Table/routine/trigger kini
di-resolve dari `pg_catalog` ke OID, dan privilege juga diperiksa langsung lewat
OID. File terkoreksi berjumlah 170 baris dan mempunyai marker komentar
`Catalog objects are resolved by OID`; pastikan SQL Editor memuat isi baru ini,
bukan query lama yang masih tersimpan di tab browser.

Rewrite OID tersebut ternyata masih menghasilkan `42P01` pada live SQL Editor.
Postflight kini disederhanakan lagi menjadi metadata-only murni: tidak ada
`FROM/JOIN public.*`, `to_reg*`, `has_*_privilege`, ataupun runtime table read.
Existence/RLS/function body dibaca dari `pg_catalog`; trigger dan grant dibaca
dari `information_schema`. Ini hanya mengubah diagnostic, bukan migration/data.

### Riwayat Phase 54

User menerima Phase 53 dan meminta lanjut sesuai rundown. Phase 54 tidak
membuka mutation: diagnostic SELECT-only mengaudit contract POS-006 bahwa
seluruh saldo lama wajib dipakai, lifecycle `ACTIVE/WIND_DOWN`, cache versus
append-only ledger, Customer/Company scope, internal Payment Method,
category/account, histori tender, runtime defer guard, snapshot gap, dan direct
browser write boundary.

Jalankan
`supabase/diagnostics/g4_phase54_customer_balance_tender_preflight.sql` penuh
dan kirim seluruh output. `SETUP` di ledger source, Payment snapshot, serta
runtime diharapkan; `BLOCKER` harus nol dan `REVIEW` harus dijelaskan sebelum
foundation. Balance tender, refund-to-balance, Offline Customer Balance, Ketul,
dan Finance posting tetap tertutup.

### Riwayat Phase 53

User mengonfirmasi seluruh rollout/regression Phase 52 PASS. Phase 53
menghubungkan kontrak itu ke checkout PWA: pilihan baru hanya muncul ketika
Cash/Transfer yang diterima melebihi bagian tagihan. Default tetap
`Kembalikan ke Customer`; `Simpan sebagai Saldo` hanya aktif untuk Customer
reguler, POS online, serta feature/policy Customer Balance aktif. Receipt modal
dan print tab menampilkan credit saldo secara terpisah.

Tidak ada migration Phase 53. Customer Balance sebagai tender,
refund-to-balance, Offline Customer Balance, exceptional settlement, dan jurnal
G6 tetap tertutup. Manual gate berikutnya adalah authenticated smoke sesuai
`docs/runbooks/G4_PHASE53_POS_OVERPAYMENT_DISPOSITION_UI.md`. Setelah smoke
lulus, next safe step adalah preflight khusus balance-as-tender—bukan langsung
membuka mutation baru.

Local evidence: `npm.cmd run lint` PASS; `npm.cmd run build` PASS termasuk
TypeScript/Vite/PWA service worker. Warning chunk utama di atas 500 kB tetap
warning existing dan tidak memblokir build.

### Riwayat Phase 52

User mengonfirmasi seluruh Phase-51 data invariant PASS; tiga status `SETUP`
tepat menunjukkan kolom Payment, ledger source, dan runtime credit yang belum
ada. Phase 52 sekarang menambahkan jalur atomic dari overpayment Payment/Sale
ONLINE ke append-only ledger, Customer cache, Payment/receipt snapshot, audit,
dan Financial Event HOLD. Sale row serta Customer row dikunci; retry memakai
source/idempotency unik dan tidak menggandakan stock atau saldo.

Compatibility sengaja ketat: histori Cash change tetap nullable/legacy dan
dianggap sudah dikembalikan; Cash payload baru tanpa pilihan Phase-53 otomatis
`RETURNED`; non-Cash overpayment tanpa disposition ditolak. Customer harus
regular aktif, feature serta policy harus `ACTIVE`, dan request credit Offline
ditolak. Payment Method `CUSTOMER_BALANCE` belum dibuka sebagai tender.

File Phase-52:

- `supabase/migrations/20260805130000_g4_phase52_customer_balance_sale_credit.sql`;
- `supabase/diagnostics/g4_phase52_customer_balance_sale_credit_postflight.sql`;
- `supabase/tests/g4_phase52_customer_balance_sale_credit_tests.sql`;
- `docs/runbooks/G4_PHASE52_CUSTOMER_BALANCE_SALE_CREDIT_ROLLOUT.md`.

Local evidence: migration/postflight/test parentheses seimbang, dollar tags
seimbang, postflight SELECT-only, checksum manifest `e44a9f66...` tercatat, dan scoped
`git diff --check` PASS. Live Supabase rollout/regression belum dijalankan.

### Riwayat Phase 50

Phase 49 sudah ditutup user seluruhnya sukses. Backoffice sekarang mempunyai
menu `Finance > Saldo Customer` dengan total liability, saldo per Customer,
statement append-only, pengajuan koreksi, dan approval/penolakan oleh reviewer
berbeda. UUID serta key akun disembunyikan; user memilih label bisnis. Semua
mutation memakai RPC Phase 49, optimistic version, dan idempotency key.

File Phase-50:

- `backoffice/src/lib/customer-balance.ts`;
- `backoffice/src/app/api/finance/customer-balances/**`;
- `backoffice/src/components/CustomerBalanceView.tsx`;
- integrasi menu pada `backoffice/src/app/page.tsx`;
- `docs/runbooks/G4_PHASE50_CUSTOMER_BALANCE_OPERATIONAL_UI.md`.

Local evidence: Backoffice lint PASS, production build PASS (empat route baru),
dan scoped diff check PASS. Manual gate aktif adalah authenticated role/
maker-checker smoke Phase 50. Entry koreksi Cashier pada PWA, export/aging,
checkout/refund/offline Customer Balance, exceptional settlement, dan jurnal G6
belum dibuka oleh UI ini.

### Riwayat Phase 49

User mengonfirmasi Phase-48 tanpa blocker/error; hanya satu provisioning
Company berstatus BACKFILL. Migration `20260805090000` sekarang local-ready dan
tetap berhenti bila saldo nonzero atau histori Customer Balance payment muncul
setelah preflight. Foundation memprovision satu policy serta metode internal
`Saldo Customer` per Company, menjaga lifecycle `ACTIVE -> WIND_DOWN ->
DISABLED`, dan menyimpan ledger append-only sebagai authority sementara
`customers.current_balance` menjadi cache yang direkonsiliasi.

Cashier/operasional hanya dapat membuat request koreksi melalui RPC guarded;
Finance/Owner/Admin/Super Admin mereview dengan maker-checker. Approval membuat
tepat satu ledger entry, update cache atomic, audit, dan Financial Event `HOLD`;
reject tidak mempunyai final effect. Statement tenant-scoped tersedia read-only.
Canonical Sale tetap fail-closed terhadap `CUSTOMER_BALANCE`; overpayment,
refund-to-balance, Ketul credit/offset, exceptional settlement, offline use, dan
jurnal G6 belum dibuka.

File Phase-49:

- `supabase/migrations/20260805090000_g4_phase49_customer_balance_foundation.sql`;
- `supabase/diagnostics/g4_phase49_customer_balance_postflight.sql`;
- `supabase/tests/g4_phase49_customer_balance_foundation_tests.sql`;
- `docs/runbooks/G4_PHASE49_CUSTOMER_BALANCE_FOUNDATION_ROLLOUT.md`;
- `supabase/MIGRATION_MANIFEST.md`, root `README.md`, router/gate/handoff docs.

Local evidence: SHA-256 migration
`63a4bdbc7d27983879d3f9d402b7ca84b5fa0f85aa3e2303b7717659a4ee9b82`;
scoped `git diff --check` PASS. Base migration sudah applied, sedangkan complete
behavior/regression masih menunggu forward fix berikut.

Base migration kemudian berhasil applied. Behavioral test pertama diperbaiki
karena synthetic Company belum mempunyai row entitlement. Rerun berikutnya
berhenti sebelum request insert pada `digest(text,unknown)`: Supabase memasang
pgcrypto pada schema `extensions` dan menyediakan `digest(bytea,text)`.
Forward migration `20260805100000` mengganti RPC dengan
`extensions.digest(convert_to(...,'UTF8'),'sha256')`; tidak mengubah data,
saldo, policy, atau business flow. SHA-256 forward fix
`f607b3a0162452a63fcc2da4d81332ec3e392e9583600c1c28a3510f8476d3a8`.
User kemudian mengonfirmasi seluruh rangkaian sukses.

User mengonfirmasi seluruh manual rollout Phase-46 aman. Jangan rerun migration
`20260804160000`. Phase-47 tidak menambah schema: halaman
`Finance > Selisih Setoran` membaca exception, Setoran, allocation, request,
Store, dan actor dengan query tenant-scoped terpisah, lalu memakai guarded RPC
Phase-46 untuk seluruh mutation. Finance/Owner/Admin dapat menangani selisih;
Owner/Admin lain mereview request maker-checker; Accounting hanya membaca.

UI menyembunyikan UUID, menggunakan custom modal dan Escape, mempertahankan
optimistic version serta exact idempotency, dan menunjukkan dengan eksplisit
bahwa Financial Event masih HOLD. Bank matching, reversal/replacement source
aktual, Offline Expense/Deposit, internal cash transfer, dan jurnal G6 tidak
dibuka oleh phase ini.

Phase-26 database behavior dan seluruh regression sudah ditutup user. User
berhasil membuat Draft melalui Phase-27 PWA dan mempostingnya melalui Phase-28
Backoffice. Sales Return selesai pada boundary approval REQUIRED. Posting Kasir,
approval OPTIONAL, dan Finance journal tetap tertutup.

Phase-29 diterima tanpa blocker dan Phase-30 database/postflight/behavior/
regression sudah dikonfirmasi user seluruhnya PASS. Phase-31 local-ready
membuka entry point Expense online hanya ketika `expense_enabled` aktif. PWA
mengirim idempotent Draft lalu guarded Submit dengan kategori, metode eligible,
nominal, responsible party, deskripsi, target settlement, dan external evidence
link. `SUBMITTED` menunggu approval; auto-`APPROVED` tetap belum mencairkan
uang. Retained offline catalog sengaja tidak memuat Expense.

Cash Advance tidak menjadi domain baru; canonical flow tetap requested/
disbursed/actual/returned/outstanding. Pada boundary ini tidak ada pencairan,
perubahan `expected_cash`, Cash In, Stock Movement, atau jurnal final.

User mengonfirmasi pengajuan Expense Phase-31 berhasil. Phase-32 local-ready
menambahkan `Finance > Approval Expense` untuk list/detail, guarded approve,
reject beralasan, dan cancel sesuai authority. Accounting dapat membaca tetapi
tidak menyetujui; Store Manager/Owner/Admin/Finance/Super Admin mengikuti guard
server. Semua aksi pada fase ini tetap cash-neutral.

User mengonfirmasi approval Phase-32 aman. Phase-33 hanya membuka diagnostic
SELECT-only untuk menilai Expense `APPROVED`, metode dan Store scope, open
Cashier Session untuk Cash, account/category, snapshot approval, enum/RPC
Financial Event, Cash Drawer Movement, expected-cash calculator, privilege,
dan reconciliation. Belum ada RPC pencairan atau perubahan uang pada fase ini.

User mengirim output Phase-33 tanpa blocker: empat runtime gap tepat `SETUP`,
seluruh invariant live `PASS`, dan terdapat dua Expense approved—Cash serta
non-Cash. Phase-34 local-ready menambahkan schema snapshot dan guarded RPC
`disburse_expense`: amount/method berasal dari dokumen approved, Cash wajib
Session OPEN dengan expected drawer cukup dan satu movement OUT, non-Cash hanya
Finance/Admin tanpa drawer effect, retry exact idempotent, audit immutable, dan
Financial Event `HOLD`. Dokumen live tidak dicairkan otomatis oleh migration.

User mengonfirmasi seluruh rollout/regression/closing Phase-34 aman. Phase-35
sekarang local-ready tanpa migration baru. PWA mempertahankan satu menu
`Expense` dan menambahkan tab `Cairkan Tunai`: hanya dokumen `APPROVED + CASH`
Store aktif yang tampil; nominal/metode read-only; Session dan drawer effect
tetap divalidasi RPC; retry memakai satu idempotency key; expected cash hasil
server diperbarui pada state sesi. Backoffice `Finance > Approval Expense`
menambahkan konfirmasi Transfer/non-Cash untuk Super Admin, Owner/Admin, dan
Finance. Route server menolak Cash, Accounting/Store Manager tidak mendapat
action, dan pembayaran non-Cash tidak membuat Drawer Movement. Settlement,
return, additional disbursement, Cash In, Offline Expense, Deposit, dan jurnal
G6 tetap tertutup.

User mengonfirmasi Phase-35 aman. Phase-36 hanya menambahkan diagnostic
SELECT-only: rekonsiliasi total dokumen dengan detail append-only, validitas
lifecycle `DISBURSED/PARTIALLY_SETTLED/SETTLED`, coverage Financial Event dan
Cash drawer untuk histori, readiness category account/sesi Cash return,
outstanding aging, privilege boundary, serta inventaris gap schema/enum/RPC.
Belum ada actual settlement, return funds, additional disbursement, atau Cash
In yang dapat dieksekusi pada fase ini.

User mengirim output Phase-36 tanpa blocker/review: lima runtime gap tepat
`SETUP`, semua invariant `PASS`, direct browser write tertutup, dan tidak ada
history settlement/return yang membutuhkan backfill. Phase-37 local-ready
menambahkan request actual yang cash-neutral sampai direview, approved actual
dan return immutable, Cash return sebagai Cash In + drawer `IN`, non-Cash
drawer isolation, outstanding lifecycle, idempotency, Finance `HOLD`, dan
additional disbursement request-only tanpa cash effect. Execution additional,
UI settlement, Offline Expense, correction/reversal, Deposit, dan G6 masih
tertutup.

User mengonfirmasi rollout dan seluruh regression Phase-37 aman. Phase-38
tidak menambah schema: PWA menambahkan tab `Penyelesaian` untuk request biaya
aktual, return Cash pada Session aktif, dan request dana tambahan. Backoffice
menampilkan request aktual untuk approve/reject serta menerima return non-Cash
untuk Finance/Owner/Admin. Actual tetap cash-neutral sebelum review, return
Cash memperbarui expected cash, return non-Cash tidak menyentuh drawer, dan
additional disbursement tetap request-only. Lint/build kedua aplikasi PASS.

User melanjutkan tanpa melaporkan error Phase-38. Operational UI ditutup
`COMPLETE`. Phase-39 menahan Deposit dan mengaudit additional disbursement yang
masih request-only melalui diagnostic SELECT-only: lifecycle/data/reference,
zero cash effect, approval/execution schema dan RPC gap, event enum, Session
Cash readiness, privilege, serta inventory. Tidak ada mutation pada fase ini.

User mengirim seluruh output Phase-39: tidak ada blocker/review; seluruh
dependency, tenant/reference, zero cash effect, document/payment/Session,
duplicate-open, dan privilege check `PASS`. Inventory request masih nol.
Expected `SETUP` hanya enum event, enam lifecycle column, dan dua RPC.

Phase-40 sekarang `COMPLETE`. Migration
`20260804100000` menambahkan guarded review/reject dan execution additional
Expense. Review tetap cash-neutral. Cash wajib Session `OPEN`, expected cash
cukup, dan satu immutable drawer `OUT`; non-Cash hanya Finance/Admin tanpa
drawer. Setiap request hanya dapat terhubung ke satu disbursement, retry exact
idempotent mengembalikan snapshot expected cash yang sama, document totals dan
outstanding diperbarui atomic, audit ditulis, dan Financial Event tetap `HOLD`.
User mengonfirmasi corrected behavioral test sukses setelah fixture Company B
mengaktifkan Expense untuk mencapai negative tenant guard yang dimaksud.
Migration, postflight, database behavior, regression Phase-37/34/30/2/G1, dan
closing postflight seluruhnya dikonfirmasi user berhasil. Migration tidak
memproses request existing secara otomatis.

Phase-41 local-ready membuka UI tanpa schema baru. Backoffice menampilkan
riwayat request tambahan per dokumen, mereview `SUBMITTED`, dan membayar
`APPROVED` non-Cash. Route server menolak request Cash. POS memuat request Cash
approved pada Store aktif dan mencairkannya memakai Session aktif; expected
cash diambil dari hasil server. Nominal dan metode read-only, approval tetap
cash-neutral, dialog custom mendukung Escape, dan seluruh mutation memakai
version/idempotency RPC Phase-40. Offline Expense, correction/reversal,
Deposit, Purchasing G5, dan jurnal G6 tetap tertutup.

File utama Phase-40:

- `supabase/migrations/20260804100000_g4_phase40_additional_expense_disbursement.sql`;
- `supabase/diagnostics/g4_phase40_additional_expense_disbursement_postflight.sql`;
- `supabase/tests/g4_phase40_additional_expense_disbursement_tests.sql`;
- `docs/runbooks/G4_PHASE40_ADDITIONAL_EXPENSE_DISBURSEMENT_ROLLOUT.md`;
- `docs/runbooks/G4_PHASE41_ADDITIONAL_EXPENSE_OPERATIONAL_UI.md`;
- `backoffice/src/components/ExpenseApprovalView.tsx` dan route
  `expense-additional-requests/[id]/{review,disburse}`;
- `pwa/src/ExpenseSettlementPanel.tsx` dan `pwa/src/lib/pos.ts`;
- update manifest, root README, router, implementation gates, dan handoff.

Evidence Phase-41 lokal: Backoffice ESLint + production build PASS; PWA oxlint
+ TypeScript/Vite/PWA production build PASS. Manual gate berikutnya adalah
authenticated Cash/non-Cash/reject/effect smoke pada runbook Phase-41.

User kemudian meminta lanjut tanpa melaporkan blocker Phase-41. Sesuai POS-008,
Phase-42 membuat preflight SELECT-only untuk Setor Kas multi-sesi. Query
menginventarisasi legacy `bank_deposits`, sesi `CLOSED`, actual closing cash,
duplicate allocation, legacy event/trigger, Transaction Category
`CASH_DEPOSIT`, enam account function, browser write boundary, serta gap enam
table dan empat RPC canonical. Tidak ada DDL/DML, Deposit UI, variance
resolution, bank matching, atau Finance posting yang dibuka.

File utama Phase-42:

- `supabase/diagnostics/g4_phase42_cash_deposit_preflight.sql`;
- `docs/runbooks/G4_PHASE42_CASH_DEPOSIT_PREFLIGHT.md`.

User mengonfirmasi seluruh hasil live Phase-42 aman. Phase-43 database kemudian
di-rollout dan seluruh postflight, behavior, regression, serta closing check
dikonfirmasi PASS. Migration `20260804130000` menambahkan
enam tabel canonical, policy proof company/store, guarded list/save/submit/
review/cancel RPC, deterministic lock beberapa Session `CLOSED`, expected cash
server-authoritative, optimistic version, exact create/submit/review retry,
immutable audit, variance exception awal, dan Financial Event `HOLD`.

File utama Phase-43:

- `supabase/migrations/20260804130000_g4_phase43_cash_deposit_foundation.sql`;
- `supabase/diagnostics/g4_phase43_cash_deposit_postflight.sql`;
- `supabase/tests/g4_phase43_cash_deposit_foundation_tests.sql`;
- `docs/runbooks/G4_PHASE43_CASH_DEPOSIT_FOUNDATION_ROLLOUT.md`.

Phase-44 membuka operational UI tanpa schema baru. PWA menyediakan Setor Kas
meskipun Session aktif sudah ditutup, memilih beberapa Session `CLOSED`, saldo
sesi berikutnya, tujuan Bank/Brankas, nominal aktual, bukti, serta guarded
Save+Submit. Backoffice menambahkan `Finance > Setor Kas` untuk list/detail per
sesi dan guarded Approve/Reject. Accounting read-only; Approve hanya Super
Admin/Owner/Admin/Finance. UUID tidak ditampilkan sebagai identitas dokumen.

File utama Phase-44:

- `pwa/src/CashDepositModal.tsx`, `pwa/src/App.tsx`, dan `pwa/src/lib/pos.ts`;
- `backoffice/src/components/CashDepositApprovalView.tsx`;
- `backoffice/src/app/api/finance/cash-deposits/**`;
- `docs/runbooks/G4_PHASE44_CASH_DEPOSIT_OPERATIONAL_UI.md`.

Evidence lokal: PWA lint/build PASS; Backoffice lint/build PASS dan route API
terdeteksi pada production build. User mengonfirmasi jalur approval aman setelah
optional reason bugfix. Phase-45 menambahkan preflight SELECT-only untuk
exception source/amount/type, lifecycle, responsible party, allocation
reconciliation, account mapping, maker-checker, runtime/event gap, dan browser
boundary. Bank matching, variance allocation/resolution mutation, Offline
Deposit, correction/reversal, dan journal G6 tetap tertutup.

File utama Phase-45:

- `supabase/diagnostics/g4_phase45_deposit_variance_resolution_preflight.sql`;
- `docs/runbooks/G4_PHASE45_DEPOSIT_VARIANCE_RESOLUTION_PREFLIGHT.md`.

User mengirim output live Phase-45 seluruhnya aman: dependency, source,
amount/lifecycle, responsible party, allocation reconciliation, account
catalog, privilege, dan coverage `PASS`; satu Deposit approved berstatus
matched dan history exception/allocation masih nol. Phase-46 local-ready
menambahkan penetapan responsible party, partial append-only resolution,
maker-checker untuk loss/income/source correction, exact idempotency,
cross-Company guard, immutable audit, dan Financial Event `HOLD`.

File utama Phase-46:

- `supabase/migrations/20260804160000_g4_phase46_deposit_variance_resolution.sql`;
- `supabase/diagnostics/g4_phase46_deposit_variance_resolution_postflight.sql`;
- `supabase/tests/g4_phase46_deposit_variance_resolution_tests.sql`;
- `docs/runbooks/G4_PHASE46_DEPOSIT_VARIANCE_RESOLUTION_ROLLOUT.md`.

Verification lokal terbatas pada static SQL/diff karena PostgreSQL lokal tidak
tersedia. Migration, postflight, behavior, dan regression live masih menunggu
user. Tidak ada data live yang dimutasi oleh agent.

Online checkout, split Payment, true-concurrent Post, Offline Stock Allowance,
dan canonical Offline Sale Sync database telah dikonfirmasi sukses termasuk
regression serta reconciliation penutup.

User menutup Phase-23 preflight dengan seluruh kontrak server, browser boundary,
identity/lifecycle/idempotency, retry/status recovery, final-effect coverage,
scope UAT, stale sync, serta Stock–Movement–FIFO `PASS`. Client contract
expected `SETUP` kemudian diimplementasikan tanpa migration.

Dexie v5 menambah retained operational scope yang hanya ditulis setelah
snapshot authoritative sukses. Cold-start memerlukan cached Supabase Session
dengan `user.id` sama serta exact Company–Store–Terminal–Gudang–Session–
Cashier. Snapshot integrity, katalog, allowance, dan queue dipulihkan;
reconnect menetapkan active Company lalu menjalankan status-first recovery
sebelum retry. `SYNCING/NEEDS_CONFIRMATION` tidak auto-process dan `FAILED`
memerlukan aksi Kasir. Logout/close Session menginvalidasi snapshot dan
menghapus scope. Authenticated tablet UAT masih menunggu user.

Artifact Phase-13 local-ready:

- `pwa/src/lib/db.ts`;
- `pwa/src/lib/offline.ts`;
- `docs/runbooks/G4_PHASE13_OFFLINE_PWA_QUEUE_FOUNDATION.md`.

Dexie v3 menambah retained queue terpisah dari tabel legacy. Record menyimpan
payload, hash, client transaction ID, posting key, submission ID, attempt,
status, error, dan acknowledgement. Retry tidak membuat identity baru dan
response `POSTED` tidak menghapus record lokal. Adapter hanya memakai RPC
canonical browser-scoped; direct table write dan service-role tidak dibuka.
Keranjang, cache catalog/pricing/Tax, allowance lokal, Slip Offline, serta
entitlement activation masih tertutup sampai gate berikutnya.

Live Phase-14 preflight diterima bersih. Dependency Phase-12, Product-UOM,
Pricelist, Tax, Payment, submission, entitlement, dan browser boundary sesuai
kontrak. Snapshot RPC belum ada dan satu open Session belum memiliki Terminal
policy; keduanya tepat berstatus `SETUP`. Terminal eligibility tidak boleh
dibuat otomatis.

Migration `20260730010000` sekarang local-ready. RPC snapshot hanya menerima
actor pemilik Session `OPEN` pada active Company dan Terminal yang eligible,
lalu mengembalikan Product-UOM, base price, Pricelist/rule, Sales Tax metadata,
Payment Method, stock Gudang, dan active allowance pada satu timestamp.
Migration tidak mengaktifkan entitlement dan belum menghubungkan Keranjang PWA
ke checkout Offline.

User kemudian mengonfirmasi migration, postflight, corrected behavior, seluruh
regression Phase-12/11/4/G1, dan closing postflight Phase-14 aman. Database
snapshot sekarang `COMPLETE`; `terminal_policy_configuration_scope = SETUP`
tetap benar karena Offline belum diaktifkan.

Phase-15 menambah `offline_catalog_snapshots` pada Dexie v4 dan adapter
`pwa/src/lib/offlineCatalog.ts`. Refresh hanya melalui RPC canonical Phase-14,
response harus cocok dengan exact Company/Store/Terminal/Gudang/Session/Cashier,
dan payload disimpan bersama canonical JSONB SHA-256. Read memverifikasi hash,
version, optional caller-defined freshness, serta explicit invalidation tanpa
menghapus history. Local allowance dikurangi seluruh retained queue pada
catalog version yang sama, termasuk queue `POSTED` sampai snapshot baru
diambil. Keranjang dan tombol bayar Offline masih tertutup.

Phase-16 menambahkan menu read-only setelah Session terbuka: tombol `Offline`
pada header membuka drawer status koneksi,
Terminal/Gudang/Session user-facing, snapshot timestamp/age, jumlah Product
allowance, local available per Product, serta refresh online. Refresh error
feature/policy tampil pada drawer dan tidak mencemari error transaksi global.
Close Session/logout menginvalidasi cache tanpa delete; kegagalan IndexedDB
tidak menutupi close server yang sudah sukses. Library Dexie/cache di-lazy-load
setelah Session: build membagi main JS `471.65 kB` dan Offline chunk
`102.84 kB`, tanpa chunk warning.

Phase-17 menambahkan konfigurasi Backoffice di `Pengaturan Modul` →
`Point of Sale`. Super Admin tetap satu-satunya role yang dapat mengubah
entitlement. Pemilik/Admin Perusahaan dapat mengubah default Company, override
Toko, dan eligibility Terminal; Store Manager hanya melihat/mengubah Toko serta
Terminal assignment. API memakai authenticated active Company dan mutation
seluruhnya melalui `save_pos_offline_allowance_policy(...)`; tidak ada direct
table write. Konfirmasi memakai modal custom dan dapat ditutup dengan Escape.
Backoffice lint, TypeScript, serta production build PASS. Authenticated role
smoke Phase-17 dan closed-entitlement smoke Phase-16 masih menunggu user.

Atas permintaan eksplisit user, Phase-18 menambah create Customer dasar langsung
dari checkout POS. `quick_create_pos_customer(...)` tidak menerima Company dari
client; active Company dan Cashier Session `OPEN` actor menentukan tenant.
Kode dibuat otomatis, kategori dipilih dari kategori aktif Company, credit dan
balance selalu nol, parent/default Pricelist selalu kosong, serta audit CREATE
wajib tercatat. Direct Customer table write browser tetap tertutup.

PWA menampilkan tombol `Customer baru`, modal custom yang dapat ditutup dengan
Escape, nama active Company read-only, dan otomatis memilih Customer setelah
refresh katalog. PWA dan Backoffice kini menyembunyikan dropdown Company bagi
user satu Company dan hanya menampilkannya bagi user multi-Company. Backoffice
Customer API sebelumnya sudah benar memakai `requireActiveCompany` dan RPC
guarded; tidak ada perubahan authority API.

Local evidence Phase-18: PWA oxlint PASS, PWA TypeScript/Vite production build
PASS (`478.29 kB` main gzip `134.70 kB`; Offline chunk `102.84 kB` gzip
`33.59 kB`), Backoffice ESLint PASS, dan Next.js production build PASS.
Migration, postflight, dan behavioral test kemudian dikonfirmasi sukses oleh
user; visual tenant smoke dapat diulang sesudah restart bila diperlukan.

User kemudian mengonfirmasi seluruh Phase-18 sukses. Migration `20260730040000`
tidak boleh dijalankan ulang atau diedit. Postflight dan rollback-safe
behavioral test PASS; RPC active-Company/open-Session, automatic code, safe
Customer contract, audit, uniqueness, serta browser write boundary sekarang
`COMPLETE`. Authenticated visual smoke selector satu/multi-Company tetap dapat
diulang setelah restart bila diperlukan, tetapi bukan blocker database.

Phase-19 kemudian menambah operasional allowance pada Backoffice tanpa schema
atau migration baru. `GET/POST /api/platform/offline-allowances` memerlukan
authenticated active Company serta role Super Admin, Company Owner/Admin, atau
Store Manager. GET mengembalikan hanya Session `OPEN`, Product-stock, allowance,
dan referensi yang lolos RLS. POST hanya meneruskan issue/release/force-revoke
ke RPC Phase-11; tidak ada direct table mutation.

`OfflineAllowanceOperations` tersedia pada `Pengaturan Modul` → `Point of
Sale`. UI memakai nama Product/UOM/Toko/Terminal/Gudang/Kasir, menghitung
preview hanya sebagai informasi, dan menjelaskan jumlah final selalu dihitung
server. Force-revoke memakai modal custom, alasan wajib, Escape close, serta
optimistic version. Entitlement disabled memblokir issuance tetapi allowance
lama tetap dapat direview/release/revoke.

Local evidence Phase-19: Backoffice ESLint PASS; TypeScript/Next.js production
build PASS dan route `/api/platform/offline-allowances` terdaftar. Browser
connector gagal tersedia pada environment agent, sehingga authenticated visual
UAT belum diklaim. Checkout Offline, PWA cart, dan queue execution tidak
diubah.

Phase-20 menambah kontrol Cashier pada drawer `Offline` PWA. Cashier dapat
meminta allowance untuk Product stok eligible pada Session miliknya dan
melepaskan allowance sendiri bila belum consumed serta tidak dipakai retained
queue. Jumlah tidak pernah berasal dari input client; PWA hanya memanggil RPC
Phase-11 lalu merefresh snapshot authoritative Phase-14. UI menampilkan server
remaining, local queued, dan local available. Jika mutation berhasil tetapi
refresh/reconciliation gagal, cache lama di-invalidasi agar angka stale tidak
tetap dianggap aman. Force revoke tetap hanya pada Backoffice.

Local evidence Phase-20: PWA oxlint PASS; TypeScript/Vite production build dan
service-worker generation PASS. Browser connector kembali gagal tersedia pada
environment agent, jadi authenticated tablet smoke belum diklaim. Tidak ada
migration/schema change dan checkout Offline tetap closed.

Phase-21 live output sudah ditutup: seluruh invariant `PASS`, sedangkan
`offline_checkout_uat_scope=SETUP` expected karena entitlement, Terminal,
allowance, dan disposable open Session belum diaktifkan.

Phase-22 menghubungkan Cart ke retained queue tanpa migration. Saat koneksi
putus setelah Session/snapshot tersedia, harga dihitung dari resolver Pricelist
snapshot yang mengikuti selection AUTO/override server, discount dan rounding
Rp100 dihitung lokal, kebutuhan Product diagregasi ke Base UOM, lalu Payment
harus exact-total dan eligible. Payload/hash/catalog version/idempotency
disimpan lebih dulu di Dexie; hanya setelah local commit sukses Cart direset dan
Slip Offline ber-watermark ditampilkan. Drawer menyediakan retry, status check
untuk state ambigu, retained error/acknowledgement, serta invoice final setelah
`POSTED`.

Fail-closed tetap berlaku untuk cache/scope invalid, allowance kurang, Product
Bundle, TEMPO, Payment/reference snapshot tidak valid, dan direct table write.
Cold-start penuh tanpa network belum termasuk Phase-22. Authenticated tablet
UAT Phase-20/22 masih menunggu user.

Riwayat integrasi online yang mendasari phase aktif:

Smoke login pertama menemukan `Failed to fetch`. Root cause terverifikasi bukan
password/RLS: `pwa/.env` masih berisi URL dan key placeholder, sedangkan
`backoffice/.env.local` mempunyai konfigurasi publik yang valid. Vite PWA
sekarang fallback hanya ke `NEXT_PUBLIC_SUPABASE_URL` dan public publishable
key Backoffice ketika nilai PWA placeholder; deployment tetap membutuhkan
`VITE_*`. `supabase.ts` juga menolak konfigurasi kosong/placeholder dengan pesan
yang actionable. PWA lint/build PASS dan inspeksi bundle membuktikan URL/public
key aktif terpasang serta service-role key tidak ikut. Manual gate: restart
proses PWA, login ulang, lalu lanjutkan smoke; user tetap perlu assignment
Cashier/Store/Terminal yang valid setelah Auth berhasil.

Setelah login berhasil, PWA masih menampilkan Terminal/Gudang kosong untuk akun
Admin. Audit membuktikan ini bukan schema-cache atau data Backoffice: PWA dan
`open_cashier_session(...)` hanya menerima Store role persis `CASHIER`,
sedangkan spesifikasi menyatakan Super Admin serta Company Owner/Admin
mewarisi aksi Cashier. Forward migration `20260729080000` memperbaiki predicate
server tanpa melewati active Company/Terminal/Gudang/single-session guard.
PWA memakai role aktif yang sama untuk menampilkan Terminal. Provisioning
Cashier biasa di Backoffice sekarang mewajibkan Toko. Local PWA dan Backoffice
lint/build PASS; manual migration, 4-check postflight, behavior, regression,
restart, dan authenticated smoke masih menunggu user.

User berikutnya menguji akun `STORE_MANAGER` yang sudah di-assign ke Toko dan
tetap mendapat Terminal/Gudang kosong. Root cause: fix sebelumnya hanya
Super/Admin inheritance, sedangkan PWA dan RPC belum memasukkan Store Manager
walau role matrix menyatakan Store Manager boleh checkout bila memakai POS.
Migration forward `20260729090000`, postflight, behavior cross-Store negative,
dan PWA filter sudah local-ready. Store Manager hanya memperoleh Terminal pada
Store membership aktif; Gudang tetap wajib sale-source dan Store-compatible.
PWA lint/build PASS. Manual rollout kedua fix berurutan, regression, restart,
dan smoke masih menunggu user.

Sesudah restart, Backoffice user melaporkan `INVALID_SESSION`. Migration
Cashier tidak menyentuh Auth; root cause pada bootstrap UI adalah session object
lokal tetap dianggap aktif walaupun `/api/me/context` sudah menolak access
token. Catch khusus sekarang menjalankan local sign-out, membersihkan context,
dan mengembalikan UI ke Login. Backoffice lint dan production build PASS.
Manual gate: restart/refresh sekali, login ulang; bila browser masih memuat
bundle lama, hard refresh atau hapus site data localhost. Jangan mengubah
Auth user/password atau migration database untuk menangani token client ini.

User kemudian mengonfirmasi Terminal dan Gudang penjualan sudah terbaca. Empat
closure PWA berikut telah dibuat: layout tablet-first, cart/form langsung
direset setelah transaksi `POSTED`, receipt dibuka sebagai halaman print di tab
baru, serta pemilihan Pricelist di bawah Customer dengan mode otomatis dan
override Kasir. Migration forward `20260729100000` menambah wrapper guarded dan
resolver server-side; pilihan eksplisit hanya menerima Pricelist aktif yang
berlaku pada Store serta Global atau milik Customer terpilih. Bridge checkout
Backoffice memakai wrapper yang sama, sedangkan signature RPC lama dipertahankan
untuk kompatibilitas AUTO. PWA dan Backoffice lint/build PASS. Migration,
postflight, behavior/regression, hard refresh, dan tablet smoke masih menunggu
user. Browser preview connector gagal attach pada sesi ini sehingga belum ada
evidence visual otomatis; verifikasi visual harus dilakukan pada smoke manual.

Review user terhadap versi tablet pertama menyatakan hierarchy, keterbacaan,
dan affordance tombol masih terlalu lemah. PWA kemudian disusun ulang mengikuti
pola umum Moka-like tablet POS tanpa menyalin aset/brand: katalog/Product grid
dominan di kiri, Order panel tegas di kanan, header putih, tiga tahap form
bernomor, Total berkontras tinggi, category tab rectangular, Product add control
solid, serta action Draft/Post besar dan sticky. Kontras label/input/tombol
diperkuat dan icon-only Printer/Keluar mendapat label pada viewport yang cukup.
Tidak ada dependency visual baru. PWA lint dan production build PASS; visual
authenticated tablet smoke masih menunggu user karena browser preview connector
tidak dapat attach pada sesi ini.

User meminta pekerjaan diteruskan sampai terbentuk satu relasi stok aktual yang
bisa dipakai menguji Minimum Stock. Boundary aman pertama sudah dibuat sebagai
diagnostic SELECT-only:

- `supabase/diagnostics/g3_phase1_opening_stock_preflight.sql`;
- `docs/runbooks/G3_PHASE1_OPENING_STOCK_PREFLIGHT.md`.

Preflight mengaudit dependency G2, Base UOM Product aktif, pasangan
Product-Gudang eligible, konsistensi saldo terhadap movement, FIFO remaining,
Finance function `INVENTORY_ASSET`/`OPENING_BALANCE_CLEARING`, Transaction
Category `STOCK_OPENING`, enum, serta schema Opening Stock yang belum tersedia.
File ini tidak membuat saldo, movement, batch, event, atau dokumen.

Live preflight, migration `20260728120000`, postflight, behavioral test, dan
regression sudah ditutup sukses oleh user. Database menyediakan Draft/Posted
Opening Stock, guarded role boundary, atomic movement/balance/FIFO, event
Finance `HOLD`, audit, idempotency, serta hard guard prior movement.

Backoffice sekarang menyediakan menu `Inventory > Stok Awal`, Draft yang belum
mengubah saldo, konfirmasi Posting final, dan detail bukti stok aktual,
movement, serta FIFO. Seluruh referensi menampilkan nama Product, Gudang, dan
Base UOM; UUID tetap internal. Manual gate aktif mengikuti
`docs/runbooks/G3_PHASE2_OPENING_STOCK_API_UI.md`.

Follow-up read model sudah ditambahkan setelah user menemukan saldo belum
terlihat: `Produk & Stok` membaca saldo aktual total/per Gudang, sedangkan
`Minimum Stock` membandingkan saldo aktual terhadap batas dan menandai
`Stok menipis` bila notifikasi aktif serta `actual <= minimum`. Ini adalah
indikator saat halaman dimuat/refresh, belum push/background notification.

Audit ulang roadmap mengonfirmasi struktur resmi: Stock Real merupakan halaman
operasional utama di Inventory; Minimum Stock hanya konfigurasi; Stock Movement
adalah halaman ledger read-only berikutnya; notice Cashier/inbox/Stock Request
baru G4 dan Purchasing baru G5. Karena itu menu `Produk & Stok` dikoreksi
menjadi `Produk & UOM`, dan `Inventory > Stock Real` dibuat terpisah dengan
On Hand, Reserved explicit belum aktif, Available sementara sama dengan On
Hand, nilai FIFO, threshold, movement terakhir, serta filter Gudang/menipis.

Audit langkah Kartu Stok menemukan schema `stock_movements` existing belum
menyimpan seluruh minimum contract: actor, Base UOM snapshot, status,
source-line identity, notes, dan balance-after. Karena field audit tidak boleh
ditebak dari UI, boundary aktif dipindahkan ke diagnostic SELECT-only
`supabase/diagnostics/g3_phase4_stock_movement_preflight.sql` dan runbook
`docs/runbooks/G3_PHASE4_STOCK_MOVEMENT_PREFLIGHT.md`.

Live result user seluruhnya bersih: satu movement Opening, satu source/pair,
saldo cocok, tidak ada duplicate/orphan/negative/missing coverage, dan browser
write false. Delapan missing snapshot serta lima missing future enum sesuai
ekspektasi. Migration `20260728150000`, postflight, behavioral test, dan
regression sudah ditutup sukses oleh user. Backoffice sekarang menyediakan
menu `Inventory > Kartu Stok` sebagai ledger read-only dengan snapshot Base
UOM, quantity masuk/keluar, saldo setelah movement, jenis, dokumen sumber,
actor aman, waktu posting, catatan, serta filter. UUID tidak ditampilkan dan
tidak ada jalur mutation baru.

User mengonfirmasi Kartu Stok aman. Urutan target Inventory berikutnya adalah
Transfer Stok. Audit repo menemukan RPC legacy masih sengaja server-only sejak
G1 karena menerima quantity negatif, tidak memiliki row-lock/idempotency/source
document canonical, dan tidak memindahkan FIFO dengan contract production.
Boundary aktif adalah SELECT-only preflight:

- `supabase/diagnostics/g3_phase6_stock_transfer_preflight.sql`;
- `docs/runbooks/G3_PHASE6_STOCK_TRANSFER_PREFLIGHT.md`.

Live preflight seluruh blocker PASS: tidak ada Transfer history/backfill,
saldo/FIFO/Base UOM/category valid, browser stock write false, dan legacy RPC
tetap non-executable bagi browser. Migration `20260728180000` sekarang
local-ready dengan Draft/Posted/Canceled document, positive quantity, atomic
balance/FIFO relocation, source-batch lineage, paired canonical movement,
operator guard, idempotency, audit, dan full application-role revoke untuk RPC
legacy. User kemudian mengonfirmasi migration, 15-check postflight, behavioral
test, dan seluruh regression sukses. Backoffice sekarang menyediakan
`Inventory > Transfer Stok`, guarded Draft/Edit/Post/Cancel, stok tersedia dari
Gudang asal, bukti saldo/movement/FIFO setelah Posting, serta lookup nomor
Transfer pada Kartu Stok. UUID tidak ditampilkan. Authenticated smoke mengikuti
`docs/runbooks/G3_PHASE7_STOCK_TRANSFER_API_UI.md`; user mengonfirmasi seluruh
smoke sukses.

Roadmap berikutnya adalah Stock Adjustment sebelum Stock Opname karena Posting
Opname menghasilkan Adjustment otomatis untuk line variance. Diagnostic
SELECT-only:

- `supabase/diagnostics/g3_phase8_stock_adjustment_preflight.sql`;
- `docs/runbooks/G3_PHASE8_STOCK_ADJUSTMENT_PREFLIGHT.md`.

Diagnostic mengaudit legacy `stock_adjustments`, linkage dan snapshot Movement,
reason backfill, balance/FIFO, Base UOM, kategori/fungsi Finance, privilege, dan
missing canonical document/RPC. User mengonfirmasi seluruh blocker PASS, zero
legacy Adjustment/backfill, dua positive balance/FIFO pair bersih, dan Finance
siap.

Database foundation telah dikonfirmasi user seluruhnya sukses:

- `supabase/migrations/20260728210000_g3_phase8_stock_adjustment_foundation.sql`;
- `supabase/diagnostics/g3_phase8_stock_adjustment_postflight.sql`;
- `supabase/tests/g3_phase8_stock_adjustment_foundation_tests.sql`;
- `docs/runbooks/G3_PHASE8_STOCK_ADJUSTMENT_FOUNDATION_ROLLOUT.md`.

Kontrak memakai stok fisik akhir, server-derived difference, reason reusable,
FIFO gain/loss, immutable canonical Movement, Finance `STOCK_GAIN`/`STOCK_LOSS`
berstatus `HOLD`, optimistic version, idempotency, audit, serta Store Manager
yang hanya dapat memproses Gudang Store assignment. Browser direct write tetap
tertutup.

Backoffice Phase 9 sekarang local-ready:

- helper validation `backoffice/src/lib/stock-adjustment.ts`;
- empat guarded route di
  `backoffice/src/app/api/inventory/stock-adjustments`;
- UI `backoffice/src/components/StockAdjustmentView.tsx`;
- menu role-aware serta Kartu Stok source lookup;
- runbook `docs/runbooks/G3_PHASE9_STOCK_ADJUSTMENT_API_UI.md`.

Form menjelaskan bahwa user memasukkan stok fisik akhir, menampilkan stok sistem
dan selisih otomatis, memakai nama Base UOM, menyaring reason berdasarkan arah,
serta meminta alasan bila gain cost dioverride. Draft/Edit/Post/Cancel dan
seluruh modal Escape tersedia. Lint dan production build 34 pages PASS.
User melanjutkan setelah authenticated smoke, sehingga Phase 9 ditutup.

Preflight Stock Opname sudah ditutup bersih:

- `supabase/diagnostics/g3_phase10_stock_opname_preflight.sql`;
- `docs/runbooks/G3_PHASE10_STOCK_OPNAME_PREFLIGHT.md`.

Kontrak target adalah blind count nonblocking oleh kasir, movement watermark
pada `counted_at`, recount bila ada movement dalam window count, supersede
per-line untuk sesi overlap, review/post sesuai assignment, dan variance yang
diposting atomic melalui canonical Stock Adjustment. Preflight hanya membaca
aggregate legacy session/detail, linkage Adjustment, balance/FIFO, Base UOM,
channel Store/POS/Cashier, privilege, enum, dan gap schema. Preflight tidak
membuat mutation; G4 dan G5 tetap tertutup.

Database foundation sudah `COMPLETE` berdasarkan konfirmasi user:

- `supabase/migrations/20260728230000_g3_phase10_stock_opname_foundation.sql`;
- `supabase/diagnostics/g3_phase10_stock_opname_postflight.sql`;
- `supabase/tests/g3_phase10_stock_opname_foundation_tests.sql`;
- `docs/runbooks/G3_PHASE10_STOCK_OPNAME_FOUNDATION_ROLLOUT.md`.

Foundation menjaga detail direct-read reviewer-only dan menyediakan
`get_stock_opname_blind_session(...)` untuk kasir agar system/expected/variance,
physical count lama, HPP, dan nilai tidak bocor. Posting memakai satu canonical
Adjustment secara atomic; zero variance tidak membuat Adjustment line.
Membership Cashier aktif belum ada pada hasil preflight, sehingga tidak
memblokir migration tetapi harus disiapkan sebelum smoke POS. Checksum migration
local `23e5026157f21dec4ee8d6df93f2363baffd67a79ee598b1831d8ced4814322d`.

User kemudian mengonfirmasi seluruh rollout database berhasil. Migration Phase
10 tidak boleh diedit atau dijalankan ulang. Backoffice Phase 11 sekarang
menyediakan route read-only tenant-scoped, guarded action `recount`, `post`, dan
`cancel`, helper error contract, serta UI `Inventory > Stock Opname`. Report
menampilkan snapshot, expected saat hitung, fisik, variance, counter, attempt
timeline, dan bukti Adjustment memakai nama bisnis tanpa UUID. Finance dan
Accounting read-only; reviewer mutation tetap divalidasi oleh RPC.

Lint dan production build PASS; build mendeteksi empat route Opname sebagai
dynamic API. Pembuatan sesi dan blind count POS sengaja tidak dipasang pada PWA
prototype. Requirement STK-004 melintasi G3/G4 dan jalur kasir baru boleh
dibuka setelah G4 menyediakan production auth, Company/Store/Terminal context,
Cashier Session, dan offline queue. Database sudah menyediakan
`get_stock_opname_blind_session(...)` sebagai contract aman untuk G4.

User menyatakan halaman report belum dapat diuji end-to-end karena belum ada
POS production yang membuat sesi. Ini expected dependency STK-004 lintas G3/G4,
bukan error dan bukan alasan memasang flow kasir pada PWA mock. Sisa roadmap G3
berpindah ke Bundle STK-006. Boundary aktif:

- `supabase/diagnostics/g3_phase12_bundle_foundation_preflight.sql`;
- `docs/runbooks/G3_PHASE12_BUNDLE_FOUNDATION_PREFLIGHT.md`.

Diagnostic hanya membaca aggregate dependency, Bundle/component existing,
nested/self reference, quantity, duplicate, canonical Base UOM, sales/purchase
UOM, physical stock/Movement/FIFO yang ilegal pada Bundle virtual, browser
privilege, serta gap column/audit/RPC. Existing Product RPC masih sengaja
menolak `BUNDLE_COMPONENTS_REQUIRED_G3`; tidak ada schema, stock, checkout,
Import, atau allocation mutation pada fase preflight ini.

User mengirim seluruh hasil: dependencies dan seluruh invariant PASS, zero
Bundle/component/backfill/physical stock, dua sale-source warehouse, serta
schema/RPC/audit gap sesuai expected. Direct INSERT/UPDATE legacy pada
composition masih terbuka dan menjadi bagian boundary migration.

Database foundation sekarang local-ready:

- `supabase/migrations/20260729010000_g3_phase12_bundle_foundation.sql`;
- `supabase/diagnostics/g3_phase12_bundle_foundation_postflight.sql`;
- `supabase/tests/g3_phase12_bundle_foundation_tests.sql`;
- `docs/runbooks/G3_PHASE12_BUNDLE_FOUNDATION_ROLLOUT.md`.

Migration membuat Product Bundle dan composition sebagai satu mutation atomic,
menurunkan berat dari UOM/berat komponen, melarang nested/self/cross-Company,
mengunci Product type, menjaga Bundle tanpa physical stock/FIFO, menyimpan
audit/version, serta menyediakan private expansion untuk G4 dan availability
reviewer per Gudang. Direct browser write composition dicabut. Checkout,
allocation, Return, Import, dan PWA tetap tidak dibuka.

### Boundary sebelumnya: G2 Phase 47

**G2 Phase 47 — Backoffice Minimum Stock + fixed Import/Export UI**

Phase 46 database sudah ditutup `COMPLETE` berdasarkan konfirmasi user bahwa
seluruh rollout aman dan pekerjaan boleh dilanjutkan. Jangan mengedit atau
menjalankan ulang migration `20260728090000`.

Sebelum Phase 47 dilanjutkan, app shell mendapat follow-up navigasi global:

- tombol `Kembali` pada seluruh halaman non-dashboard memakai history view
  internal Backoffice dan tidak bergantung pada browser Back;
- breadcrumb menampilkan `Beranda / Modul / Halaman`;
- breadcrumb Beranda dan nama Modul dapat dipakai untuk berpindah konteks;
- tombol brand tetap kembali ke app launcher dan mereset history;
- pergantian Company juga mereset history agar user tidak kembali ke halaman
  tenant sebelumnya.

Phase 47 kini local-ready. Modul Inventory memiliki halaman **Minimum Stock**
untuk create/edit pasangan Product–Gudang. UI hanya menampilkan Product,
Gudang, nama Base UOM, threshold, serta status notifikasi; UUID tetap internal.
Create/update melewati guarded RPC Phase 46 dengan optimistic master version.

Import & Export mendukung tipe `PRODUCT_WAREHOUSE_MINIMUM_STOCK`: template
create memakai SKU Product dan nama Gudang; export update menambahkan
`internal_id`; preview menjelaskan threshold Base UOM dan status notifikasi.
API export menggabungkan settings/Product/Gudang melalui query terpisah agar
tidak bergantung pada PostgREST embedded relationship. Tidak ada saldo,
movement, request, order, atau Opening Stock yang dimutasi.

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
referensi export namun validator menolak mutasinya. Local lint, production
build, dan authenticated smoke user PASS. Phase 41 dinyatakan `COMPLETE`.

Phase 42 memulai grouped Product Import melalui diagnostic SELECT-only.
Kontrak fixed memakai beberapa row per Product: satu row per UOM dan seluruh
row dengan `product_key` yang sama diproses atomic. Tepat satu faktor base `1`,
UOM aktif berfaktor terbesar menjadi acuan berat, minimal satu UOM jual/beli
aktif, dan reference Category/UOM/Tax harus sudah tersedia. Product import
tidak membuat master referensi, stock, FIFO, movement, atau Opening Stock.

User mengonfirmasi seluruh hasil live Phase-42 preflight PASS. Migration
`20260727130000` menambahkan job type `PRODUCT`, grouped validator,
optimistic preview capture, dan per-group partial commit ditambahkan tanpa
mengubah signature public import RPC. Tujuh simple master existing tetap
didelegasikan ke implementation Phase 40 yang dipindahkan ke private.

Validator menyelesaikan Category/UOM/Tax berdasarkan nama tenant yang aktif,
menolak group header yang tidak konsisten, duplicate UOM/barcode, Base UOM
selain tepat satu faktor `1`, acuan berat yang ambigu, serta Product tanpa UOM
jual/beli. Commit hanya memanggil overload atomic
`save_product_with_uoms(..., sales_tax_rule_id, purchase_tax_rule_id)`.
Product Bundle, stock, Opening Stock, dan auto-create reference tetap ditolak.
SKU, Base UOM, struktur UOM, dan faktor terkunci bila sudah ada Sales,
Purchase, atau stock-movement history.

Migration Phase 42 kemudian berhasil applied. Behavioral test mencapai commit
tetapi rollback pada constraint `master_import_job_events_type_check` karena
private Product commit menulis event `COMMIT`, sementara vocabulary canonical
adalah `COMPLETE`. Seluruh fixture/write test rollback; migration utama tetap
applied. Forward migration `20260727140000` hanya mengganti literal audit
tersebut tanpa mengubah signature atau business behavior.

User kemudian mengonfirmasi forward migration, 4-check postflight, behavioral
test Phase 42, serta regression Phase 40 dan Phase 38 seluruhnya PASS. Database
Grouped Product Import kini `COMPLETE`; migration utama maupun forward fix
tidak boleh dijalankan ulang.

Phase 43 menambahkan tipe **Produk + Satuan** pada Backoffice Import & Export.
Template fixed memakai satu baris per Product-UOM dan `product_key` yang sama
untuk seluruh satuan Product. Export menambahkan `internal_id` hanya untuk mode
update dan mereferensikan Category/UOM/Tax berdasarkan nama. Preview
mengelompokkan baris berdasarkan Product, menampilkan nama Product, SKU, nama
UOM, faktor langsung ke Base UOM, fungsi beli/jual, dan harga. Ringkasan
create/update/skip/error dihitung per Product group. Tidak ada stock, Opening
Stock, movement, FIFO, atau auto-create master reference.

Phase 44 melanjutkan dependency order fixed import ke Product-Supplier. Kontrak
create memakai `product_sku`, `supplier_name`, `purchase_uom_name`,
`supplier_product_code`, reference price, preferred flag, dan status. Diagnostic
baru hanya membaca aggregate live state. Ia memblokir reference aktif ambigu,
Product stok tanpa UOM pembelian, orphan/cross-Company relation, relasi aktif
ke master nonaktif/UOM non-pembelian/Bundle, preferred Supplier ganda, nilai
existing invalid, guarded RPC hilang, serta import job nonterminal.

User mengirim seluruh hasil live Phase-44 preflight: semua blocker `PASS`,
job type `PRODUCT_SUPPLIER` belum ada sesuai expected pre-migration, tidak ada
job nonterminal, dan satu relation existing valid. Migration
`20260727160000` menambahkan job type/dispatcher secara additive, validator
tenant-scoped, optimistic version capture, dan partial commit melalui
`save_product_supplier(...)`. Pergantian preferred memproses row `false`
sebelum `true`; final preview tetap menolak lebih dari satu preferred aktif.
Import tidak menyentuh `last_purchase_price`, Purchase, stock, FIFO, movement,
atau Opening Stock.

User kemudian mengonfirmasi seluruh rollout Phase 44 PASS. Phase 45 menambah
tipe **Relasi Produk–Supplier** pada Backoffice Import & Export. Template create
berisi tujuh header fixed tanpa ID; export update menambahkan `internal_id`.
Product ditampilkan sebagai SKU, sedangkan Supplier dan UOM pembelian selalu
ditampilkan sebagai nama. Preview tidak memperlihatkan UUID dan menjelaskan
harga referensi, preferred/alternatif, serta status. Export menggabungkan query
relation/Product/Supplier/UOM secara terpisah agar tidak bergantung pada nested
PostgREST relationship schema cache. Lint dan production build PASS.

User melanjutkan setelah verifikasi tersebut sehingga Phase 45 ditutup
`COMPLETE`. Phase 46 mengaudit Minimum Stock per Produk–Gudang sebelum schema
ditulis. Kontrak approved menyimpan threshold opsional dalam base UOM dan
memisahkan lifecycle konfigurasi dari saldo `product_stocks`. Dengan demikian,
pasangan Product–Gudang tanpa movement/saldo tetap dapat dikonfigurasi tanpa
membuat row saldo nol palsu.

Diagnostic Phase 46 hanya membaca aggregate state. Ia memeriksa dependency
Phase 44, SKU Product dan nama Gudang aktif yang kosong/ambigu, tepat satu base
Product-UOM aktif berfaktor `1`, orphan/duplicate/negative saldo, movement pair
tanpa materialized balance, import job nonterminal, direct browser stock write,
eligible pair inventory, serta state schema/job/RPC yang memang belum tersedia.
Tidak ada threshold, stock mutation, movement, Stock Request, Supplier Order,
atau Opening Stock yang dibuat.

User mengirim hasil live: seluruh check hanya `PASS`/`INFO`. Satu Product stock
aktif dan tiga Gudang aktif menghasilkan tiga eligible pair; belum ada balance
atau movement. Tidak ada reference kosong/ambigu, base UOM invalid,
orphan/duplicate/negative balance, movement tanpa balance, browser write, atau
job nonterminal. Schema/RPC/job type belum ada sesuai expected pre-migration.

Migration `20260728090000` kini local-ready. Ia membuat tabel settings dan
audit terpisah dari `product_stocks`, guarded optimistic RPC dengan advisory
pair lock, RLS read boundary, serta fixed import
`PRODUCT_WAREHOUSE_MINIMUM_STOCK`. Template memakai SKU Product dan nama
Gudang; threshold memakai base UOM. Validator/partial commit bersifat
tenant-safe dan tidak membuat balance, movement, Stock Request, Supplier
Order, atau Opening Stock.

File aktif:

- `supabase/diagnostics/g2_phase42_grouped_product_import_preflight.sql`;
- `supabase/migrations/20260727130000_g2_phase42_grouped_product_import.sql`;
- `supabase/diagnostics/g2_phase42_grouped_product_import_postflight.sql`;
- `supabase/tests/g2_phase42_grouped_product_import_tests.sql`;
- `supabase/migrations/20260727140000_g2_phase42_product_import_complete_event_fix.sql`;
- `supabase/diagnostics/g2_phase42_product_import_complete_event_fix_postflight.sql`;
- `docs/runbooks/G2_PHASE42_GROUPED_PRODUCT_IMPORT_PREFLIGHT.md`;
- `docs/runbooks/G2_PHASE42_GROUPED_PRODUCT_IMPORT_ROLLOUT.md`;
- `docs/runbooks/G2_PHASE42_PRODUCT_IMPORT_COMPLETE_EVENT_FIX.md`;
- `docs/runbooks/G2_PHASE43_GROUPED_PRODUCT_IMPORT_UI.md`;
- `supabase/diagnostics/g2_phase44_product_supplier_import_preflight.sql`;
- `docs/runbooks/G2_PHASE44_PRODUCT_SUPPLIER_IMPORT_PREFLIGHT.md`;
- `supabase/migrations/20260727160000_g2_phase44_product_supplier_import.sql`;
- `supabase/diagnostics/g2_phase44_product_supplier_import_postflight.sql`;
- `supabase/tests/g2_phase44_product_supplier_import_tests.sql`;
- `docs/runbooks/G2_PHASE44_PRODUCT_SUPPLIER_IMPORT_ROLLOUT.md`;
- `docs/runbooks/G2_PHASE45_PRODUCT_SUPPLIER_IMPORT_UI.md`;
- `supabase/diagnostics/g2_phase46_product_warehouse_minimum_stock_preflight.sql`;
- `docs/runbooks/G2_PHASE46_PRODUCT_WAREHOUSE_MINIMUM_STOCK_PREFLIGHT.md`;
- `supabase/migrations/20260728090000_g2_phase46_product_warehouse_minimum_stock.sql`;
- `supabase/diagnostics/g2_phase46_product_warehouse_minimum_stock_postflight.sql`;
- `supabase/tests/g2_phase46_product_warehouse_minimum_stock_tests.sql`;
- `docs/runbooks/G2_PHASE46_PRODUCT_WAREHOUSE_MINIMUM_STOCK_ROLLOUT.md`;
- `backoffice/src/lib/master-import.ts`;
- `backoffice/src/app/api/master/import-export/route.ts`;
- `backoffice/src/app/api/master/import-jobs/[id]/route.ts`;
- `backoffice/src/components/MasterImportView.tsx`;
- `docs/MASTER_IMPORT_FIXED_CSV_CONTRACTS.md`;
- `docs/PRODUCT_STOCK_MASTERDATA_SPEC.md`.

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

Database Online Sale, Payment-Leg, true-concurrent Post, Offline allowance/sync,
Sales Return, Expense/Cash Deposit, dan Deposit Variance sudah ditutup pada
boundary masing-masing. Gate manual aktif sekarang adalah Phase-52 database
rollout. Authenticated smoke Customer Balance Phase-50 tetap perlu ditutup
sesuai `docs/runbooks/G4_PHASE50_CUSTOMER_BALANCE_OPERATIONAL_UI.md`.

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

Current G5 step (menggantikan instruksi rollout lama di bawah): jalankan seluruh
`supabase/diagnostics/g5_phase4_goods_receipt_preflight.sql` dan kirim semua row
`check_name,status,details`. `BLOCKER` wajib nol; `REVIEW` harus dijelaskan;
schema/RPC/lineage `SETUP` adalah expected baseline. Jangan membuat atau posting
Receipt/AP/jurnal sebelum hasil ini direview.

Catatan berikutnya di bagian ini adalah guard historis fase sebelumnya; jangan
menjalankan ulang migration yang sudah dinyatakan sukses user.

Jangan rerun migration `20260805090000` atau forward fix `20260805100000`.
Jalankan Phase-52 migration `20260805130000`, postflight, rollback-safe
behavior, regression Phase-4/8/10/49, G3 Phase-14, G1 Security Closure, lalu
closing postflight sesuai runbook. Hentikan pada FAIL/error dan kirim pesan
persisnya. Phase-50 authenticated smoke dua-user tetap perlu dilakukan sebelum
UI dinyatakan complete.

Jangan mengubah status Deposit/Session/exception/Financial Event secara direct.
Jangan membuka checkout usage/refund-to-balance, credit Ketul,
exceptional settlement, TEMPO, Ketul, Offline Customer Balance, bank matching,
reversal/replacement source aktual, jurnal G6, atau G5 Purchasing pada phase ini.

`/api/pos/sync` legacy tetap closed; Receipt Supplier/Purchase Return tetap G5.

Jangan rerun migration Phase 46, Phase 44, atau migration/forward fix Phase 42.

Jangan mengubah atau rerun migration Phase 30–34 yang sudah applied; explicit-code CSV
lama tetap compatibility surface selama transisi.
Product Brand tetap menunggu canonical master.
Permission granular per-user/submodule tetap follow-up access-control terpisah.
Jangan mengaktifkan resolver, checkout calculation, journal, e-Faktur, atau
official tax reporting.

UX follow-up wajib Customer: tambahkan dropdown `Customer induk` langsung pada
modal Edit Customer. Saat ini grouping tersedia pada panel terpisah dan tombol
baru aktif setelah minimal dua Customer non-sistem tersedia.

## 7. Update Log
| 2026-08-06 | Codex — Phase-8 behavioral fixture order fix | Error `FINAL_SUPPLIER_ORDER_LINES_IMMUTABLE` berasal dari fixture yang mengisi line setelah header final, bukan runtime Return | Fixture sekarang DRAFT → line → CONFIRMED; 61/61 parentheses, transaction rollback, diff check PASS | Jangan rerun migration; rerun behavioral test terbaru lalu postflight |
| 2026-08-06 | Codex — G5 Phase-8 Purchase Return foundation | Phase-7 user output seluruhnya PASS; menambahkan Cashier Draft, manager review/Post, exact Receipt FIFO consumption, Stock/Movement, append-only AP adjustment, Event HOLD, audit/idempotency/RLS | Migration 287/287 parentheses, checksum `ee1f7090...e1b22ba`; postflight/test/runbook dibuat; scoped diff check PASS; live rollout pending | Migration `20260806070000` → all-PASS postflight → behavior → closing postflight; setelah PASS baru UI PWA/Backoffice |
| 2026-08-06 | Codex — G5 Phase-7 Purchase Return preflight | User menerima Goods Receipt PWA; diagnostic SELECT-only Purchase Return memeriksa source receipt, kondisi/FIFO/Movement/AP provisional, category/event, reconciliation, schema/RPC, dan browser boundary | Metadata table memakai `pg_namespace`/`pg_class` tanpa dynamic relation parsing; local structural/mutation/diff checks PASS; live output pending | Jalankan preflight penuh; hanya schema/routine diharapkan `SETUP`, kirim seluruh output sebelum foundation |
| 2026-08-06 | Codex — G5 remaining-order UX + Phase-4 preflight | Order workspace mengurangi allocation order aktif per Request line, menyembunyikan baris fulfilled, dan menawarkan sisa partial; Goods Receipt readiness SELECT-only dibuat | Backoffice ESLint + TypeScript PASS; SQL mutation scan zero; parentheses 112/112; diff check PASS | User jalankan Phase-4 preflight penuh dan kirim seluruh output |
| 2026-08-06 | Codex — G5 Phase-3 Stock Request/Supplier Order UI | User menutup Phase-2 migration/postflight/behavior sukses; PWA request tanpa Supplier dan Backoffice Purchase order Draft/Confirm ditambahkan memakai RPC guarded | PWA lint/build PASS; Backoffice lint/build PASS; no schema migration; authenticated smoke pending | Smoke Request → Order dan buktikan Stock/FIFO/Finance zero-effect; setelah PASS lanjut Goods Receipt preflight |
| 2026-08-05 | Codex — G4 Phase-56 Customer Balance tender foundation | User menutup Phase-55 seluruhnya PASS; menambahkan full-balance ONLINE tender, Payment/receipt snapshot, append-only debit/cache/Event/audit, exact retry, WIND_DOWN closure, postflight/test/runbook | Migration 353 lines, postflight 190, behavior 264; delimiter/parentheses seimbang; SHA-256 `b31cbdc...9b297`; live rollout pending | Migration `20260805160000` → all postflight PASS → behavior → regression → closing postflight |
| 2026-08-05 | Codex — G4 Phase-57 Customer Balance tender POS UI | User mengonfirmasi corrected Phase-56 postflight dan behavior seluruhnya PASS; PWA memuat saldo/lifecycle, membuat mandatory full-balance leg otomatis, memblokir shortfall, memperbarui receipt/print, dan menutup Offline | PWA oxlint PASS; TypeScript/Vite production build + service worker PASS; authenticated tablet smoke pending | Restart/hard refresh dan jalankan smoke Phase-57; bila PASS lanjut STK-006 foundation |
| 2026-08-05 | Codex — Phase-56 postflight execution-chain correction | Live migration applied dan 11 checks PASS; satu false FAIL berasal dari `bool_and` yang keliru menuntut setiap routine memiliki seluruh marker. Diagnostic sekarang memeriksa gabungan tiga routine | User mengonfirmasi corrected postflight seluruhnya PASS dan behavioral test PASS | Phase-57 POS UI |
| 2026-08-05 | Codex — G4 Phase-55 POS negative-stock permission preflight | User menutup Phase-54 aman dan membuka STK-006; menambahkan SELECT-only audit current nonnegative data, Warehouse hard guard, shortage runtime, FIFO/HPP/replenishment gap, Offline boundary, direct writes, serta roadmap default-OFF | User mengonfirmasi seluruh preflight PASS; runtime tetap OFF | Lanjut Phase-56 balance tender sebelum STK-006 foundation |
| 2026-08-05 | Codex — G4 Phase-54 Customer Balance tender preflight | User menerima Phase-53; menambahkan SELECT-only audit mandatory full-balance usage, ACTIVE/WIND_DOWN lifecycle, ledger/cache, Customer/method/category/account, historical tender, runtime/snapshot/source gap, dan direct-write boundary | User output: tiga expected SETUP; seluruh invariant PASS; direct writes false; positive balance/history tender nol | Phase-55 negative-stock permission preflight, lalu kembali ke balance tender foundation |
| 2026-08-05 | Codex — G4 Phase-53 POS overpayment disposition UI | User menutup Phase-52 seluruhnya PASS; PWA menambahkan nominal aktual Transfer, pilihan returned/balance untuk selisih Cash/Transfer online, eligibility Customer/feature/offline, serta receipt/print credit snapshot | PWA oxlint PASS; TypeScript/Vite/PWA production build PASS; user menerima dan meminta lanjut | Phase-54 balance tender preflight |
| 2026-08-05 | Codex — G4 Phase-52 Customer Balance Sale credit foundation | Phase-51 live output seluruh invariant PASS/expected SETUP; menambahkan atomic ONLINE overpayment disposition, ledger/cache/Event/audit, Payment/receipt/expected-cash snapshot, Customer lock, exact replay, Offline fail-closed, dan compatibility Cash returned tanpa membuka balance tender | Migration 609 lines, postflight 216, behavior 313; parentheses/tags seimbang; postflight SELECT-only; migration SHA `e44a9f66...`; scoped diff check PASS; user mengonfirmasi rollout/regression/closing seluruhnya PASS | Phase-53 POS disposition UI |
| 2026-08-05 | Codex — G4 Phase-51 Customer Balance Sale credit preflight | Roadmap overpayment diperjelas: server atomic credit lalu UI POS disposition, baru balance usage; menambahkan SELECT-only audit Payment/change, snapshot, ledger source, account/category, identity, reconciliation, dan direct-write boundary | User output: seluruh invariant PASS; 3 expected SETUP; zero non-Cash overpayment, 1 historical Cash change tetap returned | Phase-52 atomic foundation |
| 2026-08-05 | Codex — G4 Phase-50 Customer Balance operational UI | Phase-49 dikonfirmasi user seluruhnya sukses; menambahkan Backoffice liability, koreksi, maker-checker review, statement, API guarded, custom modal/Escape, serta label bisnis tanpa UUID/account key | Backoffice lint PASS; production build PASS dengan 4 route Customer Balance; scoped diff check PASS | Restart Backoffice dan jalankan authenticated smoke dua-user sesuai runbook Phase-50 |
| 2026-08-05 | User confirmation — G4 Phase-49 closure | User mengonfirmasi seluruh rangkaian setelah digest forward fix sukses | Base/fix postflight, corrected behavior, regression, dan closing checks diterima PASS | Lanjut Phase-50 UI tanpa rerun migration |
| 2026-08-05 | Codex — Phase-49 pgcrypto digest forward fix | Behavior berhenti sebelum request insert karena RPC memakai `digest(text,text)` tanpa schema; Supabase menyediakan `extensions.digest(bytea,text)` | Forward migration `20260805100000`, 3-check postflight, manifest checksum `f607b3a0...6d3a8`, scoped diff check PASS; base migration tidak diubah/direrun | Jalankan forward fix → 3 PASS → rerun behavior terbaru |
| 2026-08-05 | Codex — Phase-49 behavior entitlement fixture fix | Behavioral test pertama berhenti `CUSTOMER_BALANCE_CREDIT_DISABLED` karena synthetic Company tidak otomatis memperoleh row `company_features`; fixture sekarang UPSERT entitlement rollback-only agar lifecycle trigger menerima INSERT/UPDATE | Error terjadi sebelum request/ledger/balance final effect; migration tidak berubah dan tidak perlu direrun; scoped diff check PASS | Rerun behavioral test Phase-49 terbaru, lalu regression/closing postflight bila PASS |
| 2026-08-05 | Codex — G4 Phase-49 Customer Balance foundation | Phase-48 user preflight ditutup tanpa blocker/error; menambahkan Company lifecycle, internal method, append-only ledger, correction maker-checker, statement, immutable audit, idempotency, RLS, dan Finance HOLD tanpa membuka checkout | Migration SHA-256 `63a4bdbc...9b82`; scoped diff check PASS; postflight/test/runbook local-ready; manual Supabase pending | Migration `20260805090000` → postflight all PASS → behavior → Phase-46/43/4/G1 regression → closing postflight |
| 2026-08-05 | Codex — G4 Phase-48 Customer Balance readiness preflight | Phase-47 user smoke ditutup aman; mengaudit entitlement, legacy balance/payment, internal method, category/account, Sale fail-closed, direct privilege, dan canonical gap | User melaporkan tanpa blocker/error; hanya Company internal-method provisioning BACKFILL; exact row output tidak dicopy ke chat | Phase-49 guarded foundation |
| 2026-08-05 | Codex — G4 Phase-47 Deposit variance operational UI | Phase-46 ditutup COMPLETE dari konfirmasi user; menambahkan Finance list/detail, responsible party, partial resolution, maker-checker review, role boundary, custom modal/Escape, dan runbook | Backoffice lint PASS; Next production build PASS (42 pages, 4 route variance); authenticated user smoke safe | Phase-48 Customer Balance SELECT-only preflight |
| 2026-08-04 | Codex — G4 Phase-46 Deposit variance resolution foundation | Phase-45 live preflight ditutup bersih; menambahkan responsible party, partial append-only allocation, maker-checker, exact retry, audit, dan Finance HOLD | User confirmed migration/postflight/behavior/regression all safe | Phase-47 operational UI |
| 2026-08-04 | Codex — G4 Phase-45 Deposit variance resolution preflight | Phase-44 approval smoke ditutup aman; membuat SELECT-only audit source/coverage, lifecycle, responsible party, allocation totals, category/account readiness, maker-checker/runtime gap, event, dan privilege | SQL 525 lines, parentheses 188/188, satu statement, scoped diff check PASS; live Supabase output pending | Jalankan seluruh Phase-45 preflight dan kirim output; jangan lanjut bila ada BLOCKER |
| 2026-08-04 | Codex — Phase-44 approve reason bugfix | Smoke approval Setor Kas memunculkan `REASON_REQUIRED` karena client mengirim `reason: ''` dan API mem-parsing optional text sebelum membedakan aksi | Approve sekarang menghilangkan field reason dan API mem-parsing reason hanya untuk Reject; Reject tetap wajib alasan | Restart Backoffice lalu Approve ulang dokumen SUBMITTED yang sama |
| 2026-08-04 | Codex — G4 Phase-44 Cash Deposit operational UI | User mengonfirmasi seluruh Phase-43 rollout/verification PASS; membuka PWA multi-Session create/submit dan Backoffice Finance list/detail/approve/reject tanpa schema baru | PWA lint + TypeScript/Vite/PWA build PASS; Backoffice ESLint + Next production build PASS; scoped diff check PASS; authenticated smoke pending | Restart kedua aplikasi dan jalankan smoke Phase-44; lalu closing postflight Phase-43 |
| 2026-08-04 | User confirmation — Phase-40 corrected behavior | User mengonfirmasi behavioral test Phase-40 sukses setelah fixture Company B diperbaiki | Atomic Cash execution, retry, stale version, rejected zero-effect, cross-Company isolation, document/event/drawer reconciliation rollback-safe PASS | Jalankan Phase-37/34/30/2/G1 regression lalu closing postflight |
| 2026-08-04 | Codex — G4 Phase-42 Cash Deposit preflight | User melanjutkan dari Phase-41; membuat SELECT-only audit Setor Kas multi-sesi, legacy deposit, closed Session, account/category, event/trigger, privilege, dan canonical gap | SQL 344 lines, parentheses 131/131, satu result query, scoped diff check PASS; live Supabase output pending | Jalankan seluruh Phase-42 preflight dan kirim semua output; jangan lanjut bila ada BLOCKER |
| 2026-08-04 | Codex — G4 Phase-43 Cash Deposit foundation | User mengonfirmasi Phase-42 aman; membuat multi-Session lifecycle, lock, expected/actual/variance, proof policy, approval/reject/cancel, audit, exception, dan Financial Event HOLD | Migration 791 lines; SQL delimiter scan, Store schema correction, scoped `git diff --check` PASS; manual Supabase belum dijalankan | Migration `20260804130000` → postflight all PASS → behavioral test → regressions Phase-40/37/34/2/G1 → closing postflight |
| 2026-08-04 | Codex — G4 Phase-41 Additional Expense operational UI | User menutup seluruh Phase-40 regression/closing postflight; membuka review tambahan dan non-Cash execution di Backoffice serta Cash execution pada active POS Session | Backoffice ESLint + Next production build PASS; PWA oxlint + TypeScript/Vite/PWA build PASS; user melanjutkan tanpa blocker | Lanjut POS-008 Deposit preflight tanpa membuka mutation/UI lebih dulu |
| 2026-08-04 | Codex — Phase-40 cross-Company behavioral fixture correction | Behavioral test berpindah ke Company B untuk negative tenant test, tetapi fixture B belum menyalakan `expense_enabled`, sehingga feature guard benar berhenti sebelum request-not-found guard | User error `EXPENSE_FEATURE_DISABLED` hanya di rollback-safe test; fixture B kini mengaktifkan Expense, test 343 lines/65–65 parentheses/SHA `7f3af4b5...`; migration tidak diubah atau diulang | Rerun behavioral test Phase-40 dari awal; setelah PASS lanjut regression |
| 2026-08-04 | Codex — G4 Phase-40 Additional Expense disbursement foundation | Phase-39 live output ditutup bersih; menambahkan lifecycle terminal, guarded review/reject, atomic Cash/non-Cash execution, exact retry, unique request-disbursement link, drawer isolation, audit, Finance HOLD, postflight, rollback test, dan runbook | User: seluruh Phase-39 invariant PASS dan expected SETUP tepat; migration/postflight/test 591/290/343 lines, parentheses 92/92, 134/134, 65/65; SHA `45e0112d...`, `0e04667e...`, `7f3af4b5...`; postflight mutation scan 0 dan `git diff --check` PASS; live migration applied, behavioral rerun pending | Rerun corrected behavior → Phase-37/34/30/2/G1 regression → closing postflight |
| 2026-08-04 | Codex — G4 Phase-39 Additional Expense disbursement preflight | Phase-38 ditutup COMPLETE; SELECT-only audit request lifecycle, runtime/event gap, zero-effect, tenant/payment/session, privilege, dan inventory dibuat | User melanjutkan tanpa error; mutation keyword 0; parentheses 115/115; `git diff --check` PASS | Jalankan seluruh Phase-39 preflight dan kirim semua output |
| 2026-08-04 | Codex — G4 Phase-38 Expense settlement operational UI | Phase-37 ditutup COMPLETE; POS actual/return Cash/request tambahan dan Backoffice review actual/return non-Cash dibuka melalui guarded RPC | User: Phase-37 all safe; PWA lint/build PASS; Backoffice lint/build PASS; `git diff --check` PASS | Authenticated role/effect smoke sesuai runbook Phase-38; additional execution tetap tertutup |
| 2026-08-03 | Codex — G4 Phase-37 Expense settlement foundation | Phase-36 live output bersih; menambahkan actual request/review, immutable settlement/return snapshots, Cash In + drawer IN, expected-cash/outstanding lifecycle, idempotency, Finance HOLD, participant RLS, and request-only additional disbursement | Migration 1053 lines/247–247 parentheses/8–8 blocks; postflight 314 lines/167–167; behavior 290 lines/55–55; checksums/scoped diff PASS. Supabase local DB lint unavailable karena local Postgres tidak berjalan; live rollout pending | Migration → postflight → behavior → Phase-34/30/2/G1 regression → closing postflight |
| 2026-08-03 | Codex — G4 Phase-36 Expense settlement preflight | User mengonfirmasi Phase-35 aman; menambahkan diagnostic SELECT-only actual/return/outstanding/additional disbursement, event-total reconciliation, lifecycle, Finance/drawer coverage, category-account, Cash return Session, aging, privilege, dan gap schema/enum/RPC | SQL 448 lines, 166/166 parentheses, satu statement, zero mutation; scoped diff check PASS; live Supabase output menunggu user | Jalankan seluruh preflight Phase-36; `SETUP` expected, `BLOCKER` wajib nol sebelum foundation |
| 2026-08-03 | Codex — G4 Phase-35 Expense disbursement operational UI | User menutup Phase-34 seluruhnya aman; menambahkan satu menu Expense PWA dengan tab pengajuan/Cash approved, Cash Session disbursement + expected-cash update, Backoffice non-Cash confirmation, authenticated server route, proof/idempotency/custom confirmation, dan explicit role/channel separation | PWA oxlint PASS; PWA TypeScript/Vite/PWA build PASS; Backoffice ESLint PASS; Next 16 production build PASS dengan route `/api/finance/expenses/[id]/disburse`; `git diff --check` PASS; authenticated cash/noncash smoke pending | Jalankan runbook Phase-35, lalu closing Phase-34 postflight; settlement/return/Cash In tetap closed |
| 2026-08-03 | Codex — G4 Phase-34 Expense disbursement foundation | Phase-33 live output bersih dengan dua approved Expense; menambahkan migration guarded initial disbursement, approval/payment/account snapshots, exact approved amount, Cash Session/drawer sufficiency + OUT movement, non-Cash Finance isolation, expected-cash integration, idempotency, audit, Finance HOLD, postflight, rollback test, manifest, dan rollout guide | Migration 591 lines/98–98 parentheses; postflight 343 lines/147–147 and SELECT-only; test 358 lines/72–72; scoped diff check PASS; SHA migration `28b27f47ff075bae3cae3940553b28797da320ca4ea11c6094eceda9addc9540`, postflight `b9d39329c7e539d5aeb75de89851e44e2bf52623bbed1dede11147a8d4d3a16e`, test `6629a799eb5815b8af894361c6e215508cab419e0decd56efa94d869d1900f3a`; live rollout pending | Migration → all-PASS postflight → behavior → Phase-30/26/2/G1 regressions → closing postflight |
| 2026-08-03 | User confirmation — G4 Phase-33 preflight | User output: four expected runtime SETUP, all data/reference/category/account/Session/privilege/reconciliation checks PASS; approved inventory two documents totaling 325000 | Live SELECT-only preflight complete; one Cash and one non-Cash approved fixture available; zero disbursement history | Rollout Phase-34 foundation; no direct/manual cash mutation |
| 2026-08-03 | Codex — G4 Phase-33 Expense disbursement preflight | User mengonfirmasi Phase-32 approval aman; membuat diagnostic SELECT-only untuk approved Expense, eligible payment/Store/Session, category/account, approval snapshot, event/drawer/expected-cash runtime, direct-write boundary, dan event-total reconciliation | SQL: 443 lines, 140/140 parentheses, satu statement, zero mutation token; seluruh referenced column diaudit terhadap migration aktif; scoped `git diff --check` PASS; live Supabase output menunggu user | Jalankan seluruh preflight Phase-33; jangan rollout pencairan bila ada BLOCKER |
| 2026-08-03 | Codex — Phase-32 approve reason bugfix | Smoke pertama memunculkan `Alasan wajib diisi` saat approve karena client mengirim `reason: ''` dan API memakai optional parser yang memvalidasi string kosong sebagai required | Approve kini tidak mengirim reason dan parser menetapkan `null` tanpa validasi; reject/cancel tetap required; Backoffice ESLint + production build PASS | Hard refresh lalu approve ulang Expense yang sama |
| 2026-08-03 | Codex — G4 Phase-32 Expense approval Backoffice UI | User mengonfirmasi pengajuan Phase-31 aman; menambahkan Finance navigation, tenant-scoped list/detail, role-aware approve/reject/cancel, optimistic version, required reason, user-facing snapshots/evidence, dan custom confirmation/Escape tanpa cash effect | Backoffice ESLint PASS; Next 16 production build PASS; dynamic routes `/api/finance/expenses`, `[id]/review`, `[id]/cancel` terdeteksi; authenticated role smoke pending | Uji approve + reject disposable, Accounting read-only, dan zero cash/stock/journal effect; lalu preflight disbursement |
| 2026-08-03 | Codex — G4 Phase-31 Expense request PWA UI | User menutup Phase-30 seluruhnya PASS; menambahkan entitlement-aware online Expense entry point, category/payment lookup, responsible party, nominal/description/evidence/target settlement, idempotent Draft + guarded Submit, status yang membedakan approval dari pencairan, custom modal/Escape, dan offline fail-closed | `pwa` oxlint PASS; TypeScript + Vite production build PASS; generated Expense chunk terpisah; authenticated tablet smoke pending | Restart/hard refresh; uji entitlement off/on, Cash dan Transfer, status, serta zero cash/stock/journal effect |
| 2026-08-03 | Codex — G4 Phase-30 Expense request/approval foundation | Phase-29 output diterima tanpa blocker; menambahkan sembilan tabel canonical, default policy/category untuk Company existing/future, guarded category/policy/Draft/Submit/Review/Cancel, immutable future-event tables, RLS/audit, feature default off, targeted retirement trigger Cash Advance legacy, dan concurrency-safe Draft idempotency | Audit schema exact `stores.status`, `pos_terminals.status`, Session/Payment/COA/Transaction Category/composite FK; parentheses migration/postflight/test `513/513`, `135/135`, `47/47`; mutation diagnostic hanya privilege strings; `git diff --check` PASS; SHA migration `499561965867459FE250B8FF33C1917BB4698B3A8EDA113740F2F71882BB89E3`, postflight `E5B6D733DD7626DE9E05CD53C8A0EF1054CFC0D0F18A03430EE322EAB5B7935F`, test `2052AEB01B6C265D33B6D446BB468C3AF1706FF24032DB699966452681863FC3`; live rollout pending | Jalankan migration → all-PASS postflight → rollback-safe behavior → Phase-26/2/G1 regressions |
| 2026-08-03 | User confirmation — G4 Phase-29 preflight | User mengirim output tanpa BLOCKER: seluruh readiness/integrity PASS, legacy rows zero, expected legacy trigger REVIEW dan nine-table canonical SETUP | Live SELECT-only preflight complete; satu active Store/Terminal/open Session serta Cash/Transfer ready | Rollout Phase-30 foundation; jangan membuka cash effect |
| 2026-08-03 | Codex — Phase-29 Store column correction | First live run failed before returning rows because preflight incorrectly assumed `stores.is_active`; corrected to verified canonical `stores.status = 'ACTIVE'` and re-audited every referenced column against repository schema/migrations | User error `42703`; failed statement SELECT-only/no side effect; corrected SQL static balance/mutation/diff checks pending | Rerun corrected Phase-29 preflight once and send full output |
| 2026-08-03 | Codex — G4 Phase-29 Expense/Cash Flow preflight | User mengonfirmasi Backoffice Return berhasil posting; menutup Phase-28 dan membuat SELECT-only audit legacy Cash Advance, tenant/value, trigger/Event, Store Cash/Transfer, Session, required category/account, entitlement, privilege, dan canonical schema gap | Phase-28 user smoke PASS; preflight 1 executable statement, parentheses 136/136, mutation scan zero, scoped diff check PASS | Jalankan seluruh Phase-29 preflight dan kirim semua output; jangan rollout bila ada BLOCKER |
| 2026-08-03 | Codex — G4 Phase-28 Sales Return Backoffice approval UI | User mengonfirmasi Draft Return berhasil; menambahkan Sales menu/list/detail user-facing, guarded post/cancel route, required-role boundary, optimistic version/idempotency, alasan cancel, custom confirmation/Escape, dan explicit open-session warning | Backoffice lint PASS; production build PASS; 3 dynamic Return route terdeteksi; authenticated role/effect smoke pending | Jalankan runbook Phase-28 dengan satu cancel disposable dan satu post; kirim hasil/notifikasi persis |
| 2026-08-03 | Codex — G4 Phase-27 Sales Return PWA Draft UI | Regression Phase-26 ditutup user; menambahkan modal Return online, invoice search, user-facing Product/UOM/Customer, qty tersisa, condition/Gudang Rusak, refund Cash/Transfer exact-total otomatis, Draft-only submit, Escape/backdrop, dan tablet layout | User: G4/G1 success, G3 Phase-14 seluruh invariant PASS dengan expected SETUP/DEFERRED; PWA lint PASS; production build PASS | Restart/hard refresh dan jalankan smoke Phase-27; setelah PASS bangun Backoffice approval/post |

| Tanggal | Agent/Turn | Perubahan | Evidence | Next gate |
|---|---|---|---|---|
| 2026-08-03 | User confirmation — Phase-26 lineage + behavior closure | User mengonfirmasi forward-fix migration, fix postflight, dan behavioral Return seluruhnya sukses | Return/refund/FIFO/Movement/Cash Session/idempotency/immutability/audit/Finance HOLD rollback-safe behavior PASS | Jalankan G4 Phase-10, G3 Phase-14, dan G1 Security Closure regression; UI tetap closed |
| 2026-08-03 | Codex — Phase-26 Return batch-lineage forward fix | Behavioral test membuktikan `source_batch_id` masih dikunci khusus Transfer oleh constraint G3; membuat migration forward-only yang mengizinkan exactly-one Transfer/Return lineage dan index Return line tanpa mengubah migration applied | User error `23514 product_batches_transfer_lineage_check`; transaction test rollback; parentheses migration 9/9 dan postflight 25/25; SHA-256 migration `AA6558B0E43F7897EE26C286FC6572AA5D7C8EF86076C092E3B4884D92C8C189`, postflight `54FCA51792711E3943452F038820627937C4972CCEB24C830A9867C6D7EA3ED2`; scoped `git diff --check` PASS | Apply `20260803020000` → all-PASS fix postflight → rerun behavior Phase-26 |
| 2026-08-03 | User confirmation — G4 Phase-26 migration/postflight | User mengonfirmasi migration Sales Return dan seluruh postflight sukses tanpa FAIL | Live ledger/schema/RPC/grant/invariant postflight all PASS; behavioral/regression belum dijalankan | Jalankan rollback-safe Phase-26 behavior; hanya setelah PASS lanjut G4 Phase-10/G3 Phase-14/G1 regression |
| 2026-08-03 | Codex — G4 Phase-26 Sales Return foundation | Phase-25 user output seluruh source PASS/expected SETUP; menambahkan 5 canonical tables, 4 guarded RPC, default required approval, cumulative quantity/refund guard, condition-based original FIFO restoration, Cash expected integration, RLS/grant boundary, audit/idempotency, Finance HOLD, postflight, rollback-safe behavior, dan rollout runbook | Parentheses migration 417/417, postflight 119/119, test 49/49; dollar tags balanced; SHA-256 migration `5FFD8A2CB6D1CADF1BD74D0C5167ED34D477259F50FC97ED2ED323F950167C57`, postflight `9D4094D0592BBFFA0A3A94EFADE5CCB3FAB99E80A3FCD92E516BB60FAAF04330`, test `E1811BDED208F10645E0AE04EDA5608323E8D96D63CFD34316FC6D6C450B4FEB`; scoped `git diff --check` PASS; live SQL pending | Migration `20260803010000` → all-PASS postflight → rollback-safe behavior → G4 Phase-10/G3 Phase-14/G1 regression; UI tetap closed |
| 2026-08-03 | User confirmation — G4 Phase-25 readiness | Dependencies, source header/line/Payment, totals, Bundle/FIFO, Offline state, warehouse, Finance catalog, dan browser boundary PASS; schema/routines expected SETUP | User output: 6 Sale, 6 line, 6 Payment leg, 6 stock requirement, 7 FIFO allocation; zero blocker | Roll out Phase-26 foundation only; jangan buka UI sebelum database behavior/regression lulus |
| 2026-08-03 | Codex — G4 Phase-25 Sales Return readiness preflight | Setelah user menutup Offline core, menambahkan SELECT-only audit source Sale/line/Payment/receipt, Bundle/FIFO, Offline terminal state, warehouse condition, refund method, Finance catalog, expected Return schema/RPC, dan browser write boundary; Return mutation/UI tetap tertutup | 1 executable statement; parentheses 147/147; SHA-256 `3963294354832AB194B44F95A14D5AA4FCD6DD2884BA7AA4A3ED7F9C6AC32459`; scoped `git diff --check` PASS; live SQL pending | Jalankan seluruh Phase-25 preflight dan kirim output; expected schema/routine `SETUP`, tetapi tidak boleh ada source `BLOCKER` |
| 2026-07-31 | Codex — Phase-22 payment/offline UAT correction | Single-payment allocation mengikuti total final otomatis, Cash over-tender dipisah sebagai `Uang diterima`/kembalian, summary kembalian ditambahkan, Offline snapshot dicoba otomatis saat Session online terbuka, dan blocked reason dibuat eksplisit; Customer Balance tetap deferred | PWA oxlint PASS; TypeScript/Vite production build + service worker PASS; `git diff --check` PASS; in-app browser tidak dapat attach karena environment sehingga authenticated visual smoke belum diklaim | User restart/hard refresh PWA; uji E2E-09/E2E-14/E2E-22 lalu warm-session Offline happy path; kirim exact blocker bila snapshot/allowance belum siap |
| 2026-07-30 | Codex — Phase-22 POS end-to-end UAT gate | Checklist 40 jalur Online/Offline, negative path, retry/recovery, final reconciliation, evidence, cleanup, dan batas warm-session didokumentasikan tanpa membuka cold-start atau modul deferred | Documentation-only; memakai Phase-12 postflight dan Phase-21 preflight existing sebagai oracle server; no schema/runtime change | User jalankan E2E disposable dan kirim dua output SQL + kegagalan per ID; hanya setelah PASS lanjut cold-start restore/conflict stress |
| 2026-07-30 | Codex — Phase-21 Offline checkout queue preflight | SELECT-only dependency/RPC/grant, UAT scope, allowance/Product/Payment, submission identity/final effect, Session guard, dan Stock–Movement–FIFO readiness audit | 1 executable statement; mutation line 0; parentheses 170/170; SHA-256 `11300EA1F048A3372BD73A19EC0720C599DACEEC5074C8A40CD37B29D1BADBB0`; `git diff --check` PASS | Jalankan seluruh preflight dan kirim semua PASS/SETUP/INFO/BLOCKER; checkout Offline tetap closed |
| 2026-07-30 | Codex — Phase-22 Offline checkout retained queue PWA UI | Phase-21 ditutup PASS/expected SETUP; Cart sekarang memakai snapshot pricing, Base-UOM allowance, exact Payment, retained commit, Slip Offline watermark, queue retry/status, dan final invoice acknowledgement secara fail-closed | User: seluruh Phase-21 invariant PASS, UAT scope SETUP; PWA oxlint PASS; TypeScript/Vite production build + service worker PASS; `git diff --check` PASS; browser connector environment gagal attach sehingga visual/authenticated UAT belum diklaim | Jalankan combined Phase-20/22 disposable tablet UAT; setelah sukses lanjut cold-start restore/conflict stress, bukan membuka deferred module |
| 2026-07-31 | Codex — Phase-23 Offline cold-start/conflict recovery preflight | Menambahkan SELECT-only audit dependency, browser boundary, immutable lifecycle, idempotent submit, controlled retry, status recovery, final-effect coverage, stale sync, dan Stock–Movement–FIFO; PWA cold-start tetap closed | 1 statement; mutation line 0; parentheses 151/151; SHA-256 `5A06EDCE0496D72E5F79BDD0EBD5926776F34DE013EE34DA48E4B60460D5E9AA`; scoped `git diff --check` PASS | Jalankan seluruh Phase-23 preflight; kirim semua hasil dan jangan mulai client bootstrap bila ada `BLOCKER` |
| 2026-07-31 | Codex — Phase-23 Offline cold-start/recovery PWA | User preflight seluruh core PASS dan UAT scope PASS; Dexie v5 operational scope, cached-auth exact match, offline catalog/queue restore, reconnect active-Company reconciliation, status-first recovery, dan controlled retry dibuat tanpa server migration | PWA oxlint PASS; TypeScript/Vite production build + service worker PASS; scoped `git diff --check` PASS; in-app browser tidak dapat diinisialisasi pada environment sehingga authenticated visual smoke belum diklaim | Restart/hard refresh online sekali, jalankan cold-start/negative UAT Phase-23, lalu rerun Phase-23 preflight + Phase-12 postflight |
| 2026-08-03 | Codex — Phase-23 Offline sync latency recovery | User menemukan satu order dapat tertahan pada UI hingga hitungan menit. Client sekarang membatasi status 10 detik, submit 15 detik, dan process 25 detik; outcome timeout dengan submission ID menjadi `NEEDS_CONFIRMATION`, status server diperiksa sebelum retry, `POSTED` tidak lagi menunggu refresh katalog penuh, cache hanya diverifikasi sekali per load, dan record final tidak lagi mengurangi allowance lokal dua kali | PWA oxlint PASS; TypeScript/Vite production build + service worker PASS; tidak ada schema/migration/data mutation | Hard refresh PWA, buka transaksi yang macet lalu `Periksa status`; setelah terminal state, buat satu transaksi Offline disposable dan catat durasi submit/process serta pastikan tombol bebas kembali maksimal sekitar 35 detik bila server tidak merespons |
| 2026-08-03 | Codex — Phase-24 Offline disconnect/reconnect stress preflight | User mengonfirmasi sync latency aman; SELECT-only gate dan runbook dibuat untuk baseline zero-nonterminal, fixture Session/Cash/allowance, RPC/browser boundary, identity/final effect, allowance ledger, Stock–Movement–FIFO, serta lima titik pemutusan jaringan | SQL aggregate-only; no schema/data/entitlement mutation; local structural verification pending | Jalankan seluruh Phase-24 preflight dan kirim semua hasil sebelum stress |
| 2026-08-03 | Codex — Phase-24 Terminal readiness correction | Eksekusi pertama berhenti sebelum menghasilkan output karena diagnostic memakai `pos_terminals.is_active`; referensi dikoreksi ke canonical `status='ACTIVE'` dan readiness diselaraskan dengan Store aktif, Gudang sale-source aktif, serta Cash effective/CASH_DRAWER | Error hanya SELECT parse; tidak ada mutation atau stress yang berjalan; structural verification diulang | Rerun seluruh Phase-24 preflight terbaru |
| 2026-08-03 | User confirmation — Phase-24 stress readiness | Seluruh preflight PASS/INFO; satu ready Session/Cash/allowance, zero nonterminal, dua posted submission existing valid, max attempt 1, dan seluruh identity/final-effect/allowance/stock reconciliation bersih | User mengirim output lengkap 14 checks; tidak ada BLOCKER/SETUP | Jalankan controlled disconnect saat `PROCESSING`, status-first recovery, lalu closing diagnostics |
| 2026-08-03 | User confirmation — Phase-24 Offline core closure | Controlled disconnect/reconnect berhasil, sync selesai melalui UI, dan user mengonfirmasi seluruh Phase-24/23/12 closing diagnostic PASS | Authenticated UI stress + database reconciliation all clear | Lanjut G4 Phase-25 Sales Return readiness preflight; Finance posting, TEMPO, Expense, Deposit, dan G5 Purchasing tetap tertutup |
| 2026-07-30 | Codex — Phase-20 Cashier Offline Allowance PWA UI | Cashier issue/release allowance sesi sendiri via RPC, server/local/queued quantity, custom confirmation, snapshot reconciliation, dan fail-closed cache invalidation tanpa membuka checkout | PWA oxlint PASS; TypeScript/Vite production build + service worker PASS; browser connector unavailable, authenticated tablet UAT pending | Restart Backoffice/PWA; jalankan combined Phase-19/20 UAT; checkout Offline tetap closed |
| 2026-07-30 | Codex — Phase-19 Offline Allowance operations UI | Active-Company manager API, scoped Session/Product-stock list, guarded issue/release/force-revoke, reason modal, status history, dan explicit disabled-entitlement state tanpa direct table write | Backoffice ESLint PASS; Next.js production build PASS; route terdaftar; browser connector unavailable, authenticated UAT pending | Restart Backoffice; jalankan disabled-state + disposable issuance/revoke UAT; checkout Offline tetap closed |
| 2026-07-30 | User confirmation — Phase-18 database closure | User mengonfirmasi seluruh rollout POS Customer quick-create sukses | Migration applied; postflight dan behavioral test all success | Jangan rerun Phase-18; kembali ke guarded Offline allowance operational UI |
| 2026-07-30 | Codex — Phase-18 POS Customer quick-create | RPC create-only active-Company/open-Session, automatic code, safe zero-credit contract, audit, PWA modal/select-refresh, serta selector Company adaptif PWA/Backoffice | PWA oxlint + production build PASS; Backoffice ESLint + production build PASS; SQL manual gate pending | Migration `20260730040000` → all-PASS postflight → rollback-safe behavior → restart dan tenant smoke |
| 2026-07-30 | Codex — Phase-16 Offline status drawer UX | Panel permanen dipindah ke tombol header `Offline` dan drawer kanan; indikator cache tetap terlihat, drawer tutup via tombol/Escape/backdrop, workspace checkout tidak lagi terdorong | PWA `oxlint` PASS; TypeScript/Vite production build PASS; visual browser connector unavailable, authenticated smoke pending | Restart PWA dan smoke tombol/drawer bersama closed-entitlement behavior |
| 2026-07-30 | Codex — Phase-17 guarded Offline policy Backoffice UI | Menu Pengaturan Modul dibuka bagi Owner/Admin/Store Manager sesuai scope; entitlement tetap Super Admin-only; default Company, override Toko, Terminal eligibility, custom confirmation/Escape, dan guarded API ditambahkan | Backoffice ESLint PASS; TypeScript/Next production build PASS; `/api/platform/offline-settings` terdaftar; authenticated role smoke pending | Restart Backoffice/PWA dan jalankan smoke Phase-16 + Phase-17; jangan aktifkan entitlement |
| 2026-07-30 | Codex — Phase-16 read-only Offline status/cache UI | Panel connection/scope/snapshot age/allowance, refresh message, close/logout invalidation, minute refresh, responsive tablet/mobile layout, dan lazy cache chunk dibuat tanpa membuka checkout | PWA `oxlint` PASS; production build PASS; main `471.65 kB`, cache chunk `102.84 kB`, no chunk warning; automated browser unavailable, manual smoke pending | Restart PWA dan jalankan closed-entitlement smoke sesuai runbook Phase-16 |
| 2026-07-30 | Codex — Phase-14 closure dan Phase-15 retained catalog cache | User menutup seluruh regression/closing postflight; Dexie v4 snapshot, guarded RPC adapter, scope/hash/freshness/invalidation, dan queue-aware allowance reconciliation dibuat tanpa membuka checkout | User: Phase-12/11/4/G1 + Phase-14 closing postflight all good; PWA `oxlint` PASS; TypeScript/Vite production build PASS | Read-only Offline status/cache UX; entitlement dan checkout tetap disabled |
| 2026-07-30 | Codex — Phase-14 corrected behavior closure | User mengonfirmasi behavioral test terbaru aman setelah rollback-safe feature upsert | Snapshot shape, Product price/Tax completeness, Session/Terminal scope, dan browser privilege behavior PASS; migration tidak berubah | Jalankan regression Phase-12/11/4/G1 lalu rerun postflight Phase-14 |
| 2026-07-30 | Codex — Phase-14 behavior feature-fixture fix | Behavior gagal sebelum snapshot karena test memakai `UPDATE` terhadap Company yang belum mempunyai entitlement row; fixture diperbaiki menjadi rollback-safe upsert dan explicit enabled assertion | User error `OFFLINE_POS_FEATURE_DISABLED`; test SHA-256 `46ea0d836fc3870858a0384b80c067c28574af7190a046231f3ce537b463aea1`; migration/RPC/postflight tetap valid | Rerun hanya behavioral test Phase-14 terbaru |
| 2026-07-30 | Codex — Phase-14 migration/postflight live | User menjalankan migration authoritative Offline catalog snapshot dan postflight; ledger, RPC, privilege boundary, serta closed entitlement PASS; Terminal policy tetap tidak diprovision | `migration_ledger`, `offline_catalog_snapshot_rpc`, RPC boundary, dan `offline_entitlement_remains_closed` PASS; source inventory INFO; zero Terminal policy expected SETUP | Jalankan rollback-safe behavioral test Phase-14 |
| 2026-07-30 | Codex — G4 Phase-14 authoritative Offline catalog snapshot | Live preflight diterima bersih; guarded Session/Terminal snapshot Product-UOM, Pricelist/rule, Sales Tax metadata, Payment Method, stock Gudang, dan allowance beserta postflight/test/runbook dibuat; feature dan PWA checkout Offline tetap tertutup | User: dependency/invariant PASS, RPC dan Terminal policy expected `SETUP`, entitlement disabled; migration SHA-256 `386a0edc...`; local structural/diff verification PASS | Migration `20260730010000` → postflight → rollback-safe behavior → Phase-12/11/4 + G1 regression |
| 2026-07-29 | Codex — G4 Phase-11 Offline Stock Allowance preflight | Phase-10 ditutup COMPLETE; diagnostic SELECT-only entitlement, Terminal/Session/Gudang, Payment offline, Stock–Movement–FIFO, identity, expected schema, dan browser boundary dibuat; offline tetap tertutup | GitHub checkpoint `cdd1e26` terverifikasi di `origin/main`; SQL SHA-256 `7724C17C...`; executable mutation keyword 0, satu statement, parenthesis balanced, `git diff --check` PASS | Jalankan seluruh Phase-11 preflight dan kirim semua hasil |
| 2026-07-29 | Codex — G4 Phase-11 Offline Stock Allowance foundation | Live preflight ditutup bersih; policy Company/Store/Terminal, reservation Base UOM, stock/session guard, release/revoke, immutable audit/history, closed submission envelope, postflight/test/runbook dibuat; sync/PWA tetap tertutup | User: seluruh blocker PASS, expected 5-table SETUP, entitlement disabled, terminal/payment/stock ready; migration SHA-256 `3dd7c002...`; local structural/diff checks | Migration `20260729180000` → all-PASS postflight → behavior → listed regression |
| 2026-07-29 | Codex — Phase-11 behavior Profile fixture fix | Test gagal sebelum behavior karena Auth insert trigger sudah membuat `profiles`; explicit fixture sekarang memakai idempotent `ON CONFLICT(id) DO UPDATE` | User error `profiles_pkey` UUID `...060091`; test SHA-256 baru `19fe98dc...`; delimiter/parenthesis/diff check PASS; migration tidak berubah dan tidak perlu direrun | Rerun hanya behavioral test Phase-11 terbaru |
| 2026-07-29 | Codex — G4 Phase-12 Offline submission/sync preflight | User menutup Phase-11 all success; diagnostic submission/hash/version, consumption, Sale/Payment snapshot, acknowledgement, payment exception/Finance, routine, Session guard, stock reconciliation, dan browser boundary dibuat; endpoint/PWA tetap closed | User: Phase-11 migration/postflight/corrected behavior/regression success; preflight SHA-256 `ca1a46e8...`; one statement, mutation keyword 0, balanced, diff check PASS | Jalankan dan kirim seluruh hasil Phase-12 preflight |
| 2026-07-29 | Codex — Phase-12 preflight routine-alias fix | Pemeriksaan routine memakai derived table yang hanya mengekspos `proname`, tetapi agregasi lama salah merujuk `p.oid`; filter diperbaiki menjadi `p.proname IS NULL` tanpa mengubah kontrak check | User error PostgreSQL `42703`; preflight SHA-256 baru `057b49101a9a087b255aef2b5ae81879e6dd3eff7da5ea91cf845f77587c0cac`; satu statement, mutation 0, parenthesis balanced, `git diff --check` PASS | Rerun hanya seluruh file preflight Phase-12 terbaru; tidak perlu rerun migration/test Phase-11 |
| 2026-07-29 | Codex — G4 Phase-12 canonical Offline Sale Sync database | Live preflight ditutup bersih; immutable client/server hash+version, snapshot price resolver, canonical Draft/Post, atomic allowance consumption, Payment verification exception, acknowledgement, failure rollback, postflight/test/runbook dibuat; PWA tetap tertutup | User: seluruh prerequisite/invariant PASS dan expected SETUP tepat pada objek baru; migration SHA-256 `a2c7865c...`; local delimiter/parenthesis/diff verification PASS, manual Supabase pending | Migration `20260729210000` → all-PASS postflight → behavior → Phase-11/8/4, G3 Phase-15, G1 regression |
| 2026-07-29 | Codex — Phase-12 postflight routine-signature fix | Live migration ledger, tables, columns, grants, RLS, triggers, dan reconciliation PASS, tetapi routine check false-fail karena `pg_get_function_identity_arguments()` menyertakan nama parameter. Expected routine sekarang diperiksa sebagai exact signature memakai `to_regprocedure()` | Perubahan hanya diagnostic SELECT-only; SHA-256 `da18d87cb07ebcddf283e613fe0aa98457522f08f91f8ea56d5cc2fd19e623c0`; satu statement, mutation keyword 0, parenthesis balanced, `git diff --check` PASS; migration yang sudah applied tidak diubah | Rerun hanya postflight Phase-12 terbaru; bila seluruh non-INFO PASS, lanjut behavior Phase-12 |
| 2026-07-29 | Codex — Phase-12 corrected postflight closure | User mengonfirmasi corrected postflight seluruhnya sukses; false-fail routine signature tertutup tanpa migration ulang | Migration ledger dan seluruh postflight invariant live PASS; behavioral test belum dijalankan pada turn ini | Jalankan hanya behavioral test Phase-12, lalu regression sesuai runbook |
| 2026-07-29 | Codex — Phase-12 behavioral closure | User mengonfirmasi behavioral test Offline Sale Sync PASS | Atomic price snapshot/variance, allowance consumption, canonical Sale effect, retry/idempotency, failure rollback, dan acknowledgement test selesai tanpa migration tambahan | Jalankan lima regression file sesuai runbook, lalu rerun postflight Phase-12 |
| 2026-07-30 | Codex — Phase-12 rollout closure dan Phase-13 retained queue | User mengonfirmasi lima regression serta postflight penutup PASS; Dexie v3 queue dan canonical RPC adapter dibuat tanpa membuka checkout offline | PWA lint PASS; production build PASS; payload/acknowledgement lokal tidak dihapus; no service-role/direct write; functional offline smoke belum berlaku | Lanjut snapshot catalog/pricing/Tax/Payment + allowance cache; entitlement tetap disabled |
| 2026-07-30 | Codex — G4 Phase-14 Offline catalog cache preflight | SELECT-only diagnostic authoritative snapshot RPC, Product-UOM, Pricelist, Tax, Payment, open Session/Terminal policy, allowance, submission, dan browser boundary dibuat; client resolver tidak ditebak | SHA-256 `0d05550e7461897e3962b3eea8d59b331c3ec9fead88cefacb649923073bb244`; one statement, mutation 0, parenthesis balanced, `git diff --check` PASS; live execution pending | Jalankan seluruh preflight Phase-14 dan kirim semua output termasuk INFO/SETUP |
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
| 2026-07-27 | Codex — Phase-42 grouped Product Import preflight | Phase-41 smoke ditutup PASS; diagnostic atomic Product/Product-UOM, reference, Tax, history, RPC, dan job readiness dibuat | SELECT-only static review; live Supabase result pending | Jalankan Phase-42 preflight dan kirim seluruh output |
| 2026-07-27 | Codex — Phase-40 forward-fix diagnostic correction | Postflight diubah dari full function-definition pattern menjadi direct `pg_proc.prosrc` inspection tanpa menjalankan validator | User reached step 2 and reported relation `v_parent_id`; forward migration treated applied | Rerun latest 4-check postflight only, then both behavioral tests |
| 2026-07-27 | Codex — Phase-42 grouped Product Import database | Live preflight ditutup PASS; grouped Product/Product-UOM validator, atomic guarded commit, history lock, postflight/test/runbook dibuat | User: preflight all pass; `git diff --check` clean; local SQL structural review; manual DB execution pending | Migration `20260727130000` → 11 PASS → behavioral test → Phase-40/38 regression |
| 2026-07-27 | Codex — Phase-42 create-job whitelist fix | Rollout pertama rollback pada brittle `pg_get_functiondef` text match; migration unapplied. Dynamic rewrite diganti full stable RPC body dengan signature/behavior lama dan tambahan `PRODUCT` | User error `MIGRATION_PRECONDITION_FAILED: create job whitelist changed`; transaction rollback menjaga schema/data lama | Rerun seluruh migration Phase 42 terbaru dari awal |
| 2026-07-27 | Codex — Phase-42 COMPLETE event forward fix | Migration utama applied; behavioral test rollback saat audit memakai event `COMMIT` yang tidak ada dalam constraint canonical | User error PostgreSQL 23514; canonical Phase-33/40 implementation memakai `COMPLETE`; forward migration/postflight local-ready | Migration `20260727140000` → 4 PASS → rerun Phase-42 test → Phase-40/38 regression |
| 2026-07-27 | Codex — Phase-43 grouped Product Import UI | Phase-42 database ditutup COMPLETE; Product ditambahkan ke template/export/mapping, preview dikelompokkan per `product_key`, dan semua referensi operasional memakai nama | User: forward fix/postflight/behavior/regression all pass; Backoffice lint PASS; production build PASS | Restart dan authenticated smoke sesuai runbook Phase 43 |
| 2026-07-27 | Codex — Phase-44 Product-Supplier Import preflight | Diagnostic SELECT-only untuk dependency Phase 42, reference aktif, UOM pembelian, existing relation, preferred uniqueness, guarded RPC, privilege, dan job readiness dibuat | Contract/source/RPC review; SQL aggregate-only; manual Supabase result pending | Jalankan preflight Phase 44 dan kirim seluruh output |
| 2026-07-27 | Codex — Phase-44 Product-Supplier Import database | Live preflight ditutup bersih; additive job type/dispatcher, guarded validator/partial commit, preferred switch ordering, postflight/test/runbook/manifest dibuat | User output seluruh blocker PASS; local checksum/diff/SQL structural checks; manual Supabase pending | Migration `20260727160000` → 11 PASS → behavioral test → Phase-42/40/38 regression |
| 2026-07-27 | Codex — Phase-45 Product-Supplier Import UI | Phase-44 DB ditutup COMPLETE; fixed template/export, SKU/nama references, preferred-switch UX, preview/error labels tanpa UUID ditambahkan | User: seluruh Phase-44 rollout PASS; Backoffice lint PASS; production build PASS | Restart dan authenticated smoke sesuai runbook Phase 45 |
| 2026-07-28 | Codex — Phase-46 Minimum Stock Produk-Gudang preflight | Phase-45 smoke ditutup; kontrak konfigurasi terpisah dari saldo dan diagnostic aggregate-only untuk pair/base UOM/saldo/movement/reference/job/schema dibuat | User melanjutkan setelah Phase-45; SQL tanpa mutation; manual live result pending | Jalankan Phase-46 preflight dan kirim seluruh output |
| 2026-07-28 | Codex — Phase-46 Minimum Stock database | Live preflight ditutup bersih; settings/audit, guarded optimistic RPC, fixed import dispatcher/validator/commit, postflight/test/runbook/manifest dibuat | User: seluruh preflight PASS/INFO, 3 eligible pair, zero balance/movement; checksum manifest recorded; manual rollout pending | Migration `20260728090000` → 12 PASS → behavior → Phase-44/42/40/38 regression |
| 2026-07-28 | Codex — app shell Back + breadcrumb | Phase-46 rollout ditutup dari konfirmasi user; history view internal, tombol Kembali, dan breadcrumb Beranda/Modul/Halaman diterapkan global serta direset saat Home/Company berubah | Backoffice lint PASS; production build PASS (28 static/dynamic app routes); authenticated click smoke menunggu user | Restart Backoffice, smoke navigation, lalu Phase-47 Minimum Stock UI |
| 2026-07-28 | Codex — Phase-47 Minimum Stock API/UI | Guarded API list/create/update, Inventory page, Base-UOM threshold UX, fixed template/export/preview/error guidance, dan runbook dibuat tanpa schema/stock mutation | Backoffice lint PASS; production build PASS (29 pages, dua route Minimum Stock); authenticated smoke pending | Restart dan jalankan smoke Phase 47, lalu audit exit G2 |
| 2026-07-28 | Codex — G3 Phase-1 Opening Stock preflight | SELECT-only audit dependency, Product-Gudang eligibility, saldo/movement/FIFO, Finance readiness, enum, dan missing canonical schema dibuat | Static review against current schema; live Supabase result pending | Jalankan preflight penuh dan kirim seluruh hasil sebelum migration Opening Stock |
| 2026-07-28 | Codex — G3 Phase-1 Opening Stock database | Live preflight ditutup bersih; Draft/Posted schema, guarded save/post RPC, atomic movement-balance-FIFO-HOLD event, audit/idempotency, postflight/test/runbook dibuat | User: 13 invariant PASS, 3 eligible pair, zero stock history; local static/diff checks; manual Supabase pending | Migration `20260728120000` → all postflight PASS → behavior → Phase-46/44/G1 regression |
| 2026-07-28 | Codex — G3 Phase-2 Opening Stock API/UI | User menutup seluruh database gate; guarded Draft/Posting API, Inventory UI, dan detail bukti saldo/movement/FIFO dibuat | DB user all success; Backoffice lint PASS; production build PASS (30 pages); `git diff --check` PASS | Restart Backoffice dan jalankan authenticated smoke runbook Phase 2 |
| 2026-07-28 | Codex — G3 stock actual/minimum alert read model | Gap smoke ditemukan: canonical Product dan Minimum Stock belum membaca saldo hasil Posting; stock overview API, total/per-Gudang display, dan low-stock indicator ditambahkan | Backoffice lint PASS; production build PASS (31 pages) | Restart, pastikan dokumen POSTED, cek Produk & Stok lalu Minimum Stock |
| 2026-07-28 | Codex — G3 Phase-3 Stock Real roadmap alignment | Source-of-truth diaudit ulang; Stock Real dipisahkan dari Product/Minimum config dan dibuat read-only dengan On Hand/Available/FIFO/last movement/filter | Backoffice lint PASS; production build PASS (31 pages); `git diff --check` PASS | Smoke Stock Real; setelah PASS lanjut Kartu Stok, bukan G4/G5 |
| 2026-07-28 | Codex — G3 Phase-4 Stock Movement preflight | Existing ledger dibandingkan dengan minimum Kartu Stok contract; SELECT-only audit dan runbook dibuat tanpa mutation | Static SQL review; live Supabase result pending | Jalankan preflight penuh dan kirim seluruh output |
| 2026-07-28 | Codex — G3 Phase-4 canonical Stock Movement database | Live preflight ditutup bersih; additive snapshot/backfill/enrichment, immutable guard, source uniqueness, postflight/test/runbook dibuat | User: 11 invariant PASS, 1 Opening row/pair/source, zero mismatch; static checks pending | Migration `20260728150000` → postflight → behavior → Phase-1/46/G1 regression |
| 2026-07-28 | Codex — G3 Phase-5 Stock Movement API/UI | User menutup canonical database all good; API tenant-scoped dan read-only Kartu Stok dengan snapshot, nama bisnis, source/actor aman, serta filter dibuat | Backoffice lint PASS; production build PASS (32 pages); authenticated smoke pending | Restart dan jalankan smoke Phase 5; G4/G5 tetap tertutup |
| 2026-07-28 | Codex — G3 Phase-6 Stock Transfer preflight | Kartu Stok smoke ditutup PASS; SELECT-only audit dibuat untuk legacy unsafe RPC, transfer pair/snapshot, balance/FIFO, Base UOM, Finance category, privilege, dan missing canonical document schema | SQL aggregate-only; no mutation; local static/diff checks | Jalankan seluruh preflight dan kirim output; Transfer mutation belum dibuka |
| 2026-07-28 | Codex — G3 Phase-6 canonical Stock Transfer database | Live preflight ditutup bersih; Draft/Posted/Canceled document, atomic Base-UOM balance, FIFO relocation/lineage, paired movement, role/idempotency/audit, legacy RPC retirement, postflight/test/runbook dibuat | User: all blockers PASS, zero Transfer history, 1 positive source/3 warehouses; checksum/static checks local | Migration `20260728180000` → 15 PASS → behavior → Phase-4/1/46/G1 regression |
| 2026-07-28 | Codex — G3 Phase-7 Stock Transfer API/UI | Database gate ditutup all success; guarded create/edit/post/cancel, source balance UX, movement/FIFO proof, role-aware Inventory menu, dan nomor Transfer di Kartu Stok dibuat | User: DB rollout/regression all success; Backoffice lint PASS; production build PASS (33 pages); `git diff --check` PASS | Restart dan authenticated smoke sesuai runbook Phase 7 |
| 2026-07-28 | Codex — G3 Phase-8 Stock Adjustment preflight | Transfer authenticated smoke ditutup; roadmap menempatkan canonical Adjustment sebelum Opname; diagnostic legacy/reason/balance/FIFO/Finance/privilege/schema dibuat | User menyatakan Transfer all success; 16 checks, forbidden mutation 0, dan `git diff --check` PASS | Jalankan preflight Phase 8 dan kirim seluruh output |
| 2026-07-28 | Codex — G3 Phase-8 canonical Stock Adjustment database | Live preflight ditutup bersih; reason master, final-quantity Draft/Posted/Canceled document, FIFO gain/loss, immutable Movement, Finance HOLD, role/idempotency/audit, postflight/test/runbook dibuat | User: seluruh blocker PASS, zero legacy/backfill, 2 positive FIFO layers/pairs; SHA-256 `602259e7...`; delimiter dan `git diff --check` PASS | Migration `20260728210000` → 16 PASS → behavior → Transfer/Movement/Opening/Minimum/G1 regression |
| 2026-07-28 | Codex — G3 Phase-9 Stock Adjustment API/UI | User menutup seluruh database gate; guarded API/UI final-quantity, reason direction, gain-cost override, Draft/Post/Cancel, FIFO/value proof, serta Kartu Stok source dibuat | User: DB all good; Backoffice lint PASS; production build PASS (34 pages); authenticated smoke pending | Restart dan jalankan smoke Phase 9; setelah PASS baru preflight Opname |
| 2026-07-28 | Codex — G3 Phase-10 Stock Opname preflight | User melanjutkan setelah Adjustment smoke; kontrak blind count nonblocking, recount, per-line supersede, dan posting via canonical Adjustment diaudit; diagnostic/runbook dibuat tanpa mutation | 22 aggregate checks; static SQL dan diff verification lokal | Jalankan preflight penuh dan kirim seluruh output; migration Opname belum dibuka |
| 2026-07-28 | Codex — G3 Phase-10 canonical Stock Opname database | Live preflight ditutup bersih; legacy table diperluas dengan blind-safe RPC, movement-window recount, attempt audit, supersede, dan atomic Adjustment posting | User: seluruh invariant PASS, zero legacy/overlap/backfill; checksum `23e50261...`; 14-check postflight dan behavior local-ready | Migration `20260728230000` → 14 PASS → behavior → Phase-8/6/4/1/46/G1 regression |
| 2026-07-28 | Codex — G3 Phase-11 Stock Opname Backoffice API/UI | Database gate ditutup all success; tenant-scoped report/review, recount/post/cancel RPC bridge, attempt timeline, Adjustment proof, role-aware Inventory menu, dan Escape modal dibuat | User: Phase-10 rollout/regression all success; Backoffice lint PASS; production build PASS (35 pages); four Opname routes detected | Restart dan authenticated smoke sesuai runbook Phase 11; POS blind count tetap G4 |
| 2026-07-28 | Codex — G3 Phase-12 Bundle foundation preflight | SO end-to-end smoke dicatat menunggu POS G4; sisa G3 dialihkan ke SELECT-only audit Bundle composition, UOM, virtual stock, privilege, dan guarded RPC gap | Existing Bundle table/RPC/spec audit; diagnostic aggregate-only; no schema/stock/checkout mutation | Jalankan Phase-12 preflight penuh dan kirim seluruh output |
| 2026-07-28 | Codex — G3 Phase-12 canonical Bundle foundation database | Live preflight ditutup bersih; atomic Product+composition, derived weight, immutable type, hard virtual-stock guard, audit/version, private expansion, reviewer availability, postflight/test/runbook dibuat | User: all invariant PASS, zero Bundle/component/backfill/physical stock; checksum `7a5c1fbd...`; local delimiter/diff verification | Migration `20260729010000` → 14 PASS → behavior → Product/Opname/Adjustment/Transfer/Movement/Opening/G1 regression |
| 2026-07-28 | Codex — G3 Phase-13/14 Bundle UI closure dan inventory-core exit preflight | Bundle DB/UI ditutup dari continuation user; SELECT-only reconciliation saldo–Movement–FIFO, source coverage, Bundle/Opname/browser invariant, fixture stress, serta explicit G4/G5 deferral dibuat | User: Bundle all good; diagnostic mutation scan dan diff check lokal | Jalankan Phase-14 preflight penuh dan kirim semua row |
| 2026-07-28 | Codex — G3 Phase-15 inventory-core stress behavior | Phase-14 live preflight ditutup PASS; rollback-safe fixture menguji two-layer FIFO, idempotent retry, 20 repeated Transfer contenders, Adjustment gain, reconciliation, dan Bundle virtual | User: seluruh core invariant PASS; `SETUP` dan G4/G5 `DEFERRED` expected; delimiter/diff check PASS; test SHA-256 `09CEBC17...0742` | Jalankan Phase-15 test, rerun Phase-14 preflight dan G1 closure |
| 2026-07-28 | Codex — G1/G2/G3 regression fixture compatibility fix | Rollback-only synthetic Movement fixtures memakai `PURCHASE`/`PURCHASE_RETURN`; canonical Adjustment hanya boleh berasal dari dokumen Adjustment lengkap; assertion history/RLS/FIFO tetap identik | User mengonfirmasi G1 closure terbaru SUCCESS setelah error PostgreSQL 23514 diperbaiki; audit juga menutup lima regression fixture lama dengan pola sama | Jalankan Phase-15 stress, lalu rerun Phase-14 preflight; tidak ada migration |
| 2026-07-28 | Codex — G3 closure dan G4 Phase-1 POS readiness preflight | Phase-14 rerun ditutup aman; SELECT-only audit dibuat untuk config POS, Session, Product-UOM/Bundle, Payment/Pricelist/Tax, Sale history, runtime snapshot, direct-write, dan legacy checkout authority | User: seluruh G3 core invariant PASS, `SETUP` rollback-expected, G4/G5 `DEFERRED`; diagnostic mutation scan 0 dan `git diff --check` PASS | Jalankan G4 Phase-1 preflight dan kirim seluruh output |
| 2026-07-28 | Codex — G4 Phase-2 canonical Cashier Session foundation | Phase-1 output direview valid; additive Session warehouse/cash/version, one-open guard, opening/closing stock snapshots, guarded open/close RPC, idempotent retry, RLS/audit, postflight/test/runbook dibuat tanpa checkout cutover | User: dependency/config/data PASS; expected blockers hanya legacy checkout/price/runtime; delimiter/mutation scan, manifest hash, dan `git diff --check` PASS; live rollout pending | Migration `20260729040000` → 13 PASS → behavioral test → G3/G1 regression |
| 2026-07-29 | Codex — G4 Phase-3 Atomic Sale runtime preflight | Phase-2 ditutup COMPLETE; diagnostic SELECT-only memetakan Session, legacy authority, pricing/payment/tax, Product-UOM/Bundle, Stock–Movement–FIFO, Finance category, snapshot/allocation, dan Draft/Post RPC gap | User mengonfirmasi Phase-2 all success; SQL static verification lokal | Jalankan Phase-3 preflight penuh dan kirim seluruh output; checkout tetap tertutup |
| 2026-07-29 | Codex — G4 Phase-4 Atomic Sale runtime database | Live preflight ditutup sesuai baseline; server price/Draft/Post, shortage-safe no-effect, FIFO/Bundle, Payment/Tax/rounding, receipt, Finance HOLD, idempotency, postflight/test/runbook dibuat; legacy browser checkout retired | User: seluruh prerequisite/data invariant PASS, expected 2 legacy blocker + 4 setup; migration SHA-256 cocok manifest; delimiter/parenthesis seimbang; postflight SELECT-only 17 checks; behavioral test rollback-safe; `git diff --check` bersih | Migration `20260729070000` → 17 PASS → behavioral test → G4/G3/G2/G1 regression |
| 2026-07-29 | Codex — G4 Phase-5 POS online integration | Phase-4 user gate ditutup clear; PWA mock diganti login/context/Session/real catalog/canonical Draft/Post/shortage/receipt; Backoffice legacy checkout route diganti canonical action dan offline sync dikarantina | PWA lint/build PASS; Backoffice lint/build PASS (36 app routes); active-path scan zero `MOCK_PRODUCTS`/legacy checkout; authenticated smoke pending | Jalankan smoke Phase-5; setelah PASS lanjut Draft lock/list + split payment |
| 2026-07-29 | Codex — G4 Phase-5 PWA tablet/Pricelist/receipt closure | Terminal/Gudang user smoke diterima; PWA tablet-first, reset POSTED, receipt print-tab, Customer Pricelist AUTO/override, guarded wrapper/resolver, postflight/test/runbook dibuat | PWA lint/build PASS; Backoffice lint/build PASS (36 routes); SQL structural/diff check PASS; browser preview connector gagal attach; live DB/UI smoke pending | Migration `20260729100000` → 4 PASS → behavior/regression → hard refresh + tablet smoke |
| 2026-07-29 | Codex — G4 Phase-5 Moka-like tablet hierarchy revision | Redesign pertama ditolak user karena hierarchy/tombol lemah; shell POS dirombak menjadi two-pane high-contrast, numbered checkout stages, solid add/category/actions, dan sticky total/action tanpa dependency baru | PWA lint PASS; production build PASS; browser preview connector tidak dapat attach; authenticated visual smoke pending | Restart/hard refresh PWA dan validasi hierarchy pada tablet sebelum rollout closure dilanjutkan |
| 2026-07-29 | Codex — G4 Phase-6 Sale Draft edit-lock preflight | Phase-5 rollout/PWA smoke ditutup all clear; SELECT-only diagnostic dan runbook dibuat untuk Draft lifecycle, same-Store continuation, stale age, side effects, lock/audit/RPC/schema/privilege | Source-of-truth audit terhadap canonical Sale runtime dan approved Draft contract; local SQL safety verification pending | Jalankan Phase-6 preflight penuh dan kirim seluruh output |
| 2026-07-29 | Codex — G4 Phase-6 Sale Draft edit-lock foundation | Live preflight ditutup bersih; Draft numbering/metadata, same-Store visibility/list, heartbeat lock, confirmed takeover, force release, cancel, guarded Save/Post core boundary, postflight/test/runbook dibuat | User: all data invariant PASS, zero Draft, expected SETUP only; migration checksum/static checks local; manual rollout pending | Migration `20260729120000` → all postflight PASS → behavior → Phase-5/4/Store Manager/G1 regression |
| 2026-07-29 | Codex — G4 Phase-7 Sale Draft PWA UI | User menutup rollout Phase-6 all-good; PWA mendapat daftar Draft per Store, metadata user-facing, resume+server repricing, payment reconfirm, heartbeat, stale takeover, force release, cancel, dan Escape panel | PWA lint PASS; production build PASS; browser visual connector gagal tersambung sehingga authenticated tablet smoke menunggu user | Restart/hard refresh dan jalankan runbook Phase-7; split payment tetap tertutup |
| 2026-07-29 | Codex — G4 Phase-7 custom action dialog | Native browser confirm/prompt dihapus dari PWA; takeover, force release, cancel Draft, transaksi baru, dan tutup sesi memakai modal konsisten dengan textarea alasan tervalidasi dan Escape | Scan `window.confirm/prompt` zero; PWA lint PASS; production build PASS | Hard refresh lalu smoke seluruh modal Phase-7 |
| 2026-07-29 | Codex — G4 Phase-8 Split Payment preflight | User menerima Draft/custom modal; audit SELECT-only dibuat untuk multi-leg server loop, fee per leg, Store eligibility, posted snapshot/total/tender, duplicate method, payment-leg identity, dan privilege | SQL single-statement SELECT-only; no schema/data mutation; user execution pending | Jalankan Phase-8 preflight dan kirim seluruh output |
| 2026-07-29 | Codex — G4 Phase-8 Payment-Leg identity foundation | Live preflight bersih; forward migration menambah stable UUID per leg, legacy normalization, duplicate key/metode guard, unique payment identity, receipt traceability, postflight/test/runbook | User: dependency/runtime/data PASS, 3 active methods, 1 posted Sale/payment, expected identity SETUP only; static SQL/hash verification local | Migration `20260729150000` → 10 PASS → behavior → Phase-6/5/4/G1 regression |
| 2026-07-29 | Codex — Phase-8 behavior fixture correction | Behavior pertama berhenti pada precondition karena Company sintetis hanya mendapat Cash mandatory; fixture sekarang menambah metode `CUSTOM` kedua secara rollback-only dan memilih kedua ID secara deterministik | Error terjadi sebelum assertion/runtime mutation; migration tidak diubah dan tidak perlu direrun; test static/diff check PASS | Rerun behavior Phase-8 terbaru, lalu regression bila PASS |
| 2026-07-29 | Codex — G4 Phase-9 Split Payment PWA UI | User menutup Payment-Leg rollout sukses; PWA memakai stable key per leg, exact base-total split, duplicate-method prevention, Cash tender/change, per-leg proof, fee estimate, dan tablet-friendly summary | PWA lint PASS; production build PASS; browser connector gagal attach sehingga authenticated visual smoke belum diklaim | Restart/hard refresh dan jalankan runbook Phase-9; setelah PASS lanjut online E2E + true concurrent double-post |
| 2026-07-29 | Codex — Phase-9 POS visual correction | User menemukan field overlap, istilah membingungkan, dan icon action tidak center; dua kolom checkout dihapus, input mendapat padding/containment, copy diganti bahasa Kasir, Cash auto-fill, dan seluruh icon-only Keranjang/modal/struk memakai ukuran tetap + grid centering tanpa baseline/transform | PWA lint PASS; production build PASS; browser connector masih gagal attach, jadi visual smoke tetap manual | Restart/hard refresh PWA dan validasi icon Keranjang serta satu/dua cara bayar pada tablet |
| 2026-07-29 | Codex — G4 Phase-10 Online Checkout stress preflight | User meminta lanjut sesuai rundown; diagnostic SELECT-only dibuat untuk server lock/idempotency, identity uniqueness, posted final effect, Payment/Movement/FIFO/stock reconciliation, dan fixture dua Kasir | Parenthesis balanced; mutation scan hanya menemukan kata dalam function definition/index privilege strings; `git diff --check` PASS | Jalankan preflight Phase-10 penuh dan kirim seluruh output |
| 2026-07-29 | Codex — Phase-10 preflight execution-chain correction | Live result menunjukkan false blocker karena diagnostic membaca public wrapper saja; revision membaca wrapper Sale lock + private core stock/FIFO/idempotency dan menghitung Company Owner/Admin/Super Admin sebagai effective POS users | Seluruh live data invariant lain PASS; one Store punya Terminal/payment/stock-FIFO; static balance dan diff check PASS | Rerun preflight terbaru; jangan membuat migration dari false blocker lama |
| 2026-07-29 | Codex — G4 Phase-10 true-concurrent Post harness | User menutup preflight seluruhnya PASS; staging-only CLI mengirim 2–20 Post dengan satu key dan memverifikasi single final effect, Payment identity, Movement, Event, serta audit tanpa service role | `node --check`, PWA lint, production build PASS; harness sengaja belum dieksekusi karena mem-post Draft/stok sungguhan | Buat Draft disposable staging, jalankan runbook, kirim JSON saja, lalu rerun preflight |
| 2026-07-29 | Codex — Phase-10 harness Supabase config fix | Eksekusi pertama gagal sebelum Auth karena script membaca placeholder `pwa/.env`; loader sekarang menolak placeholder dan fallback ke public config `backoffice/.env.local` seperti runtime PWA | Error `ENOTFOUND your-project-id.supabase.co` tidak mencapai Auth/RPC dan tidak membuat mutation; syntax/lint/build diverifikasi ulang | Jalankan ulang command yang sama; tidak perlu membuat ulang Draft akibat error konfigurasi ini |
| 2026-07-29 | Codex — Phase-10 harness Draft payment preparation fix | Instruksi awal keliru mewajibkan Draft sudah mempunyai payment intent, padahal `Simpan Draft` normal mengosongkan Payment; harness sekarang memilih metode non-proof eligible, memprioritaskan Cash, menyimpan payment intent sebesar total, lalu menjalankan Post concurrent | Dua eksekusi user berhenti pada assertion sebelum Save/Post sehingga tidak membuat final effect; contract diselaraskan dengan `handlePostSale` PWA | Jalankan ulang Draft normal yang sama; tidak perlu membayar Draft lewat UI |
| 2026-07-29 | Codex — Phase-10 harness authoritative version fix | Percobaan setelah payment preparation membuat semua Post ditolak `MASTER_VERSION_CONFLICT`; harness tidak lagi mempercayai version response intermediate dan membaca ulang row Draft authoritative setelah Save sebelum fan-out | Semua 20 Post ditolak sebelum final effect; payment intent Draft mungkin sudah tersimpan tetapi Sale/stock/payment final belum dibuat | Jalankan ulang Draft yang sama setelah local syntax/lint/build PASS |
| 2026-07-29 | Codex — Phase-10 stress gate paused | Authoritative reread tetap menghasilkan 20 `MASTER_VERSION_CONFLICT`; repeated user execution dihentikan dan harness tidak lagi diklaim local-ready | Tidak ada response Post sukses, jadi tidak ada final Sale/stock/payment effect dari percobaan ini; root cause orchestration belum terbukti | Jangan rerun; lanjutkan development independen, tetapi blok offline/pilot/deploy sampai concurrency gate diperbaiki |
| 2026-07-29 | Codex — Phase-10 live root-cause audit | Service-role read-only audit membuktikan Draft tetap DRAFT v6 dengan satu payment intent; audit terakhir `STOCK_SHORTAGE`; requirement 7 versus stock 1. Satu shortage response tertutup oleh 19 stale-version errors | Query hanya SELECT; tidak ada data berubah. Harness ditambah stock precheck dan shortage-first reporting | Gunakan fixture baru qty ≤ stok bila gate dilanjutkan; Draft lama jangan direrun |
| 2026-07-29 | Codex — Phase-10 concurrent gate closure | User menambah stok dan harness mencapai final verification; Kasir melihat Event count 0 karena Finance RLS, bukan Event hilang. Server read-only membuktikan POSTED, 1 Movement, 1 Payment, 1 POST audit, 1 SALE_POSTED Event HOLD | Seluruh concurrency assertions sebelum Event sudah lolos; service query SELECT-only; harness Finance assertion dihapus; syntax/lint/build PASS | Jangan rerun Sale POSTED; lanjut gate G4 berikutnya |
| 2026-08-05 | Codex — G4 Phase-58 POS Negative Stock policy foundation | User meminta lanjut sesuai rundown setelah Phase-56 database PASS dan Phase-57 UI local-ready; menambahkan default-OFF entitlement/policy, opt-in Gudang, permission user, config audit, serta future authorization/allocation/replenishment schema tanpa shortage bypass | Migration/postflight/rollback-safe behavior/runbook/manifest dibuat; FK canonical diverifikasi; parenthesis seimbang; SHA-256 `c5d9823b...1bb76`; `git diff --check` bersih; live rollout pending | Migration `20260805190000` → all-PASS postflight → behavior → listed regression → closing postflight; jangan aktifkan operasional sebelum runtime phase berikutnya |
| 2026-08-05 | Codex — G4 Phase-59 POS Negative Stock runtime preflight | User mengonfirmasi seluruh Phase-58 PASS; menambahkan diagnostic SELECT-only untuk configuration chain, tenant permission, provisional cost, current Stock–FIFO–Movement, Movement negative snapshot guard, online allocation gap, Offline/import isolation, serta G5/G6 dependency | Satu statement SELECT-only; expected tiga runtime `SETUP` dan satu cross-gate `DEFERRED`; local parenthesis/diff validation PASS; live output pending | Jalankan seluruh preflight Phase-59 dan kirim semua row; `BLOCKER` wajib nol sebelum runtime foundation |
| 2026-08-05 | Codex — G4 Phase-60 POS Negative Stock online runtime | Phase-59 live output diterima tanpa blocker/review; menambahkan gated online non-Bundle authorization, limit/reason, last-FIFO/Product-COGS provisional cost, negative Sale Movement, outstanding allocation, dan automatic incoming-batch reconciliation | Migration/postflight/rollback-safe behavior/runbook/manifest local-ready; parentheses seimbang; SHA-256 `7e2b56db...6dd9c`; `git diff --check` bersih; live rollout pending | Migration `20260805220000` → all-PASS postflight → behavior → listed regression → closing postflight; konfigurasi live tetap OFF sampai UI phase |
| 2026-08-05 | Codex — Phase-60 Offline reservation guard forward fix | Behavioral test membuktikan guard Phase-11 salah menolak authorized Sale dari stok 1 ke -2 saat reservasi Offline nol; forward migration memisahkan active reservation, exact same-transaction Sale authorization, replenishment, dan negative INSERT | Error terjadi di dalam transaksi rollback test; migration Phase-60 tidak diedit. Forward-fix SHA-256 `6fbd6f8e...26ac7`; postflight, stale-authorization regression, dan `git diff --check` local-ready | Migration `20260805230000` → 4 PASS → rerun behavior Phase-60 → behavior Phase-11 → regression lain → kedua closing postflight |
| 2026-08-05 | Codex — Phase-60 authorization transaction-marker fix | User rerun membuktikan fix pertama masih berhenti pada final guard raise; inferred actor/time/status match diganti marker Sale transaction-local yang dibuat oleh authorization INSERT dan diverifikasi bersama exact stock scope/balance | Eksekusi pertama migration kedua gagal parse sebelum ledger karena alias reserved `authorization`; alias diganti `authz`, checksum baru `76a62871...7034b`, manifest/runbook diselaraskan | Jalankan migration `20260805233000` terkoreksi → 4 PASS postflight → rerun behavior Phase-60 |
| 2026-08-05 | Codex — Phase-60 Offline guard responsibility fix | User membuktikan marker fix tetap ditolak final fallback; desain dikoreksi pada boundary sebenarnya: Offline guard hanya melindungi active reserved quantity dan tidak lagi menduplikasi authorization Sale/Movement | Migration `20260805234500`, four-check postflight, marker cleanup, corrected Phase-60 behavior; SHA-256 `55b6b82e...cb0d92`; static hash/SELECT-only/diff checks local-ready | Jalankan migration → 4 PASS → rerun behavior Phase-60; bila PASS baru Phase-11 reservation regression |
