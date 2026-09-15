# Warehouse Transit Usage Foundation Rollout

Gate ini memisahkan Gudang Transit berdasarkan Gudang operasional dan tujuan
proses. Kombinasi aktif bersifat unik sehingga Transit Pengiriman, Transfer
antar Gudang, dan Retur Customer tidak dipilih atau dicampur secara acak.

Migration menyediakan writer Master Gudang terautentikasi dan resolver privat
yang dapat membuat Transit secara lazy saat operasi pertama membutuhkan. Gate
ini belum memanggil resolver dari Dispatch dan sama sekali tidak membuat Stock
Movement, FIFO allocation, Delivery mutation, Invoice, Payment, atau Finance.

Status 2026-09-09: migration sudah live hanya pada isolated Development
`fkywtxucmyjvpwdiqpix`; lint dan full build PASS. Postflight dan behavioral
test PASS berdasarkan eksekusi manual user. Authenticated smoke/UAT Master
Gudang masih pending; production/staging tidak disentuh.

## Urutan Development

1. Pastikan project-ref `fkywtxucmyjvpwdiqpix`.
2. Jalankan `supabase/diagnostics/warehouse_transit_usage_foundation_preflight.sql`.
   Stop bila ada `BLOCKER`; `REVIEW` hanya menginventarisasi Transit lama yang
   masih mempunyai flag operasional dan tidak mengubahnya.
3. Apply `supabase/migrations/20260909150000_warehouse_transit_usage_foundation.sql`.
4. Jalankan `supabase/diagnostics/warehouse_transit_usage_foundation_postflight.sql`.
   Seluruh baris selain inventory harus `PASS`.
5. Jalankan `supabase/tests/warehouse_transit_usage_foundation_behavior.sql`.
   Test membuat Transit sementara, menguji retry/duplikat, lalu rollback.
6. Refresh Backoffice lokal dan buka Master Data > Gudang. Tipe Transit wajib
   menampilkan Gudang operasional terkait dan Penggunaan Transit.

## Compatibility dan forward-fix

- Transit lama dipertahankan tanpa backfill dan tampil `Transit belum
  ditentukan` sampai user memetakannya.
- Writer Warehouse lama tidak dihapus. Client baru memakai RPC khusus hanya
  ketika tipe `TRANSIT`.
- Resolver otomatis belum terhubung ke operasi pada gate ini. Dispatch
  Backoffice tetap terkunci.
- Kegagalan sebelum COMMIT rollback otomatis. Setelah COMMIT, perubahan
  dibatalkan melalui forward-fix yang menonaktifkan writer/resolver baru;
  kolom tidak di-drop selama masih mungkin dibaca client.
- Production/staging tidak disentuh tanpa instruksi deployment eksplisit.
