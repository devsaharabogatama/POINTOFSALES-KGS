# Rollout Policy Surat Jalan Otomatis per Company

## Outcome

Company dapat memilih di `Platform -> Profil Perusahaan`:

- `Hanya transaksi Perlu dikirim` (default dan kompatibel dengan behavior lama);
- `Semua transaksi final`, termasuk transaksi `PICKUP`.

Policy hanya berlaku untuk Sale baru yang diposting setelah setting aktif.
Dokumen historis tidak dibackfill. Surat Jalan tetap merupakan bukti pemenuhan
dan tidak membuat Stock Movement, Payment, Financial Event, atau Journal baru.

## Lifecycle

- `DELIVERY`: `READY -> DISPATCHED -> DELIVERED`;
- `PICKUP`: `READY -> DELIVERED` melalui tombol **Sudah diserahkan**;
- keduanya boleh dibatalkan hanya saat `READY` dengan alasan.

Untuk Pickup, penerima/telepon/alamat diambil dari snapshot Customer yang sudah
ada. Telepon dan alamat boleh kosong. Master Customer tidak diubah.

## Urutan manual Supabase

1. Jalankan `supabase/diagnostics/company_automatic_delivery_document_policy_preflight.sql`.
2. Hanya lanjut bila tidak ada `BLOCKER`.
3. Jalankan `supabase/migrations/20260827153000_company_automatic_delivery_document_policy.sql`.
4. Jalankan `supabase/tests/company_automatic_delivery_document_policy_postflight.sql`.
5. Jalankan `supabase/tests/company_automatic_delivery_document_policy_behavior.sql`.
6. Jalankan postflight sekali lagi.

## Smoke test

1. Biarkan default `DELIVERY_ONLY`; Post Pickup baru dan pastikan tidak ada SJ.
2. Ubah policy menjadi `ALL_POSTED_SALES`; Post Pickup baru dan pastikan satu SJ
   berlabel `Ambil di toko` muncul pada Inventory.
3. Klik **Sudah diserahkan** dan pastikan status langsung final tanpa status
   `Dalam perjalanan`.
4. Post transaksi Delivery dan pastikan alur Kirim lalu Terkirim tetap sama.
5. Retry/reload dokumen dan pastikan nomor SJ tidak bertambah.
6. Pastikan jumlah Stock Movement, Payment, Financial Event, dan Journal tidak
   bertambah hanya karena cetak atau perubahan status SJ.

## Compatibility dan forward-fix

- Default menjaga behavior lama.
- Signature RPC enam parameter tetap menjadi wrapper dan mempertahankan policy.
- Dokumen lama dibackfill `fulfillment_mode='DELIVERY'` dari source Sale.
- Bila rollout bermasalah, jangan drop kolom atau histori. Kembalikan seluruh
  Company ke `DELIVERY_ONLY`, lalu lakukan forward-fix function/constraint.
