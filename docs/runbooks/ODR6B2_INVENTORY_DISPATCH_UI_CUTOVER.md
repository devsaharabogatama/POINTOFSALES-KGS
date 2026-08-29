# ODR-6B.2 Inventory Dispatch UI Cutover

## Status

Local client verification **PASS**. Database canonical Dispatch/Received sudah
live dari ODR-3C dan Finance hook ODR-5C/5E; tahap ini tidak menambah migration.
Rollout Backoffice dan authenticated smoke masih harus dijalankan manual.

## Batas perubahan

- Menu `Inventory -> Surat Jalan` membaca workspace Dispatch canonical.
- `Kirim barang` mendukung partial maupun full Dispatch per baris.
- Dispatch mengurangi On Hand, FIFO, dan Reserved Out dengan quantity yang sama.
- `Tandai diterima` hanya menyimpan bukti penerimaan; tidak mengurangi stok lagi.
- Dokumen legacy tanpa Reservation tetap memakai jalur lama untuk compatibility.
- Pembatalan order linked tidak tersedia dari Inventory; lakukan dari kanal
  Sales Order/POS supaya Reservation dilepas atomik.
- Tidak ada perubahan policy POS, Purchasing, atau Finance pada tahap ini.

## Urutan rollout

1. Jalankan SELECT-only preflight:
   [`odr_phase6b_inventory_dispatch_ui_preflight.sql`](../../supabase/diagnostics/odr_phase6b_inventory_dispatch_ui_preflight.sql).
2. Semua baris selain `INFO` wajib `PASS`. Jangan deploy bila ada `BLOCKER`.
3. Deploy **Backoffice saja**, lalu hard refresh browser.
4. Gunakan satu Surat Jalan linked berstatus `READY` untuk smoke di bawah.
5. Jalankan SELECT-only closing postflight:
   [`odr_phase6b_inventory_dispatch_ui_postflight.sql`](../../supabase/tests/odr_phase6b_inventory_dispatch_ui_postflight.sql).
6. Semua baris selain `INFO` wajib `PASS`.

## Authenticated smoke

1. Buka `Inventory -> Surat Jalan`, lalu buka satu dokumen linked `READY`.
2. Catat On Hand, Reserved, dan Available untuk Product terkait di Stock Real.
3. Klik `Kirim barang`, isi sebagian quantity pada minimal satu baris, dan
   konfirmasi.
4. Pastikan status menjadi `Dikirim sebagian`, On Hand turun hanya sebesar
   quantity yang dikirim, Reserved turun dengan quantity yang sama, dan
   Available tidak berubah akibat pasangan penurunan tersebut.
5. Muat ulang halaman. Sisa quantity harus tetap sama dan tindakan dapat
   dilanjutkan tanpa mengulang efek sebelumnya.
6. Kirim seluruh sisa. Status menjadi `Dalam perjalanan`, Reservation menjadi
   consumed, dan On Hand/FIFO/Movement sesuai quantity total Dispatch.
7. Klik `Tandai diterima`, isi nama penerima, lalu konfirmasi. Status menjadi
   `Terkirim` dan On Hand/Reserved tidak berubah lagi.
8. Untuk Company dengan posting `CONTROLLED`, event Dispatch boleh tetap
   `HOLD` sampai Finance memproses queue. Jangan memproses queue sebagai bagian
   dari smoke Inventory ini.
9. Pastikan satu Surat Jalan historis tanpa Reservation masih dapat dibuka,
   dicetak, dan diunduh.

## Evidence lokal

- `backoffice npm run lint`: PASS.
- `backoffice npm run build`: PASS, termasuk TypeScript dan 76 route/page.
- Source contract: GET workspace, canonical Dispatch, canonical Received,
  linked-cancel guard, partial status, dan remaining quantity seluruhnya PASS.

## Compatibility dan rollback

- Perubahan client dapat di-rollback dengan redeploy build Backoffice sebelum
  cutover; tidak ada schema/data yang perlu dikembalikan.
- Jangan memakai postflight ODR-3C lama untuk smoke ini karena check
  `zero finance effect` sudah tidak berlaku setelah runtime Finance ODR-5C.
  Gunakan closing postflight ODR-6B.2 di atas.
