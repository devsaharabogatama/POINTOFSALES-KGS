# Pre-Deploy Modular Home, Company Branding, dan Sales Document Plan

> **Revision gate 2026-08-12:** final-checkout/delivery-fee revision SLD-R1—R4
> sudah user-verified. PRD-1 pre-deploy closing sekarang dibuka.

**Status:** IMPLEMENTED THROUGH SLD-R4; G6 PHASE 8 CLOSED; PRD-1 PREVIEW UAT
**Disetujui:** 2026-08-11  
**Progress:** UXD-1/2 implemented; BRD-1 database PASS; BRD-2 implemented; SLD-R1—R4 user-verified; ACP-6G database PASS; ACP-7 fixture/browser matrix pending; PRD-1 consolidated preflight updated  
**Posisi roadmap:** setelah DEX-4, sebelum full pre-deploy E2E/Vercel Preview

**Current update 2026-08-14:** ACP-7 database chain PASS; G6 Phase 8H
`HOLD=0` dan seluruh reconciliation PASS. Remaining gate adalah authenticated
role/two-Company matrix dan Vercel Preview smoke.

## 1. Outcome yang Disetujui

1. Home Backoffice tidak lagi menampilkan hero `Halo, User`, ringkasan stock,
   atau block dekoratif yang memakan ruang. Home hanya berisi aplikasi/modul
   yang dapat diakses user pada Company aktif.
2. Klik modul tidak langsung membuka submodul pertama. User masuk ke landing
   modul yang berisi card submodul, dengan pola visual bersih seperti app
   launcher dan icon yang sesuai domain.
3. Company Owner/Admin dapat mengunggah logo opsional. Logo dipakai oleh
   template dokumen Company, dengan fallback tanpa logo.
4. POS mempunyai pilihan pemenuhan `Ambil langsung` atau `Perlu dikirim`.
   Sale yang perlu dikirim menghasilkan Surat Jalan tenant-scoped.
5. Penjualan POSTED mempunyai template Sales Invoice formal yang dapat dibuka
   dan dicetak. Ini berbeda dari Supplier Invoice pembelian dan berbeda dari
   integrasi e-Faktur pemerintah.

## 2. Baseline Repository Saat Ini

- Home sudah mempunyai `appModules`, tetapi masih menampilkan hero sapaan,
  summary Produk/Stock/Nilai Persediaan, dan klik modul membuka submodul
  pertama.
- Visibility navigation masih dibentuk dari effective Company role di client;
  API/RLS tetap menjadi authority mutation/read. Belum ada landing page modul.
- `companies` belum mempunyai logo/branding profile atau upload runtime.
- Kebijakan file v1 masih external-link only. Instruksi user 2026-08-11 membuka
  exception sempit untuk **Company logo**, bukan untuk bukti transaksi.
- Sale POSTED sudah mempunyai `invoice_no` dan immutable `receipt_snapshot`;
  PWA dapat membuka struk. Belum ada halaman/template Sales Invoice formal.
- Supplier Invoice sudah ada untuk Purchase/Finance dan tidak boleh dicampur
  dengan Sales Invoice.
- Belum ada canonical Sales Delivery/Surat Jalan. `supplier_delivery_no` yang
  ada hanya referensi surat jalan Supplier pada Goods Receipt.

## 3. Batas Scope

### In scope

- two-level launcher: Home modul -> landing submodul -> halaman kerja;
- module/submodule visibility mengikuti effective Company, role, entitlement,
  dan scope operasional yang sudah tersedia;
- upload/replace/remove logo Company dengan audit dan fallback;
- branding snapshot untuk dokumen baru;
- Sales Invoice printable dari Sale POSTED;
- delivery intent di POS dan Surat Jalan minimal;
- history/list/reprint dari Backoffice;
- responsive tablet/desktop, keyboard/Escape, dan print layout.

### Out of scope

- redesign seluruh halaman kerja;
- custom theme/color/font per Company;
- upload bukti transaksi internal;
- e-Faktur/pajak pemerintah;
- route optimization, kurir, ongkir marketplace, fleet, GPS, proof of delivery,
  atau Logistics advanced;
- mengubah stock deduction dari Sale menjadi deduction saat pengiriman;
- membuat Finance event/jurnal baru hanya karena dokumen dicetak;
- membuat Sales Invoice baru yang menggandakan nilai Sale/AR/Tax existing.

## 4. Invariant Wajib

1. Hiding card bukan authorization; API/RPC/RLS tetap menolak akses langsung.
2. Module landing tidak boleh menampilkan submodul yang tidak tersedia untuk
   effective role/Company/entitlement/scope user.
3. Logo harus tenant-scoped; Company A tidak dapat membaca path pengelolaan,
   mengganti, atau menghapus logo Company B.
