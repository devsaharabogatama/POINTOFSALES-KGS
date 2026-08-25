# POS Live Pricelist Preview Rollout

## Outcome

Harga pada kartu Product dan cart POS langsung memakai resolver Pricelist
server untuk Customer, Store, quantity tier, dan override yang sedang dipilih.
Preview tidak membuat Draft dan tidak menjadi sumber kebenaran untuk Post;
Save Draft dan Post tetap menghitung ulang seluruh harga secara canonical.

## Urutan rollout

1. Jalankan migration
   [`20260825100000_pos_live_pricelist_preview.sql`](../../supabase/migrations/20260825100000_pos_live_pricelist_preview.sql).
2. Jalankan postflight
   [`pos_live_pricelist_preview_postflight.sql`](../../supabase/tests/pos_live_pricelist_preview_postflight.sql).
3. Pastikan ada satu sesi Cashier `OPEN`, Customer aktif, dan Product-UOM jual,
   lalu jalankan behavior rollback-safe
   [`pos_live_pricelist_preview_behavior.sql`](../../supabase/tests/pos_live_pricelist_preview_behavior.sql).
4. Deploy PWA pada environment yang memakai database tersebut.

## Smoke manual

1. Buka sesi POS online dan pilih Customer dengan Pricelist khusus.
2. Pastikan harga kartu Product berubah tanpa menekan **Simpan Draft**.
3. Masukkan Product ke cart dan ubah quantity melewati tier; setelah jeda singkat,
   harga cart harus mengikuti tier server.
4. Ganti ke Pricelist Global eligible; kartu dan cart harus ikut berubah.
5. Simpan Draft. Harga server pada Draft harus sama dengan preview, kecuali
   master/rule berubah di sela preview dan Save—dalam kondisi itu hasil Save
   yang authoritative wajib menang.
6. Matikan koneksi dan pastikan jalur snapshot Offline tetap bekerja seperti
   sebelumnya.

## Compatibility dan rollback

- RPC lama Save/Post, payload Draft, snapshot transaksi, Offline pricing, dan
  Finance tidak diubah.
- Client lama tetap berjalan karena migration hanya additive.
- Jika PWA baru dipakai sebelum migration, POS tetap menampilkan fallback dan
  notice preview gagal; transaksi tidak boleh mempercayai fallback saat Save.
- Rollback client: kembalikan pemanggilan preview pada PWA. RPC additive dapat
  dibiarkan. Jika harus dihapus, cabut grant lalu drop signature hanya setelah
  seluruh client baru ditarik.
