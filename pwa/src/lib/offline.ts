import { db, type OfflineSaleQueueRecord, type OfflineSaleQueueStatus } from './db'
import { supabase } from './supabase'

type JsonPrimitive = string | number | boolean | null
export type JsonValue =
  | JsonPrimitive
  | JsonValue[]
  | { [key: string]: JsonValue }

export type OfflineSalePayload = {
  clientTransactionId: string
  cashierSessionId: string
  customerId: string
  selectedPricelistId?: string | null
  pricingSelectionSource?: 'AUTO' | 'CASHIER_OVERRIDE'
  isTempo: false
  globalDiscount: number
  roundingDirection: 'NONE' | 'DOWN' | 'UP'
  roundingIncrement: number
  lines: Array<{
    lineKey: string
    productUomId: string
    quantity: number
    snapshotUnitPrice: number
    lineDiscountType?: 'AMOUNT' | 'PERCENT'
    lineDiscountInput?: number
  }>
  payments: Array<{
    clientPaymentKey: string
    paymentMethodId: string
    amount: number
    tenderedAmount: number
    proofUrl?: string
  }>
}

export type QueueOfflineSaleInput = {
  companyId: string
  storeId: string
  terminalId: string
  warehouseId: string
  cashierSessionId: string
  cashierId: string
  localMasterVersion: number
  salePayload: OfflineSalePayload
  postingIdempotencyKey?: string
  localTransactionAt?: string
}

type RpcRow = Record<string, unknown>

export type OfflineSyncStage =
  | 'CHECKING_STATUS'
  | 'SUBMITTING'
  | 'PROCESSING'
  | 'CONFIRMING_STATUS'

const STATUS_TIMEOUT_MS = 10_000
const SUBMIT_TIMEOUT_MS = 15_000
const PROCESS_TIMEOUT_MS = 25_000

async function withRequestTimeout<T>(
  operation: (signal: AbortSignal) => PromiseLike<T>,
  timeoutMs: number,
  timeoutCode: string,
) {
  const controller = new AbortController()
  const timer = window.setTimeout(() => controller.abort(), timeoutMs)
  try {
    return await operation(controller.signal)
  } catch (error) {
    if (controller.signal.aborted) throw new Error(timeoutCode)
    throw error
  } finally {
    window.clearTimeout(timer)
  }
}

function bytewiseCompare(left: string, right: string) {
  const encoder = new TextEncoder()
  const a = encoder.encode(left)
  const b = encoder.encode(right)
  const length = Math.min(a.length, b.length)
  for (let index = 0; index < length; index += 1) {
    if (a[index] !== b[index]) return a[index] - b[index]
  }
  return a.length - b.length
}

function jsonbKeyCompare(left: string, right: string) {
  const leftLength = new TextEncoder().encode(left).length
  const rightLength = new TextEncoder().encode(right).length
  return leftLength - rightLength || bytewiseCompare(left, right)
}

function finiteNumber(value: number) {
  if (!Number.isFinite(value)) throw new Error('OFFLINE_PAYLOAD_NUMBER_INVALID')
  const raw = String(value)
  if (!/[eE]/.test(raw)) return raw
  const [coefficient, exponentText] = raw.toLowerCase().split('e')
  const exponent = Number(exponentText)
  const negative = coefficient.startsWith('-')
  const unsigned = negative ? coefficient.slice(1) : coefficient
  const [integer, fraction = ''] = unsigned.split('.')
  const digits = integer + fraction
  const decimalPosition = integer.length + exponent
  const expanded =
    decimalPosition <= 0
      ? `0.${'0'.repeat(-decimalPosition)}${digits}`
      : decimalPosition >= digits.length
        ? `${digits}${'0'.repeat(decimalPosition - digits.length)}`
        : `${digits.slice(0, decimalPosition)}.${digits.slice(decimalPosition)}`
  return negative ? `-${expanded}` : expanded
}

/**
 * Mirrors PostgreSQL `jsonb::text` for the JSON values emitted by this PWA.
 * PostgreSQL orders object keys by UTF-8 byte length, then bytewise, and emits
 * a space after separators. The server independently hashes the parsed JSONB
 * and rejects any mismatch.
 */
