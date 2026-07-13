-- -----------------------------------------------------
-- Trigger: cash_advances_to_financial_events
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION trg_cash_advances_to_financial_events() 
RETURNS TRIGGER AS $$
DECLARE
    v_event_code TEXT;
BEGIN
    -- Check if approved and doesn't already have an event logged (idempotency safety)
    IF NEW.status = 'APPROVED' AND (OLD IS NULL OR OLD.status != 'APPROVED') THEN
        
        -- Prevent duplicates
        IF EXISTS (
            SELECT 1 FROM financial_events 
            WHERE source_table = 'cash_advances' AND source_id = NEW.id
        ) THEN
            RETURN NEW;
        END IF;

        -- Generate Event Code
        v_event_code := 'EVT-' || to_char(NOW(), 'YYYYMMDD') || '-' || lpad(nextval('financial_event_code_seq')::text, 6, '0');

        INSERT INTO financial_events (
            event_code, event_type, source_table, source_id, event_date,
            idempotency_key, amounts, status, created_by
        ) VALUES (
            v_event_code, 'EXPENSE_POSTED'::event_type, 'cash_advances', NEW.id, NEW.transaction_date,
            'CA|APPROVED|' || NEW.ca_no || '|V1', 
            jsonb_build_object(
                'amount', NEW.amount,
                'category', NEW.category,
                'description', NEW.description,
                'payment_method', NEW.payment_method::TEXT
            ),
            'READY'::event_status, NEW.created_by
        );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER cash_advances_financial_event_trigger
AFTER INSERT OR UPDATE ON cash_advances
FOR EACH ROW EXECUTE FUNCTION trg_cash_advances_to_financial_events();


-- -----------------------------------------------------
-- Trigger: bank_deposits_to_financial_events
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION trg_bank_deposits_to_financial_events() 
RETURNS TRIGGER AS $$
DECLARE
    v_event_code TEXT;
BEGIN
    -- Prevent duplicates
    IF EXISTS (
        SELECT 1 FROM financial_events 
        WHERE source_table = 'bank_deposits' AND source_id = NEW.id
    ) THEN
        RETURN NEW;
    END IF;

    -- Generate Event Code
    v_event_code := 'EVT-' || to_char(NOW(), 'YYYYMMDD') || '-' || lpad(nextval('financial_event_code_seq')::text, 6, '0');

    INSERT INTO financial_events (
        event_code, event_type, source_table, source_id, event_date,
        idempotency_key, amounts, status, created_by
    ) VALUES (
        v_event_code, 'BANK_DEPOSIT'::event_type, 'bank_deposits', NEW.id, NEW.transaction_date,
        'DEP|POSTED|' || NEW.deposit_no || '|V1', 
        jsonb_build_object(
            'amount', NEW.amount,
            'bank_account_info', NEW.bank_account_info
        ),
        'READY'::event_status, NEW.created_by
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER bank_deposits_financial_event_trigger
AFTER INSERT ON bank_deposits
FOR EACH ROW EXECUTE FUNCTION trg_bank_deposits_to_financial_events();
