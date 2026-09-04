# Spesifikasi Revisi Sales Order Terkonfirmasi

Status dokumen: approved untuk implementasi additive. Fitur ini tidak mengubah
Invoice final atau Sales Order terkonfirmasi secara langsung.

## 1. Tujuan

Memberi Kasir cara memperbaiki salah barang, quantity, Customer, Pricelist,
pengiriman, atau pembayaran pada Order yang sudah dikonfirmasi tetapi belum
pernah dikirim. Koreksi dilakukan melalui Draft pengganti agar histori dan
identitas dokumen lama tetap dapat diaudit.

## 2. Batas kelayakan

Tombol **Revisi Order** hanya boleh aktif ketika seluruh kondisi berikut benar:

1. Order berada pada status `CONFIRMED` atau `RESERVED`;
2. Reservation masih `OPEN`;
3. jumlah Dispatch sama dengan nol;
4. tidak ada pembayaran berstatus `VERIFIED`;
5. Kasir mempunyai sesi `OPEN` pada Store Order yang sama; dan
6. Order belum mempunyai Draft revisi berstatus `PENDING`.

Order `PARTIALLY_DISPATCHED`, `DISPATCHED`, `DELIVERED`, atau yang sudah
memiliki pembayaran terverifikasi tidak boleh direvisi. Koreksinya tetap melalui
Return, refund, reversal, atau dokumen koreksi yang sesuai.

## 3. Alur operasional

1. Kasir membuka **Order aktif**, memilih Order, lalu menekan **Revisi Order**.
2. Kasir wajib mengisi alasan. Server membuat Draft baru dari snapshot Order
   sumber. Payment tidak disalin; Kasir wajib memeriksa dan mengisi ulang cara
   bayar. Harga dihitung ulang oleh resolver canonical ketika Draft dibuka.
3. Selama Draft pengganti belum dikonfirmasi, Order sumber, Reservation,
   Invoice, Surat Jalan, demand Purchasing, dan payment request lama tetap aktif.
4. Kasir dapat membatalkan Draft revisi. Tindakan ini hanya menandai revisi
   `ABANDONED`; Order sumber tidak berubah.
5. Saat **Konfirmasi Order**, server mengunci source dan replacement, memeriksa
   ulang version, status Dispatch, dan pembayaran, kemudian dalam satu transaksi:
   - membatalkan payment request lama yang masih dapat dibatalkan;
   - membatalkan Order sumber dan melepaskan Reserved Out;
   - membatalkan Surat Jalan lama secara terkontrol;
   - menyelaraskan demand Purchasing lama;
   - mengonfirmasi Draft pengganti melalui runtime canonical;
   - membuat Reservation, Invoice, Surat Jalan, demand, dan payment request baru;
   - menandai relasi revisi `APPLIED` serta menulis audit.
6. Jika satu langkah gagal, seluruh perubahan di langkah 5 di-rollback. Order
   sumber tetap aktif dan Draft revisi tetap dapat diperbaiki.

### Tanggal TEMPO pada revisi

- Draft pengganti mempertahankan tanggal bisnis Order sumber sampai Kasir
  mengubah field tanggal secara eksplisit. Untuk `SCHEDULED`, authority adalah
  `plannedOrderAt` yang tanggal lokalnya wajib sama dengan `planned_order_date`;
  untuk `IMMEDIATE` dan `BACKORDER`, authority adalah canonical header date.
- Identitas yang disalin mencakup resolved `transaction_date`, sumber tanggal,
  actor/waktu pemilih, `order_timing_mode`, planned-date metadata, dan
  `transactionAt` canonical pada payload agar save/resume tidak menggantinya
  dengan waktu Draft revisi dibuat.
- Setting template `ORDER_DATE` mencetak tanggal bisnis Order sumber pada
  Invoice pengganti. Setting `POSTED_DATE` tetap mencetak tanggal replacement
  benar-benar dikonfirmasi; perubahan tanggal pada mode ini adalah perilaku
  yang memang dipilih Company, bukan tanggal Order yang hilang.
- `created_at`, `posted_at`, nomor Invoice, dan nomor Surat Jalan milik
  replacement tetap baru. Timestamp lifecycle tersebut tidak boleh disalin
  dari source.
- Validasi "masa depan" membandingkan tanggal bisnis dalam timezone Company,
  bukan bagian jam dari timestamp. Jam yang lebih maju pada tanggal bisnis yang
  sama tidak boleh menggagalkan simpan atau konfirmasi revisi.
- Tanggal bisnis setelah hari ini tetap mengikuti kontrak Order TEMPO
  `SCHEDULED`; jatuh tempo dan rencana kirim tidak boleh lebih awal dari tanggal
  rencana Order.
- Backorder tetap memerlukan periode akuntansi yang terbuka. Perubahan ini tidak
  memberi Draft revisi kewenangan untuk membuat efek Stock atau Finance.

## 4. Identitas dan histori

- Invoice/SJ sumber tidak ditimpa atau dihapus; proyeksinya menjadi canceled
  dengan alasan revisi.
- Replacement mendapat nomor Order/Invoice/SJ baru dari sequence canonical.
- Relasi source-replacement bersifat tenant-scoped, versioned, exact-retry, dan
  dapat dibaca Backoffice untuk menjelaskan "Direvisi menjadi" / "Revisi dari".
- Detail Invoice Backoffice menampilkan nomor Invoice manusiawi sebagai tautan
  dua arah. Invoice sumber menampilkan **Buka Invoice Pengganti**, sedangkan
  Invoice pengganti menampilkan **Lihat Invoice Sebelumnya**. Pembatalan biasa
  tanpa relasi revisi tidak menampilkan tautan pengganti.
- Waktu dibuat, terakhir diperbarui, dikonfirmasi, revisi dimulai/diterapkan/
  dibatalkan, serta pembatalan Order dibaca dari timestamp server dan actor
  audit. UUID hanya menjadi identitas routing internal dan tidak ditampilkan.
- Satu source hanya boleh memiliki satu revisi `PENDING`.
- Satu replacement hanya boleh menjadi pengganti untuk satu source.

## 5. Kompatibilitas

- Flow Draft biasa dan Confirm biasa tetap melewati runtime lama tanpa cabang
  revisi.
- Stock On Hand, FIFO, Movement, Finance, dan Dispatch tidak berubah saat Draft
  revisi dibuat.
- Offline revision, revisi sesudah partial Dispatch, penggunaan ulang nomor
  Invoice lama, serta edit langsung snapshot final berada di luar scope.
- Tidak ada backfill terhadap Order historis.
- Forward-fix preservasi tanggal tidak mengubah Invoice source/replacement yang
  sudah final. Revisi `PENDING` yang berasal dari runtime lama dan mempunyai
  date identity berbeda wajib diselesaikan atau dibatalkan sebelum rollout,
  lalu dibuat ulang sesudah migration.
- Read model activity bersifat additive dan tidak membuat efek Stock, Payment,
  Financial Event, atau Journal.

## 6. Gate rilis

Urutan wajib: preflight SELECT-only, migration foundation, migration runtime,
contract test tanpa mutasi data bisnis, postflight, lint/build PWA dan Backoffice,
lalu authenticated smoke di staging. Hentikan rollout pada SQL error,
`BLOCKER`, atau `FAIL`. Production tidak boleh dimutasi oleh proses development.
