-- Permit positive inbound Stock movements to repair an existing negative
-- balance. Outbound movements ending below zero remain authorization-guarded.
BEGIN;

DO $guard$
DECLARE v_guard text;v_constraint text;
BEGIN
  IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations
    WHERE version='20260917140000') THEN
    RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260917140000';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260911140000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260914180000')
    OR NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations
      WHERE version='20260917100000') THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: inbound recovery dependencies missing';
  END IF;
  IF EXISTS(SELECT 1 FROM public.finance_posting_queue_runs
    WHERE status IN('PREVIEWED','APPROVED','PROCESSING')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: active Finance queue';
  END IF;
  IF EXISTS(SELECT 1 FROM public.pos_offline_sale_submissions
    WHERE status IN('QUEUED','SYNCING','NEEDS_CONFIRMATION')) THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: nonterminal Offline submission';
  END IF;

  SELECT pg_get_functiondef(
    'private.trg_g4_guard_negative_sale_movement()'::regprocedure) INTO v_guard;
  SELECT pg_get_constraintdef(oid) INTO v_constraint FROM pg_constraint
  WHERE conrelid='public.stock_movements'::regclass
    AND conname='stock_movements_balance_after_controlled';
  IF v_guard IS NULL OR v_guard!~'NEGATIVE_STOCK_AUTHORIZATION_REQUIRED'
    OR v_guard!~'pos_negative_stock_authorizations'
    OR v_guard!~'backoffice_negative_stock_allocations'
    OR v_guard!~'REVERSAL' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: negative movement guard drift';
  END IF;
  IF v_constraint IS NULL OR v_constraint!~'sales_headers'
    OR v_constraint!~'stock_transfer_documents' OR v_constraint!~'REVERSAL' THEN
    RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Stock balance constraint drift';
  END IF;
END
$guard$;

ALTER TABLE public.stock_movements
  DROP CONSTRAINT stock_movements_balance_after_controlled,
  ADD CONSTRAINT stock_movements_balance_after_controlled CHECK(
    balance_after_base_qty IS NULL OR balance_after_base_qty>=0
    OR qty_change>0
    OR (movement_type='SALE'::public.stock_movement_type
      AND reference_table='sales_headers')
    OR (movement_type='TRANSFER_OUT'::public.stock_movement_type
      AND reference_table='stock_transfer_documents')
    OR (movement_type='REVERSAL'::public.stock_movement_type
      AND reference_table='sales_headers' AND qty_change>0));

CREATE OR REPLACE FUNCTION private.trg_g4_guard_negative_sale_movement()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF NEW.balance_after_base_qty<0 AND NEW.qty_change<0 AND NOT (
    EXISTS(SELECT 1 FROM public.pos_negative_stock_authorizations authz
      WHERE authz.company_id=NEW.company_id AND authz.sales_id=NEW.reference_id
        AND authz.stock_product_id=NEW.product_id AND authz.warehouse_id=NEW.warehouse_id
        AND authz.balance_after_base_qty=NEW.balance_after_base_qty
        AND ((authz.authority_source='LEGACY_USER_POLICY'
            AND authz.policy_version IS NOT NULL AND authz.permission_version IS NOT NULL)
          OR (authz.authority_source='WAREHOUSE' AND authz.warehouse_version IS NOT NULL)))
    OR EXISTS(SELECT 1 FROM public.backoffice_negative_stock_allocations allocation
      WHERE allocation.company_id=NEW.company_id
        AND allocation.stock_transfer_document_id=NEW.reference_id
        AND allocation.stock_transfer_line_id=NEW.source_line_id
        AND allocation.product_id=NEW.product_id
        AND allocation.source_warehouse_id=NEW.warehouse_id
        AND allocation.authority_source='WAREHOUSE'
        AND allocation.warehouse_version>0
        AND NEW.movement_type='TRANSFER_OUT'::public.stock_movement_type
        AND NEW.reference_table='stock_transfer_documents')
    OR (NEW.movement_type='REVERSAL'::public.stock_movement_type
      AND NEW.reference_table='sales_headers' AND NEW.qty_change>0
      AND EXISTS(SELECT 1 FROM public.stock_movements original
        WHERE original.company_id=NEW.company_id AND original.id=NEW.source_line_id
          AND original.product_id=NEW.product_id
          AND original.warehouse_id=NEW.warehouse_id
          AND original.reference_id=NEW.reference_id
          AND original.reference_table='sales_headers'
          AND original.movement_type='SALE'::public.stock_movement_type
          AND original.movement_status='POSTED'
          AND original.qty_change=-NEW.qty_change))
  ) THEN RAISE EXCEPTION 'NEGATIVE_STOCK_AUTHORIZATION_REQUIRED'; END IF;
  RETURN NEW;
END
$$;

REVOKE ALL ON FUNCTION private.trg_g4_guard_negative_sale_movement()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g4_guard_negative_sale_movement()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES('20260917140000','negative_stock_inbound_recovery_fix',
  'Allows positive inbound Stock movements, including Goods Receipt, to reduce an existing negative balance without Sale authorization while preserving authorization for outbound negative Stock');

NOTIFY pgrst,'reload schema';
COMMIT;