4. Binary tidak disimpan sebagai base64/blob PostgreSQL dan tidak disimpan pada
   filesystem Vercel.
5. Sales Invoice dan Surat Jalan menyimpan document snapshot. Perubahan nama,
   alamat, logo, Customer, Product, UOM, harga, atau pajak sesudah penerbitan
   tidak boleh menulis ulang histori dokumen.
6. Surat Jalan adalah efek dokumen/logistik dari Sale POSTED dan tidak membuat
   Stock Movement/FIFO/Financial Event kedua.
7. Sale retry hanya boleh menghasilkan satu Invoice dan maksimal satu Surat
   Jalan aktif untuk identity/idempotency yang sama.
8. Sale `Ambil langsung` tidak membuat Surat Jalan.
9. Sale `Perlu dikirim` wajib mempunyai recipient dan alamat snapshot; Customer
   Walk-In hanya boleh dipakai bila data penerima diisi eksplisit.
10. Koreksi Sale POSTED tetap melalui Return/reversal source flow. Reprint
    bukan mutation transaksi.

## 5. Rencana Delivery per Phase

### Phase UXD-1 — Navigation authority dan launcher audit

**Status 2026-08-11:** COMPLETE. Evidence dan contract UXD-2 berada di
`audits/UXD1_NAVIGATION_AUTHORITY_AND_REPOSITORY_HYGIENE_AUDIT_2026-08-11.md`.
Audit menemukan client-owned navigation registry, entitlement blind spot, dan
duplikasi ownership Faktur/Pembayaran Supplier. Seluruh Route Handler aktif
tetap memiliki auth/context atau retirement guard. Tidak ada runtime/schema
yang diubah pada fase audit.

- petakan `navigation`, `appModules`, role constants, Company context,
  entitlement, Store/Warehouse scope, dan seluruh route/submodule aktif;
- buat matrix expected module/submodule per role;
- tentukan server-readable navigation catalog tanpa membuat permission baru
  yang tidak disetujui;
- diagnostic/read-only evidence untuk route yang UI-nya tersembunyi tetapi API
  masih wajib aman.

**Exit:** tidak ada orphan submodule, duplikasi module ownership, atau route
yang mengandalkan hiding UI sebagai security.

### Phase UXD-2 — Clean two-level Odoo-like launcher

**Status 2026-08-11:** LOCAL READY; authenticated role/Company smoke pending.
Implementasi dan manual gate berada di
`runbooks/UXD2_TWO_LEVEL_LAUNCHER_ROLLOUT.md`. Belum ada schema/data migration.

- hapus hero `Halo, User`, block summary, dan statistik dari Home;
- Home hanya menampilkan card modul authorized;
- klik modul membuka landing berisi card submodul authorized, bukan submodul
  pertama;
- icon submodul disesuaikan dengan domain;
- pertahankan tombol Home, Back, breadcrumb, fast-link sidebar, dan Company
  switcher;
- deep navigation dan refresh tidak membuat user jatuh ke halaman tanpa akses.

**Exit:** role matrix, tablet/desktop layout, Home -> Module -> Submodule,
Back/Home, Company switch, dan direct-route denial smoke PASS.

### Phase BRD-1 — Company branding/logo foundation

**Status 2026-08-11:** preflight, migration, postflight, dan rollback-safe
two-Company isolation behavior user-reported ALL PASS. BRD-2 server-only upload
dan setting UI sekarang LOCAL READY melalui
`runbooks/BRD2_COMPANY_BRANDING_UPLOAD_UI.md`: magic-byte/MIME/extension/size/
SHA-256 validation, generated Company path, optimistic version, cleanup, modal
remove, serta remount saat Company switch. Authenticated multi-Company smoke
masih manual; document snapshot tetap milik SLD.

Shell integration juga LOCAL READY: resolved logo Company tampil di samping
nama/selector Company dan menjadi tombol kembali ke Home. Fast Link memiliki
search label menu/nama modul, tetapi hanya menyaring item hasil navigation
catalog server untuk role, entitlement, dan active Company; search tidak
memiliki registry/fallback yang dapat memunculkan menu terlarang.

- preflight schema Company, role, audit, dan Storage policy;
- storage object khusus branding Company; public-read hanya karena logo memang
  ditujukan untuk dokumen eksternal, write/delete tetap guarded;
- PNG/JPEG/WebP saja, ukuran maksimal direncanakan 2 MB, tanpa SVG aktif;
- metadata minimum: object path, public URL/version, MIME, size, checksum,
  uploaded/updated actor dan timestamp, `master_version`;
- guarded upload/replace/remove serta cross-Company negative test;
- Backoffice setting hanya Owner/Admin/Super Admin; role lain read-only melalui
  resolved branding view;
- fallback template tetap rapi bila logo tidak diunggah.

**Exit:** upload, replace, remove, cache-busting, wrong MIME/oversize,
cross-tenant, audit, dan fallback PASS. Bukti transaksi tetap external-link.

