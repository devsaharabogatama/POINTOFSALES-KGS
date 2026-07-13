-- -----------------------------------------------------
-- ENUMS
-- -----------------------------------------------------
DO $$ 
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'opname_status') THEN
        CREATE TYPE opname_status AS ENUM ('DRAFT', 'SUBMITTED', 'APPROVED');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'stock_movement_type') THEN
        CREATE TYPE stock_movement_type AS ENUM ('SALE', 'PURCHASE', 'ADJUSTMENT', 'TRANSFER_IN', 'TRANSFER_OUT');
    END IF;
END $$;

-- -----------------------------------------------------
-- UOM & CONVERSION TABLES
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS uoms (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    code TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS product_uom_conversions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    from_uom_id UUID NOT NULL REFERENCES uoms(id) ON DELETE CASCADE,
    to_uom_id UUID NOT NULL REFERENCES uoms(id) ON DELETE CASCADE,
    conversion_factor NUMERIC NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_product_uom_conversion UNIQUE (product_id, from_uom_id, to_uom_id)
);

-- Alter products to reference uoms table (optional but good for master data selection)
-- We keep uom TEXT column in products as fallback, but add a foreign key uom_id if needed
ALTER TABLE products ADD COLUMN IF NOT EXISTS uom_id UUID REFERENCES uoms(id);

-- -----------------------------------------------------
-- FIFO TABLES
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS product_batches (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE CASCADE,
    purchase_detail_id UUID, -- nullable, reference to purchases_details
    qty_purchased NUMERIC NOT NULL,
    qty_remaining NUMERIC NOT NULL,
    cogs_unit NUMERIC NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS sales_fifo_allocations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    sales_detail_id UUID NOT NULL REFERENCES sales_details(id) ON DELETE CASCADE,
    product_batch_id UUID NOT NULL REFERENCES product_batches(id) ON DELETE CASCADE,
    qty_allocated NUMERIC NOT NULL,
    cogs_unit NUMERIC NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- -----------------------------------------------------
-- STOCK OPNAME & ADJUSTMENT TABLES
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS stock_opnames (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    opname_no TEXT UNIQUE NOT NULL,
    warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE CASCADE,
    status opname_status NOT NULL DEFAULT 'DRAFT',
    notes TEXT,
    created_by UUID REFERENCES profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS stock_opname_details (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    opname_id UUID NOT NULL REFERENCES stock_opnames(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    system_qty NUMERIC NOT NULL,
    physical_qty NUMERIC NOT NULL,
    difference NUMERIC NOT NULL, -- (system_qty - physical_qty)
    notes TEXT
);

CREATE TABLE IF NOT EXISTS stock_adjustments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    adjustment_no TEXT UNIQUE NOT NULL,
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE CASCADE,
    opname_detail_id UUID REFERENCES stock_opname_details(id) ON DELETE SET NULL,
    qty_adjusted NUMERIC NOT NULL,
    cogs_unit NUMERIC NOT NULL,
    reason TEXT NOT NULL,
    created_by UUID REFERENCES profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- -----------------------------------------------------
-- STOCK MOVEMENT / STOCK CARD TABLE
-- -----------------------------------------------------
CREATE TABLE IF NOT EXISTS stock_movements (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE CASCADE,
    qty_change NUMERIC NOT NULL,
    movement_type stock_movement_type NOT NULL,
    reference_table TEXT NOT NULL,
    reference_id UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Enable RLS on new tables
ALTER TABLE uoms ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_uom_conversions ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales_fifo_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_opnames ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_opname_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_adjustments ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_movements ENABLE ROW LEVEL SECURITY;

-- -----------------------------------------------------
-- RLS POLICIES FOR NEW TABLES
-- -----------------------------------------------------
CREATE POLICY "Uoms viewable by authenticated users" ON uoms FOR SELECT TO authenticated USING (true);
CREATE POLICY "Uoms manageable by owner/manager" ON uoms FOR ALL TO authenticated USING (get_my_role() IN ('owner', 'manager'));

CREATE POLICY "Conversions viewable by authenticated users" ON product_uom_conversions FOR SELECT TO authenticated USING (true);
CREATE POLICY "Conversions manageable by owner/manager" ON product_uom_conversions FOR ALL TO authenticated USING (get_my_role() IN ('owner', 'manager'));

CREATE POLICY "Batches viewable by owner/manager" ON product_batches FOR ALL TO authenticated USING (get_my_role() IN ('owner', 'manager'));
CREATE POLICY "FIFO allocations viewable by owner/manager" ON sales_fifo_allocations FOR SELECT TO authenticated USING (get_my_role() IN ('owner', 'manager'));

CREATE POLICY "Opnames viewable by owner/manager" ON stock_opnames FOR SELECT TO authenticated USING (get_my_role() IN ('owner', 'manager'));
CREATE POLICY "Opnames manageable by owner/manager" ON stock_opnames FOR ALL TO authenticated USING (get_my_role() IN ('owner', 'manager'));

CREATE POLICY "Opname details viewable by owner/manager" ON stock_opname_details FOR SELECT TO authenticated USING (get_my_role() IN ('owner', 'manager'));
CREATE POLICY "Opname details manageable by owner/manager" ON stock_opname_details FOR ALL TO authenticated USING (get_my_role() IN ('owner', 'manager'));

CREATE POLICY "Adjustments viewable by owner/manager" ON stock_adjustments FOR SELECT TO authenticated USING (get_my_role() IN ('owner', 'manager'));
CREATE POLICY "Adjustments insertable by owner/manager" ON stock_adjustments FOR INSERT TO authenticated WITH CHECK (get_my_role() IN ('owner', 'manager'));

CREATE POLICY "Movements viewable by owner/manager" ON stock_movements FOR SELECT TO authenticated USING (get_my_role() IN ('owner', 'manager'));

-- -----------------------------------------------------
-- UPDATED RPC: transfer_product_stock WITH MOVEMENT LOGGING
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION transfer_product_stock(
    p_product_id UUID,
    p_src_warehouse_id UUID,
    p_dest_warehouse_id UUID,
    p_qty NUMERIC
) RETURNS BOOLEAN AS $$
DECLARE
    v_src_qty NUMERIC := 0;
    v_transfer_id UUID := uuid_generate_v4();
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

    -- 4. Log to stock_movements (Out & In)
    INSERT INTO stock_movements (product_id, warehouse_id, qty_change, movement_type, reference_table, reference_id)
    VALUES (p_product_id, p_src_warehouse_id, -p_qty, 'TRANSFER_OUT'::stock_movement_type, 'product_stocks', v_transfer_id);

    INSERT INTO stock_movements (product_id, warehouse_id, qty_change, movement_type, reference_table, reference_id)
    VALUES (p_product_id, p_dest_warehouse_id, p_qty, 'TRANSFER_IN'::stock_movement_type, 'product_stocks', v_transfer_id);

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;
