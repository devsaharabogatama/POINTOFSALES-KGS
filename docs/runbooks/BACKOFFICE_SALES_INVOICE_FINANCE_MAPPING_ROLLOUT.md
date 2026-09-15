# Backoffice Sales Invoice Finance Mapping Rollout

Status: DATABASE LIVE + MANUAL POSTFLIGHT/BEHAVIOR PASS menurut eksekusi user.
Target hanya isolated Development Supabase
`fkywtxucmyjvpwdiqpix`; production dan staging tidak boleh digunakan.

## Outcome dan batas gate

Gate `20260909160000` menyediakan dua identitas Finance terpisah:

- `BACKOFFICE_SALES_INVOICE` untuk Regular Invoice;
- `BACKOFFICE_SALES_DOWN_PAYMENT` untuk Down Payment Invoice.

Migration membuat Transaction Category, account rules, approved posting-rule
definition, dan audit untuk setiap Company aktif. Akun tidak dibuat atau
ditebak: resolver reuse mengikuti precedence nyata `SALE_POSTED`, lalu
`SALE_DISPATCHED`, Company fallback, lalu satu system account yang kompatibel.
Missing atau ambigu memblokir migration secara atomik.

Gate ini belum membuat runtime Post Invoice, Financial Event, Journal, AR
schedule mutation, DP application final, Payment, Stock/FIFO, atau perubahan
POS/UI. Definisi yang disiapkan adalah:

- Regular: debit Customer Receivable; debit Customer Advance Liability bila DP
  diterapkan; credit Sales Revenue; credit sisa Output Tax;
- DP: debit Customer Receivable; credit Customer Advance Liability; credit
  Output Tax proporsional.

Saat posting dibuat pada gate berikutnya, Output Tax wajib memakai
`tax_account_id` immutable per tax group dari `159000`. Mapping generic
`OUTPUT_TAX` pada gate ini hanya membuktikan kesiapan katalog/resolver dan tidak
boleh dipakai untuk menggabungkan kelompok pajak secara diam-diam.

## Impact map

- Direct: `system_events`, `transaction_categories`,
  `transaction_account_rules`, `finance_master_audit`, `posting_rule_sets`,
  `posting_rule_lines`, dan `posting_rule_set_audit`.
- Downstream: dispatcher canonical baru dapat mengenali definisi ini setelah
  runtime posting terpisah dibuat; pada gate ini belum ada pemanggil baru.
- Tidak terdampak: POS retail, Reservation, DO, Customer receipt, Stock,
  Transit, FIFO/COGS, Payment, Invoice Draft nominal/status, dan Finance Event/
  Journal existing.
- Compatibility: mapping kategori baru efektif untuk seluruh tanggal bisnis,
  sehingga Draft Invoice historis tidak gagal hanya karena dibuat sebelum waktu
  migration. Existing event/category/rule dengan identitas sama menjadi
  blocker, bukan ditimpa.
- Concurrency/retry: migration memakai satu transaksi dan hanya boleh dipasang
  sekali menurut ledger. Runtime mutation belum dibuka.

## Urutan manual

Jalankan satu per satu pada project Development tersebut:

1. `supabase/diagnostics/backoffice_sales_invoice_finance_mapping_preflight.sql`
2. `supabase/migrations/20260909160000_backoffice_sales_invoice_finance_mapping.sql`
3. `supabase/diagnostics/backoffice_sales_invoice_finance_mapping_postflight.sql`
4. `supabase/tests/backoffice_sales_invoice_finance_mapping_behavior.sql`
5. `supabase/diagnostics/backoffice_sales_invoice_finance_mapping_postflight.sql`

Stop bila preflight memiliki `BLOCKER`, postflight memiliki `FAIL`, atau ada SQL
error. Kirim seluruh output, bukan hanya satu row.

## Behavioral coverage

Behavior test memakai Company, Store, Super Admin, dan dua Category yang benar-
benar dibuat migration. Test membuat dua Financial Event `READY` sementara,
memanggil resolver Finance canonical untuk AR/Revenue/Advance/Output Tax,
memeriksa account compatibility, memastikan tidak ada Journal, lalu me-rollback
seluruh fixture. Test tidak memilih Product, Invoice, atau Tax fixture yang tidak
disiapkan oleh gate ini.

## Rollback / forward-fix

- Error saat migration membuat seluruh transaksi rollback; tidak ada config
  parsial.
- Setelah migration sukses, jangan menghapus Category/rule/audit secara manual.
  Karena audit dan mapping sudah terbentuk, koreksi harus melalui migration
  forward-fix yang meretire versi lama dan membuat versi baru.
- Walaupun postflight dan behavior PASS, status baru `DATABASE LIVE` pada
  isolated Development. `CLIENT DEPLOYED`, authenticated posting smoke, dan UAT
  belum berlaku karena runtime posting memang belum dibuat.

## Next gate

Lima langkah telah dilaporkan PASS oleh user. Runtime Post Invoice atomik yang
memvalidasi open Accounting Period, tax breakdown per account, DP allocation,
balance debit-credit, exact retry, stale version, dan source reconciliation
disiapkan terpisah pada gate `20260909161000`.