Behavioral database pada foundation wajib memakai dua Company. Closing PRD-1
memperluas matrix isolasi ke module launcher, list/detail, export/import,
Finance, Stock, Sale, dan document: switch Company harus menghapus state/cache
lama dan direct route/RPC lintas Company wajib gagal.

### Phase SLD-1 — Sales document preflight dan contract

- audit `sales_headers`, `sales_details`, Customer address, Store, Warehouse,
  `invoice_no`, receipt snapshot, Return, Offline Sale, dan print path;
- tetapkan snapshot Company/Store/Customer/Product/UOM/Tax/Payment;
- tetapkan human number Surat Jalan, lifecycle minimal, uniqueness,
  idempotency, reprint, Return reference, dan retention;
- pastikan online/offline Sale serta Bundle mempunyai line snapshot cukup;
- jangan membuat schema sebelum seluruh blocker preflight nol.

**Exit:** contract printable tidak menggandakan Stock/Finance dan mendukung
Sale existing secara backward-compatible.

**Status 2026-08-11:** contract canonical dikunci pada
`SALES_INVOICE_DELIVERY_DOCUMENT_SPEC.md`. Preflight SELECT-only dan runbook
SLD-1 local-ready. Sales Invoice tetap memakai Sale POSTED/`invoice_no`;
Surat Jalan memakai `SJ/YYYY/MM/NNNNNN`, hanya untuk `DELIVERY`, dibuat atomic
bersama Post Sale, dan tidak membuat Stock/Finance effect kedua. Historical
Sale memakai provenance `LEGACY_CUTOVER`. Object logo yang sudah direferensikan
snapshot final wajib dipertahankan. Output live user 2026-08-11 tidak memiliki
`BLOCKER`: Customer/Store identity tetap `REVIEW`, sembilan Sale historis
`BACKFILL`, dan schema/retention `SETUP` menjadi scope SLD-2.

### Phase SLD-2 — Canonical Sales Invoice dan Surat Jalan foundation

- Sales Invoice menggunakan Sale POSTED sebagai single source of truth dan
  nomor invoice existing; tidak membuat total/AR/Tax baru;
- tambah immutable/versioned print snapshot bila receipt snapshot existing
  belum mencukupi;
- Surat Jalan hanya dibuat untuk delivery intent `DELIVERY`, dengan nomor
  manusiawi, Sale/Store/Warehouse/Customer source, recipient/address/notes,
  lines/qty/UOM snapshot, created/printed/dispatched/delivered audit;
- guarded create/read/status/reprint RPC/API; browser direct table write
  ditolak;
- generation dan retry idempotent; tidak ada Stock Movement/Event tambahan.

**Exit:** migration, backfill policy, postflight, behavioral, retry,
cross-tenant, Return compatibility, dan no-double-effect PASS.

**Status 2026-08-11:** user melaporkan migration, postflight, dan behavioral
SLD-2 seluruhnya PASS. Foundation database dinyatakan applied dan gate SLD-3
dibuka. Snapshot final, lifecycle, logo retention, serta no-double-effect tetap
menjadi invariant regression.

### Phase SLD-3 — POS/Backoffice UI dan printable templates

- POS checkout mendapat pilihan default `Ambil langsung` dan toggle
  `Perlu dikirim`;
- mode delivery mengisi Customer/penerima, telepon, alamat, tanggal/rencana,
  dan catatan; default boleh diambil dari Customer tetapi harus bisa direview;
- transaksi sukses tetap reset cart dan menawarkan buka/print struk, Invoice,
  serta Surat Jalan bila delivery;
- Backoffice Sales mempunyai daftar Invoice dan Surat Jalan, filter/search,
  detail, print/reprint, serta status delivery minimal;
- template memakai branding snapshot Company, data Store, Customer,
  Sale/Delivery number, tanggal, lines, UOM, totals (Invoice), dan tanda terima
  (Surat Jalan);
- print membuka new tab, bukan download paksa.

**Exit:** Cash/Transfer/split/TEMPO yang tersedia, Return, Offline replay,
Bundle, logo/no-logo, Walk-In recipient, tablet, print A4/thermal boundary,
dan permission smoke PASS.

**Status 2026-08-11:** implementasi POS, Backoffice list/detail/lifecycle, serta
template Invoice/Surat Jalan new-tab sudah LOCAL READY. PWA dan Backoffice lint/
production build PASS. Manual authenticated UAT mengikuti
`runbooks/SLD3_POS_BACKOFFICE_PRINT_UI.md`; fase belum COMPLETE sebelum matrix
role, two-Company, online/offline, dan no-double-effect dikonfirmasi user.

