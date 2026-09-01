# MADS — Management Distribution System

> 2026-09-01: kompatibilitas detail dan unduh/print Surat Jalan ODR untuk Admin
> Gudang **local-ready**. Forward migration `20260901110000` memakai snapshot
> Delivery immutable di bawah `inventory.delivery_documents VIEW`; rollout
> database dan authenticated smoke masih manual. Lihat
> `docs/runbooks/INVENTORY_DELIVERY_ODR_PRINT_COMPATIBILITY.md`.

> 2026-09-01: ODR Dispatch runtime schema forward-fix **local-ready**.
> Error generik Dispatch dilacak ke pemanggilan `digest` dari schema yang salah
> dan referensi kolom requirement legacy. Forward-fix `20260901100000`
> menggunakan `extensions.digest` serta Product canonical tanpa mengubah alur
> bisnis atau data historis. Exact SJ berhasil dalam transaksi rollback; lint
> dan production build Backoffice PASS. Produksi belum dimutasi oleh agent.
> Rollout dan authenticated smoke masih manual; lihat
> `docs/runbooks/ODR_DISPATCH_RUNTIME_SCHEMA_FORWARD_FIX.md`.

> 2026-09-01: Platform Health Operasional Super Admin **local-ready**.
> Dashboard global hanya membaca agregat status lintas Company melalui RPC
> guarded, refresh manual, timeout terbatas, tanpa trigger, auto-fix, atau
> perubahan transaksi. Database rollout, deploy Backoffice, dan authenticated
> Super Admin/regular-user smoke masih manual; lihat
> `docs/runbooks/PLATFORM_OPERATIONAL_HEALTH_DASHBOARD_ROLLOUT.md`.

> 2026-08-31: detail penerimaan pada riwayat Supplier Order local-ready.
> Read model `20260831110000` menampilkan ordered, total receipt `POSTED`, dan
> remaining per barang tanpa mengubah PO, Goods Receipt, Stock, AP, atau
> Finance. Rollout database, deploy Backoffice, dan authenticated smoke masih
> manual; lihat `docs/runbooks/PURCHASE_SUPPLIER_ORDER_RECEIPT_PROGRESS.md`.

> 2026-08-31: forward-fix read-only Purchasing Demand `20260831100000`
> local-ready. Alias Product pada aggregate composed PO diperbaiki tanpa
> mengubah Demand, Request, PO, Stock, atau Finance. Migration, postflight,
> behavioral rollback, dan authenticated smoke masih harus dijalankan manual;
> lihat `docs/runbooks/ODR6C1_PURCHASING_DEMAND_UI_CUTOVER.md`.

> 2026-08-30: forward-fix pembatalan Cash Order dari sesi sumber yang sudah
> ditutup sekarang local-ready. Reversal exact-once masuk ke sesi aktif Kasir
> pada Store yang sama tanpa menulis ulang closing lama. Rollout database,
> deployment, dan authenticated smoke masih manual; lihat
> `docs/runbooks/SALES_ORDER_CANCELLATION_INVOICE_SYNC.md`.

> 2026-08-30: forward-fix ODR Draft-resume local-ready memisahkan Draft input
> dari Order confirmed/reserved. Rollout database dan authenticated smoke masih
> manual; lihat `docs/runbooks/ODR_CONFIRMED_ORDER_DRAFT_RESUME_GUARD.md`.

Arsitektur lanjutan Order Reservation/Dispatch telah **disetujui**. ODR-1,
ODR-2A, dan ODR-2B atomic reservation runtime sudah dikonfirmasi PASS pada
database user. Targetnya: konfirmasi POS
membuat Sales Order serta `Reserved Out`, Stock/FIFO baru berkurang saat Surat
Jalan di-Dispatch, shortage dihimpun per sesi untuk Purchasing, dan verifikasi
pembayaran Finance dipisahkan dari event Dispatch. Rencana enam fase dan batas
compatibility tersedia di
[POS Order Reservation, Dispatch, Procurement, and Finance Plan](docs/POS_ORDER_RESERVATION_DISPATCH_FINANCE_PLAN.md).
ODR-6B.2 Inventory Dispatch UI sekarang **local-ready**. Backoffice Surat Jalan
memakai runtime canonical untuk partial/full Dispatch dan konfirmasi diterima;
Dispatch menyelaraskan On Hand, FIFO, Movement, dan Reserved Out, sedangkan
Received tidak memberi stock effect kedua. Dokumen legacy tetap kompatibel dan
tidak ada migration baru pada tahap UI ini. Deploy serta authenticated smoke
masih menunggu user sesuai
[runbook ODR-6B.2](docs/runbooks/ODR6B2_INVENTORY_DISPATCH_UI_CUTOVER.md).
ODR-6C.1 Purchasing Demand UI juga **local-ready**. Supplier Order sekarang
menampilkan shortage Reservation per sesi serta amendment Draft/final PO, dan
allocation Draft ikut mengurangi daftar permintaan yang masih dapat dibuatkan
PO. Tahap client ini tidak membuat migration atau mengubah PO final. Rollout
manual mengikuti
[runbook ODR-6C.1](docs/runbooks/ODR6C1_PURCHASING_DEMAND_UI_CUTOVER.md).
ODR-6C.2 Finance Payment Verification UI sekarang **local-ready**. Finance
memperoleh composed workspace untuk melihat, memverifikasi, atau menolak
payment intent dengan effective capability, maker-checker, optimistic version,
dan exact retry. Verifikasi hanya membuat Event `HOLD`; jurnal tetap melalui
controlled Posting Queue dan policy Company tidak diubah. Tahap ini tidak
menambah migration. Rollout manual mengikuti
[runbook ODR-6C.2](docs/runbooks/ODR6C2_FINANCE_PAYMENT_VERIFICATION_UI_CUTOVER.md).
Forward-fix Tutup Sesi asynchronous-payment `20260829130000` juga **local-ready**:
kasir tidak lagi menunggu Finance memverifikasi setiap pembayaran untuk menutup
sesi. Cash drawer movement, actual count/difference, antrean verifikasi, audit,
dan controlled Journal tetap dipertahankan. Rollout manual mengikuti
[runbook Cash Session Close](docs/runbooks/CASH_SESSION_CLOSE_ASYNC_PAYMENT_VERIFICATION.md).
Closing database gate ODR-6C.2 sudah dikonfirmasi seluruhnya PASS. ODR-6D
menemukan lalu menutup tiga consumer legacy pada Return, AR/Statement, dan
TEMPO Collection. Combined postflight dan closure preflight kemudian dilaporkan
PASS: Return dibatasi quantity Dispatch immutable, AR/Receipt hanya mengakui
receivable yang sudah Dispatch, dan pre-Dispatch payment tetap Customer
Advance. Order ODR tidak diubah menjadi legacy POSTED. Full authenticated UAT
lintas role/two-Company/retry tetap pending. Ikuti
[runbook compatibility ODR-6D](docs/runbooks/ODR6D_CONSUMER_COMPATIBILITY_ROLLOUT.md).
Contract freeze, klasifikasi historical, failure code, dan manifest ODR-2 ada di
[ODR-1 Live Contract Audit](docs/ODR1_LIVE_CONTRACT_AUDIT.md). Jalankan
[runbook preflight ODR-1](docs/runbooks/ODR1_ORDER_RESERVATION_DISPATCH_PREFLIGHT.md)
dan pastikan tidak ada `BLOCKER` sebelum ODR-2 dimulai.
ODR-2B membentuk `Reserved Out` dengan optimistic version, exact retry,
Product-Warehouse lock, serta validasi stok-minus terhadap saldo proyeksi.
Confirm/Cancel belum mengubah On Hand, FIFO, Movement, dokumen final, atau
Finance. Migration, behavioral, dan closing postflight ODR-2B sudah
dikonfirmasi PASS oleh user. Preflight ODR-3 juga sudah PASS tanpa blocker.
ODR-3A foundation sekarang local-ready untuk linkage Delivery–Reservation,
partial Dispatch, dan immutable allocation evidence; migration ini belum
mengubah Stock/FIFO/Movement/Finance atau dokumen historis. Ikuti
[runbook ODR-2](docs/runbooks/ODR2_SALES_ORDER_RESERVATION_ROLLOUT.md).
Rollout berikutnya mengikuti
[runbook ODR-3A](docs/runbooks/ODR3A_DELIVERY_DISPATCH_FOUNDATION.md).
ODR-3A telah dikonfirmasi user seluruhnya PASS. ODR-3B confirmed-order
documents kini local-ready: Confirm membuat snapshot Invoice/SJ immutable dan
RPC status lama tidak boleh menandai linked Delivery sebagai Dispatch tanpa
runtime stok. Rollout mengikuti
[runbook ODR-3B](docs/runbooks/ODR3B_CONFIRMED_ORDER_DOCUMENTS.md).
ODR-3B juga telah dikonfirmasi user seluruhnya PASS. ODR-3C atomic Delivery
Dispatch sudah database-live dan seluruh SQL gate PASS: partial/full Dispatch menyelaraskan Reservation,
On Hand, FIFO, Movement, dan immutable allocation dalam satu transaksi;
Delivered tidak memberi stock effect kedua dan Finance tetap ditunda ke ODR-5.
Runbook dan evidence mengikuti
[runbook ODR-3C](docs/runbooks/ODR3C_ATOMIC_DELIVERY_DISPATCH.md).
Gate aktif berpindah ke ODR-4 preflight SELECT-only
untuk demand Purchasing per sesi dan sinkronisasi Draft PO; belum ada schema
atau runtime ODR-4 yang diaktifkan. Jalankan
[runbook ODR-4](docs/runbooks/ODR4_PROCUREMENT_DEMAND_PREFLIGHT.md).
Preflight ulang kemudian diterima tanpa blocker. ODR-4A additive demand
foundation kini local-ready dan tetap zero-backfill; Stock Request, Draft/final
PO, stok, serta Finance belum disentuh. Rollout manual mengikuti
[runbook ODR-4A](docs/runbooks/ODR4A_PROCUREMENT_DEMAND_FOUNDATION.md).
User kemudian mengonfirmasi seluruh gate ODR-4A PASS. ODR-4B session demand
runtime kini local-ready: Confirm/Cancel merekonsiliasi demand secara atomik,
session close membekukan identitas, dan Purchasing memperoleh composed read.
Stock Request/PO sync tetap belum dibuka. Rollout mengikuti
[runbook ODR-4B](docs/runbooks/ODR4B_SESSION_PROCUREMENT_DEMAND_RUNTIME.md).

