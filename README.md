# KGS POS

Panduan penggunaan lengkap: [Manual Pengguna KGS POS](docs/MANUAL_PENGGUNA_KGS_POS.md).

G6 Phase 8 historical Finance closure sudah database-live dan user-confirmed
PASS. Seluruh 32 Financial Event historis telah final: 31 Event mempunyai tepat
satu canonical Journal dan satu exact-zero Goods Receipt ditutup sebagai
`NO_FINANCIAL_EFFECT`; `HOLD=0`, queue aktif nol, exception terbuka nol, serta
seluruh jurnal seimbang. FIFO dan Inventory GL KGS sama tepat Rp89.485.000;
Supplier AP dan Customer Balance juga reconcile per Company.

Gate aktif kembali ke PRD-1 predeploy closure. Local Backoffice lint/build dan
PWA lint/build 14 Agustus 2026 PASS; hasil client build tidak memuat marker
service-role/private key. PWA masih memberi warning non-blocking untuk main
chunk 555,22 kB (153,61 kB gzip), yang harus diukur pada Preview. Remaining
manual gate adalah authenticated role/preset/two-Company E2E, Auth redirect,
Storage branding/cache, dan Vercel Preview smoke; ini belum merupakan approval
Production.

Dua project Vercel staging dan satu Supabase staging terpisah sudah live.
Fresh-database migration chain terverifikasi lengkap sampai G6 Phase 8G setelah
baseline schema pra-ledger dan compatibility bridge ditambahkan. Alias stabil:
`https://pointofsales-kgs-staging.vercel.app` dan
`https://kgs-pos-pwa-staging.vercel.app`. Public HTTP/API/secret-boundary smoke
PASS; authenticated role/terminal smoke serta Supabase Auth invite/recovery
redirect masih menjadi manual staging gate dan belum merupakan Production
approval.

PWA Expense Settlement modal menerima deployment UI forward-fix pada tanggal
yang sama: nested dialog sekarang centered, field tidak overlap, konten scroll
internal, dan tablet/mobile layout bounded. Tidak ada business flow atau RPC
yang berubah; lint/build PASS dan visual authenticated smoke menunggu Vercel
redeploy dari Git.

Manual logout Backoffice dan PWA juga diisolasi per aplikasi (`local` scope),
agar logout pada satu domain tidak lagi mencabut refresh token aplikasi lain
untuk user Supabase yang sama. Invalid/expired server session tetap fail-closed.
Behavioral pertama menemukan Goods Receipt sah bernilai Rp0 (seluruh source
amount dan batch value nol); transaksi rollback tanpa live effect. Forward-fix
`20260814143000` sudah database-live dan terbukti menutup event tersebut sebagai
`CANCELED / NO_FINANCIAL_EFFECT`, bukan membuat jurnal nol. Runtime positif
tetap source-verified dan tidak dilonggarkan.

## Current development status (2026-08-13)

Atas revisi user, pemisahan Backoffice Invoice/Surat Jalan sekarang user-pass:
Sales hanya memiliki Invoice, sedangkan Inventory mempunyai Surat Jalan
quantity-only untuk print dan lifecycle. Permission additive
`inventory.delivery_documents`, delivery-only RPC/API/UI, pre/postflight, dan
behavior test pada migration `20260813150000` telah dilaporkan sukses; POS print authority,
canonical Sale, nomor, snapshot, Stock, dan Finance tidak berubah. Backoffice
lint dan production build PASS (67 route/page entries); manual database rollout
dan authenticated role smoke masih pending.

POS pre-presentation smoke menemukan satu stale direct read terhadap protected
`customer_balance_company_policies` setelah ACP-6D. Client sudah dikoreksi
untuk memakai hasil guarded open-session Payment Method RPC sebagai authority
availability Customer Balance; tidak ada grant/RLS/migration yang dibuka.
PWA lint dan production build setelah koreksi PASS. Hard refresh/Service Worker
update dan authenticated POS smoke tetap wajib sebelum demo.

