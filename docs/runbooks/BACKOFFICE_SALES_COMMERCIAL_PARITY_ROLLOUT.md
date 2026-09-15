# Backoffice Sales Commercial Parity Rollout

## Status

`DATABASE LIVE — ISOLATED DEVELOPMENT ONLY; CLIENT LOCAL READY; MANUAL SQL,
AUTHENTICATED SMOKE, POS REGRESSION, AND UAT PENDING`.

Target Development yang diizinkan adalah `fkywtxucmyjvpwdiqpix`. Production
`nbxjslqojexjfogamnjt` dan staging lama `yjxpddwrjdczuqyixqwi` tidak boleh
disentuh tanpa instruksi deployment eksplisit dari user.

## Kontrak bisnis yang dikunci

- `SALES` dan `SALES_ADMIN` adalah role formal. Keduanya memperoleh seluruh
  capability pada modul Sales; Platform Super Admin tetap authority tertinggi.
- Akses tetap tenant-scoped. Role pada Company A tidak memberikan akses ke
  Store, Warehouse, Pricelist, Customer, atau dokumen Company B.
- Backoffice Quotation/SO memakai resolver harga, Pricelist, pajak inclusive,
  discount, dan rounding canonical MADS. Harga manual adalah override eksplisit
  dan tersimpan bersama harga canonical untuk audit.
- Izin stok minus adalah atribut Warehouse. UI hanya memindahkan source
  pengaturan ke Warehouse; seluruh guard Company, Warehouse, user, sesi,
  online, alasan, limit, audit, FIFO, dan reconciliation existing tetap berlaku.
- Save Draft tidak boleh membuat Reservation, Stock/FIFO movement, Delivery,
  Invoice, Payment, Finance Event, atau Journal.
- POS retail, Terminal price-override policy, dan lifecycle dokumen existing
  tidak diubah oleh rollout ini.

## Urutan manual gate

Jalankan dari SQL Editor project Development baru, satu per satu:

1. `supabase/diagnostics/sales_roles_and_module_authority_postflight.sql`
2. `supabase/diagnostics/backoffice_sales_commercial_parity_postflight.sql`
3. `supabase/diagnostics/backoffice_sales_canonical_insert_fix_postflight.sql`
4. `supabase/tests/backoffice_sales_commercial_parity_behavior.sql`

Hentikan pengujian pada error SQL, status `FAIL`/`BLOCKER`, row pelanggaran,
cross-Company access, duplicate operation, atau munculnya downstream effect
pada Draft. Kirim output lengkap sebelum ada forward-fix.

Jika ketiga SQL lulus:

1. restart client dengan `npm run dev:backoffice-sales` dari folder
   `backoffice`, lalu hard refresh;
2. login sebagai Platform Super Admin, `SALES`, dan `SALES_ADMIN`;
3. pada dua Company berbeda, pastikan user hanya melihat scope Company-nya;
4. uji Pricelist AUTO dan explicit, harga manual lalu reset ke Pricelist,
   discount line nominal/persen, discount order, produk kena/tidak kena pajak,
   serta rounding NONE/DOWN/UP;
5. uji exact retry dan stale version tanpa duplikasi Draft/audit;
6. konfirmasi Draft tetap tidak menimbulkan Reservation, Stock, SJ, Invoice,
   Payment, atau Finance;
7. lakukan satu transaksi POS regression dan pastikan price/tax/stock behavior
   POS tidak berubah.

## Compatibility dan pemulihan

Migration bersifat additive dan tidak mengubah nilai komersial Draft lama.
Behavioral run pertama menemukan atomic INSERT belum mengisi kolom baru
`canonical_unit_price`. Forward migration `20260909141000` mengisi kolom itu
langsung dari `canonicalResolvedUnitPrice`, atau `resolvedUnitPrice` jika tidak
ada override; tidak memakai default/backfill harga nol.
Jika client bermasalah, feature Backoffice Sales dapat tetap OFF sehingga POS
tidak bergantung pada fitur ini. Migration yang sudah live tidak diedit ulang;
defect diperbaiki dengan forward migration baru beserta preflight, postflight,
behavioral test, dan catatan dampak.

Production baru dapat dipertimbangkan setelah manual SQL, authenticated smoke,
POS regression, dan UAT seluruhnya PASS serta user memberi instruksi deploy.
