-- G6 corrective phase 6A: POSTED-only Trial Balance and General Ledger.
-- P&L, Balance Sheet, pending analysis, reconciliation mutation, and UI remain closed.

BEGIN;

DO $guard$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260810210000') THEN
  RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: G6 phase 5 required';
 END IF;
 IF EXISTS(SELECT 1 FROM private.kgs_schema_migrations WHERE version='20260810220000') THEN
  RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260810220000';
 END IF;
 IF to_regclass('public.finance_report_definitions') IS NOT NULL
 OR to_regclass('public.finance_report_versions') IS NOT NULL
 OR to_regclass('public.finance_report_lines') IS NOT NULL
 OR to_regclass('public.finance_report_exports') IS NOT NULL
 OR to_regprocedure('public.get_finance_trial_balance(date,date,uuid,uuid)') IS NOT NULL
 OR to_regprocedure('public.get_finance_general_ledger(uuid,date,date,uuid,uuid,integer,integer)') IS NOT NULL THEN
  RAISE EXCEPTION 'MIGRATION_PRECONDITION_FAILED: Phase 6A target exists';
 END IF;
END
$guard$;

CREATE TABLE public.finance_report_definitions(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 company_id UUID NOT NULL REFERENCES public.companies(id) ON DELETE RESTRICT,
 report_code TEXT NOT NULL,
 report_name TEXT NOT NULL,
 is_active BOOLEAN NOT NULL DEFAULT TRUE,
 master_version BIGINT NOT NULL DEFAULT 1,
 created_by UUID NOT NULL REFERENCES public.profiles(id),
 updated_by UUID NOT NULL REFERENCES public.profiles(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
 updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
 CONSTRAINT finance_report_definitions_company_id_id_unique UNIQUE(company_id,id),
 CONSTRAINT finance_report_definitions_company_code_unique UNIQUE(company_id,report_code),
 CONSTRAINT finance_report_definitions_code_check CHECK(report_code IN(
  'TRIAL_BALANCE','GENERAL_LEDGER','INCOME_STATEMENT','BALANCE_SHEET',
  'PENDING_ANALYSIS','RECONCILIATION_SUMMARY'
 )),
 CONSTRAINT finance_report_definitions_name_not_blank CHECK(btrim(report_name)<>''),
 CONSTRAINT finance_report_definitions_version_positive CHECK(master_version>0)
);

CREATE TABLE public.finance_report_versions(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 company_id UUID NOT NULL,
 report_definition_id UUID NOT NULL,
 version_no BIGINT NOT NULL,
 status TEXT NOT NULL DEFAULT 'DRAFT',
 formula_key TEXT NOT NULL,
 effective_from DATE NOT NULL,
 effective_to DATE,
 created_by UUID NOT NULL REFERENCES public.profiles(id),
 approved_by UUID REFERENCES public.profiles(id),
 created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
 approved_at TIMESTAMPTZ,
 CONSTRAINT finance_report_versions_company_id_id_unique UNIQUE(company_id,id),
 CONSTRAINT finance_report_versions_number_unique UNIQUE(company_id,report_definition_id,version_no),
 CONSTRAINT finance_report_versions_version_positive CHECK(version_no>0),
 CONSTRAINT finance_report_versions_status_check CHECK(status IN('DRAFT','ACTIVE','RETIRED')),
 CONSTRAINT finance_report_versions_formula_not_blank CHECK(btrim(formula_key)<>''),
 CONSTRAINT finance_report_versions_effective_check CHECK(effective_to IS NULL OR effective_to>effective_from),
 CONSTRAINT finance_report_versions_approval_check CHECK(
  status<>'ACTIVE' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)
 ),
 CONSTRAINT fk_finance_report_version_definition FOREIGN KEY(company_id,report_definition_id)
  REFERENCES public.finance_report_definitions(company_id,id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX uq_finance_report_versions_current
 ON public.finance_report_versions(company_id,report_definition_id)
 WHERE status='ACTIVE' AND effective_to IS NULL;

CREATE TABLE public.finance_report_lines(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 company_id UUID NOT NULL,
 report_version_id UUID NOT NULL,
 line_no INTEGER NOT NULL,
 line_key TEXT NOT NULL,
 line_label TEXT NOT NULL,
 parent_line_key TEXT,
 account_types TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
 balance_multiplier SMALLINT NOT NULL DEFAULT 1,
 created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
 CONSTRAINT finance_report_lines_company_id_id_unique UNIQUE(company_id,id),
 CONSTRAINT finance_report_lines_number_unique UNIQUE(company_id,report_version_id,line_no),
 CONSTRAINT finance_report_lines_key_unique UNIQUE(company_id,report_version_id,line_key),
 CONSTRAINT finance_report_lines_line_positive CHECK(line_no>0),
 CONSTRAINT finance_report_lines_identity_check CHECK(btrim(line_key)<>'' AND btrim(line_label)<>''),
 CONSTRAINT finance_report_lines_multiplier_check CHECK(balance_multiplier IN(-1,1)),
 CONSTRAINT finance_report_lines_account_type_check CHECK(
  account_types<@ARRAY['ASSET','LIABILITY','EQUITY','REVENUE','COGS','EXPENSE','OTHER_INCOME','OTHER_EXPENSE']::TEXT[]
 ),
 CONSTRAINT fk_finance_report_line_version FOREIGN KEY(company_id,report_version_id)
  REFERENCES public.finance_report_versions(company_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.finance_report_exports(
 id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
 company_id UUID NOT NULL,
 report_definition_id UUID NOT NULL,
 report_version_id UUID NOT NULL,
 requested_by UUID NOT NULL REFERENCES public.profiles(id),
 report_timezone TEXT NOT NULL,
 as_of_date DATE NOT NULL,
 filter_snapshot JSONB NOT NULL DEFAULT '{}'::JSONB,
 status TEXT NOT NULL DEFAULT 'REQUESTED',
 row_count BIGINT,
 external_url TEXT,
 error_message TEXT,
 requested_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
 completed_at TIMESTAMPTZ,
 CONSTRAINT finance_report_exports_company_id_id_unique UNIQUE(company_id,id),
 CONSTRAINT finance_report_exports_status_check CHECK(status IN('REQUESTED','COMPLETED','FAILED')),
 CONSTRAINT finance_report_exports_filter_object CHECK(jsonb_typeof(filter_snapshot)='object'),
 CONSTRAINT finance_report_exports_row_nonnegative CHECK(row_count IS NULL OR row_count>=0),
 CONSTRAINT finance_report_exports_url_check CHECK(external_url IS NULL OR external_url~*'^https://'),
 CONSTRAINT finance_report_exports_lifecycle_check CHECK(
  (status='REQUESTED' AND completed_at IS NULL AND external_url IS NULL AND error_message IS NULL)
  OR (status='COMPLETED' AND completed_at IS NOT NULL AND row_count IS NOT NULL AND error_message IS NULL)
  OR (status='FAILED' AND completed_at IS NOT NULL AND btrim(COALESCE(error_message,''))<>'')
 ),
 CONSTRAINT fk_finance_report_export_definition FOREIGN KEY(company_id,report_definition_id)
  REFERENCES public.finance_report_definitions(company_id,id) ON DELETE RESTRICT,
 CONSTRAINT fk_finance_report_export_version FOREIGN KEY(company_id,report_version_id)
  REFERENCES public.finance_report_versions(company_id,id) ON DELETE RESTRICT
);

CREATE TABLE public.finance_report_audit(
 id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 company_id UUID NOT NULL,
 report_definition_id UUID NOT NULL,
 action TEXT NOT NULL CHECK(action IN('PROVISION','ACTIVATE','RETIRE')),
 actor_id UUID NOT NULL REFERENCES public.profiles(id),
 before_state JSONB,
 after_state JSONB NOT NULL,
 created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
 CONSTRAINT fk_finance_report_audit_definition FOREIGN KEY(company_id,report_definition_id)
  REFERENCES public.finance_report_definitions(company_id,id) ON DELETE RESTRICT
);

CREATE FUNCTION private.g6_report_role_allowed(p_company UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT public.private_request_company_matches(p_company)
 AND public.private_user_has_any_company_or_store_role(
  p_company,ARRAY['COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING']::TEXT[]
 )
$$;

CREATE FUNCTION private.provision_g6_posted_reports(p_company UUID,p_actor UUID DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_actor UUID:=p_actor; v_code TEXT; v_name TEXT; v_formula TEXT; v_definition UUID;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.companies WHERE id=p_company AND status='ACTIVE') THEN RETURN; END IF;
 IF v_actor IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=v_actor) THEN
  SELECT profile.id INTO v_actor FROM public.profiles profile JOIN auth.users auth_user ON auth_user.id=profile.id
  WHERE profile.role::TEXT='super_admin' ORDER BY profile.id LIMIT 1;
 END IF;
 IF v_actor IS NULL THEN RAISE EXCEPTION 'LINKED_SUPER_ADMIN_REQUIRED'; END IF;
 FOR v_code,v_name,v_formula IN SELECT * FROM(VALUES
  ('TRIAL_BALANCE','Trial Balance','POSTED_ACCOUNT_BALANCE_V1'),
  ('GENERAL_LEDGER','General Ledger','POSTED_ACCOUNT_LEDGER_V1')
 ) AS seed(code,name,formula)
 LOOP
  INSERT INTO public.finance_report_definitions(company_id,report_code,report_name,created_by,updated_by)
  VALUES(p_company,v_code,v_name,v_actor,v_actor)
  ON CONFLICT(company_id,report_code) DO UPDATE SET is_active=TRUE,updated_by=v_actor,updated_at=clock_timestamp()
  RETURNING id INTO v_definition;
  IF NOT EXISTS(SELECT 1 FROM public.finance_report_versions version WHERE version.company_id=p_company
   AND version.report_definition_id=v_definition AND version.status='ACTIVE' AND version.effective_to IS NULL) THEN
   INSERT INTO public.finance_report_versions(company_id,report_definition_id,version_no,status,formula_key,effective_from,created_by,approved_by,approved_at)
   VALUES(p_company,v_definition,1,'ACTIVE',v_formula,DATE '2000-01-01',v_actor,v_actor,clock_timestamp());
   INSERT INTO public.finance_report_audit(company_id,report_definition_id,action,actor_id,after_state)
   VALUES(p_company,v_definition,'PROVISION',v_actor,jsonb_build_object('reportCode',v_code,'version',1,'formulaKey',v_formula));
  END IF;
 END LOOP;
END;
$$;

CREATE FUNCTION private.trg_g6_provision_posted_reports() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF NEW.status='ACTIVE' AND (TG_OP='INSERT' OR OLD.status IS DISTINCT FROM NEW.status) THEN
  PERFORM private.provision_g6_posted_reports(NEW.id,auth.uid());
 END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER g6_provision_posted_reports
AFTER INSERT OR UPDATE OF status ON public.companies
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_provision_posted_reports();

CREATE FUNCTION private.trg_g6_guard_report_history() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'FINANCE_REPORT_HISTORY_IMMUTABLE'; END IF;
 IF TG_TABLE_NAME IN('finance_report_versions','finance_report_lines','finance_report_audit') THEN
  RAISE EXCEPTION 'FINANCE_REPORT_HISTORY_IMMUTABLE';
 END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER g6_guard_report_version_history BEFORE UPDATE OR DELETE ON public.finance_report_versions
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_guard_report_history();
CREATE TRIGGER g6_guard_report_line_history BEFORE UPDATE OR DELETE ON public.finance_report_lines
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_guard_report_history();
CREATE TRIGGER g6_guard_report_audit_history BEFORE UPDATE OR DELETE ON public.finance_report_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_guard_report_history();

DO $provision$
DECLARE v_company UUID; v_actor UUID;
BEGIN
 SELECT profile.id INTO v_actor FROM public.profiles profile JOIN auth.users auth_user ON auth_user.id=profile.id
 WHERE profile.role::TEXT='super_admin' ORDER BY profile.id LIMIT 1;
 IF v_actor IS NULL THEN RAISE EXCEPTION 'LINKED_SUPER_ADMIN_REQUIRED'; END IF;
 FOR v_company IN SELECT id FROM public.companies WHERE status='ACTIVE' ORDER BY id LOOP
  PERFORM private.provision_g6_posted_reports(v_company,v_actor);
 END LOOP;
END
$provision$;

CREATE FUNCTION public.get_finance_trial_balance(
 p_date_from DATE,p_as_of DATE,p_store_id UUID DEFAULT NULL,p_warehouse_id UUID DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id(); v_timezone TEXT; v_version BIGINT;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
 IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
 IF NOT private.g6_report_role_allowed(v_company) THEN RAISE EXCEPTION 'FINANCE_REPORT_ROLE_REQUIRED'; END IF;
 IF p_date_from IS NULL OR p_as_of IS NULL OR p_date_from>p_as_of THEN RAISE EXCEPTION 'REPORT_DATE_RANGE_INVALID'; END IF;
 IF p_store_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.stores WHERE company_id=v_company AND id=p_store_id) THEN RAISE EXCEPTION 'REPORT_STORE_NOT_FOUND'; END IF;
 IF p_warehouse_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.warehouses WHERE company_id=v_company AND id=p_warehouse_id) THEN RAISE EXCEPTION 'REPORT_WAREHOUSE_NOT_FOUND'; END IF;
 SELECT company.timezone INTO v_timezone FROM public.companies company WHERE company.id=v_company AND company.status='ACTIVE';
 IF v_timezone IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_NOT_FOUND'; END IF;
 SELECT version.version_no INTO v_version FROM public.finance_report_definitions definition
 JOIN public.finance_report_versions version ON version.company_id=definition.company_id AND version.report_definition_id=definition.id
 WHERE definition.company_id=v_company AND definition.report_code='TRIAL_BALANCE' AND definition.is_active
 AND version.status='ACTIVE' AND version.effective_from<=p_as_of AND (version.effective_to IS NULL OR version.effective_to>p_as_of);
 IF v_version IS NULL THEN RAISE EXCEPTION 'ACTIVE_REPORT_VERSION_NOT_FOUND'; END IF;
 RETURN (WITH balance AS(
  SELECT account.id,account.account_code,account.account_name,account.account_type,account.normal_balance,
   COALESCE(sum(line.debit-line.credit) FILTER(WHERE journal.accounting_date<p_date_from),0) opening_raw,
   COALESCE(sum(line.debit) FILTER(WHERE journal.accounting_date BETWEEN p_date_from AND p_as_of),0) period_debit,
   COALESCE(sum(line.credit) FILTER(WHERE journal.accounting_date BETWEEN p_date_from AND p_as_of),0) period_credit
  FROM public.chart_of_accounts account LEFT JOIN public.finance_journal_lines line ON line.company_id=account.company_id AND line.account_id=account.id
  LEFT JOIN public.finance_journals journal ON journal.company_id=line.company_id AND journal.id=line.journal_id AND journal.status='POSTED'
   AND journal.accounting_date<=p_as_of AND (p_store_id IS NULL OR line.store_id=p_store_id) AND (p_warehouse_id IS NULL OR line.warehouse_id=p_warehouse_id)
  WHERE account.company_id=v_company GROUP BY account.id,account.account_code,account.account_name,account.account_type,account.normal_balance
 ), rows AS(SELECT *,opening_raw+period_debit-period_credit closing_raw FROM balance)
 SELECT jsonb_build_object('companyId',v_company,'timezone',v_timezone,'dateFrom',p_date_from,'asOf',p_as_of,'reportVersion',v_version,
  'periodDebit',COALESCE(sum(period_debit),0),'periodCredit',COALESCE(sum(period_credit),0),
  'balanced',COALESCE(sum(period_debit),0)=COALESCE(sum(period_credit),0),'rows',COALESCE(jsonb_agg(jsonb_build_object(
   'accountId',id,'accountCode',account_code,'accountName',account_name,'accountType',account_type,'normalBalance',normal_balance,
   'openingBalance',CASE WHEN normal_balance='CREDIT' THEN -opening_raw ELSE opening_raw END,'periodDebit',period_debit,
   'periodCredit',period_credit,'closingBalance',CASE WHEN normal_balance='CREDIT' THEN -closing_raw ELSE closing_raw END
  ) ORDER BY account_code),'[]'::JSONB)) FROM rows);
END;
$$;

CREATE FUNCTION public.get_finance_general_ledger(
 p_account_id UUID,p_date_from DATE,p_as_of DATE,p_store_id UUID DEFAULT NULL,p_warehouse_id UUID DEFAULT NULL,
 p_limit INTEGER DEFAULT 100,p_offset INTEGER DEFAULT 0
) RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_company UUID:=public.private_active_company_id(); v_timezone TEXT; v_account public.chart_of_accounts%ROWTYPE; v_open NUMERIC:=0; v_total BIGINT; v_version BIGINT;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
 IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
 IF NOT private.g6_report_role_allowed(v_company) THEN RAISE EXCEPTION 'FINANCE_REPORT_ROLE_REQUIRED'; END IF;
 IF p_date_from IS NULL OR p_as_of IS NULL OR p_date_from>p_as_of THEN RAISE EXCEPTION 'REPORT_DATE_RANGE_INVALID'; END IF;
 IF p_limit IS NULL OR p_limit<1 OR p_limit>500 OR p_offset IS NULL OR p_offset<0 THEN RAISE EXCEPTION 'REPORT_PAGINATION_INVALID'; END IF;
 SELECT * INTO v_account FROM public.chart_of_accounts WHERE company_id=v_company AND id=p_account_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'REPORT_ACCOUNT_NOT_FOUND'; END IF;
 IF p_store_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.stores WHERE company_id=v_company AND id=p_store_id) THEN RAISE EXCEPTION 'REPORT_STORE_NOT_FOUND'; END IF;
 IF p_warehouse_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.warehouses WHERE company_id=v_company AND id=p_warehouse_id) THEN RAISE EXCEPTION 'REPORT_WAREHOUSE_NOT_FOUND'; END IF;
 SELECT timezone INTO v_timezone FROM public.companies WHERE id=v_company AND status='ACTIVE';
 SELECT version.version_no INTO v_version FROM public.finance_report_definitions definition
 JOIN public.finance_report_versions version ON version.company_id=definition.company_id AND version.report_definition_id=definition.id
 WHERE definition.company_id=v_company AND definition.report_code='GENERAL_LEDGER' AND definition.is_active
 AND version.status='ACTIVE' AND version.effective_from<=p_as_of AND (version.effective_to IS NULL OR version.effective_to>p_as_of);
 IF v_version IS NULL THEN RAISE EXCEPTION 'ACTIVE_REPORT_VERSION_NOT_FOUND'; END IF;
 SELECT COALESCE(sum(line.debit-line.credit),0) INTO v_open FROM public.finance_journal_lines line JOIN public.finance_journals journal
 ON journal.company_id=line.company_id AND journal.id=line.journal_id AND journal.status='POSTED'
 WHERE line.company_id=v_company AND line.account_id=p_account_id AND journal.accounting_date<p_date_from
 AND (p_store_id IS NULL OR line.store_id=p_store_id) AND (p_warehouse_id IS NULL OR line.warehouse_id=p_warehouse_id);
 SELECT count(*) INTO v_total FROM public.finance_journal_lines line JOIN public.finance_journals journal
 ON journal.company_id=line.company_id AND journal.id=line.journal_id AND journal.status='POSTED'
 WHERE line.company_id=v_company AND line.account_id=p_account_id AND journal.accounting_date BETWEEN p_date_from AND p_as_of
 AND (p_store_id IS NULL OR line.store_id=p_store_id) AND (p_warehouse_id IS NULL OR line.warehouse_id=p_warehouse_id);
 RETURN (WITH base AS(
  SELECT journal.accounting_date,journal.journal_no,journal.journal_type,journal.source_type,journal.source_id,
   journal.original_event_date,journal.posted_at,line.id line_id,line.debit,line.credit,line.store_id,line.warehouse_id,
   v_open+sum(line.debit-line.credit) OVER(ORDER BY journal.accounting_date,journal.id,line.line_no) running_raw
  FROM public.finance_journal_lines line JOIN public.finance_journals journal ON journal.company_id=line.company_id AND journal.id=line.journal_id
  WHERE line.company_id=v_company AND line.account_id=p_account_id AND journal.status='POSTED'
  AND journal.accounting_date BETWEEN p_date_from AND p_as_of AND (p_store_id IS NULL OR line.store_id=p_store_id)
  AND (p_warehouse_id IS NULL OR line.warehouse_id=p_warehouse_id)
 ), page AS(SELECT * FROM base ORDER BY accounting_date,line_id LIMIT p_limit OFFSET p_offset)
 SELECT jsonb_build_object('companyId',v_company,'timezone',v_timezone,'dateFrom',p_date_from,'asOf',p_as_of,'accountId',v_account.id,
  'accountCode',v_account.account_code,'accountName',v_account.account_name,'normalBalance',v_account.normal_balance,
  'reportVersion',v_version,'openingBalance',CASE WHEN v_account.normal_balance='CREDIT' THEN -v_open ELSE v_open END,'totalRows',v_total,
  'limit',p_limit,'offset',p_offset,'rows',COALESCE(jsonb_agg(jsonb_build_object('accountingDate',accounting_date,'journalNo',journal_no,
  'journalType',journal_type,'sourceType',source_type,'sourceId',source_id,'originalEventDate',original_event_date,'postedAt',posted_at,
  'lineId',line_id,'debit',debit,'credit',credit,'storeId',store_id,'warehouseId',warehouse_id,
  'runningBalance',CASE WHEN v_account.normal_balance='CREDIT' THEN -running_raw ELSE running_raw END) ORDER BY accounting_date,line_id),'[]'::JSONB)) FROM page);
END;
$$;

ALTER TABLE public.finance_report_definitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_report_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_report_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_report_exports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_report_audit ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Finance report definitions readable" ON public.finance_report_definitions FOR SELECT TO authenticated USING(private.g6_report_role_allowed(company_id));
CREATE POLICY "Finance report versions readable" ON public.finance_report_versions FOR SELECT TO authenticated USING(private.g6_report_role_allowed(company_id));
CREATE POLICY "Finance report lines readable" ON public.finance_report_lines FOR SELECT TO authenticated USING(private.g6_report_role_allowed(company_id));
CREATE POLICY "Finance report exports readable" ON public.finance_report_exports FOR SELECT TO authenticated USING(private.g6_report_role_allowed(company_id));
CREATE POLICY "Finance report audit readable" ON public.finance_report_audit FOR SELECT TO authenticated USING(private.g6_report_role_allowed(company_id));

REVOKE ALL ON public.finance_report_definitions,public.finance_report_versions,public.finance_report_lines,public.finance_report_exports,public.finance_report_audit FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.finance_report_definitions,public.finance_report_versions,public.finance_report_lines,public.finance_report_exports,public.finance_report_audit TO authenticated;
GRANT ALL ON public.finance_report_definitions,public.finance_report_versions,public.finance_report_lines,public.finance_report_exports,public.finance_report_audit TO service_role;
REVOKE ALL ON FUNCTION private.g6_report_role_allowed(UUID),private.provision_g6_posted_reports(UUID,UUID),private.trg_g6_provision_posted_reports(),private.trg_g6_guard_report_history() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.g6_report_role_allowed(UUID) TO authenticated,service_role;
GRANT EXECUTE ON FUNCTION private.provision_g6_posted_reports(UUID,UUID),private.trg_g6_provision_posted_reports(),private.trg_g6_guard_report_history() TO service_role;
REVOKE ALL ON FUNCTION public.get_finance_trial_balance(DATE,DATE,UUID,UUID),public.get_finance_general_ledger(UUID,DATE,DATE,UUID,UUID,INTEGER,INTEGER) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_finance_trial_balance(DATE,DATE,UUID,UUID),public.get_finance_general_ledger(UUID,DATE,DATE,UUID,UUID,INTEGER,INTEGER) TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes) VALUES(
 '20260810220000','g6_phase6a_posted_financial_reports',
 'POSTED-only tenant/role/timezone-aware Trial Balance and General Ledger with version metadata, immutable report history, pagination, prior-period/source drilldown, RLS, and no HOLD/cache/export processing'
);
COMMIT;