ACP-4B database rollout, postflight, and behavior are user-confirmed PASS:
`inventory.master_data` is the first complete custom
permission enforcement slice. Category/UOM/Warehouse/Category-Tax mutations
are guarded server-side, direct Product Category column grants are closed,
navigation and the consolidated Master API consume effective capabilities,
and the user-detail modal can edit the active preset. ACP-4C Product preflight
returned no blockers. User kemudian mengonfirmasi seluruh SQL ACP-4C dan ACP-4D
PASS/INFO. Product management/reference, Product/UOM/Tax mutation, Product
import, navigation, dan Data Exchange memakai authority efektif masing-masing.
Stock Real
komposit kini terpisah dari Kartu Stok, valuasi/Movement terakhir dihitung di
server, dan export mempunyai authority masing-masing. ACP-4E
migration/postflight/behavior/closing kemudian user-confirmed PASS/INFO;
Transfer Stok sekarang live ENFORCED. ACP-4F migration, postflight, behavior,
G3 Opname regression, dan closing generic juga user-confirmed PASS/INFO;
Penyesuaian Stok dan Stock Opname sekarang live ENFORCED setelah seluruh SQL
ACP-4G user-confirmed PASS/INFO. ACP-4H Stok Awal database, postflight,
behavior, regression, dan closing juga user-confirmed PASS. Seluruh rollout,
postflight, behavior, regression, dan closing ACP-4I Minimum Stock kemudian
user-confirmed PASS. Sembilan key Inventory sekarang live ENFORCED. ACP-5A
Customer preflight, migration, postflight, behavior, regression, dan smoke
kemudian user-confirmed PASS; `contacts.customers` sekarang live ENFORCED.
ACP-5B Supplier preflight, migration, postflight, behavior, regression, dan
authenticated smoke kemudian user-confirmed PASS; `contacts.suppliers`
sekarang live ENFORCED. ACP-5C Supplier Order preflight kemudian dikonfirmasi
tanpa blocker dan seluruh migration, postflight, behavior, serta regression
user-confirmed PASS; `purchase.supplier_orders` sekarang database-live
ENFORCED. Authenticated preset/two-Company smoke tetap menjadi closing UAT.
ACP-5D Purchase Return preflight, migration, postflight, behavior, dan
regression kemudian user-confirmed PASS; `purchase.purchase_returns` sekarang
database-live ENFORCED. Authenticated preset/two-Company smoke tetap menjadi
closing UAT. ACP-5E preflight, migration, postflight, behavior, dan regression
kemudian user-confirmed PASS; `sales.sales_documents` sekarang database-live
ENFORCED. Authenticated preset/two-Company smoke tetap closing UAT. ACP-5F
`sales.pricelists` preflight, migration, postflight, behavior, dan regression
kemudian user-confirmed PASS; runtime database sekarang ENFORCED, sedangkan
authenticated preset/two-Company smoke tetap closing UAT. Resolver POS
online/offline tetap memakai authority terpisah. ACP-5G `sales.bundles`
preflight, migration, postflight, behavior, dan regression kemudian
user-confirmed PASS; runtime database sekarang ENFORCED. Gate aktif berpindah
hanya ke ACP-5H `sales.sales_returns`; seluruh rollout dan regression kemudian
user-confirmed PASS. ACP-5 ditutup database-live, sedangkan authenticated matrix
tetap closing UAT. ACP-6A Expense kemudian user-confirmed PASS dan database-live
ENFORCED. ACP-6B Setor Kas migration, postflight, behavior, dan regressions
juga user-confirmed PASS; authenticated smoke ditunda ke closing UAT. Gate
ACP-6C Deposit Variance database/postflight/behavior/regression kemudian
user-confirmed PASS; smoke ditunda ke closing UAT. ACP-6D Customer Balance,
forward-fix mode `WIND_DOWN`, postflight, behavior, serta regression
Phase-49/52/56 seluruhnya user-confirmed PASS. Smoke Finance tetap ditunda ke
closing UAT. ACP-6E Supplier Invoice migration, postflight, behavior, dan
regressions sudah user-confirmed PASS; authenticated smoke tetap closing UAT.
ACP-6F Supplier Payment migration, postflight, behavior, dan regressions sudah
user-confirmed PASS; authenticated smoke tetap closing UAT. ACP-6G Payment
Method migration, postflight, behavior, regression, dan closing postflight
sekarang user-confirmed PASS; runtime database live `ENFORCED`. Gate aktif
berpindah ke ACP-7 security closure. Consolidated ACP-7/PRD-1 live preflight
terbaru tidak memiliki `BLOCKER`: chain ACP-7 25/25, chain PRD-1 32/32, dan 24
permission enforcement PASS; tenant/Stock/Sale/Document/Journal invariant
bersih serta dua Company aktif. Regular multi-Company identity sudah PASS.
PRD-1 belum ditutup karena distinct override dua Company, fixture minimum pada
satu Company, dan empat role UAT masih `SETUP`.
Sebelum UAT, lifecycle akses user per Company sudah database/postflight/behavior
user-confirmed PASS:
Company selector eksplisit pada detail user, edit role/Store tenant-scoped,
guarded revoke, last-owner protection, override cleanup ber-audit, serta active
context repair. Authenticated UI smoke masih menunggu user.

KGS POS adalah aplikasi Point of Sale dan mini ERP multi-Company yang sedang
dibangun bertahap dengan Supabase sebagai backend, Next.js untuk Backoffice,
serta React/Vite PWA untuk kasir.

> Dokumen ini adalah README aplikasi yang hidup. Setiap build yang mengubah
> status modul, cara menjalankan aplikasi, migration chain, compatibility, atau
> roadmap wajib memperbarui file ini bersama kode dan handoff.

**Status terakhir:** 14 Agustus 2026
**Gate aktif:** PRD-1 authenticated role/preset/two-Company E2E dan Vercel
Preview readiness. ACP-4 sampai ACP-7 database enforcement serta G6 Phase 8
historical Finance closure user-confirmed PASS. Local lint/build dan secret
bundle scan Backoffice/PWA PASS. Fixture role yang belum lengkap tetap manual
UAT scope, bukan alasan melemahkan permission.
**Runtime:** lokal; Supabase aktif; Vercel Preview belum dibuka

## Kondisi Aplikasi Saat Ini

