# Panduan Kategori Transaksi KGS POS

Dokumen ini membantu owner, admin, dan Finance memahami menu
`Kategori & COA` tanpa harus memahami teknis database.

## Konsep Singkat

Kategori transaksi menjawab pertanyaan:

> “Kejadian bisnis apa yang sedang dicatat?”

Kategori transaksi bukan akun dan bukan jurnal. Contohnya:

- `Penjualan` menjelaskan bahwa barang sudah dijual;
- `Pembayaran Penjualan` menjelaskan bahwa uangnya diterima;
- `Penerimaan Barang` menjelaskan bahwa barang supplier sudah sampai;
- `Invoice Supplier` menjelaskan bahwa tagihan supplier sudah diakui.

Satu transaksi dapat melewati beberapa kejadian pada waktu berbeda. Karena itu
Penjualan dan Pembayaran Penjualan, atau Penerimaan Barang dan Invoice Supplier,
tidak boleh digabung menjadi satu kategori.

Alurnya:

```text
Kejadian bisnis → Kategori transaksi → Fungsi akun → Akun Company
```

- **Jenis transaksi sistem** menjaga arti kejadian bagi aplikasi.
- **Kategori transaksi** adalah nama bisnis yang dipahami user.
- **Fungsi akun** menjelaskan kebutuhan akuntansi, misalnya Kas, Persediaan,
  Pendapatan, atau Beban.
- **Akun Company** adalah akun tujuan yang dipilih Finance.

## Kategori Bawaan

Setiap Company menerima 26 kategori bawaan berikut. Semuanya wajib tersedia
secara struktur, tetapi kategori dari modul yang tidak dipakai tidak akan
membuat transaksi dengan sendirinya.

### Penjualan dan Customer

| Kategori | Dipakai ketika |
|---|---|
| Penjualan | transaksi penjualan selesai dan siap dicatat |
| Pembayaran Penjualan | pembayaran penjualan diterima |
| Retur Penjualan | barang dikembalikan customer |
| Credit Note Customer | nilai tagihan customer dikurangi lewat koreksi |
| Debit Note Customer | nilai tagihan customer ditambah lewat koreksi |
| Top Up Saldo Customer | customer menitipkan atau menambah saldo |
| Pemakaian Saldo Customer | saldo customer digunakan untuk transaksi |

### Pembelian dan Supplier

| Kategori | Dipakai ketika |
|---|---|
| Penerimaan Barang | barang supplier benar-benar diterima |
| Invoice Supplier | invoice diakui sebagai tagihan supplier |
| Pembayaran Supplier | utang supplier dibayar |
| Retur Pembelian | barang dikembalikan kepada supplier |
| Credit Note Supplier | supplier mengurangi nilai tagihan |
| Debit Note Supplier | dokumen koreksi menambah klaim/tagihan supplier |

Penerimaan Barang dan Invoice Supplier dipisahkan karena barang bisa tiba lebih
dulu daripada invoice. Ini penting untuk stok dan utang provisional.

### Stok

| Kategori | Dipakai ketika |
|---|---|
| Stok Awal | saldo stok dimasukkan saat awal penggunaan sistem |
| Stok Lebih | hasil hitung fisik lebih besar dari sistem |
| Stok Kurang atau Rusak | ada kehilangan, kerusakan, atau fisik kurang |
| Transfer Stok | stok berpindah antar-gudang dalam Company |

Transfer stok tidak otomatis menjadi pendapatan atau beban karena barang masih
milik Company yang sama.

### Expense dan Kas

| Kategori | Dipakai ketika |
|---|---|
| Uang Muka Operasional | uang dicairkan sebelum bukti pengeluaran final |
| Beban Operasional Umum | bukti pengeluaran diselesaikan menjadi beban |
| Kas Masuk Lainnya | penerimaan kas sah yang bukan penjualan |
| Setoran Kas | kas toko dipindahkan ke kas transit atau bank |
| Selisih Kas | hasil hitung kas berbeda dari sistem |

`Uang Muka Operasional` bukan beban final. Contoh: kasir menerima Rp500.000
untuk belanja; setelah nota masuk, penyelesaiannya memakai kategori beban.

Company boleh menambah kategori khusus dengan jenis sistem
`Settlement Expense`, misalnya:

- Listrik;
- Bensin;
- ATK;
- Sewa;
- Internet.

Kategori khusus membantu laporan lebih rinci tanpa mengubah jenis kejadian
sistem.

### Ketul dan Finance

| Kategori | Dipakai ketika |
|---|---|
| Penerimaan Ketul Customer | ketul milik customer diterima |
| Hasil Pengolahan Ketul | hasil dari vendor pengolahan diterima |
| Pembayaran Vendor Ketul | biaya vendor pengolahan dibayar |
| Jurnal Penyesuaian Manual | Finance membuat koreksi di luar modul operasional |

Kategori Ketul tetap tersedia sebagai kontrak sistem, tetapi tidak digunakan
bila fitur Ketul Company tidak aktif. Jurnal Penyesuaian Manual hanya untuk role
Finance/Accounting dan tidak menggantikan transaksi operasional biasa.

## Yang Boleh dan Tidak Boleh Diubah

Kategori bawaan:

- nama, kode internal, dan keterangan boleh disesuaikan;
- jenis transaksi sistem tidak boleh diganti;
- tidak boleh dinonaktifkan atau dihapus;
- tidak otomatis memiliki mapping akun.

Kategori khusus Company:

- dapat dibuat untuk kebutuhan rincian bisnis;
- nama dan kode harus unik;
- dapat dinonaktifkan jika tidak lagi dipakai;
- jenis transaksi terkunci setelah memiliki mapping atau histori.

## Mapping Akun

Mapping akun menjawab pertanyaan:

> “Untuk kejadian ini, fungsi tertentu diarahkan ke akun Company yang mana?”

Contoh kategori `Listrik`:

```text
Kategori: Listrik
Jenis sistem: Settlement Expense
Fungsi akun: Beban
Akun tujuan: Beban Listrik
```

Jika Company belum mempunyai akun `Beban Listrik`, Finance dapat membuat akun
posting tersebut di bawah grup Beban, atau sementara memilih `Beban Operasional
Umum`.

Fallback Company adalah pilihan terakhir yang dibuat Finance secara eksplisit
untuk satu fungsi akun. Contoh: fungsi `Beban` diarahkan ke `Beban Operasional
Umum` bila kategori belum mempunyai mapping lebih khusus. Fallback bukan
tebakan sistem dan tidak mengalahkan mapping kategori yang sudah ada.

COA dapat disusun maksimum tiga tingkat. Akun grup tidak menerima posting;
journal hanya boleh menuju akun posting aktif. Saldo normal mengikuti tipe akun,
tetapi Finance dapat melakukan override dengan warning untuk akun kontra seperti
Retur dan Potongan Penjualan.

Perubahan mapping membuat versi baru dengan tanggal mulai berlaku. Histori lama
tidak ditimpa.

## Status Implementasi Saat Ini

Kategori dan mapping sudah dapat dikonfigurasi, tetapi automatic Finance
posting masih nonaktif. Menambah kategori atau mapping saat ini tidak membuat
jurnal. Aktivasi resolver, period lock, balanced posting, dan retry queue akan
melewati gate Finance terpisah.
