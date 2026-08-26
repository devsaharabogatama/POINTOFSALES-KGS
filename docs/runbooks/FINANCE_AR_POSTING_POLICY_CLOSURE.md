# F4B Finance Posting Policy dan AR Closure

Status: **database closure PASS; 40 event mempunyai 40 jurnal, HOLD dan
posting exception nol; authenticated smoke masih manual**.

F4A migration, forward-fix, postflight, dan behavioral test sudah dikonfirmasi
user sukses. F4B adalah fase terakhir pada penyelesaian Finance AR/periode.

Jalankan
[`finance_ar_posting_policy_closure_preflight.sql`](../../supabase/diagnostics/finance_ar_posting_policy_closure_preflight.sql)
dan kirim seluruh output.

Hasil preflight live:

- 31 event sudah mempunyai jurnal canonical dan tidak ada coverage/balance gap;
- 9 event masih `HOLD` dan menjadi backlog controlled queue;
- 1 event `CANCELED` sengaja tidak diposting;
- seluruh 5 Company tetap `CONTROLLED`;
- tidak ada active queue atau posting exception.

Target runtime:

- `CONTROLLED` tetap default dan mempertahankan preview → approve → process;
- `AUTOMATIC` hanya memproses event final yang sudah didukung canonical
  dispatcher, tanpa direct browser write;
- kegagalan posting tidak membatalkan finalitas dokumen sumber, tidak membuat
  jurnal parsial, dan tetap retryable dengan exception yang dapat ditelusuri;
- perubahan policy versioned/audited dan hanya dapat dilakukan authority
  Finance period yang disetujui;
- regression menutup Customer Receipt, AR outstanding/statement, period lock,
  event/journal identity, balance, retry, dan lintas Company.

Preflight tidak mengubah policy, event, queue, journal, receipt, Sale, saldo,
atau Accounting Period.

## Urutan rollout

1. Jalankan migration
   [`20260827140000_finance_posting_policy_closure.sql`](../../supabase/migrations/20260827140000_finance_posting_policy_closure.sql).
   Migration memasang runtime dan **tidak memposting 9 event HOLD**.
2. Jalankan
   [`finance_posting_policy_closure_postflight.sql`](../../supabase/diagnostics/finance_posting_policy_closure_postflight.sql).
   `supported_hold_backfill_scope=BACKFILL` masih benar pada tahap ini;
   seluruh check lain harus `PASS/INFO`.
3. Jalankan
   [`finance_posting_policy_closure_behavioral_test.sql`](../../supabase/tests/finance_posting_policy_closure_behavioral_test.sql).
   Test memilih Owner/Admin existing, mencoba transisi policy dan preview satu
   event, lalu me-rollback seluruh write.
4. Buka Backoffice `Finance -> Posting Queue`. Dalam mode `Controlled`, buat
   preview, periksa seluruh event, setujui, lalu proses. Queue sekarang memakai
   scope `ALL_SUPPORTED`, bukan hanya Stok Awal.
5. Jalankan ulang postflight. `supported_hold_backfill_scope` harus berubah
   menjadi `PASS` dengan `eventCount=0`, tidak boleh ada exception terbuka,
   duplicate journal, atau jurnal tidak balance.
6. Smoke test mode `Otomatis` hanya setelah backlog bersih. Owner/Admin dapat
   mengubah policy; Finance dengan capability `POST` dapat menekan `Proses
   backlog` untuk retry event lama. Event baru diproses oleh deferred trigger
   setelah source final; kegagalan mempertahankan event `HOLD` dan membuat
   exception tanpa membatalkan finalitas dokumen sumber.

## Temuan controlled closure

Queue live KGS pertama selesai dengan 8 POSTED dan 1 FAILED. Event gagal adalah
Sale TEMPO unpaid Rp133.500 dengan source/event nominal yang konsisten, tetapi
runtime lama belum membuat debit `CUSTOMER_RECEIVABLE`. Ikuti
[`FINANCE_TEMPO_SALE_POSTING_FORWARD_FIX.md`](FINANCE_TEMPO_SALE_POSTING_FORWARD_FIX.md),
lalu retry satu event melalui queue baru. Queue lama tetap dipertahankan sebagai
audit `COMPLETED_WITH_ERRORS`. Mode otomatis belum boleh diaktifkan.

Forward-fix dan controlled retry selanjutnya dikonfirmasi PASS. Final F4B dan
TEMPO postflight menunjukkan 40 event/jurnal, satu TEMPO receivable coverage,
HOLD nol, exception nol, serta tidak ada duplicate atau journal imbalance.
Mode otomatis baru boleh diuji secara terbatas pada Company dummy.

## Batas kompatibilitas dan rollback

- `CONTROLLED` tetap default dan seluruh Company existing tetap berada pada
  mode tersebut setelah migration.
- Event `CANCELED` tidak pernah masuk queue maupun automatic processor.
- Jurnal final tetap immutable dan satu event hanya boleh mempunyai satu
  jurnal canonical.
- Jika smoke otomatis bermasalah, kembalikan policy Company ke `Controlled`;
  jangan menghapus event/jurnal. Perbaiki mapping/period lalu retry event HOLD.
- Setelah migration dipakai membuat jurnal baru, rollback schema tidak aman;
  gunakan forward-fix dan pertahankan audit/event/journal.
