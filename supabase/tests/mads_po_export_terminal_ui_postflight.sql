WITH checks AS (
  SELECT 'migration_ledger' check_name,
    EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260820100000') pass,
    jsonb_build_object('ledgerRows',(SELECT count(*) FROM private.kgs_schema_migrations WHERE version='20260820100000')) details
  UNION ALL SELECT 'supplier_order_export_capability',
    EXISTS(SELECT 1 FROM public.access_permission_catalog WHERE permission_key='purchase.supplier_orders' AND 'EXPORT'=ANY(supported_capabilities)),
    jsonb_build_object('capabilities',(SELECT supported_capabilities FROM public.access_permission_catalog WHERE permission_key='purchase.supplier_orders'))
  UNION ALL SELECT 'required_runtime_routines',
    (SELECT count(*)=3 FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
      WHERE namespace.nspname='public' AND procedure.proname IN('export_purchase_supplier_orders','get_pos_terminal_ui_settings','save_pos_terminal_ui_settings')),
    jsonb_build_object('routineRows',(SELECT count(*) FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
      WHERE namespace.nspname='public' AND procedure.proname IN('export_purchase_supplier_orders','get_pos_terminal_ui_settings','save_pos_terminal_ui_settings')))
  UNION ALL SELECT 'terminal_ui_column_state',
    (SELECT count(*)=4 FROM information_schema.columns WHERE table_schema='public' AND table_name='pos_terminals'
      AND column_name IN('hidden_feature_keys','ui_settings_master_version','ui_settings_updated_at','ui_settings_updated_by')),
    jsonb_build_object('columnRows',(SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='pos_terminals'
      AND column_name IN('hidden_feature_keys','ui_settings_master_version','ui_settings_updated_at','ui_settings_updated_by')))
  UNION ALL SELECT 'legacy_terminal_default_visibility',
    NOT EXISTS(SELECT 1 FROM public.pos_terminals WHERE cardinality(hidden_feature_keys)>0 AND ui_settings_updated_at IS NULL),
    jsonb_build_object('unexpectedRows',(SELECT count(*) FROM public.pos_terminals WHERE cardinality(hidden_feature_keys)>0 AND ui_settings_updated_at IS NULL))
  UNION ALL SELECT 'browser_terminal_ui_direct_write_boundary',
    NOT has_column_privilege('authenticated','public.pos_terminals','hidden_feature_keys','UPDATE'),
    jsonb_build_object('columnUpdate',has_column_privilege('authenticated','public.pos_terminals','hidden_feature_keys','UPDATE'))
  UNION ALL SELECT 'terminal_ui_audit_immutable',
    EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.pos_terminal_ui_setting_audit'::regclass
      AND tgname='trg_mads_terminal_ui_audit_immutable' AND tgenabled<>'D'),
    jsonb_build_object('triggerRows',(SELECT count(*) FROM pg_trigger WHERE tgrelid='public.pos_terminal_ui_setting_audit'::regclass
      AND tgname='trg_mads_terminal_ui_audit_immutable' AND tgenabled<>'D'))
)
SELECT check_name,CASE WHEN pass THEN 'PASS' ELSE 'FAIL' END status,
  CASE WHEN pass THEN 0 ELSE 1 END violation_rows,details FROM checks ORDER BY check_name;
