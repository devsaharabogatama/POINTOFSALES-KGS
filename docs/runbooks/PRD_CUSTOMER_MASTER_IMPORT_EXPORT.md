# Import dan Export Master Customer

## Status

Local-ready. Migration database dan smoke test user masih wajib dijalankan.

## Cakupan

- menambahkan `CUSTOMER` pada Data Exchange global;
- export hanya Customer bisnis milik Company aktif, tanpa Walk-In;
- import memakai staging, preview, konfirmasi update, optimistic version, dan audit;
- kategori, Customer induk, dan Pricelist dicocokkan berdasarkan nama di Company aktif;
- saldo berjalan, piutang awal, transaksi, dan histori tidak dapat diimpor;
- Customer induk harus sudah ada. Untuk hierarki, import induk lalu cabang pada batch berikutnya.

## Urutan rollout

1. Pastikan tidak ada import job nonterminal.
2. Jalankan `supabase/migrations/20260819150000_customer_master_import_export.sql`.
3. Jalankan `supabase/diagnostics/customer_master_import_export_postflight.sql`; seluruh baris wajib `PASS`.
4. Jalankan `supabase/tests/customer_master_import_export_tests.sql`; hasil harus sukses dan otomatis `ROLLBACK`.
5. Jalankan postflight sekali lagi.
6. Deploy/restart Backoffice, buka **Data Exchange → Contacts → Customer**, unduh template, lalu uji satu Customer dummy.

## Template CSV

`code,name,customer_category_name,parent_customer_name,default_pricelist_name,phone,email,address,customer_type,credit_limit,credit_term_days,notes,is_active`

`code` boleh kosong ketika membuat Customer. `customer_type` menerima
`INDIVIDUAL` atau `BUSINESS`. Boolean menerima `true/false`, `ya/tidak`, atau
`aktif/nonaktif`.

## Forward fix

Migration bersifat additive. Jika ditemukan masalah setelah rollout, hentikan import
Customer baru dan buat forward migration; jangan menghapus job/audit atau Customer
yang sudah dipakai transaksi.