Order TEMPO terjadwal sekarang **local-ready**. Kasir dapat menyimpan order
untuk tanggal mendatang; Draft otomatis tampil sebagai Order aktif ketika
tanggal bisnis Company tercapai, tetapi tetap memerlukan Post manual. Sebelum
Post tidak ada efek Stock, Payment, AR, Invoice, Surat Jalan, Financial Event,
atau jurnal. Tanggal Finance memakai waktu Post aktual dan tanggal rencana tetap
disimpan sebagai referensi order. Rollout manual mengikuti
[runbook POS Scheduled TEMPO Order](docs/runbooks/POS_SCHEDULED_TEMPO_ORDER_ROLLOUT.md).
Preflight, migration, postflight, dan behavior SQL telah dikonfirmasi PASS oleh
user; PWA smoke terautentikasi dan deployment client masih menunggu.

Finance F1–F4B sekarang **local-ready**: kebijakan pembuatan Accounting Period per
Company (`MANUAL`/`AUTOMATIC`), auto-create bulan berjalan dan berikutnya tanpa
membuka periode terkunci, serta perbaikan resume Draft TEMPO dan perbandingan
jatuh tempo berdasarkan tanggal bisnis Company; Customer Receipt, historical
collection, AR aging/statement/export; serta policy posting `CONTROLLED` atau
`AUTOMATIC`. F4B tidak mengubah policy live saat migration dan tidak memposting
backlog secara diam-diam. Rollout terakhir mengikuti
[runbook Finance F4B](docs/runbooks/FINANCE_AR_POSTING_POLICY_CLOSURE.md).

Panduan penggunaan lengkap: [Manual Pengguna MADS](docs/MANUAL_PENGGUNA_KGS_POS.md).
Checklist UAT, edge case, stop condition, dan risk register:
[Matriks UAT User MADS](docs/USER_UAT_EDGE_CASE_RISK_REGISTER.md).

Pengaturan tanggal Invoice per Company sekarang **local-ready**. Owner/Admin
dapat memilih `Tanggal Order` untuk backorder atau `Tanggal Transaksi` untuk
hari POST; print/PDF Backoffice dan POS hanya menampilkan tanggal tanpa jam.
Policy disnapshot pada Invoice baru dan rollout manual mengikuti
[runbook pengaturan tanggal Invoice](docs/runbooks/INVOICE_DATE_DISPLAY_POLICY_ROLLOUT.md).

Penyelarasan dokumen penjualan sekarang **local-ready**. Invoice A4 POS memakai
template canonical yang sama dengan Backoffice, sedangkan Surat Jalan dapat
dipilih per Company sebagai template Gudang (`Warehouse, Security, Driver,
Customer`) atau Toko (`Kasir, Ekspedisi, Customer`). Nota thermal tidak berubah;
policy Surat Jalan disnapshot pada dokumen baru. Rollout manual mengikuti
[runbook penyelarasan template](docs/runbooks/SALES_DOCUMENT_TEMPLATE_ALIGNMENT_ROLLOUT.md).

Kontak Delivery fleksibel sekarang **local-ready**. Nama penerima tetap wajib,
sedangkan telepon, alamat, jadwal, catatan, dan ongkir boleh kosong; data yang
tersedia hanya disnapshot ke transaksi/Surat Jalan dan tidak memutasi Customer.
Rollout manual mengikuti
[runbook kontak opsional Surat Jalan](docs/runbooks/SALES_DELIVERY_OPTIONAL_CONTACT_ROLLOUT.md).

Penerimaan Barang melalui Backoffice Gudang sekarang **local-ready**. Menu baru
`Purchase → Penerimaan Barang` memberi Owner/Admin/Warehouse Admin jalur Draft
tanpa sesi Kasir, tetapi Post tetap memakai mesin canonical Goods Receipt yang
sama dengan PWA untuk Stock, FIFO, AP provisional, Financial Event, status PO,
idempotency, dan audit. Database belum diubah; rollout manual mengikuti
[runbook Penerimaan Barang Backoffice](docs/runbooks/BACKOFFICE_GOODS_RECEIPT_ROLLOUT.md).

