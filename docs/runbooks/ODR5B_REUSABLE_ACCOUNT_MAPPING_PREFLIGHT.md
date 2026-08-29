# ODR-5B Reusable Account Mapping Preflight

Status: `LOCAL READY`  
Jenis: `SELECT-only`

## Alasan audit tambahan

Preflight awal menemukan `COGS`, `INVENTORY_ASSET`, dan `SALES_REVENUE` tidak
memiliki system-owned COA atau Company fallback pada empat Company. Itu tidak
otomatis berarti akun ekonominya tidak ada: Company dapat sudah memakai akun
yang sah melalui `transaction_account_rules` existing.

Membuat COA baru tanpa memeriksa rule tersebut dapat menggandakan akun
Persediaan, HPP, atau Penjualan. Audit terkoreksi memilih candidate dengan
urutan yang sama dengan sumber ekonomi existing:

1. tepat satu account ID dari ACTIVE rule `SALE_POSTED` atau `SALE_PAYMENT`
   sesuai target event;
2. tepat satu Company fallback;
3. tepat satu system-owned COA yang valid;
4. selain itu `MISSING` atau `AMBIGUOUS` dan migration wajib berhenti.

Urutan ini penting karena beberapa Company sah memiliki lebih dari satu akun
berlabel system function untuk kebutuhan kategori berbeda. Existing event rule,
bukan jumlah label master secara global, adalah sumber mapping reusable.

## Cara menjalankan

Jalankan:

[`odr_phase5b_reusable_account_mapping_preflight.sql`](../../supabase/diagnostics/odr_phase5b_reusable_account_mapping_preflight.sql)

Kirim seluruh output. File hanya melakukan pembacaan.

## Expected

- `customer_advance_provision_scope` dapat `BACKFILL` untuk akun baru kode
  default `2190`;
- collision akun/kategori harus `PASS`;
- core reusable source harus `PASS` sebelum mapping migration dibuat;
- conditional source `REVIEW` hanya boleh diterima setelah fungsi yang hilang
  dan kondisi amount-nya dipahami;
- active queue dan protected Finance history harus `PASS`.

Jangan menjalankan migration mapping sebelum hasil audit ini ditinjau.
