# Manual Pengguna KGS POS

Versi dokumen: 14 Agustus 2026  
Sasaran pembaca: pemilik perusahaan, administrator, manajer toko, staf gudang, kasir, Finance, dan Accounting.

Manual ini menjelaskan penggunaan Backoffice dan PWA KGS POS berdasarkan fitur yang tersedia saat ini. Menu dan tindakan yang terlihat dapat berbeda karena akses ditentukan oleh perusahaan aktif, peran, pengaturan modul, penugasan toko, serta pembatasan khusus pengguna.

> Catatan penting: status **Draft**, **Diajukan**, atau **Menunggu Persetujuan** belum menimbulkan dampak final terhadap stok, kas, utang, saldo pelanggan, atau jurnal. Dampak final hanya terjadi melalui tindakan seperti **Post**, **Validasi**, **Cairkan**, atau **Setujui**, sesuai alur masing-masing dokumen.

## Daftar Isi

1. [Mengenal KGS POS](#1-mengenal-kgs-pos)
2. [Peran dan hak akses](#2-peran-dan-hak-akses)
3. [Masuk, keluar, dan memilih perusahaan](#3-masuk-keluar-dan-memilih-perusahaan)
4. [Navigasi Backoffice](#4-navigasi-backoffice)
5. [Persiapan awal perusahaan](#5-persiapan-awal-perusahaan)
6. [Modul Inventory](#6-modul-inventory)
7. [Modul Contacts](#7-modul-contacts)
8. [Modul Purchase](#8-modul-purchase)
9. [Modul Sales](#9-modul-sales)
10. [Modul Finance](#10-modul-finance)
11. [Modul Platform](#11-modul-platform)
12. [Data Exchange](#12-data-exchange)
13. [Menggunakan PWA POS](#13-menggunakan-pwa-pos)
14. [Alur penjualan lengkap](#14-alur-penjualan-lengkap)
15. [Retur penjualan dan pembelian](#15-retur-penjualan-dan-pembelian)
16. [Expense operasional](#16-expense-operasional)
17. [Setor kas dan selisih setoran](#17-setor-kas-dan-selisih-setoran)
18. [Mode offline dan sinkronisasi](#18-mode-offline-dan-sinkronisasi)
19. [Nota, invoice, dan surat jalan](#19-nota-invoice-dan-surat-jalan)
20. [Jurnal dan laporan keuangan](#20-jurnal-dan-laporan-keuangan)
21. [Periode akuntansi](#21-periode-akuntansi)
22. [Operasi multi-company](#22-operasi-multi-company)
23. [Pemecahan masalah](#23-pemecahan-masalah)
24. [Praktik operasional yang disarankan](#24-praktik-operasional-yang-disarankan)
25. [Glosarium](#25-glosarium)

---

## 1. Mengenal KGS POS

KGS POS terdiri atas dua aplikasi:

- **Backoffice** untuk pengaturan master, persediaan, pembelian, penjualan, Finance, laporan, perusahaan, pengguna, serta pertukaran data.
- **PWA POS** untuk kegiatan kasir: membuka sesi, menjual, menyimpan Draft, menerima pembayaran, mencetak dokumen, membuat permintaan stok, menerima barang, retur, Expense, setor kas, dan transaksi offline yang diizinkan.

Data setiap perusahaan terisolasi. Selalu periksa nama perusahaan, toko, terminal, gudang, dan sesi aktif sebelum membuat transaksi.

## 2. Peran dan hak akses

Peran standar meliputi:

| Peran | Kegunaan umum |
|---|---|
| Company Owner | Kendali tertinggi pada perusahaan dan persetujuan final tertentu. |
| Company Admin | Administrasi perusahaan, master, pengguna, dan operasi. |
| Store Manager | Operasi serta persetujuan dalam cakupan toko yang ditugaskan. |
| Warehouse Admin | Operasi persediaan dan pembelian yang diizinkan. |
| Finance | Kas, Expense, piutang/utang, dokumen keuangan, dan proses persetujuan. |
| Accounting | Jurnal, laporan, rekonsiliasi, dan akses baca yang relevan. |
| Cashier | Operasi POS dalam toko, terminal, gudang, dan sesi yang ditugaskan. |

Administrator dapat memberikan pembatasan khusus per submodul. Preset yang umum adalah **Lihat Saja**, **Operasional**, dan **Tanpa Akses**. Pembatasan khusus hanya dapat mempersempit kewenangan dasar; tidak dapat memperluas cakupan perusahaan atau toko.

Jika menu tidak tampil, periksa perusahaan aktif, status keanggotaan, peran, penugasan toko, status modul perusahaan, dan pembatasan khusus pengguna.

## 3. Masuk, keluar, dan memilih perusahaan

### Masuk ke Backoffice

1. Buka alamat Backoffice.
2. Masukkan email dan kata sandi akun.
3. Tekan **Masuk**.
4. Jika pengguna memiliki lebih dari satu perusahaan, pilih perusahaan yang akan dikerjakan.
5. Pastikan nama perusahaan aktif di bagian atas aplikasi sudah benar.

### Masuk ke PWA POS

1. Buka alamat PWA POS.
2. Masuk menggunakan akun yang mempunyai penugasan kasir aktif.
3. Pilih terminal POS dan gudang penjualan yang tersedia.
4. Buka sesi kasir dan isi kas awal bila diminta.

Pesan **ACTIVE STORE MEMBERSHIP REQUIRED** berarti pengguna belum mempunyai penugasan toko aktif pada perusahaan yang sedang dipilih.

### Berpindah perusahaan

Gunakan pemilih perusahaan. Peran dan pembatasan dihitung ulang untuk perusahaan tujuan. Jangan mengandalkan tab lama setelah berpindah perusahaan; muat ulang halaman bila tampilan belum berubah.

### Keluar

Gunakan tombol **Keluar** pada aplikasi yang sedang digunakan. Logout Backoffice dan PWA diisolasi per aplikasi. Bila sesi server telah kedaluwarsa atau dicabut, masuk kembali.

## 4. Navigasi Backoffice

- Halaman **Home** hanya menampilkan modul yang dapat diakses pengguna.
- Klik sebuah modul untuk membuka daftar submodul.
- Klik logo atau nama perusahaan untuk kembali ke Home.
- Gunakan tombol menu untuk membuka **Fast Link**.
- Gunakan kolom pencarian Fast Link untuk menemukan modul atau submodul.

Menyembunyikan kartu di Home bukan satu-satunya pengamanan. Akses URL langsung dan operasi server tetap diperiksa berdasarkan hak pengguna.

## 5. Persiapan awal perusahaan

Urutan persiapan yang disarankan:

1. Lengkapi identitas dan logo perusahaan.
2. Aktifkan modul yang diperlukan.
3. Buat toko, gudang, terminal POS, dan UOM.
4. Buat kategori serta produk.
5. Atur metode pembayaran, pajak, dan pricelist.
6. Buat pelanggan dan supplier.
7. Tambahkan pengguna ke perusahaan, pilih peran, lalu tetapkan toko bila diperlukan.
8. Siapkan COA dan pemetaan kategori transaksi.
9. Masukkan stok awal hanya untuk pasangan produk–gudang yang belum mempunyai pergerakan non-stok-awal.
10. Uji satu transaksi kecil dari awal sampai laporan sebelum mulai beroperasi.

## 6. Modul Inventory

### 6.1 Stock Real

Menampilkan saldo aktual per produk dan gudang, termasuk ringkasan FIFO dan nilai persediaan yang diolah server. Gunakan filter produk/gudang. Jika saldo berbeda dari kondisi fisik, gunakan Penyesuaian Stok atau Stock Opname; jangan mengubah saldo langsung.

### 6.2 Kartu Stok

Menampilkan riwayat sumber masuk/keluar, tanggal posting, jumlah, dan saldo setelah transaksi. Riwayat final tidak boleh diedit langsung.

### 6.3 Transfer Stok

1. Pilih gudang asal dan tujuan yang berbeda.
2. Tambahkan produk serta kuantitas.
3. Simpan Draft dan periksa kembali.
4. Klik **Post** untuk memindahkan stok secara atomik.

Posting membuat pergerakan keluar dan masuk yang saling berpasangan.

### 6.4 Penyesuaian Stok

1. Buat dokumen dan pilih gudang.
2. Pilih alasan penyesuaian.
3. Masukkan selisih positif atau negatif.
4. Simpan dan Post sesuai kewenangan.

Gunakan untuk koreksi resmi, bukan untuk penjualan atau pembelian.

### 6.5 Stock Opname

1. Buat sesi opname dan tentukan gudang.
2. Mulai penghitungan.
3. Petugas memasukkan hasil melalui tampilan blind count.
4. Manajer meninjau selisih dan meminta hitung ulang bila perlu.
5. Selesaikan lalu Post.

Posting opname membuat Penyesuaian Stok kanonis.

### 6.6 Surat Jalan

1. Buka **Inventory → Surat Jalan**.
2. Cari dokumen berdasarkan nomor, pelanggan, atau status.
3. Buka detail dan cetak dokumen.
4. Ubah status menjadi dikirim ketika barang berangkat.
5. Konfirmasikan terkirim setelah penerima menerima barang.

Perubahan status Surat Jalan tidak mengurangi stok untuk kedua kalinya.

### 6.7 Produk & UOM

Kelola identitas produk, SKU, jenis produk, UOM dasar, UOM jual/beli, dan konversi.

- Produk **STOCK** memiliki saldo fisik dan FIFO.
- Produk **BUNDLE** bersifat virtual; ketersediaannya diturunkan dari komponen.
- Faktor konversi UOM harus benar sebelum produk dipakai.
- Produk bersejarah sebaiknya dinonaktifkan, bukan dihapus.

### 6.8 Stok Awal

1. Pilih tanggal, gudang, produk, kuantitas, dan biaya per unit dasar.
2. Simpan Draft.
3. Minta Company Owner/Admin memeriksa dan Post.

Gunakan sekali pada pasangan produk–gudang yang belum memiliki histori non-stok-awal. Jangan gunakan untuk memperbaiki saldo berjalan.

### 6.9 Minimum Stock

Tetapkan ambang minimum per produk dan gudang. Peringatan kebutuhan tidak otomatis membuat Supplier Order.

### 6.10 Master Inventory

Berisi toko, gudang, terminal POS, UOM, kategori produk, serta pengaturan terkait. Nonaktifkan master yang sudah digunakan daripada menghapusnya.

## 7. Modul Contacts

### 7.1 Pelanggan

1. Buka **Contacts → Pelanggan**.
2. Tambah atau pilih pelanggan.
3. Isi identitas, kategori, kontak, alamat pengiriman, parent customer bila ada, dan pricelist default.
4. Simpan.

Pelanggan terikat pada perusahaan aktif. Pelanggan Umum adalah identitas sistem dan tidak boleh memegang saldo pelanggan.

### 7.2 Supplier

Simpan identitas supplier, kontak, rekening bank, dan relasi produk–supplier. Supplier hanya dapat digunakan oleh perusahaan pemiliknya.

### 7.3 User & Akses

1. Pilih pengguna untuk membuka detail.
2. Pilih perusahaan yang hendak diatur.
3. Tambahkan atau ubah peran perusahaan.
4. Tambahkan penugasan toko bila diperlukan.
5. Opsional: atur pembatasan khusus per modul/submodul.
6. Simpan dan periksa catatan audit.

Saat mencabut akses, nonaktifkan keanggotaan perusahaan.

## 8. Modul Purchase

### 8.1 Supplier Order dan permintaan stok

1. Kasir membuat dan mengajukan permintaan stok.
2. Petugas Purchase membuka daftar permintaan.
3. Pilih baris yang akan dipesan dan supplier tujuan.
4. Buat Supplier Order, periksa harga estimasi, UOM, serta gudang tujuan.
5. Konfirmasikan order.

Baris yang sudah masuk Supplier Order tidak lagi ditampilkan sebagai kebutuhan terbuka. Baris lain tetap dapat dipesan ke supplier berbeda.

### 8.2 Penerimaan Barang

1. Di PWA, buka **Terima Barang**.
2. Pilih Supplier Order yang memenuhi syarat untuk toko/sesi.
3. Masukkan kuantitas diterima, baik, rusak, atau ditolak.
4. Konfirmasi penerimaan.

Barang baik menambah stok/FIFO. Barang rusak atau ditolak dicatat terpisah.

### 8.3 Retur Pembelian

1. Pilih sumber penerimaan.
2. Pilih barang, UOM retur, dan kuantitas.
3. Simpan Draft.
4. Lakukan review dan Post dari pihak yang berwenang.

Retur sebagian dus dalam satuan lebih kecil diperbolehkan jika konversi UOM tersedia. Jumlah retur dibatasi oleh sisa kuantitas sumber.

## 9. Modul Sales

### 9.1 Invoice Penjualan

Menampilkan snapshot invoice final untuk melihat, mencetak ulang, dan menelusuri bukti transaksi. Perubahan master tidak mengubah invoice historis.

### 9.2 Pricelist

1. Buat pricelist Global atau Customer.
2. Tambahkan aturan harga dan periode berlaku.
3. Pilih cakupan toko/pelanggan bila bukan global.
4. Tentukan default jika diperlukan.

Di POS, pricelist pelanggan menjadi pilihan awal, tetapi kasir dapat memilih alternatif yang aktif dan memenuhi syarat. Harga final selalu dihitung server.

### 9.3 Bundle

1. Buat produk bertipe Bundle.
2. Pilih UOM jual.
3. Tambahkan komponen dan kuantitas dasar.
4. Simpan.

Bundle tidak mempunyai stok fisik sendiri. Penjualannya mengurangi stok dan FIFO komponen.

### 9.4 Approval Return

Gunakan untuk meninjau Draft retur penjualan dan melakukan Post. Aksi Post merupakan persetujuan final.

## 10. Modul Finance

### 10.1 Expense

Menangani kategori, kebijakan persetujuan, pengajuan, pencairan, penyelesaian, pengembalian dana, dan tambahan pencairan. Lihat [alur Expense](#16-expense-operasional).

### 10.2 Setor Kas

Menangani sesi kasir tertutup, bukti setoran, pengajuan, dan approval/rejection. Lihat [alur Setor Kas](#17-setor-kas-dan-selisih-setoran).

### 10.3 Selisih Setoran

Digunakan jika nilai aktual berbeda dari nilai yang diharapkan. Finance dapat menetapkan penanggung jawab, membuat resolusi, dan meminta Owner/Admin menyetujuinya.

### 10.4 Saldo Customer

- Menampilkan saldo, ledger, statement, dan pengajuan koreksi.
- Kelebihan pembayaran non-tunai dapat dikreditkan jika fitur/kebijakan aktif.
- Saldo dapat digunakan sebagai metode pembayaran sesuai kebijakan.
- Koreksi manual memakai maker-checker; pembuat tidak boleh menyetujui pengajuannya sendiri.

### 10.5 Faktur Supplier

1. Buat Draft berdasarkan dokumen pembelian/penerimaan.
2. Isi nomor dan nilai faktur.
3. Tinjau matching serta toleransi.
4. Validasi untuk membentuk AP final.

Toleransi bersifat opsional; batas absolut kosong berarti tidak menambah pembatasan ekstra.

### 10.6 Pembayaran Supplier

1. Pilih supplier dan faktur tervalidasi yang masih terbuka.
2. Pilih sumber kas/bank dan metode pembayaran.
3. Alokasikan nilai pembayaran.
4. Validasi.

Total alokasi harus sama dengan pembayaran dan tidak melampaui saldo faktur.

### 10.7 Metode Pembayaran

Atur nama, jenis, rute penyelesaian, cakupan toko, kebutuhan bukti, serta biaya. Kode sistem tertentu tidak dapat diubah.

### 10.8 Aturan Pajak

Atur pajak penjualan/pembelian, periode, tarif, dan assignment. Ongkir tidak otomatis kena pajak tanpa aturan eksplisit.

### 10.9 Kategori & COA

Hubungkan kategori transaksi dan fungsi akun ke COA perusahaan. Akun hasil impor perusahaan bukan otomatis akun sistem dan tidak boleh dipakai lintas tenant.

### 10.10 Jurnal Keuangan

- **Journal Entries**: log seluruh jurnal; klik baris untuk melihat debit/kredit.
- **General Ledger**: daftar akun yang dapat diperluas untuk melihat pergerakan.
- **Trial Balance**: saldo debit dan kredit per akun.
- **Income Statement**: pendapatan dan beban periode.
- **Balance Sheet**: aset, liabilitas, dan ekuitas.
- **Pending Analysis**: event keuangan yang belum selesai.
- **Reconciliation Summary**: perbandingan subledger dengan GL.
- **Accounting Period**: periode buku terbuka atau tertutup.

Nomor tampilan seperti `JUR/...` digunakan di UI; UUID internal tetap disimpan server-side.

## 11. Modul Platform

### 11.1 Perusahaan

Kelola identitas perusahaan. Perubahan hanya berlaku pada perusahaan terpilih.

### 11.2 Logo Perusahaan

Unggah, ganti, atau hapus logo. Logo tampil di samping nama perusahaan dan dipakai pada dokumen. Berkas yang sudah dirujuk snapshot historis tetap dipertahankan.

### 11.3 Pengaturan Modul

Aktifkan/nonaktifkan fitur per perusahaan. Menonaktifkan modul menutup operasi baru, tetapi tidak menghapus histori.

## 12. Data Exchange

Pilihan dataset hanya muncul jika pengguna memiliki akses modul dan kemampuan **EXPORT** atau **IMPORT** yang sesuai.

### Ekspor

1. Pilih modul dan dataset.
2. Tentukan filter/periode bila tersedia.
3. Unduh hasil ekspor.

### Impor

1. Pilih tipe yang didukung dan unduh template.
2. Unggah berkas.
3. Jalankan validasi.
4. Perbaiki semua baris bermasalah.
5. Commit setelah hasil bersih.

Impor tidak boleh menulis transaksi final, histori stok, jurnal, atau pembayaran secara langsung.

## 13. Menggunakan PWA POS

### Membuka sesi

1. Pilih terminal dan gudang penjualan.
2. Pastikan toko, terminal, dan perusahaan benar.
3. Isi kas awal aktual.
4. Buka sesi.

Satu kasir tidak boleh mempunyai dua sesi terbuka yang tumpang tindih.

### Area utama

Tersedia daftar produk, kategori, keranjang, pelanggan/pricelist, Draft, checkout, Return, Expense, Minta Stok, Terima Barang, Retur Supplier, Setor Kas, Offline, printer, dan tutup sesi.

### Draft

Gunakan saat transaksi belum siap dibayar. Draft tidak mengurangi stok dan belum membentuk jurnal. Kunci edit mencegah Draft ditimpa kasir lain.

### Split payment

Tambahkan beberapa pembayaran, pilih metode, lalu isi **Uang diterima** per metode. Jumlah dasar harus memenuhi total. Kembalian dan kredit saldo mengikuti kebijakan.

### Menutup sesi

Pastikan transaksi selesai, antrean Offline diperiksa, isi kas penutupan aktual, lalu tutup sesi. Sesi dengan kewajiban Offline aktif dapat ditolak.

## 14. Alur penjualan lengkap

1. Buka sesi kasir.
2. Pilih produk/Bundle dan kuantitas.
3. Pilih pelanggan atau Pelanggan Umum.
4. Periksa pricelist dan ubah bila diizinkan.
5. Periksa diskon, pajak, pembulatan, dan ongkir.
6. Klik **Konfirmasi & Post**.
7. Pilih metode pembayaran dan isi nilai diterima.
8. Konfirmasi posting.
9. Setelah sukses, keranjang kembali ke awal.
10. Buka nota/invoice pada tab baru dan cetak.
11. Jika dikirim, centang opsi pengiriman, periksa data pelanggan, lalu cetak Surat Jalan.

Posting bersifat atomik dan idempoten. Stok/FIFO dan jurnal dihitung server, bukan dari nilai buatan client.

### Ongkir

- Menambah total tagihan dan dicatat sebagai pendapatan pengiriman tersendiri.
- Dapat ditampilkan atau disembunyikan pada invoice sesuai pengaturan.
- Hanya dikenai pajak jika ada aturan eksplisit.

### Izin stok minus

Hanya tersedia jika entitlement, kebijakan perusahaan, izin produk/gudang, otorisasi, dan biaya provisional lengkap. Allowance Offline aktif tetap dilindungi. Pengadaan berikutnya merekonsiliasi alokasi negatif.

## 15. Retur penjualan dan pembelian

### Retur penjualan

1. Cari penjualan yang dapat diretur.
2. Pilih baris dan kuantitas tersisa.
3. Tentukan kondisi serta gudang tujuan.
4. Tentukan refund.
5. Putuskan refund ongkir secara eksplisit; retur sebagian tidak otomatis mengembalikan ongkir.
6. Simpan Draft.
7. Manager/Admin melakukan Post.

Posting mengembalikan FIFO sumber yang sesuai dan membuat event refund tepat satu kali.

### Retur pembelian

Lihat [Retur Pembelian](#83-retur-pembelian). Gunakan UOM yang tersedia agar satu dus dapat diretur sebagian.

## 16. Expense operasional

1. **Ajukan**: pilih kategori, nilai, tujuan, dan bukti.
2. **Submit** untuk pemeriksaan.
3. Approver melakukan **Approve/Reject**. Alasan wajib untuk penolakan atau tindakan yang memang memerlukannya, bukan persetujuan biasa.
4. **Cairkan**; tunai memengaruhi cash drawer, non-tunai tidak.
5. **Penyelesaian**: catat biaya aktual.
6. Kembalikan sisa dana atau ajukan tambahan pencairan.
7. Review sampai final.

Jangan menganggap nilai pengajuan sebagai biaya aktual sebelum penyelesaian.

## 17. Setor kas dan selisih setoran

### Setor kas

1. Tutup sesi kasir.
2. Pilih sesi yang memenuhi syarat.
3. Buat Draft, isi nilai aktual dan bukti.
4. Submit.
5. Finance/approver menyetujui atau menolak.

Persetujuan biasa tidak memerlukan alasan.

### Selisih setoran

Sistem membuat exception, Finance meneliti dan membuat resolusi, lalu Owner/Admin menyetujui atau menolak. Sistem menyimpan alokasi dan Financial Event penyelesaian.

## 18. Mode offline dan sinkronisasi

Offline memerlukan fitur perusahaan, kebijakan terminal, sesi siap, katalog yang sudah diunduh saat online, allowance stok, dan metode pembayaran Offline yang sah.

### Sebelum terputus

1. Buka menu **Offline**.
2. Perbarui katalog.
3. Pastikan status terminal dan allowance siap.
4. Jangan menghapus data situs/browser.

### Saat offline

Transaksi disimpan ke antrean lokal menggunakan snapshot yang telah diizinkan.

### Saat tersambung kembali

1. Buka panel Offline dan jalankan sinkronisasi.
2. Sistem memeriksa status server untuk mencegah posting ganda.
3. Periksa status Posted, Needs Confirmation, Failed, atau Invalidated.
4. Jangan membuat ulang transaksi sebelum status server diperiksa.

## 19. Nota, invoice, dan surat jalan

### Nota

Setelah transaksi sukses, nota dibuka pada tab baru agar langsung dapat dicetak.

### Invoice

Invoice memakai snapshot saat posting sehingga perubahan master tidak mengubah histori.

### Surat Jalan

- Dapat dicetak dari POS setelah opsi pengiriman dipilih.
- Dapat dicetak ulang dari **Inventory → Surat Jalan**.
- Terpisah dari Invoice dan berfokus pada kuantitas/pengiriman.
- Konfirmasi pengiriman dilakukan dari detail Surat Jalan di Backoffice Inventory.

## 20. Jurnal dan laporan keuangan

### Journal Entries

Klik jurnal untuk melihat tanggal, sumber Financial Event, deskripsi, serta baris debit/kredit. Koreksi jurnal final dilakukan melalui reversal yang dijaga server.

### General Ledger

Pilih periode, lalu klik akun untuk memperluas detail transaksi. Akun khusus pada tampilan merupakan filter akun, bukan buku besar yang berbeda.

### Laporan

Buka Neraca Saldo, Laba Rugi, Neraca, Pending Analysis, atau Rekonsiliasi. Gunakan ekspor bulanan bila akses tersedia.

### Rekonsiliasi

Pastikan nilai FIFO sama dengan Inventory GL, utang supplier sama dengan AP GL, saldo pelanggan sama dengan ledger/GL, jurnal seimbang, serta tidak ada HOLD/exception terbuka.

## 21. Periode akuntansi

Periode mengendalikan tanggal posting, bukan menghapus transaksi tempo lintas bulan. Faktur bulan lalu tetap terbuka dan pembayaran bulan berikutnya menyelesaikan AP/AR pada periode pembayaran. Penutupan mencegah posting baru ke periode tersebut; pembukaan kembali memerlukan otorisasi, alasan, dan audit.

## 22. Operasi multi-company

- Peran dan pembatasan pengguna dapat berbeda per perusahaan.
- Setiap transaksi mengikuti perusahaan aktif.
- Semua referensi transaksi harus berasal dari perusahaan yang sama.
- Pilih perusahaan target secara eksplisit saat mengatur akses pengguna.
- Setelah berpindah perusahaan, periksa nama perusahaan dan menu sebelum bekerja.

## 23. Pemecahan masalah

### Menu tidak tampil

Periksa peran, modul aktif, override, perusahaan aktif, dan penugasan toko. Lakukan hard refresh setelah akses diubah.

### Tidak ada terminal/gudang di POS

Pastikan terminal aktif, gudang penjualan ditetapkan, dan pengguna mempunyai store membership aktif dalam perusahaan yang sama.

### `ACTIVE STORE MEMBERSHIP REQUIRED`

Aktifkan penugasan toko pengguna, lalu masuk kembali.

### `CUSTOM_PERMISSION_DENIED` atau `permission denied`

Hak pengguna tidak cukup atau konteks perusahaan tidak cocok. Jangan memberikan akses tabel langsung; perbaiki role/override atau gunakan RPC resmi.

### Sering keluar sendiri

Pastikan deployment terbaru, masuk ulang jika token lama dicabut, periksa Auth redirect URL, waktu perangkat, dan koneksi. Catat URL, waktu, aksi, serta pesan error bila berulang.

### Sinkronisasi Offline lama

Jangan mengulang checkout. Pulihkan koneksi, jalankan status check, lalu retry dari panel Offline.

### Konflik versi

Muat ulang dokumen, tinjau data terbaru, lalu ulangi. Jangan mengubah master version secara manual.

### Data perusahaan tercampur

Hentikan operasi dan laporkan segera. Jangan memperbaiki langsung melalui database.

## 24. Praktik operasional yang disarankan

- Gunakan akun pribadi dan hak minimum.
- Pisahkan pembuat serta penyetuju koreksi Finance.
- Periksa perusahaan, toko, terminal, gudang, dan sesi sebelum Post.
- Simpan Draft jika data belum final.
- Jangan mengedit database untuk memperbaiki transaksi.
- Nonaktifkan master bersejarah; jangan menghapusnya.
- Lakukan backup, rekonsiliasi, dan review exception berkala.
- Uji konfigurasi pada transaksi kecil.
- Setelah deployment, uji login, role, transaksi, print, dan laporan.

## 25. Glosarium

| Istilah | Arti |
|---|---|
| ACP | Pembatasan kemampuan per submodul dan perusahaan. |
| AP | Utang usaha kepada supplier. |
| AR | Piutang usaha dari pelanggan. |
| COA | Chart of Accounts atau daftar akun. |
| Draft | Dokumen yang belum final. |
| FIFO | Stok masuk pertama, keluar pertama. |
| Financial Event | Peristiwa bisnis sumber jurnal. |
| GL | General Ledger atau Buku Besar. |
| Idempoten | Pengulangan permintaan tidak membuat efek ganda. |
| Master Version | Versi untuk mencegah konflik perubahan. |
| Movement | Catatan perubahan kuantitas stok. |
| Post | Finalisasi dokumen dan efek transaksinya. |
| PWA | Aplikasi POS web dengan dukungan Offline terbatas. |
| Rekonsiliasi | Pencocokan subledger dengan GL. |
| Snapshot | Salinan nilai transaksi yang tidak berubah bersama master. |
| Tenant | Perusahaan yang datanya terisolasi. |

---

## Bantuan dan pelaporan masalah

Sertakan aplikasi/URL, waktu, email dan peran tanpa kata sandi, perusahaan/toko/terminal/gudang aktif, nomor dokumen, langkah sebelum error, pesan lengkap, tangkapan layar, serta status koneksi.

Jangan pernah mengirim kata sandi, service-role key, access token, refresh token, atau secret deployment.
