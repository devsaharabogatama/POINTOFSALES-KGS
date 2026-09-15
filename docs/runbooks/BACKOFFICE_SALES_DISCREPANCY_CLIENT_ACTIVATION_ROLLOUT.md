# Backoffice Sales Discrepancy Client Activation — Step 4/6.5C4

Status: **DATABASE LIVE + BEHAVIOR/POSTFLIGHT USER-CONFIRMED PASS ON ISOLATED DEVELOPMENT; AUTHENTICATED SMOKE/UAT PENDING**.

Target hanya project Development terisolasi `fkywtxucmyjvpwdiqpix`.
Production `nbxjslqojexjfogamnjt` dan staging lama `yjxpddwrjdczuqyix`
tidak boleh dipakai untuk rollout ini.

## Clone evidence — 2026-09-15

Unit 66 installed on historical clone only: preflight five PASS, initial/closing
postflight six PASS, rollback-only behavior 12 reported scenarios PASS. Fixture
actor Auth and guarded Office setup aligned; marker cleared before runtime RPC.
Approval preserves zero Stock/Invoice/Finance delta; SO/DO projections tested.
No Production/client writes; UI smoke, Sales role/tenant denial and UAT pending.

## Outcome

- Detail SO menampilkan kasus penerimaan yang memerlukan keputusan komersial.
  Harga, diskon proporsional, dan pajak default dari SO dapat disesuaikan role
  `SALES`/`SALES_ADMIN`/Company Admin/Super Admin sebelum approval.
- Detail Surat Jalan mencatat qty aktual yang diterima dibanding DO, termasuk
  shortage, overage, dan wrong item. Resolution Gudang memanggil RPC canonical
  yang sudah lulus C3; client tidak menulis Stock/FIFO secara langsung.
- Projection Gudang tidak menerima harga, diskon, pajak, atau commercial
  snapshot. Projection Sales tidak memberi aksi Stock.
- Clean receipt lima argumen tetap digunakan bila tidak ada selisih. Overload
  mixed receipt enam argumen hanya dipanggil bila user menambahkan selisih.

## Impact dan compatibility

- Direct: satu read-model RPC additive, wrapper role approval Sales, dua API
  existing-domain, form SO existing, dan halaman Surat Jalan existing.
- Downstream: RPC mixed receipt, approval Sales, shortage resolver, serta
  overage/wrong-item resolver yang sudah live pada isolated Development.
- Tidak mengubah tabel bisnis, nomor SO/DO/SJ/Invoice, template dokumen, POS
  Retail, Payment, Cashier Session, mode cutover, maupun aturan Finance.
- Event COGS/stock-loss tetap `HOLD`; paket ini tidak membuat Journal.
- Retry memakai operation UUID; stale version dan tenant/permission tetap
  divalidasi server-side oleh RPC canonical.

## Urutan manual wajib

1. [Preflight](../../supabase/diagnostics/backoffice_sales_discrepancy_client_read_model_preflight.sql)
2. [Migration](../../supabase/migrations/20260912133000_backoffice_sales_discrepancy_client_read_model.sql)
3. [Behavioral rollback-only](../../supabase/tests/backoffice_sales_discrepancy_client_read_model_behavior.sql)
4. [Postflight](../../supabase/diagnostics/backoffice_sales_discrepancy_client_read_model_postflight.sql)
5. Jalankan postflight sekali lagi setelah behavioral PASS.

Jalankan setiap file utuh pada SQL Editor. Stop pada SQL error, `BLOCKER`, atau
`FAIL`. Jangan menjalankan migration ulang setelah ledger `20260912133000`
tercatat. Kirim seluruh result set jika ada kegagalan.

## Authenticated smoke setelah SQL PASS

1. Jalankan Backoffice melalui launcher Development yang mengunci ref
   `fkywtxucmyjvpwdiqpix`, lalu login `localadmin@local.com`.
2. Buat SO → Dispatch penuh → buka Surat Jalan → Konfirmasi diterima.
3. Clean case: tanpa baris selisih harus tetap selesai seperti sebelumnya.
4. Short case: masukkan qty sesuai + shortage, pilih posisi fisik dan keputusan
   Backorder/terima kekurangan; selesaikan dari Gudang dan cek child SJ jika
   Backorder.
5. Accept overage: catat kelebihan dari Surat Jalan; buka SO, sesuaikan/approve
   nilai; kembali ke Surat Jalan dan selesaikan fisik; cek Qty To Invoice.
6. Return overage dan Wrong Item: cek Stock kembali ke Gudang dan child SJ
   koreksi pada SO/parent SJ yang sama.
7. Ulangi klik dengan request sama, stale tab, user tanpa permission, dan ganti
   Company. Harus exact-retry atau ditolak tanpa efek ganda/cross-tenant.
8. Pastikan Gudang tidak melihat harga/diskon/pajak dan Finance Event tetap
   HOLD tanpa Journal otomatis.

## Rollback / forward-fix

Sebelum ada client deployment, rollback client cukup tidak merilis bundle baru.
Setelah migration applied, jangan menghapus read-model atau mengubah audit/
operational history. Koreksi schema/RPC harus migration forward-only dengan
guard. Wrapper role dapat dikembalikan hanya melalui forward-fix dan hanya jika
keputusan bisnis role `SALES` juga dicabut secara eksplisit.
