# ODR-4E — Sinkronisasi Satu Draft PO

## Outcome

Delta positif managed Stock Request dapat menambah quantity pada tepat satu
baris Draft PO yang seluruh quantity-nya mempunyai allocation. Perubahan
menaikkan version PO, menulis audit, dan menyelesaikan notice terkait.

PO final, target ambigu, quantity manual/campuran, serta konversi UOM yang tidak
presisi tidak dimutasi otomatis. Stock, FIFO, Movement, AP, Financial Event, dan
Journal tidak berubah pada fase ini.

## Urutan manual

1. Jalankan migration
   `supabase/migrations/20260828200000_odr_phase4e_single_draft_po_sync.sql`.
2. Jalankan
   `supabase/tests/odr_phase4e_single_draft_po_sync_postflight.sql`.
3. Jalankan rollback-safe structural behavior
   `supabase/tests/odr_phase4e_single_draft_po_sync_behavior.sql`.
4. Jalankan postflight sekali lagi.

Semua check selain `INFO` wajib `PASS`. Migration memerlukan tidak ada open
procurement amendment agar cutover tidak menebak tindakan terhadap notice lama.

## Forward-fix

Migration bersifat transactional dan tidak mempunyai backfill. Setelah ledger
tercatat jangan menjalankan rollback destruktif. Koreksi dilakukan dengan
forward migration sambil mempertahankan audit dan allocation lineage.

## Smoke setelah SQL gate

Gunakan Company dummy. Buat shortage Order dalam satu sesi, tutup sesi, lalu
alokasikan request ke satu Draft PO. Ubah quantity Order ke atas dan pastikan:

- Draft PO bertambah tepat sebesar delta;
- version dan audit PO bertambah satu;
- retry tidak menambah quantity kedua kali;
- setelah PO dikonfirmasi, perubahan berikutnya hanya menghasilkan amendment.
