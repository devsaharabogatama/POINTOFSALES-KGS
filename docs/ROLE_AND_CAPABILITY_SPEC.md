# Role dan Capability KGS POS

## Status dan tujuan

Dokumen ini menjelaskan baseline hak akses yang dibentuk runtime saat ini.
Ini bukan izin untuk memperluas role atau mengubah approval flow. Hak efektif
tetap dihitung server-side untuk User, Company aktif, feature aktif, permission
submodul, dan pembatasan khusus.

## Cara sistem menentukan hak akses

Hak akses bukan hanya nama role. Urutannya:

1. User harus mempunyai membership aktif pada Company yang sedang dibuka.
2. Modul/feature Company harus aktif.
3. Permission submodul menetapkan role yang boleh melihat, mengoperasikan, atau
   menyetujui.
4. Pembatasan khusus User hanya dapat mempersempit baseline role
   non-privileged. Platform Super Admin dan Company Owner selalu mengikuti
   authority penuh masing-masing.
5. Store/Warehouse/document ownership dan status dokumen tetap divalidasi oleh
   operasi terkait.

Menu yang terlihat bukan bukti bahwa aksi mutation diizinkan. Tombol UI membaca
effective capability, sedangkan RPC/API memeriksanya kembali di server.

## Arti capability

| Capability | Arti |
|---|---|
| `VIEW` | Melihat daftar/detail yang diizinkan. |
| `CREATE_DRAFT` | Membuat dokumen Draft. |
| `EDIT_DRAFT` | Mengubah atau membatalkan Draft sesuai lifecycle dokumen. |
| `MANAGE` | Menjalankan transisi operasional, misalnya konfirmasi Quotation menjadi SO atau mengubah tahap Surat Jalan. |
| `REVIEW` / `APPROVE` | Memeriksa atau menyetujui pada workflow yang mendukungnya. |
| `POST` | Membuat efek final seperti posting penerimaan atau pembayaran. |
| `CANCEL_FINAL` / `REVERSE` | Koreksi dokumen final melalui jalur yang diizinkan; bukan menghapus histori. |
| `CLOSE_PERIOD` | Menutup periode akuntansi. |
| `EXPORT` / `IMPORT` | Ekspor atau impor pada submodul yang mendukungnya. |

## Pembatasan khusus per User

| Preset | Effective capability |
|---|---|
| Mengikuti role | Seluruh capability baseline role pada submodul tersebut. |
| Lihat saja | Hanya `VIEW`. |
| Operasional | Hanya `VIEW`, `CREATE_DRAFT`, dan `EDIT_DRAFT` yang memang sudah dimiliki role. `MANAGE`, approval, dan posting dilepas. |
| Tanpa akses | Tidak mempunyai capability pada submodul tersebut. |

Preset tidak dapat memberi capability baru. Contoh: role Finance yang baseline-nya
hanya `VIEW` pada Quotation/SO tidak berubah menjadi pembuat Quotation dengan
memilih **Operasional**.

## Fungsi setiap role

| Role | Fungsi baseline saat ini |
|---|---|
| Platform Super Admin | Seluruh capability yang didukung lintas Company dan pengaturan platform. Tetap mengikuti guard status dokumen, idempotency, Stock, dan Finance; bukan jalur bypass histori. |
| Company Owner | Seluruh capability yang didukung hanya pada Company dengan membership Owner aktif. Tidak dapat dibatasi oleh preset user dan tidak memperoleh pengaturan tenant tingkat platform. |
| Company Admin | Administrasi dan operasi luas dalam Company. Tidak memperoleh akses ke Company lain. |
| Store Manager | Operasi Sales/Purchase/Store yang diberikan katalog, termasuk konfirmasi dokumen operasional terkait. |
| Sales | Seluruh capability yang didukung permission dalam modul Sales pada runtime saat ini. |
| Sales Admin | Sama dengan Sales pada permission Sales lama; pada permission baru `sales.backoffice_returns`, Sales Admin juga menjadi approver komersial. |
| Warehouse Admin | Master/operasi Inventory, Surat Jalan, dan Penerimaan Barang yang diberikan katalog. Bukan role posting pembayaran Finance. |
| Finance | Operasi pembayaran, AR/AP, kas dan Finance yang diberikan katalog; hanya melihat dokumen Sales tertentu. |
| Accounting | Jurnal, laporan, rekonsiliasi dan akses baca Finance/Sales yang relevan. Pada Penerimaan Customer baseline-nya melihat/ekspor, bukan membuat atau posting. |
| Cashier | Operasi POS pada Store/terminal/sesi yang ditugaskan. Tidak otomatis memperoleh workspace Backoffice. |

## Matriks proses utama

Ini adalah baseline tanpa pembatasan khusus User.

