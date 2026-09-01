# Matriks UAT, Edge Case, dan Risk Register MADS

Versi: 1 September 2026  
Pemilik pengujian: Product Owner/UAT Lead  
Sasaran: user operasional, administrator, gudang, purchasing, Finance, dan
Accounting.

Dokumen ini adalah checklist pengujian manusia. Ia tidak menggantikan migration
postflight, behavioral SQL, lint, build, atau rekonsiliasi database.

## Daftar Isi

1. [Cara membaca status](#1-cara-membaca-status)
2. [Rekap status sistem](#2-rekap-status-sistem)
3. [Persiapan UAT](#3-persiapan-uat)
4. [Smoke test wajib P0](#4-smoke-test-wajib-p0)
5. [Matriks UAT per area](#5-matriks-uat-per-area)
6. [Edge case yang wajib dicoba](#6-edge-case-yang-wajib-dicoba)
7. [Risk register](#7-risk-register)
8. [Format bukti dan laporan defect](#8-format-bukti-dan-laporan-defect)
9. [Kriteria go/no-go](#9-kriteria-gono-go)

## 1. Cara membaca status

| Status | Arti |
|---|---|
| PASS | Skenario dijalankan pada environment target dan hasil sesuai. |
| FAIL | Hasil berbeda, terjadi salah data, atau operasi yang harus ditolak justru lolos. |
| BLOCKED | Test tidak dapat dimulai karena data, role, migration, atau konfigurasi belum siap. |
| NOT RUN | Belum pernah diuji pada environment target. |
| EXPECTED DENIAL | Penolakan memang bagian dari kontrak keamanan/bisnis. |

`PASS` pada postflight SQL membuktikan struktur dan invariant yang diperiksa,
tetapi tidak otomatis membuktikan alur browser end-to-end. `INFO`, `SETUP`, dan
`REVIEW` bukan PASS operasional. Skenario yang menghasilkan nol source row juga
belum membuktikan transaksi nyata.

## 2. Rekap status sistem

### 2.1 Yang sudah mempunyai bukti database

- tenant, RLS, permission enforcement, Stock/Movement/FIFO, Finance posting,
  ODR Reservation/Dispatch, procurement demand, payment verification, dan
  compatibility Return/AR memiliki rangkaian migration/postflight yang telah
  dilaporkan PASS pada tahapan masing-masing;
- Stock Real mempunyai read model `On Hand`, `Reserved Out`, dan `Available to
  Sell`;
- konfirmasi Order, Invoice/SJ final identity, Dispatch stock, demand sesi,
  controlled Finance event, serta payment verification mempunyai runtime
  canonical;
- foundation dan runtime Negative Stock Cost (NSC-1..3) terpasang dan
  postflight terakhir PASS: 10 routine, 5 trigger, private boundary, serta
  structural reconciliation;
- Finance historical closure sebelumnya melaporkan seluruh event HOLD lama
  selesai dan jurnal balance.

### 2.2 Yang belum boleh dianggap terbukti penuh

- authenticated E2E matrix lintas POS, Inventory, Purchasing, Finance, Return,
  AR, two-Company, role denial, exact retry, dan hard refresh belum mempunyai
  satu bukti closure terpadu;
- NSC end-to-end nyata masih ditunda. Snapshot terakhir mempunyai 49 negative
  allocation terbuka, shortage 1.279 base quantity, dan belum mempunyai cost
  source/batch plan baru. Runtime terpasang, tetapi belum terbukti oleh siklus
  Dispatch minus sampai Supplier Invoice dan jurnal;
- checkout Offline baru untuk Order ODR masih fail-closed. Yang dipertahankan
  adalah pemulihan/status antrean historis, bukan izin membuat Order final baru;
- semua Company yang terakhir diaudit memakai policy Finance `CONTROLLED`.
  Mode `AUTOMATIC` tidak boleh diasumsikan aktif atau aman tanpa UAT Company
  dummy;
- deployment browser dapat tertinggal dari database karena Vercel deployment,
  cache PWA, service worker, atau tab lama. Version parity wajib diuji;
- data produksi/master yang berubah setelah postflight dapat membuat mapping,
  role, periode, UOM, atau account function kembali tidak siap.

### 2.3 Ringkasan per domain

| Domain | Status dokumentasi saat ini | Gate user yang masih diperlukan |
|---|---|---|
| Login, role, multi-company, ACP | Enforcement database tersedia; satu role utama berlaku per user per Company. | Role denial, cabut akses saat sesi aktif, user tanpa Company, dan dua Company. |
| Master Product/UOM/Customer/Supplier | CRUD dan import/export terjaga tersedia; master bersejarah tidak boleh hard delete. | Template nyata, duplicate identity/barcode, partial import, dan nonterminal-job cleanup. |
| Pricelist dan terminal price override | Resolver server, tier, Customer default, dan opt-in override tersedia. | Parity kartu/cart/Draft/final serta terminal ON/OFF. |
| POS Draft dan Sales Order | Draft side-effect-free; Confirm Order membuat Reservation dan dokumen final. | Exact retry, stale version, scheduled Order, cancel, dan hard refresh. |
| Inventory Reservation/Dispatch | Read model Reserved/Available dan partial/full Dispatch canonical tersedia. | Dispatch/Received nyata, shared Warehouse, legacy Delivery, dan stock reconciliation. |
| Purchasing/demand/PO/receipt | Demand sesi, managed request, Draft-PO sync/amendment, serta Goods Receipt canonical tersedia. | Deployment read model detail receipt, partial/multiple receipt, dan final-PO immutability. |
| Payment dan Finance | Payment verification asynchronous dan controlled posting tersedia; Kasir tidak menunggu Finance untuk close. | Maker-checker, reject/reversal, pre/post-Dispatch settlement, queue failure isolation. |
| TEMPO, AR, collection, Return | Consumer database sudah ODR-aware dan closure SQL dilaporkan PASS. | Partial Dispatch AR/Receipt, payment-before-order guard, Return cumulative, dan legacy compatibility. |
| Invoice/Surat Jalan | Immutable snapshot, final identity, cancel watermark, template policy, PDF/print tersedia. | Detail endpoint, bulk PDF, snapshot policy, popup/download, dan cancel visibility. |
| Negative Stock Cost | NSC runtime terpasang dan structural postflight PASS. | Seluruh NSC-01 s.d. NSC-08; saat ini belum mempunyai source nyata baru. |
| Offline | Recovery/status antrean historis dipertahankan. | Checkout Order baru tetap ditolak sampai reservation replay parity resmi dibuka. |
| Laporan dan rekonsiliasi | Jurnal/report canonical tersedia; historical closure pernah PASS. | Filter/tanggal/timezone, period lock, pending-vs-posted, serta FIFO/AP/AR versus GL setelah transaksi UAT. |

## 3. Persiapan UAT

### 3.1 Gunakan Company uji

Jangan menjalankan skenario destruktif pertama pada Company operasional. Siapkan:

- satu Company dummy dengan mode Finance `CONTROLLED`;
- satu Store, satu Terminal, satu Warehouse penjualan, dan satu Warehouse rusak;
- akun Owner/Admin, Warehouse Admin, Purchasing/Store Manager, Finance,
  Accounting, dan Cashier;
- satu user multi-company dengan role berbeda;
- dua Product STOCK dengan UOM dasar dan UOM jual;
- satu Product dengan stok positif dan satu Product dengan izin stok minus;
- satu Customer reguler, satu Customer TEMPO, dan Pelanggan Umum;
- satu Supplier, satu metode Cash, dan satu metode Transfer/Bank;
- periode akuntansi terbuka;
- COA/account mapping aktif untuk Sales, Inventory, COGS, AR, AP, Clearing,
  Customer Advance, PPV, Tax bila digunakan, dan Rounding bila digunakan.

### 3.2 Aturan pencatatan bukti

Untuk setiap test, simpan:

- ID test dan waktu;
- URL/deployment yang dipakai;
- Company, Store, Terminal, Warehouse, user, dan role;
- nomor Draft/Order/Invoice/SJ/PO/Receipt/Event/Journal;
- screenshot sebelum dan sesudah;
- nilai On Hand, Reserved, Available, FIFO, AR/AP, dan GL yang relevan;
- hasil retry atau denial;
- status PASS/FAIL/BLOCKED dan catatan.

### 3.3 Stop condition

Hentikan pengujian pada Company tersebut bila terjadi salah satu kondisi:

- data Company lain terlihat atau dapat dipilih sebagai referensi transaksi;
- On Hand berubah saat hanya menyimpan Draft atau Confirm Order;
- Dispatch, Goods Receipt, Return, atau payment retry membuat efek ganda;
- jurnal tidak balance atau satu event mempunyai lebih dari satu jurnal aktif;
- Invoice/SJ memakai nomor `DRAFT-*`;
- Reserved Out tidak dilepas setelah pembatalan aman;
- quantity Return melebihi quantity yang sudah Dispatch;
- FIFO, Inventory GL, COGS, AR, atau AP tidak dapat direkonsiliasi;
- aplikasi menyarankan direct table write sebagai jalan keluar.

## 4. Smoke test wajib P0

Seluruh P0 harus PASS sebelum data operasional baru dimasukkan.

| ID | Skenario | Pelaksana | Hasil yang diharapkan |
|---|---|---|---|
| P0-01 | Login dan pilih Company | User multi-company | Nama Company, menu, role, Store, dan referensi berubah sesuai Company aktif; tidak ada data silang. |
| P0-02 | Buka sesi POS | Cashier | Hanya Terminal/Store/Warehouse yang ditugaskan; satu sesi aktif. |
| P0-03 | Simpan Draft | Cashier | Draft tersimpan; On Hand, Reserved, Movement, FIFO, payment final, dan jurnal tidak berubah. |
| P0-04 | Konfirmasi Order stok cukup | Cashier | Nomor Invoice final bukan `DRAFT-*`; Reserved bertambah; Available turun; On Hand/FIFO/Movement belum berubah. |
| P0-05 | Dispatch parsial | Warehouse Admin | On Hand/FIFO/Movement turun sesuai quantity parsial; Reserved tinggal sisa; SJ berstatus parsial. |
| P0-06 | Dispatch final dan Received | Warehouse Admin | Reserved nol/selesai; Dispatch final memberi efek sisa tepat sekali; Received tidak mengurangi stok kedua kali. |
| P0-07 | Payment review dan queue | Finance berbeda dari maker | Verify membuat event sesuai policy; controlled queue menghasilkan satu jurnal balance; retry tidak menggandakan. |
| P0-08 | Cancel sebelum Dispatch | Cashier/Backoffice | Reservation dilepas, SJ dibatalkan, demand diperbarui, Invoice tetap ada dengan status/watermark Dibatalkan. |
| P0-09 | Cancel setelah Dispatch | Cashier/Admin | Ditolak; user diarahkan ke Return/refund/reversal, bukan hard delete. |
| P0-10 | Tutup sesi dengan payment pending | Cashier | Sesi dapat ditutup tanpa Finance standby; cash drawer/actual/difference dan payment review tetap tersimpan. |
| P0-11 | Supplier Order dan Goods Receipt | Purchasing/Warehouse | Ordered/received/remaining benar; Draft receipt tanpa efek; Post menambah Stock/FIFO/AP/event tepat sekali. |
| P0-12 | Return penjualan | Cashier/Manager | Hanya quantity Dispatch yang dapat diretur; cumulative guard dan FIFO restoration benar. |
| P0-13 | Laporan Finance | Accounting | Jurnal balance; FIFO=Inventory GL, AP=AP GL, AR=AR GL; tidak ada exception tak dijelaskan. |
| P0-14 | Hard refresh dan exact retry | Semua channel | State tetap sama dan tidak ada duplikasi dokumen, reservation, Movement, payment, event, atau jurnal. |

## 5. Matriks UAT per area

### 5.1 Akses, multi-company, dan deployment

| ID | Langkah | Hasil yang diharapkan |
|---|---|---|
| ACC-01 | Login user tanpa membership Company | Halaman menjelaskan user tidak mempunyai akses Company; detail akun tetap dapat dikelola Super Admin. |
| ACC-02 | Tambahkan user yang sama ke dua Company dengan role berbeda | Role dan Store tersimpan per Company; perubahan panel Company B tidak mengubah Company A. |
| ACC-03 | Cabut satu membership saat user masih login | Tab lama ditolak setelah refresh/aksi berikutnya; Company lain tetap dapat diakses. |
| ACC-04 | Coba URL langsung submodul tanpa izin | Server menolak; bukan hanya menu yang disembunyikan. |
| ACC-05 | Ubah Company pada Backoffice dan POS | Context berubah eksplisit; sesi POS terbuka harus ditutup sebelum pindah Store/Company. |
| ACC-06 | Buka deployment dari perangkat lama | Versi terbaru tampil setelah hard refresh; bila tidak, bersihkan service worker/cache secara terkontrol dan login ulang. |

### 5.2 Master data dan import/export

| ID | Langkah | Hasil yang diharapkan |
|---|---|---|
| MST-01 | Buat Product dengan base UOM dan UOM jual | Faktor base tepat satu; harga/UOM/berat tersimpan sesuai aturan. |
| MST-02 | Tambah UOM turunan lewat template contextual | Baris REFERENCE tidak diimport; hanya INPUT valid ditambah; Product existing tidak diduplikasi. |
| MST-03 | Upload satu baris SKU tidak ditemukan bersama baris valid | Baris tidak ditemukan dilewati/ditandai sesuai kontrak dataset; baris valid tetap diproses bila dataset mendukung partial result. |
| MST-04 | Hapus UOM/Product yang sudah dipakai | Hard delete ditolak; user dapat menonaktifkan bila diizinkan. |
| MST-05 | Impor dengan job tidak tervalidasi lalu tinggalkan | Job dapat dibatalkan atau auto-cancel sesuai timeout; tidak memblokir import berikutnya. |
| MST-06 | Ekspor dan impor Customer | Kode/nama Company-scoped; Customer existing diperbarui hanya sesuai aturan; transaksi historis tidak berubah. |
| MST-07 | Uji barcode duplikat antar Product-UOM | Validasi menolak sebelum commit. |

### 5.3 Pricelist dan harga POS

| ID | Langkah | Hasil yang diharapkan |
|---|---|---|
| PRC-01 | Pilih Customer dengan Pricelist default | Kartu Product, cart, Draft, resume, dan Confirm menampilkan harga server yang sama. |
| PRC-02 | Buat tier minimum quantity | Harga berubah tepat saat threshold tercapai dan kembali bila quantity turun. |
| PRC-03 | Aktifkan terminal price override lalu edit satu baris | Hanya baris tersebut memakai override; snapshot menyimpan harga awal/akhir dan indikator. |
| PRC-04 | Terminal override OFF atau mode Offline | Edit harga tidak tersedia/ditolak server. |
| PRC-05 | Ubah Pricelist setelah Draft dibuat | Resume menjalankan preview/repricing sesuai kontrak dan meminta konfirmasi bila harga berubah. |

### 5.4 POS Order, reservasi, dan dokumen

| ID | Langkah | Hasil yang diharapkan |
|---|---|---|
| ORD-01 | Confirm Order non-TEMPO stok positif | Reservation OPEN, Invoice/SJ snapshot final, zero On Hand/FIFO/Movement/Journal effect. |
| ORD-02 | Confirm ulang dengan operation key sama | Mengembalikan Order yang sama tanpa efek ganda. |
| ORD-03 | Gunakan master version lama | Ditolak sebagai konflik; muat ulang lalu ulangi. |
| ORD-04 | Scheduled Order masa depan | Tersimpan terjadwal; tidak memberi final effect; tampil aktif pada tanggal bisnis yang tepat. |
| ORD-05 | Tanggal kirim lebih awal dari tanggal Order | Ditolak. |
| ORD-06 | Delivery hanya dengan nama penerima | Dapat Confirm; kontak/alamat kosong dicetak kosong, tidak memutasi Customer. |
| ORD-07 | Batalkan pending non-Cash sebelum Dispatch | Payment intent pending dibatalkan, Reservation/SJ/demand dilepas tepat sekali. |
| ORD-08 | Batalkan Cash dari sesi sumber CLOSED dengan sesi aktif Store sama | Reversal masuk tepat sekali ke sesi aktif; sesi lama tetap immutable. |
| ORD-09 | Batalkan Cash tanpa sesi aktif Store sama | EXPECTED DENIAL; buka sesi sah atau gunakan workflow koreksi resmi. |

### 5.5 Inventory Dispatch

| ID | Langkah | Hasil yang diharapkan |
|---|---|---|
| DSP-01 | Dispatch satu dari tiga unit | Allocation/Movement/FIFO satu unit; Reservation sisa dua. |
| DSP-02 | Dispatch sisa dua | Reservation selesai; residual komersial ditutup pada Dispatch final. |
| DSP-03 | Klik Dispatch dua kali dengan key sama | Hasil sama; tidak ada Movement/FIFO/event ganda. |
| DSP-04 | Dispatch melebihi sisa reservasi | Ditolak. |
| DSP-05 | Konfirmasi Received dua kali | Exact retry; tidak ada stock effect kedua. |
| DSP-06 | Buka Delivery legacy | Tetap bisa dilihat; tidak dipaksa memakai effect ODR baru. |

### 5.6 Stok minus dan biaya FIFO

Skenario ini adalah closure NSC yang **belum mempunyai bukti E2E terakhir**.
Jalankan pada Company dummy dengan Finance `CONTROLLED`.

| ID | Langkah | Hasil yang diharapkan |
|---|---|---|
| NSC-01 | Dispatch melebihi FIFO positif dengan izin sah | Negative allocation terbentuk dengan provisional COGS; quantity dan actor/source dapat ditelusuri. |
| NSC-02 | Goods Receipt parsial dengan harga estimasi | Batch menutup shortage tertua sebagian; cost source dibuat; sisa shortage benar. |
| NSC-03 | Goods Receipt final | Shortage tertutup; Inventory/COGS correction source tepat; available FIFO sisanya benar. |
| NSC-04 | Goods Receipt harga nol untuk shortage | Tidak berhenti sebagai no-effect bila koreksi provisional dibutuhkan; event biaya tetap dapat diproses. |
| NSC-05 | Validasi Supplier Invoice harga berbeda | Remaining batch direvaluasi ke Inventory; quantity terjual/shortage settlement masuk COGS/PPV sesuai mapping. |
| NSC-06 | Process controlled queue | Satu source-satu event-satu jurnal; jurnal balance; Inventory GL sama dengan FIFO bersih. |
| NSC-07 | Retry Receipt, Invoice, dan queue | Tidak ada cost source, batch plan, revaluation, atau jurnal ganda. |
| NSC-08 | Periode terkunci/mapping hilang | EXPECTED DENIAL/failure terisolasi; source tetap retryable dan tidak ada partial revaluation. |

### 5.7 Purchasing dan penerimaan

| ID | Langkah | Hasil yang diharapkan |
|---|---|---|
| PUR-01 | Tutup sesi yang mempunyai shortage Reservation | Satu managed Stock Request per identitas sesi/Store/Warehouse; quantity sesuai shortage terbuka. |
| PUR-02 | Tambah/kurangi Order sebelum PO final | Demand/request direkonsiliasi; hanya satu Draft PO fully managed yang dapat auto-sync. |
| PUR-03 | Ubah kebutuhan setelah PO Confirmed | PO final tidak berubah; amendment/notifikasi dibuat. |
| PUR-04 | Partial Goods Receipt | PO menjadi partially received; detail menunjukkan ordered/received/remaining benar. |
| PUR-05 | Dua receipt untuk PO sama | Total received adalah jumlah POSTED receipt; Draft tidak ikut dihitung. |
| PUR-06 | Barang baik/rusak/ditolak | Hanya quantity eligible menambah gudang yang benar; AP dan status sumber konsisten. |

### 5.8 Payment, sesi kasir, dan Finance queue

| ID | Langkah | Hasil yang diharapkan |
|---|---|---|
| PAY-01 | Satu metode tanpa mengedit nominal leg | Sistem mengisi total final; tidak muncul zero-leg race. |
| PAY-02 | Split payment dengan satu leg nol | Ditolak dengan pesan jelas. |
| PAY-03 | Cash Order lalu tutup sesi sebelum Finance verify | Tutup sesi berhasil; expected/actual/difference benar; request tetap pending untuk Finance. |
| PAY-04 | Maker mencoba verify request sendiri | Ditolak maker-checker. |
| PAY-05 | Reject Cash payment | Drawer reversal tepat sekali sesuai kontrak; retry tidak menggandakan. |
| PAY-06 | Verify sebelum Dispatch | Menjadi Customer Advance, bukan revenue/AR settlement. |
| PAY-07 | Verify setelah Dispatch non-TEMPO | Menyelesaikan Clearing sesuai source; tidak membuat revenue/COGS kedua. |
| PAY-08 | Verify TEMPO setelah Dispatch | Menyelesaikan Customer Receivable sesuai allocation Dispatch. |
| PAY-09 | Queue satu event gagal | Event lain tetap dapat selesai; exception mencatat penyebab dan retry tidak membuat jurnal ganda. |

### 5.9 TEMPO, AR, receipt, dan return

| ID | Langkah | Hasil yang diharapkan |
|---|---|---|
| AR-01 | TEMPO sebelum Dispatch | Belum muncul sebagai receivable yang dapat dialokasikan; payment awal adalah advance. |
| AR-02 | Partial Dispatch TEMPO | Aging, statement, dan Customer Receipt hanya menampilkan bagian yang sudah Dispatch. |
| AR-03 | Receipt lebih kecil dari outstanding | Outstanding berkurang sebesar allocation, tidak negatif. |
| AR-04 | Payment business date sebelum order date | Ditolak, kecuali tanggal bisnis sama dan hanya jam yang berbeda. |
| AR-05 | Return setelah partial Dispatch | Quantity Return maksimum sesuai Dispatch kumulatif dikurangi Return sebelumnya. |
| AR-06 | Return full setelah ongkir | Keputusan refund ongkir eksplisit; tidak diduplikasi pada retry. |
| AR-07 | Sale legacy POSTED | Return dan collection legacy tetap dapat berjalan tanpa memakai Reservation baru. |

### 5.10 Dokumen dan template

| ID | Langkah | Hasil yang diharapkan |
|---|---|---|
| DOC-01 | Buka Detail Invoice | Response JSON valid; tidak ada `Unexpected token '<'`. |
| DOC-02 | Unduh/print Invoice | Nomor final, Customer, tanggal policy, harga, rekening, logo/stempel sesuai snapshot. |
| DOC-03 | Unduh/print SJ | Quantity Dispatch/Order sesuai template; tanda tangan sesuai policy Gudang/Toko. |
| DOC-04 | Bulk download SJ | ZIP berisi PDF terpisah; maksimal dan kegagalan parsial dilaporkan. |
| DOC-05 | Cancel Order | Invoice tetap dapat dicari dan tampil watermark Dibatalkan; bukan hilang. |

### 5.11 Accounting Period dan laporan

| ID | Langkah | Hasil yang diharapkan |
|---|---|---|
| FIN-01 | Posting pada periode OPEN | Berhasil sesuai policy. |
| FIN-02 | Posting pada periode LOCKED/CLOSED | Ditolak tanpa partial journal. |
| FIN-03 | Policy periode AUTOMATIC pada Company dummy | Bulan yang diizinkan dibuat otomatis; periode terkunci tidak dibuka diam-diam. |
| FIN-04 | Process queue controlled | Preview, approval, process, event, dan jurnal mempunyai lineage yang sama. |
| FIN-05 | Trial Balance/GL/P&L/Balance Sheet | Debit=credit; filter Company/periode konsisten; event HOLD tidak masuk laporan POSTED. |
| FIN-06 | Reconciliation Summary | FIFO=Inventory GL, AP=AP GL, AR=AR GL, Customer Balance=liability GL. |

## 6. Edge case yang wajib dicoba

| Edge case | Perilaku yang benar |
|---|---|
| User mempunyai Company A dan B dengan role berbeda | Role, Store, permission, dan data dihitung ulang per Company. |
| Semua membership user dicabut | Login tidak memberi akses operasi; admin tetap dapat membuka detail user dan assign ulang. |
| Dua tab mengedit Draft sama | Lock/optimistic version mencegah lost update; takeover tidak otomatis. |
| Browser sleep lebih dari masa lock | Draft milik sesi yang sama dapat renew; lock user/sesi lain tetap ditolak. |
| Double-click Confirm/Dispatch/Post | Idempotent; satu efek final. |
| Harga Pricelist berubah saat cart terbuka | Preview final server menang; user melihat perubahan sebelum Confirm. |
| Quantity tepat melewati tier | Harga tier berlaku hanya saat threshold terpenuhi. |
| Scroll pada input angka | Nilai tidak berubah karena wheel/gesture. |
| UOM inactive setelah dipakai histori | Snapshot lama tetap terbaca; transaksi baru tidak boleh memilih UOM inactive. |
| Stok nol dan negative policy OFF | Confirm/Dispatch ditolak sesuai tahap, tanpa efek parsial. |
| Stok minus lalu receipt lebih kecil dari shortage | Menutup shortage tertua sebagian; tidak menciptakan FIFO tersedia palsu. |
| Receipt lebih besar dari shortage | Shortage ditutup; sisa menjadi FIFO positif batch tersebut. |
| Harga Supplier Invoice di atas/di bawah estimasi | Split Inventory/COGS/PPV memakai tanda yang benar dan jurnal balance. |
| Order dibatalkan setelah Invoice tercetak | Invoice tidak dihapus; status dan watermark berubah. |
| Cash session sumber sudah CLOSED | Cancel hanya boleh memakai sesi aktif actor di Store sama; selain itu denial. |
| Payment VERIFIED atau Dispatch sudah dimulai | Cancel biasa ditolak; gunakan Return/refund/reversal. |
| Delivery nama penerima saja | Confirm boleh; kontak kosong tidak memblokir. |
| Partial Dispatch lalu Return | Return dibatasi bagian yang sudah Dispatch. |
| Payment sebelum partial Dispatch | Advance dialokasikan proporsional saat Dispatch; tidak menjadi revenue kedua. |
| Accounting period belum ada | Policy MANUAL menolak; policy AUTOMATIC hanya membuat periode yang diizinkan. |
| Vercel baru deploy tetapi user melihat versi lama | Hard refresh/service-worker update; jangan mengulang transaksi sebelum versi dipastikan. |
| Network putus setelah user menekan aksi | Jalankan status check/reload; retry dengan operation key sama, jangan membuat dokumen baru. |
| Company mempunyai Gudang bersama beberapa Store | POS availability mengurangi seluruh Reservation aktif pada Gudang, bukan hanya Store browser. |
| PO final berubah kebutuhannya | PO tidak dimutasi; amendment/notifikasi. |
| Goods Receipt Draft | Tidak menambah received total, Stock, FIFO, AP, atau event final. |

## 7. Risk register

### 7.1 Risiko kritis dan tinggi

| ID | Level | Risiko tersisa | Bukti/status saat ini | Mitigasi dan gate penutup |
|---|---|---|---|---|
| R-01 | KRITIS | NSC stok-minus belum terbukti end-to-end sehingga COGS/Inventory GL dapat berbeda setelah replenishment nyata. | Runtime/postflight PASS, tetapi cost source dan batch plan masih nol; 49 allocation terbuka. | Jalankan NSC-01 s.d. NSC-08 pada Company dummy dan cocokkan FIFO/GL sebelum memperluas stok minus. |
| R-02 | KRITIS | Deployment client dan database dapat tidak seversi, menghasilkan RPC missing, placeholder Reserved, HTML 404, atau guard lama. | Pernah terjadi applied-migration drift dan cache client lama. | Catat migration ledger, deployment commit, hard refresh, lalu jalankan P0 pada URL yang dipakai user. |
| R-03 | TINGGI | Full authenticated ODR matrix belum mempunyai satu closure evidence terpadu. | Banyak postflight PASS; matrix UAT masih manual. | Jalankan seluruh P0 dan matriks ORD/DSP/PAY/AR dengan dua Company dan role denial. |
| R-04 | TINGGI | Offline checkout baru belum mempunyai reservation replay parity. | Secara desain fail-closed. | Jangan operasikan checkout Offline baru; uji hanya recovery antrean historis sampai scope resmi dibuka. |
| R-05 | TINGGI | Cancel Order setelah payment verified/Dispatch dapat memerlukan refund/reversal yang belum menjadi satu tombol universal. | Cancel biasa sengaja fail-closed. | SOP: batalkan sebelum Dispatch; setelah final gunakan Return/refund/reversal dan review Finance. |
| R-06 | TINGGI | Mapping COA/periode dapat rusak setelah master diubah walaupun postflight lama PASS. | Resolver bergantung pada mapping aktif dan periode. | Setelah perubahan COA/category/policy, jalankan preflight/reconciliation dan transaksi kecil. |
| R-07 | TINGGI | 49 negative allocation lama dapat memengaruhi replenishment pertama dan menghasilkan jurnal koreksi material. | Inventory terakhir mencatat provisional total Rp25.816.106. | Review per Company/Product sebelum Goods Receipt; proses queue terkontrol; jangan aktifkan automatic. |
| R-08 | TINGGI | Data produksi bisa salah bila user memperbaiki dokumen final langsung di DB. | Banyak FK/audit/final-history invariant. | Larang direct write; gunakan Cancel sebelum Dispatch, Return, Adjustment, Credit/Debit Note, atau reversal. |

### 7.2 Risiko sedang

| ID | Level | Risiko tersisa | Mitigasi |
|---|---|---|---|
| R-09 | SEDANG | UOM/factor/weight salah menyebabkan quantity, harga, COGS, dan PO salah. | Export master, review base UOM/factor/barcode/weight, lalu uji satu SKU sebelum import massal. |
| R-10 | SEDANG | Pricelist card, cart, Draft, dan final dapat berbeda bila cache/repricing tidak dipahami. | Selalu periksa preview final; jalankan PRC-01/05 setelah perubahan Pricelist. |
| R-11 | SEDANG | Payment pending menumpuk karena verifikasi asynchronous. | Tutup sesi tetap boleh, tetapi Finance wajib memiliki SLA review dan dashboard exception. |
| R-12 | SEDANG | Draft PO campuran manual dan managed tidak aman untuk auto-sync. | Sistem hanya mengubah fully managed Draft PO; petugas review amendment/mixed allocation. |
| R-13 | SEDANG | Dokumen historis legacy dan Order ODR mempunyai lifecycle berbeda. | Pertahankan label/provenance; jangan backfill effect ODR ke histori. Uji satu dokumen dari tiap generasi. |
| R-14 | SEDANG | Future/backdated Order dapat salah periode/report bila tanggal order, transaksi, due date, dan Dispatch disamakan. | Gunakan field sesuai arti; uji ORD-04/05 dan FIN-01/02. |
| R-15 | SEDANG | Automatic posting dapat memperbesar dampak mapping salah. | Tetap `CONTROLLED` sampai UAT automatic terisolasi dan rollback rehearsal PASS. |
| R-16 | SEDANG | User multi-company salah memilih tenant sebelum Post. | Header Company wajib terlihat; SOP baca Company/Store/Terminal/Warehouse sebelum aksi final. |
| R-17 | SEDANG | Browser refresh setelah network timeout memicu user membuat ulang transaksi. | Cari Order/status dengan nomor/customer terlebih dahulu; retry operation yang sama. |
| R-18 | SEDANG | Report dapat tampak nol karena filter tanggal/Company/periode, bukan karena transaksi hilang. | Simpan nomor dokumen, cek timezone Company, source event, status HOLD/POSTED, dan filter. |

### 7.3 Risiko rendah tetapi mengganggu operasi

| ID | Level | Risiko tersisa | Mitigasi |
|---|---|---|---|
| R-19 | RENDAH | Tampilan Compact/Katalog berbeda pada ukuran laptop. | Uji pada resolusi kasir sebenarnya dan pastikan cart 10 item dapat diperiksa. |
| R-20 | RENDAH | File PDF/ZIP atau popup print diblok browser. | Izinkan popup/download untuk domain dan uji DOC-01 s.d. DOC-04. |
| R-21 | RENDAH | Logo/stempel/rekening/tanggal dokumen tidak sesuai karena snapshot policy. | Ubah policy sebelum membuat dokumen baru; dokumen lama memang mempertahankan snapshot. |
| R-22 | RENDAH | Error teknis mentah membingungkan user. | Catat code lengkap; UI harus memberi pesan ramah tanpa menyembunyikan correlation/source ID. |

## 8. Format bukti dan laporan defect

Gunakan format berikut:

```text
Test ID:
Status: PASS / FAIL / BLOCKED
Tanggal dan waktu:
Environment/URL:
Commit/deployment:
Company / Store / Terminal / Warehouse:
User / role:
Nomor dokumen terkait:
Langkah:
Hasil yang diharapkan:
Hasil aktual:
Pesan error lengkap:
Nilai sebelum/sesudah:
Screenshot/video:
Apakah retry dilakukan:
Apakah ada dampak Stock/FIFO/Payment/Event/Journal:
```

Jangan menyertakan kata sandi, access token, refresh token, publishable secret,
service-role key, atau data kartu pembayaran.

## 9. Kriteria go/no-go

### GO terbatas

Pilot dapat dimulai secara terbatas bila:

- seluruh P0 PASS pada deployment yang sama dengan user;
- Company/Store/Terminal/role fixture benar;
- periode dan mapping Finance siap;
- tidak ada queue aktif, exception terbuka tanpa owner, atau jurnal imbalance;
- transaksi dummy Confirm -> Dispatch -> Payment -> Journal sudah
  direkonsiliasi;
- bila stok minus akan dipakai, seluruh NSC-01 s.d. NSC-08 PASS;
- SOP cancel, Return, payment review, dan incident tersedia;
- backup dan forward-fix/rollback rehearsal sudah disepakati.

### NO-GO

Jangan mulai atau hentikan pilot bila:

- ada satu P0 FAIL;
- tenant/cross-Company leak;
- Stock/FIFO/Movement/Reservation tidak rekonsiliasi;
- AR/AP/Inventory/COGS tidak cocok dengan GL;
- event/jurnal duplikat atau tidak balance;
- client dan migration target tidak seversi;
- user hanya dapat menyelesaikan masalah melalui direct database mutation;
- stok minus dipakai sementara NSC E2E belum PASS;
- checkout Offline baru dibutuhkan tetapi jalurnya masih fail-closed.
