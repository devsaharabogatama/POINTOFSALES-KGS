# G4 Phase 8 — Payment-Leg Identity Rollout

## Outcome

Foundation ini menambah identitas UUID stabil per payment leg, menormalkan
payload lama yang belum memiliki key, menolak key/metode ganda dalam satu Sale,
serta membawa identitas tersebut ke `sales_payments` dan receipt snapshot.

Perhitungan harga, discount, Tax, fee, surcharge, stock, FIFO, Sale, dan
Financial Event tidak berubah.

## Urutan Supabase

Jalankan:

1. `supabase/migrations/20260729150000_g4_phase8_payment_leg_identity.sql`;
2. `supabase/diagnostics/g4_phase8_payment_leg_identity_postflight.sql`;
3. `supabase/tests/g4_phase8_payment_leg_identity_tests.sql`.

Expected:

- seluruh 10 postflight check `PASS`;
- behavior notice:
  `TEST PASSED: payment-leg keys normalize, duplicate key/method is rejected, persisted identity is unique, and browser writes remain closed.`

Fixture note: Company sintetis hanya diprovision satu metode Cash mandatory.
Behavior test terbaru membuat metode kedua `CUSTOM` secara rollback-only;
test tidak lagi bergantung pada master Payment Method milik user.

Lalu regression:

1. `supabase/tests/g4_phase6_sale_draft_edit_lock_tests.sql`;
2. `supabase/tests/g4_phase5_cashier_pricelist_override_tests.sql`;
3. `supabase/tests/g4_phase4_atomic_sale_runtime_tests.sql`;
4. `supabase/tests/g1_security_closure_tests.sql`.

## Compatibility

- signature public Save/Post tidak berubah;
- client lama yang belum mengirim `clientPaymentKey` mendapat UUID dari server;
- client Split Payment berikutnya wajib mempertahankan key yang sama selama
  edit/retry;
- technical backfill hanya menambahkan identity pada payload/payment/receipt
  existing dan tidak mengubah nilai atau status dokumen;
- direct browser write ke `sales_payments` tetap tertutup.

## Rollback dan Forward Fix

Migration berjalan dalam satu transaction; error sebelum `COMMIT` merollback
seluruh perubahan. Setelah applied, jangan menghapus kolom/key atau mengedit
migration ini. Masalah diselesaikan dengan forward migration karena identity
sudah dapat direferensikan receipt dan audit/runtime berikutnya.

## Boundary

Migration ini belum menambahkan UI Split Payment. PWA multi-leg baru dibuat
setelah migration, 10-check postflight, behavior, dan regression lulus.
Offline queue, Customer Balance, Ketul Offset, settlement, dan refund tetap
belum dibuka.