Forward-fix workspace, postflight, dan behavioral test telah dikonfirmasi PASS
oleh user. Navigation Backoffice juga dibuat fail-closed per permission agar
satu key bermasalah tidak lagi mengosongkan seluruh aplikasi Super Admin.

Deployment staging 24 Agustus 2026 sudah diperbarui pada
`https://pointofsales-kgs-staging.vercel.app` dan
`https://kgs-pos-pwa-staging.vercel.app`; kedua root dan manifest PWA lulus
smoke publik. Project serta database production tidak disentuh.

Filter rentang tanggal Inventory Surat Jalan sudah dipasang melalui migration
`20260824120000_inventory_delivery_date_range_filter.sql` dan dideploy ke
Backoffice staging. Penyaringan memakai timezone Company; authenticated UI
smoke tetap menunggu konfirmasi user.

Operasi cutover Product-UOM per Company ke PACK-only sudah **local-ready**.
Operasi default PREVIEW, mengaktifkan PACK untuk beli/jual, menonaktifkan DUS
dari transaksi baru tanpa menghapus histori, serta menjaga referensi Supplier,
Pricelist, berat, dan audit. Database belum diubah; jalankan sesuai
[runbook PACK-only](docs/runbooks/COMPANY_PACK_ONLY_UOM_CUTOVER.md).

Import Pricelist Distributor kini **local-ready** melalui Global Data Exchange.
File Excel/CSV dicocokkan berdasarkan Company aktif dan SKU; COGS/Retail PACK
menjadi harga dasar, harga DUS/UOM lain diturunkan dari faktor UOM, tiga harga
Customer reusable dibuat/diperbarui, dan tier 60/100/150 PACK masuk Global
default. Preview, apply atomik, audit, exact retry, postflight, behavioral test,
dan rollout tersedia pada
[runbook Import Pricelist Distributor](docs/runbooks/DISTRIBUTOR_PRICELIST_IMPORT_ROLLOUT.md).
Database dan deployment belum diubah oleh perubahan lokal ini.
Jika migration dasar import sudah terpasang, gunakan forward-fix
`20260824110000_distributor_pricelist_missing_sku_skip.sql`; SKU yang tidak
ditemukan akan dilewati tanpa membatalkan SKU valid lainnya.

Operasi admin manual untuk akun terdaftar tersedia sebagai SQL terpisah:
[`find_registered_user.sql`](supabase/operations/find_registered_user.sql)
bersifat SELECT-only dan langsung menampilkan seluruh akun beserta Company,
role, serta status membership tanpa perlu UUID; sedangkan
[`update_registered_user_identity.sql`](supabase/operations/update_registered_user_identity.sql)
default PREVIEW dan menyinkronkan email login, profile, email identity, serta
nama metadata secara atomik setelah konfirmasi eksplisit. Password, role,
membership, permission, dan histori tidak diubah.

Update 21 Agustus 2026: Platform kini memiliki workspace **Point of Sales**
untuk membuat dan mengubah Toko/Terminal secara guarded dan audited. PWA
multi-Company memilih Company serta Terminal/Toko sebelum membuka sesi dan
mengunci perpindahan selama sesi aktif. Form User & Akses juga telah diperbaiki:
state role/Toko membership terpilih tidak lagi bercampur dengan form assignment
Company baru. Backoffice dan PWA lint/build PASS. Perubahan sudah dipublikasikan
ke `https://pointofsales-kgs-staging.vercel.app` dan
`https://kgs-pos-pwa-staging.vercel.app`; kedua root memberi HTTP 200 dan API
Backoffice tanpa sesi tetap menolak dengan HTTP 401 JSON. Project/database
production tidak disentuh.

Staging terbaru berhasil dipublikasikan pada 20 Agustus 2026 dari commit
`cc3efab`: PWA di `https://kgs-pos-pwa-staging.vercel.app` dan Backoffice di
`https://pointofsales-kgs-staging.vercel.app`. Kedua build Vercel dan smoke HTTP
publik PASS; deployment ini tidak mengubah database maupun project production.

Deployment staging berikutnya pada 20 Agustus 2026 mempublikasikan seluruh
working tree terbaru, termasuk Profil/Rekening Company dan export PO terpilih,
langsung ke project ID staging yang terverifikasi. Build Backoffice (70 route)
dan PWA berhasil; kedua alias memberi HTTP 200. Project, environment, database,
dan domain production tidak disentuh.

Paket MADS dokumen/PO/Terminal UI sekarang **local-ready**: Backoffice dapat
mengunduh PDF Invoice dan Surat Jalan dengan nama Customer di depan, Supplier
Order mempunyai export XLSX berizin, dan fitur operasional PWA dapat
disembunyikan per Terminal tanpa mengubah otorisasi server. Branding visual
menjadi **MADS - Management Distribution System**; identifier database
historis tetap dipertahankan. Migration dan authenticated smoke masih menunggu
rollout manual sesuai [runbook](docs/runbooks/MADS_DOCUMENT_PO_TERMINAL_UI_ROLLOUT.md).

Surat Jalan juga mendukung bulk download lokal tanpa schema baru: pengguna
dapat memilih hingga 50 dokumen dan menerima satu ZIP yang tetap berisi PDF
individual Customer-first. Unduh satuan, print, lifecycle pengiriman, tenant,
dan audit dokumen tidak berubah.

Template print/PDF Invoice dan Surat Jalan tidak lagi merender nama Company.
Logo tetap opsional. Invoice tidak mempunyai tanda tangan; Surat Jalan memakai
template Gudang empat pihak atau template Toko tiga pihak sesuai snapshot.

Pengaturan logo dokumen sekarang **local-ready** per Company. Owner/Admin dapat
mengatur logo header dan stempel visual secara independen pada print/PDF Invoice
dan Surat Jalan tanpa menghapus file logo atau menghilangkannya dari navigasi
aplikasi. Stempel tampil mandiri pada Invoice dan berada di kolom pertama Surat
Jalan sesuai template yang dipilih.
Company existing default menampilkan logo header dan menyembunyikan stempel.
Rollout database dan smoke staging masih manual sesuai
[runbook](docs/runbooks/COMPANY_DOCUMENT_LOGO_VISIBILITY_ROLLOUT.md).

UX PWA POS untuk input angka dan penutupan sesi juga **local-ready**. Wheel pada
field numerik kini menggulir container tanpa mengubah nilai. Penutupan sesi
diakses melalui tombol **Tutup Sesi** di header dan kas fisik diisi dalam modal
konfirmasi. Field nominal utama menampilkan pemisah ribuan Indonesia, misalnya
`100.000`, sementara payload server tetap berupa nilai numerik mentah. Tidak ada
kontrak transaksi atau schema yang berubah.

Import/export Customer dan import additive UOM Product sekarang local-ready di
Global Data Exchange. Template additive UOM mengambil seluruh Product aktif dan
memberi satu baris input kosong per Product; baris kosong dilewati, UOM existing
tetap dipertahankan, Base UOM tidak dapat diganti, dan conversion historis yang
sudah dipakai Movement tetap terkunci. Rollout database masih manual melalui
[runbook Customer](docs/runbooks/PRD_CUSTOMER_MASTER_IMPORT_EXPORT.md) lalu
[runbook Product-UOM](docs/runbooks/PRD_PRODUCT_UOM_ADDITIVE_IMPORT_EXPORT.md).
Backoffice targeted ESLint dan production build sudah PASS.

