# Backoffice Sales Invoice Client Activation

Historical-clone evidence 2026-09-15 (`idrufihckscppsyclmsu`, unit 47/88):
five preflight PASS; migration installed; eight-scenario behavioral PASS; six
closing postflight PASS. Preparation selects an Auth-backed actor and prepares
Office mode only inside outer rollback, clearing the setup marker before any
operational RPC. All five active Companies remain Retail afterward; Invoice
fixture rows zero. Runtime gates and historical rows are unchanged. This is
database rehearsal evidence, not client deployment, authenticated UI smoke,
UAT or final fresh-clone/Production compatibility approval.

Target saat ini hanya project Supabase development terisolasi `fkywtxucmyjvpwdiqpix`. Jangan jalankan pada production atau staging lama.

Status 2026-09-11: migration DATABASE LIVE pada isolated Development;
behavioral dan postflight dikonfirmasi PASS oleh user. Authenticated smoke/UAT
di bawah masih pending.

Urutan manual di SQL Editor, selalu jalankan satu file penuh:

1. `supabase/diagnostics/backoffice_sales_invoice_client_activation_preflight.sql`
2. `supabase/migrations/20260911150000_backoffice_sales_invoice_client_activation.sql`
3. `supabase/tests/backoffice_sales_invoice_client_activation_behavior.sql`
4. `supabase/diagnostics/backoffice_sales_invoice_client_activation_postflight.sql`

Setelah seluruh hasil PASS, jalankan Backoffice lokal lalu smoke test terautentikasi:

1. Buka SO berstatus Selesai dan klik **Buat Invoice**.
2. Ubah Qty Invoice menjadi kurang dari Qty Diterima, simpan Draft, lalu buka kembali.
3. Pastikan Invoice kedua hanya menawarkan sisa Qty To Invoice.
4. Pastikan Sales tanpa akses Finance tidak dapat menerbitkan Invoice.
5. Dengan role Finance berizin POST dan periode tanggal Invoice terbuka, klik **Konfirmasi & Terbitkan**.
6. Pastikan nomor `INV-...`, schedule piutang, Finance journal, serta tombol Print/Download tampil.
7. Pastikan Invoice final tidak dapat diedit; koreksi final tetap melalui Retur/Credit Note.
8. Pastikan halaman Quotation/SO hanya memiliki tab `Quotation` dan `Sales Order`;
   tidak ada daftar Invoice kedua di dalam halaman tersebut.
9. Buka menu existing `Invoice Penjualan`; pastikan Invoice Retail dan
   Backoffice muncul dalam daftar yang sama.
10. Print/Download satu Invoice Backoffice dan satu Surat Jalan Backoffice.
    Pastikan keduanya memakai logo/stempel/rekening/template tanda tangan dari
    pengaturan Company existing. Ubah satu setting di Company Development lalu
    pastikan output berikutnya mengikuti setting tersebut.

Behavioral test membuat tambahan Stock dan FIFO batch canonical hanya di dalam
transaksi `BEGIN`/`ROLLBACK`. Fixture ini sengaja tidak mensyaratkan Product
tanpa open negative allocation karena shortage operasional existing bukan
dependency Invoice client. Tidak ada Stock, batch, movement, Order, DO, receipt,
atau Invoice fixture yang bertahan setelah test selesai.

Rollback tidak disediakan sebagai DROP karena runtime dapat mulai memiliki Draft/final Invoice. Jika gate gagal setelah migration, gunakan forward-fix baru. Migration ini tidak mengubah data historis dan tidak menyentuh POS, Stock, DO, receipt, FIFO, atau production.
