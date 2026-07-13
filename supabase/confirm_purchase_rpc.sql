-- -----------------------------------------------------
-- Column Update: Add status to purchases_headers
-- -----------------------------------------------------
ALTER TABLE purchases_headers ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'PENDING';

-- -----------------------------------------------------
-- RPC: confirm_purchase_order
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION confirm_purchase_order(
    p_purchase_id UUID,
    p_user_id UUID
) RETURNS BOOLEAN AS $$
DECLARE
    v_purchase_status TEXT;
    v_company_id UUID;
    v_warehouse_id UUID;
    v_detail_rec RECORD;
BEGIN
    -- 1. Check PO status and details
    SELECT status, company_id, warehouse_id INTO v_purchase_status, v_company_id, v_warehouse_id
    FROM purchases_headers 
    WHERE id = p_purchase_id;

    IF v_purchase_status IS NULL THEN
        RAISE EXCEPTION 'PURCHASE_ORDER_NOT_FOUND';
    END IF;

    IF v_purchase_status = 'CONFIRMED' THEN
        RAISE EXCEPTION 'PURCHASE_ALREADY_CONFIRMED';
    END IF;

    -- 2. Verify User Otorisasi
    IF NOT private_user_has_company_access(v_company_id) THEN
        RAISE EXCEPTION 'COMPANY_ACCESS_DENIED';
    END IF;

    -- 3. Loop through details, add stock, and create FIFO batches
    FOR v_detail_rec IN 
        SELECT id, product_id, qty, purchase_price 
        FROM purchases_details 
        WHERE purchase_id = p_purchase_id
    LOOP
        -- A. Update/insert stock level
        INSERT INTO product_stocks (product_id, warehouse_id, stock_qty, company_id)
        VALUES (v_detail_rec.product_id, v_warehouse_id, v_detail_rec.qty, v_company_id)
        ON CONFLICT (product_id, warehouse_id) 
        DO UPDATE SET stock_qty = product_stocks.stock_qty + EXCLUDED.stock_qty, updated_at = NOW();

        -- B. Insert new batch for FIFO
        INSERT INTO product_batches (product_id, warehouse_id, purchase_detail_id, qty_purchased, qty_remaining, cogs_unit, company_id)
        VALUES (v_detail_rec.product_id, v_warehouse_id, v_detail_rec.id, v_detail_rec.qty, v_detail_rec.qty, v_detail_rec.purchase_price, v_company_id);

        -- C. Log stock movement
        INSERT INTO stock_movements (product_id, warehouse_id, qty_change, movement_type, reference_table, reference_id, company_id)
        VALUES (v_detail_rec.product_id, v_warehouse_id, v_detail_rec.qty, 'PURCHASE'::stock_movement_type, 'purchases_details', v_detail_rec.id, v_company_id);
    END LOOP;

    -- 4. Update status to CONFIRMED
    UPDATE purchases_headers 
    SET status = 'CONFIRMED' 
    WHERE id = p_purchase_id;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;
