# G4 Phase 5 — PWA Tablet UX, Pricelist Override, dan Receipt Print

## Outcome

PWA POS memakai layout tablet-first, mengosongkan transaksi segera setelah
Sale berhasil `POSTED`, membuka receipt di tab cetak baru, dan menyediakan
pilihan Pricelist di bawah Customer.

Mode Pricelist:

- `Otomatis` mengikuti Pricelist khusus yang di-assign pada Customer;
- Customer tanpa Pricelist khusus memakai Global default;
- Cashier dapat override ke Global eligible atau Pricelist khusus Customer
  tersebut;
- Pricelist khusus Customer lain tidak ditampilkan dan tetap ditolak resolver
  server bila request dimanipulasi.

## Manual Database Rollout

Jalankan berurutan di Supabase SQL Editor:

1. `supabase/migrations/20260729100000_g4_phase5_cashier_pricelist_override.sql`;
2. `supabase/diagnostics/g4_phase5_cashier_pricelist_override_postflight.sql`;
3. `supabase/tests/g4_phase5_cashier_pricelist_override_tests.sql`.

Expected:

- postflight menghasilkan empat baris `PASS`;
- behavior mengeluarkan notice:
  `TEST PASSED: AUTO and eligible override resolve server-side; cross-Customer Pricelist is denied.`

Setelah itu rerun:

1. `supabase/tests/g4_phase4_atomic_sale_runtime_tests.sql`;
2. `supabase/tests/g4_phase5_store_manager_pos_access_tests.sql`;
3. `supabase/tests/g1_security_closure_tests.sql`.

## Authenticated PWA Smoke

1. Restart PWA dan lakukan hard refresh agar service worker tidak memakai
   bundle lama.
2. Buka sesi pada tablet portrait dan landscape.
3. Pastikan katalog dan checkout tetap dapat digunakan tanpa horizontal scroll.
4. Pilih Customer yang memiliki Pricelist khusus:
   - opsi `Otomatis` menampilkan nama Pricelist tersebut;
   - simpan Draft dan pastikan harga server sesuai.
5. Override ke Global eligible, simpan ulang, dan pastikan seluruh cart
   dihitung ulang.
6. Pastikan Pricelist Customer lain tidak muncul.
7. Post transaksi:
   - receipt tetap tampil;
   - cart, Customer, Pricelist, Payment, diskon, TEMPO, dan rounding sudah
     kembali ke transaksi baru;
   - tombol `Buka & cetak` membuka tab baru dan print dialog, bukan download.
8. Blok pop-up lalu ulangi tombol print; expected notice meminta izin pop-up.

## Compatibility dan Boundary

- resolver lama tetap tersedia untuk client lama dan tetap menjalankan mode
  `AUTO`;
- wrapper baru membawa pilihan hanya dalam transaction-local setting, bukan
  mengubah master Customer/Pricelist;
- harga, eligibility Store/Customer, tier, Tax, rounding, dan posting tetap
  dihitung server-side;
- Bluetooth printer tetap dicetak langsung. Tab baru adalah fallback browser;
- split payment, Draft lock/list, offline queue, Return, dan modul G4 lanjutan
  tetap belum dibuka.

## Rollback / Forward Fix

Sale `POSTED`, receipt, Payment, Movement, FIFO, dan Financial Event tidak boleh
dihapus. Jika UI bermasalah, hentikan pemakaian bundle PWA baru dan gunakan
mode `AUTO`. Jika migration sudah applied, jangan mengedit migration; buat
forward fix dengan version lebih tinggi.