| Area | Status | Catatan |
|---|---|---|
| Tenant, role, RLS, active Company | Complete | Boundary lintas-Company dan browser mutation sudah diuji |
| Custom permission per submodul | ACP-4B sampai ACP-4I, ACP-5A sampai ACP-5H, dan ACP-6A sampai ACP-6G database PASS | Seluruh key yang dibuka pada Inventory, Contacts/Purchase/Sales, dan Finance database-live ENFORCED; ACP-7 role/preset/two-Company/authenticated closure aktif |
| Product Category, UOM, Warehouse | Complete | Canonical master, guarded API/UI, versioning |
| Product + multi-UOM | Complete | Atomic Product/Product-UOM, base UOM, harga per UOM |
| Supplier + Product-Supplier | Complete | Preferred Supplier, purchase UOM, audit |
| Customer + Customer Category | Complete | Walk-In system, credit boundary, grouping induk/cabang |
| Pricelist | Complete pada online core | Global/Customer reusable; resolver aktif pada canonical Draft/Post |
| Payment Method | Online split-payment ready for smoke | Store scope, fee/proof snapshot, stable payment-leg identity, dan tablet multi-metode UI aktif |
| Transaction Category + minimum COA | Complete pada master dan posting historis | 26 kategori, guarded COA, explicit fallback, rule snapshot, dan Phase 8 controlled posting PASS |
| Tax Sales/Purchase | Sales resolver aktif pada online core | Guarded master/version/assignment; Purchase/jurnal tetap belum dibuka |
| Pengaturan Modul | Entitlement + Offline/Stock Minus policy UI ready for smoke | Super Admin mengelola entitlement; Owner/Admin mengelola policy Company, opt-in Gudang penjualan, dan izin user melalui guarded RPC; Store Manager read-only untuk Stock Minus |
| App Launcher & shell | UXD-2 local-ready; authenticated smoke pending | Home bersih hanya card modul; klik membuka landing submodul. Fast Link search hanya menyaring catalog server-authorized. Logo Company di header menjadi tombol Home. API/RPC/RLS tetap authority final |
| Company branding | BRD-1 database USER VERIFIED; BRD-2 upload/UI LOCAL READY | Server-only Storage upload, magic-byte/MIME/extension/size/SHA-256 validation, generated tenant path, version/audit, cleanup, remove modal, dan Company setting tersedia; authenticated multi-Company smoke pending |
| Sales Invoice, Surat Jalan & Ongkir | SLD-R4 USER VERIFIED | Checkbox Delivery berada di final checkout; ongkir ikut total/payment/offline. Full remaining Return menawarkan refund ongkir eksplisit default OFF; historical Sale/Refund journal sudah ditutup melalui G6 Phase 8 |
| Tax assignment Product/Category | Complete pada Sales online boundary | Category default dan Product inheritance/override memakai nama Tax Rule; resolver aktif saat Draft/Post |
| Tax resolver/calculator | Complete pada Sales online boundary | Effective-dated resolver + deterministic calculation dipakai Draft/Post; Purchase/jurnal belum dicutover |
| Master Import/Export | Complete untuk 7 simple master | Phase 40 DB dan Phase 41 authenticated UI smoke PASS |
| Global Data Exchange Center | DEX-4 navigation cutover local-ready; closing smoke pending | Data Exchange menjadi satu-satunya visible Import/Export entry; role-aware 10 master CSV, tujuh Finance XLSX, serta guarded import tersedia. Backend compatibility lama tetap aktif |
| Generic import framework | Phase 47 UI local-ready | Grouped Product, Product-Supplier, dan Minimum Stock Produk–Gudang database PASS; Minimum Stock guarded API/UI serta fixed import-export lint/build PASS dan menunggu authenticated smoke; Opening Stock, transaksi, Company, dan Staff/password tetap workflow khusus |
| Stock ledger/FIFO production | Complete pada G3 core boundary | Integrated stress/regression diteruskan tanpa error dan Phase-14 rerun seluruh invariant PASS; Sale/Return/Receipt coverage pindah ke gate transaksi |
| POS checkout/offline production | Online checkout dan Offline core COMPLETE sampai Phase 24 | Retained queue/status-first recovery, time-bounded sync, controlled disconnect/reconnect, single final effect, allowance, dan Stock–Movement–FIFO closing diagnostics dikonfirmasi PASS |
| Sales Return | Complete pada required-approval boundary | PWA Draft serta Backoffice review/post berhasil diuji user; guarded cancel/post, stock/FIFO/Movement/refund, dan historical Finance journal PASS. Posting Kasir/optional approval tetap deferred |
| Expense & Cash In | Deposit variance operational UI complete | Actual/return/additional dan Setor Kas online tersedia sesuai channel; historical Expense/Deposit/Variance posting sudah reconcile melalui G6 Phase 8. Bank matching dan offline Expense/Deposit tetap di luar scope aktif |
| Customer Balance | Phase 56 COMPLETE; Phase 57 UI local-ready | Full-balance ONLINE tender database PASS. POS menampilkan saldo, auto-fill seluruh saldo, minimum tambah belanja, dan receipt; authenticated tablet smoke dapat digabung pada E2E berikutnya |
| POS Stock Minus | Phase 60 database COMPLETE; Phase 61 operational UI accepted | User melanjutkan roadmap setelah guarded Backoffice config dan POS reason/retry tersedia. Default tetap OFF, online non-Bundle saja; replenishment dari Goods Receipt menjadi dependency G5 |
| Purchasing end-to-end | Supplier Payment user-reported PASS; corrective tolerance pending | Historical Goods Receipt, Supplier Invoice, dan Supplier Payment sudah mempunyai canonical Journal atau exact no-effect closure; optional tolerance tetap forward-only |
| Finance posting/reconciliation | G6 Phase 8 historical closure USER VERIFIED | 31 Event/Journal POSTED, 92 lines, satu exact no-effect Event, HOLD/queue/exception nol. FIFO–Inventory GL Rp89.485.000 matched; Supplier AP dan Customer Balance reconcile. Buku Besar, Journal Entries, dan XLSX bulanan tetap menunggu authenticated cross-role/cross-Company Preview smoke |

