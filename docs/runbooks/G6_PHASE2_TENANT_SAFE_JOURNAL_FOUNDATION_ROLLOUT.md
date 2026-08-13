# G6 Corrective Phase 2 Tenant-Safe Journal Foundation

## Boundary

Migration ini mengadopsi `accounting_periods` valid dan membuat tabel additive
`finance_journals`, `finance_journal_lines`, serta `finance_journal_audit`.
Legacy `journal_entries` tidak diubah. Tabel rejected `journal_lines` wajib kosong
dan dikarantina dari browser. Tidak ada event HOLD yang diposting.

## Urutan manual

1. Jalankan migration
   `supabase/migrations/20260810180000_g6_phase2_tenant_safe_journal_foundation.sql`.
2. Jalankan
   `supabase/diagnostics/g6_phase2_tenant_safe_journal_postflight.sql`.
   Seluruh status non-INFO wajib `PASS`.
3. Jalankan
   `supabase/tests/g6_phase2_tenant_safe_journal_tests.sql`.
   Harus muncul notice `TEST PASSED`; seluruh fixture di-rollback.
4. Rerun postflight Phase 2 dan G6 Phase 1 preflight sebagai regression.

## Kontrak

- Period bulanan tenant-scoped; Finance dapat lock, hanya Owner/Admin dapat
  reopen dengan alasan dan optimistic version.
- Period tidak dapat dilock selama ada Draft jurnal atau event belum POSTED.
- Jurnal canonical harus mulai Draft, memakai akun aktif/postable milik Company
  yang sama, minimal dua baris, Debit=Credit, dan period OPEN/REOPENED.
- Posted journal/line dan audit immutable; correction nanti memakai reversal
  append-only.
- Browser hanya membaca melalui RLS; mutation tabel tetap server-only.
- Phase ini belum menyediakan posting engine event, mapping resolver, report,
  manual-journal UI, atau memproses historical HOLD.

## Forward-fix

Jika guard menemukan period invalid, target table sudah ada, atau rejected
`journal_lines` berisi data, hentikan. Jangan drop/truncate/edit migration;
buat diagnostic dan forward-fix berdasarkan live-state.
