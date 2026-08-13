# G6 Corrective Phase 2 Journal Foundation Preflight

## Tujuan

Mengaudit live schema sebelum membuat fondasi Accounting Period dan jurnal
canonical. Database mempunyai object `accounting_periods` dan `journal_lines`
yang tidak boleh langsung dipercaya karena draft G6 pembuatnya ditolak dan
tidak tercatat pada migration ledger.

## Cara menjalankan

1. Jalankan seluruh file
   `supabase/diagnostics/g6_phase2_journal_foundation_preflight.sql` di Supabase
   SQL Editor.
2. Kirim seluruh output `check_name,status,details`.
3. Jangan menjalankan migration G6 lain sebelum output direview.

Jika preflight utama hanya menghasilkan `journal_line_legacy_header_collision`
dan `accounting_period_minimum_contract`, jalankan diagnostic fokus
`supabase/diagnostics/g6_phase2_period_journal_contract_resolution.sql` lalu
kirim seluruh output. Diagnostic kedua memastikan status/month boundary,
overlap, lifecycle, exact row count, constraint/index/policy, dan dependency
routine sebelum migration additive ditulis.

## Interpretasi

- `BLOCKER`: hentikan Phase 2 dan buat forward-fix spesifik live-state.
- `journal_line_legacy_header_collision=REVIEW`: `journal_lines` menunjuk tabel
  `journal_entries` legacy yang sebenarnya menyimpan baris jurnal, sehingga
  topology tersebut tidak boleh dipakai sebagai header/line canonical.
- `accounting_period_minimum_contract=SETUP`: object boleh dipertahankan hanya
  setelah kolom/constraint live dibandingkan dengan kontrak bulanan per Company.
- `canonical_additive_name_inventory=INFO`: nama additive disurvei agar fondasi
  baru tidak mengubah arti `journal_entries` legacy.
- `hold_event_mapping_inventory=INFO`: 26 event HOLD tidak diproses pada Phase 2;
  mapping/version resolution baru dibuka pada Corrective Phase 3.

Diagnostic ini SELECT-only, tidak mengubah event, jurnal, period, privilege,
atau migration ledger.
