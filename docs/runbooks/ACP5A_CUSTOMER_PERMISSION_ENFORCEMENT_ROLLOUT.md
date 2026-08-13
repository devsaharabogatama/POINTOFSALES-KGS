# ACP-5A Customer Permission Enforcement

Status: LOCAL READY; manual Supabase rollout dan authenticated smoke menunggu.

## Boundary

ACP-5A menegakkan tepat `contacts.customers`:

- Company Owner/Admin dan Store Manager: View/Manage Customer, kategori,
  customer induk/cabang, dan assignment Pricelist;
- Finance/Accounting: View Customer dan tetap dapat mengubah limit/termin kredit
  melalui authority Finance yang terpisah;
- restriction preset hanya dapat mengurangi baseline role;
- Export mengikuti View, sedangkan import Kategori Customer hanya tersedia
  untuk Owner/Admin yang memiliki capability `IMPORT`.

Backoffice membaca Customer, kategori, Pricelist label, dan audit melalui satu
RPC `get_contacts_customers()`. Browser tidak lagi membaca tabel Customer,
kategori, atau audit secara langsung.

Cutover ini tidak menjadikan permission Contacts sebagai jalan pintas bagi
modul lain:

- POS tetap memakai open Cashier Session untuk quick-create dan reference;
- Sales Document/Return memakai reference RPC yang memeriksa permission Sales;
- Customer Balance dan credit memakai authority Finance masing-masing;
- saldo Customer tetap ledger-derived dan tidak dapat diedit dari Master;
- Customer Category import diperiksa pada create, stage, validate, dan commit.

## Urutan SQL manual

Jalankan penuh dan berhenti pada error atau `FAIL`:

1. [`20260812220000_acp_phase5a_customer_permission_enforcement.sql`](../../supabase/migrations/20260812220000_acp_phase5a_customer_permission_enforcement.sql)
2. [`acp_phase5a_customer_permission_postflight.sql`](../../supabase/diagnostics/acp_phase5a_customer_permission_postflight.sql)
3. [`acp_phase5a_customer_permission_tests.sql`](../../supabase/tests/acp_phase5a_customer_permission_tests.sql)
4. [`g2_phase8_customer_foundation_tests.sql`](../../supabase/tests/g2_phase8_customer_foundation_tests.sql)
5. [`g2_phase10_customer_grouping_tests.sql`](../../supabase/tests/g2_phase10_customer_grouping_tests.sql)
6. [`g2_phase13_reusable_customer_pricelist_tests.sql`](../../supabase/tests/g2_phase13_reusable_customer_pricelist_tests.sql)
7. [`g4_phase18_pos_customer_quick_create_tests.sql`](../../supabase/tests/g4_phase18_pos_customer_quick_create_tests.sql)
8. [`g4_phase49_customer_balance_foundation_tests.sql`](../../supabase/tests/g4_phase49_customer_balance_foundation_tests.sql)
9. ulangi langkah 2.

Expected langkah 3:

`TEST PASSED: Customer management is capability-aware, credit-separated, restricted, and tenant-safe.`

## Authenticated smoke

1. Owner/Admin dan Store Manager tanpa override dapat membuka dan mengubah
   Customer serta kategori.
2. Finance/Accounting dapat melihat Customer dan mengubah limit/termin kredit,
   tetapi tidak dapat mengubah nama, kategori, parent, atau Pricelist.
3. `LIHAT_SAJA`: daftar tersedia, seluruh mutation dan import ditolak.
4. `OPERASIONAL`: mengikuti irisan baseline; tidak menambah capability baru.
5. `TANPA_AKSES`: menu, direct URL, API Customer, RPC, export, dan import ditolak.
6. Kasir dengan sesi aktif tetap melihat Customer dan dapat quick-create dari
   POS walaupun tidak memiliki akses Backoffice Customer.
7. Sales Document/Return dan Finance Customer Balance tetap dapat menampilkan
   label Customer lewat permission modulnya sendiri.
8. Ganti Company A/B; Customer, kategori, parent, Pricelist, audit, dan import
   job tidak boleh silang tenant.

## Recovery

Migration forward-only. Bila smoke gagal, set override terdampak ke
`IKUTI_ROLE`, hentikan mutation/import Customer, dan buat forward fix. Jangan
mengaktifkan kembali direct browser table read dan jangan mengedit migration
yang sudah applied. Existing Customer, saldo, audit, transaksi, dan import
history tidak dihapus oleh cutover ini.
