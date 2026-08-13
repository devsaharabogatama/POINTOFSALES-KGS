# ACP-5D Purchase Return Permission Enforcement Rollout

**Status:** LOCAL READY — manual Supabase rollout and authenticated smoke pending  
**Permission key:** `purchase.purchase_returns`

## Urutan Wajib

Jalankan satu per satu dan berhenti pada SQL error atau postflight `FAIL`:

1. `supabase/migrations/20260813010000_acp_phase5d_purchase_return_permission_enforcement.sql`
2. `supabase/diagnostics/acp_phase5d_purchase_return_permission_postflight.sql`
3. `supabase/tests/acp_phase5d_purchase_return_permission_tests.sql`
4. `supabase/tests/g5_phase8_purchase_return_foundation_tests.sql`
5. `supabase/tests/acp_phase5b_supplier_permission_tests.sql`
6. `supabase/tests/acp_phase5c_supplier_order_permission_tests.sql`
7. ulangi postflight langkah 2.

## Outcome

- Backoffice list/detail dijaga `VIEW` melalui composed RPC;
- Review dan Post memakai capability masing-masing;
- cancel milik pembuat Draft tetap tersedia, cancel oleh manager memakai
  `CANCEL_FINAL`;
- PWA hanya menerima source Return untuk open Cashier session dan Store aktif;
- direct SELECT lima tabel Return ditutup;
- core G5 tetap atomic/idempotent dan dipindahkan ke schema `private`;
- Goods Receipt, Supplier Order, Supplier, Stock, AP, dan Finance tidak
  mewarisi Return management permission.

## Smoke Setelah SQL PASS

Restart Backoffice dan PWA:

1. Owner/Admin default dapat View, Review, Post, dan Cancel.
2. `OPERASIONAL` dapat View tetapi tidak Review/Post/Cancel Final.
3. `LIHAT_SAJA` hanya View; `TANPA_AKSES` tidak melihat launcher/API.
4. Cashier open session tetap dapat membuat/edit/cancel Draft miliknya.
5. Cashier Store lain tidak melihat Receipt/Return source.
6. switch Company A/B tidak membocorkan Return, source, Supplier, atau Gudang.
7. Post tetap satu kali dan Stock–Movement–FIFO/AP tetap rekonsiliasi.

Jika migration sudah masuk ledger, koreksi wajib forward migration; jangan edit
migration applied dan jangan mengembalikan direct table grant.
