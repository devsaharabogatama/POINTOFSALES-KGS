-- KGS POS G6 corrective phase 5: controlled historical posting queue.
--
-- The migration installs preview/approval/processing infrastructure only.
-- It never creates a queue run and never processes an existing HOLD event.
-- Phase 4 remains the posting authority and currently supports STOCK_OPENING.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260810200000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G6 phase 4 posting required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version = '20260810210000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260810210000';
    END IF;
    IF to_regclass('public.finance_posting_queue_runs') IS NOT NULL
       OR to_regclass('public.finance_posting_queue_items') IS NOT NULL
       OR to_regclass('public.finance_posting_queue_audit') IS NOT NULL
       OR to_regprocedure(
           'public.preview_financial_event_posting_queue(integer)'
       ) IS NOT NULL
       OR to_regprocedure(
           'public.approve_financial_event_posting_queue(uuid,bigint)'
       ) IS NOT NULL
       OR to_regprocedure(
           'public.process_financial_event_posting_queue(uuid,bigint)'
       ) IS NOT NULL THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: Phase 5 target already exists';
    END IF;
END
$migration_guard$;

CREATE TABLE public.finance_posting_queue_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL
        REFERENCES public.companies(id) ON DELETE RESTRICT,
    queue_no TEXT NOT NULL,
    scope_system_key TEXT NOT NULL DEFAULT 'STOCK_OPENING',
    status TEXT NOT NULL DEFAULT 'PREVIEWED',
    preview_limit INTEGER NOT NULL,
    previewed_event_count INTEGER NOT NULL DEFAULT 0,
    posted_count INTEGER NOT NULL DEFAULT 0,
    failed_count INTEGER NOT NULL DEFAULT 0,
    skipped_count INTEGER NOT NULL DEFAULT 0,
    preview_hash TEXT NOT NULL,
    master_version BIGINT NOT NULL DEFAULT 1,
    created_by UUID NOT NULL REFERENCES public.profiles(id),
    approved_by UUID REFERENCES public.profiles(id),
    processing_by UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    approved_at TIMESTAMPTZ,
    processing_started_at TIMESTAMPTZ,
    processed_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT finance_posting_queue_runs_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT finance_posting_queue_runs_company_no_unique
        UNIQUE(company_id,queue_no),
    CONSTRAINT finance_posting_queue_runs_no_not_blank
        CHECK(btrim(queue_no) <> ''),
    CONSTRAINT finance_posting_queue_runs_scope_check
        CHECK(scope_system_key = 'STOCK_OPENING'),
    CONSTRAINT finance_posting_queue_runs_status_check CHECK(
        status IN (
            'PREVIEWED','APPROVED','PROCESSING',
            'COMPLETED','COMPLETED_WITH_ERRORS'
        )
    ),
    CONSTRAINT finance_posting_queue_runs_limit_check
        CHECK(preview_limit BETWEEN 1 AND 500),
    CONSTRAINT finance_posting_queue_runs_count_check CHECK(
        previewed_event_count >= 0
        AND posted_count >= 0
        AND failed_count >= 0
        AND skipped_count >= 0
        AND posted_count + failed_count + skipped_count
            <= previewed_event_count
    ),
    CONSTRAINT finance_posting_queue_runs_hash_check
        CHECK(preview_hash ~ '^[0-9a-f]{32}$'),
    CONSTRAINT finance_posting_queue_runs_version_positive
        CHECK(master_version > 0),
    CONSTRAINT finance_posting_queue_runs_lifecycle_check CHECK(
        (
            status = 'PREVIEWED'
            AND approved_by IS NULL AND approved_at IS NULL
            AND processing_by IS NULL AND processing_started_at IS NULL
            AND processed_at IS NULL
        ) OR (
            status = 'APPROVED'
            AND approved_by IS NOT NULL AND approved_at IS NOT NULL
            AND processing_by IS NULL AND processing_started_at IS NULL
            AND processed_at IS NULL
        ) OR (
            status = 'PROCESSING'
            AND approved_by IS NOT NULL AND approved_at IS NOT NULL
            AND processing_by IS NOT NULL
            AND processing_started_at IS NOT NULL
            AND processed_at IS NULL
        ) OR (
            status IN ('COMPLETED','COMPLETED_WITH_ERRORS')
            AND approved_by IS NOT NULL AND approved_at IS NOT NULL
            AND processing_by IS NOT NULL
            AND processing_started_at IS NOT NULL
            AND processed_at IS NOT NULL
        )
    )
);

