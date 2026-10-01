# Delivery Return Status Overlay Rollout

## Status

`DATABASE LIVE / PREFLIGHT + DUAL-BRANCH BEHAVIOR + POSTFLIGHT PASS`.
Production preflight, migration, revised behavior, dan closing postflight sudah
PASS/user-confirmed. Behavior membuktikan real retained-Retail exact Delivery
attribution dan rollback-only Backoffice SO-level attribution; seluruh fixture
test di-rollback. Client deployment, authenticated smoke, dan UAT masih
menunggu.

## Urutan wajib

1. Jalankan read-only
   `supabase/diagnostics/delivery_return_status_overlay_preflight.sql`.
2. Hentikan bila ada `BLOCKER`; jangan jalankan migration.
3. Jalankan
   `supabase/migrations/20261001110000_delivery_return_status_overlay.sql`.
4. Jalankan rollback-only/read-only behavior
   `supabase/tests/delivery_return_status_overlay_behavior.sql`.
5. Jalankan read-only
   `supabase/diagnostics/delivery_return_status_overlay_postflight.sql`.
6. Deploy client hanya setelah langkah 3-5 lulus.
7. Smoke dengan user yang memiliki akses Inventory Surat Jalan:
   - buka DO Retail yang memiliki Return;
   - buka DO Backoffice dari SO yang memiliki Return;
   - pastikan DO tanpa Return tidak mendapat badge;
   - pastikan Return canceled tetap berlabel dibatalkan;
   - cocokkan quantity panel terhadap detail Return/receipt.

## Expected UI

- Kolom Status tetap menampilkan status Delivery sebagai badge utama.
- Badge kedua hanya muncul bila ada histori Return.
- Detail menampilkan setiap Return secara terpisah dengan status, alasan,
  requested, received, restocked, destroyed, dan jumlah receipt.
- Backoffice selalu memakai teks **Retur tercatat pada SO ini** karena Return
  belum mempunyai exact `delivery_order_id`.

## Rollback

Migration hanya menambah read RPC. Jika client perlu di-rollback, kembalikan
route/component dan biarkan RPC tidak terpakai. Jika RPC harus dihapus:

```sql
BEGIN;
REVOKE ALL ON FUNCTION
  public.get_inventory_delivery_return_overlays(date,date)
FROM PUBLIC,anon,authenticated,service_role;
DROP FUNCTION public.get_inventory_delivery_return_overlays(date,date);
COMMIT;
```

Ledger migration dan data bisnis tidak dihapus. Forward-fix baru diperlukan
bila contract RPC sudah pernah dipakai client Production.

