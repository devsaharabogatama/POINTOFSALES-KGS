# G4 Phase 18 — POS Customer Quick-Create Rollout

## Outcome

Kasir dapat membuat Customer sederhana dari checkout POS tanpa memperoleh
akses tulis langsung ke tabel Customer.

Kontrak server:

- `company_id` selalu berasal dari active Company pada request;
- request tidak menerima parameter Company;
- actor wajib memiliki Cashier Session `OPEN` pada Company tersebut;
- kode Customer dibuat otomatis dengan format `CUST-000001`;
- kategori memakai kategori Customer aktif milik Company yang sama;
- quick-create tidak dapat mengisi limit kredit, termin, saldo, Customer induk,
  atau default Pricelist;
- nama Customer tetap unik setelah normalisasi pada Company yang sama;
- setiap create dicatat pada `customer_master_audit`.

Backoffice tetap memakai API guarded yang sudah ada dan juga mengambil Company
dari active Company server context. Selector Company hanya ditampilkan apabila
user memiliki lebih dari satu Company. Perilaku yang sama dipakai PWA; pada
Cashier Session yang sudah terbuka, Company tidak boleh diganti sampai Session
ditutup.

## File

- migration:
  `supabase/migrations/20260730040000_g4_phase18_pos_customer_quick_create.sql`;
- postflight:
  `supabase/diagnostics/g4_phase18_pos_customer_quick_create_postflight.sql`;
- behavior:
  `supabase/tests/g4_phase18_pos_customer_quick_create_tests.sql`.

## Urutan Manual Supabase

Jalankan seluruh file, satu per satu:

1. migration `20260730040000`;
2. postflight Phase 18 — seluruh baris harus `PASS`;
3. behavioral test Phase 18 — harus mengeluarkan notice `TEST PASSED` dan
   berakhir dengan `ROLLBACK`.

Behavioral test membutuhkan satu user Auth yang sedang mempunyai Cashier
Session `OPEN`. Test tidak menyimpan Customer atau perubahan sequence karena
seluruh fixture berada dalam transaksi rollback.

## Smoke PWA

1. restart PWA setelah migration;
2. login dan buka Cashier Session;
3. pada bagian `Pelanggan & harga`, tekan `Customer baru`;
4. pastikan nama Company hanya berupa informasi, bukan input bebas;
5. simpan Customer dan pastikan Customer baru langsung terpilih;
6. pastikan nama duplikat ditolak;
7. untuk user multi-Company, tutup Session, pindah Company dari selector
   header, buka Session Company tujuan, lalu ulangi create;
8. pastikan Customer tidak terlihat dari Company lain.

## Smoke Backoffice

1. user satu Company melihat nama Company tanpa dropdown;
2. user multi-Company melihat dropdown Company;
3. buat Customer melalui menu Kontak/Pelanggan;
4. pindah Company aktif dan pastikan Customer terisolasi per Company.

## Compatibility dan Forward-Fix

- Customer lama tidak diubah atau di-backfill;
- RPC `save_customer_with_pricelist` Backoffice tidak diubah;
- direct `INSERT/UPDATE/DELETE` role `authenticated` tetap tertutup;
- rollback setelah migration applied dilakukan dengan forward fix, bukan
  mengedit migration ini;
- quick-create lanjutan untuk Customer induk, kredit, atau Pricelist harus tetap
  dilakukan dari Backoffice karena berada di luar kontrak Kasir sederhana.
