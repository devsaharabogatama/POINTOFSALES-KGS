import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  BanknoteArrowUp,
  Building2,
  Landmark,
  Loader2,
  RefreshCw,
  ShieldCheck,
  X,
} from 'lucide-react'
import {
  listCashDepositEligibleSessions,
  saveCashDepositDraft,
  submitCashDeposit,
  type CashDepositEligibleSession,
} from './lib/pos'
import { CurrencyInput } from './CurrencyInput'

type Props = {
  storeId: string
  storeName: string
  close: () => void
  completed: (message: string) => void
}

function money(value: number) {
  return new Intl.NumberFormat('id-ID', {
    style: 'currency', currency: 'IDR', maximumFractionDigits: 0,
  }).format(value)
}

function dateTime(value: string) {
  return new Intl.DateTimeFormat('id-ID', {
    dateStyle: 'medium', timeStyle: 'short',
  }).format(new Date(value))
}

function errorText(reason: unknown) {
  const code = reason instanceof Error ? reason.message : 'UNKNOWN_ERROR'
  const messages: Record<string, string> = {
    ACTIVE_STORE_NOT_FOUND: 'Store aktif tidak ditemukan atau tidak dapat diakses.',
    DEPOSIT_SESSION_REQUIRED: 'Pilih minimal satu sesi yang akan disetor.',
    CLOSED_CASHIER_SESSION_NOT_FOUND: 'Salah satu sesi sudah berubah. Muat ulang daftar.',
    CASHIER_SESSION_ALREADY_DEPOSITED_OR_LOCKED: 'Salah satu sesi sudah dikunci atau selesai disetor pada dokumen lain.',
    NEXT_SESSION_FLOAT_INVALID: 'Saldo sesi berikutnya tidak valid.',
    SESSION_HAS_NO_DEPOSITABLE_CASH: 'Saldo yang ditahan menghabiskan seluruh kas yang dapat disetor.',
    ACTUAL_DEPOSIT_AMOUNT_MUST_BE_POSITIVE: 'Nominal aktual setoran harus lebih besar dari nol.',
    DEPOSIT_DESTINATION_NAME_REQUIRED: 'Isi nama bank, rekening, atau brankas tujuan.',
    DEPOSIT_EVIDENCE_REQUIRED: 'Kebijakan Store mewajibkan link bukti setoran.',
    DEPOSIT_EVIDENCE_MUST_USE_HTTPS: 'Link bukti setoran harus menggunakan HTTPS.',
    MASTER_VERSION_CONFLICT: 'Draft Setor Kas berubah. Muat ulang dan coba kembali.',
    CLIENT_DEPOSIT_ID_CONFLICT: 'Identitas retry bertentangan dengan isi draft sebelumnya.',
  }
  return messages[code] ?? code.replaceAll('_', ' ')
}

