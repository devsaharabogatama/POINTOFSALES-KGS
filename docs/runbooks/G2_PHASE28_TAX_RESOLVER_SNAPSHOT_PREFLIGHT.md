# G2 Phase 28 — Tax Resolver/Snapshot Preflight

## Tujuan

Mengaudit kesiapan resolver Tax server-side dan snapshot transaksi setelah
assignment Product Category/Product selesai. Preflight ini tidak mengaktifkan
kalkulasi Tax pada checkout, Supplier Invoice, jurnal, return/reversal, atau
pelaporan pajak resmi.

Source of truth: `docs/TAX_ENGINE_SPEC.md`.

## Boundary yang Diaudit

- dependency guarded Tax assignment `20260723040000`;
- entitlement `SALES_TAX` dan `PURCHASE_TAX` per Company;
- resolusi `Product override → Category default → no tax`;
- tepat satu versi Tax aktif/effective untuk assignment yang dipakai;
- Sales selalu `INCLUSIVE`, Purchase `INCLUSIVE/EXCLUSIVE`;
- akun Tax current aktif dan postable;
- snapshot Tax Sales/Purchase existing tidak setengah terisi;
- jalur checkout legacy belum diam-diam menulis snapshot Tax;
- browser tidak mendapat direct update pada detail transaksi.

`no tax` adalah hasil resolver yang valid ketika tidak ada Product override atau
Category default. Karena itu audit tersebut dilaporkan `INFO`, bukan kegagalan.

## Cara Menjalankan

Jalankan seluruh file berikut di Supabase SQL Editor:

```text
supabase/diagnostics/g2_phase28_tax_resolver_snapshot_preflight.sql
```

Kirim seluruh hasil `check_name,status,details` sebelum migration resolver
ditulis atau dijalankan.

## Interpretasi

- `BLOCKER`: hentikan rollout dan perbaiki invariant/data terlebih dahulu;
- `PASS`: invariant yang diuji bersih;
- `INFO`: inventory untuk menentukan migration berikutnya, bukan error.

Expected pada database yang masih belum memakai Tax di transaksi:

- seluruh check invariant `PASS`;
- inventory snapshot transaksi boleh nol;
- `routines_referencing_tax_snapshot` expected nol karena checkout Tax memang
  masih disabled;
- scope enabled tanpa assignment boleh menghasilkan `no tax`, sesuai resolver
  yang disetujui.

## Next Gate

Setelah hasil live bersih, buat migration resolver private yang tenant-safe dan
effective-dated, lalu unit/behavioral test kalkulasi `PER_LINE` dan
`PER_DOCUMENT`. Integrasi checkout/Purchase/jurnal tetap menjadi gate terpisah
dan tidak boleh dicutover dari preflight ini.