Status operasional detail dan manual gate terbaru ada di
[`docs/ACTIVE_DEVELOPMENT_HANDOFF.md`](docs/ACTIVE_DEVELOPMENT_HANDOFF.md).

## Struktur Repository

```text
backoffice/   Next.js Backoffice untuk master dan administrasi
pwa/          React/Vite PWA kasir; online canonical checkout local-ready
supabase/     migration, diagnostic, behavioral test, dan schema reference
docs/         requirement, spesifikasi, audit, runbook, dan handoff
```

Alur authority aplikasi:

```text
UI -> authenticated API -> guarded RPC/RLS -> tenant-scoped table/audit
```

UUID, tenant identity, actor, role, version, account function, dan system key
divalidasi server-side. UI menampilkan nama bisnis; identifier teknis tidak
menjadi informasi utama pengguna.

Finance memakai UUID sebagai identity backend, tetapi nomor yang dibaca user
berformat `JUR/JRB/PST/EXC/REC/YYYY/MM/######`. Buku Besar bersifat
account-centric dan Journal Entries document-centric. Rollout perubahan ini
ada di
[`docs/runbooks/G6_PHASE7B_FINANCE_HUMAN_IDS_LEDGER_EXPORT.md`](docs/runbooks/G6_PHASE7B_FINANCE_HUMAN_IDS_LEDGER_EXPORT.md).

## Menjalankan Lokal

Prasyarat:

- Node.js yang kompatibel dengan dependency repository;
- project Supabase dan migration chain sesuai
  [`supabase/MIGRATION_MANIFEST.md`](supabase/MIGRATION_MANIFEST.md);
- environment variable lokal. Jangan commit secret.

Backoffice:

```powershell
cd backoffice
npm.cmd install
npm.cmd run dev
```

Pemeriksaan Backoffice:

```powershell
npm.cmd run lint
npm.cmd run build
```

PWA:

```powershell
cd pwa
npm.cmd install
npm.cmd run dev
```

Pemeriksaan PWA:

```powershell
npm.cmd run lint
npm.cmd run build
```

Environment minimum memakai nilai lokal berikut tanpa menuliskan nilainya ke
README atau log:

```text
NEXT_PUBLIC_SUPABASE_URL
NEXT_PUBLIC_SUPABASE_ANON_KEY atau NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
SUPABASE_SERVICE_ROLE_KEY  # server-only; tidak boleh masuk client
```

PWA memakai nama environment yang terdapat pada `pwa/.env.example`:

```text
VITE_SUPABASE_URL
VITE_SUPABASE_ANON_KEY
```

Pada development monorepo, placeholder PWA otomatis fallback hanya ke
`NEXT_PUBLIC_SUPABASE_URL` dan public publishable key dari
`backoffice/.env.local`. Deployment PWA tetap wajib mengisi variable `VITE_*`;
service-role key tidak pernah diteruskan ke bundle browser.

Cashier biasa dibuat dari `Kontak > User & Akses` dan wajib dipasangkan ke
Toko. Super Admin serta Company Owner/Admin mewarisi aksi Cashier sesuai
kontrak. Store Manager dapat memakai POS hanya pada Toko assignment aktifnya.
Seluruh operator tetap harus memilih Terminal aktif dan Gudang sale-source.
Jika access token browser sudah ditolak Supabase sebagai `INVALID_SESSION`,
Backoffice membersihkan sesi lokal dan kembali ke layar login; restart server
tidak lagi membiarkan aplikasi terkunci pada token kedaluwarsa.

## Database dan Rollout

- Migration production dijalankan manual melalui runbook; agent tidak boleh
  menerapkannya diam-diam.
- Dataset UAT Finance yang mengikuti guarded Product → Opening Stock →
  controlled posting queue → Journal serta Stock Adjustment → Pending Analysis
  tersedia di
  [`docs/runbooks/G6_PHASE7B_FINANCE_UAT_DATASET.md`](docs/runbooks/G6_PHASE7B_FINANCE_UAT_DATASET.md).
  Operation ini membuat histori permanen dan hanya untuk database test/pilot.
- Jangan mengedit migration yang sudah applied. Gunakan forward migration.
- Urutan wajib: preflight -> migration -> postflight -> behavioral test ->
  application smoke.
- Diagnostic preflight harus `SELECT-only`.
- Behavioral fixture wajib dibungkus transaction dan `ROLLBACK`.
- Finance worker, checkout resolver, stock posting, atau module deferred tidak
  boleh diaktifkan hanya karena master/schema sudah tersedia.

Router rollout berada di [`docs/README.md`](docs/README.md). Migration canonical
dan checksum berada di
[`supabase/MIGRATION_MANIFEST.md`](supabase/MIGRATION_MANIFEST.md).

## Invariant Utama

- Semua data operasional tenant-scoped berdasarkan Company aktif.
- Browser tidak menulis langsung ledger, stock movement, atau master sensitif.
- Stock disimpan pada base UOM dan tidak boleh negatif.
- Harga, discount, tax, payment total, UOM conversion, stock, dan journal final
  dihitung ulang server-side.
- Mutation penting atomic, versioned, auditable, dan idempotent sesuai source.
- Dokumen posted tidak dihapus; koreksi menggunakan reversal/return/adjustment.
- Journal production harus balanced dan tidak boleh memakai nomor COA
  hard-coded.
