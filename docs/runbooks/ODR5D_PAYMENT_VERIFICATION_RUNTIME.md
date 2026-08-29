# ODR-5D Payment Verification Runtime

Status dokumen: siap untuk rollout manual Supabase setelah ODR-5D preflight lulus.

## Tujuan

Fase ini menangkap payment intent dari Sales Order yang dikonfirmasi, mencatat
kas fisik tepat satu kali, dan memberikan Finance workflow maker-checker untuk
verifikasi atau penolakan. Verifikasi menciptakan satu Financial Event `HOLD`;
jurnal hanya dibuat melalui controlled Finance posting queue.

## Urutan eksekusi

1. Jalankan `supabase/diagnostics/odr_phase5d_payment_verification_runtime_preflight.sql`.
2. Pastikan tidak ada `BLOCKER` atau `FAIL`.
3. Jalankan `supabase/migrations/20260828240000_odr_phase5d_payment_verification_runtime.sql`.
4. Jalankan `supabase/tests/odr_phase5d_payment_verification_runtime_behavior.sql`.
5. Jalankan `supabase/tests/odr_phase5d_payment_verification_runtime_postflight.sql`.
6. Kirim seluruh hasil behavioral dan postflight sebelum ODR-5E dijalankan.

## Batas aman sementara

- Posting mode tetap `CONTROLLED`; `AUTOMATIC` masih ditolak.
- Payment `CUSTOMER_BALANCE` dan `KETUL_OFFSET` tidak dialihkan menjadi
  Kas/Bank/Advance karena keduanya memiliki ledger liability tersendiri.
- Payment yang diverifikasi sebelum Dispatch masuk ke Customer Advance.
  Dispatch order tersebut sengaja diblok sampai ODR-5E memasang aplikasi
  advance secara proporsional dan idempotent.
- Dispatch dengan payment surcharge aktif juga diblok sampai ODR-5E membawa
  snapshot surcharge ke commercial Dispatch effect; ini mencegah pendapatan
  surcharge hilang pada boundary rollout.
- Transaksi dan jurnal legacy tidak diubah.

## Ekspektasi hasil

Behavioral test mengembalikan satu baris `PASS`. Postflight hanya boleh berisi
`PASS` dan `INFO`; setiap `FAIL` harus diperbaiki sebelum melanjutkan.
