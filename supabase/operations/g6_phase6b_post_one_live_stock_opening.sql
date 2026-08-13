-- G6 phase 6B controlled live operation: post exactly one reviewed STOCK_OPENING.
--
-- WARNING: THIS FILE MUTATES LIVE FINANCE STATE.
-- Run only after g6_phase6b_stock_opening_live_reconciliation_preflight.sql
-- has zero BLOCKER/REVIEW and reports exactly one event totaling 450000.
-- The operation is audited, idempotent through the queue, and irreversible;
-- a posted journal must never be deleted or returned to HOLD.

BEGIN;

DO $controlled_live_run$
DECLARE
    v_actor UUID;
    v_company UUID;
    v_event_count BIGINT;
    v_amount NUMERIC(24,4);
    v_preview JSONB;
    v_approval JSONB;
    v_process JSONB;
BEGIN
    SELECT
        count(*),min(event.company_id::TEXT)::UUID,
        COALESCE(sum(document.total_cost),0)
    INTO v_event_count,v_company,v_amount
    FROM public.financial_events event
    JOIN public.opening_stock_documents document
      ON document.company_id=event.company_id
     AND document.id=event.source_id
     AND document.financial_event_id=event.id
     AND document.status='POSTED'
    WHERE event.status::TEXT='HOLD'
      AND event.system_event_key='STOCK_OPENING'
      AND event.event_type::TEXT='STOCK_OPENING'
      AND event.source_table='opening_stock_documents'
      AND NOT EXISTS (
          SELECT 1 FROM public.finance_journals journal
          WHERE journal.company_id=event.company_id
            AND journal.financial_event_id=event.id
      );

    IF v_event_count<>1 OR v_company IS NULL OR v_amount<>450000 THEN
        RAISE EXCEPTION
            'LIVE_SCOPE_CHANGED: expected one STOCK_OPENING totaling 450000, got % totaling %',
            v_event_count,v_amount;
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.finance_posting_queue_runs
        WHERE company_id=v_company
          AND status IN ('PREVIEWED','APPROVED','PROCESSING')
    ) THEN
        RAISE EXCEPTION 'ACTIVE_FINANCE_POSTING_QUEUE_ALREADY_EXISTS';
    END IF;

    SELECT profile.id INTO v_actor
    FROM public.profiles profile
    JOIN auth.users auth_user ON auth_user.id=profile.id
    WHERE profile.role::TEXT='super_admin'
    ORDER BY profile.id
    LIMIT 1;
    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'LINKED_SUPER_ADMIN_REQUIRED';
    END IF;

    PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub',v_actor,'role','authenticated')::TEXT,
        TRUE
    );
    PERFORM public.set_active_company_context(
        v_company,'G6_PHASE6B_LIVE_POST'
    );

    v_preview:=public.preview_financial_event_posting_queue(1);
    IF (v_preview->>'eventCount')::BIGINT<>1 THEN
        RAISE EXCEPTION 'LIVE_PREVIEW_SCOPE_INVALID';
    END IF;
    v_approval:=public.approve_financial_event_posting_queue(
        (v_preview->>'queueRunId')::UUID,
        (v_preview->>'masterVersion')::BIGINT
    );
    v_process:=public.process_financial_event_posting_queue(
        (v_approval->>'queueRunId')::UUID,
        (v_approval->>'masterVersion')::BIGINT
    );

    RAISE NOTICE 'CONTROLLED LIVE RUN RESULT: %',v_process;
END
$controlled_live_run$;

COMMIT;

SELECT
    run.queue_no,
    run.status,
    run.previewed_event_count,
    run.posted_count,
    run.failed_count,
    run.skipped_count,
    run.master_version,
    run.processed_at
FROM public.finance_posting_queue_runs run
ORDER BY run.created_at DESC,run.id DESC
LIMIT 1;
