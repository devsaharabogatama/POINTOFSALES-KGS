-- G5 phase 5 forward fix: resolve receipt ownership per trigger table.
-- The original CASE referenced fields from unrelated trigger records, causing
-- PostgreSQL to resolve receipt_line_id while inserting goods_receipt_lines.

BEGIN;

DO $migration_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260806040000'
    ) THEN
        RAISE EXCEPTION
            'MIGRATION_PRECONDITION_FAILED: G5 Goods Receipt foundation required';
    END IF;
    IF EXISTS (
        SELECT 1 FROM private.kgs_schema_migrations
        WHERE version='20260806050000'
    ) THEN
        RAISE EXCEPTION 'MIGRATION_ALREADY_APPLIED: 20260806050000';
    END IF;
END
$migration_guard$;

CREATE OR REPLACE FUNCTION private.trg_g5_goods_receipt_history_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public,pg_temp
AS $$
DECLARE
    v_document_id UUID;
    v_status TEXT;
BEGIN
    IF TG_TABLE_NAME='goods_receipt_documents' THEN
        IF TG_OP<>'INSERT' AND OLD.status IN('POSTED','CANCELED') THEN
            RAISE EXCEPTION 'FINAL_GOODS_RECEIPT_IMMUTABLE';
        END IF;
        IF TG_OP='DELETE' THEN RETURN OLD; END IF;
        RETURN NEW;
    ELSIF TG_TABLE_NAME='goods_receipt_lines' THEN
        IF TG_OP='DELETE' THEN
            v_document_id:=OLD.document_id;
        ELSE
            v_document_id:=NEW.document_id;
        END IF;
    ELSIF TG_TABLE_NAME='goods_receipt_condition_allocations' THEN
        IF TG_OP='DELETE' THEN
            SELECT line.document_id INTO v_document_id
            FROM public.goods_receipt_lines line
            WHERE line.id=OLD.receipt_line_id;
        ELSE
            SELECT line.document_id INTO v_document_id
            FROM public.goods_receipt_lines line
            WHERE line.id=NEW.receipt_line_id;
        END IF;
    ELSIF TG_TABLE_NAME='goods_receipt_ap_provisionals' THEN
        IF TG_OP='DELETE' THEN
            v_document_id:=OLD.receipt_id;
        ELSE
            v_document_id:=NEW.receipt_id;
        END IF;
    ELSE
        RAISE EXCEPTION 'UNSUPPORTED_GOODS_RECEIPT_HISTORY_TABLE:%',TG_TABLE_NAME;
    END IF;

    SELECT document.status INTO v_status
    FROM public.goods_receipt_documents document
    WHERE document.id=v_document_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'GOODS_RECEIPT_NOT_FOUND'; END IF;
    IF v_status<>'DRAFT' THEN
        RAISE EXCEPTION 'FINAL_GOODS_RECEIPT_IMMUTABLE';
    END IF;
    IF TG_OP='DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.trg_g5_goods_receipt_history_guard()
FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.trg_g5_goods_receipt_history_guard()
TO service_role;

INSERT INTO private.kgs_schema_migrations(version,migration_name,notes)
VALUES(
    '20260806050000',
    'g5_phase5_goods_receipt_history_trigger_fix',
    'Forward fix isolates table-specific trigger record fields with IF branches'
);

COMMIT;
