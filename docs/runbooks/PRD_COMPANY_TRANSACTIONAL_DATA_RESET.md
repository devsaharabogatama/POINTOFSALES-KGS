# Reset Data Transaksi per Company

## Tujuan

Operasi ini membersihkan data transaksi/uji coba milik **satu Company** sebelum
pengisian opening balance dan trial operasional. Operasi tidak menghapus master
data, user, konfigurasi, atau data Company lain.

SQL yang digunakan:

[`supabase/operations/prd_reset_company_transactional_data.sql`](../../supabase/operations/prd_reset_company_transactional_data.sql)

Ini adalah controlled operation, bukan migration. Jangan memasukkannya ke rantai
migration dan jangan menjalankannya otomatis pada deployment.

## Yang dihapus

Semua row milik Company target pada kelompok berikut:

1. POS dan penjualan: sesi kasir, Sale header/detail/payment, alokasi FIFO dan
   Bundle, draft, audit transaksi, invoice snapshot, surat jalan, serta Sales
   Return/refund;
2. offline dan stok minus: submission/event/sync exception, stock allowance,
   payment exception, authorization dan alokasi stok minus;
3. inventory: saldo stok, FIFO batch, Stock Movement, Stok Awal, Transfer,
   Adjustment, dan Opname beserta line/alokasi/audit dokumennya;
4. purchase/AP: Stock Request, Supplier Order, Goods Receipt, Purchase Return,
   Supplier Invoice, Supplier Payment, allocation—including lineage request
   otomatis dari stok minus—tolerance result, audit, dan tabel purchase legacy;
5. expense/kas: Expense, pencairan, settlement, return, additional request,
   cash drawer/in, Setoran Kas, serta Deposit Variance;
6. saldo Customer: correction request, ledger, audit, dan cache
   `customers.current_balance` dikembalikan ke nol;
7. Finance runtime: Financial Event, jurnal canonical dan legacy, posting queue,
   posting exception, reconciliation, serta riwayat export laporan.

Snapshot harga pembelian terakhir pada relasi Product-Supplier dihapus karena
nilainya berasal dari Supplier Invoice yang ikut dibersihkan. Harga referensi
Supplier tetap dipertahankan.

## Yang dipertahankan

- Company, Store, Terminal POS, Gudang, user, membership, role, custom permission,
  active Company context, dan branding;
- UOM, kategori, Product, konversi UOM, Bundle, Supplier, Product-Supplier,
  Customer, kategori Customer, Pricelist, dan Payment Method;
- Tax, COA, Transaction Category, account mapping/fallback, posting rule,
  Accounting Period, serta definisi/template laporan Finance;
- Minimum Stock, alasan Adjustment, kebijakan Expense/Setoran/Saldo Customer,
  Offline, dan stok minus;
- histori/audit perubahan master dan histori Master Import;
- `private` schema, migration ledger, dan seluruh counter nomor dokumen.

Counter tidak di-reset agar nomor dokumen yang pernah terpakai tidak diterbitkan
ulang setelah go-live.

## Urutan menjalankan

1. Pastikan aplikasi Backoffice dan PWA tidak dipakai. Ambil backup database.
2. Buka SQL pada Supabase SQL Editor.
3. Isi `company_id` dan **nama Company persis** pada blok konfigurasi.
4. Biarkan `execute_reset = FALSE`, jalankan sebagai preview.
5. Pastikan result `kgs_reset_issues` kosong dan periksa seluruh
   `PREVIEW_DELETE`/`PREVIEW_RESET_DERIVED_CACHE`.
6. Jika sudah benar, ubah `execute_reset = TRUE` dan isi frasa:
   `I_UNDERSTAND_THIS_DELETES_TRANSACTION_DATA`.
7. Jalankan ulang satu kali. Mode hasil harus `EXECUTED` dan tidak boleh ada
   error. Semua perubahan berada dalam satu transaction; error apa pun memicu
   rollback.
8. Jalankan ulang dalam mode preview. Seluruh jumlah target dan derived cache
   harus nol.
9. Baru mulai import master yang belum ada, Stok Awal, dan opening Finance
   melalui workflow yang disetujui.

## Batasan dan rollback

Penghapusan ini permanen setelah `COMMIT`. Rollback setelah berhasil hanya dapat
dilakukan dengan restore backup/PITR. Karena itu preview, nama Company, UUID,
token konfirmasi, maintenance window, dan backup wajib diperiksa.

Script sengaja berhenti jika menemukan tabel `company_id` baru yang belum
diklasifikasikan atau target lama tanpa `company_id`. Jangan menghapus guard
tersebut; klasifikasikan schema baru terlebih dahulu.
