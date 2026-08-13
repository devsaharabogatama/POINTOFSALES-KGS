# G6 Corrective Phase 4 Single-Event Posting Preflight

## Tujuan

Mengaudit live-state sebelum engine posting satu Financial Event dibuat. Gate
ini memastikan event dapat di-lock dan diposting secara exact-idempotent ke
jurnal canonical yang balanced, tenant-safe, dan period-safe tanpa menebak akun
atau nominal.

Diagnostic ini belum menjalankan posting. Seluruh event `HOLD`, jurnal,
periode, mapping, dan exception queue tetap tidak berubah.

## Cara menjalankan

1. Buka Supabase SQL Editor.
2. Jalankan seluruh file
   `supabase/diagnostics/g6_phase4_single_event_posting_preflight.sql`.
3. Kirim seluruh output `check_name,status,details`, termasuk dua inventory
   JSON di bagian bawah.
4. Jangan menjalankan routine legacy, retry event, atau batch posting.

## Interpretasi

- `BLOCKER`: invariant live-state tidak aman; Phase 4 berhenti sampai diperbaiki.
- `BACKFILL`: rule expression yang disetujui atau periode postable belum cukup.
- `REVIEW`: event lama memerlukan kontrak prior-period adjustment.
- `SETUP`: routine atomic posting memang belum dibuat; expected sebelum
  migration Phase 4.
- `PASS`: invariant existing aman.
- `INFO`: inventory aggregate untuk desain resolver; bukan kegagalan.

`hold_event_approved_rule_set_scope=BACKFILL` expected bila Phase 3 baru
memasang model rule/account mapping tetapi belum mempunyai rule expression
`APPROVED`. Rule tersebut tidak boleh diisi dengan nominal default atau ekspresi
SQL bebas. Output `hold_event_source_contract_inventory` menjadi dasar whitelist
resolver per System Event.

`prior_period_adjustment_scope=REVIEW` tidak berarti event boleh diposting ke
periode terkunci. Phase 4 wajib menyimpan tanggal event asli lalu memakai
periode terbuka berikutnya dengan tipe `PRIOR_PERIOD_ADJUSTMENT` sesuai kontrak
approved.

## Boundary setelah output

Jika semua `BLOCKER` nol, output direview sebelum migration Phase 4 dibuat.
Migration berikutnya hanya boleh mencakup:

- resolver amount/condition berbasis whitelist per source contract;
- resolver account exact dari rule version/effective date;
- row lock Financial Event dan exact idempotency;
- validasi seluruh line debit/kredit sebelum journal ditulis;
- snapshot source version, rule, account, dan period;
- satu transaction: event menjadi `POSTED` hanya setelah jurnal lengkap;
- exception terkontrol tanpa partial journal.

Historical queue dan pemrosesan 26 event `HOLD` tetap Phase 5. Phase 4 hanya
membuktikan posting satu event melalui fixture rollback-safe.
