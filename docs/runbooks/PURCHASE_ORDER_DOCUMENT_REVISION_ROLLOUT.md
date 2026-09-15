# Purchase Order Document and Pre-Receipt Revision

Target wajib isolated Development `fkywtxucmyjvpwdiqpix`. Jangan jalankan pada
production atau staging tanpa production discovery/rehearsal terpisah.

## Impact

- PO list membuka halaman dokumen, bukan expanded row.
- PO harian `CONFIRMED` dapat direvisi sebelum Receipt aktif pertama.
- Product dan source shortage tetap immutable. Supplier, expected date, notes,
  Qty, purchase UOM, harga estimasi, dan Gudang penerimaan per line dapat diedit.
- Revisi versioned, idempotent, tenant-scoped, permission-enforced, dan diaudit.
- Receipt/Stock/FIFO/AP/Bill/Payment/Journal tidak dibuat oleh revisi.
- Setelah Receipt dimulai, revisi ditolak dan koreksi mengikuti Purchase Return.

## Urutan manual gate

1. Jalankan preflight penuh.
2. Jika seluruh status PASS, jalankan migration `20260914170000` penuh.
3. Jalankan behavioral test penuh; seluruh write di-rollback.
4. Jalankan postflight penuh.
5. Restart/muat ulang Backoffice lokal, lalu smoke PO dummy sampai pembayaran.

Gunakan file yang ditautkan pada handoff; jangan menjalankan selected text.

## Authenticated UI smoke

1. Buka `Purchase -> Request Order & Purchase Order -> Purchase Order`.
2. Klik nomor/baris salah satu PO fixture; aplikasi harus membuka halaman
   dokumen penuh, bukan memperluas card/baris.
3. Klik `Edit PO`, ubah minimal satu nilai yang diizinkan, simpan, lalu pastikan
   versi dokumen dan Log aktivitas bertambah.
4. Pastikan PO tidak mempunyai tombol untuk memulai penerimaan. Buka menu
   `Purchase -> Penerimaan Barang`; dokumen Receipt untuk PO dan Gudang tersebut
   harus sudah dibuat sistem. Proses lalu Post dokumen itu dari menu Gudang.
5. Kembali ke PO. Status penerimaan harus berubah dan `Buat Bill` harus membuka
   form Faktur Supplier existing dengan Supplier/AP provisional PO tersebut.
6. Setelah Bill tersimpan, tombol/status harus berubah menjadi `Lihat Bill` dan
   membuka Faktur Supplier terkait, bukan membuat dokumen kedua diam-diam.
7. Pastikan `Edit PO` tidak tersedia setelah Receipt atau Bill dimulai.

Status saat ini: database isolated Development serta behavioral/postflight
`PASS`; client lint, TypeScript, dan build `PASS`; authenticated UI smoke/UAT
belum dicatat. Production/staging tidak disentuh.

## Forward-fix / rollback boundary

Migration yang sudah applied tidak diedit dan tidak memiliki destructive down
migration. Jika smoke menemukan defect, hentikan workflow pada dokumen uji,
audit call chain, lalu buat migration forward-fix additive. Jangan menghapus
Purchase, Receipt, AP provisional, Supplier Invoice, Stock/FIFO, atau audit row.