export function CashDepositModal({ storeId, storeName, close, completed }: Props) {
  const [sessions, setSessions] = useState<CashDepositEligibleSession[]>([])
  const [selected, setSelected] = useState<Record<string, boolean>>({})
  const [reserved, setReserved] = useState<Record<string, string>>({})
  const [destinationType, setDestinationType] = useState<'BANK' | 'VAULT'>('BANK')
  const [destinationName, setDestinationName] = useState('')
  const [actualAmount, setActualAmount] = useState('')
  const [depositAt, setDepositAt] = useState(() => {
    const now = new Date(Date.now() - new Date().getTimezoneOffset() * 60_000)
    return now.toISOString().slice(0, 16)
  })
  const [evidenceUrl, setEvidenceUrl] = useState('')
  const [notes, setNotes] = useState('')
  const [documentId, setDocumentId] = useState<string | null>(null)
  const [masterVersion, setMasterVersion] = useState<number | null>(null)
  const [clientDepositId] = useState(() => crypto.randomUUID())
  const [submitKey] = useState(() => crypto.randomUUID())
  const [confirmed, setConfirmed] = useState(false)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const chosen = useMemo(
    () => sessions.filter((session) => selected[session.sessionId]),
    [selected, sessions],
  )
  const totalExpected = useMemo(
    () => chosen.reduce((total, session) => {
      const hold = Math.max(Number(reserved[session.sessionId] || 0), 0)
      return total + Math.max(session.availableDepositAmount - hold, 0)
    }, 0),
    [chosen, reserved],
  )
  const actual = Number(actualAmount || 0)
  const variance = actual - totalExpected

  const load = useCallback(async () => {
    setLoading(true); setError('')
    try {
      const rows = await listCashDepositEligibleSessions(storeId)
      setSessions(rows)
      setSelected((current) => Object.fromEntries(
        rows.map((row) => [row.sessionId, Boolean(current[row.sessionId])]),
      ))
    } catch (reason) { setError(errorText(reason)) }
    finally { setLoading(false) }
  }, [storeId])

  useEffect(() => { void load() }, [load])
  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && !busy) close()
    }
    window.addEventListener('keydown', handler)
    return () => window.removeEventListener('keydown', handler)
  }, [busy, close])

  async function saveAndSubmit() {
    if (chosen.length === 0) return setError('Pilih minimal satu sesi.')
    if (!destinationName.trim()) return setError('Isi nama tujuan setoran.')
    if (!Number.isFinite(actual) || actual <= 0) return setError('Nominal aktual setoran harus lebih besar dari nol.')
    if (!depositAt) return setError('Isi waktu setoran.')
    if (evidenceUrl && !/^https:\/\//i.test(evidenceUrl)) return setError('Link bukti harus menggunakan HTTPS.')
    for (const session of chosen) {
      const hold = Number(reserved[session.sessionId] || 0)
      if (!Number.isFinite(hold) || hold < 0 || hold >= session.availableDepositAmount) {
        return setError(`Saldo berikutnya untuk ${session.sessionCode} harus lebih kecil dari kas tersedia.`)
      }
    }
    if (!confirmed) return setError('Centang konfirmasi setelah seluruh nominal diperiksa.')
    setBusy(true); setError('')
    try {
      const draft = await saveCashDepositDraft({
        documentId, masterVersion, storeId, destinationType, destinationName,
        actualDepositAmount: actual,
        depositAt: new Date(depositAt).toISOString(), evidenceUrl, notes,
        clientDepositId,
        sessions: chosen.map((session) => ({
          sessionId: session.sessionId,
          nextSessionFloatReserved: Number(reserved[session.sessionId] || 0),
        })),
      })
      setDocumentId(draft.depositDocumentId)
      setMasterVersion(draft.masterVersion)
      const submitted = await submitCashDeposit({
        documentId: draft.depositDocumentId,
        masterVersion: draft.masterVersion,
        idempotencyKey: submitKey,
      })
      completed(
        `Setor Kas berhasil diajukan. Expected ${money(Number(submitted.totalExpectedDeposit ?? draft.totalExpectedDeposit))}, ` +
        `aktual ${money(actual)}, selisih ${money(Number(submitted.depositVariance ?? variance))}.`,
      )
    } catch (reason) { setError(errorText(reason)) }
    finally { setBusy(false) }
  }

  return <div className="fixed inset-0 z-[80] grid place-items-center bg-slate-950/65 p-3 backdrop-blur-sm sm:p-5">
    <section role="dialog" aria-modal="true" aria-labelledby="cash-deposit-title" className="flex max-h-[96vh] w-full max-w-6xl flex-col overflow-hidden rounded-3xl bg-white text-slate-900 shadow-2xl">
      <header className="flex items-start justify-between gap-4 border-b border-slate-200 px-5 py-4 sm:px-7">
        <div><p className="text-xs font-black uppercase tracking-[0.18em] text-emerald-600">Kas setelah sesi ditutup</p><h2 id="cash-deposit-title" className="mt-1 text-2xl font-black">Buat Setor Kas</h2><p className="mt-1 text-sm text-slate-500">{storeName} · gabungkan satu atau beberapa sesi CLOSED.</p></div>
        <button type="button" onClick={close} disabled={busy} className="rounded-xl bg-slate-100 p-2 text-slate-500" aria-label="Tutup Setor Kas"><X className="h-5 w-5" /></button>
      </header>
      <div className="grid flex-1 gap-5 overflow-y-auto p-4 sm:p-6 lg:grid-cols-[minmax(0,1fr)_380px]">
        <div>
          <div className="mb-4 flex items-center justify-between"><div><h3 className="font-black">Sesi yang belum disetor</h3><p className="text-sm text-slate-500">Saldo sesi berikutnya mengurangi expected setoran.</p></div><button type="button" onClick={() => void load()} disabled={loading || busy} className="inline-flex min-h-10 items-center gap-2 rounded-xl border border-slate-200 px-3 text-sm font-black"><RefreshCw className={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} /> Muat ulang</button></div>
          {loading && <div className="grid min-h-40 place-items-center rounded-2xl border border-slate-200"><Loader2 className="h-6 w-6 animate-spin text-emerald-600" /></div>}
          {!loading && sessions.length === 0 && <div className="rounded-2xl border border-dashed border-slate-300 p-8 text-center text-sm text-slate-500">Belum ada sesi CLOSED dengan kas yang wajib disetor.</div>}
          <div className="space-y-3">{sessions.map((session) => {
            const checked = Boolean(selected[session.sessionId])
            const hold = Number(reserved[session.sessionId] || 0)
            return <div key={session.sessionId} className={`rounded-2xl border p-4 ${checked ? 'border-emerald-400 bg-emerald-50/50' : 'border-slate-200'}`}>
              <label className="flex cursor-pointer items-start gap-3"><input type="checkbox" checked={checked} onChange={(event) => setSelected((current) => ({ ...current, [session.sessionId]: event.target.checked }))} className="mt-1 h-4 w-4 accent-emerald-600" /><span className="flex-1"><span className="block font-black">{session.sessionCode} · {session.cashierName}</span><span className="mt-1 block text-xs text-slate-500">Ditutup {dateTime(session.closedAt)}</span></span><strong>{money(session.availableDepositAmount)}</strong></label>
              {checked && <div className="mt-4 grid gap-3 rounded-xl bg-white p-3 sm:grid-cols-3"><Info label="Kas penutupan" value={money(session.closingCashActual)} /><Info label="Sudah dialokasikan" value={money(session.postedDepositAllocations)} /><label className="text-xs font-black uppercase tracking-wider text-slate-500">Saldo sesi berikutnya<CurrencyInput value={reserved[session.sessionId] ?? ''} onValueChange={(value) => setReserved((current) => ({ ...current, [session.sessionId]: value }))} placeholder="0" className="mt-2 w-full rounded-xl border border-slate-200 px-3 py-2 text-sm font-bold text-slate-900 outline-none focus:border-emerald-500" /><span className="mt-2 block normal-case tracking-normal text-emerald-700">Disetor: {money(Math.max(session.availableDepositAmount - Math.max(hold, 0), 0))}</span></label></div>}
            </div>
          })}</div>
        </div>
        <aside className="space-y-4 rounded-2xl border border-slate-200 bg-slate-50 p-4 sm:p-5">
          <div><p className="text-xs font-black uppercase tracking-wider text-slate-500">Ringkasan</p><div className="mt-3 rounded-2xl bg-slate-950 p-4 text-white"><p className="text-sm text-slate-400">Total expected</p><p className="mt-1 text-2xl font-black text-emerald-400">{money(totalExpected)}</p><p className="mt-2 text-xs text-slate-400">{chosen.length} sesi dipilih</p></div></div>
          <div className="grid grid-cols-2 gap-2"><button type="button" onClick={() => setDestinationType('BANK')} className={`rounded-xl border p-3 text-left ${destinationType === 'BANK' ? 'border-emerald-500 bg-white' : 'border-slate-200'}`}><Landmark className="h-5 w-5" /><strong className="mt-2 block text-sm">Bank</strong><span className="text-xs text-slate-500">Kas transit</span></button><button type="button" onClick={() => setDestinationType('VAULT')} className={`rounded-xl border p-3 text-left ${destinationType === 'VAULT' ? 'border-emerald-500 bg-white' : 'border-slate-200'}`}><Building2 className="h-5 w-5" /><strong className="mt-2 block text-sm">Brankas</strong><span className="text-xs text-slate-500">Kas besar</span></button></div>
          <Field label={destinationType === 'BANK' ? 'Bank / rekening tujuan' : 'Nama brankas'} value={destinationName} setValue={setDestinationName} placeholder={destinationType === 'BANK' ? 'Contoh: BCA Operasional' : 'Contoh: Brankas Utama'} />
          <Field label="Nominal aktual yang disetor" value={actualAmount} setValue={setActualAmount} type="number" placeholder="0" />
          <label className="block text-sm font-black text-slate-700">Waktu setor<input type="datetime-local" value={depositAt} onChange={(event) => setDepositAt(event.target.value)} className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-2.5 outline-none focus:border-emerald-500" /></label>
          <Field label="Link bukti setoran" value={evidenceUrl} setValue={setEvidenceUrl} type="url" placeholder="https://... (sesuai kebijakan Store)" />
          <label className="block text-sm font-black text-slate-700">Catatan<textarea value={notes} onChange={(event) => setNotes(event.target.value)} rows={3} maxLength={1000} className="mt-2 w-full rounded-xl border border-slate-200 bg-white p-3 font-normal outline-none focus:border-emerald-500" /></label>
          <div className={`rounded-xl border p-3 text-sm font-bold ${variance === 0 ? 'border-emerald-200 bg-emerald-50 text-emerald-800' : variance < 0 ? 'border-rose-200 bg-rose-50 text-rose-800' : 'border-amber-200 bg-amber-50 text-amber-800'}`}>Selisih aktual − expected: {money(variance)}<span className="mt-1 block text-xs font-normal">{variance === 0 ? 'Sesuai expected.' : variance < 0 ? 'Setoran kurang; Finance akan mengevaluasi selisih.' : 'Setoran lebih; Finance akan mengevaluasi selisih.'}</span></div>
          <label className="flex cursor-pointer items-start gap-3 rounded-xl border border-slate-200 bg-white p-3 text-sm font-semibold"><input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} className="mt-0.5 h-4 w-4 accent-emerald-600" /><span>Saya sudah menghitung kas fisik, saldo yang ditahan, tujuan, dan bukti setoran.</span></label>
          {error && <p className="rounded-xl border border-rose-200 bg-rose-50 p-3 text-sm font-semibold text-rose-700">{error}</p>}
        </aside>
      </div>
      <footer className="flex flex-wrap items-center justify-between gap-3 border-t border-slate-200 px-5 py-4 sm:px-7"><p className="flex items-center gap-2 text-xs text-slate-500"><ShieldCheck className="h-4 w-4 text-emerald-600" /> Submit mengunci semua sesi sampai direview Finance.</p><div className="flex gap-3"><button type="button" onClick={close} disabled={busy} className="min-h-11 rounded-xl border border-slate-200 px-5 font-black text-slate-600">Batal</button><button type="button" onClick={() => void saveAndSubmit()} disabled={busy || chosen.length === 0} className="inline-flex min-h-11 items-center gap-2 rounded-xl bg-emerald-600 px-5 font-black text-white disabled:bg-slate-300">{busy ? <Loader2 className="h-4 w-4 animate-spin" /> : <BanknoteArrowUp className="h-4 w-4" />}{busy ? 'Mengajukan...' : 'Simpan & Ajukan'}</button></div></footer>
    </section>
  </div>
}

function Field({ label, value, setValue, type = 'text', placeholder }: { label: string; value: string; setValue: (value: string) => void; type?: string; placeholder?: string }) {
  return <label className="block text-sm font-black text-slate-700">{label}{type === 'number' ? <CurrencyInput value={value} onValueChange={setValue} placeholder={placeholder} className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-2.5 font-normal outline-none focus:border-emerald-500" /> : <input type={type} value={value} onChange={(event) => setValue(event.target.value)} placeholder={placeholder} className="mt-2 w-full rounded-xl border border-slate-200 bg-white px-3 py-2.5 font-normal outline-none focus:border-emerald-500" />}</label>
}
function Info({ label, value }: { label: string; value: string }) { return <div><p className="text-[10px] font-black uppercase tracking-wider text-slate-400">{label}</p><p className="mt-1 text-sm font-black text-slate-800">{value}</p></div> }
