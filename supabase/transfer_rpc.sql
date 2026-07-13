-- -----------------------------------------------------
-- RPC: transfer_product_stock
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION transfer_product_stock(
    p_product_id UUID,
    p_src_warehouse_id UUID,
    p_dest_warehouse_id UUID,
    p_qty NUMERIC
) RETURNS BOOLEAN AS $$
DECLARE
    v_src_qty NUMERIC := 0;
BEGIN
    -- 1. Check quantity in source warehouse
    SELECT COALESCE(stock_qty, 0) INTO v_src_qty 
    FROM product_stocks 
    WHERE product_id = p_product_id AND warehouse_id = p_src_warehouse_id;

    IF v_src_qty < p_qty THEN
        RAISE EXCEPTION 'Insufficient stock in source warehouse. Available: %, Requested: %', v_src_qty, p_qty;
    END IF;

    -- 2. Deduct from source
    UPDATE product_stocks 
    SET stock_qty = stock_qty - p_qty, updated_at = NOW() 
    WHERE product_id = p_product_id AND warehouse_id = p_src_warehouse_id;

    -- 3. Add to destination
    INSERT INTO product_stocks (product_id, warehouse_id, stock_qty)
    VALUES (p_product_id, p_dest_warehouse_id, p_qty)
    ON CONFLICT (product_id, warehouse_id) 
    DO UPDATE SET stock_qty = product_stocks.stock_qty + EXCLUDED.stock_qty, updated_at = NOW();

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;
