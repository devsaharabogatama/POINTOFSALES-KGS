# ACP-4H Opening Stock Permission Enforcement

Status: LOCAL READY; manual Supabase rollout dan authenticated smoke menunggu.

## Boundary

ACP-4H menegakkan tepat `inventory.opening_stock`:

- Company Owner/Admin: lihat, buat/edit Draft, dan Post;
- Finance: lihat dan buat/edit Draft, tanpa Post;
- Store Manager: lihat dan buat/edit Draft hanya pada Gudang Store tempat ia
  memiliki membership aktif, tanpa Post;
- Accounting: report-only;
- restriction preset tetap hanya dapat mengurangi baseline tersebut.

Backoffice membaca dokumen, line, narrow Product/Gudang reference, saldo terkait,
Opening Movement, FIFO, Finance Event, audit, dan pasangan Movement eligibility
melalui satu RPC `get_inventory_opening_stock()`. Browser tidak lagi dapat
membaca tiga tabel Opening Stock secara langsung atau seluruh Company Movement
ledger lewat halaman ini. Atomic Post, no-prior-Movement, FIFO, Finance HOLD,
idempotency, dan public signature existing tetap dipertahankan.

## Urutan SQL manual

Jalankan setiap file secara penuh. Berhenti pada error atau row `FAIL`:

1. [`20260812200000_acp_phase4h_opening_stock_permission_enforcement.sql`](../../supabase/migrations/20260812200000_acp_phase4h_opening_stock_permission_enforcement.sql)
2. [`acp_phase4h_opening_stock_permission_postflight.sql`](../../supabase/diagnostics/acp_phase4h_opening_stock_permission_postflight.sql)
3. [`acp_phase4h_opening_stock_permission_tests.sql`](../../supabase/tests/acp_phase4h_opening_stock_permission_tests.sql)
4. [`g3_phase1_opening_stock_tests.sql`](../../supabase/tests/g3_phase1_opening_stock_tests.sql)
5. ulangi langkah 2
6. [`acp_phase4_inventory_pilot_preflight.sql`](../../supabase/diagnostics/acp_phase4_inventory_pilot_preflight.sql)

Expected notice langkah 3:

`TEST PASSED: Opening Stock preparation is capability-aware, Store-scoped, tenant-safe, and only Company Owner/Admin can Post.`

## Authenticated smoke

1. Accounting: menu/report terlihat; tombol Draft/Edit/Post tidak ada.
2. Finance: dapat membuat dan mengedit Draft di Gudang Company; tidak dapat Post.
3. Store Manager: hanya melihat Gudang Store assignment-nya, dapat membuat/edit
   Draft di sana, dan tidak dapat Post atau memilih Gudang Central/Store lain.
4. Company Owner/Admin: dapat Post Draft Finance/Store Manager.
5. `LIHAT_SAJA`: report tetap terbuka, seluruh mutation hilang dan API/RPC
   mutation ditolak.
6. `OPERASIONAL`: Draft/Edit tersedia sesuai role dan scope Gudang, Post ditolak.
7. `TANPA_AKSES`: menu hilang dan API/RPC report maupun mutation ditolak.
8. Ganti Company A/B; dokumen, Product, Gudang, saldo, Movement, FIFO, Event,
   dan audit tidak boleh silang tenant.

## Recovery

Migration bersifat forward-only. Jika smoke gagal, reset override user ke
`IKUTI_ROLE`, hentikan mutation Stok Awal, dan buat forward fix. Jangan mengedit
migration applied, membuka kembali direct table read, atau menghapus dokumen
posted. Minimum Stock tetap `SHADOW` dan berada di slice berikutnya.
