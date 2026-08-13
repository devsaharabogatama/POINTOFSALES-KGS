-- SLD phase 2: canonical Sales Invoice snapshot and delivery-only Surat Jalan.
-- Sale POSTED remains the only commercial/Stock/Finance source of truth.

BEGIN;

DO $migration_guard$
BEGIN
    IF (
        SELECT count(*) FROM private.kgs_schema_migrations
        WHERE version='20260811110000'
    )<>1 THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: BRD Phase 1 dependency missing';
    END IF;
    IF EXISTS(
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260811130000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: SLD Phase 2 already applied';
    END IF;
    IF EXISTS(
        SELECT 1 FROM public.sales_headers sale
        WHERE sale.document_status='POSTED'
          AND (
              sale.invoice_no IS NULL OR btrim(sale.invoice_no)=''
              OR sale.receipt_snapshot IS NULL
          )
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: invalid POSTED Sale snapshot';
    END IF;
    IF EXISTS(
        SELECT 1 FROM public.sales_headers sale
        WHERE sale.sj_required
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: legacy delivery requires review';
    END IF;
    IF to_regclass('public.sales_invoice_snapshots') IS NOT NULL
       OR to_regclass('public.sales_delivery_documents') IS NOT NULL
       OR to_regclass('public.sales_delivery_lines') IS NOT NULL
       OR to_regclass('public.sales_document_audit') IS NOT NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Sales document relation collision';
    END IF;
END
$migration_guard$;

ALTER TABLE public.sales_headers
    ADD COLUMN fulfillment_mode TEXT NOT NULL DEFAULT 'PICKUP',
    ADD COLUMN delivery_recipient_name TEXT,
    ADD COLUMN delivery_recipient_phone TEXT,
    ADD COLUMN delivery_address TEXT,
    ADD COLUMN delivery_scheduled_at TIMESTAMPTZ,
    ADD COLUMN delivery_notes TEXT,
    ADD CONSTRAINT sales_headers_fulfillment_mode_check CHECK(
        fulfillment_mode IN ('PICKUP','DELIVERY')
    ),
    ADD CONSTRAINT sales_headers_fulfillment_shape_check CHECK(
        (
            fulfillment_mode='PICKUP'
            AND NOT sj_required
            AND delivery_recipient_name IS NULL
            AND delivery_recipient_phone IS NULL
            AND delivery_address IS NULL
            AND delivery_scheduled_at IS NULL
            AND delivery_notes IS NULL
        ) OR (
            fulfillment_mode='DELIVERY'
            AND sj_required
            AND (
                document_status<>'POSTED'
                OR (
                    COALESCE(btrim(delivery_recipient_name),'')<>''
                    AND COALESCE(btrim(delivery_recipient_phone),'')<>''
                    AND COALESCE(btrim(delivery_address),'')<>''
                )
            )
        )
    );

CREATE TABLE public.sales_invoice_snapshots(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    sales_id UUID NOT NULL,
    invoice_no TEXT NOT NULL,
    snapshot_version BIGINT NOT NULL DEFAULT 1,
    snapshot_provenance TEXT NOT NULL,
    snapshot_payload JSONB NOT NULL,
    branding_logo_object_path TEXT,
    branding_logo_version BIGINT,
    branding_logo_checksum_sha256 TEXT,
    created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT sales_invoice_snapshots_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT sales_invoice_snapshots_company_sale_unique
        UNIQUE(company_id,sales_id),
    CONSTRAINT sales_invoice_snapshots_company_invoice_unique
        UNIQUE(company_id,invoice_no),
    CONSTRAINT sales_invoice_snapshot_version_positive
        CHECK(snapshot_version>0),
    CONSTRAINT sales_invoice_snapshot_provenance_check
        CHECK(snapshot_provenance IN ('LIVE_POST','LEGACY_CUTOVER')),
    CONSTRAINT sales_invoice_snapshot_identity_check CHECK(
        btrim(invoice_no)<>''
        AND jsonb_typeof(snapshot_payload)='object'
    ),
    CONSTRAINT fk_sales_invoice_snapshot_company
        FOREIGN KEY(company_id) REFERENCES public.companies(id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_sales_invoice_snapshot_sale
        FOREIGN KEY(company_id,sales_id)
        REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.sales_delivery_documents(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    delivery_no TEXT NOT NULL,
    sales_id UUID NOT NULL,
    invoice_snapshot_id UUID NOT NULL,
    store_id UUID NOT NULL,
    warehouse_id UUID NOT NULL,
    customer_id UUID,
    recipient_name TEXT NOT NULL,
    recipient_phone TEXT NOT NULL,
    delivery_address TEXT NOT NULL,
    scheduled_at TIMESTAMPTZ,
    delivery_notes TEXT,
    status TEXT NOT NULL DEFAULT 'READY',
    snapshot_payload JSONB NOT NULL,
    branding_logo_object_path TEXT,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    dispatched_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    dispatched_at TIMESTAMPTZ,
    delivered_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    delivered_at TIMESTAMPTZ,
    canceled_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
    canceled_at TIMESTAMPTZ,
    cancel_reason TEXT,
    CONSTRAINT sales_delivery_documents_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT sales_delivery_documents_company_no_unique
        UNIQUE(company_id,delivery_no),
    CONSTRAINT sales_delivery_documents_company_sale_unique
        UNIQUE(company_id,sales_id),
    CONSTRAINT sales_delivery_document_identity_check CHECK(
        btrim(delivery_no)<>''
        AND btrim(recipient_name)<>''
        AND btrim(recipient_phone)<>''
        AND btrim(delivery_address)<>''
        AND jsonb_typeof(snapshot_payload)='object'
    ),
    CONSTRAINT sales_delivery_document_status_check
        CHECK(status IN ('READY','DISPATCHED','DELIVERED','CANCELED')),
    CONSTRAINT sales_delivery_document_version_positive
        CHECK(master_version>0),
    CONSTRAINT sales_delivery_document_lifecycle_check CHECK(
        (status='READY' AND dispatched_at IS NULL AND delivered_at IS NULL
            AND canceled_at IS NULL)
        OR (status='DISPATCHED' AND dispatched_at IS NOT NULL
            AND dispatched_by IS NOT NULL AND delivered_at IS NULL
            AND canceled_at IS NULL)
        OR (status='DELIVERED' AND dispatched_at IS NOT NULL
            AND dispatched_by IS NOT NULL AND delivered_at IS NOT NULL
            AND delivered_by IS NOT NULL AND canceled_at IS NULL)
        OR (status='CANCELED' AND canceled_at IS NOT NULL
            AND canceled_by IS NOT NULL
            AND COALESCE(btrim(cancel_reason),'')<>'')
    ),
    CONSTRAINT fk_sales_delivery_company
        FOREIGN KEY(company_id) REFERENCES public.companies(id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_sales_delivery_sale
        FOREIGN KEY(company_id,sales_id)
        REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sales_delivery_invoice
        FOREIGN KEY(company_id,invoice_snapshot_id)
        REFERENCES public.sales_invoice_snapshots(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_sales_delivery_store
        FOREIGN KEY(company_id,store_id)
        REFERENCES public.stores(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sales_delivery_warehouse
        FOREIGN KEY(company_id,warehouse_id)
        REFERENCES public.warehouses(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sales_delivery_customer
        FOREIGN KEY(company_id,customer_id)
        REFERENCES public.customers(company_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.sales_delivery_lines(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    delivery_document_id UUID NOT NULL,
    sales_detail_id UUID NOT NULL,
    line_no INTEGER NOT NULL,
    product_id UUID NOT NULL,
    product_sku_snapshot TEXT NOT NULL,
    product_name_snapshot TEXT NOT NULL,
    sale_uom_id UUID NOT NULL,
    sale_uom_name_snapshot TEXT NOT NULL,
    quantity_uom NUMERIC(24,6) NOT NULL,
    factor_to_base_snapshot NUMERIC(24,6) NOT NULL,
    quantity_base NUMERIC(24,6) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT sales_delivery_lines_company_id_id_unique UNIQUE(company_id,id),
    CONSTRAINT sales_delivery_line_no_unique
        UNIQUE(company_id,delivery_document_id,line_no),
    CONSTRAINT sales_delivery_line_source_unique
        UNIQUE(company_id,delivery_document_id,sales_detail_id),
    CONSTRAINT sales_delivery_line_snapshot_check CHECK(
        line_no>0 AND btrim(product_sku_snapshot)<>''
        AND btrim(product_name_snapshot)<>''
        AND btrim(sale_uom_name_snapshot)<>''
        AND quantity_uom>0 AND factor_to_base_snapshot>0
        AND quantity_base>0
    ),
    CONSTRAINT fk_sales_delivery_line_document
        FOREIGN KEY(company_id,delivery_document_id)
        REFERENCES public.sales_delivery_documents(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_sales_delivery_line_detail
        FOREIGN KEY(company_id,sales_detail_id)
        REFERENCES public.sales_details(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sales_delivery_line_product
        FOREIGN KEY(company_id,product_id)
        REFERENCES public.products(company_id,id) ON DELETE RESTRICT,
    CONSTRAINT fk_sales_delivery_line_uom
        FOREIGN KEY(company_id,sale_uom_id)
        REFERENCES public.uoms(company_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.sales_document_audit(
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    document_type TEXT NOT NULL,
    document_id UUID NOT NULL,
    sales_id UUID NOT NULL,
    action TEXT NOT NULL,
    actor_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT sales_document_audit_type_check CHECK(
        document_type IN ('SALE','SALES_INVOICE','SALES_DELIVERY')
    ),
    CONSTRAINT sales_document_audit_action_check CHECK(
        action IN (
            'CONFIGURE_FULFILLMENT','CREATE','PRINT','DISPATCH',
            'DELIVER','CANCEL'
        )
    ),
    CONSTRAINT fk_sales_document_audit_sale
        FOREIGN KEY(company_id,sales_id)
        REFERENCES public.sales_headers(company_id,id) ON DELETE RESTRICT
);

CREATE TABLE private.sales_delivery_number_counters(
    company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
    period_key TEXT NOT NULL,
    next_value BIGINT NOT NULL CHECK(next_value>0),
    PRIMARY KEY(company_id,period_key),
    CONSTRAINT sales_delivery_counter_period_check
        CHECK(period_key ~ '^[0-9]{6}$')
);

CREATE INDEX idx_sales_invoice_snapshots_created
    ON public.sales_invoice_snapshots(company_id,created_at DESC);
CREATE INDEX idx_sales_delivery_documents_status_created
    ON public.sales_delivery_documents(company_id,status,created_at DESC);
CREATE INDEX idx_sales_document_audit_document_created
    ON public.sales_document_audit(
        company_id,document_type,document_id,created_at DESC
    );

CREATE FUNCTION private.next_sales_delivery_no(
    p_company_id UUID,p_document_at TIMESTAMPTZ
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_period TEXT:=to_char(p_document_at,'YYYYMM');
    v_number BIGINT;
BEGIN
    INSERT INTO private.sales_delivery_number_counters(
        company_id,period_key,next_value
    ) VALUES(p_company_id,v_period,2)
    ON CONFLICT(company_id,period_key) DO UPDATE SET
        next_value=private.sales_delivery_number_counters.next_value+1
    RETURNING next_value-1 INTO v_number;
    RETURN 'SJ/'||substr(v_period,1,4)||'/'||substr(v_period,5,2)||'/'
        ||lpad(v_number::TEXT,6,'0');
END;
$$;

CREATE FUNCTION private.build_sales_invoice_snapshot(
    p_company_id UUID,p_sales_id UUID,p_provenance TEXT
)
RETURNS JSONB
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
    SELECT jsonb_build_object(
        'snapshotVersion',1,
        'snapshotProvenance',p_provenance,
        'capturedAt',clock_timestamp(),
        'invoiceNo',sale.invoice_no,
        'saleId',sale.id,
        'company',jsonb_build_object(
            'name',company.company_name,'legalName',company.legal_name,
            'taxId',company.tax_id,'timezone',company.timezone,
            'currencyCode',company.currency_code
        ),
        'branding',jsonb_build_object(
            'logoObjectPath',branding.logo_object_path,
            'logoPublicUrl',branding.logo_public_url,
            'logoVersion',branding.logo_version,
            'logoChecksumSha256',branding.logo_checksum_sha256
        ),
        'store',jsonb_build_object(
            'name',store.store_name,'address',store.address,
            'timezone',store.timezone
        ),
        'warehouse',jsonb_build_object('name',warehouse.name),
        'terminal',jsonb_build_object('name',terminal.pos_name),
        'cashier',jsonb_build_object('name',cashier.name),
        'customer',CASE WHEN customer.id IS NULL THEN NULL ELSE
            jsonb_build_object(
                'code',customer.code,'name',customer.name,
                'phone',customer.phone,'address',customer.address,
                'parentCode',parent_customer.code,
                'parentName',parent_customer.name
            ) END,
        'transactionAt',sale.transaction_date,
        'postedAt',sale.posted_at,
        'sourceChannel',sale.source_channel,
        'isTempo',sale.is_tempo,
        'dueDate',sale.due_date,
        'lines',COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'lineKey',line.client_line_key,
                'sku',line.product_sku_snapshot,
                'productName',line.product_name_snapshot,
                'uomName',line.sale_uom_name_snapshot,
                'quantity',line.qty,
                'factorToBase',line.uom_factor_to_base_snapshot,
                'quantityBase',line.quantity_base,
                'unitPrice',line.resolved_unit_price,
                'discount',line.line_discount_amount
                    +line.allocated_order_discount_amount,
                'taxCode',line.tax_code_snapshot,
                'taxName',line.tax_name_snapshot,
                'taxRatePercent',line.tax_rate_percent_snapshot,
                'taxPriceMode',line.tax_price_mode_snapshot,
                'taxAmount',line.tax_amount,
                'lineTotal',line.line_total
            ) ORDER BY line.id)
            FROM public.sales_details line
            WHERE line.company_id=sale.company_id
              AND line.sales_id=sale.id
        ),'[]'::JSONB),
        'payments',COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'clientPaymentKey',payment.client_payment_key,
                'methodName',payment.payment_method_name_snapshot,
                'methodType',payment.payment_method_type_snapshot,
                'settlementRoute',payment.settlement_route_snapshot,
                'amount',payment.amount,
                'configuredFee',payment.configured_fee_amount,
                'customerSurcharge',payment.customer_surcharge_amount,
                'tenderedAmount',payment.tendered_amount,
                'changeAmount',payment.change_amount,
                'overpaymentDisposition',payment.overpayment_disposition,
                'customerBalanceCreditAmount',
                    payment.customer_balance_credit_amount,
                'customerBalanceUsageAmount',
                    payment.customer_balance_usage_amount,
                'proofUrl',payment.proof_url,
                'offlineVerificationStatus',
                    payment.offline_verification_status
            ) ORDER BY payment.payment_no)
            FROM public.sales_payments payment
            WHERE payment.company_id=sale.company_id
              AND payment.sales_id=sale.id
              AND NOT payment.is_reversal
        ),'[]'::JSONB),
        'totals',jsonb_build_object(
            'subtotal',sale.subtotal,
            'itemDiscount',sale.item_discount,
            'orderDiscount',sale.global_discount,
            'totalBeforeRounding',sale.grand_total_before_rounding,
            'roundingDirection',sale.rounding_direction,
            'roundingAdjustment',sale.rounding_adjustment,
            'grandTotal',sale.grand_total_after_rounding,
            'paidAmount',sale.paid_amount,
            'receivable',sale.sisa_piutang,
            'customerBalanceCredit',(
                SELECT COALESCE(sum(payment.customer_balance_credit_amount),0)
                FROM public.sales_payments payment
                WHERE payment.company_id=sale.company_id
                  AND payment.sales_id=sale.id AND NOT payment.is_reversal
            ),
            'customerBalanceUsage',(
                SELECT COALESCE(sum(payment.customer_balance_usage_amount),0)
                FROM public.sales_payments payment
                WHERE payment.company_id=sale.company_id
                  AND payment.sales_id=sale.id AND NOT payment.is_reversal
            )
        )
    )
    FROM public.sales_headers sale
    JOIN public.companies company ON company.id=sale.company_id
    JOIN public.stores store
      ON store.company_id=sale.company_id AND store.id=sale.store_id
    JOIN public.warehouses warehouse
      ON warehouse.company_id=sale.company_id
     AND warehouse.id=sale.sales_warehouse_id
    JOIN public.pos_terminals terminal
      ON terminal.company_id=sale.company_id AND terminal.id=sale.pos_id
    JOIN public.profiles cashier ON cashier.id=sale.posted_by
    LEFT JOIN public.customers customer
      ON customer.company_id=sale.company_id AND customer.id=sale.customer_id
    LEFT JOIN public.customers parent_customer
      ON parent_customer.company_id=customer.company_id
     AND parent_customer.id=customer.parent_customer_id
    LEFT JOIN public.company_branding_profiles branding
      ON branding.company_id=sale.company_id
    WHERE sale.company_id=p_company_id AND sale.id=p_sales_id
      AND sale.document_status='POSTED';
$$;

CREATE FUNCTION private.ensure_sales_documents(
    p_company_id UUID,p_sales_id UUID,p_provenance TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_sale public.sales_headers%ROWTYPE;
    v_invoice_id UUID;
    v_delivery_id UUID;
    v_delivery_no TEXT;
    v_payload JSONB;
    v_branding public.company_branding_profiles%ROWTYPE;
BEGIN
    SELECT sale.* INTO v_sale
    FROM public.sales_headers sale
    WHERE sale.company_id=p_company_id AND sale.id=p_sales_id;
    IF NOT FOUND OR v_sale.document_status<>'POSTED' THEN RETURN; END IF;
    IF p_provenance NOT IN ('LIVE_POST','LEGACY_CUTOVER') THEN
        RAISE EXCEPTION 'INVALID_SALES_DOCUMENT_PROVENANCE';
    END IF;

    v_payload:=private.build_sales_invoice_snapshot(
        p_company_id,p_sales_id,p_provenance
    );
    IF v_payload IS NULL THEN
        RAISE EXCEPTION 'SALES_INVOICE_SNAPSHOT_SOURCE_INCOMPLETE';
    END IF;
    SELECT branding.* INTO v_branding
    FROM public.company_branding_profiles branding
    WHERE branding.company_id=p_company_id;

    INSERT INTO public.sales_invoice_snapshots(
        company_id,sales_id,invoice_no,snapshot_version,
        snapshot_provenance,snapshot_payload,branding_logo_object_path,
        branding_logo_version,branding_logo_checksum_sha256,created_by,created_at
    ) VALUES(
        p_company_id,p_sales_id,v_sale.invoice_no,1,p_provenance,v_payload,
        v_branding.logo_object_path,v_branding.logo_version,
        v_branding.logo_checksum_sha256,v_sale.posted_by,
        COALESCE(v_sale.posted_at,clock_timestamp())
    ) ON CONFLICT(company_id,sales_id) DO NOTHING
    RETURNING id INTO v_invoice_id;
    IF v_invoice_id IS NOT NULL THEN
        INSERT INTO public.sales_document_audit(
            company_id,document_type,document_id,sales_id,action,actor_id,
            before_state,after_state,created_at
        ) VALUES(
            p_company_id,'SALES_INVOICE',v_invoice_id,p_sales_id,'CREATE',
            v_sale.posted_by,NULL,jsonb_build_object(
                'invoiceNo',v_sale.invoice_no,'provenance',p_provenance
            ),COALESCE(v_sale.posted_at,clock_timestamp())
        );
    ELSE
        SELECT invoice.id INTO STRICT v_invoice_id
        FROM public.sales_invoice_snapshots invoice
        WHERE invoice.company_id=p_company_id AND invoice.sales_id=p_sales_id;
    END IF;

    IF v_sale.fulfillment_mode='PICKUP' THEN
        IF EXISTS(
            SELECT 1 FROM public.sales_delivery_documents delivery
            WHERE delivery.company_id=p_company_id
              AND delivery.sales_id=p_sales_id
        ) THEN RAISE EXCEPTION 'PICKUP_SALE_HAS_DELIVERY_DOCUMENT'; END IF;
        RETURN;
    END IF;
    IF COALESCE(btrim(v_sale.delivery_recipient_name),'')=''
       OR COALESCE(btrim(v_sale.delivery_recipient_phone),'')=''
       OR COALESCE(btrim(v_sale.delivery_address),'')='' THEN
        RAISE EXCEPTION 'DELIVERY_RECIPIENT_REQUIRED';
    END IF;

    SELECT delivery.id,delivery.delivery_no
    INTO v_delivery_id,v_delivery_no
    FROM public.sales_delivery_documents delivery
    WHERE delivery.company_id=p_company_id AND delivery.sales_id=p_sales_id;
    IF v_delivery_id IS NULL THEN
        v_delivery_no:=private.next_sales_delivery_no(
            p_company_id,COALESCE(v_sale.posted_at,clock_timestamp())
        );
        INSERT INTO public.sales_delivery_documents(
            company_id,delivery_no,sales_id,invoice_snapshot_id,store_id,
            warehouse_id,customer_id,recipient_name,recipient_phone,
            delivery_address,scheduled_at,delivery_notes,status,
            snapshot_payload,branding_logo_object_path,created_by,created_at
        ) VALUES(
            p_company_id,v_delivery_no,p_sales_id,v_invoice_id,v_sale.store_id,
            v_sale.sales_warehouse_id,v_sale.customer_id,
            btrim(v_sale.delivery_recipient_name),
            btrim(v_sale.delivery_recipient_phone),
            btrim(v_sale.delivery_address),v_sale.delivery_scheduled_at,
            NULLIF(btrim(v_sale.delivery_notes),''),'READY',
            jsonb_build_object(
                'snapshotVersion',1,'deliveryNo',v_delivery_no,
                'invoiceNo',v_sale.invoice_no,'saleId',p_sales_id,
                'company',v_payload->'company','branding',v_payload->'branding',
                'store',v_payload->'store','warehouse',v_payload->'warehouse',
                'customer',v_payload->'customer',
                'recipient',jsonb_build_object(
                    'name',btrim(v_sale.delivery_recipient_name),
                    'phone',btrim(v_sale.delivery_recipient_phone),
                    'address',btrim(v_sale.delivery_address)
                ),
                'scheduledAt',v_sale.delivery_scheduled_at,
                'notes',NULLIF(btrim(v_sale.delivery_notes),''),
                'lines',(
                    SELECT jsonb_agg(jsonb_build_object(
                        'sku',line.product_sku_snapshot,
                        'productName',line.product_name_snapshot,
                        'uomName',line.sale_uom_name_snapshot,
                        'quantity',line.qty
                    ) ORDER BY line.id)
                    FROM public.sales_details line
                    WHERE line.company_id=p_company_id
                      AND line.sales_id=p_sales_id
                )
            ),v_branding.logo_object_path,v_sale.posted_by,
            COALESCE(v_sale.posted_at,clock_timestamp())
        ) RETURNING id INTO v_delivery_id;

        INSERT INTO public.sales_delivery_lines(
            company_id,delivery_document_id,sales_detail_id,line_no,
            product_id,product_sku_snapshot,product_name_snapshot,sale_uom_id,
            sale_uom_name_snapshot,quantity_uom,factor_to_base_snapshot,
            quantity_base
        )
        SELECT
            line.company_id,v_delivery_id,line.id,
            (row_number() OVER(ORDER BY line.id))::INTEGER,line.product_id,
            line.product_sku_snapshot,line.product_name_snapshot,
            line.sale_uom_id,line.sale_uom_name_snapshot,line.qty,
            line.uom_factor_to_base_snapshot,line.quantity_base
        FROM public.sales_details line
        WHERE line.company_id=p_company_id AND line.sales_id=p_sales_id;

        INSERT INTO public.sales_document_audit(
            company_id,document_type,document_id,sales_id,action,actor_id,
            before_state,after_state,created_at
        ) VALUES(
            p_company_id,'SALES_DELIVERY',v_delivery_id,p_sales_id,'CREATE',
            v_sale.posted_by,NULL,jsonb_build_object(
                'deliveryNo',v_delivery_no,'status','READY'
            ),COALESCE(v_sale.posted_at,clock_timestamp())
        );
    END IF;

    IF v_sale.sj_no IS DISTINCT FROM v_delivery_no
       OR v_sale.sj_status<>'PENDING'::public.sj_status THEN
        UPDATE public.sales_headers SET
            sj_required=TRUE,sj_no=v_delivery_no,
            sj_status='PENDING'::public.sj_status
        WHERE company_id=p_company_id AND id=p_sales_id;
    END IF;
END;
$$;

CREATE FUNCTION private.trg_sld_capture_fulfillment_payload()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_mode TEXT;
BEGIN
    IF NEW.payload_snapshot IS NULL
       OR NOT (NEW.payload_snapshot ? 'fulfillmentMode') THEN
        RETURN NEW;
    END IF;
    v_mode:=upper(btrim(COALESCE(
        NEW.payload_snapshot->>'fulfillmentMode',''
    )));
    IF v_mode NOT IN ('PICKUP','DELIVERY') THEN
        RAISE EXCEPTION 'INVALID_FULFILLMENT_MODE';
    END IF;
    NEW.fulfillment_mode:=v_mode;
    NEW.sj_required:=v_mode='DELIVERY';
    IF v_mode='PICKUP' THEN
        NEW.delivery_recipient_name:=NULL;
        NEW.delivery_recipient_phone:=NULL;
        NEW.delivery_address:=NULL;
        NEW.delivery_scheduled_at:=NULL;
        NEW.delivery_notes:=NULL;
    ELSE
        NEW.delivery_recipient_name:=NULLIF(btrim(
            NEW.payload_snapshot->>'deliveryRecipientName'
        ),'');
        NEW.delivery_recipient_phone:=NULLIF(btrim(
            NEW.payload_snapshot->>'deliveryRecipientPhone'
        ),'');
        NEW.delivery_address:=NULLIF(btrim(
            NEW.payload_snapshot->>'deliveryAddress'
        ),'');
        NEW.delivery_scheduled_at:=NULLIF(
            NEW.payload_snapshot->>'deliveryScheduledAt',''
        )::TIMESTAMPTZ;
        NEW.delivery_notes:=NULLIF(btrim(
            NEW.payload_snapshot->>'deliveryNotes'
        ),'');
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_sld_finalize_posted_sale()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_sale public.sales_headers%ROWTYPE;
BEGIN
    SELECT sale.* INTO v_sale FROM public.sales_headers sale
    WHERE sale.company_id=NEW.company_id AND sale.id=NEW.id;
    IF FOUND AND v_sale.document_status='POSTED' THEN
        PERFORM private.ensure_sales_documents(
            v_sale.company_id,v_sale.id,'LIVE_POST'
        );
    END IF;
    RETURN NULL;
END;
$$;

CREATE FUNCTION private.trg_sld_immutable_history()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'FINAL_SALES_DOCUMENT_HISTORY_IMMUTABLE';
END;
$$;

CREATE FUNCTION private.trg_sld_guard_delivery_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
BEGIN
    IF TG_OP='DELETE' THEN
        RAISE EXCEPTION 'FINAL_SALES_DOCUMENT_HISTORY_IMMUTABLE';
    END IF;
    IF COALESCE(current_setting('kgs.sld_delivery_status_mutation',TRUE),'')
            <>'1' THEN
        RAISE EXCEPTION 'GUARDED_SALES_DELIVERY_MUTATION_REQUIRED';
    END IF;
    IF NEW.company_id IS DISTINCT FROM OLD.company_id
       OR NEW.delivery_no IS DISTINCT FROM OLD.delivery_no
       OR NEW.sales_id IS DISTINCT FROM OLD.sales_id
       OR NEW.invoice_snapshot_id IS DISTINCT FROM OLD.invoice_snapshot_id
       OR NEW.store_id IS DISTINCT FROM OLD.store_id
       OR NEW.warehouse_id IS DISTINCT FROM OLD.warehouse_id
       OR NEW.customer_id IS DISTINCT FROM OLD.customer_id
       OR NEW.recipient_name IS DISTINCT FROM OLD.recipient_name
       OR NEW.recipient_phone IS DISTINCT FROM OLD.recipient_phone
       OR NEW.delivery_address IS DISTINCT FROM OLD.delivery_address
       OR NEW.scheduled_at IS DISTINCT FROM OLD.scheduled_at
       OR NEW.delivery_notes IS DISTINCT FROM OLD.delivery_notes
       OR NEW.snapshot_payload IS DISTINCT FROM OLD.snapshot_payload
       OR NEW.branding_logo_object_path
            IS DISTINCT FROM OLD.branding_logo_object_path
       OR NEW.created_by IS DISTINCT FROM OLD.created_by
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'SALES_DELIVERY_SOURCE_SNAPSHOT_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_sld_validate_audit_reference()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
BEGIN
    IF NEW.document_type='SALE' AND NOT EXISTS(
        SELECT 1 FROM public.sales_headers sale
        WHERE sale.company_id=NEW.company_id AND sale.id=NEW.document_id
          AND sale.id=NEW.sales_id
    ) THEN RAISE EXCEPTION 'SALES_DOCUMENT_AUDIT_SOURCE_NOT_FOUND'; END IF;
    IF NEW.document_type='SALES_INVOICE' AND NOT EXISTS(
        SELECT 1 FROM public.sales_invoice_snapshots invoice
        WHERE invoice.company_id=NEW.company_id AND invoice.id=NEW.document_id
          AND invoice.sales_id=NEW.sales_id
    ) THEN RAISE EXCEPTION 'SALES_DOCUMENT_AUDIT_SOURCE_NOT_FOUND'; END IF;
    IF NEW.document_type='SALES_DELIVERY' AND NOT EXISTS(
        SELECT 1 FROM public.sales_delivery_documents delivery
        WHERE delivery.company_id=NEW.company_id
          AND delivery.id=NEW.document_id AND delivery.sales_id=NEW.sales_id
    ) THEN RAISE EXCEPTION 'SALES_DOCUMENT_AUDIT_SOURCE_NOT_FOUND'; END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER sld_capture_fulfillment_payload
BEFORE INSERT OR UPDATE OF payload_snapshot ON public.sales_headers
FOR EACH ROW EXECUTE FUNCTION private.trg_sld_capture_fulfillment_payload();

CREATE CONSTRAINT TRIGGER sld_finalize_posted_sale
AFTER INSERT OR UPDATE ON public.sales_headers
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION private.trg_sld_finalize_posted_sale();

CREATE TRIGGER sld_invoice_history_immutable
BEFORE UPDATE OR DELETE ON public.sales_invoice_snapshots
FOR EACH ROW EXECUTE FUNCTION private.trg_sld_immutable_history();
CREATE TRIGGER sld_delivery_line_history_immutable
BEFORE UPDATE OR DELETE ON public.sales_delivery_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_sld_immutable_history();
CREATE TRIGGER sld_document_audit_immutable
BEFORE UPDATE OR DELETE ON public.sales_document_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_sld_immutable_history();
CREATE TRIGGER sld_delivery_update_guard
BEFORE UPDATE OR DELETE ON public.sales_delivery_documents
FOR EACH ROW EXECUTE FUNCTION private.trg_sld_guard_delivery_update();
CREATE TRIGGER sld_document_audit_reference
BEFORE INSERT ON public.sales_document_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_sld_validate_audit_reference();

CREATE FUNCTION public.configure_pos_sale_fulfillment(
    p_sales_id UUID,p_master_version BIGINT,p_fulfillment_mode TEXT,
    p_recipient_name TEXT,p_recipient_phone TEXT,p_delivery_address TEXT,
    p_scheduled_at TIMESTAMPTZ,p_notes TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_actor UUID:=auth.uid();
    v_company UUID:=public.private_active_company_id();
    v_sale public.sales_headers%ROWTYPE;
    v_mode TEXT:=upper(btrim(COALESCE(p_fulfillment_mode,'')));
    v_new_version BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    SELECT sale.* INTO v_sale FROM public.sales_headers sale
    WHERE sale.company_id=v_company AND sale.id=p_sales_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SALE_DRAFT_NOT_FOUND'; END IF;
    IF v_sale.document_status<>'DRAFT' THEN RAISE EXCEPTION 'SALE_DRAFT_REQUIRED'; END IF;
    IF v_sale.master_version<>p_master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF v_sale.edit_lock_owner_id IS DISTINCT FROM v_actor
       OR v_sale.edit_lock_session_id IS DISTINCT FROM v_sale.session_id
       OR v_sale.edit_lock_heartbeat_at IS NULL
       OR v_sale.edit_lock_heartbeat_at<clock_timestamp()-interval '5 minutes' THEN
        RAISE EXCEPTION 'SALE_DRAFT_EDIT_LOCK_REQUIRED';
    END IF;
    IF v_mode NOT IN ('PICKUP','DELIVERY') THEN
        RAISE EXCEPTION 'INVALID_FULFILLMENT_MODE';
    END IF;
    IF v_mode='DELIVERY' AND (
        COALESCE(btrim(p_recipient_name),'')=''
        OR COALESCE(btrim(p_recipient_phone),'')=''
        OR COALESCE(btrim(p_delivery_address),'')=''
    ) THEN RAISE EXCEPTION 'DELIVERY_RECIPIENT_REQUIRED'; END IF;

    v_new_version:=v_sale.master_version+1;
    UPDATE public.sales_headers SET
        fulfillment_mode=v_mode,
        sj_required=v_mode='DELIVERY',
        delivery_recipient_name=CASE WHEN v_mode='DELIVERY'
            THEN btrim(p_recipient_name) END,
        delivery_recipient_phone=CASE WHEN v_mode='DELIVERY'
            THEN btrim(p_recipient_phone) END,
        delivery_address=CASE WHEN v_mode='DELIVERY'
            THEN btrim(p_delivery_address) END,
        delivery_scheduled_at=CASE WHEN v_mode='DELIVERY'
            THEN p_scheduled_at END,
        delivery_notes=CASE WHEN v_mode='DELIVERY'
            THEN NULLIF(btrim(p_notes),'') END,
        payload_snapshot=COALESCE(payload_snapshot,'{}'::JSONB)
            ||jsonb_build_object(
                'fulfillmentMode',v_mode,
                'deliveryRecipientName',CASE WHEN v_mode='DELIVERY'
                    THEN btrim(p_recipient_name) END,
                'deliveryRecipientPhone',CASE WHEN v_mode='DELIVERY'
                    THEN btrim(p_recipient_phone) END,
                'deliveryAddress',CASE WHEN v_mode='DELIVERY'
                    THEN btrim(p_delivery_address) END,
                'deliveryScheduledAt',CASE WHEN v_mode='DELIVERY'
                    THEN p_scheduled_at END,
                'deliveryNotes',CASE WHEN v_mode='DELIVERY'
                    THEN NULLIF(btrim(p_notes),'') END
            ),
        master_version=v_new_version,updated_at=clock_timestamp()
    WHERE company_id=v_company AND id=p_sales_id;

    INSERT INTO public.sales_document_audit(
        company_id,document_type,document_id,sales_id,action,actor_id,
        before_state,after_state
    ) VALUES(
        v_company,'SALE',p_sales_id,p_sales_id,'CONFIGURE_FULFILLMENT',v_actor,
        jsonb_build_object(
            'fulfillmentMode',v_sale.fulfillment_mode,
            'masterVersion',v_sale.master_version
        ),jsonb_build_object(
            'fulfillmentMode',v_mode,'masterVersion',v_new_version
        )
    );
    RETURN jsonb_build_object(
        'salesId',p_sales_id,'fulfillmentMode',v_mode,
        'masterVersion',v_new_version
    );
END;
$$;

CREATE FUNCTION public.get_sales_invoice_document(p_sales_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id(); v_result JSONB;
BEGIN
    IF NOT public.private_sales_document_visible(p_sales_id) THEN
        RAISE EXCEPTION 'SALES_DOCUMENT_NOT_FOUND';
    END IF;
    SELECT jsonb_build_object(
        'invoiceNo',invoice.invoice_no,
        'snapshotVersion',invoice.snapshot_version,
        'snapshotProvenance',invoice.snapshot_provenance,
        'snapshot',invoice.snapshot_payload
    ) INTO v_result
    FROM public.sales_invoice_snapshots invoice
    WHERE invoice.company_id=v_company AND invoice.sales_id=p_sales_id;
    IF v_result IS NULL THEN RAISE EXCEPTION 'SALES_INVOICE_NOT_FOUND'; END IF;
    RETURN v_result;
END;
$$;

CREATE FUNCTION public.get_sales_delivery_document(p_sales_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id(); v_result JSONB;
BEGIN
    IF NOT public.private_sales_document_visible(p_sales_id) THEN
        RAISE EXCEPTION 'SALES_DOCUMENT_NOT_FOUND';
    END IF;
    SELECT jsonb_build_object(
        'deliveryDocumentId',delivery.id,
        'deliveryNo',delivery.delivery_no,'status',delivery.status,
        'masterVersion',delivery.master_version,
        'snapshot',delivery.snapshot_payload,
        'lines',COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'lineNo',line.line_no,'sku',line.product_sku_snapshot,
                'productName',line.product_name_snapshot,
                'uomName',line.sale_uom_name_snapshot,
                'quantity',line.quantity_uom
            ) ORDER BY line.line_no)
            FROM public.sales_delivery_lines line
            WHERE line.company_id=delivery.company_id
              AND line.delivery_document_id=delivery.id
        ),'[]'::JSONB)
    ) INTO v_result
    FROM public.sales_delivery_documents delivery
    WHERE delivery.company_id=v_company AND delivery.sales_id=p_sales_id;
    IF v_result IS NULL THEN RAISE EXCEPTION 'SALES_DELIVERY_NOT_FOUND'; END IF;
    RETURN v_result;
END;
$$;

CREATE FUNCTION public.update_sales_delivery_status(
    p_delivery_document_id UUID,p_master_version BIGINT,
    p_action TEXT,p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_actor UUID:=auth.uid(); v_company UUID:=public.private_active_company_id();
    v_delivery public.sales_delivery_documents%ROWTYPE;
    v_action TEXT:=upper(btrim(COALESCE(p_action,'')));
    v_status TEXT; v_now TIMESTAMPTZ:=clock_timestamp();
BEGIN
    SELECT delivery.* INTO v_delivery
    FROM public.sales_delivery_documents delivery
    WHERE delivery.company_id=v_company AND delivery.id=p_delivery_document_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SALES_DELIVERY_NOT_FOUND'; END IF;
    IF v_delivery.master_version<>p_master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,ARRAY[
            'COMPANY_OWNER','COMPANY_ADMIN','STORE_MANAGER'
        ]::TEXT[]
    ) THEN RAISE EXCEPTION 'SALES_DELIVERY_MANAGER_REQUIRED'; END IF;
    IF v_action='DISPATCH' AND v_delivery.status='READY' THEN
        v_status:='DISPATCHED';
    ELSIF v_action='DELIVER' AND v_delivery.status='DISPATCHED' THEN
        v_status:='DELIVERED';
    ELSIF v_action='CANCEL' AND v_delivery.status='READY'
          AND COALESCE(btrim(p_reason),'')<>'' THEN
        v_status:='CANCELED';
    ELSE RAISE EXCEPTION 'INVALID_SALES_DELIVERY_TRANSITION'; END IF;

    PERFORM set_config('kgs.sld_delivery_status_mutation','1',TRUE);
    UPDATE public.sales_delivery_documents SET
        status=v_status,master_version=master_version+1,
        dispatched_by=CASE WHEN v_status='DISPATCHED' THEN v_actor
            ELSE dispatched_by END,
        dispatched_at=CASE WHEN v_status='DISPATCHED' THEN v_now
            ELSE dispatched_at END,
        delivered_by=CASE WHEN v_status='DELIVERED' THEN v_actor
            ELSE delivered_by END,
        delivered_at=CASE WHEN v_status='DELIVERED' THEN v_now
            ELSE delivered_at END,
        canceled_by=CASE WHEN v_status='CANCELED' THEN v_actor
            ELSE canceled_by END,
        canceled_at=CASE WHEN v_status='CANCELED' THEN v_now
            ELSE canceled_at END,
        cancel_reason=CASE WHEN v_status='CANCELED' THEN btrim(p_reason)
            ELSE cancel_reason END
    WHERE company_id=v_company AND id=p_delivery_document_id;
    PERFORM set_config('kgs.sld_delivery_status_mutation','',TRUE);

    UPDATE public.sales_headers SET
        sj_status=CASE WHEN v_status IN ('DISPATCHED','DELIVERED')
            THEN 'SHIPPED'::public.sj_status
            WHEN v_status='CANCELED' THEN 'NONE'::public.sj_status
            ELSE sj_status END
    WHERE company_id=v_company AND id=v_delivery.sales_id;

    INSERT INTO public.sales_document_audit(
        company_id,document_type,document_id,sales_id,action,actor_id,
        before_state,after_state
    ) VALUES(
        v_company,'SALES_DELIVERY',p_delivery_document_id,v_delivery.sales_id,
        v_action,v_actor,jsonb_build_object(
            'status',v_delivery.status,'masterVersion',v_delivery.master_version
        ),jsonb_build_object(
            'status',v_status,'masterVersion',v_delivery.master_version+1,
            'reason',CASE WHEN v_status='CANCELED' THEN btrim(p_reason) END
        )
    );
    RETURN jsonb_build_object(
        'deliveryDocumentId',p_delivery_document_id,
        'deliveryNo',v_delivery.delivery_no,'status',v_status,
        'masterVersion',v_delivery.master_version+1
    );
END;
$$;

CREATE FUNCTION public.record_sales_document_print(
    p_document_type TEXT,p_document_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_actor UUID:=auth.uid(); v_company UUID:=public.private_active_company_id();
    v_type TEXT:=upper(btrim(COALESCE(p_document_type,'')));
    v_sales UUID; v_number TEXT;
BEGIN
    IF v_type='SALES_INVOICE' THEN
        SELECT invoice.sales_id,invoice.invoice_no INTO v_sales,v_number
        FROM public.sales_invoice_snapshots invoice
        WHERE invoice.company_id=v_company AND invoice.id=p_document_id;
    ELSIF v_type='SALES_DELIVERY' THEN
        SELECT delivery.sales_id,delivery.delivery_no INTO v_sales,v_number
        FROM public.sales_delivery_documents delivery
        WHERE delivery.company_id=v_company AND delivery.id=p_document_id;
    ELSE RAISE EXCEPTION 'INVALID_SALES_DOCUMENT_TYPE'; END IF;
    IF v_sales IS NULL OR NOT public.private_sales_document_visible(v_sales) THEN
        RAISE EXCEPTION 'SALES_DOCUMENT_NOT_FOUND';
    END IF;
    INSERT INTO public.sales_document_audit(
        company_id,document_type,document_id,sales_id,action,actor_id,
        before_state,after_state
    ) VALUES(
        v_company,v_type,p_document_id,v_sales,'PRINT',v_actor,NULL,
        jsonb_build_object('documentNo',v_number)
    );
    RETURN jsonb_build_object('documentNo',v_number,'printRecorded',TRUE);
END;
$$;

CREATE FUNCTION public.company_branding_logo_is_referenced(p_object_path TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE v_company UUID:=public.private_active_company_id();
BEGIN
    IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF NOT public.private_user_has_any_company_or_store_role(
        v_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN']::TEXT[]
    ) THEN RAISE EXCEPTION 'COMPANY_BRANDING_MANAGER_REQUIRED'; END IF;
    IF COALESCE(btrim(p_object_path),'')='' THEN RETURN FALSE; END IF;
    RETURN EXISTS(
        SELECT 1 FROM public.sales_invoice_snapshots invoice
        WHERE invoice.company_id=v_company
          AND invoice.branding_logo_object_path=p_object_path
    ) OR EXISTS(
        SELECT 1 FROM public.sales_delivery_documents delivery
        WHERE delivery.company_id=v_company
          AND delivery.branding_logo_object_path=p_object_path
    );
END;
$$;

-- Existing POSTED Sale receives a cutover snapshot. No Sale value is changed.
DO $legacy_backfill$
DECLARE v_sale RECORD;
BEGIN
    FOR v_sale IN
        SELECT sale.company_id,sale.id
        FROM public.sales_headers sale
        WHERE sale.document_status='POSTED'
        ORDER BY sale.company_id,sale.posted_at,sale.id
    LOOP
        PERFORM private.ensure_sales_documents(
            v_sale.company_id,v_sale.id,'LEGACY_CUTOVER'
        );
    END LOOP;
END
$legacy_backfill$;

ALTER TABLE public.sales_invoice_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_delivery_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_delivery_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_document_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Sales Invoice readable in visible Sale"
ON public.sales_invoice_snapshots FOR SELECT TO authenticated
USING(public.private_sales_document_visible(sales_id));
CREATE POLICY "Sales Delivery readable in visible Sale"
ON public.sales_delivery_documents FOR SELECT TO authenticated
USING(public.private_sales_document_visible(sales_id));
CREATE POLICY "Sales Delivery lines readable in visible Sale"
ON public.sales_delivery_lines FOR SELECT TO authenticated
USING(EXISTS(
    SELECT 1 FROM public.sales_delivery_documents delivery
    WHERE delivery.company_id=sales_delivery_lines.company_id
      AND delivery.id=sales_delivery_lines.delivery_document_id
      AND public.private_sales_document_visible(delivery.sales_id)
));
CREATE POLICY "Sales document audit readable in visible Sale"
ON public.sales_document_audit FOR SELECT TO authenticated
USING(public.private_sales_document_visible(sales_id));

REVOKE ALL ON
    public.sales_invoice_snapshots,public.sales_delivery_documents,
    public.sales_delivery_lines,public.sales_document_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON
    public.sales_invoice_snapshots,public.sales_delivery_documents,
    public.sales_delivery_lines,public.sales_document_audit
TO authenticated;
GRANT ALL ON
    public.sales_invoice_snapshots,public.sales_delivery_documents,
    public.sales_delivery_lines,public.sales_document_audit
TO service_role;

REVOKE ALL ON FUNCTION
    public.configure_pos_sale_fulfillment(
        UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ,TEXT
    ),
    public.get_sales_invoice_document(UUID),
    public.get_sales_delivery_document(UUID),
    public.update_sales_delivery_status(UUID,BIGINT,TEXT,TEXT),
    public.record_sales_document_print(TEXT,UUID),
    public.company_branding_logo_is_referenced(TEXT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
    public.configure_pos_sale_fulfillment(
        UUID,BIGINT,TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ,TEXT
    ),
    public.get_sales_invoice_document(UUID),
    public.get_sales_delivery_document(UUID),
    public.update_sales_delivery_status(UUID,BIGINT,TEXT,TEXT),
    public.record_sales_document_print(TEXT,UUID),
    public.company_branding_logo_is_referenced(TEXT)
TO authenticated,service_role;

REVOKE ALL ON FUNCTION
    private.next_sales_delivery_no(UUID,TIMESTAMPTZ),
    private.build_sales_invoice_snapshot(UUID,UUID,TEXT),
    private.ensure_sales_documents(UUID,UUID,TEXT),
    private.trg_sld_capture_fulfillment_payload(),
    private.trg_sld_finalize_posted_sale(),
    private.trg_sld_immutable_history(),
    private.trg_sld_guard_delivery_update(),
    private.trg_sld_validate_audit_reference()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.next_sales_delivery_no(UUID,TIMESTAMPTZ),
    private.build_sales_invoice_snapshot(UUID,UUID,TEXT),
    private.ensure_sales_documents(UUID,UUID,TEXT),
    private.trg_sld_capture_fulfillment_payload(),
    private.trg_sld_finalize_posted_sale(),
    private.trg_sld_immutable_history(),
    private.trg_sld_guard_delivery_update(),
    private.trg_sld_validate_audit_reference()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
    '20260811130000','sld_phase2_sales_document_foundation',
    'Immutable Sales Invoice snapshots, delivery-only Surat Jalan, deferred atomic finalization, legacy cutover provenance, guarded lifecycle/print audit, tenant RLS, and referenced branding retention without duplicate Stock or Finance effects'
);

COMMIT;
