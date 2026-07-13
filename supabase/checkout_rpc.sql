-- Sequence for event code generation
CREATE SEQUENCE IF NOT EXISTS financial_event_code_seq;
CREATE SEQUENCE IF NOT EXISTS journal_no_seq;

-- -----------------------------------------------------
-- RPC: create_sales_transaction
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION create_sales_transaction(
    p_invoice_no TEXT,
    p_session_id UUID,
    p_customer_id UUID,
    p_is_tempo BOOLEAN,
    p_due_date TIMESTAMPTZ,
    p_sj_required BOOLEAN,
    p_sj_no TEXT,
    p_subtotal NUMERIC,
    p_item_discount NUMERIC,
    p_global_discount NUMERIC,
    p_grand_total NUMERIC,
    p_paid_amount NUMERIC,
    p_sisa_piutang NUMERIC,
    p_payment_status payment_status,
    p_created_by UUID,
    p_payload_snapshot JSONB,
    p_details JSONB, -- Array of objects: {product_id, warehouse_id, qty, price, discount_amount, subtotal, cogs_unit, cogs_total}
    p_payments JSONB -- Array of objects: {payment_no, payment_method, amount, balance_before, balance_after, is_reversal}
) RETURNS UUID AS $$
DECLARE
    v_sales_id UUID;
    v_session_status session_status;
    v_detail_rec RECORD;
    v_payment_rec RECORD;
    v_total_cogs NUMERIC := 0;
    v_cash_paid NUMERIC := 0;
    v_transfer_paid NUMERIC := 0;
    v_qris_paid NUMERIC := 0;
    v_balance_paid NUMERIC := 0;
    v_event_code TEXT;
    v_event_id UUID;
BEGIN
    -- 1. Check Session Status
    SELECT status INTO v_session_status FROM cashier_sessions WHERE id = p_session_id;
    IF v_session_status IS NULL OR v_session_status != 'OPEN' THEN
        RAISE EXCEPTION 'Cashier session is not open or does not exist.';
    END IF;

    -- 2. Insert into sales_headers
    INSERT INTO sales_headers (
        invoice_no, session_id, customer_id, transaction_date, is_tempo, due_date,
        sj_required, sj_no, sj_status, so_confirm_status, invoice_status,
        subtotal, item_discount, global_discount, grand_total, paid_amount, sisa_piutang,
        payment_status, financial_status, recon_status, created_by, payload_snapshot
    ) VALUES (
        p_invoice_no, p_session_id, p_customer_id, NOW(), p_is_tempo, p_due_date,
        p_sj_required, p_sj_no, 
        CASE WHEN p_sj_required THEN 'PENDING'::sj_status ELSE 'NONE'::sj_status END,
        'CONFIRMED'::so_confirm_status, 'GENERATED'::invoice_status,
        p_subtotal, p_item_discount, p_global_discount, p_grand_total, p_paid_amount, p_sisa_piutang,
        p_payment_status, 'PENDING'::financial_status, 'UNRECONCILED'::recon_status, p_created_by, p_payload_snapshot
    ) RETURNING id INTO v_sales_id;

    -- 3. Loop and Insert Details + Adjust Stock
    FOR v_detail_rec IN SELECT * FROM jsonb_to_recordset(p_details) AS x(
        product_id UUID, warehouse_id UUID, qty NUMERIC, price NUMERIC, 
        discount_amount NUMERIC, subtotal NUMERIC, cogs_unit NUMERIC, cogs_total NUMERIC
    ) LOOP
        -- Insert sales_details
        INSERT INTO sales_details (
            sales_id, product_id, warehouse_id, qty, price, discount_amount, subtotal, cogs_unit, cogs_total
        ) VALUES (
            v_sales_id, v_detail_rec.product_id, v_detail_rec.warehouse_id, 
            v_detail_rec.qty, v_detail_rec.price, v_detail_rec.discount_amount, 
            v_detail_rec.subtotal, v_detail_rec.cogs_unit, v_detail_rec.cogs_total
        );

        -- Accumulate HPP
        v_total_cogs := v_total_cogs + v_detail_rec.cogs_total;

        -- Update Stock Level (ACID Safe)
        INSERT INTO product_stocks (product_id, warehouse_id, stock_qty)
        VALUES (v_detail_rec.product_id, v_detail_rec.warehouse_id, -v_detail_rec.qty)
        ON CONFLICT (product_id, warehouse_id) 
        DO UPDATE SET stock_qty = product_stocks.stock_qty - EXCLUDED.stock_qty, updated_at = NOW();
    END LOOP;

    -- 4. Loop and Insert Payments
    FOR v_payment_rec IN SELECT * FROM jsonb_to_recordset(p_payments) AS x(
        payment_no TEXT, payment_method TEXT, amount NUMERIC, 
        balance_before NUMERIC, balance_after NUMERIC, is_reversal BOOLEAN
    ) LOOP
        INSERT INTO sales_payments (
            payment_no, sales_id, session_id, payment_method, amount, 
            balance_before, balance_after, is_reversal
        ) VALUES (
            v_payment_rec.payment_no, v_sales_id, p_session_id, 
            v_payment_rec.payment_method::payment_method, v_payment_rec.amount, 
            v_payment_rec.balance_before, v_payment_rec.balance_after, v_payment_rec.is_reversal
        );

        -- Accumulate payment totals for financial event record
        CASE v_payment_rec.payment_method
            WHEN 'Cash' THEN v_cash_paid := v_cash_paid + v_payment_rec.amount;
            WHEN 'Transfer' THEN v_transfer_paid := v_transfer_paid + v_payment_rec.amount;
            WHEN 'QRIS' THEN v_qris_paid := v_qris_paid + v_payment_rec.amount;
            WHEN 'Customer_Balance' THEN v_balance_paid := v_balance_paid + v_payment_rec.amount;
        END CASE;
    END LOOP;

    -- 5. Generate Event Code
    v_event_code := 'EVT-' || to_char(NOW(), 'YYYYMMDD') || '-' || lpad(nextval('financial_event_code_seq')::text, 6, '0');

    -- 6. Insert into financial_events queue
    INSERT INTO financial_events (
        event_code, event_type, source_table, source_id, root_sales_id, event_date,
        idempotency_key, payment_method, amounts, status, created_by
    ) VALUES (
        v_event_code, 'SALE_POSTED'::event_type, 'sales_headers', v_sales_id, v_sales_id, NOW(),
        'POS|SALE_POSTED|' || p_invoice_no || '|V1', 
        p_payment_status::TEXT,
        jsonb_build_object(
            'sales_net_amount', p_grand_total,
            'hpp_amount', v_total_cogs,
            'cash_amount', v_cash_paid,
            'transfer_amount', v_transfer_paid,
            'qris_amount', v_qris_paid,
            'customer_balance_amount', v_balance_paid,
            'ar_amount', p_sisa_piutang
        ),
        'READY'::event_status, p_created_by
    ) RETURNING id INTO v_event_id;

    RETURN v_sales_id;
END;
$$ LANGUAGE plpgsql;
