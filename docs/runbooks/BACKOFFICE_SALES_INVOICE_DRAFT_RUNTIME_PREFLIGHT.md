# Backoffice Sales Invoice Draft Runtime Preflight

Status: **READ-ONLY PREFLIGHT PASS ON ISOLATED DEVELOPMENT**  
Target: isolated Development `fkywtxucmyjvpwdiqpix` only.

Jalankan
`supabase/diagnostics/backoffice_sales_invoice_draft_runtime_preflight.sql`
sebagai satu query. File hanya membaca schema/runtime/data dan tidak membuat
Invoice, DP, Payment Term, Event, Journal, Stock, atau fixture.

Preflight membuktikan dependency function yang benar-benar akan dipakai oleh
behavior test, foundation masih belum dipakai, ledger Qty To Invoice konsisten,
SO invoiceable berada pada lifecycle yang benar, serta commercial/tax snapshot
memiliki bentuk yang dapat diprorata. Row `INFO` melaporkan data nyata tanpa
menjadikan zero row sebagai bukti behavioral.

Stop dan kirim seluruh output bila ada `BLOCKER` atau SQL error. Jika semua
selain `INFO` adalah `PASS`, next artifact adalah guarded runtime Create/Edit/
Cancel Draft Regular Invoice dan DP. Runtime tersebut belum melakukan posting
Finance; posting Revenue/Tax/AR tetap gate berikutnya.
