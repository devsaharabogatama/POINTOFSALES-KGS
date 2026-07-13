-- -----------------------------------------------------
-- RPC: process_financial_events_queue
-- -----------------------------------------------------
CREATE OR REPLACE FUNCTION process_financial_events_queue() 
RETURNS JSONB AS $$
DECLARE
    v_event RECORD;
    v_journal_no TEXT;
    v_group_id TEXT;
    v_sales_net NUMERIC;
    v_hpp NUMERIC;
    v_cash NUMERIC;
    v_transfer NUMERIC;
    v_qris NUMERIC;
    v_balance NUMERIC;
    v_ar NUMERIC;
    v_amount NUMERIC;
    v_payment_method TEXT;
    v_category TEXT;
    v_description TEXT;
    v_processed_count INT := 0;
    v_error_count INT := 0;
    v_results JSONB := '[]'::jsonb;
BEGIN
    -- Loop through READY events (Using SKIP LOCKED to prevent concurrent worker collisions)
    FOR v_event IN 
        SELECT * FROM financial_events 
        WHERE status = 'READY' 
        ORDER BY event_date ASC, event_code ASC
        FOR UPDATE SKIP LOCKED
    LOOP
        BEGIN
            -- 1. Mark event as PROCESSING
            UPDATE financial_events 
            SET status = 'PROCESSING', processed_at = NOW() 
            WHERE id = v_event.id;

            -- 2. Construct entry group ID
            v_group_id := 'JE-' || v_event.event_code;

            -- 3. Resolve Accounting Rules by event_type
            IF v_event.event_type = 'SALE_POSTED' THEN
                -- Extract amounts from JSONB payload
                v_sales_net := COALESCE((v_event.amounts->>'sales_net_amount')::NUMERIC, 0);
                v_hpp := COALESCE((v_event.amounts->>'hpp_amount')::NUMERIC, 0);
                v_cash := COALESCE((v_event.amounts->>'cash_amount')::NUMERIC, 0);
                v_transfer := COALESCE((v_event.amounts->>'transfer_amount')::NUMERIC, 0);
                v_qris := COALESCE((v_event.amounts->>'qris_amount')::NUMERIC, 0);
                v_balance := COALESCE((v_event.amounts->>'customer_balance_amount')::NUMERIC, 0);
                v_ar := COALESCE((v_event.amounts->>'ar_amount')::NUMERIC, 0);

                -- Verify double entry equation: Cash + Transfer + QRIS + Balance + AR = Sales Net
                IF (v_cash + v_transfer + v_qris + v_balance + v_ar) != v_sales_net THEN
                    RAISE EXCEPTION 'Double entry mismatch: Sum of payments (Rp %) != Net Sales (Rp %)', 
                        (v_cash + v_transfer + v_qris + v_balance + v_ar), v_sales_net;
                END IF;

                -- A. Post Revenue (Credit) & Payments/Receivables (Debit)
                v_journal_no := 'JNL-' || to_char(NOW(), 'YYYYMMDD') || '-' || lpad(nextval('journal_no_seq')::text, 4, '0');
                
                -- PENJUALAN (Credit)
                INSERT INTO journal_entries (journal_no, entry_group_id, transaction_date, financial_event_id, coa_code, coa_name, debit, kredit, note)
                VALUES (v_journal_no, v_group_id, v_event.event_date, v_event.id, '4101-01', 'Pendapatan Penjualan', 0, v_sales_net, 'Penjualan SO ' || v_event.event_code);

                -- DEBITS (Payments)
                IF v_cash > 0 THEN
                    INSERT INTO journal_entries (journal_no, entry_group_id, transaction_date, financial_event_id, coa_code, coa_name, debit, kredit, note)
                    VALUES (v_journal_no, v_group_id, v_event.event_date, v_event.id, '1101-01', 'Kas Kasir KGS', v_cash, 0, 'Pembayaran Tunai SO ' || v_event.event_code);
                END IF;
                IF v_transfer > 0 THEN
                    INSERT INTO journal_entries (journal_no, entry_group_id, transaction_date, financial_event_id, coa_code, coa_name, debit, kredit, note)
                    VALUES (v_journal_no, v_group_id, v_event.event_date, v_event.id, '1102-01', 'Bank BCA Mandiri', v_transfer, 0, 'Pembayaran Transfer SO ' || v_event.event_code);
                END IF;
                IF v_qris > 0 THEN
                    INSERT INTO journal_entries (journal_no, entry_group_id, transaction_date, financial_event_id, coa_code, coa_name, debit, kredit, note)
                    VALUES (v_journal_no, v_group_id, v_event.event_date, v_event.id, '1102-02', 'QRIS Kasir', v_qris, 0, 'Pembayaran QRIS SO ' || v_event.event_code);
                END IF;
                IF v_balance > 0 THEN
                    INSERT INTO journal_entries (journal_no, entry_group_id, transaction_date, financial_event_id, coa_code, coa_name, debit, kredit, note)
                    VALUES (v_journal_no, v_group_id, v_event.event_date, v_event.id, '2102-01', 'Titipan Deposito Pelanggan', v_balance, 0, 'Pembayaran Saldo Deposito SO ' || v_event.event_code);
                END IF;
                IF v_ar > 0 THEN
                    INSERT INTO journal_entries (journal_no, entry_group_id, transaction_date, financial_event_id, coa_code, coa_name, debit, kredit, note)
                    VALUES (v_journal_no, v_group_id, v_event.event_date, v_event.id, '1201-01', 'Piutang Dagang', v_ar, 0, 'Tempo Piutang SO ' || v_event.event_code);
                END IF;

                -- B. Post COGS / HPP (Debit HPP, Credit Persediaan)
                IF v_hpp > 0 THEN
                    v_journal_no := 'JNL-' || to_char(NOW(), 'YYYYMMDD') || '-' || lpad(nextval('journal_no_seq')::text, 4, '0');
                    
                    -- HPP (Debit)
                    INSERT INTO journal_entries (journal_no, entry_group_id, transaction_date, financial_event_id, coa_code, coa_name, debit, kredit, note)
                    VALUES (v_journal_no, v_group_id, v_event.event_date, v_event.id, '5101-01', 'Harga Pokok Penjualan (HPP)', v_hpp, 0, 'HPP Penjualan SO ' || v_event.event_code);
                    
                    -- PERSEDIAAN (Credit)
                    INSERT INTO journal_entries (journal_no, entry_group_id, transaction_date, financial_event_id, coa_code, coa_name, debit, kredit, note)
                    VALUES (v_journal_no, v_group_id, v_event.event_date, v_event.id, '1301-01', 'Persediaan Barang Dagang', 0, v_hpp, 'Pengurangan Stok Persediaan SO ' || v_event.event_code);
                END IF;

            ELSIF v_event.event_type = 'EXPENSE_POSTED' THEN
                -- Beban Operasional / Cash Advance
                v_amount := COALESCE((v_event.amounts->>'amount')::NUMERIC, 0);
                v_category := COALESCE(v_event.amounts->>'category', 'Umum');
                v_description := COALESCE(v_event.amounts->>'description', 'Beban Operasional');
                v_payment_method := COALESCE(v_event.amounts->>'payment_method', 'Cash');

                v_journal_no := 'JNL-' || to_char(NOW(), 'YYYYMMDD') || '-' || lpad(nextval('journal_no_seq')::text, 4, '0');

                -- BEBAN (Debit) - mapping to different COAs based on category
                INSERT INTO journal_entries (journal_no, entry_group_id, transaction_date, financial_event_id, coa_code, coa_name, debit, kredit, note)
                VALUES (v_journal_no, v_group_id, v_event.event_date, v_event.id, 
                    CASE WHEN v_category = 'Bensin' THEN '6101-01' 
                         WHEN v_category = 'Uang Makan' THEN '6101-02'
                         ELSE '6101-99' END, 
                    'Beban Operasional - ' || v_category, v_amount, 0, v_description);

                -- KAS/BANK (Credit)
                INSERT INTO journal_entries (journal_no, entry_group_id, transaction_date, financial_event_id, coa_code, coa_name, debit, kredit, note)
                VALUES (v_journal_no, v_group_id, v_event.event_date, v_event.id, 
                    CASE WHEN v_payment_method = 'Transfer' THEN '1102-01' ELSE '1101-01' END,
                    CASE WHEN v_payment_method = 'Transfer' THEN 'Bank BCA Mandiri' ELSE 'Kas Kasir KGS' END,
                    0, v_amount, 'Pengeluaran Cash Advance - ' || v_description);

            ELSIF v_event.event_type = 'BANK_DEPOSIT' THEN
                -- Setor Tunai Kasir ke Bank
                v_amount := COALESCE((v_event.amounts->>'amount')::NUMERIC, 0);
                v_description := COALESCE(v_event.amounts->>'bank_account_info', 'Setor Tunai');

                v_journal_no := 'JNL-' || to_char(NOW(), 'YYYYMMDD') || '-' || lpad(nextval('journal_no_seq')::text, 4, '0');

                -- BANK (Debit)
                INSERT INTO journal_entries (journal_no, entry_group_id, transaction_date, financial_event_id, coa_code, coa_name, debit, kredit, note)
                VALUES (v_journal_no, v_group_id, v_event.event_date, v_event.id, '1102-01', 'Bank BCA Mandiri', v_amount, 0, 'Penerimaan Setoran Bank - ' || v_description);

                -- KAS (Credit)
                INSERT INTO journal_entries (journal_no, entry_group_id, transaction_date, financial_event_id, coa_code, coa_name, debit, kredit, note)
                VALUES (v_journal_no, v_group_id, v_event.event_date, v_event.id, '1101-01', 'Kas Kasir KGS', 0, v_amount, 'Setor Kas ke Bank - ' || v_description);
            
            ELSE
                RAISE EXCEPTION 'Unsupported event type: %', v_event.event_type;
            END IF;

            -- 4. Mark event as DONE
            UPDATE financial_events 
            SET status = 'DONE', error_message = NULL 
            WHERE id = v_event.id;

            -- 5. Trigger POS Reconciliation Row
            IF v_event.event_type = 'SALE_POSTED' THEN
                INSERT INTO pos_reconciliations (
                    sales_id, reconciled_at, status, 
                    pos_net_sales, journal_net_sales, 
                    pos_net_cash, journal_net_cash, 
                    pos_net_transfer, journal_net_transfer, 
                    pos_net_qris, journal_net_qris, 
                    pos_net_ar, journal_net_ar, 
                    pos_net_hpp, journal_net_hpp,
                    differences
                ) VALUES (
                    v_event.source_id, NOW(), 'MATCH'::recon_status,
                    v_sales_net, v_sales_net,
                    v_cash, v_cash,
                    v_transfer, v_transfer,
                    v_qris, v_qris,
                    v_ar, v_ar,
                    v_hpp, v_hpp,
                    '{"sales":0,"cash":0,"transfer":0,"qris":0,"ar":0,"hpp":0}'::jsonb
                ) ON CONFLICT (sales_id) DO UPDATE SET
                    reconciled_at = NOW(),
                    status = 'MATCH'::recon_status,
                    differences = '{"sales":0,"cash":0,"transfer":0,"qris":0,"ar":0,"hpp":0}'::jsonb;
                
                -- Update sales_headers financial status
                UPDATE sales_headers 
                SET financial_status = 'POSTED'::financial_status, recon_status = 'MATCH'::recon_status 
                WHERE id = v_event.source_id;
            END IF;

            v_processed_count := v_processed_count + 1;
            v_results := v_results || jsonb_build_object('event_code', v_event.event_code, 'status', 'SUCCESS');

        EXCEPTION WHEN OTHERS THEN
            -- Rollback internal entries of this specific block iteration
            -- and mark the event as ERROR
            v_error_count := v_error_count + 1;
            v_results := v_results || jsonb_build_object('event_code', v_event.event_code, 'status', 'ERROR', 'message', SQLERRM);

            UPDATE financial_events 
            SET status = 'ERROR', error_message = SQLERRM 
            WHERE id = v_event.id;

            IF v_event.event_type = 'SALE_POSTED' THEN
                UPDATE sales_headers 
                SET financial_status = 'ERROR'::financial_status 
                WHERE id = v_event.source_id;
            END IF;
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'processed', v_processed_count,
        'errors', v_error_count,
        'results', v_results
    );
END;
$$ LANGUAGE plpgsql;
