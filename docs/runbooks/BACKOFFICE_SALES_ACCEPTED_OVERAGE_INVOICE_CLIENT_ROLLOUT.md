# Backoffice Sales Accepted-Overage Invoice Client — Step 4/6.5C2C

Status: **DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS ON ISOLATED
DEVELOPMENT; AUTHENTICATED SMOKE/UAT PENDING**. Target hanya isolated
Development `fkywtxucmyjvpwdiqpix`; production dan staging dilarang.

## Historical clone rehearsal — 2026-09-15

- Clone `idrufihckscppsyclmsu` only: unit 62 installed; preflight five PASS,
  initial/closing postflight six PASS each; rollback-only behavior nine scenarios
  PASS (source lineage, Qty Order zero, accepted qty, held remainder and detail).
- Preparation selects Auth-backed actor and sets Office mode under Company lock;
  marker cleared/root guard asserted before operational RPC. Runtime unchanged.
  Fixture uses synthetic resolved source, not physical receipt/UI smoke proof.
  Cross-tenant denial, stale-version, concurrency and visual UAT remain pending.
- Stop before unit 63: C3 test lacks Office setup and requires later ledger split
  `20260912137000`. No unit 63 SQL executed; audit gate before further migrations.
  Production/client untouched; progress 62/88 installed.

## Outcome

Accepted overage yang sudah `APPROVED + RESOLVED` muncul pada workspace Invoice
yang sudah ada sebagai line terpisah **Kelebihan barang**. User hanya dapat
mengubah Qty Invoice. Harga, diskon, dan pajak dibaca dari approval Sales dan
tidak dikirim sebagai input client. Detail, Print, dan PDF tetap memakai
template Invoice Company existing.

## Impact dan compatibility

- Direct: dua read-model Invoice existing, parser payload API, form/edit/detail,
  serta label line pada template existing.
- Tidak mengubah: Stock/FIFO, Reservation, DO/SJ, POS Retail, Payment, Finance
  posting, nomor Invoice, Company branding, dan data historis.
- Edit Draft mengidentifikasi line dengan pasangan `sourceKind` dan source ID;
  line overage tidak lagi dapat terbaca sebagai line SO normal.
- Rollback database adalah forward-fix yang mengembalikan definisi dua
  read-model dari migration `20260911150000`. Jangan menghapus column/counter
  C2A/C2B dan jangan menghapus Invoice yang sudah dibuat.

## Urutan manual wajib

Jalankan setiap file secara utuh di SQL Editor project Development:

1. [`preflight`](../../supabase/diagnostics/backoffice_sales_accepted_overage_invoice_client_preflight.sql)
2. [`migration`](../../supabase/migrations/20260912125000_backoffice_sales_accepted_overage_invoice_client.sql)
3. [`behavioral rollback-only`](../../supabase/tests/backoffice_sales_accepted_overage_invoice_client_behavior.sql)
4. [`postflight`](../../supabase/diagnostics/backoffice_sales_accepted_overage_invoice_client_postflight.sql)

Stop pada SQL error, `BLOCKER`, atau `FAIL`. `INFO` bukan bukti behavior.

## Authenticated smoke setelah seluruh SQL PASS

1. Buka SO selesai yang memiliki accepted overage `APPROVED + RESOLVED`.
2. Klik Buat Invoice; pastikan line `Kelebihan barang` tampil terpisah dengan
   Qty Order 0 dan Qty Diterima sebesar overage yang diterima.
3. Ubah hanya Qty, simpan Draft, buka kembali, lalu edit Qty lagi.
4. Pastikan harga/diskon/pajak line tersebut read-only dan berasal dari approval.
5. Posting partial Invoice, buat Invoice berikutnya, dan pastikan sisa Qty benar.
6. Print dan Download; pastikan memakai template/logo/setting Company existing
   dan label `Kelebihan barang` terbaca.
7. Uji stale version/retry, user Company lain, serta Invoice SO normal tanpa
   accepted overage.

Status baru boleh dinaikkan ke SMOKE/UAT PASS setelah langkah di atas dibuktikan.

## Evidence manual

Pada 2026-09-12 user mengonfirmasi migration, rollback-only behavioral test,
dan postflight seluruhnya PASS pada isolated Development. Agent tidak
menjalankan SQL dan production/staging tidak disentuh.
