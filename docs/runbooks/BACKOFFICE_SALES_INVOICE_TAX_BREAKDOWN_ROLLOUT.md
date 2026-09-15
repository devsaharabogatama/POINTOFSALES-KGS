# Backoffice Sales Invoice Tax Breakdown Rollout

Status: DATABASE LIVE + POSTFLIGHT/BEHAVIOR PASS menurut eksekusi manual user
pada isolated Development Supabase `fkywtxucmyjvpwdiqpix`.

## Keputusan yang dikunci

- DP tetap ditampilkan sebagai satu total kepada user.
- Backend menyimpan pembagian DPP/pajak proporsional per tax rule, versi, tarif,
  dan akun pajak.
- Posting pada periode `invoice_date` tertutup kelak wajib diblokir; tidak boleh
  menggeser accounting date diam-diam.

## Dampak

- Migration menambah satu relation RLS tanpa privilege browser:
  `backoffice_sales_invoice_tax_breakdowns`.
- Save/Edit Draft Regular dan DP otomatis membangun ulang tax breakdown melalui
  trigger setelah kalkulasi canonical selesai.
- Draft/Canceled existing, bila ada, dibackfill dari snapshot Invoice/SO yang
  sudah tersimpan. Posted/Reversed existing memblokir migration.
- Snapshot reader Invoice menambahkan `taxBreakdowns` tanpa menghapus field lama.
- Tidak ada perubahan nominal, nomor/status Invoice, quantity hold, DP
  application, schedule, SO, Customer receipt, Stock/FIFO, Event, Journal, POS,
  atau production.

## Urutan manual

Jalankan satu per satu pada project Development tersebut:

1. `supabase/diagnostics/backoffice_sales_invoice_tax_breakdown_preflight.sql`
2. `supabase/migrations/20260909159000_backoffice_sales_invoice_tax_breakdown.sql`
3. `supabase/diagnostics/backoffice_sales_invoice_tax_breakdown_postflight.sql`
4. `supabase/tests/backoffice_sales_invoice_tax_breakdown_behavior.sql`
5. `supabase/diagnostics/backoffice_sales_invoice_tax_breakdown_postflight.sql`

Stop pada `BLOCKER`, `FAIL`, atau SQL error dan kirim seluruh output.

## Behavioral coverage

Test rollback-only memakai satu Product/UOM canonical yang preparation-nya sama
dengan behavioral Draft `157000`, lalu membuktikan:

- DP dan Regular Invoice menyimpan persisted tax breakdown canonical;
- rumus residual rounding dua kelompok menghasilkan total yang persis;
- total breakdown sama dengan `invoice.tax_total`;
- histori tax breakdown Invoice canceled immutable;
- tidak tercipta Financial Event atau Journal;
- seluruh fixture di-rollback.

Test tidak lagi mensyaratkan Company memiliki dua Product aktif. Authenticated
multi-product/multi-tax UI smoke tetap menjadi gate integrasi sebelum deploy.

## Forward-fix / rollback

Belum ada posting atau data Finance yang dibuat. Sebelum dipakai production,
rollback logis adalah menghentikan rollout sebelum gate posting. Setelah Draft
memakai relation baru, jangan drop table/function; gunakan forward-fix additive
agar snapshot audit tetap terjaga.

## Next safe step

Seluruh gate sudah dilaporkan PASS. Finance mapping khusus Regular Invoice dan
DP menjadi next gate; runtime posting tetap gate terpisah dan harus memblokir
periode tertutup.
