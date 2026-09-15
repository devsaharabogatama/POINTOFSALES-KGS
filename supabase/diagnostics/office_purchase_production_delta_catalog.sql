-- READ ONLY: one SELECT statement; no calls to application RPCs, no DDL/DML.
-- Run the WHOLE file in Production SQL Editor, export ALL rows as CSV.
-- Also usable on the existing rehearsal clone. INFO is inventory, NOT readiness.
-- Catalog keys use names/signatures, not environment-specific OIDs.
-- Routine bodies are hashed, never returned; no transaction contents returned.
WITH scope AS (
  SELECT c.oid,n.nspname,c.relname,c.relkind,c.relrowsecurity,c.relforcerowsecurity
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname IN ('public','private') AND c.relkind IN ('r','p','v','m')
), inventory AS (
  SELECT 'execution_contract'::text kind,'PRODUCTION_DELTA_V1'::text object_key,
    jsonb_build_object('writes',false,'database',current_database(),
      'databaseUser',current_user,'serverAddress',inet_server_addr(),
      'capturedAt',statement_timestamp(),'serverVersion',current_setting('server_version'),
      'interpretation','Compare with rehearsed migration inputs; changes are not automatically blockers') details
  UNION ALL
  SELECT 'relation',s.nspname||'.'||s.relname,
    jsonb_build_object('kind',s.relkind,'rls',s.relrowsecurity,
      'forceRls',s.relforcerowsecurity,
      'columns',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'name',a.attname,'type',format_type(a.atttypid,a.atttypmod),
        'notNull',a.attnotnull,'identity',a.attidentity,'generated',a.attgenerated,
        'default',pg_get_expr(d.adbin,d.adrelid)) ORDER BY a.attnum)
        FROM pg_attribute a LEFT JOIN pg_attrdef d
          ON d.adrelid=a.attrelid AND d.adnum=a.attnum
        WHERE a.attrelid=s.oid AND a.attnum>0 AND NOT a.attisdropped),'[]'::jsonb),
      'viewDigest',CASE WHEN s.relkind IN ('v','m')
        THEN md5(pg_get_viewdef(s.oid,false)) ELSE NULL END)
  FROM scope s
  UNION ALL
  SELECT 'constraint',s.nspname||'.'||s.relname||'.'||c.conname,
    jsonb_build_object('type',c.contype,'validated',c.convalidated,
      'deferrable',c.condeferrable,'initiallyDeferred',c.condeferred,
      'definition',pg_get_constraintdef(c.oid,false))
  FROM scope s JOIN pg_constraint c ON c.conrelid=s.oid
  UNION ALL
  SELECT 'trigger',s.nspname||'.'||s.relname||'.'||t.tgname,
    jsonb_build_object('enabled',t.tgenabled,'definition',pg_get_triggerdef(t.oid,false))
  FROM scope s JOIN pg_trigger t ON t.tgrelid=s.oid WHERE NOT t.tgisinternal
  UNION ALL
  SELECT 'index',s.nspname||'.'||s.relname||'.'||index_class.relname,
    jsonb_build_object('valid',i.indisvalid,'ready',i.indisready,
      'definition',pg_get_indexdef(i.indexrelid))
  FROM scope s JOIN pg_index i ON i.indrelid=s.oid
  JOIN pg_class index_class ON index_class.oid=i.indexrelid
  UNION ALL
  SELECT 'policy',s.nspname||'.'||s.relname||'.'||p.polname,
    jsonb_build_object('command',p.polcmd,'permissive',p.polpermissive,
      'roles',(SELECT jsonb_agg(CASE WHEN role_oid=0 THEN 'PUBLIC'
        ELSE pg_get_userbyid(role_oid)::text END ORDER BY CASE WHEN role_oid=0
        THEN 'PUBLIC' ELSE pg_get_userbyid(role_oid)::text END)
        FROM unnest(p.polroles) role_list(role_oid)),
      'using',pg_get_expr(p.polqual,p.polrelid),
      'withCheck',pg_get_expr(p.polwithcheck,p.polrelid))
  FROM scope s JOIN pg_policy p ON p.polrelid=s.oid
  UNION ALL
  SELECT 'routine',n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')',
    jsonb_build_object('definitionDigest',md5(pg_get_functiondef(p.oid)),
      'language',l.lanname,'owner',pg_get_userbyid(p.proowner),
      'securityDefiner',p.prosecdef,'volatility',p.provolatile,
      'config',p.proconfig,'result',pg_get_function_result(p.oid),
      'executeGrants',COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'grantee',CASE WHEN acl.grantee=0 THEN 'PUBLIC' ELSE pg_get_userbyid(acl.grantee)::text END,
        'grantor',pg_get_userbyid(acl.grantor),'grantable',acl.is_grantable)
        ORDER BY CASE WHEN acl.grantee=0 THEN 'PUBLIC'
          ELSE pg_get_userbyid(acl.grantee)::text END,pg_get_userbyid(acl.grantor))
        FROM aclexplode(COALESCE(p.proacl,acldefault('f',p.proowner))) acl
        WHERE acl.privilege_type='EXECUTE'),'[]'::jsonb))
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  JOIN pg_language l ON l.oid=p.prolang
  WHERE n.nspname IN ('public','private') AND p.prokind IN ('f','p')
  UNION ALL
  SELECT 'enum',n.nspname||'.'||t.typname,
    jsonb_build_object('labels',jsonb_agg(e.enumlabel ORDER BY e.enumsortorder))
  FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
  JOIN pg_enum e ON e.enumtypid=t.oid
  WHERE n.nspname IN ('public','private') GROUP BY n.nspname,t.typname
  UNION ALL
  SELECT 'application_migration',migration.version,
    jsonb_build_object('installed',true,'entryDigest',md5(to_jsonb(migration)::text))
  FROM private.kgs_schema_migrations migration
  UNION ALL
  SELECT 'extension',e.extname,jsonb_build_object('version',e.extversion,'schema',n.nspname)
  FROM pg_extension e JOIN pg_namespace n ON n.oid=e.extnamespace
)
-- One row per kind avoids SQL Editor's default first-page row limit hiding objects.
SELECT kind,'INFO'::text status,count(*)::bigint object_rows,
  jsonb_agg(jsonb_build_object('key',object_key,'details',details) ORDER BY object_key) objects
FROM inventory GROUP BY kind ORDER BY kind;