CREATE UNIQUE INDEX uq_finance_posting_queue_runs_company_active
    ON public.finance_posting_queue_runs(company_id)
    WHERE status IN ('PREVIEWED','APPROVED','PROCESSING');
CREATE INDEX idx_finance_posting_queue_runs_company_status
    ON public.finance_posting_queue_runs(company_id,status,created_at,id);

CREATE TABLE public.finance_posting_queue_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL,
    queue_run_id UUID NOT NULL,
    line_no INTEGER NOT NULL,
    financial_event_id UUID NOT NULL,
    event_version_snapshot BIGINT NOT NULL,
    event_code_snapshot TEXT NOT NULL,
    system_event_key_snapshot TEXT NOT NULL,
    source_table_snapshot TEXT NOT NULL,
    source_id_snapshot UUID NOT NULL,
    transaction_category_id_snapshot UUID NOT NULL,
    event_date_snapshot TIMESTAMPTZ NOT NULL,
    status TEXT NOT NULL DEFAULT 'READY',
    attempt_count INTEGER NOT NULL DEFAULT 0,
    journal_id UUID,
    error_code TEXT,
    error_message TEXT,
    processed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT finance_posting_queue_items_company_id_id_unique
        UNIQUE(company_id,id),
    CONSTRAINT finance_posting_queue_items_run_line_unique
        UNIQUE(company_id,queue_run_id,line_no),
    CONSTRAINT finance_posting_queue_items_run_event_unique
        UNIQUE(company_id,queue_run_id,financial_event_id),
    CONSTRAINT finance_posting_queue_items_line_positive CHECK(line_no > 0),
    CONSTRAINT finance_posting_queue_items_event_version_positive
        CHECK(event_version_snapshot > 0),
    CONSTRAINT finance_posting_queue_items_identity_not_blank CHECK(
        btrim(event_code_snapshot) <> ''
        AND btrim(system_event_key_snapshot) <> ''
        AND btrim(source_table_snapshot) <> ''
    ),
    CONSTRAINT finance_posting_queue_items_status_check
        CHECK(status IN ('READY','POSTED','FAILED','SKIPPED')),
    CONSTRAINT finance_posting_queue_items_attempt_nonnegative
        CHECK(attempt_count >= 0),
    CONSTRAINT finance_posting_queue_items_result_check CHECK(
        (
            status = 'READY' AND attempt_count = 0
            AND journal_id IS NULL AND error_code IS NULL
            AND error_message IS NULL AND processed_at IS NULL
        ) OR (
            status = 'POSTED' AND attempt_count > 0
            AND journal_id IS NOT NULL AND error_code IS NULL
            AND error_message IS NULL AND processed_at IS NOT NULL
        ) OR (
            status IN ('FAILED','SKIPPED') AND attempt_count > 0
            AND journal_id IS NULL AND error_code IS NOT NULL
            AND processed_at IS NOT NULL
        )
    ),
    CONSTRAINT fk_finance_queue_item_company_run
        FOREIGN KEY(company_id,queue_run_id)
        REFERENCES public.finance_posting_queue_runs(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_finance_queue_item_company_event
        FOREIGN KEY(company_id,financial_event_id)
        REFERENCES public.financial_events(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_finance_queue_item_company_category
        FOREIGN KEY(company_id,transaction_category_id_snapshot)
        REFERENCES public.transaction_categories(company_id,id)
        ON DELETE RESTRICT,
    CONSTRAINT fk_finance_queue_item_company_journal
        FOREIGN KEY(company_id,journal_id)
        REFERENCES public.finance_journals(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_finance_posting_queue_items_run_status
    ON public.finance_posting_queue_items(
        company_id,queue_run_id,status,line_no
    );
CREATE INDEX idx_finance_posting_queue_items_event
    ON public.finance_posting_queue_items(company_id,financial_event_id);

CREATE TABLE public.finance_posting_queue_audit (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    company_id UUID NOT NULL,
    queue_run_id UUID NOT NULL,
    action TEXT NOT NULL,
    actor_id UUID NOT NULL REFERENCES public.profiles(id),
    before_state JSONB,
    after_state JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT finance_posting_queue_audit_action_check CHECK(
        action IN ('PREVIEW','APPROVE','PROCESS')
    ),
    CONSTRAINT finance_posting_queue_audit_after_object CHECK(
        jsonb_typeof(after_state) = 'object'
    ),
    CONSTRAINT fk_finance_queue_audit_company_run
        FOREIGN KEY(company_id,queue_run_id)
        REFERENCES public.finance_posting_queue_runs(company_id,id)
        ON DELETE RESTRICT
);

CREATE INDEX idx_finance_posting_queue_audit_run
    ON public.finance_posting_queue_audit(
        company_id,queue_run_id,created_at,id
    );

CREATE FUNCTION private.trg_g6_touch_posting_queue_run()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'FINANCE_POSTING_QUEUE_HISTORY_IMMUTABLE';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF OLD.status IN ('COMPLETED','COMPLETED_WITH_ERRORS') THEN
            RAISE EXCEPTION 'FINAL_FINANCE_POSTING_QUEUE_IMMUTABLE';
        END IF;
        IF NEW.id IS DISTINCT FROM OLD.id
           OR NEW.company_id IS DISTINCT FROM OLD.company_id
           OR NEW.queue_no IS DISTINCT FROM OLD.queue_no
           OR NEW.scope_system_key IS DISTINCT FROM OLD.scope_system_key
           OR NEW.preview_limit IS DISTINCT FROM OLD.preview_limit
           OR NEW.created_by IS DISTINCT FROM OLD.created_by
           OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
            RAISE EXCEPTION 'FINANCE_POSTING_QUEUE_IDENTITY_IMMUTABLE';
        END IF;
        IF (
            NEW.previewed_event_count IS DISTINCT FROM
                OLD.previewed_event_count
            OR NEW.preview_hash IS DISTINCT FROM OLD.preview_hash
        ) AND NOT (
            OLD.status = 'PREVIEWED'
            AND NEW.status = 'PREVIEWED'
            AND OLD.previewed_event_count = 0
            AND NEW.previewed_event_count > 0
            AND OLD.posted_count = 0 AND OLD.failed_count = 0
            AND OLD.skipped_count = 0
        ) THEN
            RAISE EXCEPTION 'FINANCE_POSTING_QUEUE_PREVIEW_IMMUTABLE';
        END IF;
        NEW.master_version := OLD.master_version + 1;
        NEW.updated_at := clock_timestamp();
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g6_guard_posting_queue_item()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'FINANCE_POSTING_QUEUE_HISTORY_IMMUTABLE';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        IF OLD.status IN ('POSTED','FAILED','SKIPPED') THEN
            RAISE EXCEPTION 'FINAL_FINANCE_POSTING_QUEUE_ITEM_IMMUTABLE';
        END IF;
        IF NEW.id IS DISTINCT FROM OLD.id
           OR NEW.company_id IS DISTINCT FROM OLD.company_id
           OR NEW.queue_run_id IS DISTINCT FROM OLD.queue_run_id
           OR NEW.line_no IS DISTINCT FROM OLD.line_no
           OR NEW.financial_event_id IS DISTINCT FROM OLD.financial_event_id
           OR NEW.event_version_snapshot IS DISTINCT FROM OLD.event_version_snapshot
           OR NEW.event_code_snapshot IS DISTINCT FROM OLD.event_code_snapshot
           OR NEW.system_event_key_snapshot IS DISTINCT FROM OLD.system_event_key_snapshot
           OR NEW.source_table_snapshot IS DISTINCT FROM OLD.source_table_snapshot
           OR NEW.source_id_snapshot IS DISTINCT FROM OLD.source_id_snapshot
           OR NEW.transaction_category_id_snapshot IS DISTINCT FROM
              OLD.transaction_category_id_snapshot
           OR NEW.event_date_snapshot IS DISTINCT FROM OLD.event_date_snapshot
           OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
            RAISE EXCEPTION 'FINANCE_POSTING_QUEUE_ITEM_SNAPSHOT_IMMUTABLE';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION private.trg_g6_guard_posting_queue_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'FINANCE_POSTING_QUEUE_AUDIT_IMMUTABLE';
END;
$$;

CREATE TRIGGER g6_touch_posting_queue_run
BEFORE UPDATE OR DELETE ON public.finance_posting_queue_runs
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_touch_posting_queue_run();
CREATE TRIGGER g6_guard_posting_queue_item
BEFORE UPDATE OR DELETE ON public.finance_posting_queue_items
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_guard_posting_queue_item();
CREATE TRIGGER g6_guard_posting_queue_audit
BEFORE UPDATE OR DELETE ON public.finance_posting_queue_audit
FOR EACH ROW EXECUTE FUNCTION private.trg_g6_guard_posting_queue_audit();

CREATE FUNCTION private.g6_finance_queue_role_allowed(
    p_company_id UUID
) RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT public.private_request_company_matches(p_company_id)
       AND public.private_user_has_any_company_or_store_role(
           p_company_id,
           ARRAY[
               'COMPANY_OWNER','COMPANY_ADMIN','FINANCE','ACCOUNTING'
           ]::TEXT[]
       )
$$;

CREATE FUNCTION public.preview_financial_event_posting_queue(
    p_limit INTEGER DEFAULT 100
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_run_id UUID := gen_random_uuid();
    v_run public.finance_posting_queue_runs%ROWTYPE;
    v_count INTEGER;
    v_hash TEXT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 500 THEN
        RAISE EXCEPTION 'QUEUE_PREVIEW_LIMIT_INVALID';
    END IF;
    IF NOT private.g6_finance_queue_role_allowed(v_company) THEN
        RAISE EXCEPTION 'FINANCE_QUEUE_ROLE_REQUIRED';
    END IF;
    PERFORM pg_advisory_xact_lock(
        hashtextextended('G6_FINANCE_QUEUE|' || v_company::TEXT,0)
    );
    IF EXISTS (
        SELECT 1 FROM public.finance_posting_queue_runs run
        WHERE run.company_id = v_company
          AND run.status IN ('PREVIEWED','APPROVED','PROCESSING')
    ) THEN
        RAISE EXCEPTION 'ACTIVE_FINANCE_POSTING_QUEUE_ALREADY_EXISTS';
    END IF;

    INSERT INTO public.finance_posting_queue_runs(
        id,company_id,queue_no,scope_system_key,status,preview_limit,
        preview_hash,created_by
    ) VALUES (
        v_run_id,v_company,
        'FQ-' || to_char(clock_timestamp(),'YYYYMMDD') || '-'
            || upper(substr(replace(v_run_id::TEXT,'-',''),1,8)),
        'STOCK_OPENING','PREVIEWED',p_limit,
        md5('EMPTY|' || v_company::TEXT || '|' || v_run_id::TEXT),v_actor
    );

    INSERT INTO public.finance_posting_queue_items(
        company_id,queue_run_id,line_no,financial_event_id,
        event_version_snapshot,event_code_snapshot,
        system_event_key_snapshot,source_table_snapshot,source_id_snapshot,
        transaction_category_id_snapshot,event_date_snapshot
    )
    SELECT
        event.company_id,v_run_id,
        row_number() OVER(ORDER BY event.event_date,event.id)::INTEGER,
        event.id,event.event_version,event.event_code,event.system_event_key,
        event.source_table,event.source_id,event.transaction_category_id,
        event.event_date
    FROM public.financial_events event
    JOIN public.opening_stock_documents document
      ON document.company_id = event.company_id
     AND document.id = event.source_id
     AND document.financial_event_id = event.id
     AND document.status = 'POSTED'
    WHERE event.company_id = v_company
      AND event.status::TEXT = 'HOLD'
      AND event.system_event_key = 'STOCK_OPENING'
      AND event.event_type::TEXT = 'STOCK_OPENING'
      AND event.source_table = 'opening_stock_documents'
      AND NOT EXISTS (
          SELECT 1 FROM public.finance_journals journal
          WHERE journal.company_id = event.company_id
            AND journal.financial_event_id = event.id
      )
    ORDER BY event.event_date,event.id
    LIMIT p_limit;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    IF v_count = 0 THEN
        RAISE EXCEPTION 'NO_SUPPORTED_HOLD_EVENTS';
    END IF;
    SELECT md5(string_agg(
        item.financial_event_id::TEXT || ':'
            || item.event_version_snapshot::TEXT,
        '|' ORDER BY item.line_no
    )) INTO v_hash
    FROM public.finance_posting_queue_items item
    WHERE item.company_id = v_company AND item.queue_run_id = v_run_id;

    UPDATE public.finance_posting_queue_runs SET
        previewed_event_count = v_count,preview_hash = v_hash
    WHERE company_id = v_company AND id = v_run_id
    RETURNING * INTO v_run;

    INSERT INTO public.finance_posting_queue_audit(
        company_id,queue_run_id,action,actor_id,after_state
    ) VALUES (
        v_company,v_run_id,'PREVIEW',v_actor,
        jsonb_build_object(
            'status',v_run.status,'masterVersion',v_run.master_version,
            'eventCount',v_count,'previewHash',v_hash,
            'scopeSystemKey',v_run.scope_system_key
        )
    );
    RETURN jsonb_build_object(
        'queueRunId',v_run.id,'queueNo',v_run.queue_no,
        'status',v_run.status,'masterVersion',v_run.master_version,
        'eventCount',v_count,'previewHash',v_hash
    );
END;
$$;

CREATE FUNCTION public.approve_financial_event_posting_queue(
    p_queue_run_id UUID,p_expected_master_version BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_run public.finance_posting_queue_runs%ROWTYPE;
    v_before JSONB;
    v_stale_count BIGINT;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT private.g6_finance_queue_role_allowed(v_company) THEN
        RAISE EXCEPTION 'FINANCE_QUEUE_ROLE_REQUIRED';
    END IF;
    SELECT * INTO v_run
    FROM public.finance_posting_queue_runs run
    WHERE run.company_id = v_company AND run.id = p_queue_run_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FINANCE_POSTING_QUEUE_NOT_FOUND'; END IF;
    IF p_expected_master_version IS NULL
       OR p_expected_master_version <> v_run.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF v_run.status <> 'PREVIEWED' THEN
        RAISE EXCEPTION 'FINANCE_POSTING_QUEUE_NOT_PREVIEWED';
    END IF;

    SELECT count(*) INTO v_stale_count
    FROM public.finance_posting_queue_items item
    LEFT JOIN public.financial_events event
      ON event.company_id = item.company_id
     AND event.id = item.financial_event_id
    WHERE item.company_id = v_company
      AND item.queue_run_id = v_run.id
      AND (
          event.id IS NULL
          OR event.status::TEXT <> 'HOLD'
          OR event.event_version <> item.event_version_snapshot
          OR event.system_event_key <> item.system_event_key_snapshot
          OR event.source_table <> item.source_table_snapshot
          OR event.source_id <> item.source_id_snapshot
          OR EXISTS (
              SELECT 1 FROM public.finance_journals journal
              WHERE journal.company_id = item.company_id
                AND journal.financial_event_id = item.financial_event_id
          )
      );
    IF v_stale_count <> 0 THEN RAISE EXCEPTION 'QUEUE_PREVIEW_STALE'; END IF;

    v_before := jsonb_build_object(
        'status',v_run.status,'masterVersion',v_run.master_version
    );
    UPDATE public.finance_posting_queue_runs SET
        status = 'APPROVED',approved_by = v_actor,
        approved_at = clock_timestamp()
    WHERE company_id = v_company AND id = v_run.id
    RETURNING * INTO v_run;
    INSERT INTO public.finance_posting_queue_audit(
        company_id,queue_run_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_run.id,'APPROVE',v_actor,v_before,
        jsonb_build_object(
            'status',v_run.status,'masterVersion',v_run.master_version,
            'previewHash',v_run.preview_hash
        )
    );
    RETURN jsonb_build_object(
        'queueRunId',v_run.id,'status',v_run.status,
        'masterVersion',v_run.master_version,
        'eventCount',v_run.previewed_event_count
    );
END;
$$;

CREATE FUNCTION public.process_financial_event_posting_queue(
    p_queue_run_id UUID,p_expected_master_version BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor UUID := auth.uid();
    v_company UUID := public.private_active_company_id();
    v_run public.finance_posting_queue_runs%ROWTYPE;
    v_item public.finance_posting_queue_items%ROWTYPE;
    v_result JSONB;
    v_error TEXT;
    v_reason TEXT;
    v_exception_id UUID;
    v_posted INTEGER := 0;
    v_failed INTEGER := 0;
    v_skipped INTEGER := 0;
    v_before JSONB;
BEGIN
    IF v_actor IS NULL THEN RAISE EXCEPTION 'AUTHENTICATION_REQUIRED'; END IF;
    IF v_company IS NULL THEN RAISE EXCEPTION 'ACTIVE_COMPANY_REQUIRED'; END IF;
    IF NOT private.g6_finance_queue_role_allowed(v_company) THEN
        RAISE EXCEPTION 'FINANCE_QUEUE_ROLE_REQUIRED';
    END IF;
    SELECT * INTO v_run
    FROM public.finance_posting_queue_runs run
    WHERE run.company_id = v_company AND run.id = p_queue_run_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'FINANCE_POSTING_QUEUE_NOT_FOUND'; END IF;
    IF v_run.status IN ('COMPLETED','COMPLETED_WITH_ERRORS') THEN
        RETURN jsonb_build_object(
            'queueRunId',v_run.id,'status',v_run.status,
            'masterVersion',v_run.master_version,
            'postedCount',v_run.posted_count,
            'failedCount',v_run.failed_count,
            'skippedCount',v_run.skipped_count,
            'idempotentReplay',TRUE
        );
    END IF;
    IF p_expected_master_version IS NULL
       OR p_expected_master_version <> v_run.master_version THEN
        RAISE EXCEPTION 'MASTER_VERSION_CONFLICT';
    END IF;
    IF v_run.status <> 'APPROVED' THEN
        RAISE EXCEPTION 'FINANCE_POSTING_QUEUE_NOT_APPROVED';
    END IF;

    v_before := jsonb_build_object(
        'status',v_run.status,'masterVersion',v_run.master_version
    );
    UPDATE public.finance_posting_queue_runs SET
        status = 'PROCESSING',processing_by = v_actor,
        processing_started_at = clock_timestamp()
    WHERE company_id = v_company AND id = v_run.id
    RETURNING * INTO v_run;

    FOR v_item IN
        SELECT item.*
        FROM public.finance_posting_queue_items item
        WHERE item.company_id = v_company
          AND item.queue_run_id = v_run.id
          AND item.status = 'READY'
        ORDER BY item.line_no
        FOR UPDATE
    LOOP
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM public.financial_events event
                WHERE event.company_id = v_company
                  AND event.id = v_item.financial_event_id
                  AND event.status::TEXT = 'HOLD'
                  AND event.event_version = v_item.event_version_snapshot
            ) THEN
                UPDATE public.finance_posting_queue_items SET
                    status = 'SKIPPED',attempt_count = attempt_count + 1,
                    error_code = 'QUEUE_PREVIEW_STALE',
                    error_message = 'Event changed after queue approval',
                    processed_at = clock_timestamp()
                WHERE company_id = v_company AND id = v_item.id;
                v_skipped := v_skipped + 1;
            ELSE
                v_result := private.post_financial_event_core(
                    v_company,v_item.financial_event_id,
                    v_item.event_version_snapshot,v_actor
                );
                UPDATE public.finance_posting_queue_items SET
                    status = 'POSTED',attempt_count = attempt_count + 1,
                    journal_id = (v_result->>'journalId')::UUID,
                    processed_at = clock_timestamp()
                WHERE company_id = v_company AND id = v_item.id;
                v_posted := v_posted + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_error := SQLERRM;
            v_reason := CASE
                WHEN v_error LIKE '%PERIOD%' THEN 'LOCKED_PERIOD'
                WHEN v_error LIKE '%UNBALANCED%' OR v_error LIKE '%AMOUNT%'
                    THEN 'UNBALANCED_JOURNAL'
                WHEN v_error LIKE '%VERSION%' THEN 'RULE_VERSION_CONFLICT'
                WHEN v_error LIKE '%ACCOUNT%INVALID%'
                    THEN 'INACTIVE_ACCOUNT'
                WHEN v_error LIKE '%SOURCE%' OR v_error LIKE '%UNSUPPORTED%'
                    THEN 'INVALID_DIMENSION'
                ELSE 'MISSING_REQUIRED_FUNCTION'
            END;
            SELECT exception_state.id INTO v_exception_id
            FROM public.finance_posting_exceptions exception_state
            WHERE exception_state.company_id = v_company
              AND exception_state.financial_event_id = v_item.financial_event_id
              AND exception_state.reason_code = v_reason
              AND exception_state.resolver_level = 'CONTROLLED_QUEUE'
              AND exception_state.status <> 'RESOLVED'
            ORDER BY exception_state.created_at DESC,exception_state.id
            LIMIT 1
            FOR UPDATE;
            IF FOUND THEN
                UPDATE public.finance_posting_exceptions SET
                    status = 'POSTING_ERROR',retry_count = retry_count + 1,
                    last_error = left(v_error,1000),
                    updated_at = clock_timestamp()
                WHERE company_id = v_company AND id = v_exception_id;
            ELSE
                INSERT INTO public.finance_posting_exceptions(
                    company_id,financial_event_id,source_table,source_id,
                    system_key,transaction_category_id,reason_code,
                    resolver_level,status,retry_count,last_error
                ) VALUES (
                    v_company,v_item.financial_event_id,
                    v_item.source_table_snapshot,v_item.source_id_snapshot,
                    v_item.system_event_key_snapshot,
                    v_item.transaction_category_id_snapshot,v_reason,
                    'CONTROLLED_QUEUE','POSTING_ERROR',1,left(v_error,1000)
                ) RETURNING id INTO v_exception_id;
            END IF;
            UPDATE public.finance_posting_queue_items SET
                status = 'FAILED',attempt_count = attempt_count + 1,
                error_code = v_reason,error_message = left(v_error,1000),
                processed_at = clock_timestamp()
            WHERE company_id = v_company AND id = v_item.id;
            v_failed := v_failed + 1;
        END;
    END LOOP;

    UPDATE public.finance_posting_queue_runs SET
        status = CASE WHEN v_failed = 0 AND v_skipped = 0
                      THEN 'COMPLETED'
                      ELSE 'COMPLETED_WITH_ERRORS' END,
        posted_count = v_posted,failed_count = v_failed,
        skipped_count = v_skipped,processed_at = clock_timestamp()
    WHERE company_id = v_company AND id = v_run.id
    RETURNING * INTO v_run;

    INSERT INTO public.finance_posting_queue_audit(
        company_id,queue_run_id,action,actor_id,before_state,after_state
    ) VALUES (
        v_company,v_run.id,'PROCESS',v_actor,v_before,
        jsonb_build_object(
            'status',v_run.status,'masterVersion',v_run.master_version,
            'postedCount',v_posted,'failedCount',v_failed,
            'skippedCount',v_skipped
        )
    );
    RETURN jsonb_build_object(
        'queueRunId',v_run.id,'status',v_run.status,
        'masterVersion',v_run.master_version,
        'postedCount',v_posted,'failedCount',v_failed,
        'skippedCount',v_skipped,'idempotentReplay',FALSE
    );
END;
$$;

ALTER TABLE public.finance_posting_queue_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_posting_queue_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.finance_posting_queue_audit ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Finance queue runs readable by Finance roles"
ON public.finance_posting_queue_runs FOR SELECT TO authenticated
USING(private.g6_finance_queue_role_allowed(company_id));
CREATE POLICY "Finance queue items readable by Finance roles"
ON public.finance_posting_queue_items FOR SELECT TO authenticated
USING(private.g6_finance_queue_role_allowed(company_id));
CREATE POLICY "Finance queue audit readable by Finance roles"
ON public.finance_posting_queue_audit FOR SELECT TO authenticated
USING(private.g6_finance_queue_role_allowed(company_id));

REVOKE ALL ON public.finance_posting_queue_runs,
    public.finance_posting_queue_items,public.finance_posting_queue_audit
FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.finance_posting_queue_runs,
    public.finance_posting_queue_items,public.finance_posting_queue_audit
TO authenticated;
GRANT ALL ON public.finance_posting_queue_runs,
    public.finance_posting_queue_items,public.finance_posting_queue_audit
TO service_role;

REVOKE ALL ON FUNCTION
    private.trg_g6_touch_posting_queue_run(),
    private.trg_g6_guard_posting_queue_item(),
    private.trg_g6_guard_posting_queue_audit(),
    private.g6_finance_queue_role_allowed(UUID)
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION
    private.trg_g6_touch_posting_queue_run(),
    private.trg_g6_guard_posting_queue_item(),
    private.trg_g6_guard_posting_queue_audit()
TO service_role;
GRANT EXECUTE ON FUNCTION private.g6_finance_queue_role_allowed(UUID)
TO authenticated,service_role;

REVOKE ALL ON FUNCTION
    public.preview_financial_event_posting_queue(INTEGER),
    public.approve_financial_event_posting_queue(UUID,BIGINT),
    public.process_financial_event_posting_queue(UUID,BIGINT)
FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION
    public.preview_financial_event_posting_queue(INTEGER),
    public.approve_financial_event_posting_queue(UUID,BIGINT),
    public.process_financial_event_posting_queue(UUID,BIGINT)
TO authenticated,service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES (
    '20260810210000',
    'g6_phase5_controlled_posting_queue',
    'Single-active-Company historical HOLD preview/approval/process queue with immutable snapshots, per-event failure isolation, exact Phase-4 posting authority, audit, and zero automatic migration processing'
);

COMMIT;