Status UAT tersebut kemudian **SUPERSEDED/PENDING REVISION** atas keputusan
user: checkbox delivery harus berada pada final checkout sebelum payment/POST,
Customer menjadi default recipient, dan ongkir opsional masuk total serta
Finance terpisah. Rincian ongkir pada Invoice boleh disembunyikan tanpa mengubah
total/ledger. Karena menyentuh payment, offline, AR, Customer Balance, Return,
event, dan jurnal, perubahan dibagi SLD-R1—R4; lihat
`SLD_DELIVERY_FEE_REVISION_PLAN.md`.

**SLD-R1/R2 status 2026-08-11:** user menjalankan diagnostic R1 dan seluruh
`BLOCKER` bernilai nol. R2 local-ready melalui migration `20260811140000`,
postflight, rollback-safe behavior, serta rollout runbook. Existing history
tetap immutable; actual Sale journal tetap G6 controlled HOLD. Manual R2 gate
wajib PASS sebelum confirmation/print UI R3 dibuka.

### Phase PRD-1 — Closing regression sebelum Vercel Preview

**Status 2026-08-12:** preflight SELECT-only siap di
`supabase/diagnostics/prd_phase1_predeploy_closing_preflight.sql`, dengan
petunjuk eksekusi di `runbooks/PRD1_PREDEPLOY_CLOSING_PREFLIGHT.md`. Preflight
harus dijalankan sebelum membuat Company kedua dan akun matrix UAT agar fixture
tidak menutupi blocker data live.

User kemudian mengirim output tanpa `BLOCKER`: migration, operational master,
Stock/FIFO/Movement, Finance journal, Invoice/Surat Jalan, Return, browser
boundary, import, dan Offline queue seluruhnya PASS. Tiga `SETUP` tersisa memang
fixture closing: Company kedua, role matrix, dan Kasir. Manual provisioning serta
postflight berikutnya ada di `runbooks/PRD1_UAT_IDENTITY_TENANT_SETUP.md`.

- full Backoffice/PWA build, auth/RLS/role matrix, multi-Company, DEX,
  Sale/Return/Stock/FIFO/Finance reconciliation regression;
- document duplicate/retry/concurrency test;
- Storage quota/CORS/content-type/cache review;
- secret/env/Auth redirect/Vercel Preview checklist;
- controlled E2E: Pickup Sale dan Delivery Sale -> Invoice/Surat Jalan ->
  Return/reprint tanpa double Stock/Finance effect.

**Exit:** baru setelah phase ini PASS project kembali ke pre-deploy/Vercel
Preview readiness.

### Insertion ACP-0—ACP-7 — Role baseline + custom restriction

Keputusan user 2026-08-12 menyisipkan custom permission sederhana sebelum full
PRD-1 role/multi-Company closing. Role existing tetap baseline sekaligus batas
maksimum; override opsional hanya membatasi per submodul. Tanpa override,
behavior harus identik dengan sekarang. Rencana resmi dan delapan cutover gate
berada di `ROLE_BASELINE_CUSTOM_PERMISSION_PLAN.md`.

PRD provisioning existing-user multi-Company tetap dependency awal. Setelah
itu urutan aman adalah ACP-1 access fingerprint, ACP-2 shadow foundation,
ACP-3 detail User/membership, ACP-4 Inventory pilot, ACP-5 Contacts/Purchase/
Sales, ACP-6 Finance/Data/Platform, ACP-7 closing. Full Vercel Preview regression
baru dilanjutkan setelah ACP-7 PASS.

Status 2026-08-12: ACP-1 access compatibility fingerprint local-ready sebagai
diagnostic SELECT-only, code-derived baseline matrix, dan runbook. Runtime tetap
role-only; ACP-2 belum dibuka sampai output live ACP-1 ditinjau.

## 6. Keputusan Produk yang Dikunci

- Home adalah launcher murni; statistik bukan bagian Home.
- Modul dan submodul memakai dua tingkat card.
- Sidebar tetap fast link, bukan sumber authorization.
- Logo Company opsional; tanpa logo tetap valid.
- Sales Invoice v1 adalah dokumen komersial printable dari Sale POSTED, bukan
  e-Faktur dan bukan Supplier Invoice.
- Surat Jalan hanya untuk Sale bertanda `Perlu dikirim`.
- Stock tetap dikurangi saat Sale POSTED; Surat Jalan tidak mengubah stock.
- Logistics advanced tetap deferred.

## 7. Rollback Strategy

- UXD dapat rollback ke launcher satu tingkat tanpa schema/data impact.
- Branding dapat dinonaktifkan dengan fallback tanpa menghapus object/history.
- Sales document UI dapat ditutup read-only tanpa menghapus Sale atau snapshot.
- Jika generation dokumen bermasalah, checkout final harus fail-closed sesuai
  atomic contract yang dipilih pada SLD-1; forward-fix tidak boleh menciptakan
  invoice/surat jalan duplikat.
