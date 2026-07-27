# G2 Phase 14 — Payment Method Preflight

## Tujuan

Mengaudit kesiapan live database sebelum membuat master Payment Method canonical.
Audit ini tidak mengubah schema, data, checkout, settlement, reconciliation,
atau Finance posting.

Source of truth:

- `docs/PAYMENT_METHOD_MASTERDATA_SPEC.md`;
- G2 pada `docs/POS_V1_IMPLEMENTATION_GATES.md`;
- `docs/POS_V1_MVP_REQUIREMENT_INDEX.md`.

## Cara menjalankan

1. Buka Supabase SQL Editor.
2. Jalankan seluruh isi
   `supabase/diagnostics/g2_phase14_payment_method_preflight.sql`.
3. Kirim seluruh hasil `check_name,status,details`.

File bersifat `SELECT-only` dan aman dijalankan pada database live.

## Interpretasi

- `BLOCKER`: jangan menulis migration sebelum penyebabnya diselesaikan.
- `REVIEW`: ada histori `Customer_Balance`; ini tender internal dan tidak boleh
  otomatis dijadikan metode pembayaran operasional biasa.
- `BACKFILL`: expected bila Company aktif belum memiliki master canonical atau
  histori pembayaran lama perlu dipetakan dan disnapshot.
- `INFO`: inventory/schema gap, bukan kegagalan.
- `PASS`: invariant yang diaudit bersih.

Pada database tanpa histori pembayaran, hasil normal adalah:

- dependency phase 13 `PASS`;
- amount dan histori internal tender `PASS`;
- master canonical/snapshot masih `INFO`;
- Company aktif masuk `BACKFILL` karena perlu default Payment Method.

## Boundary fase ini

Preflight berikut hanya menyiapkan keputusan untuk master tenant-scoped:

- kode/nama/type/lifecycle Payment Method;
- availability semua Store atau Store tertentu;
- settlement route dan konfigurasi fee;
- versioning, audit, RLS, dan guarded mutation.

Checkout lama tetap menggunakan jalur yang ada sampai resolver Payment Method
dan atomic payment posting dikerjakan pada gate G4. Settlement aktual,
reconciliation, offline snapshot, serta Finance posting tidak dibuka di G2.
