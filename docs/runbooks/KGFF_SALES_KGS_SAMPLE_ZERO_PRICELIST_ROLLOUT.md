# KGFF SALES KGS Sample Zero Pricelist Rollout

## Scope

Paket ini membuat satu Customer Pricelist KGFF `SAMPLE-SALES-KGS`, mengisi
seluruh Product-UOM aktif yang boleh dijual dengan `FIXED_PRICE = 0`, lalu
menetapkannya hanya kepada Customer `KGS003 / SALES KGS`.

Ini belum mengaktifkan checkout dengan total nol. Stock keluar dan jurnal
Sample/Promosi merupakan perubahan behavior terpisah yang masih ditutup.

## Urutan eksekusi manual

1. Jalankan `supabase/diagnostics/kgff_sales_kgs_zero_price_pricelist_preflight.sql`.
2. Lanjut hanya bila seluruh row wajib `PASS`, state `NOT_INSTALLED`, dan tidak
   ada queue aktif.
3. Jalankan satu kali
   `supabase/migrations/20261103100000_kgff_sales_kgs_sample_zero_pricelist.sql`.
4. Jalankan `supabase/diagnostics/kgff_sales_kgs_zero_price_pricelist_postflight.sql`.
5. Lanjut hanya bila empat row wajib postflight `PASS`.
6. Jalankan rollback-only
   `supabase/tests/kgff_sales_kgs_zero_price_pricelist_behavior.sql`.
7. Authenticated smoke di POS KGFF: pilih `SALES KGS`, buktikan beberapa
   Product-UOM menjadi Rp0, lalu ganti ke Customer lain dan buktikan Pricelist
   Sample tidak digunakan. Jangan konfirmasi checkout nol sebelum gate Sample
   transaction selesai.

## Expected invariant

- Header Pricelist tepat satu, scope `CUSTOMER`, reusable, aktif, semua Store.
- Customer `SALES KGS` tepat satu dan menunjuk header tersebut.
- Set aturan sama persis dengan Product-UOM aktif dan sale-allowed saat
  migration dijalankan; seluruh aturan fixed price nol.
- Product base price, Pricelist lain, Customer lain, Draft/Posted lama,
  Stock/FIFO, Payment, session, Event, dan Journal tidak diubah.

## Retry, concurrency, dan compatibility

- Migration dilindungi ledger, exact identity guard, row lock Customer, dan
  advisory transaction lock. Jangan menjalankan ulang migration yang sudah
  ledger-live.
- Catalog baru setelah rollout tidak otomatis mendapat rule nol. Gunakan
  update Pricelist canonical yang diaudit sebelum Product baru dipakai sebagai
  Sample.
- Existing Draft/Posted Sales tetap memakai snapshot lama.

## Rollback / forward-fix

Migration live bersifat immutable. Jika konfigurasi perlu dinonaktifkan, buat
forward migration baru yang atomik: kosongkan assignment exact SALES KGS,
nonaktifkan header/rules, tulis kedua master audit, dan jangan rewrite snapshot
Sales. Jika pernah dipakai, jangan delete header/rules.

## Status evidence

- `AUDIT COMPLETE`: ya.
- `LOCAL READY`: ya; scoped diff/checksum/mutation-boundary review PASS.
- `DATABASE LIVE`: ya; user-confirmed ledger tepat satu.
- `POSTFLIGHT PASS`: ya; 4/4 mandatory PASS, exact rule coverage 78/78.
- `BEHAVIOR PASS`: ya; rollback-only resolver behavior user-confirmed sukses.
- `CLIENT DEPLOYED`: tidak relevan; tidak ada perubahan client.
- `SMOKE PASS`: belum.
- `UAT PASS`: belum.
