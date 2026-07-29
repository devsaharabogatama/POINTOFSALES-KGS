import { NextResponse } from 'next/server'
import { apiError, requireCaller } from '@/lib/server-auth'

type DraftRequest = {
  action: 'SAVE_DRAFT'
  payload: Record<string, unknown>
}

type PostRequest = {
  action: 'POST'
  salesId: string
  masterVersion: number
  postingIdempotencyKey: string
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    const body = (await request.json()) as DraftRequest | PostRequest

    if (body.action === 'SAVE_DRAFT') {
      if (!body.payload || typeof body.payload !== 'object') {
        return NextResponse.json(
          { error: 'SALE_PAYLOAD_OBJECT_REQUIRED' },
          { status: 400 },
        )
      }
      const { data, error } = await caller.client.rpc(
        'save_pos_sale_draft_with_pricelist',
        { p_payload: body.payload },
      )
      if (error) {
        return NextResponse.json({ error: error.message }, { status: 400 })
      }
      return NextResponse.json({ success: true, data })
    }

    if (body.action === 'POST') {
      if (
        !body.salesId ||
        !Number.isInteger(body.masterVersion) ||
        !body.postingIdempotencyKey
      ) {
        return NextResponse.json(
          { error: 'SALE_POST_CONTRACT_REQUIRED' },
          { status: 400 },
        )
      }
      const { data, error } = await caller.client.rpc(
        'post_pos_sale_with_pricelist',
        {
          p_sales_id: body.salesId,
          p_master_version: body.masterVersion,
          p_posting_idempotency_key: body.postingIdempotencyKey,
        },
      )
      if (error) {
        return NextResponse.json({ error: error.message }, { status: 400 })
      }
      return NextResponse.json({ success: true, data })
    }

    return NextResponse.json(
      { error: 'UNSUPPORTED_CHECKOUT_ACTION' },
      { status: 400 },
    )
  } catch (error: unknown) {
    return apiError(error)
  }
}
