# Panduan Retur & Refund Penjualan Backoffice

Panduan ini digunakan ketika barang dari Sales Order Backoffice sudah diterima
Customer, kemudian sebagian atau seluruh barang dikembalikan.

## 1. Membuat Retur

1. Buka **Sales > Quotation & Sales Order**.
2. Buka Sales Order yang barangnya sudah diterima Customer.
3. Klik **Buat Retur**.
4. Isi alasan retur, catatan bila diperlukan, dan jumlah barang yang
   dikembalikan per produk.
5. Klik **Simpan Draft Retur**.
6. Periksa kembali datanya, kemudian klik **Ajukan**.

Jumlah retur tidak boleh melebihi jumlah barang yang sudah diterima Customer
dan belum pernah diretur sebelumnya.

## 2. Menyetujui Retur

Retur yang sudah diajukan harus disetujui oleh user yang mempunyai kewenangan,
seperti Sales Admin atau Finance.

1. Buka **Sales > Retur & Refund**.
2. Pilih dokumen dengan status **Menunggu persetujuan**.
3. Periksa Customer, Sales Order, produk, jumlah, dan alasan retur.
4. Klik **Setujui**.

Setelah disetujui, status berubah menjadi **Menunggu barang**.

## 3. Menerima Barang Retur

Proses fisik dilakukan oleh Gudang.

1. Buka **Inventory > Penerimaan Retur Customer**.
2. Pilih dokumen retur, kemudian klik **Terima**.
3. Isi tanggal penerimaan, jumlah barang yang benar-benar diterima, Gudang
   penerima, dan disposition setiap barang.
4. Pilih disposition:
   - **Masuk stok**: barang layak dan ditambahkan kembali ke stok Gudang.
   - **Dihancurkan**: barang tidak layak dan tidak ditambahkan ke stok.
5. Jika memilih **Dihancurkan**, catatan pemusnahan wajib diisi.
6. Klik **Post Penerimaan**.

Penerimaan boleh dilakukan sebagian. Sisa barang akan tetap menunggu
penerimaan berikutnya.

## 4. Memproses Koreksi Tagihan

Setelah barang diterima Gudang, Finance membuka kembali dokumen melalui
**Sales > Retur & Refund**.

Finance harus menentukan tujuan koreksi setiap barang:

- **Belum ditagih**: digunakan jika barang tersebut belum masuk Invoice.
- **Draft Invoice**: Draft Invoice akan disesuaikan. User tetap harus memeriksa
  dan mengonfirmasi ulang Invoice sebelum posting.
- **Posted Invoice**: sistem membuat Credit Note berdasarkan Invoice yang sudah
  diterbitkan.

Sistem tidak memilih Invoice secara otomatis. Finance harus memilih Invoice
sumber yang benar.

## 5. Memproses Credit Note

Jika Invoice sudah posted:

1. Buka Credit Note dari dokumen Retur & Refund.
2. Periksa tanggal Credit Note, nilai koreksi, koreksi ongkir jika diperlukan,
   dan alasan koreksi.
3. Klik **Simpan** jika ada perubahan.
4. Klik **Post Credit Note**.

Invoice asli tetap tersimpan dan tidak diubah. Credit Note menjadi dokumen
koreksi resmi yang terhubung ke Invoice dan dokumen retur.

## 6. Menentukan Apakah Ada Refund

Refund hanya dilakukan jika pembayaran Customer setelah Credit Note menjadi
lebih besar daripada tagihan yang seharusnya.

Contoh:

- Invoice Rp10.000.000, belum dibayar, Credit Note Rp3.000.000: piutang menjadi
  Rp7.000.000 dan tidak ada refund.
- Invoice Rp10.000.000, sudah dibayar Rp5.000.000, Credit Note Rp3.000.000:
  piutang menjadi Rp2.000.000 dan tidak ada refund.
- Invoice Rp10.000.000, sudah lunas, Credit Note Rp3.000.000: Customer berhak
  menerima refund Rp3.000.000.

## 7. Memproses Refund

Jika terdapat **Sisa Refund**:

1. Buka Credit Note yang sudah diposting.
2. Pilih metode refund.
3. Isi jumlah refund.
4. Klik **Post Refund**.

Refund dapat dilakukan sebagian atau sekaligus sampai lunas. Jumlah refund
tidak boleh melebihi sisa kewajiban refund.

Jika refund yang sudah diposting salah, jangan dihapus atau diedit. Gunakan
tombol **Reversal** dan isi alasan koreksi.

## Arti Status Retur & Refund

- **Draft**: Retur masih disusun.
- **Menunggu persetujuan**: Retur menunggu persetujuan.
- **Menunggu barang**: Retur disetujui dan menunggu barang dari Customer.
- **Diterima sebagian**: Baru sebagian barang yang diterima Gudang.
- **Menunggu koreksi tagihan**: Barang sudah diterima dan menunggu proses
  Finance.
- **Credit Note Draft**: Credit Note belum diposting.
- **Menunggu refund**: Ada kelebihan pembayaran yang harus dikembalikan.
- **Selesai**: Seluruh proses retur dan kewajiban refund sudah selesai.
- **Dibatalkan**: Pengajuan retur dibatalkan sebelum proses final.

## Catatan Penting

- Retur Backoffice tidak menggunakan kasir atau Cashier Session.
- Satu Sales Order dapat mempunyai beberapa retur parsial.
- Dokumen SO, Invoice, Credit Note, penerimaan, dan refund tetap tersimpan
  sebagai histori.
- Invoice yang sudah posted tidak boleh diedit atau dihapus.
- Hanya barang dengan disposition **Masuk stok** yang menambah stok Gudang.
- Refund tidak mengubah stok karena perubahan stok sudah dicatat saat Gudang
  memproses penerimaan retur.