export function jsonbCanonicalText(value: JsonValue): string {
  if (value === null) return 'null'
  if (typeof value === 'string') return JSON.stringify(value)
  if (typeof value === 'number') return finiteNumber(value)
  if (typeof value === 'boolean') return value ? 'true' : 'false'
  if (Array.isArray(value)) {
    return `[${value.map((item) => jsonbCanonicalText(item)).join(', ')}]`
  }
  const entries = Object.entries(value)
    .filter(([, item]) => item !== undefined)
    .sort(([left], [right]) => jsonbKeyCompare(left, right))
  return `{${entries
    .map(
      ([key, item]) =>
        `${JSON.stringify(key)}: ${jsonbCanonicalText(item as JsonValue)}`,
    )
    .join(', ')}}`
}

export async function sha256Hex(value: string) {
  const digest = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(value),
  )
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('')
}

function stringValue(value: unknown) {
  return value === null || value === undefined ? undefined : String(value)
}

function statusValue(value: unknown): OfflineSaleQueueStatus {
  const status = String(value ?? '')
  if (
    [
      'PENDING_SYNC',
      'SUBMITTING',
      'QUEUED',
      'SYNCING',
      'NEEDS_CONFIRMATION',
      'FAILED',
      'POSTED',
      'INVALIDATED',
    ].includes(status)
  ) {
    return status as OfflineSaleQueueStatus
  }
  return 'FAILED'
}

function errorMessage(error: unknown) {
  if (error && typeof error === 'object' && 'message' in error) {
    return String(error.message)
  }
  return 'OFFLINE_SYNC_NETWORK_ERROR'
}

function isConnectionFailure(code: string) {
  const normalized = code.toLowerCase()
  return (
    normalized.includes('fetch') ||
    normalized.includes('network') ||
    normalized.includes('timeout') ||
    normalized.includes('failed to fetch')
  )
}

function isSubmissionNotFound(code: string) {
  return code.includes('OFFLINE_SUBMISSION_NOT_FOUND')
}

async function updateFromServer(
  record: OfflineSaleQueueRecord,
  result: RpcRow,
) {
  const now = new Date().toISOString()
  const status = statusValue(result.status)
  const acknowledgement =
    result.acknowledgement && typeof result.acknowledgement === 'object'
      ? JSON.stringify(result.acknowledgement)
      : status === 'POSTED'
        ? JSON.stringify(result)
        : record.acknowledgement
  const next: OfflineSaleQueueRecord = {
    ...record,
    status,
    submissionId: stringValue(result.submissionId) ?? record.submissionId,
    acknowledgement,
    errorCode: stringValue(result.errorCode),
    processingAttempts:
      Number(result.processingAttempts ?? record.processingAttempts) || 0,
    updatedAt: now,
    ...(status === 'POSTED' ? { acknowledgedAt: now } : {}),
  }
  await db.offline_sale_queue.put(next)
  return next
}

export async function queueOfflineSale(
  input: QueueOfflineSaleInput,
): Promise<OfflineSaleQueueRecord> {
  if (input.salePayload.cashierSessionId !== input.cashierSessionId) {
    throw new Error('OFFLINE_SALE_SESSION_IDENTITY_INVALID')
  }
  if (
    input.salePayload.clientTransactionId === '' ||
    input.salePayload.lines.length === 0 ||
    input.salePayload.payments.length === 0 ||
    input.salePayload.isTempo
  ) {
    throw new Error('OFFLINE_SALE_PAYLOAD_INVALID')
  }
  const clientTransactionId = input.salePayload.clientTransactionId
  const canonicalPayload = jsonbCanonicalText(
    input.salePayload as unknown as JsonValue,
  )
  const payloadHash = await sha256Hex(canonicalPayload)
  const existing = await db.offline_sale_queue.get(clientTransactionId)
  if (existing) {
    if (
      existing.payloadHash !== payloadHash ||
      existing.cashierSessionId !== input.cashierSessionId
    ) {
      throw new Error('OFFLINE_LOCAL_IDEMPOTENCY_CONFLICT')
    }
    return existing
  }
  const now = new Date().toISOString()
  const record: OfflineSaleQueueRecord = {
    clientTransactionId,
    companyId: input.companyId,
    storeId: input.storeId,
    terminalId: input.terminalId,
    warehouseId: input.warehouseId,
    cashierSessionId: input.cashierSessionId,
    cashierId: input.cashierId,
    postingIdempotencyKey:
      input.postingIdempotencyKey ?? crypto.randomUUID(),
    localMasterVersion: input.localMasterVersion,
    payloadVersion: 1,
    localTransactionAt: input.localTransactionAt ?? now,
    payloadHash,
    salePayload: JSON.stringify(input.salePayload),
    status: 'PENDING_SYNC',
    processingAttempts: 0,
    createdAt: now,
    updatedAt: now,
  }
  await db.offline_sale_queue.add(record)
  return record
}

