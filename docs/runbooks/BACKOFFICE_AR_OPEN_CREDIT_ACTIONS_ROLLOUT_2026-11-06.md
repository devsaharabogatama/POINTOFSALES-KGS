# Backoffice AR Open Credit Actions — Rollout Task 5

Tanggal: 2026-11-06

## Scope

Task 5 menambahkan tindakan Finance manual untuk native Backoffice open credit:

1. alokasikan Credit Note ke Posted Invoice Customer yang sama;
2. refund Cash/Bank dari open credit;
3. konversi open credit menjadi Customer Balance jika feature/policy aktif;
4. gunakan Customer Balance pada Posted Invoice;
5. reversal append-only terhadap tindakan tersebut.

POS Retail, SO/dispatch/initial Invoice, legacy Refund Liability,
Stock/Reservation/FIFO/HPP, dan historical Posted rows tidak diubah.

## Status sebelum rollout

- Audit: complete.
- Task 2/3/4: terbukti live dari output production terakhir.
- Task 5: `NOT_INSTALLED` dari output preflight terakhir.
- Customer Balance KMS/LSM/SMS: foundation dan mapping sehat, tetapi
  entitlement/policy sengaja nonaktif. Tombol terkait saldo harus tetap tidak
  tersedia sampai activation terpisah disetujui.
- Database live Task 5: belum.
- Client deployed: belum.

## Urutan wajib

Jalankan satu file per langkah dan hentikan bila ada `FAIL`, `BLOCKER`, atau
error yang tidak diprediksi.

1. Read-only preflight:
   `supabase/diagnostics/backoffice_ar_open_credit_actions_preflight.sql`
2. Forward migration, hanya jika seluruh mandatory preflight PASS:
   `supabase/migrations/20261106100000_backoffice_ar_open_credit_actions.sql`
3. Read-only postflight:
   `supabase/diagnostics/backoffice_ar_open_credit_actions_postflight.sql`
4. Rollback-only behavior:
   `supabase/tests/backoffice_ar_open_credit_actions_behavior.sql`
5. Ulangi postflight untuk memastikan behavior tidak meninggalkan fixture.
6. Deploy client hanya setelah empat gate database di atas lulus dan ada
   instruksi user terpisah.
7. Authenticated smoke dengan Finance actor, tanpa posting dokumen nyata:
   buka workspace Penerimaan Customer/Open-item AR, cek daftar dan modal;
   mutation nyata menunggu fixture/UAT yang disetujui.

## Expected behavior output

Behavior dianggap lulus hanya bila satu row berikut muncul:

`backoffice_ar_open_credit_actions_behavior,PASS,0,...`

Script sengaja melempar dan menangkap exception rollback internal. Tidak boleh
ada pertambahan production Journal, Financial Event, Customer Balance ledger,
allocation, Stock Movement, atau FIFO allocation setelah script selesai.

## Error protocol

Jika salah satu langkah gagal:

1. jangan menjalankan file berikutnya;
2. simpan error lengkap dan output langkah terakhir;
3. cabut klaim status layer tersebut;
4. klasifikasikan sebagai `PRODUCT FIX`, `TEST HARNESS FIX`, `FIXTURE FIX`,
   atau `PRECONDITION CHANGE`;
5. kembali ke impact audit sebelum patch baru.

## Forward-fix / rollback note

Migration live bersifat immutable. Setelah ledger `20261106100000` tercatat,
jangan mengedit atau menjalankan ulang file migration ini dan jangan menghapus
ledger. Koreksi berikutnya wajib migration version baru.

Rollback bisnis dilakukan melalui RPC reversal append-only. Rollback schema
tidak disediakan karena constraint dan read model sudah menjadi dependency
runtime setelah client deploy; emergency recovery wajib forward-fix dan client
rollback terkoordinasi.

## Status gate

| Gate | Status awal |
| --- | --- |
| AUDIT COMPLETE | YES |
| LOCAL READY | Belum final review |
| DATABASE LIVE | NO |
| CLIENT DEPLOYED | NO |
| SMOKE PASS | NO |
| UAT PASS | NO |
