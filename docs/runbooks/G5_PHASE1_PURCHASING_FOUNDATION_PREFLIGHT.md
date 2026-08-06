# G5 Phase 1 — Purchasing Foundation Preflight

## Tujuan

Membuktikan kesiapan data dan security boundary sebelum membuat flow:

```text
Stock Request POS
-> Supplier Order Store Manager
-> Goods Receipt Kasir
-> AP Provisional / Supplier Invoice Finance
-> Purchase Return
```

Phase ini hanya diagnostic SELECT. Tidak membuat dokumen, stock, FIFO,
Financial Event, atau perubahan privilege.

## File

Jalankan seluruh isi:

`supabase/diagnostics/g5_phase1_purchasing_foundation_preflight.sql`

melalui Supabase SQL Editor, lalu kirim semua row `check_name,status,details`.

## Interpretasi

- `BLOCKER` harus nol sebelum desain migration Request/Order dibuat.
- `REVIEW` harus dijelaskan dan mempunyai compatibility/backfill plan.
- `BACKFILL` menunjukkan data legacy yang wajib dipetakan secara eksplisit.
- `SETUP` pada canonical Request/Order table dan routine adalah expected pada
  baseline pertama.
- `INFO` adalah inventory, bukan kegagalan.

Expected baseline repository saat ini:

- lima table Request/Order belum ada;
- empat guarded RPC Request/Order belum ada;
- `confirm_purchase_order` live seharusnya tidak ada. Jika muncul dan executable
  oleh browser, itu `BLOCKER` karena routine legacy langsung menulis Stock/FIFO;
- legacy `purchases_headers/details` dipertahankan read-only sampai keputusan
  backfill/cutover dibuat;
- satu Product aktif wajib mempunyai purchase UOM. Relasi Supplier yang belum
  ada berstatus `REVIEW`, bukan blocker, karena Store Manager boleh memilih
  Supplier baru secara eksplisit saat order;
- open negative-stock allocation hanya inventory dependency: Goods Receipt G5
  nantinya wajib memicu replenishment reconciliation Phase 60.

## Batas Keamanan

- jangan menjalankan `supabase/confirm_purchase_rpc.sql`; file itu legacy dan
  bertentangan dengan flow approved;
- jangan mengaktifkan direct INSERT/UPDATE pada Purchase atau Stock table;
- jangan mengubah `purchases_headers/details` atau membuat backfill sebelum
  hasil live dikaji;
- Goods Receipt, AP provisional, Supplier Invoice, dan Return belum dibuka oleh
  preflight ini.

## Next Safe Step

Jika seluruh `BLOCKER` nol dan `REVIEW/BACKFILL` sudah dipahami, buat additive
foundation Stock Request + Supplier Order terlebih dahulu. Goods Receipt dan
stock/AP effect tetap fase terpisah agar request/order yang belum final tidak
pernah mengubah inventory atau Finance.