Koreksi lanjutan Product-UOM **local-ready**: Template dan Export kini
menampilkan UOM existing sebagai baris `REFERENCE`, diikuti satu baris `INPUT`
kosong per Product. Reference tidak masuk staging. Validasi yang mengandung
error mempertahankan baris valid agar tetap dapat di-commit, sementara baris
error dapat diunduh dan job nonterminal dapat dibatalkan manual dari Riwayat
Import. Job upload/pemetaan milik pengguna yang
ditinggalkan lebih dari 15 menit juga ditutup otomatis dengan audit setelah
permission import diperiksa ulang. Migration, postflight, behavior, dan
smoke staging mengikuti [runbook koreksi](docs/runbooks/PRODUCT_UOM_CONTEXT_TEMPLATE_JOB_CANCEL_ROLLOUT.md).

Koreksi Master Data UOM/Kategori sebelum UAT sekarang local-ready: nama UOM
kembali terlihat, edit tetap melalui RPC berizin, dan hard delete baru hanya
berlaku untuk row yang belum direferensikan. Master yang sudah dipakai harus
dinonaktifkan; semantik quantity UOM historis dikunci. Migration, postflight,
rollback behavioral test, dan authenticated staging smoke masih menunggu
rollout manual sesuai [runbook](docs/runbooks/PRD_GUARDED_INVENTORY_MASTER_CLEANUP.md).
Local TypeScript, lint, dan production build sudah PASS.

Template persiapan data go-live dan urutan cutover tersedia di
[Paket Template Cutover Go-Live](docs/templates/go-live-cutover/README.md).
Setelah dua migration Data Exchange terbaru diterapkan, dua belas tipe master
di paket mengikuti kontrak Import & Export aktif;
template opening AR/AP/Customer Deposit/GL adalah lembar pengumpulan data dan
belum boleh diinjeksi sebelum workflow opening Finance/subledger tersedia.

Recovery user tanpa Company sekarang local-ready: Super Admin tetap dapat
membuka detail akun setelah membership terakhir dicabut, melihat status tanpa
akses, dan menambahkan kembali Company tanpa mengetik ulang email. Modal tetap
terbuka setelah revoke terakhir. Login Backoffice/PWA tetap fail-closed dan
menampilkan pesan bahwa akun tidak memiliki akses perusahaan; authenticated
staging smoke masih menunggu redeploy.

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

MADS adalah aplikasi Management Distribution System multi-Company yang sedang
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
- Controlled reset data transaksi per Company: [`docs/runbooks/PRD_COMPANY_TRANSACTIONAL_DATA_RESET.md`](docs/runbooks/PRD_COMPANY_TRANSACTIONAL_DATA_RESET.md)
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
## Status lokal terbaru — 2026-08-19

Alur stok minus POS ke Permintaan Barang per sesi telah **local-ready**, belum
aktif di database sampai migration `20260819170000` dijalankan. Sale online
yang mendapat otorisasi tetap dapat diposting; close sesi akan membuat tepat
satu Stock Request `SUBMITTED` dari shortage sesi yang belum direplenish.
Migration, preflight, postflight, rollback behavioral test, PWA readiness/error,
notice penutupan, badge Purchasing, dan [runbook rollout](docs/runbooks/PRD_NEGATIVE_STOCK_SESSION_REQUEST_ROLLOUT.md)
tersedia. PWA lint/build, targeted Backoffice lint, Backoffice production build,
static SQL/diff gate, behavioral utama, dan empat regression sudah PASS.
Final postflight serta authenticated smoke masih wajib sebelum dianggap siap
dipakai pada data go-live.

## Status lokal terbaru — 2026-08-20 (Profil/Rekening Company)

Profil Company dan tiga field rekening opsional telah **local-ready** melalui
migration `20260820120000`; belum aktif di database sampai rollout manual.
Platform **Profil Perusahaan** mencakup identitas, alamat, kontak, rekening,
logo, dan setting dokumen. Rekening Supplier otomatis mengisi Draft Pembayaran
Supplier. Toggle rekening Invoice default `OFF`; Invoice baru menyimpan snapshot
rekening immutable, sedangkan Surat Jalan tidak menampilkannya. Backoffice
targeted lint/build dan PWA lint/build PASS. Jalankan migration, postflight,
behavior rollback, lalu staging smoke sesuai
[`COMPANY_PROFILE_BANK_INVOICE_ROLLOUT.md`](docs/runbooks/COMPANY_PROFILE_BANK_INVOICE_ROLLOUT.md).

Update rollout: user telah menjalankan migration, postflight terkoreksi, dan
behavioral rollback test dengan hasil seluruhnya PASS pada database target yang
diuji. Client build tetap menunggu deployment dan authenticated smoke sebelum
fitur dinyatakan aktif end-to-end pada environment tersebut.

## Status lokal terbaru - 2026-08-20 (Export PO Terpilih)

Export Supplier Order kini **local-ready** untuk pilihan eksplisit: admin dapat
memfilter daftar, mencentang PO satuan atau seluruh hasil filter, lalu mengunduh
satu XLSX tiga-sheet yang hanya berisi maksimal 100 PO terpilih. Overload RPC
baru memvalidasi capability EXPORT, active Company, UUID, duplikasi, dan tenant
seluruh dokumen; GET/RPC tanpa argumen lama dipertahankan untuk compatibility.
Migration/postflight/behavior serta rollout manual tersedia di
[`SELECTED_SUPPLIER_ORDER_EXPORT_ROLLOUT.md`](docs/runbooks/SELECTED_SUPPLIER_ORDER_EXPORT_ROLLOUT.md).

## Operasi terkontrol - Duplikasi konfigurasi Finance antar-Company

Untuk onboarding Company baru tersedia operasi SQL preview/apply yang memetakan
COA, hierarchy, Transaction Category, Account Function mapping, dan approved
Posting Rules dari Company sumber ke UUID baru milik Company tujuan. Operasi
menolak target yang sudah mempunyai Financial Event atau Journal; baseline
mapping target tanpa histori dinonaktifkan/di-retire secara audited;
tidak menyalin saldo, transaksi, master operasional, identitas, entitlement,
atau policy Store/Warehouse/Terminal. Panduan dan batas operasinya tersedia di
[`COMPANY_FINANCE_CONFIGURATION_CLONE.md`](docs/runbooks/COMPANY_FINANCE_CONFIGURATION_CLONE.md).

Persiapan Company baru dapat dilanjutkan dengan duplikasi template master
Product tanpa membawa transaksi atau stok. Cakupan, exclusion, dan preflight
fail-closed tersedia di
[`COMPANY_MASTER_TEMPLATE_CLONE.md`](docs/runbooks/COMPANY_MASTER_TEMPLATE_CLONE.md).
Setelah preflight Company tujuan seluruhnya `PASS`, operasi atomik
`clone_company_product_master.sql` dapat dijalankan dalam mode PREVIEW lalu
APPLY. Baseline Global Pricelist direuse berdasarkan code; postflight terpisah
memverifikasi semantic parity dan memastikan tidak ada Stock/transaksi terbawa.

## Status lokal terbaru - 2026-08-21 (Platform POS: Toko & Terminal)

