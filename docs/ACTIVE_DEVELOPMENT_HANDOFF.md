# Active Development Handoff — KGS POS

**Status dokumen:** ACTIVE — wajib diperbarui setiap agent
**Terakhir diperbarui:** 2026-07-29
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

Catatan UX aktif:

- label UOM operasional memakai `name` (`Ketul`, `Dus`), bukan kode internal
  (`UOM-02`, `UOM-03`);
- kode tetap disimpan sebagai identifier master;
- Product menyimpan stok pada Base UOM; kemasan memakai faktor langsung ke base;
- kemasan terbesar otomatis menjadi acuan berat/rekomendasi UOM pembelian.

## 3. Fase Aktif

**G4 Phase 10 — True-concurrent Post stress**

Payment-Leg identity rollout, corrected behavioral test, dan regression telah
dikonfirmasi sukses oleh user. PWA sekarang membagi total server ke satu atau
lebih Payment Method dengan stable `clientPaymentKey`, duplicate-method
prevention, Cash tender/change, proof per leg, serta fee estimate. Server tetap
menjadi authority untuk total, fee, persisted Payment, stock, FIFO, dan
Financial Event.

Boundary aktif:

- `pwa/scripts/g4-phase10-concurrent-post.mjs`;
- `pwa/package.json`;
- `docs/runbooks/G4_PHASE10_TRUE_CONCURRENT_POST_STRESS.md`.

User telah menjalankan preflight terbaru dan seluruh check yang menentukan
kelayakan berstatus `PASS`; baris `INFO` mengonfirmasi browser tidak memiliki
direct final write. Percobaan harness staging belum membuktikan concurrency.
Live audit read-only atas `DRF-20260729-000005` menemukan kebutuhan Base UOM 7
sementara stok Gudang hanya 1. Request pertama benar masuk jalur Post lalu
menulis audit `STOCK_SHORTAGE` dan mempertahankan Draft; 19 request lain memakai
versi lama dan ditolak. Harness sebelumnya salah memprioritaskan daftar error
sehingga shortage terlihat seperti kegagalan version menyeluruh. Harness
sekarang memeriksa stok sebelum fan-out dan melaporkan shortage sebelum error
concurrent. Setelah stok ditambah, harness melewati seluruh assertion
concurrency dan final effect sampai pemeriksaan Financial Event. Pemeriksaan itu
melihat `0` hanya karena akun Kasir tidak mempunyai visibilitas Finance.
Read-only server audit membuktikan Sale `POSTED`, tepat 1 Movement, 1 Payment,
1 POST audit, dan 1 `SALE_POSTED` Financial Event berstatus `HOLD`. Gate
true-concurrent dinyatakan `COMPLETE`; harness tidak lagi mengassert tabel
Finance dari akun Kasir. Offline sync tetap mengembalikan
`OFFLINE_SYNC_NOT_ENABLED` tanpa mutation. Customer Balance/Ketul, Return,
Expense, Deposit, settlement, refund, dan Finance journal tetap tertutup.

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

Database dan authenticated UI Sale Draft sudah ditutup user sebagai all-good.
Payment-Leg identity rollout, corrected behavior fixture, dan regression juga
telah dikonfirmasi sukses. Gate aktif sekarang adalah authenticated tablet
smoke Split Payment sesuai
`docs/runbooks/G4_PHASE9_SPLIT_PAYMENT_PWA_UI.md`.

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

Phase-10 sudah tertutup; jangan rerun Draft yang kini `POSTED`. Next safe step
adalah melanjutkan gate G4 berikutnya sesuai roadmap. Receipt
Supplier/Purchase Return tetap G5.

Jangan rerun migration Phase 46, Phase 44, atau migration/forward fix Phase 42.

Jangan mengubah migration Phase 30–33 yang sudah applied; explicit-code CSV
lama tetap compatibility surface selama transisi.
Product Brand tetap menunggu canonical master.
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
