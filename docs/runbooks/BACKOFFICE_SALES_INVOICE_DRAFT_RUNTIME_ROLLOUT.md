# Backoffice Sales Invoice Draft Runtime Rollout

Status: **LOCAL READY; MANUAL DEVELOPMENT DATABASE ROLLOUT PENDING**  
Target: isolated Development `fkywtxucmyjvpwdiqpix` only.

## Outcome

Gate `20260909157000` membuka Create/Edit/Cancel Draft Regular dan Down Payment
Invoice melalui RPC guarded. DP persentase dihitung dari DPP Sales Order;
pajaknya mengikuti proporsi yang sama. Regular Draft hanya boleh memegang
`Qty To Invoice` yang sudah berasal dari penerimaan Customer.

Gate ini belum mem-posting Invoice. Tidak ada AR, Revenue, Tax payable,
Payment, Financial Event, Journal, Stock Movement, FIFO, atau perubahan POS.

## Impact map

- Direct: satu operation ledger RLS, satu sequence Draft private, helper/RPC
  Draft, dua kolom split aplikasi DP, dan koreksi precision constraint line.
- Downstream yang sengaja belum aktif: posting Invoice dan aplikasi DP ke final
  Invoice.
- Compatibility: tabel POS dan Invoice snapshot retail tidak diubah; SO lama
  tidak dibackfill; foundation harus masih kosong sebelum migration.
- Concurrency: operation ID mengunci exact retry; lock per SO mengurutkan nomor,
  kapasitas DP, dan quantity hold; line SO dikunci sebelum allocation.
- Rollback: sebelum ada data runtime migration dapat dibatalkan terkontrol.
  Setelah Draft dibuat, gunakan forward-fix; jangan drop tabel/fungsi.

## Kontrak payload

`save_backoffice_sales_invoice_draft(invoice_id, expected_version,
operation_id, sales_order_id, payload)`:

- `invoiceType`: `REGULAR` atau `DOWN_PAYMENT`;
- `invoiceDate`: tanggal Draft;
- `paymentTermId`: nullable;
- DP: `downPaymentMode=PERCENT|FIXED`, `downPaymentInput` adalah nilai DPP;
- Regular lines: `salesOrderLineId`, `quantityUom`, optional `unitPrice`,
  `discountAmount`, dan `taxApplied`;
- harga input merupakan harga tampilan termasuk pajak. Server memisahkan DPP
  dan pajak menggunakan snapshot tax canonical SO.

Edit wajib membawa `masterVersion` terbaru. Cancel menggunakan RPC terpisah,
memerlukan alasan, dan melepaskan hold tanpa menghapus histori.

## Urutan manual

Jalankan satu file per query pada SQL Editor project Development:

1. Pastikan preflight `backoffice_sales_invoice_draft_runtime_preflight.sql`
   terakhir seluruhnya PASS.
2. `supabase/migrations/20260909157000_backoffice_sales_invoice_draft_runtime.sql`
3. `supabase/diagnostics/backoffice_sales_invoice_draft_runtime_postflight.sql`
4. Stop bila ada `FAIL` atau SQL error dan kirim output lengkap.
5. `supabase/tests/backoffice_sales_invoice_draft_runtime_behavior.sql`
6. Jalankan postflight kembali dan kirim seluruh output.

### Forward-fix untuk database yang sudah memasang 157000

Behavioral pertama menemukan dua runtime memanggil `digest` tanpa schema,
sedangkan pgcrypto canonical Supabase berada pada `extensions.digest`. Karena
migration `157000` sudah terpasang, jangan menjalankan ulang migration tersebut.
Urutan koreksinya:

1. `supabase/diagnostics/backoffice_sales_invoice_draft_digest_fix_preflight.sql`
2. `supabase/migrations/20260909158000_backoffice_sales_invoice_draft_digest_fix.sql`
3. `supabase/diagnostics/backoffice_sales_invoice_draft_digest_fix_postflight.sql`
4. ulangi `supabase/tests/backoffice_sales_invoice_draft_runtime_behavior.sql`
5. ulangi postflight `157000` dan `158000`.

Forward-fix hanya schema-qualify pgcrypto pada Save/Cancel. Source migration
`157000` juga sudah dikoreksi untuk instalasi baru. Tidak ada perubahan payload,
flow bisnis, data, permission, Stock, Finance, Payment, atau POS.
Migration `158000` aman menjadi no-op terjaga pada fresh install yang source
`157000`-nya sudah qualified, lalu tetap mencatat urutan ledger migration.

Behavioral test memakai preparation SO canonical, Confirm canonical, Draft DP
20%, Payment Term 30/70, Regular quantity hold, over-allocation denial, edit,
stale-version denial, exact retry, cancel/release, dan zero Finance effect.
Seluruh fixture di-rollback.

## Stop condition dan next gate

Jangan membuat patch berdasarkan pesan terakhir saja bila test gagal. Kirim
error beserta context penuh agar call chain yang gagal diaudit ulang.

Setelah migration, behavior, postflight ulang, dan authenticated smoke PASS,
gate berikutnya adalah posting Invoice ke Revenue/Tax/AR serta aplikasi DP.
Posting tersebut harus period-aware, immutable, exact-retry, dan tidak boleh
mengubah Stock/COGS receipt yang sudah final.

Production dan staging tidak boleh disentuh.

Compatibility production belum dinyatakan PASS. Menjelang rollout dan hanya
setelah instruksi user, jalankan diagnostic read-only
`backoffice_sales_production_compatibility_preflight.sql`; diagnostic tersebut
sekarang mengaudit collision dan ledger chain sampai `20260909157000`.
