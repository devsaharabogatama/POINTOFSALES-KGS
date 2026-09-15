-- Cutover Step 4A/6: SELECT-only postflight. Run as one complete statement.
WITH function_state AS (
  SELECT procedure.oid,namespace.nspname,procedure.proname,
    pg_get_functiondef(procedure.oid) definition,procedure.prosecdef,
    procedure.provolatile,procedure.proconfig
  FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
  WHERE procedure.oid IN(
    to_regprocedure('private.authorize_pos_negative_stock(uuid,uuid,uuid,uuid,jsonb,text)'),
    to_regprocedure('private.confirm_pos_sales_order_core(uuid,bigint,uuid,text)'),
    to_regprocedure('private.confirm_pos_sales_order_before_revision_core(uuid,bigint,uuid,text)'),
    to_regprocedure('public.confirm_pos_sales_order(uuid,bigint,uuid,text)'),
    to_regprocedure('private.dispatch_sales_delivery_stock_core_odr3c(uuid,bigint,uuid,jsonb,text)'))
), checks AS (
  SELECT 'migration_ledger'::text check_name,CASE WHEN count(*)=1 THEN 'PASS' ELSE 'FAIL' END status,
    abs(1-count(*))::bigint violation_rows,jsonb_build_object('ledgerRows',count(*)) details
  FROM private.kgs_schema_migrations WHERE version='20260910153000'
  UNION ALL
  SELECT 'warehouse_authority_column_contract',CASE WHEN count(*)=4 THEN 'PASS' ELSE 'FAIL' END,
    abs(4-count(*))::bigint,jsonb_build_object('expected',4,'present',count(*))
  FROM information_schema.columns WHERE table_schema='public' AND
    ((table_name='sales_stock_reservation_lines' AND column_name IN('negative_authority_source','negative_warehouse_version'))
      OR (table_name='pos_negative_stock_authorizations' AND column_name IN('authority_source','warehouse_version')))
  UNION ALL
  SELECT 'warehouse_authority_runtime_contract',CASE WHEN count(*)=5
      AND bool_and(prosecdef AND provolatile='v'
        AND proconfig @> ARRAY['search_path=public, pg_temp']) THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN count(*)=5 AND bool_and(prosecdef AND provolatile='v'
      AND proconfig @> ARRAY['search_path=public, pg_temp']) THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',count(*),'securityDefiner',bool_and(prosecdef))
  FROM function_state
  UNION ALL
  SELECT 'pos_confirmation_warehouse_only_contract',CASE WHEN definition~'negative_warehouse_version'
      AND definition~'backoffice_sales_reservation_lines'
      AND definition!~'pos_negative_stock_permissions'
      AND definition!~'company_negative_limit_base_qty'
      AND definition!~'NEGATIVE_STOCK_REASON_REQUIRED' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition~'negative_warehouse_version' AND definition~'backoffice_sales_reservation_lines'
      AND definition!~'pos_negative_stock_permissions' AND definition!~'company_negative_limit_base_qty'
      AND definition!~'NEGATIVE_STOCK_REASON_REQUIRED' THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',1)
  FROM function_state WHERE proname='confirm_pos_sales_order_core'
  UNION ALL
  SELECT 'pos_confirmation_composition_preserved',CASE
      WHEN definition~'private.confirm_pos_sales_order_core'
        AND definition~'ensure_confirmed_order_invoice_identity'
        AND definition~'ensure_confirmed_order_documents'
        AND definition~'refresh_sales_order_procurement_demand'
        AND definition~'capture_sales_order_payment_requests'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition~'private.confirm_pos_sales_order_core'
        AND definition~'ensure_confirmed_order_invoice_identity'
        AND definition~'ensure_confirmed_order_documents'
        AND definition~'refresh_sales_order_procurement_demand'
        AND definition~'capture_sales_order_payment_requests'
      THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',1,'preservedLayer','document/payment composition wrapper')
  FROM function_state WHERE proname='confirm_pos_sales_order_before_revision_core'
  UNION ALL
  SELECT 'pos_revision_wrapper_preserved',CASE
      WHEN definition~'private.confirm_pos_sales_order_before_revision_core'
        AND definition~'sales_order_revisions'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition~'private.confirm_pos_sales_order_before_revision_core'
        AND definition~'sales_order_revisions' THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',1,'preservedLayer','public Revision wrapper')
  FROM function_state
  WHERE nspname='public' AND proname='confirm_pos_sales_order'
  UNION ALL
  SELECT 'direct_pos_warehouse_only_contract',CASE WHEN definition~'warehouse.allow_negative_stock'
      AND definition~'''WAREHOUSE''' AND definition!~'company_features'
      AND definition!~'pos_negative_stock_permissions' THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition~'warehouse.allow_negative_stock' AND definition~'''WAREHOUSE'''
      AND definition!~'company_features' AND definition!~'pos_negative_stock_permissions' THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',1)
  FROM function_state WHERE proname='authorize_pos_negative_stock'
  UNION ALL
  SELECT 'dispatch_dual_history_contract',CASE WHEN definition~'LEGACY_USER_POLICY'
      AND definition~'negative_warehouse_version' AND definition~'authority_source,warehouse_version'
      THEN 'PASS' ELSE 'FAIL' END,
    CASE WHEN definition~'LEGACY_USER_POLICY' AND definition~'negative_warehouse_version'
      AND definition~'authority_source,warehouse_version' THEN 0 ELSE 1 END,
    jsonb_build_object('routineRows',1)
  FROM function_state WHERE proname='dispatch_sales_delivery_stock_core_odr3c'
  UNION ALL
  SELECT 'warehouse_authority_private_boundary',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('authenticatedExecutableRows',count(*))
  FROM information_schema.routine_privileges privilege
  WHERE privilege.routine_schema='private' AND privilege.grantee='authenticated'
    AND privilege.privilege_type='EXECUTE' AND privilege.routine_name IN(
      'authorize_pos_negative_stock','confirm_pos_sales_order_core',
      'confirm_pos_sales_order_before_revision_core',
      'dispatch_sales_delivery_stock_core_odr3c','trg_g4_guard_negative_sale_movement')
  UNION ALL
  SELECT 'legacy_reservation_history_preserved',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.sales_stock_reservation_lines WHERE shortage_base_qty>0
    AND (negative_authority_source<>'LEGACY_USER_POLICY'
      OR negative_policy_version IS NULL OR negative_permission_version IS NULL)
  UNION ALL
  SELECT 'legacy_authorization_history_preserved',CASE WHEN count(*)=0 THEN 'PASS' ELSE 'FAIL' END,
    count(*)::bigint,jsonb_build_object('invalidRows',count(*))
  FROM public.pos_negative_stock_authorizations WHERE authority_source='LEGACY_USER_POLICY'
    AND (permission_id IS NULL OR NULLIF(btrim(reason),'') IS NULL
      OR policy_version IS NULL OR permission_version IS NULL)
  UNION ALL
  SELECT 'warehouse_authority_runtime_inventory','INFO',0::bigint,jsonb_build_object(
    'legacyReservationRows',(SELECT count(*) FROM public.sales_stock_reservation_lines WHERE negative_authority_source='LEGACY_USER_POLICY'),
    'warehouseReservationRows',(SELECT count(*) FROM public.sales_stock_reservation_lines WHERE negative_authority_source='WAREHOUSE'),
    'legacyAuthorizationRows',(SELECT count(*) FROM public.pos_negative_stock_authorizations WHERE authority_source='LEGACY_USER_POLICY'),
    'warehouseAuthorizationRows',(SELECT count(*) FROM public.pos_negative_stock_authorizations WHERE authority_source='WAREHOUSE'))
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'FAIL' THEN 0 WHEN 'PASS' THEN 1 ELSE 2 END,check_name;
