# ODR-6 UI dan E2E Cutover Preflight

Audit ini memastikan database ODR-1 sampai ODR-5F siap sebelum browser POS,
Inventory, Purchasing, dan Finance dipindahkan ke runtime canonical. File hanya
`SELECT`; tidak mengubah transaksi, stok, pembayaran, policy, event, atau jurnal.

## Jalankan

Jalankan:

`supabase/diagnostics/odr_phase6_ui_e2e_cutover_preflight.sql`

Kirim seluruh output. Hentikan cutover jika ada `BLOCKER`.

`REVIEW` dan `SETUP` memang expected pada preflight ini:

- POS online masih harus dipindah dari final Post ke Confirm Order;
- Delivery linked masih harus dipindah ke Dispatch/Received canonical;
- Offline final Sale tetap fail-closed sampai replay reservation tersedia;
- UAT authenticated empat channel belum dijalankan.

## Fase setelah preflight bersih

1. ODR-6A: POS Confirm/Cancel dan daftar Order aktif/terjadwal;
2. ODR-6B: Inventory partial/full Dispatch dan konfirmasi diterima;
3. ODR-6C: Purchasing demand/amendment dan Finance payment verification;
4. ODR-6D: lint/build, authenticated E2E, two-Company/role/retry/offline,
   reconciliation, deployment, dan rollback rehearsal.

Company tetap `CONTROLLED` selama seluruh UAT. Jangan mengaktifkan automatic
posting hanya karena ODR-5F sudah membuka switch policy.
