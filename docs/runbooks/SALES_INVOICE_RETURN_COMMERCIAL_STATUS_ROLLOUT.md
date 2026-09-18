# Sales Invoice Return Commercial Status Rollout

Status: `LOCAL READY`. Database rollout, client deployment, authenticated smoke,
dan UAT belum dilakukan.

## Tujuan dan batas perubahan

Invoice sumber tetap immutable dan tidak dihapus/dibatalkan hanya karena Retur.
Daftar serta detail Invoice sekarang menampilkan status komersial turunan:

- `Aktif`: belum ada Retur aktif;
- `Retur diproses`: Retur sudah dibuat tetapi belum ada Credit Note posted;
- `Diretur sebagian`: nilai Credit Note posted masih di bawah total Invoice;
- `Diretur penuh`: nilai Credit Note posted sudah sama atau melebihi total Invoice;
- `Dibatalkan`: dokumen sumber memang canceled.

Perubahan hanya menambah read-model status dan penyajian UI. Tidak ada mutation
Invoice sumber, Retur, Credit Note, Refund, Payment, AR, Journal, Stock, FIFO,
Cashier Session, ataupun histori transaksi.

## Urutan manual

Jalankan masing-masing file penuh dan hentikan proses pada SQL error, `BLOCKER`,
atau `FAIL`:

1. [Preflight](../../supabase/diagnostics/sales_invoice_return_commercial_status_preflight.sql)
2. [Migration](../../supabase/migrations/20260918160000_sales_invoice_return_commercial_status.sql)
3. [Behavior test](../../supabase/tests/sales_invoice_return_commercial_status_behavior.sql)
4. [Postflight](../../supabase/diagnostics/sales_invoice_return_commercial_status_postflight.sql)
5. Deploy client setelah seluruh pemeriksaan non-`INFO` `PASS`.

Migration tidak boleh dijalankan ulang setelah ledger `20260918160000` terpasang.
Jika ditemukan masalah setelah install, gunakan forward-fix baru; jangan menghapus
atau menulis ulang Invoice/Retur/Credit Note historis.

## Authenticated smoke wajib

1. Buka Invoice Retail tanpa Retur dan pastikan status `Aktif`.
2. Buka Retur Retail yang belum mempunyai Credit Note posted dan pastikan status
   `Retur diproses`.
3. Buka Invoice dengan Retur parsial dan pastikan status `Diretur sebagian`.
4. Buka Invoice sumber Retur penuh pada daftar serta detail dan pastikan status
   `Diretur penuh`, bukan `Aktif`.
5. Ulangi butir 1-4 untuk Invoice Backoffice.
6. Pastikan filter tiap status menghasilkan dokumen yang sesuai.
7. Pastikan Invoice canceled tetap `Dibatalkan`, dan user Retail/Backoffice VIEW
   yang sah dapat membaca status hanya pada Company aktif.
8. Verifikasi nilai Invoice, Credit Note, Journal, AR, Stock, dan FIFO tidak
   berubah setelah membuka atau memuat ulang halaman.

## Rollback/forward-fix

Client aman di-rollback karena field status komersial bersifat additive dan API
memiliki fallback ketika RPC belum terpasang. Database tidak di-drop setelah
digunakan Production; koreksi berikutnya harus berupa migration forward-fix yang
menjaga ledger dan histori.
