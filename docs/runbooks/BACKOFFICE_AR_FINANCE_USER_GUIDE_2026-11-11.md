# Manual User Finance Backoffice — Penerimaan dan Open Credit Customer

Tanggal: 2026-11-11  
Scope: Company dengan proses `BACKOFFICE_DELIVERED_QTY_INVOICE`.

## Hak akses dan menu

User harus memiliki capability `finance.customer_receipts`. Menu Finance kini
dipisahkan menjadi:

1. `Penerimaan Customer` — penerimaan uang, aging, statement, dan riwayat
   dokumen penerimaan;
2. `Open Credit Customer` — alokasi Credit Note, refund Cash/Bank, konversi ke
   Saldo Customer, penggunaan saldo pada Invoice Posted, dan reversal.

Kedua menu menggunakan otorisasi server yang sama. Pemisahan menu tidak memberi
hak akses baru.

## A. Invoice sampai piutang terbuka

1. Sales membuat dan mengonfirmasi Sales Order.
2. Warehouse menyelesaikan Dispatch.
3. Sales/Finance membuat Invoice Draft.
4. Periksa Draft; Draft belum membuat jurnal Finance.
5. Klik `Konfirmasi & Terbitkan`.

Invoice Posted membuat piutang terbuka dan jurnal Invoice normal. Stock/FIFO
tetap mengikuti Dispatch, bukan tindakan Finance berikutnya.

## B. Penerimaan Customer

Buka `Finance > Penerimaan Customer`.

### Membayar satu atau beberapa Invoice

1. Klik `Penerimaan baru`.
2. Pilih Customer, tanggal aktual, dan metode Kas/Bank.
3. Isi referensi/bukti bila diperlukan.
4. Isi `Alokasi bayar` pada satu atau beberapa Invoice Customer tersebut.
5. Isi `Nominal diterima`.
6. Pastikan `Dialokasikan ke invoice` dan `Sisa kredit Customer` benar.
7. Klik `Simpan draft`.
8. Periksa dokumen, lalu klik `Post`.

Hasil posting: seluruh uang masuk satu jurnal Cash/Bank-to-AR; outstanding
Invoice berkurang sebesar alokasi; selisih lebih bayar menjadi Receipt open
credit dengan sumber penerimaan yang dapat diaudit.

### Laporan

- Gunakan `Per tanggal`, `Mulai statement`, dan filter Customer untuk aging.
- Klik `Terapkan` setelah mengubah filter.
- `Excel aging` mengekspor aging sesuai akses.
- Pilih satu Customer untuk menampilkan dan mengekspor Customer Statement.

## C. Membuat Credit Note dari retur

1. Sales/Warehouse menyelesaikan proses dan penerimaan fisik retur.
2. Buka `Sales > Retur & Refund`, lalu pilih retur.
3. Pada Credit Note Draft, Finance memilih:
   - `Post Credit Note`: menjadi open credit tanpa alokasi otomatis;
   - `Post & Buat Invoice Pengganti`: post Credit Note, alokasikan maksimal ke
     residual Invoice sumber, dan buat satu Invoice Pengganti Draft secara
     atomik.

Plain `Post Credit Note` tidak otomatis refund, tidak otomatis menjadi Saldo
Customer, dan tidak otomatis menutup Invoice tertentu.

## D. Open Credit Customer

Buka `Finance > Open Credit Customer`. Halaman langsung menampilkan tagihan dan
kredit terbuka tanpa tabel aging di atasnya. Kolom `Aksi` bersifat kondisional.

### Kapan tombol muncul

- `Alokasikan`: baris `Kredit · CREDIT_NOTE` mempunyai residual dan Customer
  yang sama mempunyai Invoice Posted terbuka.
- `Refund`: baris `Kredit · CREDIT_NOTE` mempunyai residual.
- `Jadi saldo`: syarat Refund terpenuhi dan kebijakan Customer Balance berstatus
  `ACTIVE`.