export async function listOfflineSaleQueue(cashierSessionId: string) {
  return db.offline_sale_queue
    .where('cashierSessionId')
    .equals(cashierSessionId)
    .sortBy('createdAt')
}

export async function syncOfflineSale(
  clientTransactionId: string,
  onStage?: (stage: OfflineSyncStage) => void,
): Promise<OfflineSaleQueueRecord> {
  let record = await db.offline_sale_queue.get(clientTransactionId)
  if (!record) throw new Error('OFFLINE_LOCAL_RECORD_NOT_FOUND')
  if (record.status === 'POSTED' || record.status === 'INVALIDATED') {
    return record
  }
  if (record.status !== 'PENDING_SYNC') {
    try {
      onStage?.('CHECKING_STATUS')
      record = await refreshOfflineSaleStatus(clientTransactionId)
    } catch (error) {
      const code = errorMessage(error)
      if (
        !isSubmissionNotFound(code) ||
        record.submissionId ||
        record.status !== 'SUBMITTING'
      ) {
        throw error
      }
      record = {
        ...record,
        status: 'PENDING_SYNC',
        errorCode: undefined,
        updatedAt: new Date().toISOString(),
      }
      await db.offline_sale_queue.put(record)
    }
    if (
      record.status === 'POSTED' ||
      record.status === 'INVALIDATED' ||
      record.status === 'NEEDS_CONFIRMATION' ||
      record.status === 'SYNCING'
    ) {
      return record
    }
  }
  await db.offline_sale_queue.update(clientTransactionId, {
    status: 'SUBMITTING',
    updatedAt: new Date().toISOString(),
  })
  try {
    let current = record
    if (!current.submissionId) {
      onStage?.('SUBMITTING')
      const salePayload = JSON.parse(record.salePayload) as OfflineSalePayload
      const envelope = {
        clientTransactionId: record.clientTransactionId,
        postingIdempotencyKey: record.postingIdempotencyKey,
        cashierSessionId: record.cashierSessionId,
        localMasterVersion: record.localMasterVersion,
        payloadVersion: record.payloadVersion,
        localTransactionAt: record.localTransactionAt,
        payloadHash: record.payloadHash,
        salePayload,
      }
      const { data: submitData, error: submitError } = await withRequestTimeout(
        (signal) =>
          supabase
            .rpc('submit_pos_offline_sale', { p_envelope: envelope })
            .abortSignal(signal),
        SUBMIT_TIMEOUT_MS,
        'OFFLINE_SYNC_SUBMIT_TIMEOUT',
      )
      if (submitError) throw submitError
      current = await updateFromServer(record, submitData as RpcRow)
    }
    if (
      current.status === 'QUEUED' ||
      current.status === 'FAILED'
    ) {
      if (!current.submissionId) {
        throw new Error('OFFLINE_SUBMISSION_ID_MISSING')
      }
      onStage?.('PROCESSING')
      const { data: processData, error: processError } = await withRequestTimeout(
        (signal) =>
          supabase
            .rpc('process_pos_offline_sale_submission', {
              p_submission_id: current.submissionId,
            })
            .abortSignal(signal),
        PROCESS_TIMEOUT_MS,
        'OFFLINE_SYNC_PROCESS_TIMEOUT',
      )
      if (processError) throw processError
      current = await updateFromServer(current, processData as RpcRow)
    }
    return current
  } catch (error) {
    const code = errorMessage(error)
    if (isConnectionFailure(code)) {
      try {
        onStage?.('CONFIRMING_STATUS')
        const confirmed = await refreshOfflineSaleStatus(clientTransactionId)
        if (
          confirmed.status === 'POSTED' ||
          confirmed.status === 'INVALIDATED' ||
          confirmed.status === 'SYNCING' ||
          confirmed.status === 'NEEDS_CONFIRMATION'
        ) {
          return confirmed
        }
      } catch {
        // The outcome stays ambiguous. The next manual action must check
        // server status before another idempotent retry.
      }
    }
    const latest = await db.offline_sale_queue.get(clientTransactionId)
    const now = new Date().toISOString()
    const next: OfflineSaleQueueRecord = {
      ...(latest ?? record),
      status:
        latest?.submissionId || record.submissionId
          ? isConnectionFailure(code)
            ? 'NEEDS_CONFIRMATION'
            : 'FAILED'
          : isConnectionFailure(code)
            ? 'PENDING_SYNC'
            : 'NEEDS_CONFIRMATION',
      errorCode: code,
      updatedAt: now,
    }
    await db.offline_sale_queue.put(next)
    throw error
  }
}

