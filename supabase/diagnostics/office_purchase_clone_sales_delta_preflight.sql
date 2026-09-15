-- READ ONLY. Run the entire file once on Production and once on its rehearsal
-- clone. This script performs no DDL, DML, RPC call, temporary-table write, or
-- transaction-state change.
--
-- Purpose: prove whether the 1 sales_headers / 2 sales_details difference is a
-- post-restore transaction or a wider snapshot mismatch before any rehearsal
-- migration is applied.
WITH header_snapshot AS (
  SELECT
    count(*)::bigint AS row_count,
    md5(COALESCE(string_agg(
      concat_ws('|',
        header.id::text,
        header.invoice_no,
        header.session_id::text,
        COALESCE(header.customer_id::text,'<NULL>'),
        header.transaction_date::text,
        header.is_tempo::text,
        COALESCE(header.due_date::text,'<NULL>'),
        header.sj_required::text,
        COALESCE(header.sj_no,'<NULL>'),
        header.sj_status::text,
        header.so_confirm_status::text,
        header.invoice_status::text,
        header.subtotal::text,
        header.item_discount::text,
        header.global_discount::text,
        header.grand_total::text,
        header.paid_amount::text,
        header.sisa_piutang::text,
        header.payment_status::text,
        header.financial_status::text,
        header.recon_status::text,
        header.created_by::text,
        header.is_revision::text,
        COALESCE(header.original_invoice_no,'<NULL>'),
        header.created_at::text
      ), E'\n' ORDER BY header.id
    ),'')) AS identity_value_digest,
    max(header.created_at) AS latest_created_at,
    max(header.transaction_date) AS latest_transaction_date
  FROM public.sales_headers header
), detail_snapshot AS (
  SELECT
    count(*)::bigint AS row_count,
    md5(COALESCE(string_agg(
      concat_ws('|',
        detail.id::text,
        detail.sales_id::text,
        detail.product_id::text,
        detail.warehouse_id::text,
        detail.qty::text,
        detail.price::text,
        detail.discount_amount::text,
        detail.subtotal::text,
        detail.cogs_unit::text,
        detail.cogs_total::text
      ), E'\n' ORDER BY detail.id
    ),'')) AS identity_value_digest,
    COALESCE(sum(detail.qty),0) AS quantity_total,
    COALESCE(sum(detail.subtotal),0) AS subtotal_total
  FROM public.sales_details detail
), common_header_ids AS (
  -- 266 is the observed rehearsal-clone header count. Selecting the oldest
  -- stable set proves or rejects the specific hypothesis that Production only
  -- gained one later transaction after the restore point.
  SELECT ranked.id
  FROM (
    SELECT header.id,
      row_number() OVER(ORDER BY header.created_at,header.id) AS sequence_no
    FROM public.sales_headers header
  ) ranked
  WHERE ranked.sequence_no<=266
), common_header_candidate AS (
  SELECT count(*)::bigint AS row_count,
    md5(COALESCE(string_agg(
      concat_ws('|',
        header.id::text,
        header.invoice_no,
        header.session_id::text,
        COALESCE(header.customer_id::text,'<NULL>'),
        header.transaction_date::text,
        header.is_tempo::text,
        COALESCE(header.due_date::text,'<NULL>'),
        header.sj_required::text,
        COALESCE(header.sj_no,'<NULL>'),
        header.sj_status::text,
        header.so_confirm_status::text,
        header.invoice_status::text,
        header.subtotal::text,
        header.item_discount::text,
        header.global_discount::text,
        header.grand_total::text,
        header.paid_amount::text,
        header.sisa_piutang::text,
        header.payment_status::text,
        header.financial_status::text,
        header.recon_status::text,
        header.created_by::text,
        header.is_revision::text,
        COALESCE(header.original_invoice_no,'<NULL>'),
        header.created_at::text
      ), E'\n' ORDER BY header.id
    ),'')) AS identity_value_digest
  FROM public.sales_headers header
  JOIN common_header_ids candidate ON candidate.id=header.id
), common_detail_candidate AS (
  SELECT count(*)::bigint AS row_count,
    md5(COALESCE(string_agg(
      concat_ws('|',
        detail.id::text,
        detail.sales_id::text,
        detail.product_id::text,
        detail.warehouse_id::text,
        detail.qty::text,
        detail.price::text,
        detail.discount_amount::text,
        detail.subtotal::text,
        detail.cogs_unit::text,
        detail.cogs_total::text
      ), E'\n' ORDER BY detail.id
    ),'')) AS identity_value_digest
  FROM public.sales_details detail
  JOIN common_header_ids candidate ON candidate.id=detail.sales_id
), recent_sales AS (
  SELECT
    header.id,
    header.invoice_no,
    header.transaction_date,
    header.created_at,
    header.customer_id,
    header.grand_total,
    count(detail.id)::bigint AS detail_rows,
    COALESCE(sum(detail.qty),0) AS quantity_total,
    COALESCE(sum(detail.subtotal),0) AS detail_subtotal_total
  FROM public.sales_headers header
  LEFT JOIN public.sales_details detail ON detail.sales_id=header.id
  GROUP BY header.id,header.invoice_no,header.transaction_date,header.created_at,
    header.customer_id,header.grand_total
  ORDER BY header.created_at DESC,header.id DESC
  LIMIT 20
), checks AS (
  SELECT 'sales_header_identity_snapshot'::text AS check_name,
    'INFO'::text AS status,0::bigint AS violation_rows,
    jsonb_build_object(
      'rows',snapshot.row_count,
      'identityValueDigest',snapshot.identity_value_digest,
      'latestCreatedAt',snapshot.latest_created_at,
      'latestTransactionDate',snapshot.latest_transaction_date
    ) AS details
  FROM header_snapshot snapshot

  UNION ALL

  SELECT 'sales_detail_identity_snapshot','INFO',0,
    jsonb_build_object(
      'rows',snapshot.row_count,
      'identityValueDigest',snapshot.identity_value_digest,
      'quantityTotal',snapshot.quantity_total,
      'subtotalTotal',snapshot.subtotal_total
    )
  FROM detail_snapshot snapshot

  UNION ALL

  SELECT 'common_266_header_candidate','INFO',0,
    jsonb_build_object(
      'rows',snapshot.row_count,
      'identityValueDigest',snapshot.identity_value_digest,
      'comparisonRule','Must match between Production and clone if only one later Production transaction is absent from clone'
    )
  FROM common_header_candidate snapshot

  UNION ALL

  SELECT 'common_266_header_detail_candidate','INFO',0,
    jsonb_build_object(
      'rows',snapshot.row_count,
      'identityValueDigest',snapshot.identity_value_digest,
      'expectedCloneRows',657,
      'comparisonRule','Must match between Production and clone if only the later Production transaction lines are absent from clone'
    )
  FROM common_detail_candidate snapshot

  UNION ALL

  SELECT 'recent_sales_identity_inventory','INFO',0,
    jsonb_build_object(
      'rows',count(*),
      'documents',COALESCE(jsonb_agg(to_jsonb(recent_sales)
        ORDER BY recent_sales.created_at DESC,recent_sales.id DESC),'[]'::jsonb)
    )
  FROM recent_sales

  UNION ALL

  SELECT 'execution_contract','PASS',0,
    jsonb_build_object(
      'writes',false,
      'runOn',jsonb_build_array('PRODUCTION','REHEARSAL_CLONE'),
      'comparisonRule','Both complete outputs must be retained and compared before migration'
    )
)
SELECT check_name,status,violation_rows,details
FROM checks
ORDER BY CASE check_name
  WHEN 'execution_contract' THEN 1
  WHEN 'sales_header_identity_snapshot' THEN 2
  WHEN 'sales_detail_identity_snapshot' THEN 3
  WHEN 'common_266_header_candidate' THEN 4
  WHEN 'common_266_header_detail_candidate' THEN 5
  WHEN 'recent_sales_identity_inventory' THEN 6
  ELSE 7
END;
