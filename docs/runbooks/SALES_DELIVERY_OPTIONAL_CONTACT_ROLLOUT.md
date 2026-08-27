# Rollout Kontak Opsional Surat Jalan

## Outcome

Transaksi `DELIVERY` hanya mewajibkan nama penerima. Nomor telepon, alamat,
rencana kirim, catatan, dan ongkir tetap opsional. Nilai yang diisi menjadi
snapshot transaksi dan Surat Jalan; master Customer tidak diubah.

## Urutan Supabase

1. `supabase/diagnostics/sales_delivery_optional_contact_preflight.sql`
2. `supabase/migrations/20260827152000_sales_delivery_optional_contact.sql`
3. `supabase/tests/sales_delivery_optional_contact_postflight.sql`
4. `supabase/tests/sales_delivery_optional_contact_behavior.sql`
5. Jalankan postflight sekali lagi.

## Smoke

1. Pilih Customer yang hanya mempunyai nama.
2. Aktifkan `Perlu dikirim`; pastikan nama penerima terisi dan kosongkan telepon,
   alamat, tanggal, catatan, serta ongkir.
3. POST transaksi online. Sale, Invoice, dan Surat Jalan harus berhasil tepat
   satu kali; Stock, Payment/AR, dan jurnal mengikuti transaksi biasa.
4. Cetak Surat Jalan dari POS dan Backoffice. Nama tampil, sedangkan telepon dan
   alamat kosong ditampilkan secara netral tanpa teks rusak.
5. Ulangi dengan nama penerima kosong. POST wajib ditolak dengan
   `DELIVERY_RECIPIENT_REQUIRED`.
6. Uji satu transaksi offline name-only lalu sync; hasilnya harus identik dan
   retry tidak membuat dokumen kedua.

## Compatibility dan Forward Fix

Dokumen existing tidak diubah. Payload lama yang berisi telepon/alamat tetap
dipertahankan. Migration hanya melonggarkan requiredness, tidak mengubah
fulfillment mode, ongkir, Stock, Payment, Finance, lifecycle, atau permission.
Jika rollout belum lulus, jangan rollback schema setelah name-only document
terbentuk; gunakan forward-fix karena kolom opsional dapat berisi `NULL`.
