# G4 Phase 52 — Customer Balance Sale Credit Rollout

## Outcome

Membuka satu jalur baru: kelebihan pembayaran `CASH`/`TRANSFER` pada Sale
ONLINE dapat disimpan sebagai Saldo Customer dalam transaksi database yang
sama dengan posting Sale.

Yang tetap tertutup:

- penggunaan Saldo Customer sebagai metode bayar;
- Customer Balance pada checkout Offline;
- refund Return ke Saldo Customer;
- Ketul dan exceptional settlement;
- jurnal final G6.

Kembalian Cash historis tidak dibackfill. Nilainya tetap dianggap sudah
dikembalikan kepada Customer.

## File

- migration: `supabase/migrations/20260805130000_g4_phase52_customer_balance_sale_credit.sql`;
- postflight: `supabase/diagnostics/g4_phase52_customer_balance_sale_credit_postflight.sql`;
- behavior: `supabase/tests/g4_phase52_customer_balance_sale_credit_tests.sql`.

## Urutan Manual

Jalankan satu file penuh per eksekusi di Supabase SQL Editor:

1. migration `20260805130000`;
2. postflight Phase 52 — semua row selain `INFO` wajib `PASS`;
3. behavioral test Phase 52 — wajib notice `TEST PASSED` dan berakhir
   `ROLLBACK`;
4. regression:
   - `supabase/tests/g4_phase4_atomic_sale_runtime_tests.sql`;
   - `supabase/tests/g4_phase8_payment_leg_identity_tests.sql`;
   - `supabase/diagnostics/g4_phase10_online_checkout_stress_preflight.sql`;
   - `supabase/tests/g4_phase49_customer_balance_foundation_tests.sql`;
   - `supabase/diagnostics/g3_phase14_inventory_core_exit_preflight.sql`;
   - `supabase/tests/g1_security_closure_tests.sql`;
5. rerun postflight Phase 52 sebagai closing reconciliation.

Jangan menjalankan beberapa file sekaligus atau menyalin teks penjelasan
Markdown ke SQL Editor.

## Behavior yang Diverifikasi

- Sale dan credit rollback bersama bila validasi saldo gagal;
- Customer regular aktif dan feature/policy `ACTIVE` wajib;
- Customer Walk-In/system tidak dapat menerima credit;
- Customer row dikunci dan cache tetap sama dengan ledger append-only;
- satu Payment menghasilkan maksimal satu ledger credit dan satu Financial
  Event `HOLD`;
- retry Post dengan idempotency key yang sama tidak menggandakan saldo, stock,
  Payment, ledger, atau event;
- receipt menyimpan disposition dan nominal credit;
- Cash credit ikut expected cash sesi karena uang tidak dikembalikan, sedangkan
  Cash `RETURNED` hanya menambah kas sebesar nilai pembayaran Sale;
- Cash payload lama tanpa pilihan disposition tetap menjadi kembalian;
- browser tidak mendapat direct write ke ledger atau `current_balance`;
- transaksi Offline ditolak bila meminta Customer Balance credit.

## Compatibility

- signature `public.post_pos_sale(uuid,bigint,uuid)` tidak berubah;
- Payment lama mendapat tiga kolom additive; nilai historis tetap
  `overpayment_disposition IS NULL` dan credit nol;
- Payment Cash baru tanpa field Phase-53 tetap otomatis `RETURNED`;
- `private.post_pos_sale_online_core` mempertahankan engine stock/FIFO/tax/
  payment Phase 4, sedangkan wrapper core menambah credit dalam transaksi yang
  sama;
- Payment Method `CUSTOMER_BALANCE` tetap ditolak sebagai tender.

## Forward Fix / Rollback

Migration ini jangan dihapus setelah applied. Bila rollout gagal sebelum
`COMMIT`, PostgreSQL membatalkan seluruh DDL. Bila masalah ditemukan setelah
applied:

1. nonaktifkan `customer_balance_enabled` untuk menghentikan credit baru;
2. pertahankan ledger dan Payment snapshot sebagai histori;
3. buat forward-fix migration; jangan mengubah migration applied;
4. jangan mengubah ledger, Customer balance, atau kembalian historis secara
   manual.

## Next Safe Step

Setelah rollout, behavior, regression, dan closing postflight lulus, Phase 53
menambahkan pilihan POS yang eksplisit: `Kembalikan` atau `Simpan sebagai
saldo`. Penggunaan saldo sebagai tender tetap fase sesudahnya.
