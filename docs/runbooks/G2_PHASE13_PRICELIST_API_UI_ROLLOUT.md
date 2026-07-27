# Runbook G2 Fase 13 - Pricelist API/UI

**Status:** LOCAL READY — READY FOR AUTHENTICATED SMOKE TEST  
**Dependency:** migration `20260722080000`, 6 guard postflight PASS, guard behavioral test PASS

## Scope

- menu Backoffice `Pricelist`;
- daftar Global dan Customer Pricelist untuk active Company;
- create/update melalui `save_pricelist_with_rules(...)`, bukan direct table write;
- scope semua/specific Store;
- Product dan UOM jual dipilih berdasarkan nama user-facing;
- Global mendukung quantity tier;
- Customer-specific otomatis memakai minimum quantity 1;
- harga biasa diisi langsung sebagai harga akhir Pricelist;
- potongan per UOM hanya ditawarkan untuk quantity tier Global;
- optimistic `master_version`, validation API, error mapping, dan tombol `Esc`
  untuk menutup modal.

Fase ini tidak mengaktifkan resolver harga, tidak mengubah checkout, dan tidak
mengubah harga transaksi. Product-UOM `sale_price` masih menjadi fallback flow
existing.

## Evidence Lokal

- `npm run lint`: PASS;
- `npm run build`: PASS dengan Next.js 16.2.10;
- route dinamis build:
  - `/api/master/pricelists`;
  - `/api/master/pricelists/[id]`.

## Smoke Test Manual

1. Restart Backoffice setelah build terbaru.
2. Buka menu `Pricelist`; pastikan `Harga Umum` tampil tanpa notifikasi error.
3. Edit `Harga Umum`, tambah rule:
   - pilih Product berdasarkan nama;
   - pilih UOM berdasarkan nama, bukan UUID atau kode `UOM-xx`;
   - isi harga akhir langsung, misalnya harga normal Rp5.000 menjadi Rp4.000
     dengan memasukkan `4000`, bukan potongan `1000`;
   - muat ulang dan pastikan rule tetap tampil.
4. Buat Global Pricelist baru dengan minimum quantity lebih dari 1.
   Pada tier ini opsi potongan per UOM tetap tersedia.
5. Buat Customer Pricelist:
   - pilih Customer biasa berdasarkan nama;
   - minimum quantity harus terkunci pada 1;
   - Pelanggan Umum tidak boleh muncul pada pilihan.
6. Uji `Semua toko` dan specific Store; nama toko harus tampil.
7. Tekan `Esc` pada modal dan pastikan modal tertutup tanpa menyimpan.
8. Pastikan menu Product, Customer, Supplier, dan menu existing tetap terbuka.
9. Pastikan checkout/POS existing tidak berubah dan tidak mengambil Pricelist
   baru pada fase ini.

## Stop Conditions

- Jika ada error schema cache/relationship, kirim teks lengkap sebelum membuat
  perubahan database. API fase ini sengaja menggabungkan tabel dari query
  terpisah agar tidak bergantung pada nested relationship PostgREST.
- Jika save gagal, kirim response error dan form yang digunakan; jangan membuka
  direct INSERT/UPDATE table sebagai workaround.
- Jangan mengaktifkan resolver atau checkout cutover sebelum smoke master PASS.

## Next Safe Step

Setelah smoke PASS, tutup G2 Pricelist master. Lanjutkan urutan G2 berikutnya
berdasarkan implementation gate; server price resolver tetap bagian G4 dan
tidak boleh disisipkan ke master UI.
