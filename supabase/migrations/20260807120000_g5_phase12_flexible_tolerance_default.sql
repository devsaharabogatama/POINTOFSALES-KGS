-- Forward-fix migration for G5 Phase 12: Flexible default tolerance matching
-- When NO explicit tolerance policy is configured, default tolerance is UNLIMITED (bebas)
-- so invoices evaluate as WITHIN_TOLERANCE and can be validated without requiring prior policy setup.

CREATE OR REPLACE FUNCTION private.refresh_supplier_invoice_totals(
    p_company_id UUID,p_document_id UUID
) RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_document public.supplier_invoice_documents%ROWTYPE;
    v_policy public.supplier_invoice_tolerance_policies%ROWTYPE;
    v_line_count INTEGER;
    v_invoice_qty NUMERIC(24,6);
    v_allocated_qty NUMERIC(24,6);
    v_subtotal NUMERIC(20,4);
    v_tax NUMERIC(20,4);
    v_grand NUMERIC(20,4);
    v_provisional NUMERIC(20,4);
    v_actual NUMERIC(20,4);
    v_variance NUMERIC(20,4);
    v_value_tolerance NUMERIC(20,4);
    v_matching_status TEXT;
    v_policy_found BOOLEAN := FALSE;
BEGIN
    SELECT * INTO v_document
    FROM public.supplier_invoice_documents document
    WHERE document.company_id = p_company_id
      AND document.id = p_document_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'SUPPLIER_INVOICE_NOT_FOUND'; END IF;

    UPDATE public.supplier_invoice_lines line SET
        allocated_base_qty = COALESCE((
            SELECT sum(allocation.allocated_base_qty)
            FROM public.supplier_invoice_allocations allocation
            WHERE allocation.company_id = line.company_id
              AND allocation.invoice_line_id = line.id
        ),0)
    WHERE line.company_id = p_company_id
      AND line.document_id = p_document_id;

    SELECT count(*),COALESCE(sum(line.invoice_base_qty),0),
           COALESCE(sum(line.allocated_base_qty),0),
           COALESCE(sum(line.subtotal_before_tax),0),
           COALESCE(sum(line.tax_amount),0),
           COALESCE(sum(line.line_total),0)
      INTO v_line_count,v_invoice_qty,v_allocated_qty,
           v_subtotal,v_tax,v_grand
    FROM public.supplier_invoice_lines line
    WHERE line.company_id = p_company_id
      AND line.document_id = p_document_id;

    SELECT COALESCE(sum(allocation.provisional_value),0),
           COALESCE(sum(allocation.actual_value),0)
      INTO v_provisional,v_actual
    FROM public.supplier_invoice_allocations allocation
    WHERE allocation.company_id = p_company_id
      AND allocation.document_id = p_document_id;
    v_variance := round(v_actual-v_provisional,4);

    SELECT policy.* INTO v_policy
    FROM public.supplier_invoice_tolerance_policies policy
    WHERE policy.company_id = p_company_id
      AND policy.is_active
      AND policy.effective_from <= v_document.invoice_date
      AND (policy.supplier_id = v_document.supplier_id
           OR policy.supplier_id IS NULL)
    ORDER BY (policy.supplier_id IS NOT NULL) DESC,
             policy.effective_from DESC,policy.id
    LIMIT 1;

    IF FOUND THEN
        v_policy_found := TRUE;
        v_value_tolerance := GREATEST(
            COALESCE(v_policy.value_tolerance_amount,0),
            round(v_provisional*COALESCE(v_policy.value_tolerance_percent,0)/100,4)
        );
    ELSE
        -- Flexible default: When NO explicit tolerance policy is configured, treat as UNLIMITED (bebas)
        v_value_tolerance := 999999999999.99;
    END IF;

    IF v_allocated_qty = 0 THEN
        v_matching_status := 'UNMATCHED';
    ELSIF v_allocated_qty < v_invoice_qty THEN
        v_matching_status := 'PARTIALLY_MATCHED';
    ELSIF abs(v_variance) = 0 THEN
        v_matching_status := 'MATCHED';
    ELSIF abs(v_variance) <= v_value_tolerance THEN
        v_matching_status := 'WITHIN_TOLERANCE';
    ELSE
        v_matching_status := 'EXCEPTION';
    END IF;

    DELETE FROM public.supplier_invoice_tolerance_results result
    WHERE result.company_id = p_company_id
      AND result.document_id = p_document_id;

    INSERT INTO public.supplier_invoice_tolerance_results(
        company_id,document_id,tolerance_policy_id,tolerance_policy_version,
        invoice_base_qty,allocated_base_qty,quantity_variance_base_qty,
        quantity_tolerance_percent_snapshot,
        quantity_tolerance_base_qty_snapshot,
        provisional_value,actual_value,value_variance,
        value_tolerance_percent_snapshot,value_tolerance_amount_snapshot,
        result_status
    ) VALUES (
        p_company_id,p_document_id,
        CASE WHEN v_policy_found THEN v_policy.id ELSE NULL END,
        CASE WHEN v_policy_found THEN v_policy.master_version ELSE NULL END,
        v_invoice_qty,v_allocated_qty,v_invoice_qty-v_allocated_qty,
        CASE WHEN v_policy_found THEN COALESCE(v_policy.quantity_tolerance_percent,0) ELSE 100 END,
        CASE WHEN v_policy_found THEN v_policy.quantity_tolerance_base_qty ELSE NULL END,
        v_provisional,v_actual,v_variance,
        CASE WHEN v_policy_found THEN COALESCE(v_policy.value_tolerance_percent,0) ELSE 100 END,
        CASE WHEN v_policy_found THEN v_policy.value_tolerance_amount ELSE NULL END,
        CASE
            WHEN v_matching_status = 'MATCHED' THEN 'MATCHED'
            WHEN v_matching_status = 'WITHIN_TOLERANCE' THEN 'WITHIN_TOLERANCE'
            WHEN v_matching_status = 'EXCEPTION' THEN 'EXCEPTION'
            ELSE 'HOLD'
        END
    );

    UPDATE public.supplier_invoice_documents SET
        matching_status = v_matching_status,
        line_count = v_line_count,
        invoice_total_base_qty = v_invoice_qty,
        allocated_total_base_qty = v_allocated_qty,
        subtotal_before_tax = v_subtotal,
        tax_total = v_tax,
        grand_total = v_grand,
        provisional_value_allocated = v_provisional,
        actual_value_allocated = v_actual,
        purchase_price_variance = v_variance,
        tolerance_policy_id = CASE WHEN v_policy_found THEN v_policy.id ELSE NULL END,
        tolerance_policy_version = CASE WHEN v_policy_found THEN v_policy.master_version ELSE NULL END,
        updated_at = clock_timestamp()
    WHERE company_id = p_company_id AND id = p_document_id;

    RETURN v_matching_status;
END;
$$;
