# KGS POS

KGS POS adalah aplikasi Point of Sale dan mini ERP multi-Company yang sedang
dibangun bertahap dengan Supabase sebagai backend, Next.js untuk Backoffice,
serta React/Vite PWA untuk kasir.

> Dokumen ini adalah README aplikasi yang hidup. Setiap build yang mengubah
> status modul, cara menjalankan aplikasi, migration chain, compatibility, atau
> roadmap wajib memperbarui file ini bersama kode dan handoff.

**Status terakhir:** 29 Juli 2026
**Gate aktif:** G4 Phase 10 — true-concurrent Post stress staging
**Runtime:** lokal; Supabase aktif; Vercel Preview belum dibuka

## Kondisi Aplikasi Saat Ini

| Area | Status | Catatan |
|---|---|---|
| Tenant, role, RLS, active Company | Complete | Boundary lintas-Company dan browser mutation sudah diuji |
| Product Category, UOM, Warehouse | Complete | Canonical master, guarded API/UI, versioning |
| Product + multi-UOM | Complete | Atomic Product/Product-UOM, base UOM, harga per UOM |
| Supplier + Product-Supplier | Complete | Preferred Supplier, purchase UOM, audit |
| Customer + Customer Category | Complete | Walk-In system, credit boundary, grouping induk/cabang |
| Pricelist | Complete pada online core | Global/Customer reusable; resolver aktif pada canonical Draft/Post |
| Payment Method | Online split-payment ready for smoke | Store scope, fee/proof snapshot, stable payment-leg identity, dan tablet multi-metode UI aktif |
| Transaction Category + minimum COA | Complete pada master | 26 kategori, guarded COA, dan explicit fallback PASS; posting tetap nonaktif |
| Tax Sales/Purchase | Sales resolver aktif pada online core | Guarded master/version/assignment; Purchase/jurnal tetap belum dibuka |
| Pengaturan Modul | API/UI local ready; Super Admin smoke menunggu | Entitlement per Company melalui guarded RPC dan audit; detail konfigurasi tetap di menu modul |
| App Launcher & shell | Complete pada role boundary saat ini | Inventory, Kontak, Sales, Finance, Platform; brand KGS POS kembali ke Home; granular permission tetap deferred |
| Tax assignment Product/Category | Complete pada Sales online boundary | Category default dan Product inheritance/override memakai nama Tax Rule; resolver aktif saat Draft/Post |
| Tax resolver/calculator | Complete pada Sales online boundary | Effective-dated resolver + deterministic calculation dipakai Draft/Post; Purchase/jurnal belum dicutover |
| Master Import/Export | Complete untuk 7 simple master | Phase 40 DB dan Phase 41 authenticated UI smoke PASS |
| Generic import framework | Phase 47 UI local-ready | Grouped Product, Product-Supplier, dan Minimum Stock Produk–Gudang database PASS; Minimum Stock guarded API/UI serta fixed import-export lint/build PASS dan menunggu authenticated smoke; Opening Stock, transaksi, Company, dan Staff/password tetap workflow khusus |
| Stock ledger/FIFO production | Complete pada G3 core boundary | Integrated stress/regression diteruskan tanpa error dan Phase-14 rerun seluruh invariant PASS; Sale/Return/Receipt coverage pindah ke gate transaksi |
| POS checkout/offline production | Online single-payment + Draft UI local-ready | Session, real catalog, server Draft/Post, FIFO/Bundle, payment/tax snapshot, Pricelist override, receipt print-tab, shortage, same-Store Draft list, edit-lock/heartbeat/takeover/cancel aktif; authenticated Draft UI smoke menunggu; offline diblokir |
| Purchasing end-to-end | Belum dibuka | Gate G5 |
| Finance posting/reconciliation | Belum dibuka | Gate G6 |

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
