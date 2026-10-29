"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import type { ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import { CheckCircle2, CircleAlert, Loader2, Plus, RefreshCcw, Trash2, X } from "lucide-react";
import { userFacingError } from "@/lib/user-facing-error";

type DocumentRow = {
  id: string;
  document_no: string;
  effective_date: string;
  external_reference: string | null;
  description: string;
  status: "DRAFT" | "SUBMITTED" | "POSTED" | "CANCELED";
  total_debit: number | string;
  total_credit: number | string;
  journal_id: string | null;
  master_version: number | string;
  created_by: string;
  created_at: string;
};

type StoredLine = {
  id: string;
  document_id: string;
  line_no: number;
  line_type: "GL" | "RECEIVABLE" | "PAYABLE";
  account_id: string;
  customer_id: string | null;
  supplier_id: string | null;
  source_document_no: string | null;
  source_document_date: string | null;
  due_date: string | null;
  debit: number | string;
  credit: number | string;
  description: string | null;
};

type Choice = { id: string; code: string; name: string };
type Account = Choice & { type: string };
type Period = { id: string; startDate: string; endDate: string; status: string };
type Workspace = {
  companyId: string;
  currentUserId: string;
  capabilities: string[];
  documents: DocumentRow[];
  lines: StoredLine[];
  accounts: Account[];
  customers: Choice[];
  suppliers: Choice[];
  periods: Period[];
};

type EditLine = {
  key: string;
  lineType: "GL" | "RECEIVABLE" | "PAYABLE";
  accountId: string;
  customerId: string;
  supplierId: string;
  debit: string;
  credit: string;
  description: string;
};

const errors: Record<string, string> = {
  OPENING_BALANCE_PERIOD_NOT_OPEN: "Tanggal saldo awal belum mempunyai accounting period OPEN/REOPENED.",
  OPENING_BALANCE_CONTROL_ACCOUNT_REQUIRES_DETAIL:
    "Akun Inventory/AR/AP tidak boleh menjadi baris GL biasa. Gunakan Stok Awal, Piutang, atau Utang.",
  OPENING_RECEIVABLE_ACCOUNT_INVALID: "Akun pada baris Piutang bukan mapping CUSTOMER_RECEIVABLE aktif.",
  OPENING_PAYABLE_ACCOUNT_INVALID: "Akun pada baris Utang bukan mapping SUPPLIER_AP_FINAL aktif.",
  OPENING_BALANCE_SELF_APPROVAL_FORBIDDEN: "Pembuat draft tidak boleh memposting draftnya sendiri.",
  JOURNAL_UNBALANCED: "Total Debit dan Kredit harus sama dan lebih besar dari nol.",
  MASTER_VERSION_CONFLICT: "Draft sudah berubah. Muat ulang sebelum melanjutkan.",
  IDENTITY_INVALID: "Runtime Saldo Awal belum terpasang pada database ini.",
};

function today() {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
}

function rupiah(value: number | string) {
  return new Intl.NumberFormat("id-ID", { style: "currency", currency: "IDR", maximumFractionDigits: 0 }).format(Number(value) || 0);
}

function blankLine(lineType: EditLine["lineType"] = "GL"): EditLine {
  return {
    key: crypto.randomUUID(),
    lineType,
    accountId: "",
    customerId: "",
    supplierId: "",
    debit: "",
    credit: "",
    description: "",
  };
}