| Proses | Owner/Admin | Store Manager | Sales/Sales Admin | Warehouse Admin | Finance | Accounting | Cashier |
|---|---|---|---|---|---|---|---|
| Quotation & SO Backoffice: lihat | Ya | Ya | Ya | Tidak | Ya | Ya | Tidak |
| Quotation & SO Backoffice: buat/edit Draft | Ya | Ya | Ya | Tidak | Tidak | Tidak | Tidak |
| Quotation menjadi SO / transisi operasional | Ya | Ya | Ya | Tidak | Tidak | Tidak | Tidak |
| Surat Jalan: lihat dan tahap pengiriman | Ya | Ya | Tidak | Ya | Tidak | Tidak | Tidak |
| Invoice Penjualan final: lihat/ekspor | Ya | Ya | Ya | Tidak | Ya | Ya | Tidak |
| Retur Backoffice: buat/edit/Submit Draft | Ya | Ya | Ya | Tidak | Tidak | Tidak | Tidak |
| Retur Backoffice: approval komersial | Ya | Ya | Sales Admin saja | Tidak | Ya | Tidak | Tidak |
| Supplier Order: buat/edit/konfirmasi sesuai lifecycle | Ya | Ya | Tidak | Tidak | Tidak | Tidak | Tidak |
| Penerimaan Barang: Draft/Post | Ya | Tidak | Tidak | Ya | Tidak | Tidak | Tidak |
| Penerimaan Customer: lihat/ekspor | Ya | Tidak | Tidak | Tidak | Ya | Ya | Tidak |
| Penerimaan Customer: buat/edit/post | Ya | Tidak | Tidak | Tidak | Ya | Tidak | Tidak |
| User & Akses | Ya | Tidak | Tidak | Tidak | Tidak | Tidak | Tidak |
| POS kasir | Sesuai assignment | Sesuai assignment | Tidak otomatis | Tidak otomatis | Tidak otomatis | Tidak otomatis | Ya, pada Store/terminal/sesi yang ditugaskan |

Catatan:

- Baris **Invoice Penjualan final** adalah akses dokumen/read model. Pembuatan
  Draft Invoice Backoffice dan postingnya tetap mengikuti guard workflow Sales,
  Invoice, periode, dan Finance yang aktif; tabel ini tidak menggantikan guard
  server tersebut.
- Retur Backoffice Step 1 menetapkan Finance dan Sales Admin sebagai approver,
  sedangkan Sales biasa tetap operator Draft. Role penerima Gudang serta
  pelaksana/approver Refund baru ditentukan pada step berikutnya.
- Role dapat melihat Stock Real/Movement untuk kebutuhan kontrol tanpa otomatis
  memperoleh hak melakukan mutation Stock.

## Case: akun Finance bisa membuat Quotation tetapi tidak bisa konfirmasi

Kondisi tersebut bukan baseline role `FINANCE` canonical:

- `sales.backoffice_orders` memberi Finance `VIEW` saja;
- tombol **Quotation Baru** membutuhkan `CREATE_DRAFT`;
- simpan Draft membutuhkan `CREATE_DRAFT` atau `EDIT_DRAFT`;
- **Konfirmasi menjadi SO** membutuhkan `MANAGE`.

Kombinasi “bisa membuat Draft tetapi tidak bisa konfirmasi” adalah bentuk
effective capability **Operasional** pada role yang memang operator, misalnya
Store Manager/Sales, bukan Finance murni. Jika akun bernama Finance mengalami
ini, periksa fakta berikut sebelum mengubah permission:

1. buka **User & Akses** dan pilih Company yang sama;
2. periksa **Role di perusahaan ini**, bukan jabatan/nama akun;
3. buka **Pembatasan submodul → Penjualan → Quotation & Sales Order**;
4. periksa daftar effective capability yang tampil;
5. Finance canonical seharusnya hanya menampilkan `VIEW` untuk submodul ini.

Jika role tercatat `FINANCE` tetapi effective capability masih memuat
`CREATE_DRAFT`, katalog permission pada database aktif mengalami drift dan harus
diaudit. Jangan mengatasinya dengan menyembunyikan tombol saja karena API/RPC
tetap menjadi authority.

## Source runtime

- Permission catalog dan resolver:
  `supabase/migrations/20260812120000_acp_phase2_shadow_permission_foundation.sql`.
- Quotation/SO Backoffice:
  `supabase/migrations/20260908120000_backoffice_sales_order_runtime.sql`.
- Role Sales/Sales Admin:
  `supabase/migrations/20260909130000_sales_roles_and_module_authority.sql`.
- Penerimaan Customer:
  `supabase/migrations/20260827100000_finance_customer_receipt_ar_foundation.sql`.
- Surat Jalan dan Penerimaan Barang:
  `supabase/migrations/20260813150000_inventory_delivery_document_authority.sql`
  dan `supabase/migrations/20260825130000_backoffice_goods_receipt_channel.sql`.

Dokumen ini wajib diperbarui bila permission catalog atau pemetaan role berubah.

## Catatan pengembangan tertunda: multi-role per Company

User meminta kemungkinan satu akun mempunyai beberapa role pada Company yang
sama, tetapi pengembangannya ditunda sampai setelah Retur & Refund Backoffice.
Runtime saat ini tetap satu `role_code` per pasangan Company–User.

Desain kandidat yang sudah disepakati untuk dibahas kembali adalah satu
**Primary Role** untuk hierarchy/display ditambah **Additional Roles**; effective
capability merupakan union role aktif lalu tetap dipersempit oleh restriction
per submodul. Implementasi belum diizinkan. Decision gate yang masih terbuka
adalah maker-checker ketika satu user menggabungkan role operasional dan Finance.
