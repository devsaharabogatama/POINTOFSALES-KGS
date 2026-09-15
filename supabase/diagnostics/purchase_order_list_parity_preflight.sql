-- SELECT-only preflight for Purchase RO/PO list parity read model.
WITH checks AS (
  SELECT 'purchase_order_list_dependency_ledger' AS check_name,
    CASE WHEN count(*)=4 THEN 'PASS' ELSE 'BLOCKER' END AS status,
    abs(4-count(*))::bigint AS violation_rows,
    jsonb_build_object('present',count(*),'expected',4) AS details
  FROM private.kgs_schema_migrations
  WHERE version IN('20260806100000','20260807150000','20260831110000','20260914150000')
  UNION ALL
  SELECT 'purchase_order_list_relation_contract',
    CASE WHEN count(*)=8 THEN 'PASS' ELSE 'BLOCKER' END,
    abs(8-count(*))::bigint,
    jsonb_build_object('present',count(*),'expected',8)
  FROM (VALUES
    ('supplier_order_documents'),('supplier_order_lines'),
    ('goods_receipt_documents'),('goods_receipt_lines'),
    ('purchase_return_documents'),('purchase_return_lines'),
    ('supplier_invoice_documents'),('supplier_invoice_allocations')
  ) expected(name)
  WHERE to_regclass('public.'||expected.name) IS NOT NULL
  UNION ALL
  SELECT 'purchase_order_list_base_routine',
    CASE WHEN to_regprocedure('public.get_purchase_supplier_orders()') IS NOT NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    CASE WHEN to_regprocedure('public.get_purchase_supplier_orders()') IS NULL THEN 1 ELSE 0 END,
    jsonb_build_object('publicReaderPresent',
      to_regprocedure('public.get_purchase_supplier_orders()') IS NOT NULL)
  UNION ALL
  SELECT 'purchase_order_list_routine_collision',
    CASE WHEN to_regprocedure('private.purchase_order_list_v1_base()') IS NULL
    AND to_regprocedure('private.classify_purchase_order_bill_status(numeric,numeric,integer,integer,boolean)') IS NULL
      THEN 'PASS' ELSE 'BLOCKER' END,
    (CASE WHEN to_regprocedure('private.purchase_order_list_v1_base()') IS NOT NULL THEN 1 ELSE 0 END
      +CASE WHEN to_regprocedure('private.classify_purchase_order_bill_status(numeric,numeric,integer,integer,boolean)') IS NOT NULL THEN 1 ELSE 0 END)::bigint,
    jsonb_build_object(
      'baseCollision',to_regprocedure('private.purchase_order_list_v1_base()') IS NOT NULL,
      'classifierCollision',to_regprocedure('private.classify_purchase_order_bill_status(numeric,numeric,integer,integer,boolean)') IS NOT NULL)
)
SELECT check_name,status,violation_rows,details FROM checks
ORDER BY CASE status WHEN 'BLOCKER' THEN 0 WHEN 'FAIL' THEN 1 ELSE 2 END,check_name;
