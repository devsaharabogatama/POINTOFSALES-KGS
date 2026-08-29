# ODR-6C.1 Purchasing Demand UI Cutover

## Status

Local client verification **PASS**. Runtime Demand, managed Stock Request,
Draft PO sync, dan amendment sudah database-live dari ODR-4A–4E. Tahap ini
tidak menambah migration dan belum dianggap live sebelum authenticated smoke.

## Perubahan

- `Purchase -> Supplier Order` membaca dua composed RPC canonical secara
  server-side: workspace Supplier Order dan workspace Procurement Demand.
- Demand shortage ditampilkan per Company, Store, Warehouse, dan sesi Kasir.
- Product serta sisa kebutuhan base quantity ditampilkan tanpa membuka tabel
  Reservation/Demand langsung ke browser.
- Amendment terbuka menampilkan desired, allocation Draft/final, delta, dan
  alasan tindakan Purchasing.
- Perhitungan `Permintaan menunggu order` sekarang mengurangi allocation pada
  **Draft maupun PO final**. Draft PO tidak lagi ditawarkan sebagai kebutuhan
  baru hanya karena belum dikonfirmasi.
- Hanya Draft PO fully allocation-backed yang dapat disinkronkan runtime.
  Confirmed/received PO tetap immutable; selisih tampil sebagai amendment.
- Membuka layar ini tidak membuat atau mengubah Request, PO, Stock, maupun
  Finance.

## Rollout

1. Jalankan SELECT-only preflight:
   [`odr_phase6c_purchasing_demand_ui_preflight.sql`](../../supabase/diagnostics/odr_phase6c_purchasing_demand_ui_preflight.sql).
2. Semua baris selain `INFO` wajib `PASS`.
3. Deploy Backoffice lalu hard refresh.
4. Jalankan authenticated smoke di bawah.
5. Jalankan SELECT-only closing postflight:
   [`odr_phase6c_purchasing_demand_ui_postflight.sql`](../../supabase/tests/odr_phase6c_purchasing_demand_ui_postflight.sql).
6. Semua baris selain `INFO` wajib `PASS`.

## Authenticated smoke

1. Buka `Purchase -> Supplier Order` pada Company yang mempunyai linked Sales
   Order shortage.
2. Pastikan kartu `Kebutuhan Purchasing canonical` menampilkan sesi, Toko,
   Gudang, Product, sisa base qty, dan Stock Request yang sesuai.
3. Bila satu request line sudah dialokasikan penuh pada Draft PO, pastikan line
   itu tidak muncul lagi pada `Permintaan menunggu order`.
4. Buat satu Draft PO dari kebutuhan yang benar-benar belum dialokasikan.
   Muat ulang; quantity tersebut harus hilang dari daftar menunggu, sementara
   Draft PO tampil pada riwayat.
5. Jangan mengonfirmasi PO hanya untuk menguji UI. Jika memakai data UAT,
   konfirmasi hanya setelah Supplier/Gudang/quantity benar.
6. Jika ada amendment, cocokkan delta dengan `dibutuhkan - Draft - final` dan
   pastikan alasan yang ditampilkan sesuai. PO final tidak boleh berubah hanya
   karena halaman dimuat ulang.
7. Jalankan closing postflight.

## Evidence lokal

- Backoffice lint: PASS.
- Backoffice production build dan TypeScript: PASS (76 page/route).
- API fail-closed bila composed demand workspace belum tersedia.
- Tidak ada migration atau write operation baru pada tahap UI ini.

## Rollback

Redeploy build Backoffice sebelum cutover. Database tidak memerlukan rollback
karena tahap ini hanya mengubah composed read dan perhitungan client terhadap
allocation yang sudah canonical.