export function OpeningBalanceView({ session, notify }: { session: Session; notify: (message: string) => void }) {
  const [workspace, setWorkspace] = useState<Workspace | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [formOpen, setFormOpen] = useState(false);
  const [documentId, setDocumentId] = useState<string | null>(null);
  const [masterVersion, setMasterVersion] = useState<number | null>(null);
  const [effectiveDate, setEffectiveDate] = useState(today());
  const [externalReference, setExternalReference] = useState("");
  const [description, setDescription] = useState("Saldo awal perusahaan");
  const [lines, setLines] = useState<EditLine[]>([blankLine(), blankLine()]);

  const load = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      const response = await fetch("/api/finance/opening-balances", {
        headers: { Authorization: `Bearer ${session.access_token}` },
        cache: "no-store",
      });
      const payload = (await response.json()) as { data?: Workspace; error?: string };
      if (!response.ok || !payload.data) throw new Error(payload.error ?? "OPENING_BALANCE_LOAD_FAILED");
      setWorkspace(payload.data);
    } catch (caught) {
      setError(userFacingError(caught instanceof Error ? caught.message : undefined, errors, "Workspace Saldo Awal belum dapat dimuat."));
    } finally {
      setLoading(false);
    }
  }, [session.access_token]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- remote workspace follows the authenticated active Company
    void load();
  }, [load]);

  const capabilities = new Set(workspace?.capabilities ?? []);
  const totalDebit = lines.reduce((sum, line) => sum + (Number(line.debit) || 0), 0);
  const totalCredit = lines.reduce((sum, line) => sum + (Number(line.credit) || 0), 0);
  const balanced = totalDebit > 0 && Math.abs(totalDebit - totalCredit) < 0.0001;
  const dateHasOpenPeriod = useMemo(
    () => (workspace?.periods ?? []).some((period) => ["OPEN", "REOPENED"].includes(period.status)
      && effectiveDate >= period.startDate && effectiveDate <= period.endDate),
    [effectiveDate, workspace?.periods],
  );

  function reset() {
    setFormOpen(false);
    setDocumentId(null);
    setMasterVersion(null);
    setEffectiveDate(today());
    setExternalReference("");
    setDescription("Saldo awal perusahaan");
    setLines([blankLine(), blankLine()]);
    setError("");
  }

  function edit(document: DocumentRow) {
    const stored = (workspace?.lines ?? []).filter((line) => line.document_id === document.id);
    setDocumentId(document.id);
    setMasterVersion(Number(document.master_version));
    setEffectiveDate(document.effective_date);
    setExternalReference(document.external_reference ?? "");
    setDescription(document.description);
    setLines(stored.map((line) => ({
      key: line.id,
      lineType: line.line_type,
      accountId: line.account_id,
      customerId: line.customer_id ?? "",
      supplierId: line.supplier_id ?? "",
      debit: Number(line.debit) ? String(line.debit) : "",
      credit: Number(line.credit) ? String(line.credit) : "",
      description: line.description ?? "",
    })));
    setFormOpen(true);
  }

  function patchLine(key: string, patch: Partial<EditLine>) {
    setLines((current) => current.map((line) => line.key === key ? { ...line, ...patch } : line));
  }

  async function request(body: Record<string, unknown>, message: string) {
    setBusy(true);
    setError("");
    try {
      const response = await fetch("/api/finance/opening-balances", {
        method: "POST",
        headers: { Authorization: `Bearer ${session.access_token}`, "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const payload = (await response.json()) as { data?: { documentId?: string; masterVersion?: number }; error?: string };
      if (!response.ok) throw new Error(payload.error ?? "OPENING_BALANCE_OPERATION_FAILED");
      notify(message);
      reset();
      await load();
    } catch (caught) {
      setError(userFacingError(caught instanceof Error ? caught.message : undefined, errors, "Operasi Saldo Awal belum berhasil."));
    } finally {
      setBusy(false);
    }
  }

  async function save() {
    await request({
      action: "SAVE_DRAFT",
      documentId,
      masterVersion,
      operationKey: crypto.randomUUID(),
      effectiveDate,
      externalReference,
      description,
      lines: lines.map((line) => ({
        lineType: line.lineType,
        accountId: line.accountId,
        customerId: line.customerId,
        supplierId: line.supplierId,
        debit: line.debit,
        credit: line.credit,
        description: line.description,
      })),
    }, "Draft Saldo Awal tersimpan.");
  }

  if (loading && !workspace) {
    return <div className="grid min-h-80 place-items-center rounded-3xl border border-slate-200 bg-white"><Loader2 className="h-7 w-7 animate-spin text-violet-600" /></div>;
  }

  return (
    <div className="space-y-5">
      <section className="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <p className="text-xs font-black uppercase tracking-wider text-violet-600">Opening Finance</p>
            <h2 className="mt-2 text-xl font-black">Saldo Awal langsung dari aplikasi</h2>
            <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">
              GL, piutang per Customer, dan utang per Supplier berada dalam satu draft. Posting membuat satu jurnal OPENING_BALANCE; tidak perlu export/import.
            </p>
          </div>
          <div className="flex gap-2">
            <button type="button" onClick={() => void load()} className="inline-flex min-h-11 items-center gap-2 rounded-xl border border-slate-200 px-4 text-sm font-black"><RefreshCcw className="h-4 w-4" /> Muat ulang</button>
            <button type="button" disabled={!capabilities.has("CREATE_DRAFT")} onClick={() => { reset(); setFormOpen(true); }} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-violet-600 px-4 text-sm font-black text-white disabled:opacity-40"><Plus className="h-4 w-4" /> Draft baru</button>
          </div>
        </div>
        <div className="mt-5 grid gap-3 md:grid-cols-2">
          <div className="rounded-2xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900">
            <b>Persediaan tidak diinput di sini.</b> Gunakan Inventory &gt; Stok Awal agar quantity, FIFO, Inventory GL, dan Opening Clearing terbentuk bersama.
          </div>
          <div className="rounded-2xl border border-sky-200 bg-sky-50 p-4 text-sm leading-6 text-sky-900">
            Piutang diinput sebagai total saldo per Customer dan Utang sebagai total saldo per Supplier. Histori invoice lama tidak perlu dibuat ulang.
          </div>
        </div>
      </section>

      {error && <div className="rounded-2xl border border-rose-200 bg-rose-50 p-4 text-sm font-bold text-rose-800">{error}</div>}

      <section className="overflow-hidden rounded-3xl border border-slate-200 bg-white shadow-sm">
        <div className="border-b border-slate-100 p-5"><h3 className="font-black">Dokumen Saldo Awal</h3></div>
        <div className="overflow-x-auto">
          <table className="w-full min-w-[900px] text-left text-sm">
            <thead className="bg-slate-50 text-xs uppercase text-slate-500"><tr><th className="p-3">Dokumen</th><th className="p-3">Tanggal</th><th className="p-3">Keterangan</th><th className="p-3">Status</th><th className="p-3 text-right">Debit</th><th className="p-3 text-right">Kredit</th><th className="p-3">Aksi</th></tr></thead>
            <tbody className="divide-y divide-slate-100">
              {(workspace?.documents ?? []).map((document) => <tr key={document.id}>
                <td className="p-3 font-black">{document.document_no}<span className="block text-xs font-normal text-slate-500">{document.external_reference ?? "Tanpa referensi"}</span></td>
                <td className="p-3">{new Date(`${document.effective_date}T00:00:00`).toLocaleDateString("id-ID")}</td>
                <td className="p-3">{document.description}</td>
                <td className="p-3"><span className={`rounded-full px-2 py-1 text-xs font-black ${document.status === "POSTED" ? "bg-emerald-50 text-emerald-700" : document.status === "CANCELED" ? "bg-rose-50 text-rose-700" : "bg-amber-50 text-amber-700"}`}>{document.status}</span></td>
                <td className="p-3 text-right font-bold">{rupiah(document.total_debit)}</td>
                <td className="p-3 text-right font-bold">{rupiah(document.total_credit)}</td>
                <td className="p-3"><div className="flex flex-wrap gap-2">
                  {document.status === "DRAFT" && <button type="button" disabled={!capabilities.has("EDIT_DRAFT")} onClick={() => edit(document)} className="rounded-lg border border-slate-200 px-3 py-2 text-xs font-black disabled:opacity-40">Edit</button>}
                  {document.status === "DRAFT" && <button type="button" disabled={!capabilities.has("EDIT_DRAFT") || Number(document.total_debit) !== Number(document.total_credit)} onClick={() => void request({ action: "SUBMIT", documentId: document.id, masterVersion: Number(document.master_version) }, "Draft diajukan untuk posting.")} className="rounded-lg bg-violet-600 px-3 py-2 text-xs font-black text-white disabled:opacity-40">Ajukan</button>}
                  {document.status === "SUBMITTED" && <button type="button" disabled={!capabilities.has("APPROVE") || document.created_by === workspace?.currentUserId} onClick={() => void request({ action: "POST", documentId: document.id, masterVersion: Number(document.master_version), idempotencyKey: crypto.randomUUID() }, "Saldo Awal berhasil diposting.")} className="rounded-lg bg-emerald-600 px-3 py-2 text-xs font-black text-white disabled:opacity-40">Approve & posting</button>}
                  {["DRAFT", "SUBMITTED"].includes(document.status) && <button type="button" disabled={!capabilities.has("EDIT_DRAFT")} onClick={() => { const reason = window.prompt("Alasan pembatalan draft Saldo Awal"); if (reason?.trim()) void request({ action: "CANCEL", documentId: document.id, masterVersion: Number(document.master_version), reason }, "Dokumen Saldo Awal dibatalkan."); }} className="rounded-lg border border-rose-200 px-3 py-2 text-xs font-black text-rose-700 disabled:opacity-40">Batalkan</button>}
                </div></td>
              </tr>)}
              {!workspace?.documents.length && <tr><td colSpan={7} className="p-10 text-center text-slate-500">Belum ada dokumen Saldo Awal.</td></tr>}
            </tbody>
          </table>
        </div>
      </section>

      {formOpen && <div className="fixed inset-0 z-[95] flex items-center justify-center bg-slate-950/65 p-4" onMouseDown={(event) => { if (event.target === event.currentTarget && !busy) reset(); }}>
        <section role="dialog" aria-modal="true" aria-labelledby="opening-balance-title" className="max-h-[94vh] w-full max-w-7xl overflow-y-auto rounded-3xl bg-white p-5 shadow-2xl sm:p-6">
          <div className="flex items-start justify-between gap-4"><div><p className="text-xs font-black uppercase text-violet-600">Draft Saldo Awal</p><h2 id="opening-balance-title" className="mt-2 text-xl font-black">{documentId ? "Edit draft" : "Dokumen baru"}</h2></div><button type="button" onClick={reset} disabled={busy} aria-label="Tutup form" className="grid h-11 w-11 place-items-center rounded-xl border border-slate-200"><X className="h-5 w-5" /></button></div>
          {error && <p className="mt-4 rounded-xl bg-rose-50 p-3 text-sm font-bold text-rose-800">{error}</p>}
          <div className="mt-5 grid gap-4 md:grid-cols-3">
            <Field label="Tanggal efektif"><input type="date" value={effectiveDate} onChange={(event) => setEffectiveDate(event.target.value)} /></Field>
            <Field label="Referensi (opsional)"><input value={externalReference} maxLength={200} onChange={(event) => setExternalReference(event.target.value)} placeholder="Neraca manual / cut-off" /></Field>
            <Field label="Keterangan"><input value={description} maxLength={1000} onChange={(event) => setDescription(event.target.value)} /></Field>
          </div>
          {!dateHasOpenPeriod && <div className="mt-4 flex items-start gap-2 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm font-bold text-amber-900"><CircleAlert className="mt-0.5 h-4 w-4 shrink-0" /> Buat atau buka accounting period yang mencakup tanggal ini sebelum menyimpan.</div>}
          <div className="mt-5 flex flex-wrap gap-2">
            <button type="button" onClick={() => setLines((current) => [...current, blankLine("GL")])} className="rounded-xl border border-slate-200 px-4 py-2 text-sm font-black">+ Baris GL</button>
            <button type="button" onClick={() => setLines((current) => [...current, blankLine("RECEIVABLE")])} className="rounded-xl border border-slate-200 px-4 py-2 text-sm font-black">+ Piutang Customer</button>
            <button type="button" onClick={() => setLines((current) => [...current, blankLine("PAYABLE")])} className="rounded-xl border border-slate-200 px-4 py-2 text-sm font-black">+ Utang Supplier</button>
          </div>
          <div className="mt-4 overflow-x-auto rounded-2xl border border-slate-200">
            <table className="w-full min-w-[1100px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase text-slate-500"><tr><th className="p-3">Jenis</th><th className="p-3">Akun</th><th className="p-3">Customer / Supplier</th><th className="p-3">Keterangan</th><th className="p-3">Debit</th><th className="p-3">Kredit</th><th className="p-3" /></tr></thead>
              <tbody className="divide-y divide-slate-100">{lines.map((line) => <tr key={line.key}>
                <td className="p-3"><select value={line.lineType} onChange={(event) => patchLine(line.key, { lineType: event.target.value as EditLine["lineType"], customerId: "", supplierId: "" })}><option value="GL">GL</option><option value="RECEIVABLE">Piutang</option><option value="PAYABLE">Utang</option></select></td>
                <td className="p-3"><select value={line.accountId} onChange={(event) => patchLine(line.key, { accountId: event.target.value })}><option value="">Pilih akun</option>{workspace?.accounts.map((account) => <option key={account.id} value={account.id}>{account.code} · {account.name}</option>)}</select></td>
                <td className="p-3">{line.lineType === "RECEIVABLE" ? <select value={line.customerId} onChange={(event) => patchLine(line.key, { customerId: event.target.value })}><option value="">Pilih Customer</option>{workspace?.customers.map((choice) => <option key={choice.id} value={choice.id}>{choice.code} · {choice.name}</option>)}</select> : line.lineType === "PAYABLE" ? <select value={line.supplierId} onChange={(event) => patchLine(line.key, { supplierId: event.target.value })}><option value="">Pilih Supplier</option>{workspace?.suppliers.map((choice) => <option key={choice.id} value={choice.id}>{choice.code} · {choice.name}</option>)}</select> : <span className="text-slate-400">—</span>}</td>
                <td className="p-3"><input value={line.description} maxLength={500} onChange={(event) => patchLine(line.key, { description: event.target.value })} placeholder="Opsional" /></td>
                <td className="p-3"><input type="number" min="0" step="0.01" value={line.debit} onChange={(event) => patchLine(line.key, { debit: event.target.value, credit: event.target.value ? "" : line.credit })} disabled={line.lineType === "PAYABLE"} /></td>
                <td className="p-3"><input type="number" min="0" step="0.01" value={line.credit} onChange={(event) => patchLine(line.key, { credit: event.target.value, debit: event.target.value ? "" : line.debit })} disabled={line.lineType === "RECEIVABLE"} /></td>
                <td className="p-3"><button type="button" aria-label="Hapus baris" disabled={lines.length <= 2} onClick={() => setLines((current) => current.filter((item) => item.key !== line.key))} className="grid h-10 w-10 place-items-center rounded-lg text-rose-600 disabled:opacity-30"><Trash2 className="h-4 w-4" /></button></td>
              </tr>)}</tbody></table>
          </div>
          <div className={`mt-5 flex flex-wrap items-center justify-between gap-4 rounded-2xl p-4 ${balanced ? "bg-emerald-50" : "bg-amber-50"}`}>
            <div><p className="text-xs font-black uppercase text-slate-500">Kontrol balance</p><p className="mt-1 font-black">Debit {rupiah(totalDebit)} · Kredit {rupiah(totalCredit)} · Selisih {rupiah(Math.abs(totalDebit - totalCredit))}</p></div>
            <button type="button" disabled={busy || !balanced || !dateHasOpenPeriod || !description.trim() || lines.length < 2} onClick={() => void save()} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-violet-600 px-5 font-black text-white disabled:opacity-40">{busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <CheckCircle2 className="h-4 w-4" />} Simpan draft</button>
          </div>
        </section>
      </div>}
    </div>
  );
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return <label className="text-sm font-black">{label}<span className="mt-2 block [&>input]:min-h-11 [&>input]:w-full [&>input]:rounded-xl [&>input]:border [&>input]:border-slate-200 [&>input]:px-3 [&>input]:font-normal">{children}</span></label>;
}
