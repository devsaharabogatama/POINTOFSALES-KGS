# SLD-R4 Delivery Fee Return Preflight

## Tujuan

Membuktikan Sales Return existing aman sebelum ongkir dapat direfund secara
eksplisit. Partial Product Return tidak boleh otomatis mengembalikan ongkir.
Full remaining Return hanya boleh mengembalikan ongkir bila operator meminta
dan Manager/Admin menyetujuinya melalui POST Return.

## Eksekusi

Jalankan satu file berikut di Supabase SQL Editor:

`supabase/diagnostics/sld_r4_delivery_fee_return_preflight.sql`

File ini SELECT-only dan hanya mengeluarkan agregat.

## Interpretasi

- seluruh `BLOCKER` harus nol;
- `SETUP` untuk kolom/RPC/event snapshot adalah expected sebelum migration R4;
- `REVIEW` hanya boleh berasal dari full Return Delivery historis yang memang
  memerlukan keputusan manual;
- `BACKFILL` Draft terbuka harus direview sebelum migration menormalkan total;
- Finance `DEFERRED` expected karena posting expression Sale/Return tetap
  dikendalikan G6 dan tidak dibuka oleh SLD.

Kirim seluruh output sebelum migration R4 dibuat/dijalankan.