Menu **Platform > Point of Sales** kini local-ready untuk mengelola Toko dan
Terminal pada Company aktif. Mutation guarded, audited, versioned, dan direct
browser write ditutup. PWA mempertahankan satu login multi-Company: Company dan
Terminal/Toko dipilih sebelum membuka sesi, lalu selector Company terkunci
selama sesi aktif. Backoffice lint dan production build PASS; rollout database
dan authenticated smoke masih manual gate. Panduan ada di
[`PLATFORM_POS_STORE_TERMINAL_MANAGEMENT_ROLLOUT.md`](docs/runbooks/PLATFORM_POS_STORE_TERMINAL_MANAGEMENT_ROLLOUT.md).

## Status lokal terbaru - 2026-08-25 (Preview harga Pricelist POS)

Bug harga umum yang tetap tampil sampai Draft disimpan telah diperbaiki secara
local-ready. PWA sekarang meminta preview read-only untuk seluruh Product-UOM
dari resolver Pricelist canonical ketika Customer, Pricelist, atau quantity
berubah. Kartu Product dan cart menampilkan harga server tanpa membuat Draft;
Save/Post tetap menghitung ulang dan tetap menjadi sumber kebenaran. Migration
additive `20260825100000`, postflight, behavior rollback-safe, dan urutan rollout
tersedia di
[`POS_LIVE_PRICELIST_PREVIEW_ROLLOUT.md`](docs/runbooks/POS_LIVE_PRICELIST_PREVIEW_ROLLOUT.md).
PWA oxlint serta production build sudah PASS; database rollout dan authenticated
smoke masih manual sehingga fitur belum dinyatakan aktif pada staging/production.

## Status lokal terbaru - 2026-08-25 (Tier Pricelist diskon persen)

Form Pricelist Backoffice kini dapat membuat rule quantity tier dengan metode
**Diskon persen**, selain harga akhir langsung dan potongan nominal per UOM.
Nilai dibatasi 0–100% dan form menampilkan perkiraan harga akhir berdasarkan
harga normal Product-UOM. Resolver canonical online/offline serta kontrak API
yang sudah ada tetap menjadi sumber kebenaran; tidak ada perubahan schema atau
format Import Pricelist Distributor.

## Status lokal terbaru - 2026-08-25 (Tanggal transaksi TEMPO)

Checkout TEMPO PWA kini menampilkan tanggal transaksi/order read-only dan
tanggal jatuh tempo secara berdampingan. Tanggal transaksi berasal dari
`sales_headers.transaction_date`; default tenor Customer hanya memberikan saran
jatuh tempo dan kasir tetap dapat mengubahnya sebelum Post. Migration additive
`20260825110000`, postflight, behavior read-only, dan runbook rollout tersedia.
Core Save/Post, Finance, serta larangan TEMPO Offline tidak berubah.

## Status lokal terbaru - 2026-08-25 (Price override per Terminal POS)

Point 1 sekarang **local-ready**. Terminal/POS mempunyai policy default OFF
untuk mengizinkan override harga per line bagi seluruh kasir sah pada Terminal.
Harga awal tetap resolver Pricelist canonical; hanya override eksplisit yang
menang. Save Draft dan Post memvalidasi ulang policy, sesi aktif, actor, Store,
Terminal, serta channel Online di server. Sale line menyimpan harga canonical,
harga final, actor, Terminal, sesi, source, dan waktu resolve. Offline tetap
menolak override. Migration `20260825120000`, preflight, postflight, runbook,
Backoffice setting, dan PWA edit/reset sudah tersedia. User mengonfirmasi
preflight, migration, postflight awal, dan behavior rollback-safe PASS.
Postflight ulang menjadi closing database berikutnya; deployment client staging
dan authenticated smoke masih manual. User kemudian mengonfirmasi seluruh
dependency/closing PASS; Backoffice dan PWA berhasil dideploy ke dua alias
staging dengan root/manifest HTTP 200. Authenticated ON/OFF transaction smoke
tetap menjadi gate terakhir sebelum status operasional dinyatakan selesai.

## Status lokal terbaru - 2026-08-25 (Workspace POS laptop dua panel)

PWA POS kini local-ready dengan dua pilihan tampilan. Mode **Katalog** lama tetap
menjadi default. Mode **Compact** menjadi alternatif laptop: searchable Product
dropdown dan keranjang berada di kiri, sedangkan Customer, Pricelist, aturan
transaksi, pembayaran, total, serta aksi Draft/Post berada di kanan. Pilihan
disimpan per browser dan switcher berada di header sebagai satu grup responsif,
sehingga area kerja tidak terdorong turun ketika menu Terminal aktif/nonaktif.
Mode dapat diganti tanpa mengubah isi transaksi. Handler cart, preview
Pricelist, Save Draft, checkout, Offline, stock, payment, dan
Finance tidak diubah. PWA lint serta production build PASS; authenticated
browser smoke dan deployment staging/production belum dilakukan.

Atas koreksi user, mode Katalog memakai kembali layout sebelum Compact: kategori
dan kartu Product berada di kiri, sedangkan satu kolom kanan sticky memuat
keranjang dan checkout. Baris keranjang Katalog dibuat horizontal dan ringkas:
nama Product, quantity/UOM, indikator perubahan harga/diskon bila ada, dan
tombol **Edit**, dengan tiga Product terlihat sebelum scroll. Mode Compact tetap
menampilkan 3–4 kartu keranjang per baris pada desktop.
## Update 2026-08-26 — POS TEMPO Backdated Order/Delivery Local Ready

- POS online kini mempunyai kontrak lokal untuk tanggal efektif order TEMPO
  lampau dan rencana kirim lampau. Tanggal order wajib bukan masa depan, berada
  pada Accounting Period `OPEN/REOPENED`, jatuh tempo tidak lebih awal, dan
  rencana kirim tidak boleh sebelum order.
- Waktu input/posting aktual tetap immutable pada `created_at/posted_at`;
  Financial Event Sale memakai `transaction_date` efektif. Cash/Transfer,
  Offline, Stock Movement, serta lifecycle konfirmasi pengiriman tidak berubah.
- Rollout manual belum dijalankan ke database mana pun. Urutan preflight,
  migration, postflight, behavioral test, dan smoke tersedia di
  `docs/runbooks/POS_TEMPO_BACKDATED_ORDER_DELIVERY_ROLLOUT.md`.

## Rencana 2026-08-26 — Analitik Potensi Produk per Customer

- User menyetujui desain awal submodul opsional `Report > Potensi Produk`.
  Fitur membaca Sale/Return final untuk menghitung actual, potential, gap,
  achievement, dan tren tanpa membuat/mengubah transaksi, Stock, Pricelist,
  Purchasing, Payment, atau Finance.
- Model formula dikonfigurasi per Company dan versioned; saat aktivasi admin
  memilih tanggal efektif serta `FORWARD_ONLY` atau historical backfill sejak
  tanggal tersebut. Feature OFF tidak menjalankan job dan tidak mengganggu
  runtime operasional.
- Status masih **approved design / implementation not started**. Source of truth:
  `docs/PRODUCT_POTENTIAL_ANALYTICS_SPEC.md`. Tidak ada schema, UI, database,
  atau deployment yang dibuka oleh pencatatan ini.

## Operasi lokal 2026-08-26 — Update COGS LSM, SMS, dan KMS

