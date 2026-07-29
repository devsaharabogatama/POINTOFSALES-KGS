# G3 Phase 13 — Bundle Master API/UI

## Outcome

Backoffice menyediakan menu `Sales > Bundle` untuk membuat dan mengubah SKU
Bundle virtual melalui RPC `save_bundle_with_components`. Bundle tidak memiliki
saldo, FIFO, UOM pembelian, atau Stock Movement sendiri.

UI memakai nama Product, nama UOM, dan nama Gudang. UUID serta kode teknis UOM
tidak ditampilkan. SKU Bundle tetap ditampilkan karena merupakan identitas
bisnis yang digunakan user.

## Boundary

Fase ini hanya membuka master dan read model ketersediaan:

- create/edit Product Bundle + satu UOM jual + komponen secara atomic;
- harga diisi langsung sebagai harga jual final;
- berat Bundle dihitung server-side dari berat, faktor UOM, dan quantity
  komponen;
- availability per Gudang dihitung dari komponen paling membatasi;
- Product stok dan Bundle dipisahkan pada layar.

Fase ini tidak membuka checkout, reservasi, sale posting, konsumsi FIFO,
alokasi revenue/COGS, Return, offline sync, atau Import Bundle. Semua itu tetap
menunggu gate transaksi yang sesuai.

## Local Evidence

```powershell
cd backoffice
npm.cmd run lint
npm.cmd run build
```

Expected lint dan production build exit code `0`, serta route:

- `/api/master/bundles`;
- `/api/master/bundles/[id]`;
- `/api/master/bundles/[id]/availability`.

## Authenticated Smoke

Prasyarat: migration `20260729010000` dan seluruh database test Phase 12 PASS.

1. Restart Backoffice dan login sebagai Company Admin/Super Admin.
2. Buka launcher `Sales`, lalu `Bundle`.
3. Buat Bundle dengan minimal dua komponen Product stok memakai UOM berbeda.
4. Pastikan dropdown menampilkan nama UOM, bukan kode teknis.
5. Isi harga jual final, simpan, lalu buka kembali Edit.
6. Pastikan komposisi, UOM jual, harga, berat turunan, dan status tetap benar.
7. Coba komponen Product+UOM yang sama dua kali; submit harus ditolak.
8. Tekan `Esc` pada modal Edit; modal harus tertutup.
9. Pilih `Cek ketersediaan`, ganti Gudang, dan cocokkan kapasitas dengan stok
   komponen yang paling membatasi.
10. Buka `Inventory > Produk & UOM`; Bundle tidak boleh ikut tampil sebagai
    Product stok fisik.

## Compatibility dan Stop Condition

- Product stok existing, Opening, Transfer, Adjustment, Opname, dan Kartu Stok
  tidak diubah.
- Jika API mengembalikan schema-cache error setelah rollout, reload schema
  cache lalu ulangi smoke; jangan menambah relationship client-side sebagai
  workaround.
- Jika save menghasilkan partial Product/UOM/component, hentikan rollout.
  Kontrak RPC wajib atomic.
- Setelah smoke PASS, next safe step adalah audit exit G3 dan kesiapan
  stress-test stock/FIFO. Jangan langsung mengaktifkan checkout Bundle.
