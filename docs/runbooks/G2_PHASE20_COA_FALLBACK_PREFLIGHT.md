# G2 Phase 20 — Guarded COA dan Company Fallback Preflight

## Tujuan

Audit SELECT-only sebelum membuka mutation COA dan explicit Company fallback.
Audit menentukan apakah akun existing aman diedit/versioned, apakah hierarchy
valid, serta berapa required function yang belum memiliki Transaction Rule atau
Company fallback.

Fase ini tidak mengubah akun, mapping, fallback, event, atau jurnal.

## Cara Menjalankan

Jalankan seluruh file berikut di Supabase SQL Editor:

```text
supabase/diagnostics/g2_phase20_coa_fallback_preflight.sql
```

Kirim seluruh hasil `check_name`, `status`, dan `details` sebelum migration
phase 20 ditulis.

## Interpretasi

- `BLOCKER`: jangan lanjut; integrity/schema existing harus diperbaiki dahulu.
- `REVIEW`: normal-balance override harus dikonfirmasi sebagai keputusan
  Finance, bukan dinormalisasi otomatis.
- `BACKFILL`: expected bila Category/Account Function belum dipetakan. Angka ini
  menjadi scope konfigurasi, bukan izin untuk menebak akun.
- `INFO`: inventory dan privilege boundary.

`required_function_without_compatible_account` wajib `PASS`. Jika gagal,
Company belum memiliki kandidat akun dengan account type yang legal.

`required_category_function_resolution_scope` boleh `BACKFILL`; future UI/RPC
akan meminta Finance memilih akun secara eksplisit. Jangan membuat pasangan
akun otomatis berdasarkan kode template.

## Boundary Berikutnya

Jika tidak ada `BLOCKER`, phase implementasi dapat menambahkan:

- guarded add/edit/lifecycle COA dengan optimistic version dan audit;
- hierarchy maksimal tiga tingkat serta postable-leaf guard;
- versioned/effective Company fallback RPC;
- user-facing UI berdasarkan nama akun/fungsi;
- regression test untuk history lock dan cross-Company reference.

Automatic journal, resolver enforcement, accounting period, dan posting worker
tetap tidak aktif.