- Paket operasi COGS-only dari `Price List Distributor 26082026.xlsx` sudah
  local-ready dan belum dijalankan ke database mana pun oleh Codex.
- Operasi dijalankan satu Company per run dengan PREVIEW sebagai default,
  confirmation eksplisit untuk APPLY, SKU matching, PACK conversion, atomic
  write, dan Product master audit.
- Hanya `products.cogs` dan `purchase_price` Product-UOM aktif yang boleh
  berubah. Retail, harga jual, Pricelist, UOM nonaktif, Stock/FIFO, transaksi,
  Financial Event, dan Journal tetap tidak disentuh.
- Runbook: `docs/runbooks/COMPANY_COGS_UPDATE_20260826.md`.

## Status lokal terbaru - 2026-08-27 (Penerimaan Customer / AR)

- Foundation database Customer Receipt sudah dikonfirmasi PASS oleh user:
  Draft/Post/Cancel, alokasi parsial satu Customer ke banyak Invoice tempo,
  audit immutable, permission ENFORCED, dan `SALE_PAYMENT` event tersedia.
- Backoffice kini memiliki menu **Finance > Penerimaan Customer** untuk memilih
  Customer, melihat invoice tempo terbuka, mengalokasikan pembayaran, menyimpan
  atau melanjutkan Draft, Post, dan membatalkan Draft.
- Runtime journal lanjutan `20260827110000` local-ready: debit Kas/Bank, kredit
  Piutang Customer, dimensi Customer, source verification, exact replay, serta
  prior-period adjustment. Rollout database runtime dan authenticated smoke
  masih menunggu user; fitur belum dinyatakan aktif di deployment.
- Evidence lokal Backoffice: targeted ESLint PASS dan production build PASS
  (74 route, termasuk `/api/finance/customer-receipts`). Runbook:
  `docs/runbooks/FINANCE_CUSTOMER_RECEIPT_AR_ROLLOUT.md`.

F2 database kemudian dikonfirmasi seluruhnya PASS. F3 sekarang masuk preflight
untuk membedakan pembayaran historis atas invoice yang sudah ada dari dana
advance sebelum invoice tersedia. Advance hanya boleh memakai Customer Balance
yang memang aktif dan tidak pernah otomatis menjadi revenue. Runbook:
`docs/runbooks/FINANCE_HISTORICAL_COLLECTION_ADVANCE_ROLLOUT.md`.

Preflight F3 kemudian dikonfirmasi aman: lima Company tetap mempunyai Customer
Balance `DISABLED`, satu invoice tempo terbuka Rp133.500 menjadi scope smoke,
dan tidak ada Customer Receipt existing. Migration `20260827120000` sekarang
local-ready tanpa auto-enable policy: receipt historis dapat dialokasikan ke
invoice, sedangkan advance murni hanya dapat diposting bila policy sudah
`ACTIVE`, lalu mencatat debit Kas/Bank dan kredit Customer Balance Liability.

F3 postflight selanjutnya dikonfirmasi seluruhnya PASS. Preflight F4A juga
PASS: satu invoice tempo outstanding Rp133.500 siap menjadi fixture tanpa data
dummy. Migration `20260827130000` dan Backoffice reporting kini local-ready
untuk outstanding/aging as-of, Customer Statement, Excel export, serta guard
tanggal bisnis pembayaran tidak lebih awal dari order. Database rollout,
postflight, behavioral test, dan authenticated smoke masih manual; F4B posting
policy/closing regression belum dimulai.

Database yang sempat menjalankan build awal F4A wajib menerapkan forward-fix
`20260827131000` sebelum behavioral test. Fix menyamakan bentuk baris Invoice
dan Receipt pada Customer Statement; tidak mengubah transaksi atau saldo.

Forward-fix, postflight, dan behavioral F4A kemudian dikonfirmasi sukses oleh
user. F4B menjadi fase terakhir: preflight SELECT-only akan menilai mode
CONTROLLED/AUTOMATIC, queue, exception, event/journal coverage, dan rekonsiliasi
AR sebelum runtime policy dibuka.

Preflight F4B kemudian dinilai aman: 31 event/jurnal canonical sudah tertutup,
9 event `HOLD` menjadi backlog controlled queue, satu event `CANCELED` tetap
dikecualikan, dan lima Company masih `CONTROLLED`. Migration `20260827140000`
sekarang local-ready dengan queue `ALL_SUPPORTED`, policy Owner/Admin,
deferred automatic posting, retryable exception, serta UI Backoffice. Migration
tidak memposting backlog; postflight, behavioral test, controlled closure, dan
authenticated smoke masih manual.

Behavioral F4B dan migration policy kemudian berhasil, tetapi controlled live
queue KGS memposting 8 dari 9 event. Satu Sale TEMPO Rp133.500 gagal karena
runtime G6 lama menyamakan seluruh grand total dengan Payment aktual dan belum
membuat leg `CUSTOMER_RECEIVABLE` untuk unpaid/partial TEMPO. Forward-fix
`20260827141000` sekarang local-ready: ia memvalidasi Payment + piutang terhadap
grand total + surcharge, membuat debit AR berdimensi Customer, serta membackfill
interval mapping AR historis secara versioned/audited bila diperlukan. Ia
mempertahankan Cash/split/Return dan tidak mengubah event saat instalasi. Preflight, migration,
postflight, behavioral rollback, lalu controlled retry satu event masih manual;
mode `AUTOMATIC` tetap dilarang sebelum seluruhnya bersih.

User kemudian mengonfirmasi final controlled retry dan kedua postflight PASS:
40 event POSTED mempunyai 40 jurnal POSTED, satu Sale TEMPO mempunyai debit AR,
supported HOLD dan open exception nol, serta balance/duplicate/coverage bersih.
Database closure F4B dinyatakan PASS; yang tersisa hanya authenticated smoke
Cash/TEMPO/Receipt/report dan uji Automatic terbatas pada Company dummy.

## Update 2026-08-27 — Policy Surat Jalan Otomatis Local Ready

- Company dapat memilih di **Platform → Profil Perusahaan** apakah Surat Jalan
  hanya dibuat untuk transaksi `DELIVERY` atau untuk seluruh Sale baru yang
  `POSTED`. Default tetap `DELIVERY_ONLY`; histori tidak dibackfill.
- Surat Jalan Pickup menyimpan intent immutable dan memakai alur **Siap
  diserahkan → Sudah diserahkan**. Delivery tetap **Siap dikirim → Dalam
  perjalanan → Terkirim**.
- Migration additive `20260827153000` menjaga overload RPC lama, optimistic
  version, tenant/role guard, exact one-document-per-Sale, serta no-double-effect
  terhadap Stock, Payment, Financial Event, dan Journal.
- Backoffice lint dan production build PASS (76 route). SQL rollout dan smoke
  authenticated masih manual sesuai
  `docs/runbooks/COMPANY_AUTOMATIC_DELIVERY_DOCUMENT_POLICY_ROLLOUT.md`.
- User kemudian mengonfirmasi rangkaian SQL policy aman. POS kini membaca policy
  Company melalui RPC branding: transaksi baru otomatis mencentang **Perlu
  dikirim** saat mode `ALL_POSTED_SALES`, sementara draft existing tetap memakai
  intent tersimpan. Nilai opsional Customer yang tidak tersedia dibiarkan
  kosong. PWA lint dan production build PASS; smoke browser tetap manual.

