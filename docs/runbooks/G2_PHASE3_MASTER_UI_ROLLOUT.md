# Runbook G2 Fase 3 - Canonical Master UI

**Scope:** Frontend Backoffice untuk Product Category, UOM, dan Warehouse  
**Requirement:** MST-002, MST-003, MST-004  
**Dependency:** G2 fase 2 canonical master API complete  
**Status:** COMPLETE - LOCAL AUTHENTICATED CREATE/EDIT SMOKE PASS

## Implementasi

- Menu `Master Data` tersedia di navigasi Backoffice.
- Tiga tab tersedia: `Kategori Produk`, `UOM`, dan `Gudang`.
- List memuat record aktif dan nonaktif pada Company aktif.
- Role pengelola dapat menambah, mengedit, serta menonaktifkan/mengaktifkan record.
- Tidak ada hard delete.
- Edit mengirim `masterVersion`; konflik perubahan menghasilkan pesan untuk memuat ulang.
- Company tidak dapat dipilih dari form dan tidak dikirim dari browser. API tetap memakai active Company server-side.
- Warehouse tipe `Toko` wajib memilih Store Company aktif.
- Lokasi Warehouse opsional dan boleh sama untuk beberapa gudang fungsional.
- `Dapat menerima stok pembelian` berarti Warehouse dapat dipilih sebagai tujuan penerimaan barang dari vendor; bukan alamat vendor.
- UOM decimal menampilkan pengaturan precision; UOM non-decimal selalu precision `0`.
- Halaman Product lama belum dipindahkan ke canonical Category/Product-UOM pada fase ini.

## Verifikasi Otomatis Lokal

Jalankan dari folder `backoffice`:

```powershell
npm.cmd run lint
npm.cmd run build
```

Expected: kedua command selesai dengan exit code `0`. Build harus tetap memuat
seluruh route master fase 2.

Local authenticated review pada 2026-07-21 dikonfirmasi berhasil: Category,
UOM, dan Warehouse dapat dibuat dan diedit tanpa error.

## Review Manual Wajib

1. Restart Backoffice lokal agar bundle terbaru digunakan.
2. Login sebagai Super Admin atau role pengelola Company.
3. Pastikan Company aktif adalah Company yang memang hendak dikonfigurasi.
4. Buka menu `Master Data`; pastikan tidak ada notifikasi gagal memuat.
5. Buka ketiga tab dan pastikan empty state/list tampil dengan benar.
6. Buka form `Tambah` pada setiap tab tanpa menyimpan data dummy:
   - Category menampilkan kode, nama, dan status aktif;
   - UOM menampilkan jenis, dukungan decimal, dan precision;
   - Warehouse menampilkan tipe, Store, lokasi, dan sumber/tujuan transaksi.
7. Jika sudah memiliki nilai master riil, simpan masing-masing satu record lalu
   edit kembali untuk membuktikan update/version flow. Jangan buat nilai contoh
   yang tidak akan dipakai operasional.
8. Cek kembali menu lama Backoffice dan POS; fase ini tidak boleh mengubah flow-nya.

## Stop Condition

- `401`: session login invalid; login ulang, jangan bypass bearer token.
- `ACTIVE_COMPANY_NOT_FOUND`: pilih Company aktif sebelum membuka Master Data.
- `403`: role tidak diizinkan; jangan mengganti ke service-role dari frontend.
- `409`: record sudah berubah; klik `Muat ulang`, lalu edit versi terbaru.
- Kode/nama duplikat: gunakan master yang sudah ada atau koreksi kebijakan kode.
- Jangan lanjut ke Product cutover bila salah satu tab gagal dimuat/disimpan.

## Belum Termasuk

- Form Product canonical dan atomic Product-UOM write.
- Cutover Product lama dari free-text Category/UOM.
- Import dry-run, row error, dan import history.
- Deployment Vercel; tetap dijadwalkan setelah G2 exit gate.
