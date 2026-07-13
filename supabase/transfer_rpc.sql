-- -----------------------------------------------------
-- RPC: transfer_product_stock (Multi-Company & Stock Movements Logged)
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION transfer_product_stock(
    p_product_id UUID,
    p_src_warehouse_id UUID,
    p_dest_warehouse_id UUID,
    p_qty NUMERIC
) RETURNS BOOLEAN AS $$
DECLARE
    v_src_qty NUMERIC := 0;
    v_prod_company_id UUID;
    v_src_company_id UUID;
    v_dest_company_id UUID;
    v_transfer_id UUID := gen_random_uuid();
BEGIN
    -- 1. Get companies and verify matching
    SELECT company_id INTO v_prod_company_id FROM products WHERE id = p_product_id;
    SELECT company_id INTO v_src_company_id FROM warehouses WHERE id = p_src_warehouse_id;
    SELECT company_id INTO v_dest_company_id FROM warehouses WHERE id = p_dest_warehouse_id;

    IF v_src_company_id IS DISTINCT FROM v_dest_company_id THEN
        RAISE EXCEPTION 'TRANSFER_COMPANY_MISMATCH';
    END IF;

    IF v_prod_company_id IS DISTINCT FROM v_src_company_id THEN
        RAISE EXCEPTION 'PRODUCT_COMPANY_MISMATCH';
    END IF;

    -- 2. Verify User Otorisasi
    IF NOT private_user_has_company_access(v_src_company_id) THEN
        RAISE EXCEPTION 'COMPANY_ACCESS_DENIED';
    END IF;

    -- 3. Check quantity in source warehouse
    SELECT COALESCE(stock_qty, 0) INTO v_src_qty 
    FROM product_stocks 
    WHERE product_id = p_product_id AND warehouse_id = p_src_warehouse_id;

    IF v_src_qty < p_qty THEN
        RAISE EXCEPTION 'INSUFFICIENT_STOCK';
    END IF;

    -- 4. Deduct from source
    UPDATE product_stocks 
    SET stock_qty = stock_qty - p_qty, updated_at = NOW() 
    WHERE product_id = p_product_id AND warehouse_id = p_src_warehouse_id;

    -- 5. Add to destination
    INSERT INTO product_stocks (product_id, warehouse_id, stock_qty, company_id)
    VALUES (p_product_id, p_dest_warehouse_id, p_qty, v_src_company_id)
    ON CONFLICT (product_id, warehouse_id) 
    DO UPDATE SET stock_qty = product_stocks.stock_qty + EXCLUDED.stock_qty, updated_at = NOW();

    -- 6. Log to stock_movements (Out & In) with company_id
    INSERT INTO stock_movements (product_id, warehouse_id, qty_change, movement_type, reference_table, reference_id, company_id)
    VALUES (p_product_id, p_src_warehouse_id, -p_qty, 'TRANSFER_OUT'::stock_movement_type, 'product_stocks', v_transfer_id, v_src_company_id);

    INSERT INTO stock_movements (product_id, warehouse_id, qty_change, movement_type, reference_table, reference_id, company_id)
    VALUES (p_product_id, p_dest_warehouse_id, p_qty, 'TRANSFER_IN'::stock_movement_type, 'product_stocks', v_transfer_id, v_src_company_id);

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;