## Update 2026-08-28 — ODR-4C Stock Request Projection Local Ready

- ODR-4B telah dikonfirmasi user seluruhnya `PASS`: demand mengikuti
  konfirmasi/pembatalan Order dan dibekukan saat sesi ditutup tanpa memutasi
  Stock Request, PO, Stock, atau Finance.
- ODR-4C local-ready memproyeksikan shortage reservasi sesi yang sudah ditutup
  menjadi satu Stock Request `SUBMITTED`, digabung per Product pada base UOM.
- Stock Request manual dan sumber legacy stok minus dipertahankan. Request baru
  memakai source `SALES_ORDER_RESERVATION`, tidak dapat dibatalkan manual, dan
  mempunyai lineage ke demand/reservation asal.
- Migration, postflight, behavioral test, serta manual smoke masih harus
  dijalankan user sesuai
  `docs/runbooks/ODR4C_SESSION_STOCK_REQUEST_PROJECTION.md`. Sinkronisasi Draft
  PO dan amendment PO final belum dibuka pada fase ini.

User kemudian mengonfirmasi migration, behavioral test, dan closing postflight
ODR-4C seluruhnya PASS. Runtime inventory masih nol karena belum ada sesi ODR
ber-shortage yang ditutup. ODR-4D dimulai sebagai preflight SELECT-only untuk
memisahkan quantity Draft PO yang sepenuhnya allocation-backed dari quantity
manual/campuran serta PO final. Belum ada runtime atau PO mutation baru.

Preflight ODR-4D kemudian dikonfirmasi tanpa blocker: 18 baris Draft PO legacy
seluruhnya allocation-backed, tetapi belum ada request/allocation ODR sehingga
tidak ada data existing yang perlu dimutasi. Foundation amendment additive
`20260828180000` local-ready dan zero-backfill; runtime Draft-PO sync tetap
menunggu closing test foundation.

User kemudian mengonfirmasi foundation amendment seluruhnya PASS dan tetap
zero-backfill. Runtime rekonsiliasi managed Stock Request `20260828190000`
local-ready: perubahan Order setelah sesi ditutup memperbarui request aktif dan
membentuk notice, tetapi belum mengubah PO. Baris kebutuhan nol dinonaktifkan
untuk menjaga lineage; reader Purchasing memfilter baris inactive.

User kemudian mengonfirmasi rekonsiliasi managed request seluruhnya PASS.
Sinkronisasi satu Draft PO `20260828200000` kini local-ready: hanya delta positif
ke satu target yang sepenuhnya allocation-backed dan valid secara UOM yang dapat
diubah atomik. PO final/ambigu/manual, Stock/FIFO/Movement, dan Finance tetap
tidak dimutasi. SQL rollout serta smoke Company dummy masih manual.

User kemudian mengonfirmasi migration, behavioral test, dan closing postflight
ODR-4E seluruhnya PASS. ODR-4 database gate selesai; dua Draft PO dan 17 PO
final existing tetap aman, tanpa open amendment. ODR-5 dimulai melalui preflight
SELECT-only `odr_phase5_finance_dispatch_payment_preflight.sql`. Audit ini
memetakan operasi Dispatch, payment intent, partial Dispatch, periode, akun,
dan jurnal historis; belum ada schema, event, posting runtime, atau UI Finance
ODR-5 yang diaktifkan.

User kemudian mengonfirmasi preflight ODR-5 tanpa blocker. Seluruh source live
ODR masih nol, queue aktif nol, accounting-period readiness bersih, dan histori
40 jurnal/21 event Sale tidak disentuh. Foundation additive zero-backfill
`20260828210000` kini local-ready: empat relation source/audit tertutup dari
browser, event catalog `SALE_DISPATCHED`/`SALE_PAYMENT_VERIFIED`, serta fungsi
akun `CUSTOMER_ADVANCE_LIABILITY`. Foundation belum membuat event, jurnal,
mapping COA, posting runtime, atau UI; rollout SQL masih manual mengikuti
`docs/runbooks/ODR5A_FINANCE_SOURCE_FOUNDATION.md`.

User mengonfirmasi closing postflight ODR-5A seluruhnya PASS: empat relation
RLS/browser-closed, empat trigger, dua event catalog, account function uang
muka, migration ledger, dan zero-backfill bersih; 40 jurnal historis tetap
utuh. ODR-5B dilanjutkan hanya sebagai preflight SELECT-only
`odr_phase5b_finance_mapping_runtime_preflight.sql` untuk memetakan akun per
Company, collision kategori, approved rule, dispatcher, dan controlled queue.
Belum ada event, jurnal, mapping, posting runtime, atau automatic posting baru.

Initial ODR-5B output tidak memiliki blocker: lima Company membutuhkan akun
Customer Advance dan kode default `2190` bebas collision. Empat Company tidak
memiliki system-owned COA/fallback untuk COGS, Inventory, Sales Revenue, serta
sebagian ROUNDING_GAIN. Sebelum membuat akun baru, audit reusable-rule
SELECT-only ditambahkan untuk mencari tepat satu account ID valid yang sudah
dipakai ACTIVE transaction rule. Ini mencegah duplikasi akun ekonomi; migration
mapping tetap belum dibuat sampai output audit ditinjau.

Audit reusable pertama terlalu ketat karena mendahulukan jumlah akun berlabel
system function secara global dan menghasilkan 16 ambiguity. Jurnal historis
tetap valid; resolver existing memakai exact event/category rule. Preflight
dikoreksi agar memilih rule `SALE_POSTED`/`SALE_PAYMENT`, lalu fallback, baru
satu system account. Tidak ada database mutation dari koreksi diagnostic ini.

Output reusable terkoreksi kemudian dikonfirmasi aman: seluruh mapping inti dan
conditional `PASS`; satu-satunya scope tersisa adalah provision akun
`2190 - Uang Muka Customer` pada lima Company. Foundation ODR-5B
`20260828220000` kini local-ready untuk membuat akun advance tersebut, dua
Transaction Category ODR, 17 exact mapping dan dua approved versioned Posting
Rule Set per Company. Migration tetap zero-runtime-effect: tidak membuat Event,
Journal, Stock, FIFO, Payment, atau memproses queue. Rollout manual mengikuti
`docs/runbooks/ODR5B_FINANCE_MAPPING_FOUNDATION.md`; automatic posting dan UI
ODR-6 tetap belum dibuka.

User kemudian mengonfirmasi behavioral dan closing postflight ODR-5B seluruhnya
PASS: lima akun Customer Advance, sepuluh category/rule set, 85 exact mapping,
zero Event/Journal effect, dan 40 jurnal historis tetap utuh. Gate aktif pindah
ke preflight SELECT-only ODR-5C
`odr_phase5c_dispatch_finance_runtime_preflight.sql`. Audit ini memeriksa exact
operation Dispatch, Invoice/SJ, allocation/Movement, actual FIFO cost, periode,
mapping dan controlled boundary sebelum source capture/Event runtime dibuat.

