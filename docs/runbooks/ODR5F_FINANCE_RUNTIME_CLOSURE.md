# ODR-5F Finance Runtime Closure

## Urutan rollout

1. Jalankan migration
   `supabase/migrations/20260828260000_odr_phase5f_finance_runtime_closure.sql`.
2. Jalankan behavioral rollback
   `supabase/tests/odr_phase5f_finance_runtime_closure_behavior.sql`.
3. Jalankan SELECT-only postflight
   `supabase/tests/odr_phase5f_finance_runtime_closure_postflight.sql`.
4. Kirim seluruh output sebelum authenticated ODR-6 smoke/UI.

## Dampak

- Existing Company tetap memakai mode `CONTROLLED`.
- Switch `AUTOMATIC` baru boleh dipilih eksplisit setelah migration ini.
- Controlled queue dan automatic trigger memakai hasil posting/no-effect yang
  sama.
- Dispatch yang menggunakan advance tetap menunggu payment advance terposting.
- Migration tidak membuat Event, Journal, Payment, Dispatch, atau mengubah
  policy Company menjadi automatic.

Behavioral harus satu `PASS`; postflight hanya boleh `PASS` dan `INFO`.
