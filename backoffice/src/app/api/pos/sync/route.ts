import { NextResponse } from 'next/server'
import { apiError, requireCaller } from '@/lib/server-auth'

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    const { header, details, payments } = await request.json()

    if (!header || !details || !payments) {
      return NextResponse.json({ error: 'Missing header, details, or payments in sync payload.' }, { status: 400 })
    }

    // Call PostgreSQL Stored Procedure (RPC) to guarantee ACID transaction for synced sales
    const { data, error } = await caller.client.rpc('create_sales_transaction', {
      p_invoice_no: header.invoice_no,
      p_session_id: header.session_id,
      p_customer_id: header.customer_id || null,
      p_is_tempo: header.is_tempo || false,
      p_due_date: header.due_date || null,
      p_sj_required: header.sj_required || false,
      p_sj_no: header.sj_no || null,
      p_subtotal: Number(header.subtotal) || 0,
      p_item_discount: Number(header.item_discount) || 0,
      p_global_discount: Number(header.global_discount) || 0,
      p_grand_total: Number(header.grand_total) || 0,
      p_paid_amount: Number(header.paid_amount) || 0,
      p_sisa_piutang: Number(header.sisa_piutang) || 0,
      p_payment_status: header.payment_status || 'DRAFT',
      p_created_by: caller.user.id,
      p_payload_snapshot: header.payload_snapshot || { header, details, payments },
      p_details: details,
      p_payments: payments
    })

    if (error) {
      console.error(`Sync RPC error for invoice ${header.invoice_no}:`, error)
      return NextResponse.json({ error: error.message }, { status: 400 })
    }

    return NextResponse.json({ success: true, sales_id: data })
  } catch (error: unknown) {
    console.error('Sync endpoint error:', error)
    return apiError(error)
  }
}