- `Pakai saldo`: baris `Tagihan · INVOICE` mempunyai residual dan Customer
  mempunyai saldo tersedia.
- `Reversal`: operasi eligible, belum direversal, dan user mempunyai capability
  POST.

Jika kartu `Kredit terbuka` bernilai Rp0, tombol Alokasikan/Refund memang tidak
muncul. Baris Invoice dengan Saldo Rp0 juga tidak menampilkan `Pakai saldo`.

### Alokasikan Credit Note

1. Klik `Alokasikan` pada baris Credit Note.
2. Pilih Invoice Customer yang sama.
3. Isi tanggal efektif dan nominal.
4. Klik `Konfirmasi`.

Allocation mengurangi residual Credit Note dan outstanding Invoice tanpa jurnal
baru karena jurnal sumber sudah ada.

### Refund Cash/Bank

1. Klik `Refund`.
2. Pilih metode Kas/Bank.
3. Isi tanggal, nominal, referensi, dan bukti sesuai metode.
4. Klik `Konfirmasi`.

Refund tidak boleh melebihi residual open credit dan menghasilkan jurnal refund
AR-native dengan lineage Credit Note.

### Jadi Saldo Customer

1. Klik `Jadi saldo`.
2. Isi tanggal, nominal, dan alasan.
3. Klik `Konfirmasi`.

Tombol tidak tersedia saat policy Customer Balance tidak aktif. Konversi
memindahkan open credit ke liability Saldo Customer; tidak mengubah SO atau
Invoice Draft.

### Pakai Saldo Customer

1. Invoice harus sudah Posted.
2. Klik `Pakai saldo` pada baris Invoice.
3. Isi tanggal, nominal, dan alasan.
4. Klik `Konfirmasi`.

Nominal maksimal adalah nilai terkecil antara saldo dan outstanding. Saldo
tidak dapat dipakai pada SO atau Invoice Draft.

### Reversal

1. Cari operasi pada `Riwayat tindakan open credit`.
2. Klik `Reversal`.
3. Isi tanggal dan alasan.
4. Klik `Konfirmasi`.

Reversal append-only: histori tidak dihapus dan residual dipulihkan sesuai
operasi asal. Operasi tidak dapat direversal dua kali.

## E. Invoice pengganti

1. Setelah `Post & Buat Invoice Pengganti`, buka `Sales > Invoice Penjualan`.
2. Cari Invoice Pengganti berstatus Draft.
3. Edit atau batalkan selama Draft; belum ada jurnal/stock effect.
4. Klik `Konfirmasi & Terbitkan` setelah benar.
5. Jika Credit Note masih mempunyai residual, buka `Open Credit Customer` dan
   alokasikan manual ke Invoice pengganti yang sudah Posted.

Pembayaran/DP Invoice lama tidak disalin ke Invoice pengganti.

## F. Batas yang wajib diketahui

- Tindakan manual Task 5 saat ini hanya berlaku untuk open credit jenis
  `CREDIT_NOTE`. Receipt open credit akibat kelebihan pembayaran tercatat dan
  terlihat, tetapi belum mempunyai tombol Apply/Refund/Convert yang setara.
- Cross-Customer, cross-Company, over-allocation, future Company date, stale
  residual/version, duplicate/changed retry, dan policy tidak aktif ditolak
  server.
- POS Retail, Stock, Reservation, FIFO/HPP, dan jurnal historis tidak berubah
  karena pemisahan halaman.

## G. Smoke setelah deployment

1. Login sebagai user Finance KMS/LSM/SMS.
2. Pastikan dua menu tampil.
3. Pastikan `Penerimaan Customer` tidak lagi memuat Open-item di bawah aging.
4. Pastikan `Open Credit Customer` langsung menampilkan tabel open item.
5. Pada Company dengan kredit Rp0, pastikan kolom Aksi kosong.
6. Gunakan satu Credit Note residual yang sah untuk memastikan tombol sesuai
   kondisi; jangan post transaksi Finance nyata hanya untuk smoke tanpa
   otorisasi bisnis.