User kemudian mengonfirmasi preflight ODR-5C tanpa blocker. Migration
`20260828230000` kini local-ready: pengurangan Reservation/On Hand/FIFO/Movement
dan capture source Finance berada dalam satu transaksi; satu operation key
menghasilkan satu event `SALE_DISPATCHED` `HOLD`. Partial Dispatch memakai
alokasi komersial proporsional dan Dispatch final menutup residual; controlled
queue dapat membuat jurnal balance. Automatic posting, Payment verification
ODR-5D, serta UI ODR-6 tetap belum aktif. Rollout Supabase dan smoke masih
manual menurut `docs/runbooks/ODR5C_DISPATCH_FINANCE_RUNTIME.md`.

Closing postflight ODR-5C kemudian dikonfirmasi seluruhnya PASS dengan runtime
ODR masih nol dan 40 jurnal historis tetap utuh. Gate berikutnya adalah
preflight SELECT-only ODR-5D
`odr_phase5d_payment_verification_runtime_preflight.sql`: audit payment intent,
Payment Method/proof, total Order, exact mapping/rule, Customer Advance sebelum
Dispatch, Clearing/Piutang sesudah Dispatch, serta Cashier-session boundary.
Belum ada perubahan runtime, Event, Journal, automatic posting, atau UI pada
langkah ini.

Preflight ODR-5D kemudian dikonfirmasi tanpa blocker. Runtime payment
verification `20260828240000` kini local-ready beserta behavioral rollback,
postflight SELECT-only, dan runbook. Confirmed Order menangkap payment intent
immutable; Cash dicatat tepat sekali pada drawer; Finance verify/reject memakai
maker-checker; verified payment membuat satu HOLD Event yang diposting lewat
controlled queue. Payment internal-liability, automatic posting, dan aplikasi
pre-dispatch advance saat Dispatch tetap ditutup sampai gate berikutnya.

Closing ODR-5D kemudian dikonfirmasi seluruhnya PASS dengan runtime tetap nol.
ODR-5E `20260828250000` local-ready: Dispatch source yang baru dibuat akan
direbalance tepat sekali menggunakan surcharge immutable dan verified
pre-dispatch Customer Advance; residual tetap masuk Clearing/Piutang. Stock,
FIFO, Event, effect, dan audit berada dalam transaksi yang sama. Automatic
posting masih ditutup sampai ODR-5F closing reconciliation.

Closing ODR-5E kemudian dikonfirmasi seluruhnya PASS; tidak ada source, event,
jurnal, atau queue ODR parsial. ODR-5F `20260828260000` sekarang local-ready
untuk menyamakan hasil controlled/automatic dispatcher dan menormalkan event
tanpa efek. Seluruh Company existing tetap `CONTROLLED`; migration ini hanya
membuka switch policy yang harus dipilih eksplisit setelah behavioral dan
postflight PASS. UI/E2E ODR-6 belum aktif.

Closing ODR-5F kemudian dikonfirmasi seluruhnya PASS: Finance migration chain,
dispatcher parity, source/event/jurnal, exception, dan Advance ordering bersih;
semua lima Company tetap `CONTROLLED`. ODR-6 dimulai dengan preflight
SELECT-only untuk memeriksa canonical browser RPC dan memetakan cutover POS,
Inventory, Purchasing, Finance, serta Offline boundary sebelum frontend diubah.

Preflight ODR-6 telah dikonfirmasi tanpa blocker. ODR-6A POS Order cutover kini
local-ready: checkout online memakai Confirm Order canonical, daftar Order
aktif/terjadwal terpisah dari Draft, checkout Offline baru fail-closed, dan
cancel Order dilindungi migration `20260828270000` ketika Payment masih
`PENDING`/`VERIFIED`. Rollout Supabase dan authenticated PWA smoke masih manual;
Inventory/Purchasing/Finance UI belum dicutover pada tahap ini.

Authenticated smoke pertama menemukan snapshot Invoice/SJ Order terkonfirmasi
masih membawa nomor sementara `DRAFT-*`. Root cause adalah jalur ODR Confirm
melewati final-post legacy yang dahulu mengalokasikan nomor `INV-*`.
Forward-fix `20260828280000` sekarang local-ready: Reservation tetap dibuat
lebih dahulu, nomor Invoice final dialokasikan tepat sekali sebelum snapshot,
dan hanya snapshot `ORDER_CONFIRM` yang terdampak diperbaiki dengan audit.
Stock, FIFO, Payment, Event, Journal, dan status operasional Order tidak diubah.

Stock Real sebelumnya masih menampilkan placeholder `Reserved: Belum aktif`
meskipun Reservation backend sudah terbentuk. ODR-6B.1 Step 1 sekarang
local-ready melalui migration `20260829090000`: RPC Stock Real menghitung
Reserved Out dari Reservation `OPEN/PARTIALLY_DISPATCHED` dan Available sebagai
On Hand dikurangi Reserved. Backoffice menampilkan nilai tersebut secara nyata.
PWA juga tidak lagi memakai `product_stocks.stock_qty` sebagai ketersediaan;
RPC sesi-kasir menghitung Available dari seluruh Reservation aktif pada Gudang
yang sama melalui forward-fix `20260829100000`. Forward-fix dipisahkan karena
ledger `20260829090000` sudah pernah diterapkan tanpa RPC POS. Tahap ini belum
live sampai forward-fix, deploy kedua client, dan authenticated smoke selesai;
tidak ada mutation Stock/FIFO/Movement/Finance.

Pembatalan Sales Order lintas POS dan Backoffice sekarang **LOCAL READY** lewat
forward migration `20260830110000`. Kedua channel memakai composition canonical
yang melepaskan Reservation, membatalkan Surat Jalan linked, dan menyegarkan
demand Purchasing. Payment intent `PENDING` ikut dibatalkan; Cash pada sesi
terbuka mendapat reversal drawer idempotent. Payment `VERIFIED`, Cash dari sesi
tertutup, dan Order yang sudah Dispatch tetap fail-closed. Invoice snapshot
tidak dihapus: list/detail/export menampilkan status `Dibatalkan`, sedangkan
print/PDF memakai watermark. Rollout Supabase, deploy client, dan authenticated
smoke masih manual menurut
  `docs/runbooks/SALES_ORDER_CANCELLATION_INVOICE_SYNC.md`.

# Negative-stock FIFO cost settlement (2026-08-31)

Kontrak koreksi biaya stok minus dan Supplier Invoice sudah dikunci; diagnostic
NSC-0 live telah ditinjau tanpa blocker dan tanpa variance historis nonnol.
NSC-1..3 menyediakan foundation cost source, Goods Receipt provisional-cost
settlement (termasuk receipt nilai nol), Supplier Invoice FIFO revaluation,
serta split Inventory/COGS bersama behavioral rollback dan postflight. Lihat
[`docs/runbooks/NEGATIVE_STOCK_FIFO_FINANCE_COST_SETTLEMENT.md`](docs/runbooks/NEGATIVE_STOCK_FIFO_FINANCE_COST_SETTLEMENT.md).

Rollout manual NSC-1..3 kemudian dikonfirmasi user: foundation dan runtime
postflight seluruhnya `PASS`, termasuk private boundary dan zero-value negative
receipt contract. Runtime live masih memiliki 49 negative allocation terbuka,
sedangkan cost source/batch plan baru masih nol. Status saat ini **runtime
installed / authenticated operational smoke pending**; belum boleh dianggap
closure FIFO–GL sampai ada Dispatch minus → Goods Receipt → Supplier Invoice
variance yang benar-benar diproses melalui controlled queue.
