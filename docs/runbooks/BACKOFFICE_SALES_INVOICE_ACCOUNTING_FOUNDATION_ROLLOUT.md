# Backoffice Sales Invoice Accounting Foundation Rollout

Status: **DATABASE LIVE; POSTFLIGHT/BEHAVIOR PASS ON ISOLATED DEVELOPMENT**  
Target: isolated Development `fkywtxucmyjvpwdiqpix` only.

## Outcome

Gate `20260909156000` menyediakan foundation additive untuk pola Odoo pada
Backoffice Sales: Payment Terms dan installment; snapshot Pro-Forma
non-akuntansi; Draft Regular/Down Payment Invoice; quantity hold; aplikasi DP
sebagai deduction; jadwal piutang per Invoice; dan audit immutable.

Gate ini zero-backfill. Tidak ada RPC/UI dan tidak membuat Invoice runtime,
Payment, Financial Event, Journal, Stock Movement, FIFO, COGS, Revenue, Tax,
AR, atau perubahan POS retail.

## Kontrak yang dikunci

- Pro-Forma bukan permintaan pembayaran dan tidak membuat Finance effect.
- DP Invoice hanya berasal dari SO confirmed; runtime berikutnya boleh
  membuatnya sebelum Delivery selesai.
- Regular Invoice hanya boleh mengalokasikan `Qty To Invoice` hasil Customer
  receipt.
- Satu SO dapat memiliki beberapa Invoice; satu Invoice fase ini hanya dari
  satu SO.
- Payment Terms menghasilkan beberapa schedule dalam satu Invoice; pembayaran
  tidak menentukan produk.
- Draft hold, posting quantity, pelepasan Draft, total DP, schedule total,
  tenant, role, status, retry, dan stale version ditegakkan atomik pada runtime
  berikutnya. Foundation tidak membuka direct browser writes.

## Impact dan compatibility

- Direct: sembilan relation baru dan dua kolom Payment Term nullable pada SO.
- Existing SO mendapat `payment_term_id=NULL` dan snapshot `{}`; `due_date`
  existing tidak ditulis ulang.
- Receipt COGS `155000`, Qty To Invoice, Stock/FIFO, Finance queue, Invoice POS,
  Sales Return, dan payment existing tidak berubah.
- Semua relation baru RLS-enabled tanpa privilege langsung untuk
  `anon`/`authenticated`.
- Setelah ada runtime data jangan drop relation; rollback memakai forward-fix.

## Urutan manual

Jalankan satu file per query di SQL Editor project Development:

1. `supabase/diagnostics/backoffice_sales_invoice_accounting_foundation_preflight.sql`
2. Stop bila ada `BLOCKER` atau SQL error.
3. `supabase/migrations/20260909156000_backoffice_sales_invoice_accounting_foundation.sql`
4. `supabase/diagnostics/backoffice_sales_invoice_accounting_foundation_postflight.sql`
5. Pastikan seluruh check selain `INFO` adalah `PASS`.
6. `supabase/tests/backoffice_sales_invoice_accounting_foundation_behavior.sql`
7. Jalankan postflight lagi dan pastikan tetap `PASS`.

Behavior memakai preparation Quotation canonical yang sama dengan gate
sebelumnya. Ia menguji Payment Term 30/70, rejection persentase invalid,
identitas DP/Regular Draft, quantity hold, deduction DP, rekonsiliasi schedule,
zero Finance effect, lalu me-`ROLLBACK` seluruh fixture.

## Stop condition dan next gate

Stop pada SQL error, `BLOCKER`, atau `FAIL`; kirim output lengkap dan jangan
menjalankan patch susulan. Setelah PASS, next gate adalah runtime transactional
Create/Update/Cancel Draft Invoice dan DP dengan exact retry, stale-version,
cross-tenant denial, quantity/DP concurrency lock, dan tanpa posting Finance.

Production dan staging tidak boleh disentuh.