- Secret/service-role hanya server-side.

Requirement lengkap:
[`docs/POS_V1_MVP_REQUIREMENT_INDEX.md`](docs/POS_V1_MVP_REQUIREMENT_INDEX.md).

## Dokumentasi Pengembangan

- Entry point dokumen: [`docs/README.md`](docs/README.md)
- Gate implementasi: [`docs/POS_V1_IMPLEMENTATION_GATES.md`](docs/POS_V1_IMPLEMENTATION_GATES.md)
- Handoff aktif: [`docs/ACTIVE_DEVELOPMENT_HANDOFF.md`](docs/ACTIVE_DEVELOPMENT_HANDOFF.md)
- Playbook agent: [`docs/AI_AGENT_CONTINUATION_PLAYBOOK.md`](docs/AI_AGENT_CONTINUATION_PLAYBOOK.md)
- Requirement index: [`docs/POS_V1_MVP_REQUIREMENT_INDEX.md`](docs/POS_V1_MVP_REQUIREMENT_INDEX.md)
- Finance master API/UI rollout: [`docs/runbooks/G2_PHASE17_FINANCE_MASTER_API_UI_ROLLOUT.md`](docs/runbooks/G2_PHASE17_FINANCE_MASTER_API_UI_ROLLOUT.md)
- Panduan Kategori Transaksi: [`docs/FINANCE_TRANSACTION_CATEGORY_USER_GUIDE.md`](docs/FINANCE_TRANSACTION_CATEGORY_USER_GUIDE.md)
- Required-category rollout: [`docs/runbooks/G2_PHASE18_REQUIRED_TRANSACTION_CATEGORIES_ROLLOUT.md`](docs/runbooks/G2_PHASE18_REQUIRED_TRANSACTION_CATEGORIES_ROLLOUT.md)
- Guarded COA/fallback rollout: [`docs/runbooks/G2_PHASE20_GUARDED_COA_FALLBACK_ROLLOUT.md`](docs/runbooks/G2_PHASE20_GUARDED_COA_FALLBACK_ROLLOUT.md)
- Tax master preflight: [`docs/runbooks/G2_PHASE21_TAX_MASTER_PREFLIGHT.md`](docs/runbooks/G2_PHASE21_TAX_MASTER_PREFLIGHT.md)
- Tax master foundation rollout: [`docs/runbooks/G2_PHASE22_TAX_MASTER_FOUNDATION_ROLLOUT.md`](docs/runbooks/G2_PHASE22_TAX_MASTER_FOUNDATION_ROLLOUT.md)
- Tax master API/UI rollout: [`docs/runbooks/G2_PHASE23_TAX_MASTER_API_UI_ROLLOUT.md`](docs/runbooks/G2_PHASE23_TAX_MASTER_API_UI_ROLLOUT.md)
- Module Settings rollout: [`docs/runbooks/G2_PHASE24_MODULE_SETTINGS_API_UI_ROLLOUT.md`](docs/runbooks/G2_PHASE24_MODULE_SETTINGS_API_UI_ROLLOUT.md)
- App Launcher/shell smoke: [`docs/runbooks/G2_PHASE25_ROLE_AWARE_APP_LAUNCHER_SHELL.md`](docs/runbooks/G2_PHASE25_ROLE_AWARE_APP_LAUNCHER_SHELL.md)
- Tax assignment preflight: [`docs/runbooks/G2_PHASE26_TAX_ASSIGNMENT_PREFLIGHT.md`](docs/runbooks/G2_PHASE26_TAX_ASSIGNMENT_PREFLIGHT.md)
- Guarded Tax assignment rollout: [`docs/runbooks/G2_PHASE26_GUARDED_TAX_ASSIGNMENT_ROLLOUT.md`](docs/runbooks/G2_PHASE26_GUARDED_TAX_ASSIGNMENT_ROLLOUT.md)
- Tax assignment API/UI smoke: [`docs/runbooks/G2_PHASE27_TAX_ASSIGNMENT_API_UI_ROLLOUT.md`](docs/runbooks/G2_PHASE27_TAX_ASSIGNMENT_API_UI_ROLLOUT.md)
- Tax resolver/snapshot preflight: [`docs/runbooks/G2_PHASE28_TAX_RESOLVER_SNAPSHOT_PREFLIGHT.md`](docs/runbooks/G2_PHASE28_TAX_RESOLVER_SNAPSHOT_PREFLIGHT.md)
- Tax resolver/calculator rollout: [`docs/runbooks/G2_PHASE28_TAX_RESOLVER_CALCULATOR_ROLLOUT.md`](docs/runbooks/G2_PHASE28_TAX_RESOLVER_CALCULATOR_ROLLOUT.md)
- Master Import/Export preflight: [`docs/runbooks/G2_PHASE29_IMPORT_FRAMEWORK_PREFLIGHT.md`](docs/runbooks/G2_PHASE29_IMPORT_FRAMEWORK_PREFLIGHT.md)
- Master Import staging rollout: [`docs/runbooks/G2_PHASE30_MASTER_IMPORT_STAGING_FOUNDATION_ROLLOUT.md`](docs/runbooks/G2_PHASE30_MASTER_IMPORT_STAGING_FOUNDATION_ROLLOUT.md)
- Master Import identity validator rollout: [`docs/runbooks/G2_PHASE31_MASTER_IMPORT_IDENTITY_VALIDATOR_ROLLOUT.md`](docs/runbooks/G2_PHASE31_MASTER_IMPORT_IDENTITY_VALIDATOR_ROLLOUT.md)
- Master Import business validator rollout: [`docs/runbooks/G2_PHASE32_MASTER_IMPORT_BUSINESS_VALIDATOR_ROLLOUT.md`](docs/runbooks/G2_PHASE32_MASTER_IMPORT_BUSINESS_VALIDATOR_ROLLOUT.md)
- Master Import partial commit rollout: [`docs/runbooks/G2_PHASE33_MASTER_IMPORT_PARTIAL_COMMIT_ROLLOUT.md`](docs/runbooks/G2_PHASE33_MASTER_IMPORT_PARTIAL_COMMIT_ROLLOUT.md)
- Master Import API/UI rollout: [`docs/runbooks/G2_PHASE34_MASTER_IMPORT_API_UI_ROLLOUT.md`](docs/runbooks/G2_PHASE34_MASTER_IMPORT_API_UI_ROLLOUT.md)
- Full Master Import preflight: [`docs/runbooks/G2_PHASE35_FULL_MASTER_IMPORT_PREFLIGHT.md`](docs/runbooks/G2_PHASE35_FULL_MASTER_IMPORT_PREFLIGHT.md)
- Automatic hidden master code preflight: [`docs/runbooks/G2_PHASE36_AUTOMATIC_MASTER_CODE_PREFLIGHT.md`](docs/runbooks/G2_PHASE36_AUTOMATIC_MASTER_CODE_PREFLIGHT.md)
- Automatic hidden master code rollout: [`docs/runbooks/G2_PHASE36_AUTOMATIC_MASTER_CODES_ROLLOUT.md`](docs/runbooks/G2_PHASE36_AUTOMATIC_MASTER_CODES_ROLLOUT.md)
- Automatic master code UI cutover: [`docs/runbooks/G2_PHASE37_AUTOMATIC_MASTER_CODE_UI_CUTOVER.md`](docs/runbooks/G2_PHASE37_AUTOMATIC_MASTER_CODE_UI_CUTOVER.md)
- Code-less simple master import rollout: [`docs/runbooks/G2_PHASE38_CODELESS_MASTER_IMPORT_ROLLOUT.md`](docs/runbooks/G2_PHASE38_CODELESS_MASTER_IMPORT_ROLLOUT.md)
- Code-less Import UI cutover: [`docs/runbooks/G2_PHASE39_CODELESS_MASTER_IMPORT_UI_CUTOVER.md`](docs/runbooks/G2_PHASE39_CODELESS_MASTER_IMPORT_UI_CUTOVER.md)
- Fixed CSV contracts: [`docs/MASTER_IMPORT_FIXED_CSV_CONTRACTS.md`](docs/MASTER_IMPORT_FIXED_CSV_CONTRACTS.md)
- Kartu Stok API/UI smoke: [`docs/runbooks/G3_PHASE5_STOCK_MOVEMENT_API_UI.md`](docs/runbooks/G3_PHASE5_STOCK_MOVEMENT_API_UI.md)
- Stock Transfer preflight: [`docs/runbooks/G3_PHASE6_STOCK_TRANSFER_PREFLIGHT.md`](docs/runbooks/G3_PHASE6_STOCK_TRANSFER_PREFLIGHT.md)
- Stock Transfer database rollout: [`docs/runbooks/G3_PHASE6_STOCK_TRANSFER_FOUNDATION_ROLLOUT.md`](docs/runbooks/G3_PHASE6_STOCK_TRANSFER_FOUNDATION_ROLLOUT.md)
- Stock Transfer API/UI smoke: [`docs/runbooks/G3_PHASE7_STOCK_TRANSFER_API_UI.md`](docs/runbooks/G3_PHASE7_STOCK_TRANSFER_API_UI.md)
- Stock Adjustment preflight: [`docs/runbooks/G3_PHASE8_STOCK_ADJUSTMENT_PREFLIGHT.md`](docs/runbooks/G3_PHASE8_STOCK_ADJUSTMENT_PREFLIGHT.md)
- Stock Adjustment database rollout: [`docs/runbooks/G3_PHASE8_STOCK_ADJUSTMENT_FOUNDATION_ROLLOUT.md`](docs/runbooks/G3_PHASE8_STOCK_ADJUSTMENT_FOUNDATION_ROLLOUT.md)
- Stock Adjustment API/UI smoke: [`docs/runbooks/G3_PHASE9_STOCK_ADJUSTMENT_API_UI.md`](docs/runbooks/G3_PHASE9_STOCK_ADJUSTMENT_API_UI.md)
- Stock Opname preflight: [`docs/runbooks/G3_PHASE10_STOCK_OPNAME_PREFLIGHT.md`](docs/runbooks/G3_PHASE10_STOCK_OPNAME_PREFLIGHT.md)
- Stock Opname database rollout: [`docs/runbooks/G3_PHASE10_STOCK_OPNAME_FOUNDATION_ROLLOUT.md`](docs/runbooks/G3_PHASE10_STOCK_OPNAME_FOUNDATION_ROLLOUT.md)
- Stock Opname Backoffice review/report smoke: [`docs/runbooks/G3_PHASE11_STOCK_OPNAME_BACKOFFICE_API_UI.md`](docs/runbooks/G3_PHASE11_STOCK_OPNAME_BACKOFFICE_API_UI.md)
- Bundle foundation preflight: [`docs/runbooks/G3_PHASE12_BUNDLE_FOUNDATION_PREFLIGHT.md`](docs/runbooks/G3_PHASE12_BUNDLE_FOUNDATION_PREFLIGHT.md)
- Bundle foundation database rollout: [`docs/runbooks/G3_PHASE12_BUNDLE_FOUNDATION_ROLLOUT.md`](docs/runbooks/G3_PHASE12_BUNDLE_FOUNDATION_ROLLOUT.md)
- Offline Stock Allowance rollout: [`docs/runbooks/G4_PHASE11_OFFLINE_STOCK_ALLOWANCE_FOUNDATION_ROLLOUT.md`](docs/runbooks/G4_PHASE11_OFFLINE_STOCK_ALLOWANCE_FOUNDATION_ROLLOUT.md)
- Offline Sale Sync rollout: [`docs/runbooks/G4_PHASE12_OFFLINE_SYNC_ROLLOUT.md`](docs/runbooks/G4_PHASE12_OFFLINE_SYNC_ROLLOUT.md)
- Offline PWA queue foundation: [`docs/runbooks/G4_PHASE13_OFFLINE_PWA_QUEUE_FOUNDATION.md`](docs/runbooks/G4_PHASE13_OFFLINE_PWA_QUEUE_FOUNDATION.md)
- Offline catalog cache preflight: [`docs/runbooks/G4_PHASE14_OFFLINE_CATALOG_CACHE_PREFLIGHT.md`](docs/runbooks/G4_PHASE14_OFFLINE_CATALOG_CACHE_PREFLIGHT.md)
- POS Customer quick-create: [`docs/runbooks/G4_PHASE18_POS_CUSTOMER_QUICK_CREATE_ROLLOUT.md`](docs/runbooks/G4_PHASE18_POS_CUSTOMER_QUICK_CREATE_ROLLOUT.md)
- Offline Allowance operations UI: [`docs/runbooks/G4_PHASE19_OFFLINE_ALLOWANCE_OPERATIONS_UI.md`](docs/runbooks/G4_PHASE19_OFFLINE_ALLOWANCE_OPERATIONS_UI.md)
- Cashier Offline Allowance PWA UI: [`docs/runbooks/G4_PHASE20_CASHIER_OFFLINE_ALLOWANCE_PWA_UI.md`](docs/runbooks/G4_PHASE20_CASHIER_OFFLINE_ALLOWANCE_PWA_UI.md)
- Offline checkout queue preflight: [`docs/runbooks/G4_PHASE21_OFFLINE_CHECKOUT_QUEUE_PREFLIGHT.md`](docs/runbooks/G4_PHASE21_OFFLINE_CHECKOUT_QUEUE_PREFLIGHT.md)
- Offline checkout queue PWA UI: [`docs/runbooks/G4_PHASE22_OFFLINE_CHECKOUT_QUEUE_PWA_UI.md`](docs/runbooks/G4_PHASE22_OFFLINE_CHECKOUT_QUEUE_PWA_UI.md)
- POS end-to-end UAT sampai Phase 22: [`docs/runbooks/G4_PHASE22_POS_END_TO_END_UAT.md`](docs/runbooks/G4_PHASE22_POS_END_TO_END_UAT.md)
- Offline cold-start/conflict preflight: [`docs/runbooks/G4_PHASE23_OFFLINE_COLD_START_CONFLICT_PREFLIGHT.md`](docs/runbooks/G4_PHASE23_OFFLINE_COLD_START_CONFLICT_PREFLIGHT.md)
- Offline cold-start/recovery PWA: [`docs/runbooks/G4_PHASE23_OFFLINE_COLD_START_RECOVERY_PWA.md`](docs/runbooks/G4_PHASE23_OFFLINE_COLD_START_RECOVERY_PWA.md)
- Offline disconnect/reconnect stress: [`docs/runbooks/G4_PHASE24_OFFLINE_DISCONNECT_RECONNECT_STRESS.md`](docs/runbooks/G4_PHASE24_OFFLINE_DISCONNECT_RECONNECT_STRESS.md)
- Sales Return readiness preflight: [`docs/runbooks/G4_PHASE25_SALES_RETURN_READINESS_PREFLIGHT.md`](docs/runbooks/G4_PHASE25_SALES_RETURN_READINESS_PREFLIGHT.md)
- Sales Return foundation rollout: [`docs/runbooks/G4_PHASE26_SALES_RETURN_FOUNDATION_ROLLOUT.md`](docs/runbooks/G4_PHASE26_SALES_RETURN_FOUNDATION_ROLLOUT.md)
- Sales Return PWA Draft UI: [`docs/runbooks/G4_PHASE27_SALES_RETURN_PWA_DRAFT_UI.md`](docs/runbooks/G4_PHASE27_SALES_RETURN_PWA_DRAFT_UI.md)
- Sales Return Backoffice approval UI: [`docs/runbooks/G4_PHASE28_SALES_RETURN_BACKOFFICE_APPROVAL_UI.md`](docs/runbooks/G4_PHASE28_SALES_RETURN_BACKOFFICE_APPROVAL_UI.md)
- Expense dan arus kas preflight: [`docs/runbooks/G4_PHASE29_EXPENSE_CASH_FLOW_PREFLIGHT.md`](docs/runbooks/G4_PHASE29_EXPENSE_CASH_FLOW_PREFLIGHT.md)
- Expense request/approval foundation: [`docs/runbooks/G4_PHASE30_EXPENSE_REQUEST_APPROVAL_FOUNDATION_ROLLOUT.md`](docs/runbooks/G4_PHASE30_EXPENSE_REQUEST_APPROVAL_FOUNDATION_ROLLOUT.md)
- Expense request PWA UI: [`docs/runbooks/G4_PHASE31_EXPENSE_REQUEST_PWA_UI.md`](docs/runbooks/G4_PHASE31_EXPENSE_REQUEST_PWA_UI.md)
- Expense approval Backoffice UI: [`docs/runbooks/G4_PHASE32_EXPENSE_APPROVAL_BACKOFFICE_UI.md`](docs/runbooks/G4_PHASE32_EXPENSE_APPROVAL_BACKOFFICE_UI.md)
- Expense disbursement preflight: [`docs/runbooks/G4_PHASE33_EXPENSE_DISBURSEMENT_PREFLIGHT.md`](docs/runbooks/G4_PHASE33_EXPENSE_DISBURSEMENT_PREFLIGHT.md)
- Expense disbursement foundation: [`docs/runbooks/G4_PHASE34_EXPENSE_DISBURSEMENT_FOUNDATION_ROLLOUT.md`](docs/runbooks/G4_PHASE34_EXPENSE_DISBURSEMENT_FOUNDATION_ROLLOUT.md)
- Expense disbursement operational UI: [`docs/runbooks/G4_PHASE35_EXPENSE_DISBURSEMENT_UI.md`](docs/runbooks/G4_PHASE35_EXPENSE_DISBURSEMENT_UI.md)
- Expense settlement preflight: [`docs/runbooks/G4_PHASE36_EXPENSE_SETTLEMENT_PREFLIGHT.md`](docs/runbooks/G4_PHASE36_EXPENSE_SETTLEMENT_PREFLIGHT.md)
- Expense settlement foundation: [`docs/runbooks/G4_PHASE37_EXPENSE_SETTLEMENT_FOUNDATION_ROLLOUT.md`](docs/runbooks/G4_PHASE37_EXPENSE_SETTLEMENT_FOUNDATION_ROLLOUT.md)
- Expense settlement operational UI: [`docs/runbooks/G4_PHASE38_EXPENSE_SETTLEMENT_OPERATIONAL_UI.md`](docs/runbooks/G4_PHASE38_EXPENSE_SETTLEMENT_OPERATIONAL_UI.md)
- Additional Expense disbursement preflight: [`docs/runbooks/G4_PHASE39_ADDITIONAL_EXPENSE_DISBURSEMENT_PREFLIGHT.md`](docs/runbooks/G4_PHASE39_ADDITIONAL_EXPENSE_DISBURSEMENT_PREFLIGHT.md)
- Additional Expense disbursement foundation: [`docs/runbooks/G4_PHASE40_ADDITIONAL_EXPENSE_DISBURSEMENT_ROLLOUT.md`](docs/runbooks/G4_PHASE40_ADDITIONAL_EXPENSE_DISBURSEMENT_ROLLOUT.md)
- Additional Expense operational UI: [`docs/runbooks/G4_PHASE41_ADDITIONAL_EXPENSE_OPERATIONAL_UI.md`](docs/runbooks/G4_PHASE41_ADDITIONAL_EXPENSE_OPERATIONAL_UI.md)
- Cash Deposit multi-Session preflight: [`docs/runbooks/G4_PHASE42_CASH_DEPOSIT_PREFLIGHT.md`](docs/runbooks/G4_PHASE42_CASH_DEPOSIT_PREFLIGHT.md)
- Cash Deposit multi-Session foundation: [`docs/runbooks/G4_PHASE43_CASH_DEPOSIT_FOUNDATION_ROLLOUT.md`](docs/runbooks/G4_PHASE43_CASH_DEPOSIT_FOUNDATION_ROLLOUT.md)
- Cash Deposit operational UI: [`docs/runbooks/G4_PHASE44_CASH_DEPOSIT_OPERATIONAL_UI.md`](docs/runbooks/G4_PHASE44_CASH_DEPOSIT_OPERATIONAL_UI.md)
- Deposit variance resolution preflight: [`docs/runbooks/G4_PHASE45_DEPOSIT_VARIANCE_RESOLUTION_PREFLIGHT.md`](docs/runbooks/G4_PHASE45_DEPOSIT_VARIANCE_RESOLUTION_PREFLIGHT.md)
- Deposit variance resolution rollout: [`docs/runbooks/G4_PHASE46_DEPOSIT_VARIANCE_RESOLUTION_ROLLOUT.md`](docs/runbooks/G4_PHASE46_DEPOSIT_VARIANCE_RESOLUTION_ROLLOUT.md)

## Aturan Pembaruan README

Setiap perubahan material wajib memperbarui bagian yang relevan di file ini:

1. status modul dan gate aktif;
2. behavior yang benar-benar sudah aktif, bukan baru direncanakan;
3. migration/runbook dan langkah menjalankan bila berubah;
4. compatibility serta module yang tetap deferred;
5. link dokumentasi baru;
6. evidence lint/build/database/smoke pada handoff.

README menjelaskan keadaan aplikasi untuk manusia. Detail operasional antar-agent
tetap ditulis di `docs/ACTIVE_DEVELOPMENT_HANDOFF.md`, sedangkan keputusan bisnis
tetap berada pada spesifikasi modul masing-masing.
