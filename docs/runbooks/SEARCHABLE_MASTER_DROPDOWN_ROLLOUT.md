# Searchable Master Dropdown Rollout

Status: **LOCAL READY; CLIENT DEPLOYMENT AND AUTHENTICATED VISUAL SMOKE PENDING**.

## Keputusan User

- Dropdown master yang mempunyai banyak pilihan harus dapat dicari seperti
  combobox Odoo.
- Pencarian tidak case-sensitive.
- Dropdown dengan kurang dari 10 pilihan tetap memakai dropdown native dan
  langsung menampilkan seluruh pilihan.
- Dropdown kecil seperti status, Ya/Tidak, jenis aksi, dan pilihan tetap tidak
  membutuhkan kotak pencarian.

## Implementasi

Backoffice dan PWA memasang progressive enhancer pada root client. Elemen
`select` existing tetap menjadi pemilik value dan tetap menjalankan handler
`onChange` existing. Ketika terdapat minimal 10 pilihan aktif non-placeholder,
klik atau keyboard membuka combobox pencarian.

Pencarian menggunakan seluruh label yang terlihat, case-insensitive, dan juga
menormalkan tanda diakritik. Pemilihan mendukung mouse, Enter, Arrow Up/Down,
dan Escape. Popup memakai portal sehingga tidak terpotong tabel, modal, atau
container `overflow`.

## Impact Map

### Direct impact

- Seluruh dropdown panjang Backoffice.
- Seluruh dropdown panjang PWA.
- Interaksi mouse, touch, dan keyboard ketika memilih master data.

### Tidak berubah

- ID/value yang dikirim oleh form.
- API/RPC, schema, RLS, permission, dan feature entitlement.
- Product, Customer, Supplier, Gudang, UOM, COA, Payment, Stock, FIFO,
  Reservation, Cashier Session, dan Finance rule.
- Dropdown dengan kurang dari 10 pilihan.

### Risiko regression

- Native `change` event tidak mencapai handler React.
- Popup terpotong atau berada di luar viewport.
- Controlled value berubah di tab/form lain ketika popup terbuka.
- Keyboard atau touch membuka native select dan popup bersamaan.

Mitigasi yang dipasang: native value setter + bubbling `change`, portal ke
`document.body`, reposition saat scroll/resize, observasi perubahan option,
dan interception hanya pada select eligible.

## Evidence Lokal

- Backoffice targeted ESLint: PASS.
- Backoffice TypeScript: PASS.
- Backoffice production build: PASS, 87 halaman.
- PWA targeted Oxlint: PASS.
- PWA TypeScript build: PASS.
- PWA production build/PWA generation: PASS.
- Static contract: jalankan
  `node scripts/test-searchable-master-dropdown-contract.mjs`.

## Authenticated Visual Smoke

Setelah client dideploy, jalankan minimum berikut pada data yang tidak akan
diposting:

1. Backoffice: buka Quotation, klik Customer dengan minimal 10 pilihan, ketik
   sebagian nama menggunakan kapitalisasi berbeda, pilih hasil, lalu pastikan
   Customer terisi benar.
2. Backoffice: tambah line Product, cari dengan sebagian SKU dan nama, pilih,
   lalu pastikan UOM/harga preview berasal dari Product yang dipilih.
3. Backoffice: buka form Supplier/PO/Gudang/COA yang mempunyai minimal 10
   pilihan dan ulangi pencarian.
4. PWA: buka pemilihan Customer atau Product dengan minimal 10 pilihan, cari,
   pilih, dan pastikan cart/form memakai ID yang benar.
5. Uji Arrow Up/Down, Enter, Escape, klik di luar popup, serta teks yang tidak
   mempunyai hasil.
6. Buka dropdown dengan 9 pilihan atau kurang dan pastikan dropdown native
   tetap terbuka tanpa kotak pencarian.
7. Ulangi pada layar tablet/mobile dan pastikan popup tidak keluar viewport.

Tidak perlu membuat/post transaksi untuk smoke ini. Jika ditemukan masalah,
rollback client ke commit sebelumnya; tidak ada rollback database.

