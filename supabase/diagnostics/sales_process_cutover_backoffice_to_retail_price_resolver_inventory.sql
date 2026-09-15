-- Read-only inventory for the active POS price resolver chain used by Step 4C.
WITH routines(signature) AS (VALUES
  ('private.resolve_pos_sale_price(uuid,uuid,uuid,uuid,numeric,timestamp with time zone)'::text),
  ('private.resolve_pos_sale_price_before_backoffice_commercial(uuid,uuid,uuid,uuid,numeric,timestamp with time zone)'),
  ('private.resolve_pos_sale_price_before_backoffice_header(uuid,uuid,uuid,uuid,numeric,timestamp with time zone)'),
  ('private.resolve_pos_sale_price_before_terminal_override(uuid,uuid,uuid,uuid,numeric,timestamp with time zone)'),
  ('private.resolve_pos_sale_price_online_core(uuid,uuid,uuid,uuid,numeric,timestamp with time zone)')
)
SELECT signature,to_regprocedure(signature) IS NOT NULL present,
  CASE WHEN to_regprocedure(signature) IS NULL THEN NULL
    ELSE pg_get_functiondef(to_regprocedure(signature)) END definition
FROM routines;
