import { NextResponse } from 'next/server'
import { supabase } from '@/lib/supabase'

export async function POST(request: Request) {
  try {
    const body = await request.json()

    // Validate essential fields
    if (!body.invoice_no || !body.session_id || !body.created_by || !body.details || !body.payments) {
      return NextResponse.json({ error: 'Missing required checkout parameters.' }, { status: 400 })
    }

    // Call PostgreSQL Stored Procedure (RPC) to guarantee ACID transaction
    const { data, error } = await supabase.rpc('create_sales_transaction', {
      p_invoice_no: body.invoice_no,
      p_session_id: body.session_id,
      p_customer_id: body.customer_id || null,
      p_is_tempo: body.is_tempo || false,
      p_due_date: body.due_date || null,
      p_sj_required: body.sj_required || false,
      p_sj_no: body.sj_no || null,
      p_subtotal: Number(body.subtotal) || 0,
      p_item_discount: Number(body.item_discount) || 0,
      p_global_discount: Number(body.global_discount) || 0,
      p_grand_total: Number(body.grand_total) || 0,
      p_paid_amount: Number(body.paid_amount) || 0,
      p_sisa_piutang: Number(body.sisa_piutang) || 0,
      p_payment_status: body.payment_status || 'DRAFT',
      p_created_by: body.created_by,
      p_payload_snapshot: body.payload_snapshot || body,
      p_details: body.details,
      p_payments: body.payments
    })

    if (error) {
      console.error('Checkout RPC error:', error)
      return NextResponse.json({ error: error.message }, { status: 400 })
    }

    return NextResponse.json({ success: true, sales_id: data })
  } catch (error: any) {
    console.error('Checkout endpoint error:', error)
    return NextResponse.json({ error: error.message }, { status: 500 })
  }
}