export async function refreshOfflineSaleStatus(clientTransactionId: string) {
  const record = await db.offline_sale_queue.get(clientTransactionId)
  if (!record) throw new Error('OFFLINE_LOCAL_RECORD_NOT_FOUND')
  const { data, error } = await withRequestTimeout(
    (signal) =>
      supabase
        .rpc('get_pos_offline_submission_status', {
          p_client_transaction_id: clientTransactionId,
        })
        .abortSignal(signal),
    STATUS_TIMEOUT_MS,
    'OFFLINE_SYNC_STATUS_TIMEOUT',
  )
  if (error) throw error
  return updateFromServer(record, data as RpcRow)
}

export async function recoverOfflineSaleQueue(cashierSessionId: string) {
  const records = await listOfflineSaleQueue(cashierSessionId)
  const results: OfflineSaleQueueRecord[] = []
  for (const record of records) {
    if (
      record.status === 'POSTED' ||
      record.status === 'INVALIDATED' ||
      record.status === 'PENDING_SYNC'
    ) {
      results.push(record)
      continue
    }
    try {
      results.push(
        await refreshOfflineSaleStatus(record.clientTransactionId),
      )
    } catch (error) {
      const code = errorMessage(error)
      if (
        isSubmissionNotFound(code) &&
        !record.submissionId &&
        record.status === 'SUBMITTING'
      ) {
        const recovered: OfflineSaleQueueRecord = {
          ...record,
          status: 'PENDING_SYNC',
          errorCode: undefined,
          updatedAt: new Date().toISOString(),
        }
        await db.offline_sale_queue.put(recovered)
        results.push(recovered)
        continue
      }
      if (isConnectionFailure(code)) break
      const ambiguous: OfflineSaleQueueRecord = {
        ...record,
        status: 'NEEDS_CONFIRMATION',
        errorCode: code,
        updatedAt: new Date().toISOString(),
      }
      await db.offline_sale_queue.put(ambiguous)
      results.push(ambiguous)
    }
  }
  return results
}

export async function syncPendingOfflineSales(cashierSessionId: string) {
  const records = (await listOfflineSaleQueue(cashierSessionId)).filter(
    (record) =>
      !['POSTED', 'INVALIDATED', 'NEEDS_CONFIRMATION'].includes(record.status),
  )
  const results: OfflineSaleQueueRecord[] = []
  for (const record of records) {
    try {
      results.push(await syncOfflineSale(record.clientTransactionId))
    } catch {
      const latest = await db.offline_sale_queue.get(
        record.clientTransactionId,
      )
      if (latest) results.push(latest)
      break
    }
  }
  return results
}
